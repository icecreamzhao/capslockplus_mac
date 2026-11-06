import Foundation

enum Action: Equatable {
    case toggleCapsLock
    case escape
    case none

    case moveLeft
    case moveRight
    case moveUp
    case moveDown
    case moveWordLeft
    case moveWordRight
    case moveLineStart
    case moveLineEnd
    case moveUp10
    case moveDown10

    case selectLeft
    case selectRight
    case selectWordLeft
    case selectWordRight
    case selectUp
    case selectDown
    case selectLineStart
    case selectLineEnd
    case selectUp10
    case selectDown10

    case deleteBackward
    case deleteForward
    case deleteWordBackward
    case deleteToLineStart
    case deleteToLineEnd
    case deleteWordForward
    case deleteToPageStart
    case deleteToPageEnd
    case deleteAll
    case hardDeleteLine
    case deleteLine
    case insertLineBelow
    case pressReturn
    case selectCurrentWord
    case wrapSelection(String)

    case cut
    case copy
    case paste
    case pastePlain
    case extraCut
    case extraCopy
    case extraPaste

    case windowBind(Int)
    case windowActivate(Int)
    case minimizeWindow
    case launchApp(String)
    case sendKeys(String)
    case typeText(String)
    indirect case repeated(Action, Int)
    case reloadConfig
    case switchInputSource

    var name: String {
        switch self {
        case .toggleCapsLock: return "toggleCapsLock"
        case .escape: return "escape"
        case .none: return "none"
        case .moveLeft: return "moveLeft"
        case .moveRight: return "moveRight"
        case .moveUp: return "moveUp"
        case .moveDown: return "moveDown"
        case .moveWordLeft: return "moveWordLeft"
        case .moveWordRight: return "moveWordRight"
        case .moveLineStart: return "moveLineStart"
        case .moveLineEnd: return "moveLineEnd"
        case .moveUp10: return "moveUp10"
        case .moveDown10: return "moveDown10"
        case .selectLeft: return "selectLeft"
        case .selectRight: return "selectRight"
        case .selectWordLeft: return "selectWordLeft"
        case .selectWordRight: return "selectWordRight"
        case .selectUp: return "selectUp"
        case .selectDown: return "selectDown"
        case .selectLineStart: return "selectLineStart"
        case .selectLineEnd: return "selectLineEnd"
        case .selectUp10: return "selectUp10"
        case .selectDown10: return "selectDown10"
        case .deleteBackward: return "deleteBackward"
        case .deleteForward: return "deleteForward"
        case .deleteWordBackward: return "deleteWordBackward"
        case .deleteToLineStart: return "deleteToLineStart"
        case .deleteToLineEnd: return "deleteToLineEnd"
        case .deleteWordForward: return "deleteWordForward"
        case .deleteToPageStart: return "deleteToPageStart"
        case .deleteToPageEnd: return "deleteToPageEnd"
        case .deleteAll: return "deleteAll"
        case .hardDeleteLine: return "hardDeleteLine"
        case .deleteLine: return "deleteLine"
        case .insertLineBelow: return "insertLineBelow"
        case .pressReturn: return "pressReturn"
        case .selectCurrentWord: return "selectCurrentWord"
        case .wrapSelection(let kind): return "wrapSelection(\(kind))"
        case .cut: return "cut"
        case .copy: return "copy"
        case .paste: return "paste"
        case .pastePlain: return "pastePlain"
        case .extraCut: return "extraClipboard.cut"
        case .extraCopy: return "extraClipboard.copy"
        case .extraPaste: return "extraClipboard.paste"
        case .windowBind(let index): return "window.bind(\(index))"
        case .windowActivate(let index): return "window.activate(\(index))"
        case .minimizeWindow: return "minimizeWindow"
        case .launchApp(let bundleID): return "launchapp(\(bundleID))"
        case .sendKeys(let spec): return "send(\(spec))"
        case .typeText(let text): return "type(\(text))"
        case .repeated(let base, let count): return "\(base.name)(\(count))"
        case .reloadConfig: return "reloadConfig"
        case .switchInputSource: return "switchInputSource"
        }
    }

