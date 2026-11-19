import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrHTTPS
import PurrdrTestSupport
import Testing

/// 主機清單提供給主機挑選鈕的選項與各畫面開在挑選的電腦上(#245)。
@MainActor
@Suite("主機挑選鈕的主機")
struct HostPickerHostsTests {
    static let ssh = HostConfiguration(name: "Studio", endpoint: SSHEndpoint(host: "studio-mac", username: "ray"))
    static let https = HostConfiguration(name: "Box", hostService: HostServiceAddress("box.tail1234.ts.net")!)

    static func model(pickerStore: any HostPickerStore = InMemoryHostPickerStore()) -> HostsModel {
        let store = MemoryHostStore()
        store.hosts = [ssh, https]
        let model = HostsModel(
            store: store, demoChannel: FakeHost(), hostPicker: pickerStore,
            hostService: HostServiceConnections().access(tokens: InMemoryDeviceTokenStore(tokens: [https.id: "token-saved"])),
            makeChannel: ChannelFactory().make)
        model.load()
        return model
    }

    @Test("登入 Shell 與檔案只列支援的主機：Demo 與 SSH 主機，不列 HTTPS 主機")
    func shellToolsListOnlySupportedHosts() {
        let model = Self.model()

        for scope in HostPickerScope.allCases {
            #expect(model.hostPicker(for: scope).options.map(\.name) == ["Demo", "Studio"])
        }
    }

    @Test("新增聊天列出所有主機")
    func newChatListsEveryHost() {
        let model = Self.model()

        #expect(model.newChatHostPicker(listFilter: nil).options.map(\.name) == ["Demo", "Studio", "Box"])
    }

    @Test("登入 Shell 換電腦不改選取中主機，下次打開選回同一台")
    func pickingKeepsSelectedHost() {
        let model = Self.model()
        model.select(.host(Self.ssh.id))

        model.hostPicker(for: .loginShell).select(.demo)

        #expect(model.selection == .host(Self.ssh.id))
        #expect(model.hostPicker(for: .loginShell).selection == .demo)
        #expect(model.hostPicker(for: .files).selection == .host(Self.ssh.id))
    }

    @Test("登入 Shell 與檔案開在挑選的電腦上(標題是那台主機)")
    func toolsOpenOnPickedHost() {
        let model = Self.model()
        model.select(.host(Self.ssh.id))

        #expect(model.loginShell(on: .demo).title == "Demo")
        #expect(model.folderBrowser(on: .demo).hostName == "Demo")
    }

    @Test("新增聊天預設聊天列表篩選的主機;所有主機時用選取中主機")
    func newChatDefaultsToFilter() {
        let model = Self.model()
        model.select(.host(Self.ssh.id))

        #expect(model.newChatHostPicker(listFilter: .host(Self.https.id)).selection == .host(Self.https.id))
        #expect(model.newChatHostPicker(listFilter: nil).selection == .host(Self.ssh.id))
    }

    @Test("「⋯」的新增聊天預設聊天列表目前篩選的主機(#244);篩選所有主機時用選取中主機")
    func newChatFollowsListHostFilter() {
        let model = Self.model()
        model.select(.host(Self.ssh.id))

        model.agentList.hostFilter = .host(Self.https.id)
        #expect(model.newChatHostPicker().selection == .host(Self.https.id))

        model.agentList.hostFilter = nil
        #expect(model.newChatHostPicker().selection == .host(Self.ssh.id))
    }
}
