# 工单 09b — 修正 InputSource 的 TIS 用法（真机探针已验过）

我在 Mac 上写了独立探针跑通并验证过，以下三条是事实，按它改 `Sources/CapslockPlusMac/Support/InputSource.swift`（只改这个文件）。

## 1. `kTISPropertyInputSourceNames` 不存在

编译会报 `cannot find 'kTISPropertyInputSourceNames' in scope`。SDK 里没有这个键。

名字直接用**属性本身**：

```swift
stringProperty(source, kTISPropertyLocalizedName as CFString)
```

（`kTISPropertyLocalizedName` 是 `TISGetInputSourceProperty` 直接返回的 CFString，不是字典。）

## 2. 必须按 category + type 过滤，否则会撞上假输入源

真机枚举结果（macOS 27.2）：

```
en=1 sel=1 cat=TISCategoryKeyboardInputSource   type=TISTypeKeyboardLayout     ABC
en=1 sel=1 cat=TISCategoryKeyboardInputSource   type=TISTypeKeyboardInputMode   Pinyin – Simplified
en=1 sel=0 cat=TISCategoryKeyboardInputSource   type=TISTypeKeyboardInputMethodModeEnabled  Chinese, Simplified
en=1 sel=1 cat=TISCategoryPaletteInputSource    type=TISTypeCharacterPalette    Emoji & Symbols
en=1 sel=1 cat=TISCategoryPaletteInputSource    type=TISTypeCharacterPalette    PressAndHold
en=1 sel=1 cat=TISCategoryPaletteInputSource    type=TISTypeCharacterPalette    Dictation
```

`Emoji & Symbols` / `PressAndHold` / `Dictation` 都是 `IsEnabled && IsSelectCapable`，只按这两个条件过滤会把它们算进去；
而且 `TISSelectInputSource` 对它们**返回 0（成功）但当前源根本不变**——轮换会卡在假源上不动。

过滤条件改成：

```swift
category == (kTISCategoryKeyboardInputSource as String)
&& (type == (kTISTypeKeyboardLayout as String) || type == (kTISTypeKeyboardInputMode as String))
&& enabled && selectCapable
```

注意 `kTISCategoryKeyboardInputSource` 比较的是 **category**，`kTISTypeKeyboardLayout` 比较的是 **type**，两者不能混用
（我第一次就混了，结果过滤出 0 个源）。

## 3. 切换成功与否不能看返回值，要回读当前源

`TISSelectInputSource` 返回 0 不代表真的切过去了。切换后 `usleep(300_000)` 再读一次
`TISCopyCurrentKeyboardInputSource`，ID 变了才算成功：

- 变了 → `Log.info("longpress ... -> \(新名字)")`
- 没变 → `Log.warn("longpress ... -> switch rejected")`

## 验收（我跑）

```
swift build -c release --arch arm64 && ./scripts/build.sh && ./dist/CapslockPlusMac.app/Contents/MacOS/CapslockPlusMac --selftest
```
真机：长按 caps 松手，ABC ↔ Pinyin 真切换，日志名字正确。

## 不要做

- 只改 `Support/InputSource.swift`
- 不要联网、不要试构建
