import Foundation
import Testing

/// alert 與確認對話框的用法(#625、spec #612,HIG Alerts):
/// - 使用者自己發起的刪除、登出、關閉用底部 `confirmationDialog`,不用中央 alert(刪除會員與「仍要登出」除外)。
/// - alert 只在需要使用者決定或擋住流程時用:純告知改頁內說明,所以每個檔案的 `.alert(` 數量有上限,新增要在這裡登記並說明理由。
/// - 有其他動作時取消鈕不叫「OK」。
@Suite("alert 用法")
struct AlertUsageTests {
    /// 每個檔案允許的 `.alert(` 數量(都是需要決定、擋住流程或要輸入文字的);沒列的檔案不允許有 alert。
    static let alertAllowance: [String: Int] = [
        "PlusView.swift": 1,  // 要先登入、購買失敗等需確認的訂閱結果
        "HostEditorView.swift": 2,  // 主機身分變了、更新 herdr
        "PaneTerminalView.swift": 1,  // 終端機要寫入剪貼簿的同意
        "AccountEntryViews.swift": 3,  // 加入流程的購買失敗、找不到會員、帳號結果通知(後兩者掛在 NavigationStack 外層,#623)
        "HostThemeViews.swift": 1,  // 主機主題同意
        "PlanUsageView.swift": 1,  // 方案用量同意
        "PushDevicesSection.swift": 1,  // 重新命名(輸入文字)
        "MemberView.swift": 4,  // 訂閱結果、鎖定提示、Plus 已開啟、刪除會員、重新命名
        "WorkspaceActionsViews.swift": 2,  // 重新命名(輸入文字)、關閉失敗
        "CodexLauncherSection.swift": 1,  // Codex 啟動器同意
    ]

