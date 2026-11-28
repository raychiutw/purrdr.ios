import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 聊天列表一列的內容(diffable 的 identifier 是列 id,內容變了才重畫那一列)。
enum ChatListRowContent: Equatable {
    case older(ConversationModel.Older)
    case away(AwaySummary, isCollapsed: Bool)
    case entry(ConversationRow, turnHeader: AgentTurnHeader?)
    case pending(PendingItem)
    case notice(DisplayedError)
    /// 「需要你」的列(#680):等待回答的問題卡(`pending`)與已送達的回答紀錄(`answered`)。
    /// 帶內容是為了題目、選項或回答變了時,diffable 與列高快取知道這一列要重畫、重量。
    case prompt(pending: BlockedPrompt?, answered: AnsweredPrompt?)
    case working
}

extension ChatListRowContent {
    /// 這一列在 diffable data source 裡的 id(與 `ChatListRowPlan.ids` 的組法一致)。
    var rowID: String {
        switch self {
        case .older: ChatListRowPlan.olderID
        case .away: ChatListRowPlan.awayID
        case .entry(let row, _): row.id
        case .pending(let item): item.id
        case .notice: ChatListRowPlan.noticeID
        case .prompt: ChatListRowPlan.promptID
        case .working: ChatListRowPlan.workingID
        }
    }
}

extension ChatListRowContent {
    /// 同一種列的高度大致相近:沒量過的列用同種列的平均高度當估計(`ChatListHeightCache`)。
    var kind: String {
        switch self {
        case .older: "older"
        case .away: "away"
        case .entry: "entry"
        case .pending: "pending"
        case .notice: "notice"
        case .prompt: "prompt"
        case .working: "working"
        }
    }
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
/// 寫進列的 hosted view 的環境值(`ConversationView.rowView` 重新注入的那幾個會變的):變了就要讓已設定的 cell 重畫。
struct ChatListRowEnvironment: Equatable {
    var hostTheme: HostTheme?
    var inlineSlashNames: Set<String>
}

struct ChatListView: UIViewControllerRepresentable {
    let content: ChatListContent
    let rowEnvironment: ChatListRowEnvironment
    /// app 在前景(scenePhase);不在前景時列表不排程捲動。
    let isSceneActive: Bool
    let model: ConversationModel
    let handle: ChatListHandle
    let rowView: (ChatListRowContent) -> AnyView
    /// 一列長按選單的項目(空陣列表示這一列沒有選單,留給文字選取)。
    let menuEntries: (ChatListRowContent) -> [ChatListMenuEntry]
    /// 避開玻璃導覽列、橫幅與輸入列後的安全區域框(全域座標):列表延伸到玻璃底下,上下留白由它與列表框的差決定。
    let safeAreaFrame: CGRect
    let onShowsJumpToLatestChanged: (Bool) -> Void
    let onVisibleHeightChanged: (Double) -> Void
    /// 捲動卡頓記錄器(沒注入時不記錄)。
    var hitchRecorder: DiagnosticRecorder?
    /// 驗收用:量測閱讀位移(UI 測試;由 app 依啟動設定注入)。
    var tracksReadingDrift = false

    func makeUIViewController(context: Context) -> ChatListViewController {
        let controller = ChatListViewController()
        controller.model = model
        controller.hitchRecorder = hitchRecorder
        controller.tracksReadingDrift = tracksReadingDrift
        handle.jumpToLatestAction = { [weak controller] in controller?.jumpToLatest() }
        handle.inputBarArrangedAction = { [weak controller] in controller?.inputBarArranged() }
        model.onTimelineUpdate = { [weak controller] update in controller?.receive(update) }
        return controller
    }

