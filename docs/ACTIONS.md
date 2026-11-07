# 动作参考

键位表：`~/.config/capslock-plus-mac/keymap.json`，改完按 **caps + F5** 生效。

```json
{
  "tap": "toggleCapsLock",
  "chordMaxMs": 300,
  "longPressMs": 600,
  "longPress": "switchInputSource",
  "bindings": {
    "caps+f": "moveRight",
    "caps+t": "moveup(10)"
  }
}
```

- `tap`：短按 Caps（<`chordMaxMs`，且没按过其他键）要执行的动作，可以是下表任意一个
- `longPress`：按住 ≥`longPressMs` 后触发的动作，同上；默认 `switchInputSource`
- 动作名不区分大小写；解析不出来会写 `config unknown action=…` 并当作 `none`

## 移动

| 写法 | 作用 |
|---|---|
| `moveLeft` / `moveRight` / `moveUp` / `moveDown` | 左/右/上/下 |
| `moveWordLeft` / `moveWordRight` | 按单词左右（Option+方向） |
| `moveLineStart` / `moveLineEnd` | 行首 / 行尾（Command+方向） |
| `moveUp10` / `moveDown10` | 上/下 10 行 |
| `moveUp(20)` | 任意行数，`<base>(n)`，n 取 1–100 |

`(n)` 可用的 base：`moveLeft moveRight moveUp moveDown moveWordLeft moveWordRight
selectLeft selectRight selectUp selectDown selectWordLeft selectWordRight deleteBackward deleteForward`

## 选中

| 写法 | 作用 |
|---|---|
| `selectLeft` / `selectRight` / `selectUp` / `selectDown` | 按字符 / 行选中 |
| `selectWordLeft` / `selectWordRight` | 按单词选中 |
| `selectLineStart` / `selectLineEnd` | 选中至行首 / 行尾 |
| `selectUp10` / `selectDown10` | 上/下选 10 行 |
| `selectDown(5)` | 任意行数 |
| `selectCurrentWord` | 选中当前单词 |

## 删除与编辑

| 写法 | 作用 |
|---|---|
| `deleteBackward` / `deleteForward` | 退格 / 前向删除 |
| `deleteWordBackward` / `deleteWordForward` | 向左 / 向右删一个单词 |
| `deleteToLineStart` / `deleteToLineEnd` | 删至行首 / 行尾 |
| `deleteToPageStart` / `deleteToPageEnd` | 删至文档开头 / 结尾 |
| `deleteLine` | 删掉本行内容（保留空行） |
| `hardDeleteLine` | 连行尾换行一起删（整行消失） |
| `deleteAll` | 全选后删除 |
| `insertLineBelow` | 下方插入新行 |
| `pressReturn` | 回车 |
| `wrapSelection(paren)` | 选中内容两端加括号，见下 |
| `selectCurrentWord` | 选中当前词 |

`wrapSelection(...)` 支持：`paren` `bracket` `brace` `angle` `quote` `singlequote` `backtick` `markdown`

## 文本变换（选中文字后使用）

全部通过 AX 读写选区完成，**不合成任何按键**，不会碰剪贴板。

| 写法 | 作用 |
|---|---|
| `transform(upper)` / `transform(lower)` / `transform(title)` | 大写 / 小写 / 每个词首字母大写 |
| `transform(camel)` | `user profile name` → `userProfileName` |
| `transform(pascal)` | → `UserProfileName` |
| `transform(snake)` | → `user_profile_name` |
| `transform(kebab)` | → `user-profile-name` |
| `transform(constant)` | → `USER_PROFILE_NAME` |
| `transform(trim)` | 去掉首尾空白（逐行 + 整体） |
| `transform(sort)` / `transform(sortdesc)` | 按行排序（本地化比较，中文按拼音） |
| `transform(reverse)` | 行序反转 |
| `transform(unique)` | 按行去重（保留首次出现顺序） |
| `transform(jsonpretty)` / `transform(jsonmin)` | JSON 美化 / 压缩（非法 JSON 会失败并记日志） |
| `transform(urlencode)` / `transform(urldecode)` | URL 编解码 |
| `transform(ascii2cjk)` / `transform(cjk2ascii)` | 强制转成中文 / 英文标点 |
| `transform(punctoggle)` | 自动判断方向：选中里有中文标点就转英文，否则转中文（引号也换） |

切词规则：`userProfileID`、`user_profile_id`、`user-profile id` 都能正确切成 `user/profile/ID` 三段。

变换后结果保持选中状态，可以连续套（先 `snake` 再 `upper`）。

## 窗口

| 写法 | 作用 |
|---|---|
| `window.bind(1)` … `window.bind(10)` | 绑定当前窗口到槽位（落盘） |
| `window.activate(1)` … `window.activate(10)` | 激活槽位；App 没开会自动启动 |
| `minimizeWindow` | 最小化当前窗口（全屏窗口会失败，日志 `minimize failed`） |
| `launchApp(com.apple.Safari)` | 启动或激活指定 App（bundle id） |
| `tile(left)` / `tile(right)` | 贴左半屏 / 右半屏 |
| `tile(top)` / `tile(bottom)` | 上半屏 / 下半屏 |
| `tile(maximize)` | 铺满可视区（避开菜单栏和 Dock） |
| `tile(center)` | 保持当前尺寸，在可视区居中 |

