# 工单 11 — 长按时长默认值 1000ms 改为 600ms

只改 `Sources/CapslockPlusMac/Config.swift` 三处默认值：

1. `defaultKeymap()` 里 `longPressMs: 1000` → `600`
2. 读盘时 `(root["longPressMs"] as? NSNumber)?.intValue ?? 1000` → `?? 600`
3. 写盘字典里 `"longPressMs": 1000` → `600`

clamp 范围（300…3000）和其他逻辑都不要动。不要联网、不要试构建。

## 结束

1 行：改了哪三处。
