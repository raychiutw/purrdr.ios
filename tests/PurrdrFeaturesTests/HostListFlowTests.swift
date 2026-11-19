import Foundation
@testable import PurrdrFeatures
import Testing

/// 主機清單的 ⓘ 與刪除確認(#235;HIG 盤點 2.1、2.2)。
@MainActor
@Suite("主機清單的 ⓘ 與刪除確認")
struct HostListFlowTests {
    static let studioID = UUID(uuidString: "6F1C2B3A-0000-4000-8000-000000000001")!

    @Test("點 ⓘ 開那台主機的編輯器")
    func infoButtonOpensEditor() {
        let flow = HostListFlow()

        flow.showDetails(of: Self.studioID)

        #expect(flow.path == [.edit(Self.studioID)])
    }

    @Test("刪除先跳確認：要求刪除不會刪，確認後才刪那台並收起確認")
    func deletionWaitsForConfirmation() async throws {
        let flow = HostListFlow()
        var deleted: [UUID] = []

        flow.requestDeletion(of: Self.studioID, name: "Studio Mac")

        #expect(deleted.isEmpty)
        #expect(flow.pendingDeletion == HostDeletionRequest(id: Self.studioID, name: "Studio Mac"))

        try await flow.confirmDeletion { deleted.append($0) }

        #expect(deleted == [Self.studioID])
        #expect(flow.pendingDeletion == nil)
    }

    @Test("取消刪除：不刪主機，收起確認")
    func cancelKeepsHost() async throws {
        let flow = HostListFlow()
        var deleted: [UUID] = []
        flow.requestDeletion(of: Self.studioID, name: "Studio Mac")

        flow.cancelDeletion()
        try await flow.confirmDeletion { deleted.append($0) }

        #expect(deleted.isEmpty)
        #expect(flow.pendingDeletion == nil)
    }
}
