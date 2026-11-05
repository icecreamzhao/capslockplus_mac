# 工单 01 — SwiftPM 骨架 + Caps 键层 + 三块功能

先读 `docs/SPEC.md`，它是本工单的规格来源。本工单只写代码，不设计。

## 目标

在仓库根目录产出一个可 `swift build` 通过、可签名的 macOS 菜单栏 app，实现：
Caps Lock 按住当修饰键 + 单按切大小写、文本编辑动作、多剪贴板、窗口绑定。

## 非目标

不做 qbar / 翻译 / 计算板 / 窗口透明置顶 / hotstring / 按 App 切方案 / 自动更新；
不写测试框架、不写 README、不改 `docs/`、不改 `resources/`、不改 `scripts/`。

## 已核实事实（不要重新调研、不要改）

- 构建机：macOS 27.2 arm64，Xcode 26.1.1，Swift 6.2.1。
- `Package.swift` 必须用 `// swift-tools-version:5.9`（5 语言模式）。**不要用 6.0 工具链版本**，
  否则全局可变状态和 C 回调会撞 Swift 6 严格并发检查，本机无法通过。
- 只依赖系统框架：AppKit / ApplicationServices / IOKit / CoreGraphics。不得新增任何第三方依赖。
- `resources/Info.plist` 与 `scripts/build.sh`、`scripts/run.sh` 已存在，bundle id 为
  `com.littleboy.CapslockPlusMac`，构建脚本会自己组装 .app 并签名。你不要碰它们。
- 可执行 target 名必须是 `CapslockPlusMac`（build.sh 里写死了这个文件名）。
- 私有两把 IOHID 函数，用 `@_silgen_name` 声明，不要引头文件：
  ```swift
  @_silgen_name("IOHIDGetModifierLockState")
  func IOHIDGetModifierLockState(_ handle: io_service_t, _ selector: Int32) -> Bool
  @_silgen_name("IOHIDSetModifierLockState")
  func IOHIDSetModifierLockState(_ handle: io_service_t, _ selector: Int32, _ state: Bool) -> IOReturn
  ```
  caps 锁定状态 selector 常量 `let kIOHIDCapsLockStateSelector: Int32 = 1`，
  服务用 `IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))` 拿，
  拿到后 `IOObjectRelease` 之前一直复用同一个 handle（可缓存，但每次调用后别释放）。
