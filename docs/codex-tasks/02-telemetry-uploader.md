# 工单 02 — Mac 侧遥测上报器（Swift，root LaunchDaemon）

## 目标

在现有 CapslockPlusMac 项目里增加一个**独立于界面的**后台上报器：以 root LaunchDaemon
常驻，把本机进程快照按分层节奏推到自建服务 `capsql-api`，断网时本地排队、恢复后补传。

## 非目标（本轮不做）

- 不改现有 UI、不动活动监视器窗口、不改菜单栏读数（除 main 的参数分发外不碰 UI 文件）
- 不做服务端代码（已交付，见 `~/projects/capsql-api`）
- 不做多设备管理界面、不做证书/HTTPS（局域网 HTTP + token）
- 不实现压缩（服务端支持 gzip，但客户端先发明文 JSON，等实测包大小再决定）

## 已验证的环境事实（不要重新调研）

- 仓库：`~/projects/capslock_plus_mac`（SwiftPM，`Sources/CapslockPlusMac/`）
- **编译只能在 Mac 上**：`./scripts/build-mac.sh`（从 Linux 经 ssh 到 mac 上 `swift build -c release --arch arm64`
  并签名自检）。Linux 侧没有 macOS SDK，**不要尝试本地编译**。
- 现有采样器（`Support/ProcessSampler.swift`）：
  - `ProcessSampler.sample() -> [ProcessSample]`，`ProcessSample` 字段只有：
    `pid, name, cpu(百分比，可>100), memory(字节，phys_footprint), ports([UInt16]), measurable, down, up(字节/秒)`
  - 已有 `func networkTotals(for pid: pid_t) -> (down: UInt64, up: UInt64)?`：**累计字节**（nettop 口径，
    进程启动至今），采样过一轮后可用；没有该 pid 时返回 (0,0)，还没采过返回 nil。
  - 采样里**没有**：启动时间、可执行路径、argv、用户、ppid、threads、open_files —— 这些要用 libproc 取。
- 服务端接口（已实测通过，契约固定）：
  - `POST http://192.168.8.101:8787/v1/samples`
  - Header：`Authorization: Bearer <44 字符 token>`、`Content-Type: application/json`
  - 请求体：
    ```json
    {"agent": {"version": "0.5.0", "hostname": "mac-mini.local", "hardware": "Mac14,6", "os": "macOS 27.2"},
     "samples": [ {"pid":410, "ppid":1, "name":"WindowServer", "user":"_windowserver",
                   "exe":"/usr/sbin/WindowServer", "argv":["/usr/sbin/WindowServer"],
                   "started_at":"2026-11-23T09:00:00+08:00", "ended":false, "ports":[5000],
                   "ts":"2026-11-23T10:00:00+08:00",
                   "cpu":11.5, "rss":780000000, "footprint":820000000,
                   "threads":210, "open_files":940,
                   "net_rx":123456789, "net_tx":9876543, "net_rx_rate":120000, "net_tx_rate":8000} ]}
    ```
  - 约束（服务端会 422 拒绝）：`started_at <= ts`；两个时间都必须带时区偏移；
    `samples` 最多 5000 条；`cpu >= 0`；`threads <= 32767`；端口 0..65535。
  - 响应：`{"accepted":N,"inserted":N,"dropped":N,"device_id":N}`；`inserted` 可能小于 `accepted`（重复样本被去重），
    这是正常现象，不要当失败重试。
  - 服务端会丢弃 `ts` 早于 45 天的样本（计入 `dropped`），客户端排队太久的老数据不必再发。

## 交付物（路径固定）

```
Sources/CapslockPlusMac/Telemetry/TelemetryConfig.swift   # 读 /Library/Application Support/CapslockPlusMac/telemetry.json
Sources/CapslockPlusMac/Telemetry/ProcessMeta.swift       # libproc 取 ppid/uid→用户名/启动时间/exe/argv/threads/open_files
Sources/CapslockPlusMac/Telemetry/TelemetryPolicy.swift   # 分层节奏：谁这一轮要上报（纯函数，可自检）
Sources/CapslockPlusMac/Telemetry/TelemetryBuffer.swift   # SQLite 排队（未发送批次），容量上限与淘汰
Sources/CapslockPlusMac/Telemetry/TelemetryUploader.swift # URLSession POST、退避重试、40x/50x 分类处理
Sources/CapslockPlusMac/Telemetry/TelemetryAgent.swift    # 主循环（60s tick），组装 payload
Sources/CapslockPlusMac/Telemetry/TelemetrySelftest.swift # --telemetry-selftest 的断言集
Sources/CapslockPlusMac/main.swift 或现有入口           # 只加参数分发：--telemetry-agent / --telemetry-once / --telemetry-selftest
deploy/com.icecreamzhao.capslockplus.telemetry.plist      # LaunchDaemon（RunAtLoad + KeepAlive）
deploy/install-telemetry-daemon.sh                        # sudo 安装：写配置、拷 plist、launchctl bootstrap
docs/codex-tasks/02-telemetry-uploader.md                 # 本工单（原样保留）
```

