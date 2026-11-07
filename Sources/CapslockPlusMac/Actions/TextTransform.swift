import Foundation

/// 选中文本的纯函数变换。全部走 AX 读写选区，不合成任何按键。
enum TextTransform {
    static let kinds: [String] = [
        "upper", "lower", "title",
        "camel", "pascal", "snake", "kebab", "constant",
        "trim", "sort", "sortdesc", "reverse", "unique",
        "jsonpretty", "jsonmin",
        "urlencode", "urldecode",
        "ascii2cjk", "cjk2ascii", "punctoggle"
    ]

    /// 返回 nil 表示不认识的 kind（调用方记日志），空串是有意义的返回值。
    static func apply(_ kind: String, to text: String) -> String? {
        let key = kind.lowercased()
        switch key {
        case "upper":
            return text.uppercased()
        case "lower":
            return text.lowercased()
        case "title":
            return words(text).map { $0.capitalized }.joined(separator: " ")
        case "camel":
            return words(text).enumerated()
                .map { $0.offset == 0 ? $0.element.lowercased() : $0.element.capitalized }
                .joined()
        case "pascal":
            return words(text).map { $0.capitalized }.joined()
        case "snake":
            return words(text).map { $0.lowercased() }.joined(separator: "_")
        case "kebab":
            return words(text).map { $0.lowercased() }.joined(separator: "-")
        case "constant":
            return words(text).map { $0.uppercased() }.joined(separator: "_")
        case "trim":
            return trim(text)
        case "sort":
            return mapLines(text) { $0.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
        case "sortdesc":
            return mapLines(text) { $0.sorted { $0.localizedStandardCompare($1) == .orderedDescending } }
        case "reverse":
            return mapLines(text) { Array($0.reversed()) }
        case "unique":
            return mapLines(text) { lines in
                var seen = Set<String>()
                return lines.filter { seen.insert($0).inserted }
            }
        case "jsonpretty":
            return restructureJSON(text, pretty: true)
        case "jsonmin":
            return restructureJSON(text, pretty: false)
        case "urlencode":
            return text.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        case "urldecode":
            return text.removingPercentEncoding
        case "ascii2cjk":
            return translatePunctuation(text, toCJK: true)
        case "cjk2ascii":
            return translatePunctuation(text, toCJK: false)
        case "punctoggle":
            // 选中内容里有中文标点就转成英文，否则转成中文
            let hasCJK = text.contains { cjkPunctuation.contains($0) }
            return translatePunctuation(text, toCJK: !hasCJK)
        default:
            return nil
        }
    }

    // MARK: - 切词

    /// 把 `user_profileID`、`userProfileID`、`user-profile id` 都切成 [user, profile, ID]
    static func words(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }

        let chars = Array(text)
        for (index, ch) in chars.enumerated() {
            if ch.isLetter || ch.isNumber {
                if !current.isEmpty {
                    let prev = current.last!
                    let nextIsLower = index + 1 < chars.count && chars[index + 1].isLowercase
                    // camelCase 边界：小写→大写；连续大写后接小写（HTTPResponse → HTTP + Response）
                    if ch.isUppercase && (prev.isLowercase || prev.isNumber || (prev.isUppercase && nextIsLower)) {
                        flush()
                    }
                }
                current.append(ch)
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    // MARK: - 行处理

    private static func mapLines(_ text: String, _ body: ([String]) -> [String]) -> String {
        let hadTrailingNewline = text.hasSuffix("\n")
        var lines = text.components(separatedBy: "\n")
        if hadTrailingNewline { lines.removeLast() }
        let result = body(lines).joined(separator: "\n")
        return hadTrailingNewline ? result + "\n" : result
    }

    private static func trim(_ text: String) -> String {
        mapLines(text) { lines in
            lines.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - JSON / 标点 / 编码

    private static func restructureJSON(_ text: String, pretty: Bool) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        var options: JSONSerialization.WritingOptions = [.withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        guard let out = try? JSONSerialization.data(withJSONObject: object, options: options),
              let string = String(data: out, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private static let cjkPunctuation: Set<Character> = [
        "，", "。", "！", "？", "：", "；", "（", "）", "【", "】",
        "“", "”", "‘", "’", "、"
    ]

    private static let toCJKMap: [Character: Character] = [
        ",": "，", ".": "。", "!": "！", "?": "？", ":": "：", ";": "；",
        "(": "（", ")": "）", "[": "【", "]": "】"
    ]

    private static let fromCJKMap: [Character: Character] = [
        "，": ",", "。": ".", "！": "!", "？": "?", "：": ":", "；": ";",
        "（": "(", "）": ")", "【": "[", "】": "]", "、": ",",
        "“": "\"", "”": "\"", "‘": "'", "’": "'"
    ]

    private static func translatePunctuation(_ text: String, toCJK: Bool) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        for ch in text {
            if toCJK {
                if let mapped = toCJKMap[ch] {
                    out.append(mapped)
                } else if ch == "\"" {
                    out.append("“")
                } else if ch == "'" {
                    out.append("‘")
                } else {
                    out.append(ch)
                }
            } else {
                if let mapped = fromCJKMap[ch] {
                    out.append(mapped)
                } else {
                    out.append(ch)
                }
            }
        }
        return out
    }
}
