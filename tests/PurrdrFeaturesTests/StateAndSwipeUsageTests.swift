import Foundation
import Testing

/// 左滑、空狀態、頁內錯誤、載入中的統一用法(#626、spec #612)。原始碼守門,prior art:`AlertUsageTests`。
/// - 可刪除、可關閉的列有 trailing `.swipeActions`,而且不標 `role: .destructive`(確認前列不該被系統先移走,0.52.1 閃退的教訓)。
/// - 空狀態用系統 `ContentUnavailableView`,載入第一次用骨架、局部動作用 `ProgressView`。
/// - 頁內錯誤用 `ErrorLabel`(紅色三角說明),不自己拼 `Label(…, systemImage: "exclamationmark.triangle")`。
@Suite("左滑、空狀態、錯誤、載入的用法")
struct StateAndSwipeUsageTests {
    static func source(_ name: String) throws -> String { try AlertUsageTests.source(name) }

    // MARK: - 左滑

    /// 取出每個 `.swipeActions` 後面那一對大括號裡的文字。
    static func swipeBlocks(in source: String) -> [String] {
        var blocks: [String] = []
        var search = source.startIndex
        while let range = source.range(of: ".swipeActions", range: search..<source.endIndex) {
            search = range.upperBound
            guard let open = source[range.upperBound...].firstIndex(of: "{") else { break }
            var depth = 0
            var index = open
            var end = open
            while index < source.endIndex {
                if source[index] == "{" { depth += 1 }
                if source[index] == "}" {
                    depth -= 1
                    if depth == 0 { end = index; break }
                }
                index = source.index(after: index)
            }
            blocks.append(String(source[open...end]))
        }
        return blocks
    }

    @Test("可刪除或可關閉的列都有左滑:通知裝置、登入中的裝置、登入方式、已配對裝置、Tab")
    func removableRowsHaveTrailingSwipe() throws {
        for name in ["PushDevicesSection.swift", "MemberView.swift", "PairedDevicesSection.swift", "WorkspaceActionsViews.swift"] {
            let text = try Self.source(name)
            #expect(text.contains(".swipeActions"), "\(name) 沒有 trailing swipe")
        }
        let member = try Self.source("MemberView.swift")
        #expect(Self.swipeBlocks(in: member).count >= 2, "登入中的裝置與登入方式都要有左滑")
        let push = try Self.source("PushDevicesSection.swift")
        #expect(push.contains(#"Button("Turn Off Notifications""#) && Self.swipeBlocks(in: push).count == 1)
    }

