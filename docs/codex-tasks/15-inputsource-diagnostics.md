# 工单 15 — 输入法切换健壮性 + 现场诊断（偶发"切回中文仍打英文"）

## 现象（用户真机，一天内出现 1–2 次，暂不可稳定复现）

```
1. 短按 caps            （默认 tap = toggleCapsLock，大写锁定被打开）
2. 长按 -> 切到英文输入法
3. 长按 -> 切回中文输入法
4. 此时输入仍是英文
5. 再短按一次 caps，仍然打不出中文
```

## 我（Hermes）已定位的两个问题

1. **`InputSource.switchNext()` 在主线程 `usleep(300_000)`**。而 CGEventTap 就跑在主 run loop 上
   （`EventTapEngine` 用 `CFRunLoopAddSource(CFRunLoopGetMain(), ...)`），等于每次切输入法把事件管
   道堵 300ms，macOS 会因此丢事件/延迟派发，甚至触发 tap 超时禁用。**必须先去掉这个阻塞**。
2. **完全没有现场证据**：不知道切换前后 macOS 认为当前源是什么、切换是否真被接受、当时大写锁定
   状态如何。Apple 的拼音输入法在 **Caps Lock 打开时会强制输出英文大写**，所以第 1 步打开的大写锁定
   很可能就是"打出来是英文"的直接原因——但现有日志无法证实或排除，必须补日志。

## 改法（只改这三个文件）

### 1. `Sources/CapslockPlusMac/Support/InputSource.swift`

- `switchNext()` 改成**不阻塞**：

```swift
static func switchNext(completion: ((String?) -> Void)? = nil)
```

流程（全部用 `DispatchQueue.main.asyncAfter`，不要 `usleep`/`Thread.sleep`）：

```
let sources = selectableSources()
guard sources.count > 1 else { log("inputsource single …"); completion(nil); return }
let from = currentID()
let target = sources[(index(from) + 1) % sources.count]
log("inputsource switch from=<from> to=<id(target)> caps=<capsState> status=<noErr?>")

TISSelectInputSource(target)
150ms 后校验 currentID == id(target)
   命中 -> log("inputsource switched to=<id> caps=<caps> verify=ok"); completion(name)
   未命中 -> 再 TISSelectInputSource(target)，120ms 后二次校验
            命中 -> log("… verify=retry-ok"); completion(name)
            仍未命中 -> log("… verify=fail current=<id>"); completion(nil)
```

- 新增 `static func currentSnapshot() -> String`，返回形如
  `"<id> (<name>) caps=1"`，供菜单和日志复用
- 新增 `static func startObserving()`：注册
  `CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), …,
   kTISNotifySelectedKeyboardInputSourceChanged)`，每次系统输入源真的变化时写日志
  `inputsource changed -> <snapshot>`；`stopObserving()` 一并实现，App 退出时调用

### 2. `Sources/CapslockPlusMac/KeyLayer/CapsState.swift`

`performLongPress` 改成异步收结果：

```swift
InputSource.switchNext { name in
    if let name { Log.info("longpress \(ms)ms -> switchInputSource -> \(name)") }
    else { Log.warn("longpress \(ms)ms -> switchInputSource failed") }
}
```

不要把 `switchNext` 的返回值当同步结果用。

### 3. `Sources/CapslockPlusMac/AppDelegate.swift`

- 菜单里加两条**只读**诊断项（`menuWillOpen` 里刷新）：
  - `输入法：<当前源名称>`（取 `InputSource.currentSnapshot()` 里的 name 部分）
  - `大写锁定：开 / 关`（用 `HIDCapsLock` 现有的读锁能力；若它只有 `reconcile`，就新增一个
    `func isLocked() -> Bool?`，复用内部 `IOHIDGetModifierLockState`，不要改 ABI）
- 启动时调 `InputSource.startObserving()`，`applicationWillTerminate` 里 `stopObserving()`

## 日志样例

```
[I] inputsource switch from=com.apple.keylayout.ABC to=com.apple.inputmethod.SCIM.ITABC caps=1 status=0
[I] inputsource switched to=com.apple.inputmethod.SCIM.ITABC caps=1 verify=ok
[W] inputsource switch verify=fail current=com.apple.keylayout.ABC
[I] inputsource changed -> com.apple.keylayout.ABC (ABC) caps=0
```

## 验收（我跑 + 用户观察）

```
swift build -c release --arch arm64 && ./scripts/build.sh && ./dist/CapslockPlusMac.app/Contents/MacOS/CapslockPlusMac --selftest
```
- 日志必须能看到 `inputsource switch from=… to=… caps=…`
- 主线程不得有 >10ms 的阻塞（切输入法期间按键不卡顿）
- 菜单能看到「输入法：…」「大写锁定：开/关」

## 不要做

- 不要动 EventTapEngine / WindowStore / LoginItem / main.swift / 动作层（Config、TextActions、KeyPost）
- 不要联网、不要试 `swift build`（本机无工具链）
- 不要把 `switchNext` 改成同步阻塞的任何变体

## 结束

4 行以内：阻塞怎么搬走的、二次校验怎么做、观察器注册的是哪个通知、菜单两个诊断项的数据来源。
