import Foundation

/// 偵測到的機密類別(#302)。只有類別，畫面依它顯示名稱，不顯示內容本身。
public enum SecretKind: String, Sendable, Equatable, CaseIterable {
    case privateKey
    case gitHubToken
    case skKey
    case awsKey
    case slackToken
    case googleAPIKey
    case jwt
    case password
}

/// 一處像機密的內容：類別與在第幾行(從 1 起算)。刻意不帶比對到的文字，避免內容被顯示或記錄。
public struct SecretFinding: Sendable, Equatable, Hashable {
    public let kind: SecretKind
    public let line: Int

    public init(kind: SecretKind, line: Int) {
        self.kind = kind
        self.line = line
    }
}

/// 機密偵測的規則(#302,spec #298):全部集中在這裡(正則加上長度與字元條件),只在本機判斷，不把內容送到任何地方。
/// 寧可少報也不要每則訊息都跳確認：只認有固定前綴或明確「指定值」寫法的內容;誤判時使用者可以「仍要送出」。
public enum SecretDetection {
    /// 掃描文字，回傳依行號排序的偵測結果(同一行同一類只算一次)。
    public static func scan(_ text: String) -> [SecretFinding] {
        var findings: [SecretFinding] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(line)
            for rule in Rule.all where rule.matches(line) {
                findings.append(SecretFinding(kind: rule.kind, line: index + 1))
            }
        }
        return findings
    }

    /// 一條規則：任一個正則比對到、且比對結果通過條件，就算這一類。
    /// `@unchecked`:`NSRegularExpression` 沒標 Sendable,但建好後不可變、官方保證可跨執行緒比對;其餘都是 `let`。
    private struct Rule: @unchecked Sendable {
        let kind: SecretKind
        /// `NSRegularExpression` 建好後只讀，多執行緒共用安全。
        let patterns: [NSRegularExpression]
        /// 比對結果(第 1 個擷取群組;沒有群組時是整段)的額外條件。
        let accepts: @Sendable (String) -> Bool

        init(_ kind: SecretKind, _ patterns: [String], accepts: @escaping @Sendable (String) -> Bool = { _ in true }) {
            self.kind = kind
            // 規則是固定字串，編不過是程式錯誤。
            self.patterns = patterns.map { try! NSRegularExpression(pattern: $0) }
            self.accepts = accepts
        }

        func matches(_ line: String) -> Bool {
            let whole = NSRange(line.startIndex..., in: line)
            for pattern in patterns {
                for match in pattern.matches(in: line, range: whole) {
                    let group = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                    guard let range = Range(group, in: line) else { continue }
                    if accepts(String(line[range])) { return true }
                }
            }
            return false
        }

        static let all: [Rule] = [
            // PEM／OpenSSH／PGP 私鑰的開頭(公鑰與憑證不算)。
            Rule(.privateKey, [#"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----"#]),
            // GitHub:ghp_／gho_／ghu_／ghs_／ghr_ 加 36 字以上;fine-grained 的 github_pat_。
            Rule(.gitHubToken, [
                #"(?<![A-Za-z0-9_])gh[pousr]_[A-Za-z0-9]{36,}"#,
                #"(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9_]{22,}"#,
            ]),
            // sk- 開頭(OpenAI、Anthropic)與 Stripe 的 sk_live_／sk_test_:20 字以上，且同時有字母與數字(排除 sk-learn 之類的字詞)。
            Rule(.skKey, [#"(?<![A-Za-z0-9_-])(sk[-_][A-Za-z0-9_-]{20,})"#]) { value in
                value.contains(where: \.isNumber) && value.dropFirst(3).contains(where: \.isLetter)
            },
            // AWS:access key id(AKIA／ASIA 加 16 個大寫英數),與指定給 aws_secret_access_key 的 40 字值。
            Rule(.awsKey, [
                #"(?<![A-Za-z0-9])(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Za-z0-9])"#,
                #"(?i)aws_secret_access_key["']?\s*[=:]\s*["']?[A-Za-z0-9/+=]{40}(?![A-Za-z0-9/+=])"#,
            ]),
            // Slack:xoxb／xoxp 等 token 與 incoming webhook 網址。
            Rule(.slackToken, [
                #"(?<![A-Za-z0-9])xox[abposr]-[A-Za-z0-9-]{10,}"#,
                #"https://hooks\.slack\.com/services/T[A-Za-z0-9]+/B[A-Za-z0-9]+/[A-Za-z0-9]{16,}"#,
            ]),
            // Google API key:AIza 加剛好 35 字。
            Rule(.googleAPIKey, [#"(?<![A-Za-z0-9_-])AIza[0-9A-Za-z_-]{35}(?![0-9A-Za-z_-])"#]),
            // JWT:三段 base64url,前兩段(header、payload)是 JSON 物件，所以是 eyJ 開頭。
            Rule(.jwt, [#"(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#]),
            // password=:以 = 指定的值(含 DB_PASSWORD=),或 JSON／YAML 以冒號指定的帶引號值;
            // 值要 4 字以上，變數($X、${X}、%X%)、佔位符(<…>)與遮罩(****)不算。
            Rule(.password, [
                #"(?i)(?<![A-Za-z0-9])(?:[A-Za-z0-9]+_)*(?:password|passwd|pwd)["']?\s*=(?!=)\s*("[^"]*"|'[^']*'|\S+)"#,
                #"(?i)(?<![A-Za-z0-9])(?:[A-Za-z0-9]+_)*(?:password|passwd|pwd)["']?\s*:\s*("[^"]*"|'[^']*')"#,
            ]) { raw in
                var value = Substring(raw)
                if let first = value.first, first == "\"" || first == "'", value.count >= 2 {
                    value = value.dropFirst().dropLast()
                }
                guard value.count >= 4, let first = value.first else { return false }
                if "$<{%".contains(first) { return false }
                return !value.allSatisfy { $0 == "*" || $0 == "•" }
            },
        ]
    }
}
