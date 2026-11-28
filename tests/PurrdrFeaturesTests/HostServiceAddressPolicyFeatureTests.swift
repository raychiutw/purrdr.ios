import Foundation
import PurrdrCore
@testable import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// Release 只收 https 的主機服務位址(#696):編輯器、新增主機引導(手動與連結匯入)都擋下 http 與本機位址,
/// 並提示「位址要是 https」;Debug 規則照舊可用。規則以 model 的 `addressPolicy` 明確指定,不動全域預設。
@MainActor
@Suite("主機服務位址：畫面規則")
struct HostServiceAddressPolicyFeatureTests {
    static func editor(policy: HostServiceAddress.Policy) -> HostEditorModel {
        let model = HostEditorModel(store: MemoryHostStore(), hostService: HostServiceConnections().access(), makeChannel: ChannelFactory().make)
        model.addressPolicy = policy
        model.name = "Local"
        model.connectionMethod = .https
        model.address = "127.0.0.1"
        model.port = "47820"
        model.pairingCode = "K7QM-2XPA"
        return model
    }

    static func guide(policy: HostServiceAddress.Policy) -> AddHostGuideModel {
        let model = AddHostGuideModel(store: MemoryHostStore(), hostService: HostServiceConnections().access(), makeChannel: ChannelFactory().make)
        model.addressPolicy = policy
        model.choose(.https)
        model.advance()
        model.choose(.macOS)
        model.advance()
        model.pairAddress = "127.0.0.1"
        model.pairPort = "47820"
        model.pairingCode = "K7QM-2XPA"
        return model
    }

    @Test("編輯器:Release 規則擋下本機位址並提示,Debug 規則照舊可測試")
    func editor() {
        let release = Self.editor(policy: .httpsOnly)
        #expect(release.addressNeedsHTTPS)
        #expect(!release.canTest)

        let debug = Self.editor(policy: .allowsLocalTesting)
        #expect(!debug.addressNeedsHTTPS)
        #expect(debug.canTest)
    }

    @Test("編輯器:https 位址在 Release 規則下不提示")
    func editorAcceptsHTTPS() {
        let model = Self.editor(policy: .httpsOnly)
        model.address = "studio.tail1234.ts.net"
        model.port = "443"
        #expect(!model.addressNeedsHTTPS)
        #expect(model.canTest)
    }

    @Test("新增主機引導手動輸入:Release 規則擋下本機位址並提示,Debug 規則可往下")
    func guideManual() {
        let release = Self.guide(policy: .httpsOnly)
        #expect(release.pairAddressNeedsHTTPS)
        #expect(!release.canAdvance)

        let debug = Self.guide(policy: .allowsLocalTesting)
        #expect(!debug.pairAddressNeedsHTTPS)
        #expect(debug.canAdvance)
    }

    @Test("新增主機引導匯入連結:Release 規則下 http 的配對連結不接受")
    func guideImport() throws {
        let pairing = URL(string: "purrdr://pair?address=http%3A%2F%2F127.0.0.1%3A47820&code=K7QM-2XPA")!
        let make = { (policy: HostServiceAddress.Policy) throws -> AddHostGuideModel in
            try AddHostGuideModel(
                store: MemoryHostStore(), hostService: HostServiceConnections().access(), makeChannel: ChannelFactory().make,
                shortcut: .importLink(pairing), addressPolicy: policy)
        }
        #expect(throws: (any Error).self) { try make(.httpsOnly) }
        _ = try make(.allowsLocalTesting)
    }
}
