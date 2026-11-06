# 工单 10 — 长按改为到时立即触发（1 秒），且不打断后续组合键

## 目标行为（用户真机反馈后修正）

1. 按住 Caps 满 `longPressMs`（**默认改为 1000ms**）→ **立即**切换输入法，不等松手
2. 切换之后继续按住，**不能反复切换**（一次按住只切一次）
3. 切换之后仍按住时，再按其他键（如 `caps + w`）**照常触发对应动作**
4. 松手时：如果这次按住已经触发过长按，**不再切换大小写**
5. 短按（<`chordMaxMs`=300ms）仍然切大小写；按住期间先按了功能键（不论 300ms 前后）则长按永不触发

## 现状（`Sources/CapslockPlusMac/KeyLayer/CapsState.swift`）

- 长按是**在 keyUp 时**按 elapsed 判定的（`else if elapsed >= longPressMs { performLongPress }`），要改成定时器
- `armWatchdog()` 是 2 秒的卡键保护，会在持续按住时把 `down` 置回 false

## 要改的

只改 `Sources/CapslockPlusMac/KeyLayer/CapsState.swift` 和 `Sources/CapslockPlusMac/Config.swift`。

### 1. `CapsState`

新增内部状态：

```swift
private var longPressFired = false
private var longPressGeneration = 0
```

- `prefixKeyDown()`：**新按下**时（`down == false`）设 `longPressFired = false` 并 `armLongPress()`；
  已经是 down 状态（F18 会自动重复 keyDown）时保持现有早返回，**绝不能重启长按计时器**
- `armLongPress()`：仿 `armWatchdog` 的 generation 写法，
  `DispatchQueue.main.asyncAfter(deadline: .now() + longPressMs/1000)` 里判断
  `generation == 当前 && down && !usedAction && !longPressFired`，满足则：
  `longPressFired = true` → `performLongPress(elapsedMs: longPressMs)` → `armWatchdog()`（续命，保证还能继续吃组合键）
- `markActionUsed()`：除现有 `usedAction = true` 外，`longPressGeneration &+= 1`（取消待触发的长按）
- `prefixKeyUp()`：
  - 先 `longPressGeneration &+= 1`（取消计时器）
  - 若 `longPressFired` → 重置 `longPressFired = false`，日志 `prefix up (longpress, no tap)`，**直接返回**，不要切大小写
  - 否则保持原有逻辑（`elapsed < chordMaxMs && !usedAction` → `performTap()`）
- `forceReset()`：一并清 `longPressFired` 并将 `longPressGeneration &+= 1`
- `armWatchdog()` 的 2 秒改成 **5 秒**：长按后用户可能还按着思考，2 秒会把 `down` 清掉，导致后续
  `caps + w` 失效、keyUp 变成 "prefix up without down"。F18 的 keyUp 是可靠的，5 秒作为兜底足够。

### 2. `Config.swift`

- `defaultKeymap()` 里 `longPressMs: 1000`
- 读盘默认值 `?? 1000`，clamp 仍为 300…3000
- 写盘默认 `"longPressMs": 1000`

## 日志

```
[I] longpress 1000ms -> switchInputSource -> ABC
[I] prefix up (longpress, no tap)
```

## 验收（我跑 + 用户在真机测）

```
swift build -c release --arch arm64 && ./scripts/build.sh && ./dist/CapslockPlusMac.app/Contents/MacOS/CapslockPlusMac --selftest
```

真机：
1. 按住 caps 1 秒不松 → 输入法当场切换（日志出现 longpress 行），继续按住不再重复切
2. 保持按住再按 w → 对应动作照常执行
3. 松开 → 日志 `prefix up (longpress, no tap)`，没有 `prefixTap`
4. 短按 caps → 仍切大小写

## 不要做

- 不要动 EventTapEngine / InputSource / Actions/ 及其他文件
- 不要联网、不要试 `swift build`（本机无工具链）

## 结束

3 行以内：长按计时器怎么防重复触发、keyUp 为什么不再判 elapsed、看门狗为什么必须从 2s 提到 5s。
