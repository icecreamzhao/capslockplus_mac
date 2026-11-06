# 工单 12b — 启动时预载窗口绑定并打日志

现在 `WindowActions.bindings` 是懒加载，App 启动后日志里看不到任何绑定信息，
排查"重启后绑定还在不在"必须去翻 `windows.json`。

## 改法（只改这两个文件）

1. `Actions/WindowActions.swift`：新增
   ```swift
   static func preload() { _ = allBindings() }   // 触发懒加载即可（内部已有 "window.store loaded n=" 日志）
   ```
   懒加载逻辑和日志保持原样，不要改成同步阻塞式读取以外的行为。

2. `AppDelegate.swift`：`applicationDidFinishLaunching` 里（建 tap 之前或之后均可）调一次 `WindowActions.preload()`。

不要联网、不要试构建。

## 结束

1 行：preload 在什么时机被调用。
