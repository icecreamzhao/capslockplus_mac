import AppKit

/// 菜单栏里的两行读数：上面一行小字标签（CPU / 内存），下面一行数值。
///
/// 为什么自己画而不是用 `button.title`：
/// NSStatusBarButton 只排一行文字，塞不下"标签在上、数值在下"，
/// 也没法让两列的标签正好压在两列的数值上方。
/// 这个视图盖在按钮上，自己画图标 + 两行文字，`hitTest` 返回 nil 让点击穿透到按钮。
final class StatusReadoutView: NSView {
    private enum Metrics {
        static let iconSize: CGFloat = 17
        static let iconGap: CGFloat = 5
        static let columnGap: CGFloat = 8
        static let labelFont = NSFont.systemFont(ofSize: 7.5, weight: .medium)
        static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        static let capsFont = NSFont.systemFont(ofSize: 7.5, weight: .bold)
        static let labelHeight: CGFloat = 9
        static let valueHeight: CGFloat = 12
    }

    var glyph: NSImage? {
        didSet { needsDisplay = true }
    }

    private var capsOn = false
    private var cpuText = ""
    private var memText = ""
    private var downText = ""
    private var upText = ""

    override var isFlipped: Bool { true }

    /// 点击交给 NSStatusBarButton 处理，否则菜单打不开
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(caps: Bool, cpu: String, mem: String, down: String = "", up: String = "") {
        guard caps != capsOn || cpu != cpuText || mem != memText
                || down != downText || up != upText else { return }
        capsOn = caps
        cpuText = cpu
        memText = mem
        downText = down
        upText = up
        needsDisplay = true
    }

    // MARK: - 布局

    private struct Column {
        let label: String
        let value: String
        let labelFont: NSFont
        let width: CGFloat
    }

    private func columns() -> [Column] {
        var result: [Column] = []
        if capsOn {
            let width = textWidth("CAPS", font: Metrics.capsFont)
            result.append(Column(label: "CAPS", value: "", labelFont: Metrics.capsFont, width: width))
        }
        // 列宽必须按"最宽可能值"预留：8% → 16% → 100% 位数变化时若跟着算宽度，
        // 列位置和整个状态栏长度都会变，看起来就是数字在跳。
        if !cpuText.isEmpty {
            result.append(Column(label: "CPU", value: cpuText, labelFont: Metrics.labelFont,
                                 width: columnWidth(label: "CPU", reserves: Self.percentReserve)))
        }
        if !memText.isEmpty {
            result.append(Column(label: "内存", value: memText, labelFont: Metrics.labelFont,
                                 width: columnWidth(label: "内存", reserves: Self.percentReserve)))
        }
        if !downText.isEmpty {
            result.append(Column(label: "下载", value: downText, labelFont: Metrics.labelFont,
                                 width: columnWidth(label: "下载", reserves: Self.rateReserve)))
        }
        if !upText.isEmpty {
            result.append(Column(label: "上传", value: upText, labelFont: Metrics.labelFont,
                                 width: columnWidth(label: "上传", reserves: Self.rateReserve)))
        }
        return result
    }

    /// 需要的总宽度：图标 + 各列 + 列间距
    func requiredWidth() -> CGFloat {
        let list = columns()
        let columnsWidth = list.reduce(CGFloat(0)) { $0 + $1.width }
            + CGFloat(max(list.count - 1, 0)) * Metrics.columnGap
        let content = Metrics.iconSize + Metrics.iconGap + columnsWidth
        return ceil(content + 6)          // 两侧各留 3pt，别贴着图标
    }

    /// 列宽只看标签和最坏情况的数值样本，**不看当前值** ——
    /// 否则 8% → 16% → 100% 时列宽变化，整条状态栏会跟着抖。
    private func columnWidth(label: String, reserves: [String]) -> CGFloat {
        let labelWidth = textWidth(label, font: Metrics.labelFont)
        let valueWidth = reserves.map { textWidth($0, font: Metrics.valueFont) }.max() ?? 0
        return ceil(max(labelWidth, valueWidth))
    }

    private static let percentReserve = ["100%"]
    private static let rateReserve = ["999M", "1.0G", "9.9K"]

    private func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        let height = bounds.height
        let blockHeight = Metrics.labelHeight + Metrics.valueHeight
        let top = max((height - blockHeight) / 2, 0)

        var x: CGFloat = 3
        if let glyph {
            let iconRect = NSRect(x: x, y: (height - Metrics.iconSize) / 2,
                                  width: Metrics.iconSize, height: Metrics.iconSize)
            tinted(glyph).draw(in: iconRect)
            x += Metrics.iconSize + Metrics.iconGap
        }

        for column in columns() {
            draw(text: column.label, font: column.labelFont, color: column.labelFont === Metrics.capsFont
                 ? .systemOrange : .secondaryLabelColor,
                 rect: NSRect(x: x, y: top, width: column.width, height: Metrics.labelHeight),
                 rightAligned: true)
            if !column.value.isEmpty {
                draw(text: column.value, font: Metrics.valueFont, color: .labelColor,
                     rect: NSRect(x: x, y: top + Metrics.labelHeight, width: column.width,
                                  height: Metrics.valueHeight), rightAligned: true)
            }
            x += column.width + Metrics.columnGap
        }
    }

    private func draw(text: String, font: NSFont, color: NSColor, rect: NSRect, rightAligned: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = rightAligned ? .right : .left
        paragraph.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }

    /// 模板图按菜单栏当前前景色重画（深色菜单栏变白，浅色变黑）
    private func tinted(_ image: NSImage) -> NSImage {
        guard image.isTemplate else { return image }
        return NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            NSColor.controlTextColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
