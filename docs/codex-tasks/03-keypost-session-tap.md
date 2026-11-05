# 工单 03 — 合成按键改到 session 层，修 caps+alt+c 复制不到剪贴板

## 现象（真机日志）

```
[I] chord prefix+alt+c -> extraClipboard.copy
[W] clipboard capture timeout action=copy      ← Cmd+C 发出后 300ms 内 changeCount 没变
[I] chord prefix+alt+v -> extraClipboard.paste
[W] clipboard extra empty
```

系统剪贴板的 caps+c / caps+v 用户反馈也不可靠。窗口绑定正常，文本移动正常。

## 根因（已定位，不要重新调研）

`Support/KeyPost.swift` 用

```swift
CGEventSource(stateID: .hidSystemState)
...
event.post(tap: .cghidEventTap)
```

投递到 HID 层。CGEventPost 在 kCGHIDEventTap 这一层会把**当前物理键盘的修饰键状态**合进事件：
触发 chord 时用户正物理按着 Option，于是我们发出的 `Cmd+C` 到达目标 app 时变成 `Cmd+Option+C`，
app 不当它是复制，pasteboard 的 changeCount 自然不变。

## 改法

只改 `Sources/CapslockPlusMac/Support/KeyPost.swift`：

1. 事件源改 `CGEventSource(stateID: .combinedSessionState)`。
2. 投递位置改 `event.post(tap: .cgSessionEventTap)`（session 层不再用物理状态覆盖我们设的 flags）。
3. 保留 `kCGEventSourceUserData` 的 MAGIC 标记（session 层同样会经过我们挂在 HID 层的 tap，
   标记必须留着，否则自触发）。
4. 保留 `event.flags = flags` 显式设置，不动签名。

## 顺带一个小改动（同文件，别扩散）

`ClipboardActions.swift` 里 `captureToExtra` 的等待上限从 `0.3` 秒改成 `0.6` 秒
（浏览器/Electron 复制偶尔超过 300ms）。只改这一个数字。

## 验收

```
swift build -c release --arch arm64
./scripts/build.sh
./dist/CapslockPlusMac.app/Contents/MacOS/CapslockPlusMac --selftest
```
外加真机：caps+alt+c 后日志必须出现 `clipboard captured n=1 action=copy`，不能再有 capture timeout。

## 不要做

- 不要改其他文件（Actions/TextActions、WindowActions、CapsState、EventTapEngine 都不要碰）
- 不要引入依赖、不要联网、不要试 `swift build`（本机无工具链）

## 结束

2 行以内：改了哪两处、为什么 session 层能避免修饰键污染。
