import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 聊天列表一列的內容(diffable 的 identifier 是列 id,內容變了才重畫那一列)。
enum ChatListRowContent: Equatable {
    case older(ConversationModel.Older)
    case away(AwaySummary, isCollapsed: Bool)
    case entry(ConversationRow, turnHeader: AgentTurnHeader?)
    case pending(PendingItem)
    case notice(String)
    case prompt
    case working
}

/// 聊天列表由上而下的列與各列內容。
struct ChatListContent: Equatable {
    var ids: [String] = []
    var rows: [String: ChatListRowContent] = [:]
}

/// 讓畫面(「跳到最新」鈕、輸入列)呼叫列表;列表在 iOS 才有,其他平台只是空殼。
@MainActor
final class ChatListHandle {
    var jumpToLatestAction: (() -> Void)?
    var inputBarArrangedAction: (() -> Void)?
    /// 列表最近量到的可見高度(畫面在空狀態與列表之間切換時補報)。
    var visibleHeight: Double?

    func jumpToLatest() { jumpToLatestAction?() }
    func inputBarArranged() { inputBarArrangedAction?() }
}

#if os(iOS)
import UIKit

/// 包進 SwiftUI 的聊天列表:`UICollectionView` + 自訂 layout + diffable data source,列內容用 `UIHostingConfiguration`(ADR-0014)。
/// 捲動完全由捲動決策者的指令驅動;畫面只提供資料與回呼。
struct ChatListView: UIViewControllerRepresentable {
    let content: ChatListContent
    let model: ConversationModel
    let handle: ChatListHandle
    let rowView: (ChatListRowContent) -> AnyView
    /// 一列長按選單的項目(空陣列表示這一列沒有選單,留給文字選取)。
    let menuEntries: (ChatListRowContent) -> [ChatListMenuEntry]
    let smoothness: (any ScrollSmoothnessReporting)?
    /// 避開玻璃導覽列、橫幅與輸入列後的安全區域框(全域座標):列表延伸到玻璃底下,上下留白由它與列表框的差決定。
    let safeAreaFrame: CGRect
    let onShowsJumpToLatestChanged: (Bool) -> Void
    let onVisibleHeightChanged: (Double) -> Void

    func makeUIViewController(context: Context) -> ChatListViewController {
        let controller = ChatListViewController()
        controller.model = model
        handle.jumpToLatestAction = { [weak controller] in controller?.jumpToLatest() }
        handle.inputBarArrangedAction = { [weak controller] in controller?.inputBarArranged() }
        model.onTimelineUpdate = { [weak controller] update in controller?.receive(update) }
        return controller
    }

    func updateUIViewController(_ controller: ChatListViewController, context: Context) {
        controller.rowView = rowView
        controller.menuEntries = menuEntries
        controller.smoothness = smoothness
        controller.safeAreaFrame = safeAreaFrame
        controller.onShowsJumpToLatestChanged = onShowsJumpToLatestChanged
        controller.onVisibleHeightChanged = { [handle] height in
            handle.visibleHeight = height
            onVisibleHeightChanged(height)
        }
        controller.updateInsets()
        controller.update(content: content)
    }

    static func dismantleUIViewController(_ controller: ChatListViewController, coordinator: ()) {
        controller.detach()
    }
}

@MainActor
final class ChatListViewController: UIViewController, UICollectionViewDelegate, UIGestureRecognizerDelegate {
    var model: ConversationModel?
    var rowView: (ChatListRowContent) -> AnyView = { _ in AnyView(EmptyView()) }
    var menuEntries: (ChatListRowContent) -> [ChatListMenuEntry] = { _ in [] }
    var smoothness: (any ScrollSmoothnessReporting)?
    var safeAreaFrame: CGRect = .zero
    var onShowsJumpToLatestChanged: (Bool) -> Void = { _ in }
    var onVisibleHeightChanged: (Double) -> Void = { _ in }

    private let layout = ChatListLayout()
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var content = ChatListContent()
    private var hasAppliedContent = false
    private var hadContent = false
    private var needsInitialScroll = false
    private var hasMeasuredInsets = false
    /// 拖曳、鍵盤動畫、選單開著時先留著的最新內容,安全了再套用。
    private var pendingContent: ChatListContent?
    private var isKeyboardAnimating = false
    private var menuTracker = ChatListMenuTracker()
    private var isMenuOpen: Bool { menuTracker.isOpen }

