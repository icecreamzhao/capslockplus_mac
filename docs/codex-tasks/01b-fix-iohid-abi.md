# 工单 01b — 修复启动崩溃：IOHID 签名错误（只改一个文件）

## 现象

`./dist/CapslockPlusMac.app/Contents/MacOS/CapslockPlusMac` 一启动就崩，exit 133：

```
exception: EXC_BREAKPOINT / SIGTRAP
asi: BUG IN CLIENT OF LIBMALLOC: memory corruption of free block
stack: _AXUIElementRegisterServerWithRunLoop <- -[NSApplication finishLaunching] <- NSApplication.run
```

没有写出任何日志，即崩溃发生在 `HIDCapsLock` 第一次调用时。

## 根因（已用探针在你的机器上验证，不要再改判）

`Sources/CapslockPlusMac/KeyLayer/HIDCapsLock.swift` 里两处 ABI 错误：

1. `IOHIDGetModifierLockState` **不是**只有两个参数、也不是返回状态值。
   真实签名（来自 Capslox 3.1.1 的反汇编调用点，及其自身日志串 `IOHIDSetModifierLockState() failed: %x`）：

   ```
   kern_return_t IOHIDGetModifierLockState(io_connect_t handle, int32_t selector, bool *state);
   kern_return_t IOHIDSetModifierLockState(io_connect_t handle, int32_t selector, bool state);
   ```

   反汇编证据（Get）：`ldr w0,[sp,#0xc]` / `add x2, sp, #0xb` / `mov w1,#1` / `bl _IOHIDGetModifierLockState`
   ——第三个参数是**调用方栈上 bool 的地址**。当前代码只传两个参数，被调用方把 x2 当指针写，
   于是踩坏堆 → libmalloc 报 memory corruption。

2. handle 类型是 `io_connect_t`，必须由
   `IOServiceOpen(service, mach_task_self_, 1 /* kIOHIDParamConnectType */, &conn)` 得到，
   不能直接把 `IOServiceGetMatchingService` 的 `io_service_t` 传进去。

## 已验证可用的最小实现（我在你的机器上跑通了，输出贴在下面）

```swift
@_silgen_name("IOHIDGetModifierLockState")
func IOHIDGetModifierLockState(_ handle: io_connect_t, _ selector: Int32, _ state: UnsafeMutablePointer<Bool>) -> kern_return_t
@_silgen_name("IOHIDSetModifierLockState")
func IOHIDSetModifierLockState(_ handle: io_connect_t, _ selector: Int32, _ state: Bool) -> kern_return_t

// 每次调用都开/关连接（与 Capslox 反汇编里的 IOServiceOpen + IOServiceClose 一致）：
let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
var conn: io_connect_t = 0
let opened = IOServiceOpen(service, mach_task_self_, 1, &conn)
IOObjectRelease(service)
// 用 conn 调上面两个函数，最后 IOServiceClose(conn)
```

探针实测输出：

```
conn=6683
get kr=0 state=false
set kr=0
get2 kr=0 state=true flipped=true
restored=true
```

## 要改的东西

只允许改 `Sources/CapslockPlusMac/KeyLayer/HIDCapsLock.swift`：

1. 两个 `@_silgen_name` 声明按上面的签名改（Get 三参数带 out 指针，Set 第三参是 `Bool` 值）。
2. `isLocked` 改为 `IOServiceOpen` 拿 connect → `Get(&state)` → `IOServiceClose`；Get 返回非 0 时记日志并按“当前状态不变”处理（保持上一次已知值，不要崩）。
3. `setLocked` 同样的开/关连接模式，返回非 0 时写 `Log.warn("hid setLocked failed kr=\(kr)")`。
4. 删掉缓存的 `handle` 字段和 `deinit` 里的 `IOObjectRelease`，不要留下悬空 io_service_t。
5. 对外接口 `var isLocked: Bool` / `func setLocked(_ on: Bool)` / `func reconcile(desired:) -> Bool` 保持不变，`CapsState` 不要动。

## 验收

```
swift build -c release --arch arm64
./scripts/build.sh
./dist/CapslockPlusMac.app/Contents/MacOS/CapslockPlusMac --selftest     # selftest OK，退出码 0
```

## 不要做

- 不要改其他文件、不要改 `CapsState.swift`、不要碰 `resources/` 和 `scripts/`
- 不要引入第三方依赖、不要联网、不要尝试 `swift build`（本机无工具链）
- 不要用 `try!`/`fatalError` 兜底

## 结束

3 行以内说明改了哪几处、`isLocked` 失败时的行为。
