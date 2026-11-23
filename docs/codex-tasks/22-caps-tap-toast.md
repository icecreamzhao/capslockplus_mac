# 工单 22 — 单点 Caps 切换大小写时弹中央 HUD（显示当前输入法 + CAPS 状态）

## 需求

单点 CapsLock 切换大小写时，像长按切输入法那样在**屏幕正中**弹一个 HUD 提示。
HUD 主行显示**当前输入法名字**，副行显示刚刚切到的状态 `CAPS 开` / `CAPS 关`。

现在的行为：`CapsState.performTap()` 只调 `HIDCapsLock` 切换锁定状态，界面无任何反馈；
长按切输入法那条路（`performLongPress`）会调 `StatusToast.shared.show(name, detail: "CAPS 开")`。

## 要做的事

### 1. `Config.swift` 增加 `capsToastMs`

- `private(set) var capsToastMs: Int = 700`
- 解析 JSON 键 `capsToastMs`，范围夹到 `0...3000`（写法照抄 `imeToastMs`）
- `configLoaded` 那行日志里带上 `capsToastMs=\(capsToastMs)`
- `0` 表示不弹

### 2. `CapsState.performTap()` 加提示

```swift
if action == .toggleCapsLock {
    let on = !HIDCapsLock.shared.isLocked
    _ = CapsState.setLocked(on, reason: "tap")
    let ime = InputSource.currentName() ?? InputSource.currentSnapshot()
    // 主行是输入法，副行是刚切到的状态
    StatusToast.shared.show(ime, detail: on ? "CAPS 开" : "CAPS 关",
                            ms: Config.shared.capsToastMs)
    return
}
```

要求：
- 输入法名字用 `InputSource.currentName()`，取不到时退回 `currentSnapshot()`
  （**不要**写死或用"打算切到谁"，要的是点击这一刻的真实值）
- 空字符串或 `ms == 0` 时 `StatusToast.show` 自己会跳过，不要在外面另加判断
- 这条路径已在主 runloop（`EventTapEngine` 用 `CFRunLoopGetMain()`），**不要**再包
  `DispatchQueue.main.async`，否则连点时先后顺序会乱

### 3. 自检

`DebugCLI.swift` 里已有 `--toast-test` 和 `StatusToast.frame` 的可见性断言。
新增一条断言：`capsToastMs` 的 JSON 解析与夹取（0 / 700 / 9999 → 0 / 700 / 3000），
放在现有配置自检里。

### 4. 文档

`README.md` 的配置说明里补 `capsToastMs`，并说明单点 Caps 会弹 HUD
（主行输入法名、副行 CAPS 状态）。

## 约束

- 只改 `Config.swift`、`CapsState.swift`、`DebugCLI.swift`、`README.md`
- 不改长按切输入法那条路径的行为
- 不新增依赖
- 纯 AppKit，保持现有代码风格
- `swift build` 必须过（我在 Mac 上编）
