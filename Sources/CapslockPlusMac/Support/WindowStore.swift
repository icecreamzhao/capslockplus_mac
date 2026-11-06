import Foundation

struct WindowBinding: Codable {
    var bundleID: String
    var appName: String
    var titleHint: String
    var boundAt: Double
}

private struct WindowStoreFile: Codable {
    var version: Int
    var slots: [String: WindowBinding]
}

enum WindowStore {
    private static let directoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/capslock-plus-mac", isDirectory: true)
    static let fileURL = directoryURL.appendingPathComponent("windows.json")
    private static let tempURL = directoryURL.appendingPathComponent("windows.json.tmp")

    static func load() -> [Int: WindowBinding] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        do {
            let data = try Data(contentsOf: fileURL)
            let file = try JSONDecoder().decode(WindowStoreFile.self, from: data)
            guard file.version == 1 else {
                Log.warn("window.store load failed reason=version")
                return [:]
            }
            var slots: [Int: WindowBinding] = [:]
            for (key, binding) in file.slots {
                guard let index = Int(key), index > 0 else { continue }
                slots[index] = binding
            }
            return slots
        } catch {
            Log.warn("window.store load failed reason=invalid")
            return [:]
        }
    }

    static func save(_ slots: [Int: WindowBinding]) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            var rawSlots: [String: WindowBinding] = [:]
            for (index, binding) in slots {
                rawSlots[String(index)] = binding
            }
            let file = WindowStoreFile(version: 1, slots: rawSlots)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(file)
            try data.write(to: tempURL, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: fileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            Log.warn("window.store save failed \(error.localizedDescription)")
        }
    }

    static func clear() {
        save([:])
    }
}