    private var decider = ConversationScrollDecider()
    private var flushTask: Task<Void, Never>?
    private var flushRetriesLeft = 0
    private var keyboardSettleTask: Task<Void, Never>?
    private var lastReportedFollowing = true
    private var lastReportedShowsJump = false
    private var lastReportedVisibleHeight: Double?
    private var lastBoundsHeight: CGFloat = 0
    private var lastBoundsWidth: CGFloat = 0
    private var lastFirstVisibleRowID: String?

    private var userHasDragged = false
    private var autoLoadedPages = 0
    private var isLoadingOlder = false

    /// 最近一次套用內容時錨定的列(往上補舊訊息後維持它在畫面上的位置)。
    private struct Anchor {
        var id: String
        var distanceFromVisibleTop: Double
    }

    private var lastAnchor: (anchor: Anchor, at: TimeInterval)?

    private var isUserDriven: Bool { collectionView.isDragging || collectionView.isDecelerating }

    // MARK: - 生命週期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.allowsSelection = false
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.keyboardDismissMode = .onDrag
        collectionView.accessibilityIdentifier = "conversation.list"
        view.addSubview(collectionView)

        let registration = UICollectionView.CellRegistration<ChatListCell, String> { [weak self] cell, _, id in
            guard let self, let rowContent = self.content.rows[id] else { return }
            let hosted = self.rowView(rowContent)
            cell.contentConfiguration = UIHostingConfiguration { hosted }
                .margins(.all, 0)
                .margins(.horizontal, 16)
            cell.backgroundConfiguration = .clear()
            cell.automaticallyUpdatesBackgroundConfiguration = false
        }
        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }

        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .valueChanged)
        collectionView.refreshControl = refresh

        // 點訊息區收起鍵盤(#329);不取消觸控,連結、卡片與按鈕的點擊照常。
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        collectionView.addGestureRecognizer(tap)

        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: ChatListViewController, _) in
            controller.collectionView.collectionViewLayout.invalidateLayout()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = collectionView.bounds
        if bounds.width != lastBoundsWidth {
            lastBoundsWidth = bounds.width
            layout.updateWidth(bounds.width)
        }
        if bounds.height != lastBoundsHeight {
            let isFirstLayout = lastBoundsHeight == 0
            lastBoundsHeight = bounds.height
            if !isFirstLayout {
                decider.receive(.inputBarHeightChanged)
                scheduleFlush(after: 0.05)
            }
        }
        updateInsets()
        scrollToInitialPositionIfPossible()
        reportVisibleHeight()
        reportMeasurement()
    }

    /// 列表延伸到玻璃導覽列、橫幅與輸入列底下:上下 inset 是列表框與安全區域框的差(DESIGN.md:內容從玻璃底下捲過去)。
    func updateInsets() {
        guard isViewLoaded, collectionView != nil, view.window != nil, safeAreaFrame != .zero else { return }
        let listFrame = view.convert(view.bounds, to: nil)
        let measured = ChatListInsetMath.insets(
            listMinY: listFrame.minY, listMaxY: listFrame.maxY, safeMinY: safeAreaFrame.minY, safeMaxY: safeAreaFrame.maxY)
        let target = UIEdgeInsets(top: measured.top, left: 0, bottom: measured.bottom, right: 0)
        let current = collectionView.contentInset
        guard target != current || !hasMeasuredInsets else { return }
        let wasAtTopEdge = collectionView.contentOffset.y <= -current.top + 0.5
        let wasMeasured = hasMeasuredInsets
        hasMeasuredInsets = true
        collectionView.contentInset = target
        collectionView.verticalScrollIndicatorInsets = target
        layout.invalidateLayout()
        if wasAtTopEdge { collectionView.contentOffset.y = -target.top }
        if wasMeasured, target.bottom != current.bottom {
            decider.receive(.inputBarHeightChanged)
            scheduleFlush(after: 0.05)
        }
        scrollToInitialPositionIfPossible()
        reportVisibleHeight()
        reportMeasurement()
    }

    /// 打開時直接停在最底(有尺寸之後才算數)。
    private func scrollToInitialPositionIfPossible() {
        guard needsInitialScroll, hasMeasuredInsets, collectionView.bounds.height > 0 else { return }
        needsInitialScroll = false
        scrollToBottom(animated: false)
    }

    func detach() {
        model?.onTimelineUpdate = nil
        flushTask?.cancel()
        keyboardSettleTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 內容

    /// 收到新內容:拖曳、鍵盤動畫、選單開著時先留著最新一份,安全了再套用(spec #480)。
    func update(content newContent: ChatListContent) {
        loadViewIfNeeded()
        if hasAppliedContent, newContent == content {
            pendingContent = nil
            return
        }
        if hasAppliedContent, shouldDeferApply {
            pendingContent = newContent
            return
        }
        pendingContent = nil
        apply(newContent)
    }

    private var shouldDeferApply: Bool {
        ChatListApplyGate.shouldDefer(
            isFirstApply: !hasAppliedContent, isUserDriven: isUserDriven, isKeyboardAnimating: isKeyboardAnimating, isMenuOpen: isMenuOpen)
    }

    /// 暫存的內容在安全時套用(拖曳結束、鍵盤動畫結束)。
    private func applyPendingContentIfSafe() {
        guard let pendingContent, !shouldDeferApply else { return }
        self.pendingContent = nil
        apply(pendingContent)
    }

    /// 套用新內容:順序與內容的差異交給 diffable;閱讀中時維持畫面上第一列的位置。
    private func apply(_ newContent: ChatListContent) {
        let previous = content
        let anchor = captureAnchor()
        let hasContentNow = !newContent.ids.isEmpty
        let needsInitial = ChatListInitialPosition.needsScroll(hadContent: hadContent, hasContent: hasContentNow)
        content = newContent
        hasAppliedContent = true
        hadContent = hadContent || hasContentNow
        layout.isFollowingLatest = decider.isFollowingLatest

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(newContent.ids)
        snapshot.reconfigureItems(ChatListRowPlan.changedIDs(previous: previous.rows, current: newContent.rows))
        dataSource.apply(snapshot, animatingDifferences: false)
        collectionView.layoutIfNeeded()
        if needsInitial {
            needsInitialScroll = true
            scrollToInitialPositionIfPossible()
        }
        if let anchor {
            restore(anchor)
            lastAnchor = (anchor, ProcessInfo.processInfo.systemUptime)
        }
        reportMeasurement()
        checkOlderPage()
        scheduleFlush(after: 0)
    }

    /// 時間軸的變更(來自聊天 model):餵捲動決策者,內容套用後再排定處理。
    func receive(_ update: ConversationTimeline.Update) {
        decider.receive(.timeline(update))
        scheduleFlush(after: update.cause == .userSent ? 0.05 : ConversationScrollDecider.batchInterval)
    }

    /// 「跳到最新」與下拉重新整理後。
    func jumpToLatest() {
        decider.receive(.jumpToLatest(lastRowID: content.ids.last ?? ""))
        reportFollowing()
        scheduleFlush(after: 0)
    }

    /// 輸入列上方的元素重新安排(註記卡、建議提示詞收放)。
    func inputBarArranged() {
        decider.receive(.inputBarHeightChanged)
        scheduleFlush(after: 0.05)
    }

    // MARK: - 錨點

    private var visibleTop: Double {
        collectionView.contentOffset.y + collectionView.adjustedContentInset.top
    }

    /// 畫面上最上面那一列與它離可見頂端的距離;跟隨最新時不需要(由捲動決策者捲到底)。
    private func captureAnchor() -> Anchor? {
        guard hasAppliedContent, !decider.isFollowingLatest, let top = topVisibleRow() else { return nil }
        return Anchor(id: top.id, distanceFromVisibleTop: top.minY - visibleTop)
    }

    private func topVisibleRow() -> (id: String, minY: Double)? {
        var best: (id: String, minY: Double)?
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let id = dataSource.itemIdentifier(for: indexPath), let frame = layout.layoutAttributesForItem(at: indexPath)?.frame,
                  frame.maxY > visibleTop else { continue }
            if best == nil || frame.minY < best!.minY { best = (id, frame.minY) }
        }
        return best
    }

    private func restore(_ anchor: Anchor) {
        guard let indexPath = dataSource.indexPath(for: anchor.id), let frame = layout.layoutAttributesForItem(at: indexPath)?.frame else { return }
        let target = ChatListLayoutMath.offsetKeepingRow(
            newRowMinY: frame.minY, distanceFromVisibleTop: anchor.distanceFromVisibleTop, insetTop: collectionView.adjustedContentInset.top)
        if abs(target - collectionView.contentOffset.y) > 0.5 {
            collectionView.contentOffset.y = target
        }
    }

    // MARK: - 排定與執行指令

    /// 排定一次處理(合併多次要求,取最早的時間);沒指令且還有待辦時再試幾次。
    private func scheduleFlush(after delay: TimeInterval) {
        flushRetriesLeft = 3
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            self?.runFlush()
        }
    }

    private func runFlush() {
        let command = decider.flush(at: ProcessInfo.processInfo.systemUptime)
        reportFollowing()
        if let command {
            perform(command)
        } else if flushRetriesLeft > 0 {
            flushRetriesLeft -= 1
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(ConversationScrollDecider.batchInterval))
                guard !Task.isCancelled else { return }
                self?.runFlush()
            }
        }
    }

    private func perform(_ command: ConversationScrollDecider.Command) {
        switch command {
        case .scrollToBottom(let animated), .scrollToRow(_, let animated):
            scrollToBottom(animated: animated)
        case .keepVisible(let rowID):
            if let lastAnchor, lastAnchor.anchor.id == rowID, ProcessInfo.processInfo.systemUptime - lastAnchor.at < 1, !isUserDriven {
                restore(lastAnchor.anchor)
            }
        }
    }

    private func scrollToBottom(animated: Bool) {
        collectionView.layoutIfNeeded()
        let inset = collectionView.adjustedContentInset
        let target = ChatListLayoutMath.bottomOffset(
            contentHeight: layout.collectionViewContentSize.height, boundsHeight: collectionView.bounds.height,
            insetTop: inset.top, insetBottom: inset.bottom)
        guard abs(target - collectionView.contentOffset.y) > 0.5 else { return }
        collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: target), animated: animated && !UIAccessibility.isReduceMotionEnabled)
    }

    // MARK: - 量測與回報

    private var distanceFromBottom: Double {
        let inset = collectionView.adjustedContentInset
        let container = collectionView.bounds.height - inset.top - inset.bottom
        return collectionView.contentSize.height - container - inset.top - collectionView.contentOffset.y
    }

    private func reportMeasurement() {
        guard collectionView != nil else { return }
        let inset = collectionView.adjustedContentInset
        smoothness?.report(ScrollSmoothnessSnapshot(
            contentHeight: collectionView.contentSize.height,
            containerHeight: collectionView.bounds.height - inset.top - inset.bottom,
            contentOffsetY: collectionView.contentOffset.y, topInset: inset.top,
            visibleRowCount: collectionView.indexPathsForVisibleItems.count))
        let firstVisible = topVisibleRow()?.id
        if firstVisible != lastFirstVisibleRowID {
            lastFirstVisibleRowID = firstVisible
            decider.receive(.firstVisibleRowChanged(id: firstVisible))
        }
        let showsJump = decider.distanceFromBottom > ConversationScrollDecider.nearBottomThreshold
        if showsJump != lastReportedShowsJump {
            lastReportedShowsJump = showsJump
            onShowsJumpToLatestChanged(showsJump)
        }
    }

    private func reportFollowing() {
        guard decider.isFollowingLatest != lastReportedFollowing else { return }
        lastReportedFollowing = decider.isFollowingLatest
        layout.isFollowingLatest = decider.isFollowingLatest
        model?.isFollowingLatest = decider.isFollowingLatest
    }

    private func reportVisibleHeight() {
        let inset = collectionView.adjustedContentInset
        let height = Double(collectionView.bounds.height - inset.top - inset.bottom)
        guard height != lastReportedVisibleHeight else { return }
        lastReportedVisibleHeight = height
        onVisibleHeightChanged(height)
    }

    /// 距頂端 ≤ 1 個畫面高就讀上一頁;內容還不夠填滿畫面時不必等使用者拖動(有頁數上限,#473)。
    private func checkOlderPage() {
        guard let model, model.older == .available, !isLoadingOlder else { return }
        let inset = collectionView.adjustedContentInset
        let wants = ChatListOlderPageTrigger.wantsOlderPage(
            distanceFromTop: Double(collectionView.contentOffset.y + inset.top),
            containerHeight: Double(collectionView.bounds.height - inset.top - inset.bottom),
            contentHeight: Double(collectionView.contentSize.height),
            userHasDragged: userHasDragged, autoLoadedPages: autoLoadedPages, autoLoadLimit: ConversationModel.maximumEmptyWindowPages)
        guard wants else { return }
        if !userHasDragged { autoLoadedPages += 1 }
        isLoadingOlder = true
        Task { [weak self] in
            await model.loadOlder()
            self?.isLoadingOlder = false
            self?.checkOlderPage()
        }
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        userHasDragged = true
        decider.receive(.userBeganDragging)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard hasAppliedContent else { return }
        if isUserDriven {
            decider.receive(.userScrolled(distanceFromBottom: distanceFromBottom))
        } else {
            decider.receive(.layoutMeasured(distanceFromBottom: distanceFromBottom))
        }
        reportFollowing()
        reportMeasurement()
        checkOlderPage()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        decider.receive(.userEndedDragging(distanceFromBottom: distanceFromBottom))
        applyPendingContentIfSafe()
        reportFollowing()
        scheduleFlush(after: 0.05)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        decider.receive(.userEndedDragging(distanceFromBottom: distanceFromBottom))
        applyPendingContentIfSafe()
        reportFollowing()
        scheduleFlush(after: 0.05)
    }

    /// 動畫捲到底的途中列高又被量準了,落地後再貼一次底部。
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard decider.isFollowingLatest, abs(distanceFromBottom) > 1 else { return }
        scrollToBottom(animated: false)
    }

    // MARK: - 長按選單

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint)
        -> UIContextMenuConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let rowContent = content.rows[id] else { return nil }
        let entries = menuEntries(rowContent)
        guard !entries.isEmpty else { return nil }
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { [weak self] _ in
            let actions = entries.map { entry in
                UIAction(title: entry.item.title, image: UIImage(systemName: entry.item.symbolName)) { _ in
                    if let shareURL = entry.shareURL {
                        self?.presentShare(shareURL, from: indexPath)
                    } else {
                        entry.perform()
                    }
                }
            }
            return UIMenu(children: actions)
        }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplayContextMenu configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        menuChanged(isOpen: true)
    }

    /// 選單收起的動畫結束後才算關閉:預覽飛回原處時列表不能動。
    func collectionView(_ collectionView: UICollectionView, willEndContextMenuInteraction configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        guard let animator else {
            menuChanged(isOpen: false)
            return
        }
        animator.addCompletion { [weak self] in
            Task { @MainActor in self?.menuChanged(isOpen: false) }
        }
    }

    private func menuChanged(isOpen: Bool) {
        guard let changedTo = menuTracker.menuDidChange(isOpen: isOpen) else { return }
        decider.receive(.menu(isOpen: changedTo))
        guard !changedTo else { return }
        applyPendingContentIfSafe()
        scheduleFlush(after: 0.05)
    }

    private func presentShare(_ url: URL, from indexPath: IndexPath) {
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController, let cell = collectionView.cellForItem(at: indexPath) {
            popover.sourceView = cell
            popover.sourceRect = cell.bounds
        }
        present(sheet, animated: true)
    }

    // MARK: - 下拉重新整理、鍵盤、點擊

    private func refresh() {
        guard let model else {
            collectionView.refreshControl?.endRefreshing()
            return
        }
        Task { [weak self] in
            await model.reload()
            self?.collectionView.refreshControl?.endRefreshing()
            self?.jumpToLatest()
        }
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        decider.receive(.keyboardHeightChanged)
        decider.receive(.keyboardAnimation(isRunning: true))
        isKeyboardAnimating = true
        keyboardSettleTask?.cancel()
        keyboardSettleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration + 0.05))
            guard !Task.isCancelled, let self else { return }
            self.decider.receive(.keyboardAnimation(isRunning: false))
            self.isKeyboardAnimating = false
            self.applyPendingContentIfSafe()
            self.scheduleFlush(after: 0)
        }
    }

    @objc private func dismissKeyboard() {
        KeyboardDismissal.dismiss()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

/// 聊天列表的 cell:列延伸到狀態列、導覽列與 home indicator 底下時,hosting 內容不依位置墊高(否則列高會隨捲動位置變);只保留左右。
final class ChatListCell: UICollectionViewCell {
    override var safeAreaInsets: UIEdgeInsets {
        UIEdgeInsets(top: 0, left: super.safeAreaInsets.left, bottom: 0, right: super.safeAreaInsets.right)
    }
}
#endif
