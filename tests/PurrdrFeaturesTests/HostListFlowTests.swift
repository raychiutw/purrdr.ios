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
        let request = try #require(flow.pendingDeletion)
        #expect(request == HostDeletionRequest(id: Self.studioID, name: "Studio Mac"))

        try await flow.confirmDeletion(of: request) { deleted.append($0) }

        #expect(deleted == [Self.studioID])
        #expect(flow.pendingDeletion == nil)
    }

    @Test("按下確認時系統先收起對話框(清掉等確認的刪除):仍刪掉按下時那台")
    func confirmingAfterDialogDismissedStillDeletes() async throws {
        let flow = HostListFlow()
        var deleted: [UUID] = []
        flow.requestDeletion(of: Self.studioID, name: "Studio Mac")
        let request = try #require(flow.pendingDeletion)

        flow.cancelDeletion()
        try await flow.confirmDeletion(of: request) { deleted.append($0) }

        #expect(deleted == [Self.studioID])
        #expect(flow.pendingDeletion == nil)
    }

    @Test("取消刪除：收起確認，不留等確認的刪除")
    func cancelKeepsHost() {
        let flow = HostListFlow()
        flow.requestDeletion(of: Self.studioID, name: "Studio Mac")

        flow.cancelDeletion()

        #expect(flow.pendingDeletion == nil)
    }
}
