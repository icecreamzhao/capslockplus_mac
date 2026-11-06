# 工单 12 — 窗口绑定持久化（应用级 + 标题尽力匹配 + 未运行自动启动）

## 目标（用户已定）

1. 绑定**落盘**，App 重启 / 电脑重启后仍然有效
2. 激活顺序：app 在跑 → 切过去；标题能匹配上 → 把那个窗口 raise 到前；匹配不上 → 只切 app（不报错，日志记 `title-miss`）
3. app **没在跑**时按编号 → **直接自动启动**，起来后再尝试 raise
4. 允许跟着切 Space / 全屏（沿用现有 `.activateAllWindows`，不要自己处理 Space）
5. 菜单里能看到每个槽位的状态，并能一键清空

## 数据结构（存盘）

`~/.config/capslock-plus-mac/windows.json`

```json
{ "version": 1,
  "slots": { "1": { "bundleID": "com.google.Chrome", "appName": "Google Chrome",
                    "titleHint": "GitHub", "boundAt": 1762... } } }
```

## 要改/新增的文件

### 1. 新增 `Sources/CapslockPlusMac/Support/WindowStore.swift`

```swift
struct WindowBinding: Codable {
    var bundleID: String
    var appName: String
    var titleHint: String      // 可能为空串
    var boundAt: Double        // timeIntervalSince1970
}

enum WindowStore {
    static func load() -> [Int: WindowBinding]     // 文件不存在/坏文件 → 空字典 + Log.warn，不崩
    static func save(_ slots: [Int: WindowBinding]) // 原子写：先写 windows.json.tmp，再 rename 覆盖
    static func clear()
}
```

目录用 `FileManager` 创建（`~/.config/capslock-plus-mac/`，与 keymap.json 同目录）。
JSON 编解码用 `JSONSerialization` 或 `Codable` 均可，键名保持上面的形式。

### 2. `Support/AX.swift`

把 `raiseWindow(pid:title:)` 改成：

```swift
@discardableResult
static func raiseWindow(pid: pid_t, titleHint: String) -> Bool
```

匹配顺序（同一轮遍历里按优先级记 best）：
1. 标题完全相等
2. 标题 `hasPrefix(titleHint)`
3. 标题包含 `titleHint`

`titleHint` 为空 → 直接返回 false（不要乱 raise）。全部失败返回 false，不要各自打日志，由调用方统一记 `title-miss`。
找不到窗口数组时也返回 false（保留一条 `ax raiseWindow failed reason=no-windows`）。

### 3. `Actions/WindowActions.swift`

- `private static var bindings: [Int: WindowBinding]?`，首次访问时 `WindowStore.load()`，日志 `window.store loaded n=\(count)`
- `bind(index)`：除 bundleID 外记录 `appName = app.localizedName ?? bundleID`、`titleHint = AX.focusedWindowTitle() ?? ""`、`boundAt`；
  然后 `WindowStore.save(bindings)`；日志
  `window.bind n=1 app=Google Chrome title=GitHub saved=ok`
- `activate(index)`：
  - 未绑定 → `window.activate n=1 reason=unbound`（不变）
  - app 在跑：
    ```
    activate(options: [.activateAllWindows])
    Log.info("window.activate n=1 app=... running=1")
    DispatchQueue.main.asyncAfter(+0.15) {
        if AX.raiseWindow(pid:titleHint:) { Log.info("window.activate n=1 raised=1") }
        else { Log.warn("window.activate n=1 raised=0 reason=title-miss hint=...") }
    }
    ```
  - app 没在跑：
    ```
    Log.info("window.launch n=1 app=... reason=not-running")
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { Log.warn("window.launch n=1 failed reason=no-url"); return }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, error in ... }
    ```
    启动回调或在回调后 `DispatchQueue.main.asyncAfter(+0.8)` 找一次进程：找到就 activate + 0.3s 后 raise，
    `Log.info("window.launch n=1 ok pid=1234")`；失败 `Log.warn("window.launch n=1 failed reason=...")`。
    **注意**：launch 后窗口可能还没出来，raise 失败不要升级成 error。
- `static func statusLines() -> [(slot: Int, text: String)]`（给菜单用，按 slot 升序）：
  - 已绑定且 app 在跑 → `"1  Google Chrome"`
  - 已绑定但 app 未运行 → `"1  Google Chrome（未运行）"`
  - 未绑定 → 不返回（只列已绑定的）
- `static func clearAll()`：清字典 + `WindowStore.clear()` + `Log.info("window.clear all")`

### 4. `AppDelegate.swift`

菜单里加一个子菜单项 **「窗口绑定」**（`NSMenuItem` + 子 `NSMenu`，在 `menuWillOpen` 里每次重建内容）：

- 每个已绑定槽位一条只读项，标题用 `statusLines()` 的文本
- 没有绑定 → 一条只读项「（未绑定，Caps+Option+数字 绑定当前窗口）」
- 分隔线 + 「清除全部绑定」→ 调 `WindowActions.clearAll()` 并刷新

## 日志

```
[I] window.store loaded n=3
[I] window.bind n=1 app=Google Chrome title=GitHub saved=ok
[I] window.activate n=1 app=com.google.Chrome running=1
[I] window.activate n=1 raised=1
[W] window.activate n=1 raised=0 reason=title-miss hint=GitHub
[I] window.launch n=3 app=com.tinyspeck.slackmacgap reason=not-running
[I] window.launch n=3 ok pid=4242
```

## 验收（我跑 + 用户真机测）

```
swift build -c release --arch arm64 && ./scripts/build.sh && ./dist/CapslockPlusMac.app/Contents/MacOS/CapslockPlusMac --selftest
```
真机：
1. `caps+opt+2` 绑一个窗口 → 看 `windows.json` 里有记录
2. 杀掉我们的 app 重启 → 菜单「窗口绑定」里仍列出该槽位
3. 退出目标 app → 按 `caps+2` → 自动启动并切过去
4. 目标 app 在跑但窗口标题变了 → 仍能切到该 app（日志 title-miss）
5. 「清除全部绑定」后 `windows.json` 变空

## 不要做

- 不要动 KeyLayer/、InputSource、TextActions、ClipboardActions、KeyRemap
- 不要自己实现 Space/全屏切换逻辑，交给 NSRunningApplication.activate
- 不要引入依赖、不要联网、不要试 `swift build`（本机无工具链）

## 结束

4 行以内：落盘时机、launch 后怎么确认进程起来了、title 三种匹配顺序、坏文件怎么处理。
