# 工单 13 — 开机自启（LaunchAgent）＋ 命令行开关

## 目标

- 登录时自动启动本 App
- **崩溃自动重拉**，但用户主动退出（菜单「退出」或 SIGTERM，退出码 0）**不**重拉，否则没法正常关掉它
- 菜单里能看状态、能开关
- 提供命令行开关，方便脚本化验证（我这边没有鼠标，只能跑命令）

## 要新增/修改

### 1. 新增 `Sources/CapslockPlusMac/Support/LoginItem.swift`

```swift
enum LoginItem {
    static var label: String { "com.littleboy.CapslockPlusMac" }
    static var plistPath: String     // ~/Library/LaunchAgents/<label>.plist
    static func isEnabled() -> Bool  // plist 存在 且 launchctl 能查到
    static func enable() -> Bool
    static func disable() -> Bool
}
```

plist 内容（用 `PropertyListSerialization` 生成，别手拼字符串）：

```
Label            = com.littleboy.CapslockPlusMac
ProgramArguments = [ Bundle.main.bundlePath + "/Contents/MacOS/CapslockPlusMac" ]
RunAtLoad        = true
KeepAlive        = { SuccessfulExit = false }      // 只在非 0 退出时重拉
ThrottleInterval = 10
ProcessType      = Interactive
```

- `enable()`：创建 `~/Library/LaunchAgents` → 写 plist（已存在则覆盖）→
  `launchctl bootstrap gui/<getuid()> <plist>`；bootstrap 若返回 “already loaded”(5)，先
  `launchctl bootout gui/<uid>/<label>` 再 bootstrap
- `disable()`：`launchctl bootout gui/<uid>/<label>`（失败忽略）→ 删除 plist
- 执行外部命令用 `Process`（`/bin/launchctl`），**不要**用 shell 拼接字符串
- 日志：`loginItem enable ok|fail status=…` / `loginItem disable ok`
- 所有失败路径返回 false，不要崩

### 2. `AppDelegate.swift`

- 菜单加一项 `开机自启：开/关`（`NSMenuItem`，`state = .on/.off`），点击切换并刷新标题
- 「登录时自动启动」不需要额外提示弹窗，失败时用 `Log.error` 记录即可

### 3. `main.swift`

支持两个 CLI 参数（用于验证，不进菜单）：

```
--login-item-enable     调用 LoginItem.enable()，打印结果后 exit(0/1)
--login-item-disable    调用 LoginItem.disable()，同上
```

注意：这两个参数要在启动 AppKit 之前处理并退出，不要进入事件循环。

## 日志

```
[I] loginItem enable ok plist=/Users/x/Library/LaunchAgents/com.littleboy.CapslockPlusMac.plist
[I] loginItem disable ok
[E] loginItem enable fail status=…
```

## 验收（我跑）

```
swift build -c release --arch arm64 && ./scripts/build.sh
./dist/CapslockPlusMac.app/Contents/MacOS/CapslockPlusMac --login-item-enable
launchctl print gui/$(id -u)/com.littleboy.CapslockPlusMac | head -5
kill -9 <pid>        # 非 0 退出 -> 应在 ~10s 内被重新拉起
./dist/CapslockPlusMac.app/Contents/MacOS/CapslockPlusMac --login-item-disable
```

## 不要做

- 不要动 KeyLayer / Actions / WindowStore / InputSource
- 不要用 `/Library/LaunchDaemons`（需要 root）
- 不要联网、不要试 `swift build`（本机无工具链）

## 结束

4 行以内：KeepAlive 用的哪个键值、bootstrap 已加载时怎么处理、主动退出为什么不重拉、plist 里 ProgramArguments 指什么。
