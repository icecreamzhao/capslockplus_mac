# 工单 04 — 活动监视器里的「设备切换」（看其他设备的进程）

## 目标

在现有活动监视器窗口里加一个设备下拉框：选「本机」时行为完全不变；选某个远端设备时，
表格显示那台机器的进程（来自 `capsql-api`），点 ⓘ 看到它的完整详情（含 argv、启动时间、累计流量）。

## 非目标

- 不做网页界面、不做移动端
- 不做读取鉴权（用户明确选了「只在内网、不设鉴权」）
- 不做进程操作（结束进程/改优先级一律不提供，远端更不提供）
- 不改上报侧（Telemetry/ 目录一律不动）

## 服务端契约（已上线，实测过，字段名照抄）

```
GET {base}/v1/devices                    → [{id, hostname, hardware, os, agent_version, last_seen, instance_count}]
GET {base}/v1/devices/{hostname}/processes?limit=500
                                         → [{device_id, hostname, instance_id, name, pid, user_name, started_at,
                                             exe_path, ports, last_seen, cpu, rss, footprint, threads,
                                             open_files, net_rx, net_tx, net_rx_rate, net_tx_rate}]
GET {base}/v1/instances/{instance_id}    → 上面那些 + {ppid, ended_at, argv: [String]}
                                           不存在的 id → 404
```

- 全部**不需要 token**（只有 `POST /v1/samples` 需要）。
- `base` 默认 `http://192.168.8.101:8787`（经路由器 DNAT 到板子的 tailnet 地址，家里/公司都通）。
- 远端数据的刷新节奏不等于本地采样节奏：远端 5 秒一次，本地保持现有的 `SystemMonitor.didUpdate`。

## 现有代码事实（不要重新调研）

```
SystemWindow.swift       627 行，SystemWindowController: NSObject, NSWindowDelegate,
                         NSTableViewDataSource, NSTableViewDelegate
  - 列：进程/CPU/内存/端口/下载/上传/PID（addColumn(_:key:width:alignment:flex:)）
  - rows() -> [ProcessSample]（ProcessSample: pid, name, cpu, memory, ports, measurable, down, up）
  - refresh() 由 SystemMonitor.didUpdate 通知驱动（本地采样，2 秒一档）
  - showProcessDetail(_ sender: InfoButton) 第 450 行：ProcessInspector.inspect(pid:) → 面板
  - InfoButton 只带 `var pid: pid_t`（第 614 行）
  - 头部是手工 frame 布局的 NSTextField/NSProgressIndicator，位置写死在 buildContent() 里
  - UserDefaults 已在本文件使用（`systemWindow.origin`），可以照这个风格存选择
ProcessDetailPanel.swift 248 行
  - show(_ detail: ProcessDetail) → startUpdating() 每 2 秒 refreshTick()
  - refreshTick() 第 102 行**直接调 ProcessInspector.inspect(pid:)**（本机！）
  - 已有 `extraFieldsProvider: ((pid_t) -> [ProcessDetail.Field])?`（本机网络累计用）
  - ProcessDetail: pid + fields: [Field(label,value)]（Codable）
ProcessInspector.swift   本机详情来源（不适用于远端）
```

## 交付物

```
Sources/CapslockPlusMac/UI/RemoteDevices.swift
    - struct RemoteDevice / RemoteProcess / RemoteInstanceDetail（Decodable，字段名用 CodingKeys 映射）
    - final class RemoteClient：URLSession 三个 GET，base 取 UserDefaults["telemetry.serverURL"]
    - 必须设置 `configuration.connectionProxyDictionary = [:]`：macOS 会默认走系统代理，
      本机就有 HTTP_PROXY=192.168.8.1:7890，不关会让请求变成 502/超时（已在服务端侧实测过同样的坑）
    - 超时 5 秒，`waitsForConnectivity = false`，completion 一律回主线程
Sources/CapslockPlusMac/UI/SystemWindow.swift（改动集中在这里）
Sources/CapslockPlusMac/UI/ProcessDetailPanel.swift（只加一个 hook，见下）
```

## 行为规格

### 设备下拉框

