# 工单 06b — 修编译错误：CGSessionCopyCurrentDictionary 与 CoreGraphics 重名

## 报错（真机 swift build 原文）

```
Sources/CapslockPlusMac/Support/SecureInput.swift:14:29: error: ambiguous use of 'CGSessionCopyCurrentDictionary()'
    `- note: found this candidate in module 'CoreGraphics'
```

## 根因

`CGSessionCopyCurrentDictionary()` 已经由 CoreGraphics 模块导出，我们自己在第 5-6 行用
`@_silgen_name` 又声明了一个同名函数，两处候选冲突。

## 改法（只改 `Sources/CapslockPlusMac/Support/SecureInput.swift`）

1. 删掉第 5-6 行那个 `@_silgen_name` 声明。
2. 直接用系统那个：`import CoreGraphics`，调用 `CGSessionCopyCurrentDictionary()`。
   它的返回类型是 `Unmanaged<CFDictionary>?` 或 `CFDictionary?`，**以编译器为准**：
   先按 `Unmanaged<CFDictionary>?` 处理（`takeRetainedValue()`），编译报错就改成直接当
   `CFDictionary` 用，不要为绕过类型再引入第二个声明。
3. 逻辑不变：取 `"kCGSSessionSecureInputPID"`，`NSNumber`/`Int` 都接受，取不到返回 nil。
4. `isEnabled()`、`ownerName()` 保持原样。

## 验收（我这边跑，脚本已修成能正确报失败）

```
swift build -c release --arch arm64
./scripts/build.sh
./dist/CapslockPlusMac.app/Contents/MacOS/CapslockPlusMac --selftest
```

## 不要做

- 不要改其他任何文件、不要新增文件
- 不要联网、不要试 `swift build`（本机无工具链）

## 结束

1 行：最终用的是哪种返回类型。
