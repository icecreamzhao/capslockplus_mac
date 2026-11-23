# 工单 23 — 快速连按 Caps 时提示框不显示

## 现象

快速连续单点 Caps 切换大小写时，大写状态确实变了，但中央 HUD 有时候完全不出现。

## 根因（已定位，不需要重新调查）

`StatusToast` 复用同一个 NSPanel，两个缺陷叠加：

1. `dismiss()` 用 `NSAnimationContext` 做 180ms 淡出，`completionHandler` 里**无条件**
   `panel.orderOut(nil)`。若这 180ms 期间来了新的 `show()`，新 toast 刚 `orderFrontRegardless`
   并淡入，旧动画的 completion 紧接着把 panel 关掉 —— 用户看到的就是"没出现"。
   `hideWork?.cancel()` 只能取消未执行的延迟 dismiss，管不了已经在跑的淡出动画。
2. `show()` 里无条件 `panel.alphaValue = 0`。panel 已经可见（淡出中）时也会被清零，
   于是有一次可见的闪烁/闪烁后消失。

## 要改的（只改 UI/StatusToast.swift，必要时加 DebugCLI 自检）

### 1. 用 generation 让过期的淡出回调失效

```swift
private var generation = 0
```

- `show()` 开头 `generation &+= 1`（在 `hideWork?.cancel()` 之前或之后都行，但要在真正
  显示之前），并捕获 `let gen = generation` 不需要——show 只用来自增
- `show()` 里把 `panel.alphaValue = 0` 改成 **仅在 `!panel.isVisible` 时**设为 0，
  可见时保持当前 alpha 直接淡入到 1
- `dismiss()` 开头 `generation &+= 1`，捕获 `let gen = generation`，在 completionHandler 里
  ```swift
  guard self?.generation == gen else { return }
  panel.orderOut(nil)
  ```
  注意 `panel` 用捕获的局部常量，不要强引用 self 造成泄漏

### 2. 回归自检 `--toast-rapid-test`

`DebugCLI.swift` 加一个只做验证的命令（不需要人工看屏幕）：

- `StatusToast` 增加内部只读属性 `var debugIsVisible: Bool { panel?.isVisible ?? false }` 和
  `func debugReset()`（把 panel 关掉、generation 归零，供自检重复跑）
- 流程：`show("A", detail: nil, ms: 300)` → 350ms 后 `show("B", detail: "CAPS 开", ms: 800)`
  → 再 200ms 后（此刻旧淡出回调若未失效则已把 panel 关掉）读 `debugIsVisible`
- 断言为 true 打印 `toast-rapid-test ok visible=true`，为 false 打印
  `toast-rapid-test FAIL visible=false` 并以非 0 退出码结束
- 用 `CFRunLoopRun` / `RunLoop.main.run(until:)` 驱动，别用 signal 阻塞

### 3. 保持

- 现有 `--toast-test`、`StatusToast.frame` 的可见性断言行为不变
- 主线程调用约定不变（`CapsState.performTap` 仍在主 runloop，不加 async）
- 不新增依赖

## 验收（我在 Mac 上跑）

```
dist/CapslockPlusMac.app/Contents/MacOS/CapslockPlusMac --toast-rapid-test
# 期望：toast-rapid-test ok visible=true
```

然后我用真实按键节奏（0.3~0.7 秒一次）连点验证日志里 `toast show` 连续出现、且
`toast dismiss` 不在最后一次 show 之后立刻跟 orderOut。
