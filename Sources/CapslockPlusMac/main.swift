import Foundation
import AppKit

func runSelfTest() -> Int32 {
    var failures: [String] = []
    var seen = Set<KeyCombo>()

    for (chordText, actionText) in Config.defaultPairs {
        guard let combo = ChordParser.parse(chordText) else {
            failures.append("bad chord \(chordText)")
            continue
        }
        if !seen.insert(combo).inserted {
            failures.append("duplicate chord \(chordText)")
        }
        if Action.parse(actionText) == nil {
            failures.append("unknown action \(actionText)")
        }
    }
    if TapAction(rawValue: "toggleCapsLock") == nil {
        failures.append("unknown tap action")
    }

    if failures.isEmpty {
        print("selftest OK (\(seen.count) bindings)")
        return 0
    }
    for failure in failures {
        FileHandle.standardError.write(Data("selftest FAILED: \(failure)\n".utf8))
    }
    return 1
}

if CommandLine.arguments.contains("--selftest") {
    exit(runSelfTest())
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
