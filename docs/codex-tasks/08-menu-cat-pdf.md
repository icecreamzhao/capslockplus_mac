# 工单 08 — 菜单栏图标改用自备的小猫 PDF

## 已就绪的资产

- `resources/MenuCat.pdf` — 用户提供的 cat.svg 转成的矢量 PDF（单路径、黑色、透明背景、四周约 10% 留白）
- `scripts/build.sh` 已改成会 `cp resources/*.pdf` 到 `Contents/Resources/`
- `resources/src/cat.svg` 是原始 svg，仅供参考，不参与构建

## 要做的

只改 `Sources/CapslockPlusMac/AppDelegate.swift`（可以改 `statusImage` 辅助函数）。

1. 正常图标优先级：
   1. 从 bundle 读 `MenuCat.pdf`：
      ```swift
      if let path = Bundle.main.path(forResource: "MenuCat", ofType: "pdf"),
         let img = NSImage(contentsOfFile: path) { 用它 }
      ```
   2. 取不到才降级到现在的 `cat.fill` → `capsule.portrait` → `command`
2. 用资源图时同样：`isTemplate = true`、`image.size = NSSize(width: 18, height: 18)`。
3. 加载失败要落日志：`Log.warn("menuIcon fallback reason=\(...)")`，方便排查资源没拷进去。
4. Secure Input 的 `lock.fill` 逻辑不动。
5. **注意**：`Bundle.main.path(forResource:)` 在 `.app` 里指向 `Contents/Resources`，
   而我们是用脚本手工组的 bundle，没有 Info.plist 的 CFBundleExecutable 之外的声明也没关系，
   但**必须确保 `Contents/Resources/MenuCat.pdf` 存在**；如果读不到就走降级，并在日志里写清楚。

## 验收（我这边跑）

```
swift build -c release --arch arm64
./scripts/build.sh
ls dist/CapslockPlusMac.app/Contents/Resources/
```
真机：菜单栏出现用户那只会线小猫；`sudo -k; sudo ls` 时变锁，输完变回猫。

## 不要做

- 不要改 scripts/、resources/、其他 Swift 文件
- 不要联网、不要试 `swift build`（本机无工具链）

## 结束

1 行：`Bundle.main.path(forResource:)` 是否在没有完整 Xcode 工程的情况下也能读到手工组的 Resources。
