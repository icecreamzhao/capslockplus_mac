#!/usr/bin/env python3
"""生成代码架构图：手排 SVG → docs/architecture.png。

用法：在仓库根目录运行 python3 scripts/gen-architecture.py（需要 rsvg-convert）。
改图只需改下面的 rows/坐标，不用碰 README。
"""
import subprocess

W = 1760
PAD = 48
FONT = "Noto Sans CJK SC"
BORDER = "#6b7c93"

def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def tw(s, size):
    return sum(1.0 if ord(ch) > 0x2E80 else 0.55 for ch in s) * size

def box_h(lines):
    return 34 + 19 * len(lines) + 12 if lines else 52

class Doc:
    def __init__(self): self.p = []
    def add(self, s): self.p.append(s)
    def rect(self, x, y, w, h, fill, stroke, rx=14, sw=1.6):
        self.add(f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="{rx}" '
                 f'fill="{fill}" stroke="{stroke}" stroke-width="{sw}"/>')
    def text(self, x, y, s, size, fill, weight="400", anchor="start"):
        self.add(f'<text x="{x:.1f}" y="{y:.1f}" font-family="{FONT}" font-size="{size}" '
                 f'font-weight="{weight}" fill="{fill}" text-anchor="{anchor}">{esc(s)}</text>')
    def box(self, x, y, w, title, lines, accent):
        h = box_h(lines)
        self.rect(x, y, w, h, "#ffffff", accent, rx=9, sw=1.4)
        self.add(f'<rect x="{x:.1f}" y="{y+3:.1f}" width="5" height="{h-6:.1f}" rx="2.5" fill="{accent}"/>')
        self.text(x + 18, y + 27, title, 15.5, "#1a202c", "700")
        ty = y + 27
        for ln in lines:
            ty += 19
            self.text(x + 18, ty, ln, 12.5, "#4a5568")
        return h
    def path(self, pts, label=None, dashed=False):
        dash = ' stroke-dasharray="5 4"' if dashed else ''
        d = "M " + " L ".join(f"{x:.1f} {y:.1f}" for x, y in pts)
        self.add(f'<path d="{d}" stroke="{BORDER}" stroke-width="1.6" fill="none"{dash} '
                 f'marker-end="url(#a)"/>')
        if label:
            i = len(pts) - 1
            (x1, y1), (x2, y2) = pts[i - 1], pts[i]
            self.label((x1 + x2) / 2, (y1 + y2) / 2 - 2, label)
    def arrow(self, x1, y1, x2, y2, label=None, dashed=False):
        self.path([(x1, y1), (x2, y2)], label, dashed)
    def label(self, x, y, s):
        w = tw(s, 12.5)
        self.add(f'<rect x="{x-w/2-7:.1f}" y="{y-14:.1f}" width="{w+14:.1f}" height="20" rx="5" fill="#ffffff"/>')
        self.text(x, y, s, 12.5, "#4a5568", anchor="middle")
    def svg(self, h):
        return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{h}">'
                f'<defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" '
                f'markerHeight="7" orient="auto-start-reverse">'
                f'<path d="M 0 0 L 10 5 L 0 10 z" fill="{BORDER}"/></marker></defs>'
                f'<rect width="{W}" height="{h}" fill="#ffffff"/>' + "".join(self.p) + "</svg>")

d = Doc()
d.text(PAD, 62, "Capslock+ for macOS · 代码架构", 31, "#1a202c", "700")
d.text(PAD, 92, "按住 Caps 当修饰键的键盘增强工具　·　Swift + AppKit，只依赖系统框架　·　"
                "键位与数据在 ~/.config/capslock-plus-mac/", 14, "#5a6b7d")

y = 122
ROW_GAP = 58
TOP = 44          # 层标题到第一行方框的距离
BOT_PAD = 18

