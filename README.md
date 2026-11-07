# capslock_plus_mac

Capslock+（Windows/AutoHotkey）的 macOS 自用版，v0 只做两件事：**文本编辑**、**窗口绑定**。
单按 Caps 仍切换大小写。

## 用法

按住 **Caps** 当修饰键：

```
光标    s 左   f 右   e 上   d 下        a 左一词   g 右一词   t 上10行  b 下10行
选区    j 左   l 右   i 上   k 下        h 左选一词  y 上10行   n 下10行
        u 选到行首   o 选到行尾   , 当前词   . 右选一词
行      p 行首   ; 行尾
删除    w 删前一字符   r 删后一字符   [ 删到行首   / 删到行尾
        backspace 删整行     enter 下方插入空行     space 回车
窗口    alt+1..0 绑定当前窗口      1..0 激活已绑定的窗口（绑定会落盘，重启后仍有效）
单按 Caps = 切换大小写
长按 Caps 0.6 秒 = 切换输入法（按住满 0.6s 当次即触发，只切一次；之后仍可按着继续用组合键）
```

全部可用动作（含参数化 `moveUp(20)`、`send(cmd+shift+t)`、`wrapSelection(paren)` 等）见
[`docs/ACTIONS.md`](docs/ACTIONS.md)。

`alt` = Mac 的 **Option ⌥**。完整键位在 `~/.config/capslock-plus-mac/keymap.json`，
改完按 **caps+F5** 生效，不需要重新编译。

时间档位（`chordMaxMs` / `longPressMs` 可调，clamp 300–3000ms）：

```
< 300ms   切大小写
300–600ms 空档（按住犹豫，什么都不做）
≥ 600ms   切输入法
```

切换输入法走 Text Input Sources API 直接选源，**不依赖**系统「选择上一个输入源」快捷键。
只认 `category=TISCategoryKeyboardInputSource` 且 `type` 为 KeyboardLayout / KeyboardInputMode 的源，
所以不会切到 Emoji & Symbols、Dictation 这类假源（实测它们 `TISSelectInputSource` 返回成功但并不切换）。

## 构建与运行

```bash
./scripts/build.sh          # swift build + 组装 .app + 签名（需要登录钥匙串已解锁）
./scripts/run.sh            # 构建并重启
./scripts/build-mac.sh      # 从 Linux 侧 ssh 到 Mac 构建（本项目实际用的方式）
./scripts/sync-to-mac.sh    # 让 Mac 侧仓库快进到 origin/master
```

产物在 `dist/CapslockPlusMac.app`，用 `Apple Development: 1127534615@qq.com` 签名。
**签名身份不要换**：TCC 授权（辅助功能 / 输入监控）跟签名绑定，换了要重新授权。

## 仓库与两端分工

远程仓库：`git@github.com:icecreamzhao/capslockplus_mac.git`（macOS 与 Linux 两份工作副本共用）

- **Linux 侧**（`/home/ubuntu/projects/capslock_plus_mac`）：写代码、提交、`git push`
- **Mac 侧**（`~/projects/capslock_plus_mac`）：只 `git pull --ff-only` + 编译验证

```bash
# Linux：改完 -> 提交 -> push -> 让 Mac 快进
git add -A && git commit -m "..." && git push origin master
./scripts/sync-to-mac.sh && ./scripts/build-mac.sh
```

**不要再用 rsync 在两份副本之间搬文件**：两边各有 `.git`，rsync 会让历史互相覆盖。
两边都有未提交改动时 `sync-to-mac.sh` 会直接拒绝执行。


首次运行需要在「系统设置 > 隐私与安全性」里授予 **辅助功能** 和 **输入监控**。

## 键盘层怎么工作的

1. 启动时用 `hidutil` 把 Caps Lock 重映射成 F18（系统层，不需要 root）
2. app 在 HID 层建 CGEventTap，吞掉 F18 的 keyDown/keyUp，自己记按下/松开
3. F18 按住期间的其他键 → 查键位表执行动作；F18 单按（<300ms）→ 切真实大小写锁定

不是把 caps 当修饰键硬抓——那条路（吞 `flagsChanged` + 自己维护锁定状态）实机验证会让
WindowServer 修饰键状态失步，表现为"一直按着 caps，打不了字"。

## 恢复手段

```bash
./scripts/keyremap.sh off     # 撤掉 caps->F18（app 被 kill -9 后 Caps 变死键时用）
./scripts/keyremap.sh status  # 看当前状态
```

app 正常退出、收到 SIGTERM/SIGINT 时会自己撤掉映射；睡眠唤醒和键盘热插拔后会自己补回。

## 离线词库与读音

`caps+t` 先查本地词库，未命中才走在线翻译。

```bash
# 词典转 SQLite（牛津英汉在前，命中即停）
python3 scripts/mdx-to-sqlite.py --out ~/.config/capslock-plus-mac/dict.sqlite \
  --dict oalecd9="$HOME/Documents/dict/牛津高阶英汉/牛津高阶英汉双解词典（第9版）.mdx" \
  --dict ldoce6="$HOME/Documents/dict/LDOCE/LongmanDictionaryOfContemporaryEnglish6thEnEn.mdx"

# 抽单词读音（只要 \hwd\ 下的 mp3，不含例句音频）
python3 scripts/mdd-to-audio.py \
  --mdd "$HOME/Documents/dict/LDOCE/LongmanDictionaryOfContemporaryEnglish6thEnEn.mdd" \
  --out ~/.config/capslock-plus-mac/audio
```

