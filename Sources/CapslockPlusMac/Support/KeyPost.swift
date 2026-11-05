import Foundation
import CoreGraphics

enum KeyPost {
    static let magic: Int64 = 0x4C504D

    static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        post(code, flags: flags, down: true)
        post(code, flags: flags, down: false)
    }

    private static func post(_ code: CGKeyCode, flags: CGEventFlags, down: Bool) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
            return
        }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: magic)
        event.post(tap: .cghidEventTap)
    }
}
