import Foundation
import AppKit
import WebKit

/// 面板里的按钮要在 App 未激活时也能一次点中
final class PanelButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 来源切换小胶囊：无边框自绘底色，宽度跟着标题走
private final class SourceButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize {
        let title = attributedTitle.size()
        return NSSize(width: ceil(title.width) + 14, height: max(ceil(title.height) + 4, 20))
    }
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
    private let sourceStack = NSStackView()
    private var dismissTimer: Timer?
    private var keyMonitor: Any?
    private var isShown = false
    private var audioPath: String?
    /// 当前词条的资源目录（dict-assets/<source>/），sound:// 音频从这里找
    private var currentAssetsDirectory: String?
    /// 最近一次 sound:// 点击的结果，调试/自检用
    private(set) var lastSoundURL: String?
    private(set) var lastSoundPlayed = false
    /// 当前 HTML 是否已经 didFinish（音频自检要等它）
    private(set) var htmlDidLoad = false
    /// 一次查词命中的全部词典，以及当前显示的是第几本
    private var currentEntries: [DictEntry] = []
    private var currentIndex = 0
    private var currentAudio: String?
    /// 显示浮层前的前台 App；关掉时要还给它，否则点了浮层再打字会没地方去
    private var previousApp: NSRunningApplication?

    /// 当前是不是 HTML 模式（决定 selectionText 从哪儿读）
    private var renderModeIsHTML = false
    /// WKWebView 里划选的文字（由 selectionchange 脚本推上来）
    private var webSelection: String?
    private var currentHTMLHeight: CGFloat = 0

    private let baseWidth: CGFloat = 460
    private var width: CGFloat = 460
    private let padding: CGFloat = 14
    private let bodyFont = NSFont.systemFont(ofSize: 13)
    private let headerHeight: CGFloat = 26
    private let sourceRowHeight: CGFloat = 22
    private let sourceRowGap: CGFloat = 6
    private var sourceRowWidth: CGFloat = 0
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

        sourceStack.orientation = .horizontal
        sourceStack.alignment = .centerY
        sourceStack.distribution = .fill
        sourceStack.spacing = 6
        sourceStack.wantsLayer = true
        sourceStack.layer?.masksToBounds = true
        sourceStack.isHidden = true

        effectView.addSubview(titleLabel)
        effectView.addSubview(subtitleLabel)
        effectView.addSubview(sourceStack)
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
        clearSourceEntries()
        renderText(title: query, subtitle: "查询中…", body: "", keepPosition: updatingInPlace)
    }

    func show(result: Translation) {
        clearSourceEntries()
        renderText(title: result.query, subtitle: "在线 · " + result.engine, body: result.displayText,
                   keepPosition: updatingInPlace)
    }

    private var updatingInPlace: Bool { isShown }

    func show(entry: DictEntry, audio: String?) {
        currentEntries = [entry]
        currentIndex = 0
        currentAudio = audio
        show(entry: entry, audio: audio, keepPosition: updatingInPlace)
    }

    /// 一次命中多本词典时，整张列表都交给面板，顶部提供来源切换。
    func show(entries: [DictEntry], audio: String?, query: String) {
        guard let first = entries.first else { return }
        currentEntries = entries
        currentIndex = 0
        currentAudio = audio
        show(entry: first, audio: first.audioPath ?? audio, keepPosition: updatingInPlace)
    }

    /// 切到列表里的第 index 本词典。点击来源按钮和 ⌘↑/⌘↓ 都走这里。
    func switchTo(index: Int) {
        guard currentEntries.indices.contains(index) else { return }
        guard index != currentIndex else { return }
        currentIndex = index
        let entry = currentEntries[index]
        Log.info("panel switch source=\(entry.source) index=\(index)")
        show(entry: entry, audio: entry.audioPath ?? currentAudio, keepPosition: true)
    }

    private func show(entry: DictEntry, audio: String?, keepPosition: Bool) {
        rebuildSourceRow()
        let useHTML = Config.shared.panelRenderMode == "html" && entry.html != nil
        if useHTML, let html = entry.html {
            renderHTML(entry: entry, html: html, audio: audio, keepPosition: keepPosition)
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
                   audio: audio, keepPosition: keepPosition)
    }

    func showHint(_ text: String) {
        clearSourceEntries()
        renderText(title: "caps+t", subtitle: "", body: text)
    }

    func show(error: String) {
        clearSourceEntries()
        renderText(title: "没有结果", subtitle: "", body: error)
    }

    private func clearSourceEntries() {
        currentEntries.removeAll()
        currentIndex = 0
        currentAudio = nil
        rebuildSourceRow()
    }

    /// 按 currentEntries 重建顶部来源按钮；只有一条命中时整行隐藏。
    private func rebuildSourceRow() {
        for view in sourceStack.arrangedSubviews {
            sourceStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard currentEntries.count > 1 else {
            sourceStack.isHidden = true
            sourceStack.frame = .zero
            sourceRowWidth = 0
            width = baseWidth
            return
        }

        sourceStack.isHidden = false
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        for (index, entry) in currentEntries.enumerated() {
            let selected = index == currentIndex
            let button = SourceButton()
            button.isBordered = false
            button.bezelStyle = .inline
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.layer?.masksToBounds = true
            button.layer?.backgroundColor = (selected ? NSColor.controlAccentColor
                : NSColor.labelColor.withAlphaComponent(0.14)).cgColor
            button.attributedTitle = NSAttributedString(string: entry.sourceLabel, attributes: [
                .font: font,
                .foregroundColor: selected ? NSColor.white : NSColor.labelColor,
            ])
            button.tag = index
            button.target = self
            button.action = #selector(selectSource(_:))
            button.toolTip = entry.sourceLabel
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            button.invalidateIntrinsicContentSize()
            sourceStack.addArrangedSubview(button)
        }

        sourceStack.layoutSubtreeIfNeeded()
        let buttonWidth = sourceStack.arrangedSubviews.reduce(CGFloat(0)) { $0 + $1.intrinsicContentSize.width }
        let gaps = CGFloat(max(0, currentEntries.count - 1)) * sourceStack.spacing
        let needed = max(ceil(sourceStack.fittingSize.width), ceil(buttonWidth + gaps))
        sourceRowWidth = needed
        // 10 本也全铺开：按钮按内容宽度收紧，面板不够宽就横向长一点
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let screenCap = max(baseWidth, (screen?.visibleFrame.width ?? 900) - 24)
        width = min(max(baseWidth, needed + padding * 2), screenCap)
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
        clearSourceEntries()
        currentAssetsDirectory = nil
        htmlDidLoad = false
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
        currentAssetsDirectory = nil
        htmlDidLoad = false
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
        let rowVisible = !sourceStack.isHidden
        let hasContentBelowSubtitle = bodyHeight > 0 || rowVisible
        let spacing: CGFloat = (hasContentBelowSubtitle && subtitleHeight > 0) ? 6 : 0
        let sourceExtra = rowVisible ? sourceRowHeight + (bodyHeight > 0 ? sourceRowGap : 0) : 0

        var height = padding * 2 + titleHeight + subtitleHeight + spacing + bodyHeight + sourceExtra
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
        if rowVisible {
            sourceStack.frame = NSRect(x: padding, y: top - sourceRowHeight,
                                       width: min(sourceRowWidth, textWidth), height: sourceRowHeight)
            top -= sourceRowHeight + (bodyHeight > 0 ? sourceRowGap : 0)
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
        currentAssetsDirectory = assetsDirectory
        htmlDidLoad = false

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
        let rowVisible = !sourceStack.isHidden
        // HTML 模式下 title/subtitle 是隐藏的，多留 8pt 给顶部关闭按钮，
        // 免得它和来源切换行叠在一起
        let sourceExtra = rowVisible ? sourceRowHeight + sourceRowGap + 8 : 0
        let height = headerHeight + sourceExtra + currentHTMLHeight + padding
        let anchor = (x: frame.origin.x, top: frame.maxY)
        setFrame(NSRect(x: 0, y: 0, width: width, height: height), display: true)

        let closeSize: CGFloat = 18
        let closeX = width - padding - closeSize
        let top = height - padding
        closeButton.frame = NSRect(x: closeX, y: top - closeSize + 3, width: closeSize, height: closeSize)
        if audioPath != nil {
            speakerButton.frame = NSRect(x: closeX - 22, y: top - closeSize + 3, width: closeSize, height: closeSize)
        }
        let bodyHeight = height - headerHeight - sourceExtra - 8
        bodyWebView.frame = NSRect(x: 8, y: 8, width: width - 16, height: bodyHeight)
        if rowVisible {
            sourceStack.frame = NSRect(x: padding, y: 8 + bodyHeight + sourceRowGap,
                                       width: min(sourceRowWidth, width - padding * 2), height: sourceRowHeight)
        }

        finishLayout(anchor: anchor, keepPosition: keepPosition)
    }

    // MARK: - WKNavigationDelegate / WKScriptMessageHandler

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        htmlDidLoad = true
        webView.evaluateJavaScript("Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)") { [weak self] result, _ in
            guard let self = self, self.renderModeIsHTML else { return }
            let measured = (result as? NSNumber)?.doubleValue ?? 160
            guard abs(measured - Double(self.currentHTMLHeight)) > 2 else { return }
            self.layoutHTML(htmlHeight: CGFloat(measured), keepPosition: true)
            Log.info("panel html measured h=\(Int(measured))")
        }
    }

    /// 面板里只允许原地加载资源；sound:// 和 entry:// 是词典自己的链接协议，拦下来自己处理。
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        switch url.scheme?.lowercased() {
        case "sound":
            decisionHandler(.cancel)
            playSound(url: url)
        case "entry":
            decisionHandler(.cancel)
            openEntry(url: url)
        case "file":
            decisionHandler(.allow)
        default:
            decisionHandler(.cancel)
        }
    }

    /// sound://ameProns/abandon1.mp3 → dict-assets/<source>/ameProns/abandon1.mp3；
    /// 只在 assets 目录里找，避免路径逃逸；找不到再按文件名下探 2 层。
    private func playSound(url: URL) {
        lastSoundURL = url.absoluteString
        lastSoundPlayed = false
        let encoded = (url.host ?? "") + url.path
        let decoded = encoded.removingPercentEncoding ?? encoded
        let relative = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded
        guard !relative.isEmpty else {
            Log.warn("dict audio missing url=\(url.absoluteString) reason=empty-path")
            return
        }
        guard let directory = currentAssetsDirectory else {
            Log.warn("dict audio missing url=\(url.absoluteString) reason=no-assets-dir")
            return
        }
        var file = (directory as NSString).appendingPathComponent(relative)
        if !FileManager.default.fileExists(atPath: file) {
            let name = (relative as NSString).lastPathComponent
            guard let found = findAsset(named: name, in: directory) else {
                Log.warn("dict audio missing url=\(url.absoluteString)")
                return
            }
            file = found
        }
        lastSoundPlayed = AudioPlayer.shared.play(file: file)
    }

    private func findAsset(named name: String, in directory: String) -> String? {
        guard let enumerator = FileManager.default.enumerator(atPath: directory) else { return nil }
        for case let relative as String in enumerator {
            let depth = relative.split(separator: "/").count
            guard depth <= 2 else { continue }
            let full = (directory as NSString).appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory), isDirectory.boolValue {
                if depth >= 2 { enumerator.skipDescendants() }
                continue
            }
            if (relative as NSString).lastPathComponent.caseInsensitiveCompare(name) == .orderedSame {
                return full
            }
        }
        return nil
    }

    /// entry://word（host 可能为空，形如 entry:///word）→ 命中就用这个词重开面板。
    private func openEntry(url: URL) {
        let host = url.host?.removingPercentEncoding ?? url.host ?? ""
        let path = url.path.removingPercentEncoding ?? url.path
        let word = (host.isEmpty ? path : host)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else {
            Log.warn("entry open failed reason=empty-word url=\(url.absoluteString)")
            return
        }
        let entries = OfflineDictionary.shared.lookup(word)
        guard !entries.isEmpty else {
            Log.warn("entry open miss word=\(word)")
            return
        }
        Log.info("entry open word=\(word) hits=\(entries.count)")
        show(entries: entries, audio: entries.first?.audioPath, query: word)
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

    /// Esc 关闭；⌘↑/⌘↓ 在多本词典之间切换（浮层是 key 的时候才收得到本地按键）。
    private func installEscapeMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 53 {
                self.dismiss()
                return nil
            }
            if event.modifierFlags.contains(.command), (event.keyCode == 126 || event.keyCode == 125),
               self.currentEntries.count > 1 {
                self.stepSource(event.keyCode == 126 ? -1 : 1)
                return nil
            }
            return event
        }
    }

    private func stepSource(_ delta: Int) {
        let count = currentEntries.count
        guard count > 1 else { return }
        switchTo(index: (currentIndex + delta + count) % count)
    }

    var debugOrigin: NSPoint { frame.origin }

    /// 自检用：来源切换行里的按钮数量、是否隐藏、当前选中项和正文。
    var debugSourceButtonCount: Int { sourceStack.arrangedSubviews.count }
    var debugSourceRowHidden: Bool { sourceStack.isHidden }
    var debugSelectedSourceIndex: Int { currentIndex }
    var debugBodyText: String { bodyTextView.string }

    /// 自检用：强行把浮层挪到屏幕外，再走一次 clamp，返回夹取后的 frame
    func debugForceOffscreenAndClamp() -> (before: NSRect, after: NSRect, visible: NSRect)? {
        guard let screen = NSScreen.main else { return nil }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(x: visible.maxX - 40, y: visible.minY - 180))
        let before = frame
        clampToVisibleScreen()
        return (before, frame, visible)
    }

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

    /// 自检用：等 HTML 加载完成后点第一个 sound:// 链接。
    /// nil = HTML 没加载完；false = 词条里没有 sound 链接；true = 已点击。
    func debugClickFirstSoundLink(timeout: Double = 3.0) -> Bool? {
        let loadedBy = Date().addingTimeInterval(timeout)
        while !htmlDidLoad, Date() < loadedBy {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard htmlDidLoad else { return nil }

        var clicked = false
        var finished = false
        bodyWebView.evaluateJavaScript("""
        (function () {
            var link = document.querySelector('a[href^="sound://"]');
            if (!link) { return 0; }
            link.click();
            return 1;
        })()
        """) { result, _ in
            clicked = (result as? NSNumber)?.intValue == 1
            finished = true
        }
        let jsBy = Date().addingTimeInterval(timeout)
        while !finished, Date() < jsBy {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return clicked
    }

    @objc private func closePanel() {
        Log.info("panel closed by button")
        dismiss()
    }

    @objc private func selectSource(_ sender: NSButton) {
        switchTo(index: sender.tag)
    }

    @objc private func playAudio() {
        guard let path = audioPath else { return }
        AudioPlayer.shared.play(relativePath: path)
    }
}
