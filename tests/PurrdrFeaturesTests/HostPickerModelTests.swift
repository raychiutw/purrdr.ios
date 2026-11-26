import Foundation
import PurrdrAgentFeatures
import Testing

/// 登入 Shell、檔案與新增聊天標題列的主機挑選鈕(#245)。
@MainActor
@Suite("主機挑選鈕")
struct HostPickerModelTests {
    static let mac = HostSelection.host(UUID(uuidString: "6F1C2A4E-0B7D-4C1E-9A55-0D2C8E1F3A10")!)
    static let linux = HostSelection.host(UUID(uuidString: "1A2B3C4D-5E6F-4A1B-8C2D-3E4F5A6B7C8D")!)
    static let removed = HostSelection.host(UUID(uuidString: "0B0B0B0B-1C1C-4D1D-8E1E-2F2F2F2F2F2F")!)
    static let options = [
        HostOption(id: .demo, name: "Demo"),
        HostOption(id: mac, name: "Mac", icon: .macMini),
        HostOption(id: linux, name: "Linux", icon: .rack),
    ]

    let suite = "purrdr.tests.hostPicker.\(UUID().uuidString)"

    @Test("登入 Shell 沒選過：預設選取中主機")
    func rememberedDefaultsToSelectedHost() {
        let picker = HostPickerModel.remembering(.loginShell, options: Self.options, fallback: Self.mac, store: InMemoryHostPickerStore())

        #expect(picker.selection == Self.mac)
        #expect(picker.selectedOption?.name == "Mac")
    }

    @Test("換電腦後下次打開選回同一台；登入 Shell 與檔案各記各的")
    func eachToolRemembersItsOwnHost() {
        let store = InMemoryHostPickerStore()
        let shell = HostPickerModel.remembering(.loginShell, options: Self.options, fallback: Self.mac, store: store)
        shell.select(Self.linux)

        let reopenedShell = HostPickerModel.remembering(.loginShell, options: Self.options, fallback: Self.mac, store: store)
        let files = HostPickerModel.remembering(.files, options: Self.options, fallback: Self.mac, store: store)

        #expect(reopenedShell.selection == Self.linux)
        #expect(files.selection == Self.mac)
    }

    @Test("記住的主機已刪除或不支援：退回選取中主機")
    func rememberedHostNoLongerListedFallsBack() {
        let store = InMemoryHostPickerStore()
        store.save(Self.removed, for: .files)

        let files = HostPickerModel.remembering(.files, options: Self.options, fallback: Self.linux, store: store)

        #expect(files.selection == Self.linux)
    }

    @Test("選取中主機也不在選項裡(例：HTTPS 主機)：選第一個選項")
    func fallbackNotListedUsesFirstOption() {
        let shellOptions = Array(Self.options.prefix(2))

        let shell = HostPickerModel.remembering(.loginShell, options: shellOptions, fallback: Self.linux, store: InMemoryHostPickerStore())

        #expect(shell.selection == .demo)
    }

    @Test("選不在選項裡的主機不採用、不記住")
    func selectingUnlistedHostIsIgnored() {
        let store = InMemoryHostPickerStore()
        let shell = HostPickerModel.remembering(.loginShell, options: Self.options, fallback: Self.mac, store: store)

        shell.select(Self.removed)

        #expect(shell.selection == Self.mac)
        #expect(store.load(.loginShell) == nil)
    }

    @Test("重開 app 後還原各自記住的主機")
    func restoresAfterRelaunch() {
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let shell = HostPickerModel.remembering(
            .loginShell, options: Self.options, fallback: Self.mac, store: UserDefaultsHostPickerStore(defaults: UserDefaults(suiteName: suite)!))
        shell.select(.demo)

        let relaunched = HostPickerModel.remembering(
            .loginShell, options: Self.options, fallback: Self.mac, store: UserDefaultsHostPickerStore(defaults: UserDefaults(suiteName: suite)!))

        #expect(relaunched.selection == .demo)
    }

    @Test("新增聊天：預設聊天列表篩選的主機")
    func newChatDefaultsToListFilter() {
        let picker = HostPickerModel.newChat(options: Self.options, currentHost: Self.linux, selection: Self.mac)

        #expect(picker.selection == Self.linux)
    }

    @Test("新增聊天：篩選是所有主機時用選取中主機")
    func newChatAllHostsUsesSelectedHost() {
        let picker = HostPickerModel.newChat(options: Self.options, currentHost: nil, selection: Self.mac)

        #expect(picker.selection == Self.mac)
    }

    @Test("新增聊天換電腦不記住：下次仍從篩選或選取中主機開始")
    func newChatDoesNotRemember() {
        let picker = HostPickerModel.newChat(options: Self.options, currentHost: nil, selection: Self.mac)
        picker.select(Self.linux)

        #expect(picker.selection == Self.linux)
        #expect(HostPickerModel.newChat(options: Self.options, currentHost: nil, selection: Self.mac).selection == Self.mac)
    }
}

@MainActor
@Suite("主機選單:需要重新確認的主機(#572、#616)")
struct HostPickerReconfirmationTests {
    private static let ok = UUID()
    private static let changed = UUID()

    private func picker() -> HostPickerModel {
        HostPickerModel(
            options: [
                HostOption(id: .host(Self.ok), name: "Ok"),
                HostOption(id: .host(Self.changed), name: "Changed", needsReconfirmation: true),
                HostOption(id: .demo, name: "Demo"),
            ], preferred: [.host(Self.ok)])
    }

    @Test("選需要重新確認的主機:換成它,並回傳要開編輯頁確認的主機")
    func choosingReconfirmationHost() {
        let model = picker()
        #expect(model.choose(.host(Self.changed)) == Self.changed)
        #expect(model.selection == .host(Self.changed))
    }

    @Test("選一般主機或 Demo:只換選取,不要求確認")
    func choosingOrdinaryHost() {
        let model = picker()
        #expect(model.choose(.demo) == nil)
        #expect(model.selection == .demo)
        #expect(model.choose(.host(Self.ok)) == nil)
    }
}