- 虚拟键码（CGKeyCode）：a=0 s=1 d=2 f=3 h=4 g=5 z=6 x=7 c=8 v=9 b=11 q=12 w=13 e=14 r=15
  y=16 t=17 1=18 2=19 3=20 4=21 6=22 5=23 ==24 9=25 7=26 -=27 8=28 0=29 ]=30 o=31 u=32
  [=33 i=34 p=35 Return=36 l=37 j=38 '=39 ;=40 \=41 `=42 ,=43 /=44 n=45 m=46 .=47 Tab=48
  Space=49 Delete(退格)=51 Escape=53 Cmd=55 Shift=56 CapsLock=57 Option=58 Control=59
  RightOption=61 F5=96 Home=115 PageUp=116 ForwardDelete=117 End=119 PageDown=121
  Left=123 Right=124 Down=125 Up=126
- 修饰位：`CGEventFlags.maskShift / .maskControl / .maskAlternate / .maskCommand / .maskSecondaryFn`。
- CGEventTap 回调必须是 C 函数指针：用 `@convention(c)` 的顶层函数 + `Unmanaged.passUnretained(self).toOpaque()`
  作为 `userInfo`，在回调里 `Unmanaged<T>.fromOpaque(...).takeUnretainedValue()` 取回实例。
  禁止在回调里捕获上下文。tap 建好后 `CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)`。
- `.cgHIDEventTap` 有可能创建返回 nil（权限/根权限差异），必须回退 `.cgSessionEventTap`，
  两次都失败则写日志并弹一次提示，引导去「系统设置 > 隐私与安全性 > 辅助功能 / 输入监控」。
- TCC：`AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)`
  在启动时调一次即可（会弹授权框）。不要自己写 TCC.db。
- 打包的 app 无 Info.plist 里的 storyboard，入口必须自己 `NSApplication.shared` +
  `app.setActivationPolicy(.accessory)` + delegate + `app.run()`，不要用 `@main` + SwiftUI。

## 交付物（路径精确，少一个都算未完成）

```
Package.swift
Sources/CapslockPlusMac/main.swift
Sources/CapslockPlusMac/AppDelegate.swift
Sources/CapslockPlusMac/Log.swift
Sources/CapslockPlusMac/Config.swift
Sources/CapslockPlusMac/KeyLayer/EventTapEngine.swift
Sources/CapslockPlusMac/KeyLayer/CapsState.swift
Sources/CapslockPlusMac/KeyLayer/HIDCapsLock.swift
Sources/CapslockPlusMac/KeyLayer/Chord.swift
Sources/CapslockPlusMac/Actions/TextActions.swift
Sources/CapslockPlusMac/Actions/ClipboardActions.swift
Sources/CapslockPlusMac/Actions/WindowActions.swift
Sources/CapslockPlusMac/Support/AX.swift
Sources/CapslockPlusMac/Support/KeyPost.swift
```

## 行为要求

1. `main.swift`：`--selftest` 时执行自检并 `exit(0/1)`，不创建 tap、不请求权限；
   否则正常启动。自检内容：解析默认键位表、逐个动作名查实现表、打印 `selftest OK (N bindings)`。
2. `Config.swift`：默认键位表写死在代码里（见 SPEC 第 3 节），首次启动把 JSON 写到
   `~/.config/capslock-plus-mac/keymap.json`。结构 `{"tap":"toggleCapsLock","chordMaxMs":300,"bindings":{...}}`。
   键位字符串形如 `caps+f`、`caps+alt+1`、`caps+shift+v`；解析要容忍大小写。`reload()` 重读文件，失败保留旧表并记日志。
3. `EventTapEngine`：mask = `flagsChanged | keyDown | tapDisabledByTimeout | tapDisabledByUserInput`；
   回调返回值：被处理的 keyDown / caps 的 flagsChanged 返回 `nil`（吞掉），其余 `return Unmanaged.passUnretained(event)`。
   所有自带 MAGIC(`0x4C504D`，写入 `kCGEventSourceUserData` 字段) 的事件直接放行不处理。
   tap 被禁用在回调里立即 `CGEvent.tapEnable(tap:true)` 并记日志。
4. `CapsState`：caps 按下记时间戳；期间任何键走 chord；松开时若 `< chordMaxMs` 且本回合未执行过动作 →
   执行 tap 动作（`toggleCapsLock` / `escape` / `none`）。每次 caps 按下和松开都调
   `HIDCapsLock.reconcile(desired:)` 把锁定状态对齐到本地意图，防止系统自己翻转。
5. 文本动作按下表实现（合成事件必须带 MAGIC 标记）：
   moveLeft/Right=Left/Right；moveWordLeft/Right=Option+Left/Right；moveUp/Down=Up/Down；
   moveLineStart/End=Cmd+Left/Right；moveUp10/Down10=循环 10 次；
   select* 为对应移动加 Shift；selectLineStart/End 同 lineStart/End 加 Shift；
   deleteBackward=51；deleteForward=117；deleteWordBackward=Option+51；
   deleteToLineStart=Shift+Cmd+Left 再 51；deleteToLineEnd=Shift+Cmd+Right 再 51；
   deleteLine=Cmd+Left, Shift+Cmd+Right, 51, 51；insertLineBelow=Cmd+Right, Return；
   selectCurrentWord=Option+Shift+Left；selectWordRight=Option+Shift+Right；
   wrapSelection(kind) 走 AX（见 6），失败记日志不崩。
6. `AX.swift`：系统级 element → `kAXFocusedApplicationAttribute` → `kAXFocusedWindowAttribute` /
   `kAXFocusedUIElementAttribute`。选区读写用 `kAXSelectedTextAttribute`；写入失败时回退
   「Cmd+C → 读剪贴板 → 改文本 → 写回剪贴板 → Cmd+V」。窗口绑定记 `bundleIdentifier` + 窗口标题，
   激活时 `NSRunningApplication(processIdentifier:).activate(options:[.activateAllWindows])`，
   再用 AX 找标题匹配的窗口并 `kAXRaiseAction`。
7. `ClipboardActions`：额外剪贴板用 `NSPasteboard(name: NSPasteboard.Name("com.littleboy.CapslockPlusMac.extra1"))`。
   copy=发 Cmd+C 后轮询 `NSPasteboard.general.changeCount`（最多 300ms）再整包搬运所有 `NSPasteboardItem`
   的每个 type；paste=把 extra 的内容整包写回 general 再发 Cmd+V；pastePlain 只写 `public.utf8-plain-text`。
8. 状态栏：`NSStatusItem` 用一个 SF Symbol（`capsule.portrait`，取不到就 `NSImage(systemSymbolName:"command")`）
   + 菜单：`重载键位 (〉F5)`、`打开键位配置`、`打开日志`、`辅助功能权限状态`（只读显示）、`退出`。
9. 日志：`~/Library/Logs/CapslockPlusMac.log`，追加写，ISO8601 时间戳 + `[I]/[W]/[E]`。
   至少这些行：`tap=created location=hid|session`、`chord caps+f -> moveRight`、
   `capsTap -> toggleCaps state=on|off`、`tapDisabled reason=timeout`、`configLoaded n=<N>`、
   `axDenied`、`wrapSelection failed`。

## 验收命令（我会在 Mac 上跑，你必须让它能过）

```
swift build -c release --arch arm64
./scripts/build.sh
./dist/CapslockPlusMac.app/Contents/MacOS/CapslockPlusMac --selftest   # 必须打印 selftest OK 且退出码 0
```

## 不要做

- 不要新增第三方依赖、不要建 Xcode 工程、不要改 resources/ 和 scripts/
- 不要写 XCTest、不要写 README、不要写注释大段解释设计
- 不要在代码里用 `try!` / `fatalError` 处理可恢复错误（除非启动期必需）
- 不要联网、不要执行 `swift build`（本机没有 Swift 工具链，跑了也是浪费时间）

## 结束时

6 行以内总结：改了哪些文件、哪些行为你没把握、需要验证者注意什么。