    func updateUIViewController(_ controller: ChatListViewController, context: Context) {
        controller.rowView = rowView
        controller.rowEnvironment = rowEnvironment
        controller.setSceneActive(isSceneActive)
        controller.menuEntries = menuEntries
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
final class ChatListViewController: UIViewController, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate {
    var model: ConversationModel?
    var rowView: (ChatListRowContent) -> AnyView = { _ in AnyView(EmptyView()) }
    /// 列的環境值;與上次套用時不同就讓所有列重畫(內容相等也一樣)。
    var rowEnvironment = ChatListRowEnvironment(hostTheme: nil, inlineSlashNames: [])
    private var appliedRowEnvironment: ChatListRowEnvironment?
    var menuEntries: (ChatListRowContent) -> [ChatListMenuEntry] = { _ in [] }
    var safeAreaFrame: CGRect = .zero
    var onShowsJumpToLatestChanged: (Bool) -> Void = { _ in }
    var onVisibleHeightChanged: (Double) -> Void = { _ in }
    /// 捲動卡頓記錄器(診斷用,只記數字;列表可見且 app 在前景時才量測)。
    var hitchRecorder: DiagnosticRecorder?
    /// 驗收用:量測閱讀位移(UI 測試;由 `ChatListView` 注入)。
    var tracksReadingDrift = false
    private var hitchMonitor: ChatHitchMonitor?
    private var contentSizeObservation: NSKeyValueObservation?

    private let layout = ChatListLayout()
    let sizingProbe = ChatListSizingProbe()
    /// 量過的列高(cell 自適應時寫入、排版估計時讀出)。
    private let heightStore = ChatListHeightStore()
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
    private var flushPolicy = ChatListFlushPolicy()
    private var keyboardSettleTask: Task<Void, Never>?
    private var lastReportedFollowing = true
    private var lastReportedShowsJump = false
    private var lastReportedVisibleHeight: Double?
    private var lastBoundsHeight: CGFloat = 0
    private var lastBoundsWidth: CGFloat = 0
    private var lastFirstVisibleRowID: String?
    private var reportsScheduled = false
    private var lastApplyAt: TimeInterval?
    private var applyTask: Task<Void, Never>?
    #if DEBUG
    private var driftTracker = ReadingDriftTracker()
    #endif

    private var userHasDragged = false
    private var autoLoadedPages = 0
    private var isLoadingOlder = false

    /// 最近一次套用內容時錨定的列(往上補舊訊息後維持它在畫面上的位置)。
    private struct Anchor {
        var id: String
        var distanceFromVisibleTop: Double
    }

    private var lastAnchor: (anchor: Anchor, at: TimeInterval)?

    /// 目前是不是「跟隨最新」(測試與診斷用)。
    var isFollowingLatest: Bool { decider.isFollowingLatest }

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
        collectionView.hidesTopEdgeEffect()
        collectionView.keyboardDismissMode = .onDrag
        collectionView.accessibilityIdentifier = "conversation.list"
        view.addSubview(collectionView)
        layout.probe = sizingProbe
        if let hitchRecorder {
            hitchMonitor = ChatHitchMonitor(
                recorder: hitchRecorder, scrollView: collectionView, visibleCells: { [weak self] in self?.collectionView.visibleCells.count ?? 0 })
        }

        let registration = UICollectionView.CellRegistration<ChatListCell, String> { [weak self] cell, _, id in
            guard let self, let rowContent = self.content.rows[id] else { return }
            let hosted = self.rowView(rowContent)
            cell.fitTimer = self.hitchMonitor?.fitTimer
            cell.probe = self.sizingProbe
            cell.heightStore = self.heightStore
            cell.rowID = id
            cell.rowKind = rowContent.kind
            cell.contentConfiguration = UIHostingConfiguration { hosted }
                .margins(.all, 0)
                .margins(.horizontal, 16)
            cell.backgroundConfiguration = .clear()
            cell.automaticallyUpdatesBackgroundConfiguration = false
        }
        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }

        contentSizeObservation = collectionView.observe(\.contentSize, options: [.old, .new]) { [weak self] _, change in
            guard let old = change.oldValue, let new = change.newValue, abs(new.height - old.height) > 0.5 else { return }
            MainActor.assumeIsolated {
                self?.hitchMonitor?.note(.contentSizeChange(points: Double(new.height - old.height)))
                self?.contentSizeChangedWhileFollowing()
            }
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
            controller.configureHeightCache()
            controller.collectionView.collectionViewLayout.invalidateLayout()
        }
    }

    /// 列表正在離開畫面(`viewWillDisappear` 到再出現之間):新內容先留著,不在轉場裡做版面計算。
    private var isLeaving = false

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        resumeAfterLeaving()
    }

