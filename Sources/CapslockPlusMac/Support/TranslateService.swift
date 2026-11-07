import Foundation
import AppKit

/// 有道词典返回的解析结果。全部字段都可能缺失。
struct Translation {
    var query: String
    var phonetic: String?
    var lines: [String]
    var webLines: [String]

    var isEmpty: Bool { lines.isEmpty }

    var displayText: String {
        var parts: [String] = []
        if let phonetic = phonetic, !phonetic.isEmpty {
            parts.append("/\(phonetic)/")
        }
        parts.append(contentsOf: lines)
        if !webLines.isEmpty {
            parts.append("")
            parts.append("网络释义")
            parts.append(contentsOf: webLines.map { "· " + $0 })
        }
        return parts.joined(separator: "\n")
    }
}

enum TranslateService {
    static var endpoint: String {
        Config.shared.translateEndpoint
    }

    static func fetch(_ rawQuery: String, completion: @escaping (Result<Translation, String>) -> Void) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            completion(.failure("没有选中文字"))
            return
        }

        var components = URLComponents(string: endpoint)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else {
            completion(.failure("接口地址无效"))
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(Config.shared.translateTimeoutMs) / 1000.0
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async { completion(.failure("网络错误：\(error.localizedDescription)")) }
                return
            }
            guard let data = data, !data.isEmpty else {
                DispatchQueue.main.async { completion(.failure("没有返回内容")) }
                return
            }
            let result = parse(data: data, query: query)
            DispatchQueue.main.async {
                if result.isEmpty {
                    completion(.failure("没查到释义"))
                } else {
                    completion(.success(result))
                }
            }
        }
        task.resume()
    }

    // MARK: - 解析

    static func parse(data: Data, query: String) -> Translation {
        var out = Translation(query: query, phonetic: nil, lines: [], webLines: [])
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return out
        }

        // 英→中：ec.word[0] 有音标和分条释义
        if let ec = root["ec"] as? [String: Any],
           let word = (ec["word"] as? [[String: Any]])?.first {
            out.phonetic = (word["ukphone"] as? String) ?? (word["usphone"] as? String)
            out.lines = flattenTrs(word["trs"])
        }

        // 中→英：优先新汉英大辞典，再退旧 ce
        if out.lines.isEmpty {
            for key in ["ce_new", "ce"] {
                guard let section = root[key] as? [String: Any],
                      let word = (section["word"] as? [[String: Any]])?.first else { continue }
                if out.phonetic == nil {
                    out.phonetic = word["phone"] as? String
                }
                out.lines = flattenTrs(word["trs"])
                if !out.lines.isEmpty { break }
            }
        }

        // 兜底：simple.word[0].phone
        if out.phonetic == nil,
           let simple = root["simple"] as? [String: Any],
           let word = (simple["word"] as? [[String: Any]])?.first {
            out.phonetic = word["phone"] as? String
        }

        // 网络释义补两条，避免只查到专业词时空白
        if let web = root["web_trans"] as? [String: Any],
           let groups = web["web-translation"] as? [[String: Any]] {
            var seen = Set<String>()
            for group in groups {
                guard let trans = group["trans"] as? [[String: Any]] else { continue }
                for item in trans {
                    guard let value = item["value"] as? String else { continue }
                    let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if clean.isEmpty || seen.contains(clean) { continue }
                    seen.insert(clean)
                    out.webLines.append(clean)
                    if out.webLines.count >= 3 { break }
                }
                if out.webLines.count >= 3 { break }
            }
        }

        return out
    }

    /// `trs` 的结构： [{"tr":[{"l":{"i":["..."]}}]}]，`i` 里偶尔是对象而不是字符串
    private static func flattenTrs(_ raw: Any?) -> [String] {
        guard let trs = raw as? [[String: Any]] else { return [] }
        var lines: [String] = []
        for entry in trs {
            guard let tr = entry["tr"] as? [[String: Any]] else { continue }
            for item in tr {
                guard let l = item["l"] as? [String: Any] else { continue }
                if let text = l["#tran"] as? String, !text.isEmpty {
                    lines.append(text)
                    continue
                }
                if let parts = l["i"] as? [Any] {
                    var buffer = ""
                    for part in parts {
                        if let text = part as? String {
                            buffer += text
                        } else if let object = part as? [String: Any],
                                  let text = object["#text"] as? String {
                            buffer += text
                        }
                    }
                    let clean = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty { lines.append(clean) }
                }
            }
        }
        // 单条释义里常用 "；" 分点，保留原样即可，只去重
        var seen = Set<String>()
        return lines.filter { seen.insert($0).inserted }
    }
}
