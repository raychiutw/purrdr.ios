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
        // 只有字串的呼叫端,指紋(訊息的雜湊)也不寫進記錄。
        harness.recorder.errorShown(instance: UUID(), fingerprint: secret.hashValue, descriptor: .message, area: "Test")
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

/// 顯示字串 → 錯誤類別與錯誤碼(#637):畫面只有字串時,記錄仍有真正的類別與錯誤碼。
@MainActor
struct ErrorMessageRegistryTests {
    @Test("HostErrorText 轉出的說明,以字串查回錯誤的類別與 case 名稱")
    func lookupAfterConversion() {
        ErrorMessageRegistry.reset()
        let text = HostErrorText.message(for: HostServiceError.paneChanged)
        #expect(ErrorMessageRegistry.descriptor(for: text) == ErrorDescriptor(category: "HostServiceError", code: "paneChanged"))
        let herdr = HostErrorText.message(for: HerdrError.herdr(code: "pane_not_found", message: "studio /Users/ray/secret"))
        #expect(ErrorMessageRegistry.descriptor(for: herdr)?.code == "pane_not_found")
    }

    @Test("沒轉換過的固定文字查不到,記成 Message;登錄只存類別與碼、不含原文")
    func unknownAndNoLeak() {
        ErrorMessageRegistry.reset()
        #expect(ErrorMessageRegistry.descriptor(for: "Unknown text") == nil)
        let secret = "studio.tail1234.ts.net"
        let text = HostErrorText.message(for: HerdrError.herdr(code: "x", message: secret))
        let found = ErrorMessageRegistry.descriptor(for: text)
        #expect(found.map { !$0.category.contains("studio") && !$0.code.contains("studio") } == true)
    }

    @Test("登錄只留最近 64 筆")
    func bounded() {
        ErrorMessageRegistry.reset()
        for i in 0..<100 { ErrorMessageRegistry.note("m\(i)", .message) }
        #expect(ErrorMessageRegistry.descriptor(for: "m0") == nil)
        #expect(ErrorMessageRegistry.descriptor(for: "m99") != nil)
    }
}