    @Test("左滑按鈕不標 destructive role,紅色用 tint(確認前列不該被系統先移走)")
    func swipeButtonsAreNotDestructive() throws {
        let enumerator = try #require(FileManager.default.enumerator(at: AlertUsageTests.featuresFolder, includingPropertiesForKeys: nil))
        var violations: [String] = []
        var blocks = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for block in Self.swipeBlocks(in: text) {
                blocks += 1
                if block.contains("role: .destructive") { violations.append(url.lastPathComponent) }
            }
        }
        #expect(blocks >= 5)
        #expect(violations.isEmpty, "swipeActions 裡不要 role: .destructive:\(violations)")
    }

    @Test("掃描器:辨識 swipeActions 區塊與裡面的 destructive")
    func scannerFindsDestructiveInSwipe() {
        let bad = Self.swipeBlocks(in: """
        Row().swipeActions { Button("X", role: .destructive) { go() } }
        Other()
        """)
        #expect(bad.count == 1 && bad[0].contains("role: .destructive"))
        let good = Self.swipeBlocks(in: """
        Row().swipeActions(edge: .trailing, allowsFullSwipe: false) { if a { Button("X") { go() }.tint(.red) } }
        .contextMenu { Button("Y", role: .destructive) { go() } }
        """)
        #expect(good.count == 1 && !good[0].contains("destructive"))
    }

    // MARK: - 空狀態與載入

    @Test("空狀態用系統 ContentUnavailableView:通知裝置、流量沒資料、帳號通知沒有主機、新增聊天沒有 Agent、方案用量說明")
    func emptyStatesUseContentUnavailableView() throws {
        for name in ["PushDevicesSection.swift", "DataUsageView.swift", "AccountEntryViews.swift", "NewChatView.swift", "PlanUsageView.swift"] {
            #expect(try Self.source(name).contains("ContentUnavailableView"), "\(name) 的空狀態不是系統空狀態")
        }
        let push = try Self.source("PushDevicesSection.swift")
        let empty = try #require(push.range(of: #"accessibilityIdentifier("account.pushDevices.empty")"#))
        #expect(push[..<empty.lowerBound].suffix(400).contains("ContentUnavailableView"), "通知裝置的空狀態識別碼要掛在系統空狀態上")
        let usage = try Self.source("DataUsageView.swift")
        #expect(!usage.contains("Nothing is counted yet"), "流量沒資料不再只寫在註腳")
        let planUsage = try Self.source("PlanUsageView.swift")
        let message = try #require(planUsage.range(of: "private struct PlanUsageMessage"))
        #expect(planUsage[message.lowerBound...].contains("ContentUnavailableView"), "PlanUsageMessage 不要自己畫圖示加文字")
    }

    @Test("整頁第一次載入用骨架,不是整頁轉圈:裝置清單、Git 變更")
    func firstLoadUsesSkeleton() throws {
        for name in ["PushDevicesSection.swift", "PairedDevicesSection.swift", "ChangesView.swift"] {
            #expect(try Self.source(name).contains("RowsSkeleton("), "\(name) 第一次載入沒有骨架")
        }
        let member = try Self.source("MemberView.swift")
        #expect(member.contains(#"RowsSkeleton(identifier: "account.signInDevices.loading")"#))
        let paired = try Self.source("PairedDevicesSection.swift")
        #expect(!paired.contains("ProgressView()\n                .frame(maxWidth: .infinity)"), "已配對裝置第一次載入不要整頁轉圈")
        let changes = try Self.source("ChangesView.swift")
        #expect(!changes.contains("ProgressView()"), "Git 變更第一次載入不要整頁轉圈")
    }

    // MARK: - 頁內錯誤

    @Test("頁內錯誤一律 ErrorLabel,不自己拼紅色三角 Label(系統空狀態裡的與需求提示除外)")
    func inlineErrorsUseErrorLabel() throws {
        let enumerator = try #require(FileManager.default.enumerator(at: AlertUsageTests.featuresFolder, includingPropertiesForKeys: nil))
        var violations: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" && url.lastPathComponent != "ErrorLabel.swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("Label("), line.contains(#"systemImage: "exclamationmark.triangle""#) else { continue }
                let before = lines[max(0, index - 3)..<index].joined(separator: "\n")
                let after = lines[index..<min(lines.count, index + 3)].joined(separator: "\n")
                if before.contains("ContentUnavailableView") || after.contains("errorLabel:exempt") { continue }
                violations.append("\(url.lastPathComponent):\(index + 1)")
            }
        }
        #expect(violations.isEmpty, "頁內錯誤用 ErrorLabel(需求提示不是錯誤時在該行後 2 行內寫 // errorLabel:exempt 原因):\n\(violations.joined(separator: "\n"))")
    }

    @Test("原本自拼的錯誤列已換成 ErrorLabel")
    func formerInlineErrorsAreErrorLabels() throws {
        let expected = [
            "CodexLauncherSection.swift", "PermissionModeSection.swift", "UsageSectionView.swift", "HostPushSection.swift",
            "PlanUsageView.swift", "PushDevicesSection.swift", "HostOverviewView.swift",
        ]
        for name in expected {
            #expect(try Self.source(name).contains("ErrorLabel("), "\(name) 的頁內錯誤不是 ErrorLabel")
        }
    }

    // MARK: - 做完再送

    @Test("做完再送不能用的原因寫在 footer,不再點了跳 alert")
    func sendWhenDoneReasonIsFooter() throws {
        let views = try Self.source("SendWhenDoneViews.swift")
        #expect(!views.contains(".alert("))
        let sheets = try Self.source("ConversationMenuSheets.swift")
        #expect(sheets.contains("unavailabilityReason"))
    }
}
