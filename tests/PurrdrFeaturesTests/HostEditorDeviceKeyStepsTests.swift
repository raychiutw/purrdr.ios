import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 主機編輯頁的「這支裝置的金鑰」三步(#346):打開終端機、貼上指令、回來測試連線，全在同一頁。
@MainActor
@Suite("主機編輯頁：金鑰三步")
struct HostEditorDeviceKeyStepsTests {
    private func loadedModel() async -> (HostEditorModel, SSHPublicKey) {
        let deviceKey = EphemeralDeviceKey(comment: "purrdr@iPhone")
        let model = HostEditorModel(
            store: MemoryHostStore(),
            credentials: HostCredentials(secrets: MemorySecretStore(), deviceKey: deviceKey),
            makeChannel: ChannelFactory().make)
        model.connectionMethod = .openSSH
        model.authentication = .deviceKey
        await model.loadDeviceKey()
        return (model, model.devicePublicKey!)
    }

    @Test("公鑰還沒取得：沒有步驟")
    func emptyBeforeKeyLoads() {
        let model = HostEditorConnectionFieldsTests.newEditor()
        model.connectionMethod = .openSSH
        model.authentication = .deviceKey

        #expect(model.deviceKeySteps.isEmpty)
    }

    @Test("三步：開終端機、貼上各系統的指令、回來測試連線")
    func threeSteps() async {
        let (model, key) = await loadedModel()
        let steps = model.deviceKeySteps

        #expect(steps.first?.command == nil, "第一步只是打開終端機")
        #expect(steps.last?.command == nil, "最後一步回來測試連線")
        let commands = steps.compactMap(\.command)
        #expect(commands.contains(AuthorizedKeyCommand.command(adding: key, on: .macOSAndLinux)))
        #expect(commands.contains(AuthorizedKeyCommand.command(adding: key, on: .windows)))
        #expect(commands.contains(AuthorizedKeyCommand.command(adding: key, on: .windowsAdministrator)))
    }

    @Test("金鑰三步不要求密碼，也沒有用密碼自動加公鑰")
    func neverAsksForPassword() async {
        let (model, _) = await loadedModel()

        #expect(!model.deviceKeySteps.contains { $0.text.localizedCaseInsensitiveContains("password") })
    }
}
