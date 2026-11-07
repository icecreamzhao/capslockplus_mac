import Foundation
import AppKit

/// 查词浮层：无边框、不激活 App、贴鼠标位置。
/// 正文用 NSTextView，可以划选单词、复制；关闭方式：再按一次热键 / 点浮层外 / 12 秒后自动消失。
final class TranslatePanel: NSPanel {
    static let shared = TranslatePanel()

    private let effectView = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let bodyTextView = NSTextView()
    private let speakerButton = NSButton()
    private var dismissTimer: Timer?
    private var clickMonitor: Any?
    private var isShown = false
    private var audioPath: String?
    /// 显示浮层前的前台 App；关掉时要还给它，否则点了浮层再打字会没地方去
    private var previousApp: NSRunningApplication?

    private let width: CGFloat = 380
    private let padding: CGFloat = 14
    private let bodyFont = NSFont.systemFont(ofSize: 13)

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        ignoresMouseEvents = false

        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true

        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isSelectable = true

        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail

        bodyTextView.isEditable = false
        bodyTextView.isSelectable = true
        bodyTextView.drawsBackground = false
        bodyTextView.isRichText = false
        bodyTextView.font = bodyFont
        bodyTextView.textColor = .secondaryLabelColor
        bodyTextView.textContainerInset = NSSize(width: 0, height: 0)
        bodyTextView.isVerticallyResizable = true
        bodyTextView.isHorizontallyResizable = false
        bodyTextView.textContainer?.lineFragmentPadding = 0
        bodyTextView.textContainer?.widthTracksTextView = true
        bodyTextView.textContainer?.heightTracksTextView = false

