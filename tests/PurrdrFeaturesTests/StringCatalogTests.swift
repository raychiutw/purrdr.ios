import Foundation
import Testing

/// String Catalog(`src/App/Purrdr/Localizable.xcstrings`)的完整性(#32)。
///
/// 英文是開發語言(key 就是英文原文);每個要翻譯的字串都要有繁體中文(台灣用語，詞彙依 GLOSSARY.md)。
/// 「程式碼裡的每個字串都在 catalog 裡」由 `scripts/strings.sh check` 以編譯器抽出的字串檢查(CI 也跑)。
@Suite("String Catalog")
struct StringCatalogTests {
    static let catalogURL = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "src/App/Purrdr/Localizable.xcstrings")

    struct Entry {
        var key: String
        var shouldTranslate: Bool
        /// zh-Hant 的所有字串(含複數變化);沒有翻譯時是空陣列。
        var chinese: [String]
        var chineseStates: [String]
    }

    static func entries() throws -> [Entry] {
        let data = try Data(contentsOf: catalogURL)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["sourceLanguage"] as? String == "en")
        let strings = try #require(root["strings"] as? [String: [String: Any]])
        return strings.map { key, value in
            var texts: [String] = []
            var states: [String] = []
            let localization = (value["localizations"] as? [String: Any])?["zh-Hant"] as? [String: Any]
            collectUnits(localization, into: &texts, states: &states)
            return Entry(
                key: key, shouldTranslate: value["shouldTranslate"] as? Bool ?? true, chinese: texts, chineseStates: states
            )
        }
    }

    /// 收集 stringUnit(含 variations 裡的複數／裝置變化)。
    static func collectUnits(_ node: [String: Any]?, into texts: inout [String], states: inout [String]) {
        guard let node else { return }
        if let unit = node["stringUnit"] as? [String: Any] {
            texts.append(unit["value"] as? String ?? "")
            states.append(unit["state"] as? String ?? "")
        }
        for case let child as [String: Any] in (node["variations"] as? [String: Any])?.values.map({ $0 }) ?? [] {
            for case let variation as [String: Any] in child.values {
                collectUnits(variation, into: &texts, states: &states)
            }
        }
    }

    /// printf 格式符(`%@`、`%lld`、`%1$@`…),依出現順序。
    static func specifiers(_ text: String) -> [String] {
        let pattern = /%(?:\d+\$)?(?:ll|l|h)?[@dDuUxXoOfeEgGcCsSpaA]/
        return text.matches(of: pattern).map { String($0.output) }.filter { $0 != "%%" }
    }

    @Test("catalog 存在且至少有設定頁的字串")
    func catalogExists() throws {
        let keys = Set(try Self.entries().map(\.key))
        #expect(keys.contains("Settings"))
        #expect(keys.contains("Rate Purrdr"))
    }

    @Test("每個要翻譯的字串都有繁體中文，狀態是 translated")
    func everyStringHasTraditionalChinese() throws {
        for entry in try Self.entries() where entry.shouldTranslate {
            #expect(!entry.chinese.isEmpty, "「\(entry.key)」沒有繁體中文")
            #expect(entry.chinese.allSatisfy { !$0.isEmpty }, "「\(entry.key)」有空白的繁體中文")
            #expect(entry.chineseStates.allSatisfy { $0 == "translated" }, "「\(entry.key)」的繁體中文不是 translated")
        }
    }

    @Test("繁體中文的格式符與英文相同(數量與型別)")
    func formatSpecifiersMatch() throws {
        for entry in try Self.entries() where entry.shouldTranslate {
            let english = Self.specifiers(entry.key).map { $0.replacing(/\d+\$/, with: "") }.sorted()
            for chinese in entry.chinese {
                let translated = Self.specifiers(chinese).map { $0.replacing(/\d+\$/, with: "") }.sorted()
                #expect(translated == english, "「\(entry.key)」→「\(chinese)」格式符不同")
            }
        }
    }

    /// GLOSSARY.md 的「避免」用詞，以及常見的中國大陸用語(台灣用語為準)。
    static let avoidedWords = [
        "電腦", "伺服器", "機器", "帳號", "帳戶", "授權碼", "會話",
        "信息", "默認", "設置", "文件夾", "屏幕", "軟件", "網絡", "登錄", "用戶", "視頻", "粘貼", "復制", "鏈接",
    ]

    /// 新增主機引導(#341)給沒有電腦概念的人看，指「那台電腦」「帳號」用口語(GLOSSARY「新增主機引導」),
    /// 這些字串的「電腦」「帳號」不算避免用詞;其餘用詞照常檢查。
    static let addHostGuideKeys: Set<String> = [
        "Add This Computer", "Computer name or IP", "First time connecting to this computer",
        "herdr is updated. Restart the herdr server on that computer, then try again.",
        "herdr on that computer is too old. Update herdr there, then try again.",
        "How do you want to connect to your computer?", "Install Tailscale on that computer and sign in.",
        "Install the Purrdr host service for send-when-done and stuck alerts", "Let the computer accept connections",
        "On that computer, open PowerShell, paste this line, then press Enter.",
        "On that computer, open Terminal, paste this line, then press Enter.", "Pick the computer your agents run on.",
        "Purrdr will warn you if this computer’s identity ever changes.", "Recommended · works on most computers",
        "Share to Computer", "Sign in with an account and password or key", "This computer looks different",
        "This computer’s identity is different from the one you trusted before. Someone may be intercepting the connection. Don’t continue unless you changed this computer yourself.",
        "Trust this computer?", "What kind of computer is it?", "Which computer and which account?",
        // 原生 SSH(#342)
        "A public IP or domain name of that computer", "Let this device in",
        "If this account is an administrator, open PowerShell as an administrator and paste this line instead.",
        "On that computer, open PowerShell as an administrator (right-click it and choose Run as administrator).",
        "On that computer, open System Settings, go to General, then Sharing, and turn on Remote Login.",
        "On the same Wi-Fi as that computer", "Paste the private key you already use for that computer.",
        "Set up your router first so connections from outside can reach this computer.",
        "The password you use to sign in to that computer", "Type the password you use to sign in to that computer.",
    ]

    @Test("繁體中文不用 GLOSSARY 避免的詞與中國大陸用語")
    func usesGlossaryTerms() throws {
        for entry in try Self.entries() {
            // 「Apple 帳號」是 iOS 系統設定裡的正式名稱(引導使用者去取消訂閱時要照抄)。
            // 「帳號」單獨出現是帳號頁與帳號鈕的畫面名稱(GLOSSARY「帳號頁」);用來指會員身分仍要避免。
            let texts = entry.chinese.filter { $0 != "帳號" }
            for chinese in texts.map({ $0.replacingOccurrences(of: "Apple 帳號", with: "") }) {
                for word in Self.avoidedWords {
                    if Self.addHostGuideKeys.contains(entry.key), word == "電腦" || word == "帳號" { continue }
                    #expect(!chinese.contains(word), "「\(entry.key)」→「\(chinese)」用了「\(word)」")
                }
            }
        }
    }

    /// 帶數量、單數與複數寫法不同的字串:英文要有 plural 變化(`one`／`other`),不能寫「1 images」。
    static let pluralKeys = [
        "%lld Images", "%lld comments", "%lld files", "%lld devices", "%lld hosts", "%lld turns",
    ]

    @Test("帶數量的字串用 plural 變化，不寫死複數(1 images)")
    func countedStringsUsePlurals() throws {
        let data = try Data(contentsOf: Self.catalogURL)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: [String: Any]])
        for key in Self.pluralKeys {
            let entry = try #require(strings[key], "catalog 沒有「\(key)」")
            let english = (entry["localizations"] as? [String: Any])?["en"] as? [String: Any]
            let plural = (english?["variations"] as? [String: Any])?["plural"] as? [String: Any]
            #expect(plural?["one"] != nil && plural?["other"] != nil, "「\(key)」沒有英文的 one／other 複數變化")
        }
    }
}