- 依赖只在转换阶段：`pip3 install --user readmdict`（缺 python-lzo 时脚本会塞占位模块，这两本都是 zlib 压缩）
## 在线翻译（有道智云）

有凭据就走官方 NMT，没有或调用失败时自动退回公开的 `dict.youdao.com/jsonapi`。

```bash
# 凭据不进仓库，chmod 600
cat > ~/.config/capslock-plus-mac/youdao.json <<'JSON'
{"appId": "你的appId", "appSecret": "你的appSecret"}
JSON
chmod 600 ~/.config/capslock-plus-mac/youdao.json
```

- 接口：`POST https://openapi.youdao.com/api`，`from=auto&to=auto`，`signType=v3`
- 签名：`SHA256(appId + 截断后的q + salt + curtime + appSecret)`；q 超过 20 字符时取「前10 + 长度 + 后10」
- 日志里用 `engine=有道智云` / `nmt failed ... -> jsonapi fallback` 区分实际走了哪条

- `dict.sqlite` 48MB / 10.4 万词条；`audio` 505MB / 9.5 万 mp3
- 牛津包 `mdd` 只有 1,388 个图片，没有音频；读音全部来自朗文
- 转换脚本以 `PRAGMA journal_mode=DELETE` 收尾，别留 WAL —— 只读打开 WAL 库会 `SQLITE_CANTOPEN`

## 已知限制

- `kill -9` 无法拦截，映射会残留，需手动 `keyremap.sh off`
- 窗口跳转优先按标题把具体窗口 raise 到前；标题变了（Terminal 换命令、浏览器换页）就只切到该 app，日志记 `title-miss`。
  macOS 没有跨进程稳定的窗口标识，绑定只能存到「应用级 + 标题提示」这一层
- 绑定的 app 没在运行时按编号会自动启动它（`NSWorkspace`），启动到窗口可用之间可能有 1–2 秒延迟
- 多剪贴板未实现：带修饰键的 chord 里合成 `Cmd+C` 时目标 app 收到的不是复制（无修饰的方向键动作不受影响），见 `docs/SPEC.md` 的说明
- **Secure Input 期间热键完全失效**（密码框、`sudo` 提示）：系统不把按键投递给 event tap。app 会做两件事——菜单栏图标变锁并显示是哪个 App 开启的，以及把前缀键状态复位；解除后自动恢复。实测日志：整个 sudo 密码提示期间 0 条按键事件。

## 安装与开机自启

```bash
ditto dist/CapslockPlusMac.app /Applications/CapslockPlusMac.app   # 装到标准位置
```

菜单里「开机自启」可开关，落盘到 `~/Library/LaunchAgents/com.littleboy.CapslockPlusMac.plist`：

- `KeepAlive = { SuccessfulExit = false }` → **崩溃（非 0 退出）自动重拉**，主动退出/收到 SIGTERM 不重拉
- `ThrottleInterval = 10`，`RunAtLoad = true`
- 脚本可用 `CapslockPlusMac --login-item-enable | --login-item-disable`

注意：如果换了 .app 所在路径（例如从 dist 挪到 /Applications），要重新开一次自启，否则 plist 里
`ProgramArguments` 还指向旧路径。

## 数据文件

```
~/.config/capslock-plus-mac/keymap.json    键位表（改完 caps+F5 生效）
~/.config/capslock-plus-mac/windows.json   窗口绑定（tmp + rename 原子写，坏了只警告不影响启动）
```

`windows.json` 每条形如 `{"bundleID","appName","titleHint","boundAt"}`；菜单「窗口绑定」可看状态并一键清空。

## 日志

`~/Library/Logs/CapslockPlusMac.log`，菜单栏图标 → 「打开日志」。

## 代码结构

```
Sources/CapslockPlusMac/
  main.swift                 入口，--selftest
  AppDelegate.swift          生命周期、状态栏、唤醒/设备变化恢复
  Config.swift               键位表默认值 + 读写 + 重载
  KeyLayer/EventTapEngine     CGEventTap、事件分流、MAGIC 过滤
  KeyLayer/CapsState          前缀键状态机、单按判定、看门狗
  KeyLayer/HIDCapsLock        IOHID 锁定状态读写（私有 API）
  KeyLayer/Chord              键位组合解析
  Actions/TextActions         光标/选区/删除（合成按键）
  Actions/WindowActions       窗口绑定与激活（AX）
  Support/AX                  Accessibility 封装
  Support/KeyPost             带 MAGIC 的按键合成
  Support/KeyRemap            hidutil 重映射
  Support/SystemEvents        唤醒 + HID 设备变化通知
docs/SPEC.md                  v0 规格与决策记录
docs/codex-tasks/            逐轮工单（01 骨架 → 05 唤醒恢复）
```