        speakerButton.isBordered = false
        speakerButton.bezelStyle = .inline
        speakerButton.imagePosition = .imageOnly
        speakerButton.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "播放读音")
        speakerButton.contentTintColor = .secondaryLabelColor
        speakerButton.target = self
        speakerButton.action = #selector(playAudio)
        speakerButton.isHidden = true

        effectView.addSubview(titleLabel)
        effectView.addSubview(subtitleLabel)
        effectView.addSubview(bodyTextView)
        effectView.addSubview(speakerButton)
        contentView = effectView
    }

    // 需要能划选文字，所以允许成为 key；.nonactivatingPanel 保证不激活整个 App、不切 Space
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var isShowing: Bool { isShown }

    // MARK: - 对外接口

    func showPending(query: String) {
        render(title: query, subtitle: "查询中…", body: "", keepPosition: updatingInPlace)
    }

    func show(result: Translation) {
        render(title: result.query, subtitle: "在线 · " + result.engine, body: result.displayText,
               keepPosition: updatingInPlace)
    }

    private var updatingInPlace: Bool { isShown }

    func show(entry: DictEntry, audio: String?) {
        var subtitle = entry.sourceLabel
        if let phonetic = entry.phonetic, !phonetic.isEmpty {
            subtitle = "/\(phonetic)/  ·  " + subtitle
        }
        let lines = entry.lines.map { line -> String in
            if line.hasPrefix("例\t") {
                return "例  " + String(line.dropFirst(2))
            }
            return line.replacingOccurrences(of: "\t", with: "  ")
        }
        render(title: entry.headword, subtitle: subtitle, body: lines.joined(separator: "\n"),
               audio: audio, keepPosition: updatingInPlace)
    }

    func showHint(_ text: String) {
        render(title: "caps+t", subtitle: "", body: text)
    }

    func show(error: String) {
        render(title: "没有结果", subtitle: "", body: error)
    }

    /// 浮层正文里划选的文字；没有选区返回 nil。
    var selectionText: String? {
        guard let range = bodyTextView.selectedRanges.first?.rangeValue,
              range.length > 0, range.location != NSNotFound else { return nil }
        let text = (bodyTextView.string as NSString).substring(with: range)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        guard isShown else { return }
        let hadFocus = isKeyWindow || NSApp.isActive
        // 划选状态留着没意义，下次开是新的词
        bodyTextView.setSelectedRange(NSRange(location: 0, length: 0))
        orderOut(nil)
        isShown = false
        if hadFocus {
            // 点过浮层就等于把键盘焦点拿走了，关掉时还回原来的 App
            previousApp?.activate(options: [])
        }
        previousApp = nil
        Log.info("panel hidden restoredFocus=\(hadFocus ? 1 : 0)")
    }

    // MARK: - 布局

    private func render(title: String, subtitle: String, body: String, audio: String? = nil, keepPosition: Bool = false) {
        audioPath = audio
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        bodyTextView.string = body
        bodyTextView.setSelectedRange(NSRange(location: 0, length: 0))
        speakerButton.isHidden = (audio == nil)

        let textWidth = width - padding * 2
        let bodyHeight = body.isEmpty ? 0 : measure(body, font: bodyFont, width: textWidth)
        let titleHeight: CGFloat = 21
        let subtitleHeight: CGFloat = subtitle.isEmpty ? 0 : 14
        let spacing: CGFloat = (body.isEmpty || subtitleHeight == 0) ? 0 : 6

        var height = padding * 2 + titleHeight + subtitleHeight + spacing + bodyHeight
        height = max(height, 58)
        // 先记住原位置再改 frame：setFrame 会把 origin 打回 (0,0)，
        // 之前顺序反了，结果第二次渲染（结果回来）时浮层跳到左下角
        let previousOrigin = frame.origin
        setFrame(NSRect(x: 0, y: 0, width: width, height: height), display: true)

        var top = height - padding
        let titleWidth = textWidth - (audio == nil ? 0 : 24)
        titleLabel.frame = NSRect(x: padding, y: top - titleHeight, width: titleWidth, height: titleHeight)
        if audio != nil {
            speakerButton.frame = NSRect(x: width - padding - 18, y: top - titleHeight + 2, width: 18, height: 18)
        }
        top -= titleHeight
        if subtitleHeight > 0 {
            subtitleLabel.frame = NSRect(x: padding, y: top - subtitleHeight, width: textWidth, height: subtitleHeight)
            top -= subtitleHeight + spacing
        }
        if bodyHeight > 0 {
            bodyTextView.frame = NSRect(x: padding, y: padding, width: textWidth, height: bodyHeight)
            bodyTextView.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        }

        if !keepPosition || !isShown {
            positionNearCursor()
        } else {
            setFrameOrigin(previousOrigin)
        }
        if !isShown {
            previousApp = NSWorkspace.shared.frontmostApplication
            orderFrontRegardless()
            isShown = true
            installClickMonitor()
        }

        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
        Log.info("panel shown title=\(title) h=\(Int(height)) audio=\(audio == nil ? 0 : 1)")
    }

    private func measure(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }

    private func positionNearCursor() {
        let mouse = NSEvent.mouseLocation
        let size = frame.size
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else {
            setFrameOrigin(mouse)
            return
        }
        let visible = screen.visibleFrame
        var x = mouse.x + 12
        var y = mouse.y - size.height - 12
        if x + size.width > visible.maxX { x = visible.maxX - size.width - 8 }
        if x < visible.minX { x = visible.minX + 8 }
        if y < visible.minY { y = mouse.y + 16 }
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func installClickMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self = self else { return }
            // 点在浮层自己身上时别关（点喇叭会先把自己关掉）
            if self.frame.contains(NSEvent.mouseLocation) { return }
            self.dismiss()
        }
    }

    var debugOrigin: NSPoint { frame.origin }

    /// 自检用：程序化全选正文，再按正常路径读选区，验证 NSTextView 这条路通。
    func debugSelectAllBody() -> String {
        makeKeyAndOrderFront(nil)
        let became = makeFirstResponder(bodyTextView)
        var report = "key=\(isKeyWindow ? 1 : 0) became=\(became)"
        let length = (bodyTextView.string as NSString).length
        bodyTextView.setSelectedRange(NSRange(location: 0, length: length))
        report += " firstResponder=\(String(describing: firstResponder.map { type(of: $0) }))"
        report += " picked=\(String(describing: selectionText))"
        return report
    }

    @objc private func playAudio() {
        guard let path = audioPath else { return }
        AudioPlayer.shared.play(relativePath: path)
    }
}
