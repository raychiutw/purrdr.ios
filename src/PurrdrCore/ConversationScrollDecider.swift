import Foundation

/// 捲動決策者(ADR-0014):依「跟隨最新」規則(GLOSSARY)決定要不要捲、捲到哪,每次 `flush` 最多一個指令。純邏輯,不依賴 SwiftUI／UIKit。
public struct ConversationScrollDecider: Sendable, Equatable {
    /// 餵進來的事件;只改狀態,不產生指令。
    public enum Event: Sendable, Equatable {
        case timeline(ConversationTimeline.Update)
        case userBeganDragging
        /// 手指放開(慣性結束時也送一次)。
        case userEndedDragging(distanceFromBottom: Double)
        /// 使用者造成的捲動位移;只有這類事件能改變跟隨。
        case userScrolled(distanceFromBottom: Double)
        /// 排版或程式造成的位移,只更新量測,不改跟隨。
        case layoutMeasured(distanceFromBottom: Double)
        case keyboardHeightChanged
        case inputBarHeightChanged
        case keyboardAnimation(isRunning: Bool)
        case menu(isOpen: Bool)
        /// 畫面上第一個可見列(往上補舊訊息時要維持的位置)。
        case firstVisibleRowChanged(id: String?)
        /// 「跳到最新」按鈕。
        case jumpToLatest(lastRowID: String)
    }

    /// 一刻最多一個的捲動指令。
    public enum Command: Sendable, Equatable {
        case scrollToBottom(animated: Bool)
        /// 捲到最後一列(「跳到最新」),不會停在內容外。
        case scrollToRow(id: String, animated: Bool)
        /// 往上補舊訊息後,維持這一列在畫面上的位置。
        case keepVisible(rowID: String)
    }

    /// 距底部在這個距離內算「在底部」。
    public static let nearBottomThreshold = 48.0
    /// 新內容批次的間隔。
    public static let batchInterval: TimeInterval = 0.1

    /// 目前是否跟隨最新。
    public private(set) var isFollowingLatest = true
    /// 最近量到的離底距離(給「跳到最新」按鈕用)。
    public private(set) var distanceFromBottom = 0.0

    private var isDragging = false
    private var isKeyboardAnimating = false
    private var isMenuOpen = false
    private var firstVisibleRowID: String?
    private var hasPendingContent = false
    private var hasPendingUserSent = false
    private var hasPendingOlderLoaded = false
    private var hasPendingResize = false
    private var pendingJumpRowID: String?
    private var lastContentFlushAt: TimeInterval?

    public init() {}

    public mutating func receive(_ event: Event) {
        switch event {
        case .timeline(let update):
            guard !update.changes.isEmpty else { return }
            switch update.cause {
            case .userSent: hasPendingUserSent = true
            case .olderLoaded: hasPendingOlderLoaded = true
            case .agentReply, .refreshed: hasPendingContent = true
            }
        case .userBeganDragging:
            isDragging = true
        case .userEndedDragging(let distance):
            isDragging = false
            applyUserScroll(distance)
        case .userScrolled(let distance):
            applyUserScroll(distance)
        case .layoutMeasured(let distance):
            distanceFromBottom = distance
        case .keyboardHeightChanged, .inputBarHeightChanged:
            hasPendingResize = true
        case .keyboardAnimation(let isRunning):
            isKeyboardAnimating = isRunning
        case .menu(let isOpen):
            isMenuOpen = isOpen
        case .firstVisibleRowChanged(let id):
            firstVisibleRowID = id
        case .jumpToLatest(let lastRowID):
            pendingJumpRowID = lastRowID
            isFollowingLatest = true
        }
    }

    /// 這一刻的指令(沒有就 `nil`);輸出後清掉已處理的待辦。拖曳中、鍵盤動畫中、選單開著時延後,內容變更約每 100 ms 才處理一次。
    public mutating func flush(at now: TimeInterval) -> Command? {
        guard !isDragging, !isKeyboardAnimating, !isMenuOpen else { return nil }

        if let rowID = pendingJumpRowID {
            clearPending()
            return .scrollToRow(id: rowID, animated: true)
        }
        if hasPendingUserSent {
            clearPending()
            isFollowingLatest = true
            return .scrollToBottom(animated: true)
        }
        if hasPendingOlderLoaded {
            hasPendingOlderLoaded = false
            if let rowID = firstVisibleRowID {
                return .keepVisible(rowID: rowID)
            }
        }
        let contentReady = hasPendingContent && lastContentFlushAt.map { now - $0 >= Self.batchInterval - 1e-9 } != false
        guard isFollowingLatest, contentReady || hasPendingResize else {
            if hasPendingResize { hasPendingResize = false }
            return nil
        }
        if contentReady { lastContentFlushAt = now }
        clearPending()
        return .scrollToBottom(animated: false)
    }

    private mutating func applyUserScroll(_ distance: Double) {
        distanceFromBottom = distance
        isFollowingLatest = distance <= Self.nearBottomThreshold
    }

    private mutating func clearPending() {
        hasPendingContent = false
        hasPendingUserSent = false
        hasPendingOlderLoaded = false
        hasPendingResize = false
        pendingJumpRowID = nil
    }
}
