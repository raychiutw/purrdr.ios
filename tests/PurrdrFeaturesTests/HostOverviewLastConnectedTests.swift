import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 主機 tab 的「最後連線」時間(#392):主機更新來源記住最後一次讀到快照的時間。
@MainActor
@Suite("主機更新來源:最後連線時間")
struct HostOverviewLastConnectedTests {
    @Test("讀到快照就記下時間")
    func remembersLastLoadedTime() async throws {
        let connection = FakeHostConnection()
        await connection.expect("session.snapshot", reply: HostUpdatesTests.snapshot)
        let moment = Date(timeIntervalSince1970: 1_000)
        let updates = HostUpdates(client: HerdrClient(connection: connection), now: { moment })
        #expect(updates.lastLoadedAt == nil)

        await updates.load()

        #expect(updates.phase == .loaded)
        #expect(updates.lastLoadedAt == moment)
    }
}
