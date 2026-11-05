# 工单 05 — 睡眠唤醒 / 设备变化后自动恢复

## 背景

现在的 app 只在启动时做两件事：建 event tap、把 caps 重映射成 F18。实测有两个会失灵的时机：

1. 睡眠唤醒后 tap 可能被系统禁用或端口失效（`kCGEventTapDisabledByTimeout` 之外，唤醒时 tap 也可能被摘），
   hidutil 的按键映射在部分机器上唤醒后也会丢（映射是按设备生效的）。
2. 外接键盘热插拔后，新枚举出来的设备没有 `UserKeyMapping`，caps 在那个键盘上就不是 F18。

## 要做的

只改 `Sources/CapslockPlusMac/AppDelegate.swift`、`Sources/CapslockPlusMac/KeyLayer/EventTapEngine.swift`，
并新增 `Sources/CapslockPlusMac/Support/SystemEvents.swift`。其他文件不要动。

### 1. `EventTapEngine`

增加：

```swift
func ensureHealthy()   // 见下
var isAlive: Bool { get }   // tap != nil && CFMachPortIsValid(tap)
```

`ensureHealthy()` 行为：
- `tap == nil` 或 `!CFMachPortIsValid(tap)` → `stop()` 然后 `start()`，日志 `tap=recreated ok|fail`
- 否则 `CGEvent.tapIsEnabled(tap:) == false` → `CGEvent.tapEnable(tap:enable:true)`，日志 `tap=reenabled`
- 都正常 → 日志 `tap=ok`
- 注意 `CFMachPortIsValid` 要 import CoreFoundation。

### 2. `Support/SystemEvents.swift`（新增）

```swift
final class SystemEvents {
    static let shared = SystemEvents()
    var onWake: (() -> Void)?
    var onHIDDeviceChange: (() -> Void)?
    func start()
    func stop()
}
```

- 唤醒：`NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, ...)`，
  同时在收到后延迟 1.5 秒再触发一次（系统唤醒后设备服务还在恢复）。
- 设备变化：用 IOKit 匹配通知监听 HID 设备增删：
  `IOServiceAddMatchingNotification(kIOMasterPortDefault, kIOMatchedNotification, IOServiceMatching(kIOHIDDeviceKey), callback, refcon, &iterator)`，
  然后**必须**先 `IOIteratorNext` 把现有设备全部消费掉（否则不会回调），再在回调里同样消费迭代器。
  回调线程不是主线程 → 用 `DispatchQueue.main.async` 回到主线程再调 `onHIDDeviceChange`。
  只保留一个 iterator，`stop()` 时 `IOObjectRelease`。

### 3. `AppDelegate`

- `applicationDidFinishLaunching` 末尾：`SystemEvents.shared.start()`，并设置两个回调：
  ```swift
  onWake/onHIDDeviceChange → recover(reason:)
  func recover(reason: String) {
      engine?.ensureHealthy()
      if !KeyRemap.isApplied() { _ = KeyRemap.apply() ; Log.info("remap reapplied reason=\(reason)") }
      else { Log.info("remap ok reason=\(reason)") }
  }
  ```
- 唤醒后如果 `AX.isTrusted == false`（用户可能在别处关掉了权限），记 `Log.error("ax revoked")` 并重试一次 tap，不要弹窗轰炸。
- `applicationWillTerminate`：`SystemEvents.shared.stop()`。

## 日志要求

```
[I] wake recover
[I] tap=ok / tap=recreated ok
[I] remap ok reason=wake | remap reapplied reason=hidchange
```

## 验收（我在 Mac 上跑）

```
swift build -c release --arch arm64
./scripts/build.sh
./dist/CapslockPlusMac.app/Contents/MacOS/CapslockPlusMac --selftest
```
真机：睡眠→唤醒后日志出现 wake recover 且没有 error；`hidutil property --get UserKeyMapping` 仍有映射。

## 不要做

- 不要改 CapsState / KeyPost / Actions / Config / Log / HIDCapsLock
- 不要引入依赖、不要联网、不要试 `swift build`（本机无工具链）
- 不要在回调里做耗时操作（IOKit 回调线程不要阻塞）

## 结束

4 行以内：唤醒和设备变化分别怎么触发、IOKit 迭代器消费有没有漏、1.5 秒二次触发的作用。
