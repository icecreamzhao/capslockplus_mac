import Foundation
import AppKit
import CoreGraphics

private func capsEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else {
        return Unmanaged.passUnretained(event)
    }
    let engine = Unmanaged<EventTapEngine>.fromOpaque(UnsafeRawPointer(refcon)).takeUnretainedValue()
    return engine.handle(type: type, event: event)
}

final class EventTapEngine {
    private(set) var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let caps: CapsState

    init(caps: CapsState) {
        self.caps = caps
    }

    func start() -> Bool {
        let mask = eventMask()
        let locations: [(CGEventTapLocation, String)] = [
            (.cghidEventTap, "hid"),
            (.cgSessionEventTap, "session")
        ]

        for (location, name) in locations {
            guard let tap = CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: capsEventTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                continue
            }
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                CFMachPortInvalidate(tap)
                Log.error("tap=sourceFailed location=\(name)")
                continue
            }
            self.tap = tap
            self.source = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            Log.info("tap=created location=\(name)")
            return true
        }

        Log.error("tap=createFailed")
        return false
    }

    func stop() {
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = tap {
            CFMachPortInvalidate(tap)
        }
        tap = nil
        source = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == KeyPost.magic {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .tapDisabledByTimeout:
            Log.warn("tapDisabled reason=timeout")
            if let tap = tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        case .tapDisabledByUserInput:
            Log.warn("tapDisabled reason=userInput")
            if let tap = tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        case .flagsChanged:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == KeyCodes.caps {
                caps.capsFlagsChanged()
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            if handleKeyDown(event) {
                return nil
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleKeyDown(_ event: CGEvent) -> Bool {
        guard caps.isDown else { return false }

        caps.markActionUsed()
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let combo = KeyCombo(
            keyCode: keyCode,
            modifiers: event.flags.rawValue & KeyCodes.chordMask.rawValue
        )
        guard let binding = Config.shared.keymap.bindings[combo] else {
            return true
        }

        Log.info("chord \(binding.chordText) -> \(binding.actionName)")
        ActionRunner.run(binding.action)
        return true
    }

    private func eventMask() -> CGEventMask {
        func bit(_ type: CGEventType) -> CGEventMask {
            let shift = UInt64(type.rawValue & 0x3F)
            return CGEventMask(1) << shift
        }
        return bit(.flagsChanged)
            | bit(.keyDown)
            | bit(.tapDisabledByTimeout)
            | bit(.tapDisabledByUserInput)
    }
}

enum ActionRunner {
    static func run(_ action: Action) {
        if TextActions.run(action) {
            return
        }

        switch action {
        case .cut:
            ClipboardActions.cut()
        case .copy:
            ClipboardActions.copy()
        case .paste:
            ClipboardActions.paste()
        case .pastePlain:
            ClipboardActions.pastePlain()
        case .extraCut:
            ClipboardActions.extraCut()
        case .extraCopy:
            ClipboardActions.extraCopy()
        case .extraPaste:
            ClipboardActions.extraPaste()
        case .windowBind(let index):
            WindowActions.bind(index)
        case .windowActivate(let index):
            WindowActions.activate(index)
        case .escape:
            KeyPost.key(53)
        case .none:
            break
        case .toggleCapsLock:
            Log.warn("action toggleCapsLock is tap-only")
        case .reloadConfig:
            Config.shared.reload()
        default:
            Log.warn("action unimplemented \(action.name)")
        }
    }
}
