# 工单 09 — 长按 Caps 切换输入法

## 目标行为

| 动作 | 时间 | 结果 |
|---|---|---|
| 单按（< `chordMaxMs`，默认 300ms）且未触发组合键 | ~0-299ms | 切换大小写锁定（现有行为，不动） |
| 长按（≥ `longPressMs`，默认 500ms）且未触发组合键 | 500ms+ | **切换输入法** |
| 按住期间按了其他键 | 任意 | 组合键动作（现有行为，优先级最高） |

判定在 **松开时** 做（和现在 `prefixKeyUp` 一致），不要用定时器提前触发——用户按住 caps 犹豫一下再松开，不应该被误判成切换。

## 实现要求

### 1. 新增 `Sources/CapslockPlusMac/Support/InputSource.swift`

用 Text Input Sources API（`import Carbon`）：

```swift
enum InputSource {
    static func selectableSources() -> [TISInputSource]   // IsEnabled && IsSelectCapable
    static func currentID() -> String?                    // TISCopyCurrentKeyboardInputSource + kTISPropertyInputSourceID
    static func currentName() -> String?                  // kTISPropertyInputSourceNames -> kTISPropertyLocalizedName
    @discardableResult
    static func switchNext() -> String?                   // 切到列表里的下一个（末尾回绕），成功返回新输入源名字
}
```

要点：
- `TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource]`
- 过滤：`kTISPropertyInputSourceIsEnabled == true` **且** `kTISPropertyInputSourceIsSelectCapable == true`
- 取值统一 `TISGetInputSourceProperty(src, kTISPropertyInputSourceID as CFString)?.takeUnretainedValue() as? String`
- 名字用 `kTISPropertyInputSourceNames` → NSDictionary → `kTISPropertyLocalizedName`
- 当前源不在列表里（取不到 ID）时降级为列表第一个
- 只有一个可选源时直接返回 nil，日志 `inputsource single = 名字`，不要做无意义切换
- 全部 API 失败时返回 nil，**不要崩**

### 2. `Config.swift`

- `Keymap` 增加两个字段：`longPressMs: Int`（默认 500，读取时 clamp 300…3000）、`longPress: String`（默认 `"switchInputSource"`）
- `defaultKeymap()` 与写盘、读盘的 JSON 都要带上这两个键
- `Action` 枚举增加 `case switchInputSource`，`name` 返回 `"switchInputSource"`，字符串解析里加对应分支
- 注意 `Keymap` 是 struct，初始化点有三处（defaultKeymap / 读盘 / 可能还有 reload），全部要补参数，别漏

### 3. `CapsState.swift`

`prefixKeyUp()` 里判定顺序改为：

```swift
if usedAction { return }                       // 组合键已用过，什么都不做
if elapsed < chordMaxMs { performTap() }       // 单按
else if elapsed >= longPressMs { performLongPress() }   // 长按
// 中间地带：什么都不做
```

`performLongPress()`：
- `Config.shared.keymap.longPress` 为 `"switchInputSource"` → 调 `InputSource.switchNext()`，
  日志 `longpress 612ms -> switchInputSource -> 拼音`（失败记 `longpress ... -> failed`）
- 其他值 / `"none"` → 什么都不做

### 4. `EventTapEngine.swift` 的 `ActionRunner`

`switch action` 里加 `case .switchInputSource: InputSource.switchNext()`，这样将来也能绑到组合键上。
注意 `TextActions.run(action)` 在前面会先跑，确保它对新 case 返回 false（它现在是 switch + default，确认不会误吞）。

## 日志

```
[I] longpress 612ms -> switchInputSource -> 拼音
[W] longpress 612ms -> switchInputSource failed
```

## 验收（我这边跑）

```
swift build -c release --arch arm64
./scripts/build.sh
./dist/CapslockPlusMac.app/Contents/MacOS/CapslockPlusMac --selftest
```
真机：长按 caps 松手 → 输入法在已启用的源之间轮换；按 caps+f 之类组合键不受影响；短按仍切大小写。

## 不要做

- 不要动 `KeyPost` / `AX` / `WindowActions` / `ClipboardActions` / `EventTapEngine` 的事件分发逻辑
- 不要用 `CGEvent` 合成 Ctrl+Space（那条路要求用户开系统快捷键，正是我们要避开的）
- 不要引入依赖、不要联网、不要试 `swift build`（本机无工具链）

## 结束

4 行以内：枚举/切换用了哪几个 TIS 符号、只有一个可选源时怎么处理、`longPressMs` 中间地带为什么留空。