多显示器按窗口中心落在哪块屏幕决定平铺目标；全屏（Full Screen Space）窗口无法移动，会记 `tile ... ok=0`。

## 翻译

| 写法 | 作用 |
|---|---|
| `translate` | 翻译选中的单词/短语，浮层显示音标 + 释义 + 网络释义 |

浮层里的交互：

| 操作 | 行为 |
|---|---|
| 在浮层正文里划选单词 → 再按 `caps+t` | 翻新选中的词，内容就地替换，浮层不跳位置 |
| 浮层开着但没划选 → 再按 `caps+t` | 收起浮层，并把键盘焦点还给原来的 App |
| 点右上角 ✕ | 收起 |
| `Esc`（浮层是 key 时） | 收起 |
| 点浮层外 / 等一会儿 | **不会**关闭（想恢复自动关闭设 `panelAutoHideMs`） |

- 查词顺序：本地词库（牛津高阶英汉 → 朗文）→ 都没命中才走在线有道
- 本地词库：`~/.config/capslock-plus-mac/dict.sqlite`（48MB，10.4 万词条），由 `scripts/mdx-to-sqlite.py` 生成
- 读音：朗文 mdd 里抽出的 mp3，`~/.config/capslock-plus-mac/audio`（9.5 万个，505MB），由 `scripts/mdd-to-audio.py` 生成；牛津那个包 mdd 里只有图片，没有音频
- 在线数据源：有道智云 NMT（有凭据时）→ 公开 `https://dict.youdao.com/jsonapi` 兜底，英↔中双向
- 选中超过 60 字符时拒绝翻译（避免整篇文档打过去）
- 可在 keymap.json 顶层覆盖：`"translateEndpoint": "…"`、`"translateTimeoutMs": 4000`、`"panelAutoHideMs": 0`（0 = 不自动关，默认；>0 按毫秒自动关）

### 读选区的三条路径

不同 App 暴露选区的方式不一样，`translate` 按顺序尝试：

| 顺序 | 路径 | 适用 |
|---|---|---|
| 1 | `AXSelectedText` | 原生 App（Terminal、TextEdit、Preview、大多数 Cocoa 应用） |
| 2 | `AXSelectedTextMarkerRange` + `AXStringForTextMarkerRange` | Safari / WebKit（`AXSelectedText` 返回 `-25212`） |
| 3 | 广度优先遍历窗口树找 `AXWebArea`/`AXTextArea`（400ms 预算） | Firefox（焦点元素退化成 `AXWindow` 时） |

Chromium/Electron（VS Code、Chrome、Slack…）默认不建辅助功能树，读取前要先给目标 App 设 `AXManualAccessibility = true`，设完还要等它异步建树——代码里按 pid 只设一次。

### 兜底：白名单 App 用剪贴板

Qt、GPU 终端、部分国产客户端（微信等）根本不暴露选区。这类 App 可以登记进白名单，AX 全部失败后走「模拟 Cmd+C → 读剪贴板 → 原样写回」：

```json
"clipboardFallbackApps": ["com.microsoft.Excel", "org.inkscape.Inkscape"]
```

- 只有白名单里的 App 才会动剪贴板；其他 App 读不到就正常提示"没有选中文字"
- 剪贴板内容会被完整快照并还原（多 item、多类型都还原），但**剪贴板历史工具（Clipy 等）仍会记下这一次复制**
- 日志：`clipboard fallback start/ok/failed app=… len=…`

## 插入日期时间

| 写法 | 作用 |
|---|---|
| `insertdate` | `2026-11-07` |
| `insertdatetime` | `2026-11-07 19:46` |
| `inserttime` | `19:46` |
| `insertdate(yyyy/MM/dd)` | 自定义格式，遵循 Unicode 日期格式（`HH` 是 24 小时，`hh` 是 12 小时） |

优先用 AX 写入光标处，App 不支持 AX 文本时退回逐字符合成输入（终端里也能用）。

## 输入法 / 系统

| 写法 | 作用 |
|---|---|
| `switchInputSource` | 切到下一个输入法（TIS 直接选源） |
| `escape` | 发一个 Esc |
| `toggleCapsLock` | 切大写锁定 |
| `none` | 什么都不做 |
| `reloadConfig` | 重新读 keymap.json（默认 `caps+F5`） |

## 向目标 App 发按键

| 写法 | 作用 |
|---|---|
| `send(cmd+shift+t)` | 发一组按键；多个用逗号：`send(cmd+t, cmd+w)` |
| `type(Hello World)` | 直接输入这段文字（保留原大小写和空格） |

`send` 里可用的修饰词：`cmd` `alt` `ctrl` `shift`；
键名：`a`–`z` `0`–`9` `,` `.` `/` `-` `=` `;` `'` `[` `]` `` ` ``、
`return` `enter` `tab` `space` `escape` `left` `right` `up` `down` `delete` `backspace`
`pageup` `pagedown` `home` `end` `f1`–`f12`。

## 已知不可用

| 写法 | 说明 |
|---|---|
| `cut` `copy` `paste` `pastePlain` `extraClipboard.*` | 合成 Cmd+C 会被 WindowServer 合并物理修饰位，目标 App 不认作复制；代码保留但别绑 |
