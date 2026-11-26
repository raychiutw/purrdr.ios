import Foundation
import PurrdrCore
import Testing
@testable import PurrdrAgentFeatures

/// 操作記錄(#637):顯示給使用者的錯誤進診斷記錄。
@MainActor
struct ErrorRecordTests {
    private struct HostNamedError: Error { let host: String }

    @Test("開關打開才記錯誤、關閉不記")
    func recordsOnlyWhenEnabled() {
        let id = UUID()
        let on = HitchHarness(enabled: true)
        on.recorder.errorShown(instance: id, fingerprint: 1, descriptor: ErrorDescriptor(HerdrError.deadlineExceeded), area: "NewChat")
        #expect(on.sink.entries == [.error(ErrorRecord(
            category: "HerdrError", code: "deadlineExceeded", area: "NewChat", at: Date(timeIntervalSince1970: 1_800_000_000)))])

        let off = HitchHarness(enabled: false)
        off.recorder.errorShown(instance: id, fingerprint: 1, descriptor: ErrorDescriptor(HerdrError.deadlineExceeded), area: "NewChat")
        #expect(off.sink.entries.isEmpty)
    }

    @Test("記錄只有類別、錯誤碼、功能區與時間,含主機名稱與路徑的錯誤原文不會出現")
    func neverContainsMessageText() {
        let secret = "studio.tail1234.ts.net /Users/ray/secret"
        let errors: [any Error] = [
            HerdrError.noResponse(exitCode: 1, stderr: secret), HerdrError.herdr(code: "pane_not_found", message: secret),
            HostNamedError(host: secret), NSError(domain: "X", code: 7, userInfo: [NSLocalizedDescriptionKey: secret]),
        ]
        let harness = HitchHarness(enabled: true)
        for error in errors {
            harness.recorder.errorShown(instance: UUID(), fingerprint: 1, descriptor: ErrorDescriptor(error), area: "Test")
        }
        // 指紋(訊息的雜湊)也不寫進記錄。
        harness.recorder.errorShown(
            instance: UUID(), fingerprint: secret.hashValue,
            descriptor: DisplayedError(secret, category: "Test", code: "fixed").descriptor, area: "Test")
        let lines = harness.sink.entries.map(DiagnosticLogEncoder.line)
        #expect(lines.count == 5)
        for line in lines {
            #expect(!line.contains("studio"))
            #expect(!line.contains("/Users"))
            #expect(!line.contains("\(secret.hashValue)"))
            #expect(line.contains(#""kind":"error""#))
            #expect(line.contains(#""area":"Test""#))
        }
        #expect(lines[1].contains(#""code":"pane_not_found""#))
        #expect(lines[3].contains(#""code":"X:7""#))
    }

    @Test("同一個錯誤持續顯示只記一次,重繪不重複;內容換了或消失後再出現才再記")
    func recordsOncePerDisplay() {
        let harness = HitchHarness(enabled: true)
        let id = UUID()
        let descriptor = ErrorDescriptor(HerdrError.malformedResponse)
        for _ in 0..<3 { harness.recorder.errorShown(instance: id, fingerprint: 42, descriptor: descriptor, area: "A") }
        #expect(harness.sink.entries.count == 1)
        harness.recorder.errorShown(instance: id, fingerprint: 43, descriptor: descriptor, area: "A")
        #expect(harness.sink.entries.count == 2)
        harness.recorder.errorHidden(instance: id)
        harness.recorder.errorShown(instance: id, fingerprint: 43, descriptor: descriptor, area: "A")
        #expect(harness.sink.entries.count == 3)
    }

    @Test("閃退不論開關都記;開關偏好沿用既有 key")
    func crashAlwaysRecordedAndPreferenceKeyKept() {
        #expect(HitchLogSettings.enabledKey == "diagnostics.hitchLog")
        let off = HitchHarness(enabled: false)
        #expect(!off.recorder.isEnabled)
        off.recorder.recordCrash(CrashRecord(
            timestamp: Date(timeIntervalSince1970: 1), name: "N", reason: "R", environment: .unknown))
        #expect(off.sink.entries.count == 1)
    }
}

/// 畫面 model 保留的錯誤值(#637):顯示文字與記錄用的類別、錯誤碼出自同一個值。
struct DisplayedErrorTests {
    private static let secret = "studio.tail1234.ts.net /Users/ray/secret ghp_token"

