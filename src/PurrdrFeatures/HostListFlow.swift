import Foundation
import Observation

/// 主機清單 sheet 內 push 的畫面。
enum HostRoute: Hashable {
    case add
    case edit(UUID)
    case share(UUID)
    case hostServiceUpdate(UUID)
    case importLink(URL)

    var hostID: UUID? {
        if case .edit(let id) = self { return id }
        return nil
    }
}

/// 主機清單的導覽與刪除確認(#235)。
@MainActor
@Observable
final class HostListFlow {
    var path: [HostRoute] = []

    /// 點列尾 ⓘ:開那台主機的編輯器。
    func showDetails(of id: UUID) {
        path.append(.edit(id))
    }

    /// 從外部(主機服務通知)開那台主機的編輯器：換掉原本推入的畫面。
    func openEditor(of id: UUID) {
        path = [.edit(id)]
    }

    /// 等確認的刪除;有值時顯示確認對話框。
    var pendingDeletion: HostDeletionRequest?

    /// 滑動或選單的「刪除」:先問，不直接刪。
    func requestDeletion(of id: UUID, name: String) {
        pendingDeletion = HostDeletionRequest(id: id, name: name)
    }

    /// 主機頁已配對裝置的「這支裝置」(#291):回到主機清單，跳出同一個移除確認。
    func requestDeletionFromEditor(of id: UUID, name: String) {
        path.removeAll()
        requestDeletion(of: id, name: name)
    }

    func cancelDeletion() {
        pendingDeletion = nil
    }

    /// 使用者確認後刪掉對話框顯示的那台。帶著 `request`:按下時系統先收起對話框，`pendingDeletion` 已被清掉。
    func confirmDeletion(of request: HostDeletionRequest, _ delete: (UUID) async throws -> Void) async throws {
        pendingDeletion = nil
        try await delete(request.id)
    }
}

/// 等使用者確認的刪除主機。
struct HostDeletionRequest: Equatable {
    var id: UUID
    var name: String
}