    private func resumeAfterLeaving() {
        guard isLeaving else { return }
        isLeaving = false
        model?.setLeaving(false)
        applyPendingContentIfSafe()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        resumeAfterLeaving()
        hitchRecorder?.setSceneActive(flushPolicy.isSceneActive)
        updateHitchWorkingFlag()
        hitchMonitor?.appear()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isLeaving = true
        model?.setLeaving(true)
        hitchMonitor?.disappear()
    }

    private func updateHitchWorkingFlag() {
        hitchRecorder?.setAgentWorking(model?.agentStatus == .working)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = collectionView.bounds
        if bounds.width != lastBoundsWidth {
            lastBoundsWidth = bounds.width
            layout.updateWidth(bounds.width)
            configureHeightCache()
        }
        if bounds.height != lastBoundsHeight {
            let isFirstLayout = lastBoundsHeight == 0
            lastBoundsHeight = bounds.height
            if !isFirstLayout {
                decider.receive(.inputBarHeightChanged)
                // 版面事件:只排一次處理,不補重試額度(高度反覆變動不會無限重試)。
                scheduleFlush(after: 0.05, reason: .layout)
            }
        }
        updateInsets()
        scrollToInitialPositionIfPossible()
        reportMeasurement()
    }

    /// 內容高度變了(列被量到實際高度、內容併入)而位移沒變時 `scrollViewDidScroll` 不會來:
    /// 跟隨最新卻離底部變遠,補一次排程貼底(`.layout` 不補重試額度,不會無限重試)。
    private func contentSizeChangedWhileFollowing() {
        guard hasAppliedContent, !isUserDriven, decider.isFollowingLatest, collectionView != nil else { return }
        decider.receive(.layoutMeasured(distanceFromBottom: distanceFromBottom))
        if distanceFromBottom > ConversationScrollDecider.settleTolerance { scheduleFlush(after: 0.05, reason: .layout) }
    }

    private func configureHeightCache() {
        let category = collectionView.traitCollection.preferredContentSizeCategory
        let defaultHeight = UIFontMetrics(forTextStyle: .body).scaledValue(for: 60, compatibleWith: collectionView.traitCollection)
        heightStore.configure(width: Double(layout.estimatedItemSize.width), category: category.rawValue, defaultHeight: Double(defaultHeight))
    }

