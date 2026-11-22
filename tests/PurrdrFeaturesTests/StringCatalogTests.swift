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

    /// 已採新詞「主機」的字串(#390),等 #394 反轉規則。
    static let newHostWording: Set<String> = [
        "Add Host…", "Add a host to browse its files.", "Files Aren’t Available",
        "Files need an SSH connection. This host connects through the host service.", "No Hosts",
        "Not available on this host", "Git isn’t installed on the host", "Update the host service",
    ]

    /// GLOSSARY.md 的「避免」用詞，以及常見的中國大陸用語(台灣用語為準)。
    static let avoidedWords = [
        "伺服器", "機器", "帳戶", "授權碼", "會話",
        "信息", "默認", "設置", "文件夾", "屏幕", "軟件", "網絡", "登錄", "用戶", "視頻", "粘貼", "復制", "鏈接",
    ]

    @Test("繁體中文不用 GLOSSARY 避免的詞與中國大陸用語")
    func usesGlossaryTerms() throws {
        for entry in try Self.entries() {
            // 「電腦」「帳號」畫面可用(2026-11-21 使用者決定,見 GLOSSARY),不在避免清單。
            for chinese in entry.chinese {
                for word in Self.avoidedWords {
                    #expect(!chinese.contains(word), "「\(entry.key)」→「\(chinese)」用了「\(word)」")
                }
            }
        }
    }

    /// 畫面文字給沒有電腦概念的人看(#331,AGENTS.md):繁中對使用者說「電腦」「帳號」,不留「主機」「使用者名稱」。
    @Test("繁體中文畫面文字不用「主機」「使用者名稱」(畫面稱電腦、帳號)")
    func chineseUsesComputerAndAccountWording() throws {
        for entry in try Self.entries() {
            // 新詞彙(2026-11-22,GLOSSARY)已改稱「主機」,#390 的 tab 字串先用新詞;#394 反轉這條規則後整個例外與測試一起換掉。
            if Self.newHostWording.contains(entry.key) { continue }
            for chinese in entry.chinese {
                for word in ["主機", "使用者名稱"] {
                    #expect(!chinese.contains(word), "「\(entry.key)」→「\(chinese)」用了「\(word)」，畫面請說電腦／帳號")
                }
            }
        }
    }

    /// GLOSSARY「新增主機引導」:畫面上 OpenSSH 稱「原生 SSH」,不另外叫「內建 SSH」。
    @Test("繁體中文稱「原生 SSH」,不用「內建 SSH」")
    func chineseCallsOpenSSHNative() throws {
        for entry in try Self.entries() {
            for chinese in entry.chinese {
                #expect(!chinese.contains("內建 SSH"), "「\(entry.key)」→「\(chinese)」請改稱原生 SSH")
            }
        }
    }

    /// 英文畫面文字維持 Host(GLOSSARY「用詞對應」):不用 Computer 稱呼主機。
    /// 日常語意(「that computer」、電腦版面)不在此限。
    @Test("英文畫面文字不用 Computer 稱呼主機(日常語意的小寫 computer 除外)")
    func englishUsesHostWording() throws {
        for entry in try Self.entries() {
            #expect(!entry.key.contains("Computer"), "「\(entry.key)」用了 Computer,英文請說 host")
        }
    }

    /// 不該出現在一般使用者看得到的文字裡的技術細節(路徑、sshd、tailnet、Secure Enclave…);
    /// 要給使用者的指令請寫成獨立的可拷貝指令,不要夾在說明裡。
    static let technicalDetails = ["~/", "authorized_keys", "sshd", "tailnet", "Secure Enclave", "PATH", "keychain", "passphrase protect"]
    /// 只是輸入欄的範例文字，不是說明。
    static let technicalDetailExemptKeys: Set<String> = ["my-mac.tailnet.ts.net"]

    @Test("畫面說明不帶路徑、sshd、tailnet 等技術細節")
    func noTechnicalDetailsInExplanations() throws {
        for entry in try Self.entries() where !Self.technicalDetailExemptKeys.contains(entry.key) {
            for text in [entry.key] + entry.chinese {
                for word in Self.technicalDetails {
                    #expect(!text.contains(word), "「\(entry.key)」含技術細節「\(word)」")
                }
            }
        }
    }

    /// 帶數量、單數與複數寫法不同的字串:英文要有 plural 變化(`one`／`other`),不能寫「1 images」。
    static let pluralKeys = [
        "%lld Attachments", "%lld comments", "%lld files", "%lld devices", "%lld hosts", "%lld turns",
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
