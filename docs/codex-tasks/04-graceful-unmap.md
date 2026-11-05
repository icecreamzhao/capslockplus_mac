# 工单 04 — 退出/被杀时撤销 F18 重映射

## 现象（真机验证）

`pkill -x CapslockPlusMac` 之后 `hidutil` 里的 caps→F18 映射还在（读回仍是 232 条设备记录）。
原因：SIGTERM 不会走 `NSApplication` 的 `applicationWillTerminate`，app 直接死掉，键盘留在 F18 状态，
用户的 Caps 键变成死键，只能手动跑 `scripts/keyremap.sh off`。

## 要求

只改 `Sources/CapslockPlusMac/AppDelegate.swift`（必要时可新增 `Sources/CapslockPlusMac/Support/Lifecycle.swift`，
其他文件一律不动）：

1. **退出必撤**：注册 SIGTERM / SIGINT / SIGHUP 处理（`signal()` 或 `DispatchSourceSignal` 均可），
   收到信号时先 `KeyRemap.remove()`，再 `exit(0)`。信号处理里不要做 AppKit 操作。
   同时保留 `applicationWillTerminate` 里的 `KeyRemap.remove()`（正常退出路径）。
2. **取消也要撤**：`atexit` 注册一个只调 `KeyRemap.remove()` 的闭包没用（Swift 的 atexit 闭包不能捕获），
   所以用上面两个路径覆盖即可，不要为此折腾。
3. **先建 tap 再上重映射**：现在 `applicationDidFinishLaunching` 是先 `KeyRemap.apply()` 再建 tap。
   改成：先建 tap（`engine.start()`），成功后再 `KeyRemap.apply()`；tap 建失败则不重映射并弹提示
   （理由：tap 不通时把 caps 改成 F18 等于把键弄死，而重映射失败只是功能不可用）。
4. **重复启动保护**：如果 `KeyRemap.isApplied()` 在启动时为真（上一次残留），先 `remove()` 再 `apply()`，
   避免叠加多条映射。日志各记一行。
5. 状态栏菜单里「重映射 Caps→F18」那项如果已经加了，保持；没加就加一项显示当前状态并支持手动开关。

## 日志要求

```
[I] keyremap stale removed
[I] keyremap on
[I] keyremap off        ← 收到 SIGTERM 时必须出现
```

## 验收（我在 Mac 上跑）

```
swift build -c release --arch arm64
./scripts/build.sh
./dist/CapslockPlusMac.app/Contents/MacOS/CapslockPlusMac --selftest
# 然后：启动 app → hidutil 读回有映射 → pkill -x CapslockPlusMac → hidutil 读回必须为 0
```

## 不要做

- 不要改 EventTapEngine / CapsState / KeyPost / Actions/、不要碰 resources/ 和 scripts/
- 不要引入依赖、不要联网、不要试 `swift build`（本机无工具链）

## 结束

3 行以内：SIGTERM 走哪条路径撤映射、有没有覆盖 SIGKILL 的兜底说明（SIGKILL 无解，只说明即可）。