def band(label, fill, stroke, color, rows, gaps=None):
    """rows: [[(title, lines, width), ...], ...]；gaps: 每行方框间距。返回 (每行方框几何, 层顶 y, 层底 y)。"""
    row_hs = [max(box_h(ls) for _, ls, _ in row) for row in rows]
    # 每行按最宽的那一行等比拉伸宽度，避免出现大片空白
    def gaps_of(ri, n):
        gs = gaps[ri] if gaps and gaps[ri] is not None else None
        return [(gs[i] if gs and i < len(gs) and gs[i] is not None else (18 if n > 4 else 30))
                for i in range(n)]
    widths = [[w for _, _, w in row] for row in rows]
    gsets = [gaps_of(ri, len(row)) for ri, row in enumerate(rows)]
    spans = [sum(ws) + sum(g[:-1]) for ws, g in zip(widths, gsets)]
    target = max(spans)
    scale = [((target - sum(g[:-1])) / sum(ws)) if sum(ws) else 1.0
             for ws, g in zip(widths, gsets)]
    total = TOP + sum(row_hs) + ROW_GAP * (len(rows) - 1) + BOT_PAD
    d.rect(PAD, y, W - 2 * PAD, total, fill, stroke)
    d.text(PAD + 24, y + 30, label, 16, color, "700")
    pos, cy = [], y + TOP
    for ri, (row, rh) in enumerate(zip(rows, row_hs)):
        gs = gsets[ri]
        x, rp = PAD + 26, []
        for i, (title, lines, w) in enumerate(row):
            w2 = w * scale[ri]
            d.box(x, cy, w2, title, lines, stroke)
            rp.append((x, w2, box_h(lines)))
            x += w2 + gs[i]
        pos.append(rp)
        cy += rh + ROW_GAP
    return pos, y, y + total

def gap_arrow(x, y_from, y_to, label):
    mid = (y_from + y_to) / 2
    d.arrow(x, y_from, x, y_to, None)
    d.label(x, mid, label)

# ================= 1 入口层 =================
(p1, t1, b1) = band("入口层", "#eaf2fb", "#93b8e0", "#2c5282", [[
    ("main.swift", ["进程入口 · 单实例保护"], 340),
    ("DebugCLI", ["--selftest / --ax-* / --panel-* / --dict-test", "跑完即退，不启动常驻实例"], 440),
    ("AppDelegate", ["状态栏菜单 · 开机自启（LaunchAgent）", "唤醒与设备变化恢复 · Secure Input 监测"], 520),
]], gaps=[[120, 130]])
r = p1[0]
d.arrow(r[0][0] + r[0][1], r[0][2] / 2 + y + TOP, r[1][0], r[0][2] / 2 + y + TOP, "有 --flag")
d.arrow(r[1][0] + r[1][1], r[1][2] / 2 + y + TOP, r[2][0], r[1][2] / 2 + y + TOP, "常驻启动")
y = b1 + 48

# ================= 2 按键层 =================
rowA = [("KeyRemap", ["hidutil：Caps → F18"], 280),
        ("EventTapEngine", ["CGEventTap：吞掉 F18，其余键换算成 KeyCombo 查表"], 430)]
rowB = [("CapsState", ["单按 <300ms 切大小写　空档 300–600ms", "长按 ≥600ms 切输入法", "状态机 + 看门狗（防按住状态卡死）"], 350),
        ("Config · Chord", ["keymap.json 加载 / 热重载", "KeyCombo 键码表（键名 → keyCode）"], 400),
        ("Action 动作枚举", ["Action.swift", "名称 ↔ 动作的唯一映射"], 320)]
(p2, t2, b2) = band("KeyLayer　按键层", "#fff6e8", "#e5b483", "#9c5b1f", [rowA, rowB],
                    gaps=[[210, None], [80, 130]])
a, bb = p2
# 行内：KeyRemap → EventTapEngine
d.arrow(a[0][0] + a[0][1], a[0][2] / 2 + y + TOP, a[1][0], a[0][2] / 2 + y + TOP, "F18 keyDown/keyUp")
# 跨行：EventTapEngine → CapsState（F18 本身）/ Config（查 bindings）
rowB_y = y + TOP + a[0][2] + ROW_GAP
e_bottom = y + TOP + a[0][2]
mid_gap = (e_bottom + rowB_y) / 2
d.path([(a[1][0] + 120, e_bottom), (a[1][0] + 120, e_bottom + 18),
         (bb[0][0] + 175, e_bottom + 18), (bb[0][0] + 175, rowB_y)])
d.path([(a[1][0] + 350, e_bottom), (a[1][0] + 350, e_bottom + 42),
         (bb[1][0] + 200, e_bottom + 42), (bb[1][0] + 200, rowB_y)])
d.label((a[1][0] + 120 + bb[0][0] + 175) / 2, e_bottom + 18, "F18 本身")
d.label((a[1][0] + 350 + bb[1][0] + 200) / 2, e_bottom + 42, "查 bindings")
d.arrow(bb[1][0] + bb[1][1], rowB_y + 30, bb[2][0], rowB_y + 30, "命中")
y = b2 + 48