## 行为规格

### 采集（每个 tick）

复用 `ProcessSampler.sample()` 拿到 pid/name/cpu/memory/ports/down/up，
再用 `ProcessMeta` 补齐：`ppid`、`user`（uid → getpwuid）、`started_at`（PROC_PIDTBSDINFO 的
`pbi_start_tvsec`/`pbi_start_tvusec`）、`exe`（`proc_pidpath`）、`argv`（`KERN_PROCARGS2`）、
`threads`、`open_files`（`proc_pidinfo(PROC_PIDLISTFDS)` 计数）。

- `argv`/`exe` 对**别的用户**的进程需要 root，非 root 时读不到就填 `null`/空数组，**不要报错退出**。
- 这几个元数据几乎不变：按 pid 缓存，`started_at` 与 `exe` 只在首次见到该 pid 时取；
  `argv` 每 10 分钟刷一次；`threads/open_files` 每轮取（代价小）。
- `net_rx/net_tx` 取 `networkTotals(for:)` 的累计值；`net_rx_rate/net_tx_rate` 用相邻两轮差值 ÷ 秒数 取整。

### 上报节奏（TelemetryPolicy，纯函数，必须可自检）

```
每 60 秒一个 tick
  hot    : 按 cpu 降序前 30 个进程 → 每个 tick 都发
  active : cpu 差 > 0.5 或 rss 差 > 8MB 或 net 计数有增长 → 最多每 5 分钟发一次
  idle   : 其余 → 每 30 分钟发一条心跳
首次运行：所有进程都发一次（建立基线）
```

### 排队与重试（TelemetryBuffer）

- SQLite 路径：`/Library/Application Support/CapslockPlusMac/telemetry.db`（root 600），
  WAL 模式；表 `pending(id INTEGER PRIMARY KEY, created_at REAL, payload BLOB)`。
- 网络失败/超时：批次留在表里，下一 tick 先发最旧的；单批最大 5000 条。
- 退避：连续失败 1/2/4/8 分钟，最长 15 分钟；成功一批立即复位。
- 容量：超过 200 MB 或最老一条超过 7 天 → 删除最老的（记日志，不要静默）。
- 服务端 401 → 不重试这个批次，日志里写一次 `AUTH_FAILED`（token 过期要人处理），之后每 10 分钟才试一次。
- 服务端 5xx/网络错误 → 正常按退避重试。

### 配置

`/Library/Application Support/CapslockPlusMac/telemetry.json`（root 600）：

```json
{"server_url": "http://192.168.8.101:8787", "token": "<44 字符>", "enabled": true}
```

文件不存在或 `enabled=false` → `--telemetry-agent` 直接退出（exit 0，不刷屏）。

### 日志

统一走 `Log.info/warn`（项目已有 `Log`）。每 tick 最多 2 行：本轮发送条数、队列深度。
不要每个进程打一行（840 进程会淹没日志）。

## 自检（`--telemetry-selftest`，不需要网络/数据库）

必须断言并打印 `telemetry selftest OK (N assertions)`：

1. 政策：给定 840 个进程、其中 30 个 hot，tick=1 → 全部上行；tick=2 → 只有 hot；
   tick=60（5 分钟）→ hot + active；tick=360（30 分钟）→ 全部（心跳）。
2. 政策：cpu 变化 0.4% 不算变化，0.6% 算。
3. payload：`started_at <= ts` 恒成立（用一个未来启动时间构造，断言被裁剪）。
4. payload：`threads` 超过 32767 被截断；`cpu` 负数被夹到 0。
5. argv 摘要：同 argv 不同 pid 不互相污染（缓存键是 pid）。
6. 缓冲区：写入 3 批 → 读回顺序为 FIFO；超过上限的最老批被删。

## 禁止事项

- 不要改 `SystemMonitor`、`StatusReadoutView`、`SystemWindow`、`ProcessDetailPanel`
- 不要动现有 `scripts/build-mac.sh` / `sync-to-mac.sh`
- 不要引入第三方依赖（只用 Foundation / Darwin / SQLite3 / Compression 系统框架）
- 不要在 `--telemetry-agent` 模式下初始化 `NSApplication` 或加载 UI
- 不要用 `NSAppleScript`、不要弹授权框（root 由 LaunchDaemon 提供）

## 验收命令（我在 Mac 上跑）

```bash
./scripts/build-mac.sh                       # 必须 BUILD OK
dist/CapslockPlusMac.app/Contents/MacOS/CapslockPlusMac --telemetry-selftest
dist/CapslockPlusMac.app/Contents/MacOS/CapslockPlusMac --telemetry-once   # 打印将要发送的条数与样例
# 真机联调：装 daemon → 查库
ssh rock5bpa 'psql ... -c "select count(*), max(ts) from process_samples"'
```

## 交付总结要求

6 行以内：新增/修改了哪些文件、哪些地方没把握（尤其是 KERN_PROCARGS2 的解析、
PROC_PIDTBSDINFO 字段偏移、SQLite 在没有 C 模块时的接入方式），验证者需要注意什么。
