import AppKit

/// 菜单栏进度条的"纯几何 + 绘制"部分，不含任何状态。
///
/// 单独抽出来是为了三件事：
///   1. 几何能纯函数断言（`--progress-selftest`），不用截图比对像素
///   2. 别的地方要进度条（导出、下载、批处理）直接拿 `image(fraction:phase:)` 渲染
///   3. 想换成别的容器（状态栏 / HUD 里的小条）时，只换宿主，不动画法
enum ProgressGlyph {
    struct Metrics {
        /// 菜单栏只有 22pt 高，再大就被切
        var size = NSSize(width: 24, height: 14)
        var inset = NSEdgeInsets(top: 4, left: 1.5, bottom: 4, right: 1.5)
        var trackAlpha: CGFloat = 0.45
        /// 不定态色块宽度（占可用宽度的比例）
        var marqueeWidth: Double = 0.45
        /// 进度为 0 时也留一点可见宽度，否则看起来像没开始
        var minFill: CGFloat = 2
        var cornerRadius: CGFloat = 3.5
    }

    static func trackRect(in rect: NSRect, metrics: Metrics = Metrics()) -> NSRect {
        NSRect(x: rect.minX + metrics.inset.left,
               y: rect.minY + metrics.inset.bottom,
               width: max(rect.width - metrics.inset.left - metrics.inset.right, 0),
               height: max(rect.height - metrics.inset.top - metrics.inset.bottom, 0))
    }

    /// 已知进度：从左侧填充。超界值夹紧，0 也保留 `minFill` 宽度。
    static func fillRect(fraction: Double, in rect: NSRect, metrics: Metrics = Metrics()) -> NSRect {
        let clamped = min(max(fraction, 0), 1)
        let width = max(rect.width * CGFloat(clamped), metrics.minFill)
        return NSRect(x: rect.minX, y: rect.minY, width: min(width, rect.width), height: rect.height)
    }

    /// 不定态：一段固定宽度的色块在轨道内从 0 滑到 1（phase 取小数部分）。
    static func marqueeRect(phase: Double, in rect: NSRect, metrics: Metrics = Metrics()) -> NSRect {
        let width = rect.width * CGFloat(metrics.marqueeWidth)
        let travel = max(rect.width - width, 0)
        let wrapped = phase.truncatingRemainder(dividingBy: 1)
        let normalized = wrapped < 0 ? wrapped + 1 : wrapped
        return NSRect(x: rect.minX + CGFloat(normalized) * travel,
                      y: rect.minY, width: width, height: rect.height)
    }

    static func image(fraction: Double?, phase: Double,
                      size: NSSize? = nil,
                      tint: NSColor = .controlAccentColor) -> NSImage {
        let metrics = Metrics()
        let canvas = size ?? metrics.size
        return NSImage(size: canvas, flipped: false) { rect in
            let track = trackRect(in: rect, metrics: metrics)
            NSColor.tertiaryLabelColor.withAlphaComponent(metrics.trackAlpha).setFill()
            NSBezierPath(roundedRect: track,
                         xRadius: metrics.cornerRadius, yRadius: metrics.cornerRadius).fill()

            let bar = fraction.map { fillRect(fraction: $0, in: track, metrics: metrics) }
                ?? marqueeRect(phase: phase, in: track, metrics: metrics)
            tint.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
            return true
        }
    }
}
