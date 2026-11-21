import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 主機編輯頁的輸入欄位順序(#312):return 依畫面順序跳到下一個顯示中的欄位，最後一個收起鍵盤。
@MainActor
@Suite("主機編輯頁：輸入欄位順序")
struct HostEditorInputOrderTests {
    @Test(
        "每種連線方式依畫面順序排，隱藏的欄位不在順序內",
        arguments: [
            (.tailscaleSSH, false, [.name, .address, .port, .username]),
            (.tailscaleSSH, true, [.name, .address, .port, .username, .herdrPath, .herdrSession]),
            (.https, false, [.name, .address, .port, .pairingCode]),
        ] as [(HostConfiguration.ConnectionMethod, Bool, [HostEditorModel.InputField])])
    func orderPerMethod(method: HostConfiguration.ConnectionMethod, showsAdvanced: Bool, expected: [HostEditorModel.InputField]) {
        let model = HostEditorConnectionFieldsTests.newEditor()
        model.connectionMethod = method

        #expect(model.inputFields(showsAdvanced: showsAdvanced) == expected)
    }

    @Test("還沒選連線方式：只有名稱")
    func onlyNameBeforeChoosingMethod() {
        let model = HostEditorConnectionFieldsTests.newEditor()

        #expect(model.inputFields(showsAdvanced: true) == [.name])
    }

    @Test(
        "OpenSSH 依登入方式：密碼欄、私鑰欄;這支裝置的金鑰還沒載入時沒有加入公鑰的密碼欄",
        arguments: [
            (.password, [.name, .address, .port, .username, .password]),
            (.importedKey, [.name, .address, .port, .username, .privateKey]),
            (.deviceKey, [.name, .address, .port, .username]),
        ] as [(HostConfiguration.OpenSSHAuthentication, [HostEditorModel.InputField])])
    func openSSHOrderPerAuthentication(
        authentication: HostConfiguration.OpenSSHAuthentication, expected: [HostEditorModel.InputField]
    ) {
        let model = HostEditorConnectionFieldsTests.newEditor()
        model.connectionMethod = .openSSH
        model.authentication = authentication

        #expect(model.inputFields(showsAdvanced: false) == expected)
    }

    @Test("這支裝置的金鑰載入後：加入公鑰的密碼欄在帳號之後")
    func keyInstallPasswordAfterDeviceKeyLoads() async {
        let model = HostEditorModel(
            store: MemoryHostStore(),
            credentials: HostCredentials(secrets: MemorySecretStore(), deviceKey: EphemeralDeviceKey(comment: "purrdr@iPhone")),
            makeChannel: ChannelFactory().make)
        model.connectionMethod = .openSSH
        model.authentication = .deviceKey
        await model.loadDeviceKey()

        #expect(model.inputFields(showsAdvanced: false) == [.name, .address, .port, .username, .keyInstallPassword])
    }

    @Test("return 的去向：有下一個欄位就到下一個，最後一個是 nil(收起鍵盤)")
    func nextField() {
        let model = HostEditorConnectionFieldsTests.newEditor()
        model.connectionMethod = .openSSH
        model.authentication = .password

        #expect(model.inputField(after: .address, showsAdvanced: false) == .port)
        #expect(model.inputField(after: .username, showsAdvanced: false) == .password)
        #expect(model.inputField(after: .password, showsAdvanced: false) == nil)
        #expect(model.inputField(after: .pairingCode, showsAdvanced: false) == nil, "不在順序內的欄位收起鍵盤")
    }
}