# ================= 3 动作层 =================
(p3, t3, b3) = band("Actions　动作层　（按 Action 派发；只用系统能力，不碰事件 tap）", "#f0f7ea", "#a8cd94", "#3f6b2e", [[
    ("TextActions", ["光标 / 选区 / 删除", "整行 / 下方插入行"], 320),
    ("TextTransform", ["大小写 · 命名风格", "JSON · 排序去重 · URL 编码"], 320),
    ("WindowActions", ["绑定 / 激活 / 平铺", "按标题 raise 具体窗口"], 320),
    ("ClipboardActions", ["cut / copy / paste", "粘贴为纯文本"], 300),
    ("TranslateActions", ["划词翻译", "离线 → 在线兜底"], 250),
]])
acts = p3[0]
y = b3 + 48

# ================= 4 系统能力层 =================
(p4, t4, b4) = band("Support　系统能力层　（AX 的属性读取原语只有一处，App 与探针共用同一条路径）",
                "#f3f0fb", "#b3a6dd", "#4c3d84",
                [[("AX", ["core · attribute · selection · window", "属性读取 / 选区 / 窗口 frame / 剪贴板兜底"], 450),
                  ("KeyPost", ["带标记的按键合成"], 250),
                  ("Clipboard", ["快照与还原（多 item）"], 280),
                  ("InputSource", ["输入源切换", "重启 IME 进程"], 280),
                  ("HIDCapsLock", ["IOHID 锁定状态"], 240)],
                 [("WindowStore", ["windows.json 窗口绑定"], 320),
                  ("SystemEvents · SecureInput", ["唤醒 / 设备变化通知 · 安全输入检测"], 500),
                  ("LoginItem · Log", ["开机自启 · 日志"], 300),
                  ("AudioPlayer", ["读音播放"], 220)]])
y = b4 + 48

# ================= 5 词典与浮层 =================
(p5, t5, b5) = band("词典与翻译　·　UI 浮层　（caps+t 触发，离线优先）", "#fdeef1", "#e3a3b3", "#9b2c42", [[
    ("OfflineDictionary", ["dict.sqlite：牛津 + 朗文", "10.4 万词条，带原始 HTML"], 440),
    ("TranslateService", ["有道 NMT（有凭据时）", "→ dict.youdao.com 兜底"], 420),
    ("TranslatePanel", ["WKWebView 渲染词典 HTML", "NSTextView 纯文本回退"], 420),
]], gaps=[[130, 130]])
dic = p5[0]
d.arrow(dic[0][0] + dic[0][1], dic[0][2] / 2 + y + TOP, dic[1][0], dic[0][2] / 2 + y + TOP, "未命中")
d.arrow(dic[1][0] + dic[1][1], dic[1][2] / 2 + y + TOP, dic[2][0], dic[1][2] / 2 + y + TOP, "渲染")

# ================= 跨层箭头 =================
app_x = p1[0][2][0] + p1[0][2][1] / 2
gap_arrow(app_x, b1, t2, "装配并启动")
act_x = bb[2][0] + bb[2][1] / 2
gap_arrow(act_x, b2, t3, "switch Action")
sup_x = (acts[0][0] + acts[4][0] + acts[4][1]) / 2
gap_arrow(sup_x, b3, t4, "合成按键 · AX · 剪贴板 · 输入源")
# 翻译动作 → 浮层：走右边缘（不穿其它层）
tr_x = acts[4][0] + acts[4][1] / 2
panel_x = dic[2][0] + dic[2][1] / 2
d.path([(tr_x, b3), (tr_x, b3 + 22), (W - PAD + 20, b3 + 22), (W - PAD + 20, b5 - 24),
        (panel_x, b5 - 24), (panel_x, b5 + 4)], "caps+t")

d.text(PAD, b5 + 34, "实线＝主调用链。KeyLayer 里 F18 本身的分支（单按/长按）与组合键查表是两条独立路径；"
                     "完整动作清单见 docs/ACTIONS.md。", 12.5, "#718096")

h = b5 + 56
open("docs/architecture.svg", "w").write(d.svg(h))
subprocess.run(["rsvg-convert", "-z", "2",
                "docs/architecture.svg",
                "-o", "docs/architecture.png"], check=True)
print("height", h)
