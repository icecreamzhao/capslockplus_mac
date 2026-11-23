# 工单 08 — 远端视图与本机同频（2 秒）

## 目标

让「看远端设备」的更新频率和数据新鲜度与本机一致：

```
本机视图   2 秒一采（Config.systemSampleMs = 2000），数据当场
远端视图   现在 5 秒轮询 + 后台上报 60 秒一次 → 看着"卡在半分钟前"
改后       上报 2 秒一次、客户端 2 秒轮询、详情 2 秒刷新
```

## 已验证的事实（不要重新调研）

```
TelemetryAgent.tickInterval = 60（Sources/CapslockPlusMac/Telemetry/TelemetryAgent.swift:237）
  tick() 内部调 collector.collect(now:)，它会调 ProcessSampler.sample()，
  sample() 本身含 networkSampler.sample()（nettop）——也就是本机活动监视器
  每 2 秒已经在跑同一套东西，所以这里降到 2 秒不引入新的量级开销。
SystemWindow.startRemoteTimer()   Timer(timeInterval: 5.0)   → 改 2.0
SystemWindow.loadRemoteDetail()   Date().timeIntervalSince(remoteDetailLastFetch) < 5 → 改 < 2
footerLabel 文案里有「远端每 5 秒刷新」→ 改成 2 秒
```

## 要做的事

### 1. 上报端 60 → 2 秒

`TelemetryAgent.tickInterval` 改成 `2`。

同一处顺带确认（不要改逻辑，只确认并报告）：
- `TelemetryPolicy.duePIDs` 在 tick 变快后是否仍按"hot 每分钟/active 5 分钟/idle 30 分钟"分层；
  2 秒 tick 下 hot 进程会每个 tick 都上报（这是我们要的），**但 active/idle 的分层阈值不能跟着变短**。
- 队列/批次逻辑（`batchLimit`）不受影响。

### 2. 客户端轮询 5 → 2 秒

- `startRemoteTimer()`：`Timer(timeInterval: 2.0, repeats: true)`。
- `loadRemoteDetail()` 的节流：`< 2`。
- `footerLabel`：`远端每 2 秒刷新`。

### 3. 不要做的事

- 不要给远端轮询加并发/合并队列的复杂机制——`remoteRequestInFlight` 已经防重入；
  如果一次请求超过 2 秒，下一次 tick 会被这个标志跳过，这行为正确。
- 不要改本机采样间隔（`Config.systemSampleMs` 保持 2000，用户可自己在配置里改）。
- 不要动 Telemetry 的网络采集方式（nettop 每 tick 跑一次是现状，本机 UI 也这样）。

## 验收（我在 Mac 上跑）

```bash
./scripts/build-mac.sh                                     # Build complete
dist/CapslockPlusMac.app/Contents/MacOS/CapslockPlusMac --selftest   # 55 bindings 不倒退
dist/CapslockPlusMac.app/Contents/MacOS/CapslockPlusMac --device-menu-selftest ubuntu  # 6 assertions
dist/CapslockPlusMac.app/Contents/MacOS/CapslockPlusMac --remote-probe ubuntu          # 三条链路
# 真机上：切到 ubuntu，观察 CPU 列数值应每 2 秒变化一次（和本机视图节奏一致）
# 服务端看：journalctl -u capsql-api | grep "POST /v1/samples" 应约每 2 秒一条
```

## 约束

- 不引入第三方库、不用 SwiftUI
- 只改 `Telemetry/TelemetryAgent.swift` 和 `UI/SystemWindow.swift`
