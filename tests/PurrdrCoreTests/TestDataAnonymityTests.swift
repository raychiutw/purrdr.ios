import Foundation
import Testing

/// 公開 repo 的測試資料去識別化(#693):原始碼、測試與錄製檔裡只能出現假的 tailnet 名稱與保留網域的 email。
///
/// 規則不列任何真實值,而是只放行已知的假值,所以新加進來的真實名稱一律會被擋下。
/// 比照 `PortableCoreImportTests` 掃原始碼(`swift test`,CI 也跑)。
@Suite("測試資料去識別化")
struct TestDataAnonymityTests {
    static let scannedDirectories = ["src", "tests", "scripts", ".github"]
    /// `*.ts.net` 的 tailnet 代號(主機名稱之後的那一段)只能是這些。只有一段(`studio.ts.net`)沒有真實代號,放行。
    static let allowedTailnetLabels: Set<String> = ["tail1234", "tailnet", "example"]
    /// email 的網域只能是保留網域(RFC 2606);`aes256-gcm@openssh.com` 是加密演算法名稱,不是信箱。
    static let allowedEmailDomains: Set<String> = ["example.com", "example.org", "example.net", "openssh.com"]

    // swiftlint:disable:next force_try
    static let tailnetPattern = try! NSRegularExpression(pattern: #"([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*)\.ts\.net\b"#)
    // swiftlint:disable:next force_try
    static let emailPattern = try! NSRegularExpression(pattern: #"[A-Za-z0-9._%+*-]+@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)"#)

    /// 回傳這段文字裡不合規的種類(不帶命中的內容,避免真實值進到 log)。
    static func violations(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        var found: [String] = []
        for match in tailnetPattern.matches(in: text, range: range) {
            let labels = text[Range(match.range(at: 1), in: text)!].lowercased().split(separator: ".")
            if labels.count >= 2, let tailnet = labels.last, !allowedTailnetLabels.contains(String(tailnet)) {
                found.append("tailnet 名稱")
            }
        }
        for match in emailPattern.matches(in: text, range: range) {
            let domain = text[Range(match.range(at: 1), in: text)!].lowercased()
            // ssh 的 `user@主機`:IP 位址與 `*.ts.net`(由 tailnet 規則檢查)不是信箱。
            if domain.hasSuffix(".ts.net") || domain.allSatisfy({ $0.isNumber || $0 == "." }) { continue }
            if !allowedEmailDomains.contains(domain) { found.append("email 網域") }
        }
        return found
    }

    @Test("src、tests、scripts 與 CI 設定裡沒有真實的 tailnet 名稱或 email")
    func sourcesContainOnlyFakeIdentities() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var violations: [String] = []
        var scanned = 0
        for directory in Self.scannedDirectories {
            let files = FileManager.default.enumerator(at: root.appending(path: directory), includingPropertiesForKeys: [.isRegularFileKey])?
                .compactMap { $0 as? URL } ?? []
            for file in files where !file.path.contains("/.build/") && !file.path.contains("/.derivedData/") {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else { continue }
                scanned += 1
                let hits = Self.violations(in: text)
                if !hits.isEmpty {
                    violations.append("\(file.path.replacingOccurrences(of: root.path + "/", with: "")): \(Set(hits).sorted())")
                }
            }
        }
        #expect(scanned > 0, "沒有掃到任何檔案,路徑可能錯了")
        #expect(violations.isEmpty, "有看起來像真實身分的 tailnet 名稱或 email:\(violations)")
    }

    @Test("規則放行假值、擋下其他 tailnet 與 email 網域")
    func ruleAcceptsFakeAndRejectsOthers() {
        // 以字串相接組成樣本,原始碼不放完整的「像真的」值。
        let realTailnet = "host.tail" + "9f3a2c.ts.net"
        let realEmail = "someone@" + "mail" + "box.test"
        #expect(Self.violations(in: "host.tail1234.ts.net studio.ts.net my-mac.tailnet.ts.net a@example.org x@example.com").isEmpty)
        #expect(Self.violations(in: realTailnet) == ["tailnet 名稱"])
        #expect(Self.violations(in: realEmail) == ["email 網域"])
        #expect(Self.violations(in: "a***@" + "privaterelay.appleid.com") == ["email 網域"])
    }
}
