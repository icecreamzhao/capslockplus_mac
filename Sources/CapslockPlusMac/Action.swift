import Foundation
import AppKit

/// 动作定义与解析：动作名 ↔ Action 的唯一映射表（fixedTable），
/// 自检里有 name → parse 往返断言，防止两处手工映射漂移。
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
    case transform(String)
    case tile(String)
    case insertDate(String)

    case cut
    case copy
    case paste
    case pastePlain

    case windowBind(Int)
    case windowActivate(Int)
    case minimizeWindow
    case launchApp(String)
    case sendKeys(String)
    case typeText(String)
    indirect case repeated(Action, Int)
    case translate
    case reloadConfig
    case switchInputSource
    case resetInputMethod

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
        case .transform(let kind): return "transform(\(kind))"
        case .tile(let kind): return "tile(\(kind))"
        case .insertDate(let format): return "insertdate(\(format))"
        case .cut: return "cut"
        case .copy: return "copy"
        case .paste: return "paste"
        case .pastePlain: return "pastePlain"
        case .windowBind(let index): return "window.bind(\(index))"
        case .windowActivate(let index): return "window.activate(\(index))"
        case .minimizeWindow: return "minimizeWindow"
        case .launchApp(let bundleID): return "launchapp(\(bundleID))"
        case .sendKeys(let spec): return "send(\(spec))"
        case .typeText(let text): return "type(\(text))"
        case .repeated(let base, let count): return "\(base.name)(\(count))"
        case .translate: return "translate"
        case .reloadConfig: return "reloadConfig"
        case .switchInputSource: return "switchInputSource"
        case .resetInputMethod: return "resetInputMethod"
        }
    }

    static let fixedTable: [String: Action] = [
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
        "minimizewindow": .minimizeWindow,
        "reloadconfig": .reloadConfig,
        "translate": .translate,
        "insertdate": .insertDate("yyyy-MM-dd"),
        "inserttime": .insertDate("HH:mm"),
        "insertdatetime": .insertDate("yyyy-MM-dd HH:mm"),
        "switchinputsource": .switchInputSource,
        "imereset": .resetInputMethod,
        "resetinputmethod": .resetInputMethod
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
        if let action = fixedTable[lower] {
            return action
        }
        if let kind = argument(of: lower, prefix: "wrapselection("), !kind.isEmpty {
            return .wrapSelection(kind)
        }
        if let kind = argument(of: lower, prefix: "transform("), !kind.isEmpty {
            return .transform(kind)
        }
        if let kind = argument(of: lower, prefix: "tile("), !kind.isEmpty {
            return .tile(kind)
        }
        // 日期格式要保留原始大小写（yyyy-MM-dd HH:mm 里的 HH 不能变 hh），所以用 trimmed 取参数
        if let format = argument(of: trimmed, prefix: "insertdate("), !format.isEmpty {
            return .insertDate(format)
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