    private static let fixed: [String: Action] = [
        "togglecapslock": .toggleCapsLock,
        "escape": .escape,
        "none": Action.none,
        "moveleft": .moveLeft,
        "moveright": .moveRight,
        "moveup": .moveUp,
        "movedown": .moveDown,
        "movewordleft": .moveWordLeft,
        "movewordright": .moveWordRight,
        "movelinestart": .moveLineStart,
        "movelineend": .moveLineEnd,
        "moveup10": .moveUp10,
        "movedown10": .moveDown10,
        "selectleft": .selectLeft,
        "selectright": .selectRight,
        "selectwordleft": .selectWordLeft,
        "selectwordright": .selectWordRight,
        "selectup": .selectUp,
        "selectdown": .selectDown,
        "selectlinestart": .selectLineStart,
        "selectlineend": .selectLineEnd,
        "selectup10": .selectUp10,
        "selectdown10": .selectDown10,
        "deletebackward": .deleteBackward,
        "deleteforward": .deleteForward,
        "deletewordbackward": .deleteWordBackward,
        "deletetolinestart": .deleteToLineStart,
        "deletetolineend": .deleteToLineEnd,
        "deletewordforward": .deleteWordForward,
        "deletetopagestart": .deleteToPageStart,
        "deletetopageend": .deleteToPageEnd,
        "deleteall": .deleteAll,
        "harddeleteline": .hardDeleteLine,
        "deleteline": .deleteLine,
        "insertlinebelow": .insertLineBelow,
        "pressreturn": .pressReturn,
        "selectcurrentword": .selectCurrentWord,
        "cut": .cut,
        "copy": .copy,
        "paste": .paste,
        "pasteplain": .pastePlain,
        "extraclipboard.cut": .extraCut,
        "extraclipboard.copy": .extraCopy,
        "extraclipboard.paste": .extraPaste,
        "minimizewindow": .minimizeWindow,
        "reloadconfig": .reloadConfig,
        "switchinputsource": .switchInputSource
    ]

    private static let repeatable: [String: Action] = [
        "moveleft": .moveLeft,
        "moveright": .moveRight,
        "moveup": .moveUp,
        "movedown": .moveDown,
        "movewordleft": .moveWordLeft,
        "movewordright": .moveWordRight,
        "selectleft": .selectLeft,
        "selectright": .selectRight,
        "selectup": .selectUp,
        "selectdown": .selectDown,
        "selectwordleft": .selectWordLeft,
        "selectwordright": .selectWordRight,
        "deletebackward": .deleteBackward,
        "deleteforward": .deleteForward
    ]

    static func parse(_ raw: String) -> Action? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if let action = fixed[lower] {
            return action
        }
        if let kind = argument(of: lower, prefix: "wrapselection("), !kind.isEmpty {
            return .wrapSelection(kind)
        }
        if let index = integerArgument(of: lower, prefix: "window.bind(") {
            return .windowBind(index)
        }
        if let index = integerArgument(of: lower, prefix: "window.activate(") {
            return .windowActivate(index)
        }
        if lower.hasPrefix("type("), trimmed.hasSuffix(")") {
            let text = String(trimmed.dropFirst("type(".count).dropLast())
            return .typeText(text)
        }
        if let spec = argument(of: lower, prefix: "send("), !spec.isEmpty {
            return .sendKeys(spec)
        }
        if lower.hasPrefix("launchapp("), trimmed.hasSuffix(")") {
            let bundleID = String(trimmed.dropFirst("launchapp(".count).dropLast())
                .trimmingCharacters(in: .whitespaces)
            if !bundleID.isEmpty {
                return .launchApp(bundleID)
            }
        }
        if let open = lower.firstIndex(of: "("), lower.hasSuffix(")") {
            let base = String(lower[..<open])
            let inner = String(lower[lower.index(after: open)..<lower.index(before: lower.endIndex)])
            if let action = repeatable[base],
               let count = Int(inner.trimmingCharacters(in: .whitespaces)) {
                return .repeated(action, min(max(count, 1), 100))
            }
        }
        return nil
    }

    private static func argument(of text: String, prefix: String) -> String? {
        guard text.hasPrefix(prefix), text.hasSuffix(")") else { return nil }
        let inner = text.dropFirst(prefix.count).dropLast()
        return String(inner).trimmingCharacters(in: .whitespaces)
    }

    private static func integerArgument(of text: String, prefix: String) -> Int? {
        guard let inner = argument(of: text, prefix: prefix), let value = Int(inner), value >= 1 else {
            return nil
        }
        return value
    }
}

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
            ("caps+alt+x", "extraClipboard.cut"),
            ("caps+alt+c", "extraClipboard.copy"),
            ("caps+alt+v", "extraClipboard.paste")
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
        Log.info("configLoaded n=\(bindings.count)")
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