    /// 排版用的估計高度:量過的列用量到的高度,沒量過的用同種列的平均(寬度固定為 layout 的列寬)。
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = layout.estimatedItemSize.width
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return CGSize(width: width, height: 60) }
        return CGSize(width: width, height: CGFloat(heightStore.estimate(for: id, kind: content.rows[id]?.kind ?? "entry")))
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
        decider.receive(.topInsetChanged(wasAtTopEdge: wasAtTopEdge))
        if wasMeasured, target.bottom != current.bottom {
            decider.receive(.inputBarHeightChanged)
        }
        flushNow()
        scrollToInitialPositionIfPossible()
        reportMeasurement()
    }

    /// 打開時直接停在最底:有尺寸之後才告訴捲動決策者「開啟了」,位置由它決定。
    private func scrollToInitialPositionIfPossible() {
        guard needsInitialScroll, hasMeasuredInsets, collectionView.bounds.height > 0 else { return }
        needsInitialScroll = false
        decider.receive(.openedWithContent)
        flushNow()
    }

    func detach() {
        hitchMonitor?.teardown()
        hitchMonitor = nil
        contentSizeObservation = nil
        model?.onTimelineUpdate = nil
        flushTask?.cancel()
        applyTask?.cancel()
        keyboardSettleTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 內容

    /// 收到新內容:拖曳、鍵盤動畫、選單開著時先留著最新一份,安全了再套用(spec #480)。
    func update(content newContent: ChatListContent) {
        loadViewIfNeeded()
        if hasAppliedContent, newContent == content, rowEnvironment == appliedRowEnvironment {
            pendingContent = nil
            return
        }
        hitchMonitor?.note(.contentUpdate)
        updateHitchWorkingFlag()
        if hasAppliedContent, shouldDeferApply {
            pendingContent = newContent
            return
        }
        let delay = hasAppliedContent
            ? ChatListApplyBatch.delay(
                now: ProcessInfo.processInfo.systemUptime, lastApplyAt: lastApplyAt, interval: ConversationScrollDecider.batchInterval)
            : 0
        if delay > 0 {
            pendingContent = newContent
            scheduleApply(after: delay)
            return
        }
        pendingContent = nil
        apply(newContent)
    }

    /// 內容約每 100 ms 才套用一次;間隔未滿時留著最新一份,滿了再套。
    private func scheduleApply(after delay: TimeInterval) {
        guard applyTask == nil else { return }
        applyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            applyTask = nil
            applyPendingContentIfSafe()
        }
    }

    private var shouldDeferApply: Bool {
        ChatListApplyGate.shouldDefer(
            isFirstApply: !hasAppliedContent, isUserDriven: isUserDriven, isKeyboardAnimating: isKeyboardAnimating, isMenuOpen: isMenuOpen,
            isLeaving: isLeaving)
    }

    /// 暫存的內容在安全時套用(拖曳結束、鍵盤動畫結束)。
    private func applyPendingContentIfSafe() {
        guard let pendingContent, !shouldDeferApply else { return }
        self.pendingContent = nil
        guard pendingContent != content || rowEnvironment != appliedRowEnvironment else { return }
        apply(pendingContent)
    }

    /// 套用新內容:順序與內容的差異交給 diffable;閱讀中時維持畫面上第一列的位置。
    private func apply(_ newContent: ChatListContent) {
        let previous = content
        let anchor = captureAnchor()
        let hasContentNow = !newContent.ids.isEmpty
        let needsInitial = ChatListInitialPosition.needsScroll(hadContent: hadContent, hasContent: hasContentNow)
        content = newContent
        lastApplyAt = ProcessInfo.processInfo.systemUptime
        hasAppliedContent = true
        hadContent = hadContent || hasContentNow
        layout.isFollowingLatest = decider.isFollowingLatest

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(newContent.ids)
        let environmentChanged = appliedRowEnvironment.map { $0 != rowEnvironment } ?? false
        appliedRowEnvironment = rowEnvironment
        let reconfigureIDs = ChatListRowPlan.reconfigureIDs(previous: previous.rows, current: newContent.rows, environmentChanged: environmentChanged)
        snapshot.reconfigureItems(reconfigureIDs)
        heightStore.invalidate(reconfigureIDs)
        heightStore.prune(keeping: Set(newContent.ids))
        hitchMonitor?.note(.batchApply)
        hitchMonitor?.note(.reconfigure(count: reconfigureIDs.count))
        dataSource.apply(snapshot, animatingDifferences: false)
        collectionView.layoutIfNeeded()
        if let anchor {
            lastAnchor = (anchor, ProcessInfo.processInfo.systemUptime)
        }
        decider.receive(.contentApplied(anchorRowID: anchor?.id))
        if needsInitial {
            needsInitialScroll = true
            scrollToInitialPositionIfPossible()
        }
        reportMeasurement()
        checkOlderPage()
        flushNow()
    }

    /// 時間軸的變更(來自聊天 model):餵捲動決策者,內容套用後再排定處理。
    func receive(_ update: ConversationTimeline.Update) {
        decider.receive(.timeline(update))
        scheduleFlush(after: update.cause == .userSent ? 0.05 : ConversationScrollDecider.batchInterval)
    }

    /// 「跳到最新」鈕。下拉重新整理後不跳:由決策者依 `.refreshed` 維持原位。
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
            hitchMonitor?.note(.offsetCorrection(points: target - collectionView.contentOffset.y))
            sizingProbe.noteProgrammaticOffset(points: target - collectionView.contentOffset.y)
            collectionView.contentOffset.y = target
        }
    }

    // MARK: - 排定與執行指令

    /// 排定一次處理(合併多次要求,取最早的時間);沒指令且還有待辦時再試幾次。
    private func scheduleFlush(after delay: TimeInterval, reason: ChatListFlushPolicy.Reason = .event) {
        guard flushPolicy.schedule(reason) else { return }
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            self?.runFlush()
        }
    }

    /// 同一次更新內立刻處理(內容套用、開啟定位、inset 改變時,不能多等一個畫面):決策仍是捲動決策者的。
    private func flushNow() {
        guard flushPolicy.schedule(.event) else { return }
        flushTask?.cancel()
        runFlush()
    }

    /// app 前景狀態改變(由 SwiftUI 的 scenePhase 傳來):進背景停止排程,回前景補一次處理。
    func setSceneActive(_ isActive: Bool) {
        hitchRecorder?.setSceneActive(isActive)
        guard flushPolicy.isSceneActive != isActive else { return }
        flushPolicy.isSceneActive = isActive
        if isActive { scheduleFlush(after: 0.05) } else { flushTask?.cancel() }
    }

    private func runFlush() {
        guard flushPolicy.mayRunFlush else { return }
        let command = decider.flush(at: ProcessInfo.processInfo.systemUptime)
        reportFollowing()
        if let command {
            perform(command)
        } else if flushPolicy.consumeRetry() {
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(ConversationScrollDecider.batchInterval))
                guard !Task.isCancelled else { return }
                self?.runFlush()
            }
        }
    }

    private func perform(_ command: ConversationScrollDecider.Command) {
        switch command {
        case .scrollToBottom(let animated):
            scrollToBottom(animated: animated)
        case .scrollToRow(let id, let animated):
            scrollToRow(id: id, animated: animated)
        case .pinToTopEdge:
            setOffsetY(-collectionView.adjustedContentInset.top, animated: false)
        case .keepVisible(let rowID):
            if let lastAnchor, lastAnchor.anchor.id == rowID, ProcessInfo.processInfo.systemUptime - lastAnchor.at < 1, !isUserDriven {
                restore(lastAnchor.anchor)
            }
        }
    }

    private func bottomTarget() -> Double {
        let inset = collectionView.adjustedContentInset
        return ChatListLayoutMath.bottomOffset(
            contentHeight: layout.collectionViewContentSize.height, boundsHeight: collectionView.bounds.height,
            insetTop: inset.top, insetBottom: inset.bottom)
    }

    private func scrollToBottom(animated: Bool) {
        collectionView.layoutIfNeeded()
        settleOffset(animated: animated) { [self] in bottomTarget() }
    }

    /// 捲到指定列(底緣停在可見底緣);找不到列或它就是最後一列時等同捲到底。
    private func scrollToRow(id: String, animated: Bool) {
        guard id != content.ids.last, dataSource.indexPath(for: id) != nil else {
            scrollToBottom(animated: animated)
            return
        }
        collectionView.layoutIfNeeded()
        settleOffset(animated: animated) { [self] in
            guard let indexPath = dataSource.indexPath(for: id), let frame = layout.layoutAttributesForItem(at: indexPath)?.frame else {
                return bottomTarget()
            }
            let inset = collectionView.adjustedContentInset
            return ChatListLayoutMath.offsetShowingRowBottom(
                rowMaxY: frame.maxY, boundsHeight: collectionView.bounds.height, insetTop: inset.top, insetBottom: inset.bottom,
                contentHeight: layout.collectionViewContentSize.height)
        }
    }

    /// 捲到 `target()` 算出的位置。距離不遠且要動畫才用動畫;否則直接跳,並在同一輪排版內重算對準
    /// (目的地的列這時才被量到實際高度,估計的內容高度會變,一次跳不準)。
    private func settleOffset(animated: Bool, target: () -> Double) {
        var goal = target()
        let animates = ChatListLayoutMath.animatesJump(
            wanted: animated && !UIAccessibility.isReduceMotionEnabled, distance: goal - Double(collectionView.contentOffset.y),
            visibleHeight: visibleHeight)
        guard !animates else {
            setOffsetY(goal, animated: true)
            return
        }
        for _ in 0..<ChatListLayoutMath.maximumSettlePasses {
            setOffsetY(goal, animated: false)
            collectionView.layoutIfNeeded()
            let next = target()
            if abs(next - goal) <= 0.5 { return }
            goal = next
        }
        setOffsetY(goal, animated: false)
    }

    private func setOffsetY(_ target: Double, animated: Bool) {
        guard abs(target - collectionView.contentOffset.y) > 0.5 else { return }
        hitchMonitor?.note(.offsetCorrection(points: target - collectionView.contentOffset.y))
        sizingProbe.noteProgrammaticOffset(points: target - collectionView.contentOffset.y)
        collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: target), animated: animated)
    }

    // MARK: - 量測與回報

    /// 可見高度:列表框扣掉上下 inset(玻璃導覽列與輸入列底下的部分)。
    private var visibleHeight: Double {
        let inset = collectionView.adjustedContentInset
        return Double(collectionView.bounds.height - inset.top - inset.bottom)
    }

    private var distanceFromBottom: Double {
        collectionView.contentSize.height - visibleHeight - collectionView.adjustedContentInset.top - collectionView.contentOffset.y
    }

    /// 量測:決策者的輸入同步更新;交給 SwiftUI 的回報延後(`scheduleStateReports`)。
    private func reportMeasurement() {
        guard collectionView != nil else { return }
        let firstVisible = topVisibleRow()?.id
        if firstVisible != lastFirstVisibleRowID {
            lastFirstVisibleRowID = firstVisible
            decider.receive(.firstVisibleRowChanged(id: firstVisible))
        }
        #if DEBUG
        trackReadingDrift()
        #endif
        scheduleStateReports()
    }

    /// 回報給 SwiftUI 的狀態(「跳到最新」鈕、可見高度)延後到這次更新與排版結束後,同一批只送一次(AGENTS.md 主執行緒更新規則)。
    private func scheduleStateReports() {
        guard !reportsScheduled else { return }
        reportsScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            reportsScheduled = false
            deliverStateReports()
        }
    }

    private func deliverStateReports() {
        guard collectionView != nil else { return }
        let showsJump = decider.distanceFromBottom > ConversationScrollDecider.nearBottomThreshold
        if showsJump != lastReportedShowsJump {
            lastReportedShowsJump = showsJump
            onShowsJumpToLatestChanged(showsJump)
        }
        let height = visibleHeight
        if height != lastReportedVisibleHeight {
            lastReportedVisibleHeight = height
            onVisibleHeightChanged(height)
        }
    }

    #if DEBUG
    /// 驗收用量測(UI 測試讀 `conversation.list` 的 value):閱讀中停下後基準列離可見頂端的最大位移,實際上下 inset 與列數(測試用來等內容真的接上,不靠固定秒數)。
    private func trackReadingDrift() {
        guard tracksReadingDrift else { return }
        if isUserDriven || decider.isFollowingLatest {
            driftTracker.clear()
        } else if driftTracker.baselineRowID == nil {
            if let top = topVisibleRow() { driftTracker.setBaseline(rowID: top.id, distanceFromVisibleTop: top.minY - visibleTop) }
        } else if let rowID = driftTracker.baselineRowID, let indexPath = dataSource.indexPath(for: rowID),
                  let frame = layout.layoutAttributesForItem(at: indexPath)?.frame {
            driftTracker.observe(distanceFromVisibleTop: frame.minY - visibleTop)
        }
        let drift = driftTracker.baselineRowID == nil ? "none" : String(format: "%.1f", driftTracker.maxDrift)
        let inset = collectionView.adjustedContentInset
        collectionView.accessibilityValue = String(
            format: "drift=%@ insetTop=%.1f insetBottom=%.1f rows=%d dist=%.1f follow=%d", drift, inset.top, inset.bottom,
            dataSource.snapshot().numberOfItems, distanceFromBottom, decider.isFollowingLatest ? 1 : 0)
    }
    #endif

    private func reportFollowing() {
        guard decider.isFollowingLatest != lastReportedFollowing else { return }
        lastReportedFollowing = decider.isFollowingLatest
        layout.isFollowingLatest = decider.isFollowingLatest
        model?.isFollowingLatest = decider.isFollowingLatest
    }

    /// 距頂端 ≤ 1 個畫面高就讀上一頁;內容還不夠填滿畫面時不必等使用者拖動(有頁數上限,#473)。
    private func checkOlderPage() {
        guard let model, model.older == .available, !isLoadingOlder else { return }
        let wants = ChatListOlderPageTrigger.wantsOlderPage(
            distanceFromTop: visibleTop,
            containerHeight: visibleHeight,
            contentHeight: Double(collectionView.contentSize.height),
            userHasDragged: userHasDragged, autoLoadedPages: autoLoadedPages, autoLoadLimit: ConversationModel.maximumAutoLoadPages)
        guard wants else { return }
        if !userHasDragged { autoLoadedPages += 1 }
        isLoadingOlder = true
        hitchRecorder?.setOlderLoading(true)
        Task { [weak self] in
            await model.loadOlder()
            self?.isLoadingOlder = false
            self?.hitchRecorder?.setOlderLoading(false)
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
            // 跟隨最新卻被排版留在離底很遠的位置(A1):排一次處理補貼底部。
            if decider.isFollowingLatest, distanceFromBottom > ConversationScrollDecider.settleTolerance {
                scheduleFlush(after: 0.05, reason: .layout)
            }
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
        reportMeasurement()
        scheduleFlush(after: 0.05)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        decider.receive(.userEndedDragging(distanceFromBottom: distanceFromBottom))
        applyPendingContentIfSafe()
        reportFollowing()
        reportMeasurement()
        scheduleFlush(after: 0.05)
    }

    /// 動畫捲到底的途中列高又被量準了:交給捲動決策者判斷落地後要不要再貼一次底部。
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        decider.receive(.scrollAnimationEnded(distanceFromBottom: distanceFromBottom))
        flushNow()
    }

    // MARK: - 長按選單

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint)
        -> UIContextMenuConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let rowContent = content.rows[id] else { return nil }
        let entries = menuEntries(rowContent)
        guard !entries.isEmpty else { return nil }
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { [weak self] _ in
            let actions = entries.map { entry in
                UIAction(
                    title: entry.item.presentation.title, image: UIImage(systemName: entry.item.presentation.symbolName),
                    attributes: entry.item.presentation.isDestructive ? .destructive : []
                ) { _ in
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

/// 量過的列高,cell 與 controller 共用(都在主執行緒)。
@MainActor
final class ChatListHeightStore {
    private var cache = ChatListHeightCache()

    func configure(width: Double, category: String, defaultHeight: Double) {
        if cache.defaultHeight != defaultHeight {
            cache = ChatListHeightCache(defaultHeight: defaultHeight)
        }
        cache.configure(width: width, category: category)
    }

    func record(id: String, kind: String, height: Double) { cache.record(id: id, kind: kind, height: height) }
    func knownHeight(for id: String) -> Double? { cache.knownHeight(for: id) }
    func estimate(for id: String, kind: String) -> Double { cache.estimate(for: id, kind: kind) }
    func invalidate(_ ids: some Sequence<String>) { cache.invalidate(ids) }
    func prune(keeping ids: Set<String>) { cache.prune(keeping: ids) }
}

/// 聊天列表的 cell:列延伸到狀態列、導覽列與 home indicator 底下時,hosting 內容不依位置墊高(否則列高會隨捲動位置變);只保留左右。
final class ChatListCell: UICollectionViewCell {
    /// 卡頓記錄器的自適應計時(記錄器沒運作時 `isActive` 為 false,不計時)。
    var fitTimer: HitchFitTimer?
    var probe: ChatListSizingProbe?
    var heightStore: ChatListHeightStore?
    var rowID: String?
    var rowKind = "entry"

    override var safeAreaInsets: UIEdgeInsets {
        UIEdgeInsets(top: 0, left: super.safeAreaInsets.left, bottom: 0, right: super.safeAreaInsets.right)
    }

    /// 自適應只改高度:寬度固定為 layout 給的寬度(`required`),不讓長段文字以理想寬度撐出比畫面寬的列。
    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let attributes = layoutAttributes.copy() as? UICollectionViewLayoutAttributes ?? layoutAttributes
        // 還沒顯示在列表上的 cell(排版為了估計高度先配置的):這一列量過、內容沒變就直接用,不再重量(一次約 3~10 ms)。
        // 已顯示的 cell 一律重量:展開、圖片載入等內部變化要量得到。
        if let rowID, let known = heightStore?.knownHeight(for: rowID), (superview as? UICollectionView)?.indexPath(for: self) == nil {
            attributes.size = CGSize(width: layoutAttributes.size.width, height: CGFloat(known))
            probe?.noteCacheHit()
            return attributes
        }
        let timer = fitTimer?.isActive == true ? fitTimer : nil
        let started = DispatchTime.now().uptimeNanoseconds
        defer {
            timer?.record(startNanoseconds: started)
        }
        let fitted = contentView.systemLayoutSizeFitting(
            CGSize(width: layoutAttributes.size.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        attributes.size = CGSize(width: layoutAttributes.size.width, height: fitted.height)
        if let rowID { heightStore?.record(id: rowID, kind: rowKind, height: Double(fitted.height)) }
        probe?.noteFit(
            milliseconds: Double(DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000,
            heightChanged: abs(fitted.height - layoutAttributes.size.height) > 0.5)
        return attributes
    }
}
#endif
