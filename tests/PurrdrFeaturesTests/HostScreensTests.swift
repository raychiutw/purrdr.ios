import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrHTTPS
import PurrdrTestSupport
import Testing

/// 跨主機的畫面 model 工廠(#564,`HostScreens`):主機挑選、數據用量、方案用量、新增／編輯主機。
/// 目前主機的預設值另見 `CurrentHostTests`;這裡看每個工廠的選項、範圍與錯誤。
@MainActor
@Suite("跨主機的畫面 model 工廠")
struct HostScreensTests {
    static let ssh = CurrentHostTests.ssh
    static let https = CurrentHostTests.https

    static func model() -> HostsModel { CurrentHostTests.model() }

    @Test("登入 Shell 的主機挑選:只列支援的主機,HTTPS 主機不在內")
    func loginShellPickerExcludesHTTPS() {
        let options = Self.model().screens.hostPicker(for: .loginShell).options.map(\.id)
        #expect(options.contains(.host(Self.ssh.id)))
        #expect(!options.contains(.host(Self.https.id)))
    }

    @Test("新增聊天的主機挑選:Demo 加所有已存主機都列;指定的主機優先,沒有就用選取中主機")
    func newChatPickerListsEveryHost() {
        let model = Self.model()
        let picker = model.screens.newChatHostPicker()
        #expect(Set(picker.options.map(\.id)) == [.demo, .host(Self.ssh.id), .host(Self.https.id)])
        #expect(model.screens.newChatHostPicker(preferring: .host(Self.https.id)).selection == .host(Self.https.id))
        #expect(model.screens.newChatHostPicker(preferring: .host(Self.ssh.id)).selection == .host(Self.ssh.id))
    }

    @Test("頂列的主機選單:選一台只改選取中主機,不動聊天列表的目前主機(#390)")
    func selectedHostPickerOnlyChangesSelection() {
        let model = Self.model()
        model.agentList.currentHost = nil
        model.select(.host(Self.https.id))
        let picker = model.screens.selectedHostPicker()
        picker.select(.host(Self.ssh.id))
        #expect(model.selection == .host(Self.ssh.id))
        #expect(model.agentList.currentHost == nil)
    }

    @Test("數據用量:主機選單列所有已存主機,預設看目前主機")
    func dataUsageDefaultsToCurrentHost() {
        let model = Self.model()
        model.agentList.currentHost = .host(Self.https.id)
        let usage = model.screens.dataUsage()
        #expect(usage.host == .host(Self.https.id))
    }

    @Test("方案用量:帶 host 與 agent 時直接選那一台與那個 Agent")
    func planUsageHonorsExplicitHostAndAgent() {
        let model = Self.model()
        let plan = model.screens.planUsage(host: .host(Self.ssh.id), agent: .codex)
        #expect(plan.host == .host(Self.ssh.id))
        #expect(plan.agent == .codex)
    }

    @Test("新增主機編輯器:預選連線方式;編輯既有主機帶入它的名稱")
    func editorPreselectsMethodAndLoadsHost() {
        let model = Self.model()
        let added = model.screens.makeEditor(method: .https)
        #expect(added.connectionMethod == .https)
        let editing = model.screens.makeEditor(editing: Self.ssh)
        #expect(editing.name == Self.ssh.name)
    }

    @Test("匯入連結:壞連結丟錯而不是開出空的引導;主機分享連結帶入欄位")
    func importLinksValidate() throws {
        let model = Self.model()
        #expect(throws: (any Error).self) { try model.screens.makeImportEditor(URL(string: "purrdr://host?d=壞掉")!) }
        #expect(throws: (any Error).self) { try model.screens.makeImportGuide(URL(string: "purrdr://host?d=壞掉")!) }
        let link = HostShareLink.url(for: Self.ssh)
        #expect(try model.screens.makeImportEditor(link).name == Self.ssh.name)
    }

    @Test("新增主機引導與配對引導:不需要連線就能建立")
    func guidesBuildWithoutConnecting() throws {
        let model = Self.model()
        _ = model.screens.makeAddHostGuide()
        _ = try model.screens.makePairingGuide(for: Self.https)
    }
}
