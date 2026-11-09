import Foundation
import AppKit
import WebKit

/// 面板里的按钮要在 App 未激活时也能一次点中
final class PanelButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 查词浮层：无边框、不激活 App、贴鼠标位置。
///
/// 两种渲染模式：
///   · HTML 模式（默认）—— 用 WKWebView 直接渲染词典原始词条，颜色/表格/图片/自定义字体都保留
///   · 文本模式 —— NSTextView 显示抽取出的纯文本（词库没有 HTML 列时自动回退）
///
/// 关闭方式：再按一次热键 / 点 ✕ / Esc；是否定时自动关由 `panelAutoHideMs` 决定（默认不关）。
final class TranslatePanel: NSPanel, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = TranslatePanel()

    private let effectView = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let bodyTextView = NSTextView()
    private var bodyWebView: WKWebView!
    private let speakerButton = PanelButton()
    private let closeButton = PanelButton()
    private var dismissTimer: Timer?
    private var keyMonitor: Any?
    private var isShown = false
    private var audioPath: String?
    /// 显示浮层前的前台 App；关掉时要还给它，否则点了浮层再打字会没地方去
    private var previousApp: NSRunningApplication?

    /// 当前是不是 HTML 模式（决定 selectionText 从哪儿读）
    private var renderModeIsHTML = false
    /// WKWebView 里划选的文字（由 selectionchange 脚本推上来）
    private var webSelection: String?
    private var currentHTMLHeight: CGFloat = 0

    private let width: CGFloat = 460
    private let padding: CGFloat = 14
    private let bodyFont = NSFont.systemFont(ofSize: 13)
    private let headerHeight: CGFloat = 26
    private let maxHTMLHeight: CGFloat = 520

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 120),
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

        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        // 划选变化即时推回 Swift，caps+t 换词时才能同步读到
        let selectionScript = """
        document.addEventListener('selectionchange', function () {
            var text = window.getSelection().toString();
            window.webkit.messageHandlers.sel.postMessage(text || '');
        });
        """
        controller.addUserScript(WKUserScript(source: selectionScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.add(self, name: "sel")
        configuration.userContentController = controller
        configuration.suppressesIncrementalRendering = false

        bodyWebView = WKWebView(frame: .zero, configuration: configuration)
        bodyWebView.navigationDelegate = self
        bodyWebView.setValue(false, forKey: "drawsBackground")
        bodyWebView.wantsLayer = true
        bodyWebView.layer?.cornerRadius = 8
        bodyWebView.layer?.masksToBounds = true
        if #available(macOS 12.0, *) {
            bodyWebView.underPageBackgroundColor = .clear
        }
        bodyWebView.isHidden = true

        speakerButton.isBordered = false
        speakerButton.bezelStyle = .inline
        speakerButton.imagePosition = .imageOnly
        speakerButton.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "播放读音")
        speakerButton.contentTintColor = .secondaryLabelColor
        speakerButton.target = self
        speakerButton.action = #selector(playAudio)
        speakerButton.isHidden = true

        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭")
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closePanel)
        // 未激活时第一下点击也要立刻生效，不等 mouseUp
        closeButton.sendAction(on: [.leftMouseDown])
        speakerButton.sendAction(on: [.leftMouseDown])

        effectView.addSubview(titleLabel)
        effectView.addSubview(subtitleLabel)
        effectView.addSubview(bodyTextView)
        effectView.addSubview(bodyWebView)
        effectView.addSubview(speakerButton)
        effectView.addSubview(closeButton)
        contentView = effectView
    }

    // 需要能划选文字，所以允许成为 key；.nonactivatingPanel 保证不激活整个 App、不切 Space
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var isShowing: Bool { isShown }

    // MARK: - 对外接口

    func showPending(query: String) {
        renderText(title: query, subtitle: "查询中…", body: "", keepPosition: updatingInPlace)
    }

    func show(result: Translation) {
        renderText(title: result.query, subtitle: "在线 · " + result.engine, body: result.displayText,
                   keepPosition: updatingInPlace)
    }

    private var updatingInPlace: Bool { isShown }

    func show(entry: DictEntry, audio: String?) {
        let useHTML = Config.shared.panelRenderMode == "html" && entry.html != nil
        if useHTML, let html = entry.html {
            renderHTML(entry: entry, html: html, audio: audio, keepPosition: updatingInPlace)
            return
        }
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
        renderText(title: entry.headword, subtitle: subtitle, body: lines.joined(separator: "\n"),
                   audio: audio, keepPosition: updatingInPlace)
    }

    func showHint(_ text: String) {
        renderText(title: "caps+t", subtitle: "", body: text)
    }

    func show(error: String) {
        renderText(title: "没有结果", subtitle: "", body: error)
    }

    /// 浮层正文里划选的文字；没有选区返回 nil。
    var selectionText: String? {
        if renderModeIsHTML {
            guard let text = webSelection else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let range = bodyTextView.selectedRanges.first?.rangeValue,
              range.length > 0, range.location != NSNotFound else { return nil }
        let text = (bodyTextView.string as NSString).substring(with: range)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        guard isShown else { return }
        let hadFocus = isKeyWindow || NSApp.isActive
        // 划选状态留着没意义，下次开是新的词
        bodyTextView.setSelectedRange(NSRange(location: 0, length: 0))
        if renderModeIsHTML {
            bodyWebView.evaluateJavaScript("window.getSelection().removeAllRanges()", completionHandler: nil)
        }
        webSelection = nil
        orderOut(nil)
        isShown = false
        if hadFocus {
            // 点过浮层就等于把键盘焦点拿走了，关掉时还回原来的 App
            previousApp?.activate(options: [])
        }
        previousApp = nil
        Log.info("panel hidden restoredFocus=\(hadFocus ? 1 : 0)")
    }

    // MARK: - 渲染：文本模式

    private func renderText(title: String, subtitle: String, body: String, audio: String? = nil, keepPosition: Bool = false) {
        audioPath = audio
        renderModeIsHTML = false
        webSelection = nil
        bodyWebView.isHidden = true
        bodyWebView.stopLoading()
        bodyTextView.isHidden = false

        titleLabel.isHidden = false
        subtitleLabel.isHidden = subtitle.isEmpty
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

        let anchor = (x: frame.origin.x, top: frame.maxY)
        setFrame(NSRect(x: 0, y: 0, width: width, height: height), display: true)

        var top = height - padding
        let closeSize: CGFloat = 18
        let closeX = width - padding - closeSize
        let titleWidth = textWidth - 24 - (audio == nil ? 0 : 22)
        titleLabel.frame = NSRect(x: padding, y: top - titleHeight, width: titleWidth, height: titleHeight)
        closeButton.frame = NSRect(x: closeX, y: top - titleHeight + 2, width: closeSize, height: closeSize)
        if audio != nil {
            speakerButton.frame = NSRect(x: closeX - 22, y: top - titleHeight + 2, width: closeSize, height: closeSize)
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

        finishLayout(anchor: anchor, keepPosition: keepPosition)
        Log.info("panel shown mode=text title=\(title) h=\(Int(height))")
    }

    // MARK: - 渲染：HTML 模式

    private func renderHTML(entry: DictEntry, html: String, audio: String?, keepPosition: Bool) {
        audioPath = audio
        renderModeIsHTML = true
        webSelection = nil
        bodyTextView.isHidden = true
        bodyWebView.isHidden = false

        // HTML 词条自带词头和音标，顶部只留按钮，不再重复显示标题
        titleLabel.isHidden = true
        subtitleLabel.isHidden = true
        speakerButton.isHidden = (audio == nil)

        let assetsDirectory = DictEntry.assetsDirectory(for: entry.source)
        let document = wrap(html: html, stylesheet: entry.stylesheet, assetsDirectory: assetsDirectory)
        let tempFile = (assetsDirectory as NSString).appendingPathComponent("__panel-entry.html")

        guard FileManager.default.fileExists(atPath: assetsDirectory),
              (try? document.write(toFile: tempFile, atomically: true, encoding: .utf8)) != nil else {
            Log.warn("panel html unavailable reason=assets-missing source=\(entry.source)")
            // 资源不在就退回纯文本
            let lines = entry.lines.map { $0.replacingOccurrences(of: "\t", with: "  ") }
            var subtitle = entry.sourceLabel
            if let phonetic = entry.phonetic, !phonetic.isEmpty {
                subtitle = "/\(phonetic)/  ·  " + subtitle
            }
            renderText(title: entry.headword, subtitle: subtitle, body: lines.joined(separator: "\n"),
                       audio: audio, keepPosition: keepPosition)
            return
        }

        currentHTMLHeight = 0
        layoutHTML(htmlHeight: 160, keepPosition: keepPosition)
        bodyWebView.loadFileURL(URL(fileURLWithPath: tempFile),
                                allowingReadAccessTo: URL(fileURLWithPath: assetsDirectory))
        Log.info("panel shown mode=html title=\(entry.headword) source=\(entry.source) html=\(html.count)")
    }

    /// 词条 HTML 可能自带 <head>（牛津），也可能没有（朗文，要在外层补样式表）
    private func wrap(html: String, stylesheet: String?, assetsDirectory: String) -> String {
        var head = ""
        var body = html
        if let range = html.range(of: "</head>", options: .caseInsensitive) {
            head = String(html[html.startIndex..<range.upperBound])
                .replacingOccurrences(of: "<head>", with: "", options: .caseInsensitive)
            body = String(html[range.upperBound...])
        } else if let stylesheet = stylesheet {
            head = "<link rel=\"stylesheet\" type=\"text/css\" href=\"\(stylesheet)\" />"
        }

        // 词典样式是浅色纸面，浮层里做成白色卡片；顺带压一下超宽图片
        let override = """
        <style>
          :root { color-scheme: light; }
          html, body { background: #ffffff; margin: 0; padding: 12px 14px; }
          body { font-size: 13.5px; -webkit-text-size-adjust: 100%; }
          img, svg { max-width: 100%; height: auto; }
          ::selection { background: rgba(0, 122, 255, .22); }
          ::-webkit-scrollbar { width: 8px; height: 8px; }
          ::-webkit-scrollbar-thumb { background: rgba(0,0,0,.18); border-radius: 4px; }
        </style>
        """
        return "<!doctype html><html><head><meta charset=\"utf-8\">\(head)\(override)</head><body>\(body)</body></html>"
    }

    private func layoutHTML(htmlHeight: CGFloat, keepPosition: Bool) {
        currentHTMLHeight = min(max(htmlHeight, 90), maxHTMLHeight)
        let height = headerHeight + currentHTMLHeight + padding
        let anchor = (x: frame.origin.x, top: frame.maxY)
        setFrame(NSRect(x: 0, y: 0, width: width, height: height), display: true)

        let closeSize: CGFloat = 18
        let closeX = width - padding - closeSize
        let top = height - padding
        closeButton.frame = NSRect(x: closeX, y: top - closeSize + 3, width: closeSize, height: closeSize)
        if audioPath != nil {
            speakerButton.frame = NSRect(x: closeX - 22, y: top - closeSize + 3, width: closeSize, height: closeSize)
        }
        bodyWebView.frame = NSRect(x: 8, y: 8, width: width - 16, height: height - headerHeight - 8)

        finishLayout(anchor: anchor, keepPosition: keepPosition)
    }

    // MARK: - WKNavigationDelegate / WKScriptMessageHandler

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)") { [weak self] result, _ in
            guard let self = self, self.renderModeIsHTML else { return }
            let measured = (result as? NSNumber)?.doubleValue ?? 160
            guard abs(measured - Double(self.currentHTMLHeight)) > 2 else { return }
            self.layoutHTML(htmlHeight: CGFloat(measured), keepPosition: true)
            Log.info("panel html measured h=\(Int(measured))")
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "sel", let text = message.body as? String else { return }
        webSelection = text.isEmpty ? nil : text
    }

    // MARK: - 布局

    private func finishLayout(anchor: (x: CGFloat, top: CGFloat), keepPosition: Bool) {
        if !keepPosition || !isShown {
            positionNearCursor()
        } else {
            // 高度变了要保持"顶边不动"，否则内容变长时整块往下长
            setFrameOrigin(NSPoint(x: anchor.x, y: anchor.top - frame.height))
        }
        clampToVisibleScreen()
        if !isShown {
            previousApp = NSWorkspace.shared.frontmostApplication
            orderFrontRegardless()
            isShown = true
            installEscapeMonitor()
        }

        // 自动关闭时长由 keymap.json 的 panelAutoHideMs 决定，0 表示不自动关
        dismissTimer?.invalidate()
        dismissTimer = nil
        let autoHideMs = Config.shared.panelAutoHideMs
        if autoHideMs > 0 {
            dismissTimer = Timer.scheduledTimer(withTimeInterval: Double(autoHideMs) / 1000.0, repeats: false) { [weak self] _ in
                self?.dismiss()
            }
        }
    }

    /// 内容量完高度后会往下长；贴着屏幕底部时下半截会跑到屏幕外，这里把整块推回可视区
    private func clampToVisibleScreen() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var origin = frame.origin
        if frame.maxY > visible.maxY { origin.y = visible.maxY - frame.height }
        if origin.y < visible.minY { origin.y = visible.minY }
        if frame.maxX > visible.maxX { origin.x = visible.maxX - frame.width }
        if origin.x < visible.minX { origin.x = visible.minX }
        guard origin != frame.origin else { return }
        setFrameOrigin(origin)
        Log.info("panel clamped origin=\(Int(origin.x)),\(Int(origin.y)) h=\(Int(frame.height))")
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

    /// Esc 关闭（浮层是 key 的时候才收得到本地按键）。
    private func installEscapeMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.dismiss()
            return nil
        }
    }

    var debugOrigin: NSPoint { frame.origin }

    /// 自检用：浮层顶边（内容变长时该值必须不变，否则整块会跳）
    var debugTop: CGFloat { frame.maxY }

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

    /// 自检用：HTML 模式下程序化全选，等 selectionchange 推回来再读。
    func debugSelectAllWeb(timeout: Double = 2.0) -> String {
        makeKeyAndOrderFront(nil)
        var report = "key=\(isKeyWindow ? 1 : 0) html=\(renderModeIsHTML ? 1 : 0) h=\(Int(currentHTMLHeight))"
        guard renderModeIsHTML else { return report + " picked=nil" }

        var finished = false
        bodyWebView.evaluateJavaScript("document.body.innerText.length") { result, _ in
            report += " textLen=\(String(describing: result))"
            finished = true
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !finished, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        bodyWebView.evaluateJavaScript("""
        (function () {
            var range = document.createRange();
            range.selectNodeContents(document.body);
            var sel = window.getSelection();
            sel.removeAllRanges();
            sel.addRange(range);
            return sel.toString().length;
        })()
        """) { _, _ in }

        let waitUntil = Date().addingTimeInterval(timeout)
        while Date() < waitUntil, webSelection == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let picked = selectionText ?? "nil"
        report += " picked=\(picked.prefix(40))"
        return report
    }

    @objc private func closePanel() {
        Log.info("panel closed by button")
        dismiss()
    }

    @objc private func playAudio() {
        guard let path = audioPath else { return }
        AudioPlayer.shared.play(relativePath: path)
    }
}
