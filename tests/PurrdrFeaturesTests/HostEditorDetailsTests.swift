import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 技術細節預設收合(#359):指紋、herdr Path 與 Session 收進「詳細資訊」，
/// 只有主機已有自訂 herdr 設定時才一打開就展開;要使用者在電腦上執行的指令是固定字串(畫面給拷貝鈕)。
@MainActor
@Suite("主機編輯頁：詳細資訊預設收合")
struct HostEditorDetailsTests {
    @Test("新主機的詳細資訊預設收合")
    func collapsedByDefault() {
        let model = HostEditorConnectionFieldsTests.newEditor()

        #expect(model.detailsExpandedInitially == false)
    }

    @Test(
        "有自訂 herdr 路徑或 Session 才一打開就展開",
        arguments: [("/opt/herdr", ""), ("", "work"), ("/opt/herdr", "work")])
    func expandedWithCustomHerdrSettings(path: String, session: String) {
        let model = HostEditorConnectionFieldsTests.newEditor()
        model.herdrPath = path
        model.herdrSession = session

        #expect(model.detailsExpandedInitially)
    }

    @Test("主機服務配對指令與比對指紋的指令是可拷貝的固定字串")
    func commandsForCopying() {
        #expect(HostEditorModel.hostServicePairCommand == "purrdr-host-service pair")
        #expect(HostKeyFingerprint.compareCommand.hasPrefix("ssh-keygen -lf "))
        #expect(!HostKeyFingerprint.compareCommand.contains("<"), "不能留佔位符,拷貝後才能直接執行")
    }
}
