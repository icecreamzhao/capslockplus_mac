# 工单 14 — 动作层补齐（参数化 / 编辑动作 / Send Input / 短按可配）

对标 Capslox 缺的动作，一次性补齐。**只改下面列出的文件**。

## 一、新增动作（`Sources/CapslockPlusMac/Config.swift` 的 `enum Action`）

```swift
case deleteWordForward        // 向右删 1 个单词：forwardDelete + option
case deleteToPageStart        // 选中至文档开头再删：cmd+shift+up, backspace
case deleteToPageEnd          // 选中至文档结尾再删：cmd+shift+down, backspace
case deleteAll                // cmd+a, backspace
case hardDeleteLine           // cmd+left, cmd+shift+right, shift+down, backspace（连行尾换行一起删）
case minimizeWindow           // 最小化当前聚焦窗口
case launchApp(String)        // 按 bundle id 启动/激活应用
case sendKeys(String)         // 合成按键序列，见下方语法
case typeText(String)         // 直接输入一段文字（Unicode）
case repeated(Action, Int)    // 参数化重复
```

`name` 属性的返回字符串必须与解析语法一致（`repeated` 返回 `"<base>(<n>)"`）。

## 二、解析语法（`Config.parse`）

在现有 `fixed` 表与 `wrapselection(...)` / `window.bind(n)` 之外增加：

```
deletewordforward
deletetopagestart
deletetopageend
deleteall
harddeleteline
minimizewindow
launchapp(<bundle-id>)        例：launchapp(com.apple.Safari)
send(<keystroke-spec>)        例：send(cmd+shift+t)
type(<text>)                  例：type(hello world)   （允许空格的原文，不要 lowercased！）
<base>(<n>)                   例：moveup(20) / selectdown(5) / deletebackward(3)
```

**重要**：`type(...)` 的内容必须保留原始大小写与空格，不能被 `lowercased()` 破坏。
现有 `parse` 里用的是 `lower`，请为 `type(` 单独走一个用原始 `trimmed` 的分支（前缀比较用 lowercased，取参数用原文）。

`<base>(<n>)` 的 base 只允许这些：`moveleft moveright moveup movedown movewordleft movewordright
selectleft selectright selectup selectdown selectwordleft selectwordright deletebackward deleteforward`。
n 限制 1…100，越界 clamp。解析失败返回 nil（保持现有行为：未知动作打 warning 并绑 none）。

## 三、执行（`Sources/CapslockPlusMac/Actions/TextActions.swift`）

新增 case，键码已有（left=123 right=124 down=125 up=126 backspace=51 forwardDelete=117 enter=36）：

```swift
case .deleteWordForward:   KeyPost.key(117, flags: .maskAlternate)
case .deleteToPageStart:   KeyPost.key(126, flags: [.maskCommand, .maskShift]); KeyPost.key(51)
case .deleteToPageEnd:     KeyPost.key(125, flags: [.maskCommand, .maskShift]); KeyPost.key(51)
case .deleteAll:           KeyPost.key(0, flags: .maskCommand); KeyPost.key(51)      // keycode 0 = A
case .hardDeleteLine:
    KeyPost.key(123, flags: .maskCommand)
    KeyPost.key(124, flags: [.maskCommand, .maskShift])
    KeyPost.key(125, flags: .maskShift)
    KeyPost.key(51)
case .repeated(let base, let n):
    for _ in 0..<n { _ = run(base) }
```

`sendKeys` / `typeText` / `minimizeWindow` / `launchApp` 分别转给下面第 4、5 节实现后返回 true。

## 四、`Sources/CapslockPlusMac/Support/KeyPost.swift`

新增两个方法（保持现有 MAGIC 自触发过滤）：

```swift
static func text(_ s: String)               // 逐段 CGEventKeyboardSetUnicodeString + 空 keycode(0) 事件，unitSize=String.utf16.count
static func keys(_ spec: String) -> Bool     // spec 形如 "cmd+shift+t" 或 "cmd+t, cmd+w"（逗号分隔连续按键）
```

`keys` 语法：
- 用 `,` 分隔多组，每组 `mod+mod+key`
- 修饰词：`cmd` `alt` `ctrl` `shift`
- key 名支持：单字符 a-z / 0-9 / `,` `.` `/` `-` `=` `;` `'` `[` `]` `` ` ``；以及
  `return enter tab space escape left right up down delete backspace pageup pagedown home end f1…f12`
- 需要一张 keycode 映射表（ANSI）。解析不出 key → `Log.warn("send failed spec=…")` 返回 false
- 每组按键之间留 12ms（`usleep(12000)`），抬起修饰键后再发下一组

## 五、`Sources/CapslockPlusMac/Support/AX.swift`

```swift
@discardableResult static func minimizeFocusedWindow() -> Bool
```
取系统聚焦窗口（`kAXFocusedWindowAttribute` on system-wide element），
`AXUIElementSetAttributeValue(win, kAXMinimizedAttribute, kCFBooleanTrue)`；
失败（含全屏窗口）返回 false，由调用方记 `minimize failed`。

## 六、短按 Caps 可配（`CapsState.swift` + `Config.swift`）

- `enum TapAction` 现有的 `toggleCapsLock / escape / none` 保留，但 `Keymap.tap` 改成 `tapAction: Action`
- `Config` 读盘：`tap` 字段先用 `Config.parse()` 解析成任意 `Action`；
  解析不出来时退回 `.toggleCapsLock`，并 `Log.warn("tap parse failed …")`
- `CapsState.performTap()` 改为执行该 `Action`：
  - `.toggleCapsLock` → 走原来的 `IOHIDSetModifierLockState` 切大小写（不要改成发按键）
  - 其余 → 交给 `ActionRunner.run(action)`（`launchApp` / `minimizeWindow` / `type(...)` 都可能出现在这里）
- 日志：`prefix tap -> <actionName>`

这样 `"tap": "launchapp(com.apple.Safari)"`、`"tap": "minimizewindow"` 都能用。

## 七、日志

```
[I] action=send spec=cmd+shift+t ok=1
[W] send failed spec=cmd+zzz
[W] minimize failed
[I] action=launchApp bundle=com.apple.Safari
[I] prefix tap -> launchapp(com.apple.Safari)
```

## 八、验收（我跑）

```
swift build -c release --arch arm64 && ./scripts/build.sh && ./dist/CapslockPlusMac.app/Contents/MacOS/CapslockPlusMac --selftest
```

`--selftest` 要覆盖新语法能解析（`moveup(20)`、`selectdown(5)`、`wrapselection(paren)`、
`launchapp(com.apple.Safari)`、`send(cmd+shift+t)`、`type(Hello World)`），解析不出要打印失败项。

## 不要做

- 不要改 KeyLayer/EventTapEngine、WindowStore、LoginItem、InputSource、main.swift
- 不要联网、不要试 `swift build`（本机无工具链）
- `type()` 不要 lowercased

## 结束

5 行以内：新增了哪些 case、`type(` 怎么保护原始大小写、`repeated` 的 clamp、tap 怎么向后兼容、sendKeys 的 keycode 表覆盖哪些键。
