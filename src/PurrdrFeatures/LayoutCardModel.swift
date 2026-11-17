import Foundation
import Observation
import PurrdrCore

/// iPad 版面圖浮動卡片的狀態(#31 補充、#37 故事 22、行為規格 F4)。每個視窗一份。
///
/// - 指標停在版面圖按鈕上 300ms 出現預覽;離開按鈕與卡片 200ms 後消失(從按鈕移到卡片上不消失)。
/// - 點按鈕(或在卡片上按下)即釘住;釘住後只有「關閉」、點背景或 Esc 才關。
/// - iPhone 沒有指標停留，版面圖仍是 sheet(`SpacesLayoutSheet`)。
@MainActor
@Observable
public final class LayoutCardModel {
    public enum State: Equatable, Sendable {
        case hidden
        case peeking(workspaceID: String)
        case pinned(workspaceID: String)
    }

    public private(set) var state: State = .hidden

    /// 卡片顯示的 workspace(預覽或釘住)。
    public var workspaceID: String? {
        switch state {
        case .hidden: nil
        case .peeking(let id), .pinned(let id): id
        }
    }

    public var isPinned: Bool {
        if case .pinned = state { true } else { false }
    }

    static let showDelay = Duration.milliseconds(300)
    static let hideDelay = Duration.milliseconds(200)

    private let sleep: Sleep
    /// 指標目前停在哪個 workspace 的版面圖按鈕上。
    @ObservationIgnored private var hoveredButton: String?
    @ObservationIgnored private var isOverCard = false
    /// 每次指標進出就加一;等待結束時不一樣了，代表那次等待已過時。
    @ObservationIgnored private var generation = 0

    public init(sleep: @escaping Sleep = Sleeping.task) {
        self.sleep = sleep
    }

    /// 指標進出版面圖按鈕。
    public func pointer(overButton workspaceID: String, isInside: Bool) async {
        if isInside {
            hoveredButton = workspaceID
        } else if hoveredButton == workspaceID {
            hoveredButton = nil
        }
        await settleAfterPointerMoved()
    }

    /// 指標進出卡片。
    public func pointer(overCard isInside: Bool) async {
        isOverCard = isInside
        await settleAfterPointerMoved()
    }

    /// 點了某個 workspace 的版面圖按鈕：出現並釘住。
    public func tap(_ workspaceID: String) {
        generation += 1
        state = .pinned(workspaceID: workspaceID)
    }

    /// 在卡片上按下：釘住正在預覽的卡片。
    public func pin() {
        guard case .peeking(let id) = state else { return }
        tap(id)
    }

    /// 「關閉」、點背景或 Esc。
    public func close() {
        generation += 1
        state = .hidden
    }

    private func settleAfterPointerMoved() async {
        generation += 1
        let current = generation
        guard !isPinned else { return }
        if let hoveredButton {
            if workspaceID == hoveredButton { return }
            try? await sleep(Self.showDelay)
            guard current == generation, !isPinned else { return }
            state = .peeking(workspaceID: hoveredButton)
        } else if !isOverCard, state != .hidden {
            try? await sleep(Self.hideDelay)
            guard current == generation, !isPinned else { return }
            state = .hidden
        }
    }
}
