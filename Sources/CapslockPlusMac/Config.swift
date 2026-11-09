import Foundation
import AppKit

struct Binding {
    let action: Action
    let actionName: String
    let chordText: String
}

struct Keymap {
    var tapAction: Action
    var chordMaxMs: Int
    var longPressMs: Int
    var longPress: String
    var bindings: [KeyCombo: Binding]
}

final class Config {
    static let shared = Config()

    private(set) var keymap: Keymap
    private(set) var translateEndpoint: String = "https://dict.youdao.com/jsonapi"
    private(set) var translateTimeoutMs: Int = 4000
    /// 浮层自动关闭毫秒数；0 = 不自动关。默认 0。
    private(set) var panelAutoHideMs: Int = 0
    /// 允许用「Cmd+C + 读剪贴板」兜底读选区的 App（bundle id 白名单）。空 = 不用兜底。
    private(set) var clipboardFallbackApps: Set<String> = []
    /// 浮层渲染模式："html"（默认，原版词条排版）或 "text"（纯文本兜底）。
    private(set) var panelRenderMode: String = "html"
    let fileURL: URL

    static let defaultPairs: [(String, String)] = {
        validateSelftestSamples()

        var pairs: [(String, String)] = [
            ("caps+s", "moveLeft"),
            ("caps+f", "moveRight"),
            ("caps+e", "moveUp"),
            ("caps+d", "moveDown"),
            ("caps+a", "moveWordLeft"),
            ("caps+g", "moveWordRight"),
            ("caps+t", "moveUp10"),
            ("caps+b", "moveDown10"),
            ("caps+w", "deleteBackward"),
            ("caps+r", "deleteForward"),
            ("caps+[", "deleteToLineStart"),
            ("caps+/", "deleteToLineEnd"),
            ("caps+backspace", "deleteLine"),
            ("caps+enter", "insertLineBelow"),
            ("caps+space", "pressReturn"),
            ("caps+x", "cut"),
            ("caps+c", "copy"),
            ("caps+v", "paste"),
        ]

        for n in 1...9 {
            pairs.append(("caps+\(n)", "window.activate(\(n))"))
        }
        pairs.append(("caps+0", "window.activate(10)"))
        for n in 1...9 {
            pairs.append(("caps+alt+\(n)", "window.bind(\(n))"))
        }
        pairs.append(("caps+alt+0", "window.bind(10)"))

        pairs.append(contentsOf: [
            ("caps+f5", "reloadConfig"),
            ("caps+alt+r", "imereset"),
            ("caps+esc", "none"),
            ("caps+`", "none"),
            ("caps+tab", "none"),
            ("caps+h", "selectWordLeft"),
            ("caps+l", "selectRight"),
            ("caps+i", "selectUp"),
            ("caps+k", "selectDown"),
            ("caps+j", "selectLeft"),
            ("caps+;", "moveLineEnd"),
            ("caps+p", "moveLineStart"),
            ("caps+u", "selectLineStart"),
            ("caps+o", "selectLineEnd"),
            ("caps+y", "selectUp10"),
            ("caps+n", "selectDown10"),
            ("caps+,", "selectCurrentWord"),
            ("caps+.", "selectWordRight")
        ])
        return pairs
    }()

    static let selftestSamples = [
        "moveup(20)",
        "selectdown(5)",
        "wrapselection(paren)",
        "launchapp(com.apple.Safari)",
        "send(cmd+shift+t)",
        "type(Hello World)"
    ]

