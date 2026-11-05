# 工单 07 — 状态栏图标换成小猫

## 要做的

只改 `Sources/CapslockPlusMac/AppDelegate.swift`。

1. 正常状态：`NSImage(systemSymbolName: "cat.fill", accessibilityDescription: "Capslock+")`
   （本机已确认该符号存在），`isTemplate = true`，`image.size = NSSize(width: 18, height: 18)`。
   取不到时按现有顺序降级 `capsule.portrait` → `command`。
2. Secure Input 开启时的锁图标逻辑保留，但同样设 `size = 18x18` 和 `isTemplate = true`
   （`lock.fill`，取不到用 `lock`）。解除后换回小猫。
3. 菜单项文案、tooltip 都不改。

## 验收

```
swift build -c release --arch arm64
./scripts/build.sh
```
真机：菜单栏出现一只小猫（模板图标，深浅色下自动反色）；`sudo -k; sudo ls` 时变锁，输完密码变回猫。

## 不要做

- 不要改其他文件、不要新增资源文件、不要引入依赖、不要联网、不要试 `swift build`（本机无工具链）

## 结束

1 行：改了哪个函数。
