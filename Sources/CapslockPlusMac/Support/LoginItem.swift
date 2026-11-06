import Foundation

enum LoginItem {
    static var label: String { "com.littleboy.CapslockPlusMac" }

    static var plistPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
            .path
    }

    private static var plistURL: URL {
        URL(fileURLWithPath: plistPath)
    }

    static func isEnabled() -> Bool {
        guard FileManager.default.fileExists(atPath: plistPath) else { return false }
        return launchctl(["print", "gui/\(getuid())/\(label)"]) == 0
    }

    @discardableResult
    static func enable() -> Bool {
        let directory = plistURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [Bundle.main.bundlePath + "/Contents/MacOS/CapslockPlusMac"],
                "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false],
                "ThrottleInterval": 10,
                "ProcessType": "Interactive"
            ]
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
            try data.write(to: plistURL, options: .atomic)
        } catch {
            Log.error("loginItem enable fail status=-1")
            return false
        }

        let domain = "gui/\(getuid())"
        var status = launchctl(["bootstrap", domain, plistPath])
        if status == 5 {
            _ = launchctl(["bootout", "\(domain)/\(label)"])
            status = launchctl(["bootstrap", domain, plistPath])
        }

        guard status == 0 else {
            Log.error("loginItem enable fail status=\(status)")
            return false
        }
        Log.info("loginItem enable ok plist=\(plistPath)")
        return true
    }

    @discardableResult
    static func disable() -> Bool {
        let domain = "gui/\(getuid())"
        _ = launchctl(["bootout", "\(domain)/\(label)"])

        do {
            if FileManager.default.fileExists(atPath: plistPath) {
                try FileManager.default.removeItem(at: plistURL)
            }
        } catch {
            Log.error("loginItem disable fail status=-1")
            return false
        }
        Log.info("loginItem disable ok")
        return true
    }

    private static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