    private static func validateSelftestSamples() {
        guard CommandLine.arguments.contains("--selftest") else { return }
        var failures: [String] = []
        for sample in selftestSamples {
            guard let action = Action.parse(sample) else {
                failures.append("cannot parse \(sample)")
                continue
            }
            if sample == "type(Hello World)", action != .typeText("Hello World") {
                failures.append("type() case/space changed: \(action.name)")
            }
        }
        guard failures.isEmpty else {
            for failure in failures {
                FileHandle.standardError.write(Data("selftest FAILED: \(failure)\n".utf8))
            }
            exit(1)
        }
    }

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/capslock-plus-mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("keymap.json")
        keymap = Config.defaultKeymap()
    }

    static func defaultKeymap() -> Keymap {
        var bindings: [KeyCombo: Binding] = [:]
        for (chordText, actionText) in defaultPairs {
            guard let combo = ChordParser.parse(chordText), let action = Action.parse(actionText) else {
                continue
            }
            bindings[combo] = Binding(
                action: action,
                actionName: action.name,
                chordText: chordText.lowercased()
            )
        }
        return Keymap(
            tapAction: .toggleCapsLock,
            chordMaxMs: 300,
            longPressMs: 600,
            longPress: "switchInputSource",
            bindings: bindings
        )
    }

    func loadOrCreate() {
        ensureExists()
        if !load() {
            Log.error("configLoad failed path=\(fileURL.path)")
        }
    }

    func ensureExists() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            writeDefaultFile()
        }
    }

    func reload() {
        if !load() {
            Log.warn("configReload failed, keeping n=\(keymap.bindings.count)")
        }
    }

    @discardableResult
    private func load() -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else {
            Log.warn("configLoad failed reason=unreadable")
            return false
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            Log.warn("configLoad failed reason=json")
            return false
        }

        translateEndpoint = (root["translateEndpoint"] as? String) ?? "https://dict.youdao.com/jsonapi"
        let timeout = (root["translateTimeoutMs"] as? NSNumber)?.intValue ?? 4000
        translateTimeoutMs = min(max(timeout, 1000), 15000)
        let autoHide = (root["panelAutoHideMs"] as? NSNumber)?.intValue ?? 0
        panelAutoHideMs = min(max(autoHide, 0), 600_000)
        clipboardFallbackApps = Set((root["clipboardFallbackApps"] as? [String]) ?? [])
        panelRenderMode = (root["panelRenderMode"] as? String)?.lowercased() ?? "html"

        let tapRaw = (root["tap"] as? String) ?? "toggleCapsLock"
        let tapAction: Action
        if let parsed = Action.parse(tapRaw) {
            tapAction = parsed
        } else {
            tapAction = .toggleCapsLock
            Log.warn("tap parse failed tap=\(tapRaw)")
        }
        let maxMs = (root["chordMaxMs"] as? NSNumber)?.intValue ?? 300
        let chordMaxMs = min(max(maxMs, 50), 2000)
        let rawLongPressMs = (root["longPressMs"] as? NSNumber)?.intValue ?? 600
        let longPressMs = min(max(rawLongPressMs, 300), 3000)
        let longPress = (root["longPress"] as? String) ?? "switchInputSource"
        if longPress != "switchInputSource" {
            // 目前只有一种长按动作；写别的值不会生效，明确告警而不是静默
            Log.warn("longPress unsupported value=\(longPress) (only switchInputSource)")
        }

        guard let rawBindings = root["bindings"] as? [String: Any] else {
            Log.warn("configLoad failed reason=bindings")
            return false
        }

        var bindings: [KeyCombo: Binding] = [:]
        for (chordText, rawAction) in rawBindings {
            guard let actionText = rawAction as? String else { continue }
            guard let combo = ChordParser.parse(chordText) else {
                Log.warn("config bad chord=\(chordText)")
                continue
            }
            guard let action = Action.parse(actionText) else {
                Log.warn("config unknown action=\(actionText)")
                continue
            }
            bindings[combo] = Binding(
                action: action,
                actionName: action.name,
                chordText: chordText.lowercased()
            )
        }
        guard !bindings.isEmpty else {
            Log.warn("configLoad failed reason=no-valid-bindings")
            return false
        }

        keymap = Keymap(
            tapAction: tapAction,
            chordMaxMs: chordMaxMs,
            longPressMs: longPressMs,
            longPress: longPress,
            bindings: bindings
        )
        Log.info("configLoaded n=\(bindings.count) clipboardFallback=\(clipboardFallbackApps.count) renderMode=\(panelRenderMode)")
        return true
    }

    private func writeDefaultFile() {
        var bindings: [String: String] = [:]
        for (chord, action) in Config.defaultPairs {
            bindings[chord] = action
        }
        let root: [String: Any] = [
            "tap": "toggleCapsLock",
            "chordMaxMs": 300,
            "longPressMs": 600,
            "longPress": "switchInputSource",
            "bindings": bindings
        ]
        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            Log.error("configWrite failed")
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error("configWrite failed \(error.localizedDescription)")
        }
    }
}
