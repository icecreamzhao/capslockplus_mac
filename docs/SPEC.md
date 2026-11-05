# capslock_plus_mac — v0 规格

Capslock+（Windows/AutoHotkey）的 macOS 自用移植版。范围只做三块：**文本编辑、多剪贴板、窗口绑定**。

## 0. 目标与非目标

目标：Caps Lock 按住当修饰键，与字母/数字组合触发文本编辑动作；单按仍切换大小写；
多剪贴板（系统剪贴板 + N 个独立剪贴板）；窗口绑定（caps+数字 激活、caps+alt+数字 绑定）。

非目标（v0 不做）：qbar/启动器、翻译、计算板、窗口透明/置顶、热字串（hotstring）、
按 App 切换键位方案、自动更新、公证分发。配置热重载只做 caps+F5 重读键位文件。

## 1. 技术形态

- Swift Package Manager 可执行 target，无 Xcode 工程（scripts/build.sh 手工组装 .app）
- 纯 AppKit，`LSUIElement=true`（无 Dock 图标），NSStatusItem 菜单栏图标
- 不做 App Sandbox；需要 Accessibility + Input Monitoring 两个 TCC 权限
- 签名固定用 `Apple Development: 1127534615@qq.com (33NUEFMU8B)`（TCC 授权跟签名绑定，不要换）
- Bundle id：`com.littleboy.CapslockPlusMac`（定了就别改，改了权限会重新弹）
- 最低系统 13.0，只编 arm64

## 2. 键盘层（最关键）

macOS 的 Caps Lock 只产生 `flagsChanged`（keyCode 57），且锁定状态在 IOHIDSystem 里。
不装 Karabiner，纯用户态处理，和 Capslox 同路线：

1. `CGEventTapCreate` 先试 `.cgHIDEventTap`，失败退回 `.cgSessionEventTap`；
   mask 包含 `flagsChanged | keyDown | tapDisabledByTimeout | tapDisabledByUserInput`
2. 看到 caps 的 flagsChanged：**吞掉**（return nil），记录按下/松开时刻，启动 300ms 计时
3. caps 按住期间收到 keyDown：查键位表 → 执行动作 → 吞掉，并标记本回合已用过功能
4. 松开 caps 时若 300ms 内且没触发过任何动作 → 执行 caps 单按动作（默认切换大小写）
5. 锁定状态自己管：`IOHIDGetModifierLockState` 读、`IOHIDSetModifierLockState` 写
   （`IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))`）。
   每次 caps 按下和松开都对账一次，防止系统自己把状态翻过去。
6. tap 被系统禁用（timeout/userInput）时在回调里立刻重新启用
7. 自己也发 CGEvent，必须打标记 `CGEventSetIntegerValueField(_, .eventSourceUserData, MAGIC)`
   并在回调里丢弃，否则会自我触发

Secure Input 期间系统会屏蔽 tap，属于预期行为：不报错，只在菜单栏显示状态。

## 3. 默认键位（Capslock+ capsLox 方案简化版）

`caps+键`：

