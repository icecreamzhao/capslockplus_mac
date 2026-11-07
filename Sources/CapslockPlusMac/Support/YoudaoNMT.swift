import Foundation
import CryptoKit

/// 有道智云 文本翻译(NMT) 接口。
/// 凭据放在 ~/.config/capslock-plus-mac/youdao.json，不进仓库：
///     {"appId": "...", "appSecret": "..."}
enum YoudaoNMT {
    struct Credentials {
        let appId: String
        let appSecret: String
    }

    static var credentialPath: String {
        NSString(string: "~/.config/capslock-plus-mac/youdao.json").expandingTildeInPath
    }

    static func credentials() -> Credentials? {
        guard let data = FileManager.default.contents(atPath: credentialPath),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let appId = root["appId"] as? String,
              let appSecret = root["appSecret"] as? String,
              !appId.isEmpty, !appSecret.isEmpty else {
            return nil
        }
        return Credentials(appId: appId, appSecret: appSecret)
    }

    /// 官方签名规则：q 超过 20 字符时取「前10 + 长度 + 后10」参与签名。
    private static func signingInput(_ query: String) -> String {
        query.count <= 20 ? query : String(query.prefix(10)) + String(query.count) + String(query.suffix(10))
    }

    private static func sign(appId: String, appSecret: String, query: String, salt: String, curtime: String) -> String {
        let raw = appId + signingInput(query) + salt + curtime + appSecret
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// errorCode → 人话，方便日志里直接定位
    static func errorText(_ code: String) -> String {
        switch code {
        case "101": return "缺少必填参数"
        case "102": return "不支持的语言类型"
        case "103": return "翻译文本过长"
        case "108": return "appId 无效"
        case "110": return "无相关服务的有效实例"
        case "202": return "签名校验失败"
        case "206": return "时间戳无效"
        case "301": return "词典查询失败"
        case "401": return "账户已欠费"
        case "411": return "访问频率受限"
        default: return "错误码 \(code)"
        }
    }

    /// 不切线程，调用方自己决定回到哪个队列。
    static func translate(_ query: String, timeoutMs: Int, completion: @escaping (Translation?, String?) -> Void) {
        guard let credentials = credentials() else {
            completion(nil, "没有配置有道智云凭据")
            return
        }

        let salt = String(Int(Date().timeIntervalSince1970 * 1000))
        let curtime = String(Int(Date().timeIntervalSince1970))
        let signature = sign(appId: credentials.appId, appSecret: credentials.appSecret,
                             query: query, salt: salt, curtime: curtime)

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "from", value: "auto"),
            URLQueryItem(name: "to", value: "auto"),
            URLQueryItem(name: "appKey", value: credentials.appId),
            URLQueryItem(name: "salt", value: salt),
            URLQueryItem(name: "sign", value: signature),
            URLQueryItem(name: "signType", value: "v3"),
            URLQueryItem(name: "curtime", value: curtime)
        ]
        guard let body = form.percentEncodedQuery?.data(using: .utf8),
              let url = URL(string: "https://openapi.youdao.com/api") else {
            completion(nil, "接口地址无效")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(timeoutMs) / 1000.0
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                completion(nil, "网络错误：\(error.localizedDescription)")
                return
            }
            guard let data = data,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                completion(nil, "返回内容无法解析")
                return
            }
            let code = (root["errorCode"] as? String) ?? "?"
            guard code == "0" else {
                completion(nil, "有道智云：" + errorText(code))
                return
            }

            var lines: [String] = []
            if let basic = root["basic"] as? [String: Any] {
                if let explains = basic["explains"] as? [String] {
                    lines.append(contentsOf: explains)
                }
            }
            if let translation = root["translation"] as? [String] {
                for line in translation where !lines.contains(line) {
                    lines.append(line)
                }
            }

            var webLines: [String] = []
            if let web = root["web"] as? [[String: Any]] {
                for item in web {
                    guard let key = item["key"] as? String,
                          let values = item["value"] as? [String],
                          let first = values.first else { continue }
                    webLines.append("\(key)：\(first)")
                    if webLines.count >= 3 { break }
                }
            }

            var phonetic: String?
            if let basic = root["basic"] as? [String: Any] {
                phonetic = (basic["phonetic"] as? String) ?? (basic["us-phonetic"] as? String)
            }

            let result = Translation(
                query: (root["query"] as? String) ?? query,
                phonetic: phonetic,
                lines: lines,
                webLines: webLines,
                engine: "有道智云"
            )
            if result.isEmpty {
                completion(nil, "没查到译文")
            } else {
                completion(result, nil)
            }
        }.resume()
    }
}