    static var featuresFolder: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "src/PurrdrFeatures")
    }

    static func source(_ name: String) throws -> String {
        try String(contentsOf: featuresFolder.appending(path: name), encoding: .utf8)
    }

    @Test("每個檔案的 alert 數量不超過登記的上限")
    func alertCountsStayWithinAllowance() throws {
        let enumerator = try #require(FileManager.default.enumerator(at: Self.featuresFolder, includingPropertiesForKeys: nil))
        var violations: [String] = []
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let name = url.lastPathComponent
            let count = try String(contentsOf: url, encoding: .utf8).components(separatedBy: ".alert(").count - 1
            let allowed = Self.alertAllowance[name, default: 0]
            if count > allowed { violations.append("\(name):\(count) 個 alert(允許 \(allowed))") }
        }
        #expect(scanned > 10)
        #expect(violations.isEmpty, "純告知改頁內說明,需要決定的才用 alert:\n\(violations.joined(separator: "\n"))")
    }

    @Test("使用者發起的移除與登出用 confirmationDialog,不用中央 alert")
    func destructiveConfirmationsUseDialog() throws {
        let hosts = try Self.source("HostsTab.swift")
        #expect(!hosts.contains(".alert("))
        // 移除主機的確認對話框掛在「Remove Host」按鈕上(HostOverviewView,#625)。
        let overview = try Self.source("HostOverviewView.swift")
        #expect(overview.contains(".confirmationDialog("))
        let member = try Self.source("MemberView.swift")
        #expect(!member.contains(#".alert("Sign Out?""#))
        #expect(member.contains(#".confirmationDialog("Sign Out?""#))
        #expect(member.contains(#".alert("Delete Member?""#), "刪除會員後果最嚴重,保留 alert")
    }

    /// `.confirmationDialog(` 所在修飾鏈的起頭(往上找第一個縮排較淺、或同縮排但不是 `.`／`}` 開頭的行)。
    static func chainHead(_ lines: [String], dialogAt index: Int) -> String {
        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        let level = indent(lines[index])
        var i = index - 1
        while i >= 0 {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("//") { i -= 1; continue }
            let current = indent(line)
            if current > level { i -= 1; continue }
            if current == level, trimmed.hasPrefix(".") || trimmed.hasPrefix("}") { i -= 1; continue }
            return trimmed
        }
        return ""
    }

    /// 違規:`.confirmationDialog(` 的修飾鏈起頭不是 Button／Menu,上面也沒有 `// confirmationDialog:anchor <原因>`(#625)。
    static func unanchoredDialogs(file: String, lines: [String]) -> [String] {
        var result: [String] = []
        for (index, line) in lines.enumerated() where line.contains(".confirmationDialog(") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            let head = chainHead(lines, dialogAt: index)
            let anchoredToButton = head.hasPrefix("Button(") || head.hasPrefix("Button {") || head.hasPrefix("Menu")
            let attested = lines[max(0, index - 2) ... index].contains { $0.contains("confirmationDialog:anchor") }
            if !anchoredToButton, !attested { result.append("\(file):\(index + 1)(起頭:\(head))") }
        }
        return result
    }

    @Test("確認對話框掛在觸發的 Button／Menu 上,不掛整個畫面(#625,iOS 26 錨定在按鈕)")
    func confirmationDialogsAnchorToTrigger() throws {
        let enumerator = try #require(FileManager.default.enumerator(at: Self.featuresFolder, includingPropertiesForKeys: nil))
        var violations: [String] = []
        var dialogs = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.components(separatedBy: "\n")
            dialogs += lines.filter { $0.contains(".confirmationDialog(") }.count
            violations += Self.unanchoredDialogs(file: url.lastPathComponent, lines: lines)
        }
        #expect(dialogs >= 10, "掃不到確認對話框(掃描規則壞了?)")
        #expect(violations.isEmpty, "確認對話框要掛在觸發的 Button/Menu 上;從滑動或選單觸發的,掛在那一列並在上面寫 // confirmationDialog:anchor 原因:\n\(violations.joined(separator: "\n"))")
    }

    @Test("掃描:掛在整個畫面的確認對話框會被抓到,掛在 Button 或有註記的會過")
    func scannerCatchesScreenLevelDialog() {
        let screen = """
        var body: some View {
            List {
                Button("Remove") { go() }
            }
            .appGroupedList()
            .confirmationDialog("Sure?", isPresented: $p) {
                Button("Yes") {}
            }
        }
        """.components(separatedBy: "\n")
        #expect(!Self.unanchoredDialogs(file: "S.swift", lines: screen).isEmpty)
        let button = """
        Button("Remove") { go() }
            .accessibilityIdentifier("x")
            .confirmationDialog("Sure?", isPresented: $p) {
                Button("Yes") {}
            }
        """.components(separatedBy: "\n")
        #expect(Self.unanchoredDialogs(file: "B.swift", lines: button).isEmpty)
        let attested = """
        Row()
            // confirmationDialog:anchor 由滑動觸發
            .confirmationDialog("Sure?", isPresented: $p) {}
        """.components(separatedBy: "\n")
        #expect(Self.unanchoredDialogs(file: "A.swift", lines: attested).isEmpty)
    }

    @Test("被取代的籠統標題與純告知 alert 已移除")
    func noGenericOrInformationalAlertTitles() throws {
        let forbidden = [#".alert("Can’t Paste""#, #".alert("Can’t Upload""#, #".alert("Couldn’t Finish""#, ".alert(resultTitle", #".alert("Send When Done""#]
        let enumerator = try #require(FileManager.default.enumerator(at: Self.featuresFolder, includingPropertiesForKeys: nil))
        var violations: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for pattern in forbidden where text.contains(pattern) {
                violations.append("\(url.lastPathComponent):\(pattern)")
            }
        }
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("有其他動作的 alert 取消鈕用「Not Now」,不用「OK」")
    func cancelButtonsAreNotOK() throws {
        let plus = try Self.source("PlusView.swift")
        let member = try Self.source("MemberView.swift")
        #expect(plus.contains(#"Button("Not Now", role: .cancel)"#), "要先登入的 alert")
        #expect(member.contains(#"Button("Not Now", role: .cancel)"#), "鎖定提示")
    }
}
