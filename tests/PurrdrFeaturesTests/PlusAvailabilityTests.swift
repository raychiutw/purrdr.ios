import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

@testable import PurrdrFeatures

/// Purrdr Plus 編譯開關(#676):Info.plist 的值轉成型別、關閉時組裝不建立訂閱與主機同步。
@MainActor
@Suite("Purrdr Plus 編譯開關")
struct PlusAvailabilityTests {
    @Test("Info.plist 的值:YES 才開啟;沒寫、NO、其他值一律關閉(預設安全)")
    func infoValue() {
        #expect(PlusAvailability(infoValue: "YES") == .enabled)
        #expect(PlusAvailability(infoValue: "yes") == .enabled)
        #expect(PlusAvailability(infoValue: true) == .enabled)
        #expect(PlusAvailability(infoValue: "NO") == .disabled)
        #expect(PlusAvailability(infoValue: "$(PURRDR_PLUS_ENABLED)") == .disabled)
        #expect(PlusAvailability(infoValue: nil) == .disabled)
        #expect(PlusAvailability(infoValue: 1) == .disabled)
    }

    @Test("關閉時組裝不建立訂閱與主機同步 model;開啟時兩個都建立")
    func assembly() {
        let backend = HTTPStub()
        let session = MemberSession(
            transport: URLSessionBackendTransport(baseURL: backend.baseURL, session: backend.urlSession), tokenStore: InMemoryTokenStore())
        let syncStore = InMemoryHostSyncStore(partition: MemberPartition())
        let hosts = HostsModel(
            store: MemoryHostStore(), demoChannel: FakeHost(),
            credentials: HostCredentials(secrets: EphemeralHostSecretStore(), deviceKey: EphemeralDeviceKey()),
            hostService: HostServiceAccess(tokens: InMemoryDeviceTokenStore()), makeChannel: { _, _, _ in FakeHost() })

        let off = PlusAvailability.disabled.assemble(
            session: session, store: FakePlusStore(), confirmOwner: { true }, hosts: hosts, hostSyncStore: syncStore)
        #expect(off.plus == nil)
        #expect(off.hostSync == nil)

        let on = PlusAvailability.enabled.assemble(
            session: session, store: FakePlusStore(), confirmOwner: { true }, hosts: hosts, hostSyncStore: syncStore)
        #expect(on.plus != nil)
        #expect(on.hostSync != nil)
    }
}
