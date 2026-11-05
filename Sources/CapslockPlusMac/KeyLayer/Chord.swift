import Foundation
import CoreGraphics

struct KeyCombo: Hashable {
    let keyCode: CGKeyCode
    let modifiers: UInt64
}

enum KeyCodes {
    static let caps: CGKeyCode = 57

    static let chordMask: CGEventFlags = [
        .maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn
    ]

    static let names: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5,
        "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        "`": 50, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "tab": 48, "space": 49, "backspace": 51, "esc": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111
    ]

    static let aliases: [String: String] = [
        "return": "enter",
        "escape": "esc",
        "option": "alt",
        "command": "cmd",
        "control": "ctrl",
        "capslock": "caps"
    ]

}

enum ChordParser {
    static func parse(_ raw: String) -> KeyCombo? {
        let parts = raw.split(separator: "+").map { part -> String in
            let token = String(part).trimmingCharacters(in: .whitespaces).lowercased()
            return KeyCodes.aliases[token] ?? token
        }
        guard !parts.isEmpty else { return nil }

        var modifiers: CGEventFlags = []
        var keyCode: CGKeyCode?

        for token in parts {
            if token.isEmpty { return nil }
            switch token {
            case "caps":
                modifiers.insert(.maskAlphaShift)
            case "alt":
                modifiers.insert(.maskAlternate)
            case "shift":
                modifiers.insert(.maskShift)
            case "cmd":
                modifiers.insert(.maskCommand)
            case "ctrl":
                modifiers.insert(.maskControl)
            case "fn":
                modifiers.insert(.maskSecondaryFn)
            default:
                guard let code = KeyCodes.names[token], keyCode == nil else { return nil }
                keyCode = code
            }
        }

        guard let code = keyCode, modifiers.contains(.maskAlphaShift) else { return nil }
        return KeyCombo(keyCode: code, modifiers: (modifiers.intersection(KeyCodes.chordMask)).rawValue)
    }
}
