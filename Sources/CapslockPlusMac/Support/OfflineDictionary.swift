import Foundation
import SQLite3

struct DictEntry {
    let source: String
    let headword: String
    let phonetic: String?
    let body: String
    let audioBre: String?
    let audioAme: String?
    /// 原始词条 HTML（带词典自己的 css 类名/自定义标签），nil = 库里没有这一列的内容
    let html: String?

    var sourceLabel: String {
        switch source {
        case "oalecd9": return "牛津高阶"
        case "ldoce6": return "朗文"
        default: return source
        }
    }

    var lines: [String] { body.split(separator: "\n").map(String.init) }

    var audioPath: String? { audioBre ?? audioAme }

    /// 词典自带的样式表文件名（在 dict-assets/<source>/ 里）
    var stylesheet: String? {
        switch source {
        case "oalecd9": return "oalecd9.css"
        case "ldoce6": return "LongmanDictionaryOfContemporaryEnglish6thEnEn.css"
        default: return nil
        }
    }

    /// 排版资源目录：dict-assets/<source>/
    static func assetsDirectory(for source: String) -> String {
        NSString(string: "~/.config/capslock-plus-mac/dict-assets/\(source)").expandingTildeInPath
    }
}

/// 离线词库：查 ~/.config/capslock-plus-mac/dict.sqlite（由 scripts/mdx-to-sqlite.py 生成）。
/// 只读，单连接，主线程同步查询（本地 SQLite 命中在 1ms 量级）。
final class OfflineDictionary {
    static let shared = OfflineDictionary()

    static var databasePath: String {
        NSString(string: "~/.config/capslock-plus-mac/dict.sqlite").expandingTildeInPath
    }

    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {
        let path = Self.databasePath
        guard FileManager.default.fileExists(atPath: path) else {
            Log.info("dict unavailable reason=file-missing path=\(path)")
            return
        }
        // 读写成对 WAL 库更宽容（只读打开 WAL 库会 SQLITE_CANTOPEN）；打不开再退只读
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) != SQLITE_OK,
           sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            Log.warn("dict unavailable reason=open-failed path=\(path)")
            db = nil
            return
        }
        let count = scalar("SELECT COUNT(*) FROM entries")
        Log.info("dict loaded entries=\(count) path=\(path)")
    }

    var isAvailable: Bool { db != nil }

    func lookup(_ raw: String) -> [DictEntry] {
        guard db != nil else { return [] }
        for candidate in Self.candidates(for: raw) {
            let rows = query(candidate)
            if !rows.isEmpty {
                return rows
            }
        }
        return []
    }

    private func query(_ word: String) -> [DictEntry] {
        let sql = """
            SELECT source, headword, phonetic, body, audio_bre, audio_ame, html
            FROM entries WHERE word = ?
            ORDER BY CASE source WHEN 'oalecd9' THEN 0 WHEN 'ldoce6' THEN 1 ELSE 2 END
            """
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepare == SQLITE_OK else {
            Log.warn("dict prepare failed rc=\(prepare) msg=\(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, word, -1, transient)

        var rows: [DictEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ index: Int32) -> String? {
                guard let pointer = sqlite3_column_text(statement, index) else { return nil }
                return String(cString: pointer)
            }
            let blobIndex: Int32 = 6
            let htmlBlob = sqlite3_column_blob(statement, blobIndex)
            let htmlBytes = Int(sqlite3_column_bytes(statement, blobIndex))
            rows.append(DictEntry(
                source: text(0) ?? "",
                headword: text(1) ?? word,
                phonetic: text(2),
                body: text(3) ?? "",
                audioBre: text(4),
                audioAme: text(5),
                html: Self.inflate(htmlBlob, htmlBytes)
            ))
        }
        return rows
    }

    /// raw deflate → String；转换脚本用 zlib.compressobj(..., wbits=-15) 压的
    private static func inflate(_ pointer: UnsafeRawPointer?, _ count: Int) -> String? {
        guard let pointer = pointer, count > 0 else { return nil }
        let data = Data(bytes: pointer, count: count)
        guard let inflated = try? (data as NSData).decompressed(using: .zlib) as Data else {
            Log.warn("dict html inflate failed bytes=\(count)")
            return nil
        }
        return String(data: inflated, encoding: .utf8)
    }

    private func scalar(_ sql: String) -> Int {
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepare == SQLITE_OK else {
            Log.warn("dict prepare failed rc=\(prepare) msg=\(String(cString: sqlite3_errmsg(db)))")
            return 0
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// 查词候选：原文 → 去掉所有格/标点 → 常见词形还原。
    static func candidates(for raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        let base = cleaned.lowercased()
        guard !base.isEmpty, base.count <= 40 else { return [] }

        var list = [base]
        func add(_ word: String) {
            guard !word.isEmpty, word.count > 1, !list.contains(word) else { return }
            list.append(word)
        }

        if base.hasSuffix("'s") || base.hasSuffix("’s") {
            add(String(base.dropLast(2)))
        }
        // 名词复数 / 动词时态，按常见后缀还原；命不中也没代价
        let rules: [(suffix: String, replacement: String)] = [
            ("ies", "y"), ("ies", "ie"), ("ves", "f"), ("ves", "fe"),
            ("es", ""), ("s", ""),
            ("ied", "y"), ("ed", ""), ("ed", "e"),
            ("ying", "y"), ("ing", ""), ("ing", "e"),
            ("er", ""), ("er", "e"), ("est", ""), ("est", "e"),
            ("ly", "")
        ]
        for rule in rules where base.hasSuffix(rule.suffix) && base.count > rule.suffix.count + 2 {
            add(String(base.dropLast(rule.suffix.count)) + rule.replacement)
        }
        return list
    }
}