- 位置：窗口头部现有控件下方/右侧的空位，宽 150，不要挤掉 CPU/内存 条和网络行。
- 条目：`本机` + 每台远端 `hostname`（后面跟 `· 8m` 这样的「上次上报距今」，超过 10 分钟标灰）。
- 选中项持久化到 `UserDefaults["systemWindow.device"]`（本机存 `__local__`）。
- 下拉框底部加一条分隔项 `设置服务器…`：弹 NSAlert + NSTextField 编辑 base URL，
  写回 `UserDefaults["telemetry.serverURL"]`，然后重新拉设备列表。
- 每次下拉展开时异步刷一次 `/v1/devices`（不要常驻轮询，避免无谓请求）。

### 远端模式

- 选中远端后：`Timer(5s)` 拉 `/v1/devices/{hostname}/processes?limit=500`，主线程重载表格。
- 行数据映射成现有的 `ProcessSample`（table 的数据源不动）：
  `pid/name/cpu/memory=rss/ports/down=net_rx_rate/up=net_tx_rate/measurable=true`。
  同时维护 `instanceByPid: [pid_t: Int64]` 供 ⓘ 用。
- 顶部摘要行改成 `远程 <hostname> · 更新于 HH:mm:ss · N 个进程`；网络行显示该设备的
  `Σ net_rx_rate / Σ net_tx_rate`。
- **本机专属控件在远端模式下必须禁用**：`读取系统进程`（root 代理）按钮、以及任何启动本地采样/root 采样的入口。
- 请求失败：保留上一份数据、摘要行显示 `无法连接 <base>（<错误摘要>）`，5 秒后继续重试；
  不要把表格清空、不要弹窗。
- 切回「本机」时恢复原行为：重新绑定 `SystemMonitor.didUpdate`、重新启用 root 按钮、清掉远端缓存。

### ⓘ 详情（远端）

- `InfoButton` 增加 `var instanceID: Int64 = 0`；本机行保持 0。
- `showProcessDetail`：`instanceID != 0` 时走 `RemoteClient.fetchInstance(id:)`，
  用返回数据拼 `ProcessDetail`（字段顺序照本机那套的观感）：
  `名称 / PID / 父进程 PID / 用户 / 可执行文件 / 启动时间（含「已运行 x 天 x 小时」）/`
  `CPU / 内存(RSS) / 物理内存(footprint，空则显示 —) / 线程 / 打开文件 / 监听端口 /`
  `累计下载 / 累计上传 / 下载速率 / 上传速率 / 最后上报时间`
- `ProcessDetailPanel` 新增：
  ```swift
  /// 非空时用它代替 ProcessInspector 刷新（远端设备）。
  /// 不加这个 hook，远端详情的 2 秒刷新会去读本机同 pid 的进程，显示成完全不相干的程序。
  var refreshProvider: (() -> ProcessDetail?)?
  ```
  `refreshTick()` 里优先用它；命中时不要再去调 `ProcessInspector` / `RootProbe`。
  `extraFieldsProvider`（本机网络累计）在远端模式下也不应生效（远端字段已经自带）。
- 关闭面板或切换设备时清理 `refreshProvider`。

## 验收（我在 Mac 上跑，不看你自述）

```bash
./scripts/build-mac.sh                                  # 必须 Build complete
dist/.../CapslockPlusMac --ui-selftest                  # 不能倒退（现有自检项）
# 然后在真机上看：
#   1. 下拉框有「本机 + littleboydeMBP + ubuntu」
#   2. 切到 ubuntu：表格出现 python3/hermes/sshd 这些 Linux 进程，CPU 有值
#   3. 点 hermes 的 ⓘ：argv 里有那串 python 内联脚本，启动时间 12:03，累计下载有数字
#   4. 面板开着 6 秒：数值变化但标题不变（没有变成 Mac 上的同 pid 进程）
#   5. 切回本机：行为与改动前一致
#   6. 断开服务器（改成一个不存在的 IP）：摘要行报错，表格不清空，不弹窗
```

## 禁止事项

- 不要改 Telemetry/ 下任何文件
- 不要改 ProcessSampler / SystemMonitor / NetworkSampler 的语义
- 不要引入第三方库；不要用 SwiftUI
- 不要在远端模式下启动本地采样或 root 代理

## 交付总结要求

6 行以内：改了哪些文件、下拉框放在哪个坐标（避免压住现有控件）、远端详情那个 hook 怎么保证不会误读本机 pid。
