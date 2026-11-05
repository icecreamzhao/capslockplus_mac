# 工单 02 — 把前缀键从物理 Caps Lock 换成 F18

## 背景（不要重新调研）

上一轮的键层能跑，chord 分发正常（日志里 57 条命中、9 次按下/9 次松开均衡），但物理 Caps Lock
的路线有结构性问题：我们吞掉 caps 的 `flagsChanged` 再用 IOHID 改锁定状态，WindowServer 的修饰键
状态会和 app 失同步，用户体感是"一直按着 caps，打不了字"。

新方案（macOS 上的标准做法）：

1. 用 `hidutil` 在 HID 层把 **Caps Lock 重映射成 F18**。物理 caps 从此不再产生锁定状态，
   系统里它就是一个普通键 F18（虚拟键码 79），有正常的 keyDown/keyUp。
2. app 监听 F18：**吞掉** F18 的 keyDown/keyUp，自己记按下/松开时刻。
3. F18 按住期间收到其他键 → 走 chord（现有逻辑不变）。
4. F18 单按（<300ms 且没触发过 chord）→ 用已验证的 `IOHIDSetModifierLockState` 真正切换 Caps Lock
   （这就是"单按切大小写"）。
5. 退出时把重映射撤掉，别把用户的键盘留在 F18 状态。

## 已验证事实（照抄，别改）

- F18 的 CGKeyCode = **79**。
- `hidutil` 重映射（不需要 root）：
  ```
  hidutil property --set '{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x70000006D}]}'
  ```
  `0x700000039` = Caps Lock，`0x70000006D` = F18。撤销：`hidutil property --set '{"UserKeyMapping":[]}'`
- 读回校验：`hidutil property --get "UserKeyMapping"`，输出里应出现 `"HIDKeyboardModifierMappingSrc" = 0x700000039`。
- IOHID 签名（已在真机验证可用）：
  ```swift
  @_silgen_name("IOHIDGetModifierLockState")
  func IOHIDGetModifierLockState(_ h: io_connect_t, _ s: Int32, _ st: UnsafeMutablePointer<Bool>) -> kern_return_t
  @_silgen_name("IOHIDSetModifierLockState")
  func IOHIDSetModifierLockState(_ h: io_connect_t, _ s: Int32, _ st: Bool) -> kern_return_t
  ```
  handle 用 `IOServiceOpen(service, mach_task_self_, 1, &conn)` 得到，用完 `IOServiceClose`。
  `HIDCapsLock.swift` 已经是这个样子了，**不要改它**。
- 本机没有 Swift 工具链，不要执行 `swift build`；不要联网。

## 改动清单（只动这四个文件 + 新增一个脚本）

### 1. `Sources/CapslockPlusMac/KeyLayer/CapsState.swift`（重写这个文件）

改成前缀键状态机，类名可以保留 `CapsState`：

```swift
final class CapsState {
    func prefixKeyDown()      // 记录 pressTime，usedAction = false，down = true，日志 "prefix down"
    func prefixKeyUp()        // down = false；若 <chordMaxMs 且 !usedAction → performTap()
    func markActionUsed()     // 现有语义
    var isDown: Bool
}
```
要求：
- 不再有 `capsFlagsChanged()`、不再有 `suppressUntil`、不再在按下/松开时调 reconcile。
- `performTap()`：`toggleCapsLock` → 读当前锁定状态、取反、写回，日志
  `prefixTap -> toggleCaps state=on|off`；`escape` → `KeyPost.key(53)`；`none` → 不做事。
- **失步保护**：`prefixKeyUp` 时如果 `down` 已经是 false，只记 `Log.warn("prefix up without down")`，不要切换状态。
  另外加一个 2 秒看门狗：`prefixKeyDown` 后若 2s 内没有任何事件且仍为 down，强制把 down 置 false 并
  记 `Log.warn("prefix watchdog reset")`。用 `DispatchQueue.main.asyncAfter` 实现，注意代际计数避免误触发。

### 2. `Sources/CapslockPlusMac/KeyLayer/EventTapEngine.swift`

- mask 里去掉 `.flagsChanged`（不再需要），保留 `keyDown | keyUp | tapDisabledByTimeout | tapDisabledByUserInput`。
- 新增 `.keyUp` 分支：keyCode == 79 → `caps.prefixKeyUp()`，返回 nil（吞掉）。
- `.keyDown` 分支最先判断 keyCode == 79：`caps.prefixKeyDown()`，返回 nil（吞掉，**不要**当作 chord）。
- 其余 chord 逻辑保持不变（F18 按住时的其他键）。
- 保留 MAGIC 过滤和 tap 重新启用逻辑。

### 3. `Sources/CapslockPlusMac/Support/KeyRemap.swift`（新增）

```swift
enum KeyRemap {
    static func apply() -> Bool     // 跑上面那条 hidutil 命令，成功返回 true 并 Log.info("keyremap on")
    static func remove()            // 撤销，Log.info("keyremap off")
    static func isApplied() -> Bool // 读回校验
}
```
用 `Process` 调 `/usr/bin/hidutil`，参数用数组传，不要拼 shell 字符串。

### 4. `Sources/CapslockPlusMac/AppDelegate.swift`

- `applicationDidFinishLaunching`：先 `KeyRemap.apply()`，失败则 `Log.error("keyremap failed")` 并弹一次提示
  （说明需要手动执行 scripts/keyremap.sh）；然后再建 tap。
- `applicationWillTerminate`：`KeyRemap.remove()`。
- 状态栏菜单加一项「重映射 Caps→F18：开/关」，点击切换并显示当前状态（用 `KeyRemap.isApplied()`）。

### 5. `scripts/keyremap.sh`（新增，我会自己用）

`./scripts/keyremap.sh on|off|status` 三个子命令，直接包 `hidutil`。

## 日志要求（验收靠它）

`~/Library/Logs/CapslockPlusMac.log` 里必须能看到：
```
[I] keyremap on
[I] tap=created location=hid
[I] prefix down
[I] chord prefix+f -> moveRight
[I] prefix up
[I] prefixTap -> toggleCaps state=on
```

## 验收（我在 Mac 上跑）

```
swift build -c release --arch arm64
./scripts/build.sh
./dist/CapslockPlusMac.app/Contents/MacOS/CapslockPlusMac --selftest    # selftest OK，exit 0
```

## 不要做

- 不要改 `HIDCapsLock.swift`、`Config.swift` 的键位表内容、`resources/`、`build.sh`
- 不要动 Actions/ 下三个文件（TextActions/ClipboardActions/WindowActions）
- 不要引入依赖、不要联网、不要建 Xcode 工程

## 结束

4 行以内：改了哪些文件、F18 的 keyUp 有没有可能丢、看门狗怎么避免误触发。