| 键 | 动作 | 键 | 动作 |
|---|---|---|---|
| s | 左移一字符 | h | 选中左侧一词 |
| f | 右移一字符 | l | 选中右侧一字符 |
| e | 上移一行 | i | 上选一行 |
| d | 下移一行 | k | 下选一行 |
| a | 左移一词 | j | 左选一字符 |
| g | 右移一词 | ; | 移到行尾 |
| t | 上移 10 行 | p | 移到行首 |
| b | 下移 10 行 | u | 选到行首 |
| w | 删前一字符 | o | 选到行尾 |
| r | 删后一字符 | y | 上选 10 行 |
| [ | 删到行首 | n | 下选 10 行 |
| / | 删到行尾 | , | 选中当前词 |
| backspace | 删整行 | . | 右选一词 |
| enter | 下方插入空行 | space | Enter |
| x/c/v | 剪切/复制/粘贴 | ` | 无 |
| alt+x/c/v | 剪贴板2 剪切/复制/粘贴 | tab | 无 |
| 1..0 | 激活窗口 1..10 | alt+1..0 | 绑定当前窗口 1..10 |
| f5 | 重载键位配置 | esc | 无 |

caps 单按（松开时判定）= 切换 Caps Lock。

## 4. 动作实现约定（全部走 CGEvent 合成，除了包裹选区）

| 动作 | 实现 |
|---|---|
| moveLeft/Right | Left/Right |
| moveWordLeft/Right | Option+Left/Right |
| moveUp/Down | Up/Down |
| moveLineStart/End | Cmd+Left / Cmd+Right |
| selectX | 同上加 Shift |
| deleteBackward/Forward | Delete(51) / ForwardDelete(117) |
| deleteWordBackward | Option+Delete |
| deleteToLineStart | Shift+Cmd+Left 后 Delete |
| deleteToLineEnd | Shift+Cmd+Right 后 Delete |
| deleteLine | Cmd+Left + Shift+Cmd+Right + Delete + Delete |
| insertLineBelow | Cmd+Right + Return |
| selectCurrentWord / selectWordRight | Option+Shift+Left/Right |
| wrapSelection | AX 读 `kAXSelectedTextAttribute`，加包裹符后写回 `kAXSelectedTextAttribute`，再把光标放到内部 |
| extraClipboard.cut/copy/paste | NSPasteboard(name: "com.littleboy.CapslockPlusMac.extra1")，先 Cmd+C/X 等 changeCount 变化再整体搬运 |
| window.bind(n) | 记录前台 app 的 bundle id + 前台 AX 窗口标题 |
| window.activate(n) | 激活 app，再用 AX 把匹配标题的窗口 raise/置前；找不到就只激活 app |

粘贴到"extra"剪贴板时保留所有类型（`NSPasteboardItem` 全量搬运），文本操作用 `string` 兜底。

## 5. 配置

`~/.config/capslock-plus-mac/keymap.json`，首次启动若不存在则写入默认值。
结构：`{"tap": "toggleCapsLock", "chordMaxMs": 300, "bindings": {"caps+f": "moveRight", "caps+alt+1": "window.bind(1)"}}`。
键名解析：`caps`、`alt`、`shift`、`cmd`、`ctrl` + 主键（字母/数字/符号/backspace/enter/space/tab/esc/f1..f12）。
未知动作只记日志，不崩溃。caps+F5 重载该文件。

## 6. 可观测性（验收靠它）

日志：`~/Library/Logs/CapslockPlusMac.log`，行格式
`2026-11-06T01:00:00Z [I] tap=created location=hid`、`[I] chord caps+f -> moveRight`、
`[I] capsTap -> toggleCaps state=on`、`[W] tapDisabled reason=timeout`。
另有 `--selftest` 参数：解析内置键位表、校验所有动作名有实现，打印 `selftest OK (n bindings)` 后退出 0，
不创建 tap、不请求权限。

## 7. 目录

```
Package.swift
Sources/CapslockPlus/
  main.swift                 入口，--selftest 分发
  AppDelegate.swift          NSApplication 生命周期、状态栏
  Log.swift                  文件日志
  Config.swift               键位表解析 + 默认值 + 重载
  KeyLayer/EventTapEngine.swift    CGEventTap、事件分流、MAGIC 过滤
  KeyLayer/CapsState.swift         按下/松开/300ms/锁定状态对账
  KeyLayer/HIDCapsLock.swift       IOHIDSet/GetModifierLockState 封装
  KeyLayer/Chord.swift             键位组合解析
  Actions/TextActions.swift
  Actions/ClipboardActions.swift
  Actions/WindowActions.swift
  Support/AX.swift                 AX 焦点窗口、选区读写
  Support/KeyPost.swift            带 MAGIC 的 CGEvent 合成
scripts/build.sh              swift build + 组装 .app + codesign
scripts/run.sh                build + 杀掉旧进程 + open
docs/SPEC.md
docs/codex-tasks/*.md
```
