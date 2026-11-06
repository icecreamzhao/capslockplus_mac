import Foundation
import CoreGraphics
import Darwin

enum KeyPost {
    static let magic: Int64 = 0x4C504D

    static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        post(code, flags: flags, down: true)
        post(code, flags: flags, down: false)
    }

    static func text(_ s: String) {
        guard !s.isEmpty else { return }
        var units: [UniChar] = []
        for character in s {
            let next = Array(String(character).utf16)
            if !units.isEmpty && units.count + next.count > 20 {
                postUnicode(units)
                units.removeAll(keepingCapacity: true)
                usleep(1000)
            }
            units.append(contentsOf: next)
        }
        if !units.isEmpty {
            postUnicode(units)
        }
    }

    static func keys(_ spec: String) -> Bool {
        var parsed: [(CGKeyCode, CGEventFlags)] = []
        for group in groups(of: spec) {
            guard let item = parseGroup(group) else {
                Log.warn("send failed spec=\(spec)")
                return false
            }
            parsed.append(item)
        }
        guard !parsed.isEmpty else {
            Log.warn("send failed spec=\(spec)")
            return false
        }

        for (index, item) in parsed.enumerated() {
            if index > 0 {
                usleep(12000)
            }
            post(item.0, flags: item.1, down: true)
            post(item.0, flags: item.1, down: false)
        }
        return true
    }

    private static func post(_ code: CGKeyCode, flags: CGEventFlags, down: Bool) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
            return
        }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: magic)
        event.post(tap: .cgSessionEventTap)
    }

    private static func postUnicode(_ units: [UniChar]) {
        guard !units.isEmpty,
              let source = CGEventSource(stateID: .combinedSessionState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else {
            return
        }
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: magic)
        units.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
        }
        event.post(tap: .cgSessionEventTap)
    }

    private static func groups(of spec: String) -> [String] {
        var groups: [String] = []
        var current = ""
        for character in spec {
            if character == "," && !current.trimmingCharacters(in: .whitespaces).hasSuffix("+") {
                groups.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        groups.append(current)
        return groups
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func parseGroup(_ group: String) -> (CGKeyCode, CGEventFlags)? {
        let parts = group
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }
        guard let keyName = parts.last, let code = keyCodes[keyName] else {
            return nil
        }
        var flags: CGEventFlags = []
        for token in parts.dropLast() {
            guard let flag = modifiers[token] else { return nil }
            flags.insert(flag)
        }
        return (code, flags)
    }

    private static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand,
        "command": .maskCommand,
        "alt": .maskAlternate,
        "option": .maskAlternate,
        "ctrl": .maskControl,
        "control": .maskControl,
        "shift": .maskShift
    ]

    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5,
        "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40,
        ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "tab": 48, "space": 49, "`": 50, "backspace": 51,
        "escape": 53, "esc": 53,
        "home": 115, "pageup": 116, "delete": 117, "forwarddelete": 117,
        "end": 119, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111
    ]
}