    /// 每一種錯誤型別對應的類別與錯誤碼(帶關聯值的只取 case 名稱,herdr 的 code 例外)。
    @Test("每種錯誤型別對應的類別與錯誤碼", arguments: [
        (HostServiceError.paneChanged as any Error, "HostServiceError", "paneChanged"),
        (HostServiceError.hostServiceUpdateRequired(.tabRename, installedVersion: "0.1.0") as any Error, "HostServiceError", "hostServiceUpdateRequired"),
        (HerdrError.herdr(code: "pane_not_found", message: secret) as any Error, "HerdrError", "pane_not_found"),
        (HerdrError.deadlineExceeded as any Error, "HerdrError", "deadlineExceeded"),
        (SSHConnectionError.timedOut as any Error, "SSHConnectionError", "timedOut"),
        (SSHKeyImportError.rsaNotSupported as any Error, "SSHKeyImportError", "rsaNotSupported"),
        (PermissionModeFailure.keysFailed(target: .auto) as any Error, "PermissionModeFailure", "keysFailed"),
        (QueuedPrompt.Problem.expired as any Error, "QueuedPrompt.Problem", "expired"),
        (EchoFailure.noResponse as any Error, "EchoFailure", "noResponse"),
        (NSError(domain: "X", code: 7, userInfo: [NSLocalizedDescriptionKey: secret]) as any Error, "NSError", "X:7"),
    ])
    func descriptorTable(error: any Error, category: String, code: String) {
        let shown = DisplayedError(error: error)
        #expect(shown.descriptor == ErrorDescriptor(category: category, code: code))
        #expect(shown.descriptor == ErrorDescriptor(error))
        #expect(!shown.descriptor.category.contains("studio"))
        #expect(!shown.descriptor.code.contains("/Users"))
    }

    @Test("說明文字與描述是同一個值產生的;說明含主機名稱時描述仍不含")
    func textAndDescriptorTravelTogether() {
        let shown = DisplayedError(Self.secret, error: HerdrError.herdr(code: "folder_not_found", message: Self.secret))
        #expect(shown.text == Self.secret)
        #expect(shown.descriptor.code == "folder_not_found")
        #expect("\(shown.descriptor)".contains("studio") == false)
        #expect("\(shown.descriptor)".contains("ghp_") == false)
    }

    @Test("沒有 Swift 錯誤的情境用明確的領域類別,不再有 Message / unspecified")
    func domainCategories() {
        let shown = DisplayedError("text", category: "SendWhenDone", code: "sessionUnknown")
        #expect(shown.descriptor == ErrorDescriptor(category: "SendWhenDone", code: "sessionUnknown"))
    }

    @Test("畫面 model 的錯誤帶真正的類別與碼")
    @MainActor
    func modelsKeepRealErrors() {
        let actions = WorkspaceActionsModel.displayed(for: HerdrError.herdr(code: "workspace_group_close_required", message: Self.secret))
        #expect(actions.descriptor == ErrorDescriptor(category: "HerdrError", code: "workspace_group_close_required"))
        #expect(actions.text == WorkspaceActionsModel.groupCloseRequiredMessage)
    }
}

/// 原始碼守門(#637):`ErrorLabel(` 呼叫一律帶 `error:`,不靠顯示字串反查。
struct ErrorLabelCallSiteTests {
    @Test("ErrorLabel 的每個呼叫都帶 error:")
    func everyCallCarriesError() throws {
        let enumerator = try #require(FileManager.default.enumerator(at: AlertUsageTests.featuresFolder, includingPropertiesForKeys: nil))
        var violations: [String] = []
        var calls = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" && url.lastPathComponent != "ErrorLabel.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            var search = text.startIndex..<text.endIndex
            while let range = text.range(of: "ErrorLabel(", range: search) {
                search = range.upperBound..<text.endIndex
                if range.lowerBound > text.startIndex, text[text.index(before: range.lowerBound)].isLetter { continue }
                var depth = 1
                var index = range.upperBound
                while index < text.endIndex, depth > 0 {
                    if text[index] == "(" { depth += 1 } else if text[index] == ")" { depth -= 1 }
                    index = text.index(after: index)
                }
                calls += 1
                let call = String(text[range.upperBound..<index])
                if !call.contains("error:") {
                    let line = text[..<range.lowerBound].filter { $0 == "\n" }.count + 1
                    violations.append("\(url.lastPathComponent):\(line)")
                }
            }
        }
        #expect(calls >= 20, "沒掃到呼叫,守門失效")
        #expect(violations.isEmpty, "ErrorLabel 要帶 error:(DisplayedError.descriptor 或錯誤值):\n\(violations.joined(separator: "\n"))")
    }

    @Test("說明文字反查機制已移除")
    func registryIsGone() throws {
        let agentFeatures = AlertUsageTests.featuresFolder.deletingLastPathComponent().appendingPathComponent("PurrdrAgentFeatures")
        let enumerator = try #require(FileManager.default.enumerator(at: agentFeatures, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("ErrorMessageRegistry"), "\(url.lastPathComponent)")
        }
    }
}
