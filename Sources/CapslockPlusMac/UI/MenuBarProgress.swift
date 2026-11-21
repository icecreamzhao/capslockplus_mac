import AppKit

/// 菜单栏转换进度：直接替换状态栏图标，画一根进度条。
///
/// 为什么不复用中间那个 HUD：HUD 是为了"看一眼就走"的瞬时反馈设计的，
/// 转一个长录屏要几十秒，中间一直有块板子糊在屏幕正中最碍事。
/// 状态栏只有一个 22×14 的位置，正好放进度。
///
/// 两种形态：
///   - 知道总时长（ffprobe 拿得到）→ 实心条按百分比填充
///   - 拿不到时长 → 一段 45% 宽的色块来回滑动（不定态）
final class MenuBarProgress {
    static let shared = MenuBarProgress()

    private weak var item: NSStatusItem?
    private var originalImage: NSImage?
    private var timer: Timer?
    private var phase: Double = 0
    private var fraction: Double?
    private var label = "转换中"

    var isActive: Bool { timer != nil || fraction != nil }

    /// AppDelegate 建好 NSStatusItem 后调一次，之后 GifTool 直接用单例。
    func attach(_ statusItem: NSStatusItem) {
        item = statusItem
        originalImage = statusItem.button?.image
    }

    func start(label: String = "转换中") {
        guard let button = item?.button else { return }
        self.label = label
        fraction = nil
        phase = 0
        if originalImage == nil { originalImage = button.image }
        timer?.invalidate()
        let ticker = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            self?.advance()
        }
        // .common：菜单展开时 run loop 会切到事件跟踪模式，用 .default 加进去动画会停
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
        redraw()
    }

    /// 0...1；调用后停掉滑动动画，改为按比例填充。
    func update(_ value: Double) {
        fraction = min(max(value, 0), 1)
        timer?.invalidate()
        timer = nil
        redraw()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        fraction = nil
        item?.button?.image = originalImage
        item?.button?.toolTip = "Capslock+"
    }

    // MARK: - 绘制

    private func advance() {
        phase += 0.05
        redraw()
    }

    private func redraw() {
        guard let button = item?.button else { return }
        button.image = Self.image(fraction: fraction, phase: phase)
        button.toolTip = fraction.map { "\(label) \(Int(($0 * 100).rounded()))%" } ?? label
    }

    /// 24×14 的条：菜单栏高度就 22pt，再大就会被切。
    static func image(fraction: Double?, phase: Double) -> NSImage {
        let size = NSSize(width: 24, height: 14)
        return NSImage(size: size, flipped: false) { rect in
            let track = NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 4),
                                     xRadius: 3.5, yRadius: 3.5)
            NSColor.tertiaryLabelColor.withAlphaComponent(0.45).setFill()
            track.fill()

            let inner = rect.insetBy(dx: 3, dy: 5.5)
            let bar: NSRect
            if let fraction {
                bar = NSRect(x: inner.minX, y: inner.minY,
                             width: max(inner.width * CGFloat(fraction), 2),
                             height: inner.height)
            } else {
                let width = inner.width * 0.45
                let travel = inner.width - width
                let x = inner.minX + CGFloat(phase.truncatingRemainder(dividingBy: 1)) * travel
                bar = NSRect(x: x, y: inner.minY, width: width, height: inner.height)
            }
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
            return true
        }
    }
}
