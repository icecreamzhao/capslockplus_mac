import Foundation
import Carbon

enum InputSource {
    static func selectableSources() -> [TISInputSource] {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list.filter { source in
            let category = stringProperty(source, kTISPropertyInputSourceCategory as CFString)
            let type = stringProperty(source, kTISPropertyInputSourceType as CFString)
            return category == (kTISCategoryKeyboardInputSource as String) &&
                (type == (kTISTypeKeyboardLayout as String) || type == (kTISTypeKeyboardInputMode as String)) &&
                boolProperty(source, kTISPropertyInputSourceIsEnabled as CFString) &&
                boolProperty(source, kTISPropertyInputSourceIsSelectCapable as CFString)
        }
    }

    static func currentID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return id(of: source)
    }

    static func currentName() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return name(of: source)
    }

    @discardableResult
    static func switchNext() -> String? {
        let sources = selectableSources()
        guard !sources.isEmpty else {
            return nil
        }

        if sources.count == 1 {
            let only = name(of: sources[0]) ?? "unknown"
            Log.info("inputsource single = \(only)")
            return nil
        }

        let current = currentID()
        let currentIndex = current.flatMap { currentID in
            sources.firstIndex { id(of: $0) == currentID }
        }
        let nextIndex = currentIndex.map { ($0 + 1) % sources.count } ?? 0
        let target = sources[nextIndex]

        let status = TISSelectInputSource(target)
        guard status == noErr else {
            Log.warn("inputsource select failed status=\(status)")
            return nil
        }

        usleep(300_000)
        guard let newID = currentID(), newID == id(of: target) else {
            Log.warn("inputsource switch rejected")
            return nil
        }
        return currentName()
    }

    private static func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, key) else { return false }
        return Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue() == kCFBooleanTrue
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private static func id(of source: TISInputSource) -> String? {
        stringProperty(source, kTISPropertyInputSourceID as CFString)
    }

    private static func name(of source: TISInputSource) -> String? {
        stringProperty(source, kTISPropertyLocalizedName as CFString)
    }
}
