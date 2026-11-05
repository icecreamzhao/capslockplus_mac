import Foundation

enum KeyRemap {
    private static let hidutil = "/usr/bin/hidutil"
    private static let mapping = """
        {"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x70000006D}]}
        """
    private static let cleared = """
        {"UserKeyMapping":[]}
        """

    @discardableResult
    static func apply() -> Bool {
        guard run(["property", "--set", mapping]) else {
            return false
        }
        Log.info("keyremap on")
        return true
    }

    static func remove() {
        _ = run(["property", "--set", cleared])
        Log.info("keyremap off")
    }

    static func isApplied() -> Bool {
        guard let output = capture(["property", "--get", "UserKeyMapping"]) else {
            return false
        }
        return output.contains("HIDKeyboardModifierMappingSrc")
            && output.contains("0x700000039")
    }

    @discardableResult
    private static func run(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: hidutil)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            Log.error("hidutil launch failed \(error.localizedDescription)")
            return false
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            Log.error("hidutil exit=\(process.terminationStatus) args=\(arguments.first ?? "")")
        }
        return process.terminationStatus == 0
    }

    private static func capture(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: hidutil)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            Log.error("hidutil launch failed \(error.localizedDescription)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
