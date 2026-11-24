#if os(iOS)
import PurrdrCore
import UIKit

/// 聊天列表自適應高度與位移補償的累計數字(診斷與測試用;只加數字,不做 I/O)。
@MainActor
final class ChatListSizingProbe {
    struct Counts: Equatable {
        /// 列自適應(`preferredLayoutAttributesFitting`)的次數與總毫秒、單次最長毫秒。
        var fits = 0
        var fitMilliseconds = 0.0
        var longestFitMilliseconds = 0.0
        /// 自適應結果與原本(估計)高度不同的次數:每一次都會讓 layout 重算並補償位移。
        var heightChanges = 0
        /// layout 在列高改變時補的 contentOffset:次數與位移絕對值總和。
        var layoutAdjustments = 0
        var layoutAdjustmentPoints = 0.0
        /// 程式設定的 contentOffset(捲到底、錨點還原):次數與位移絕對值總和。
        var programmaticOffsets = 0
        var programmaticOffsetPoints = 0.0
        /// 自適應直接用了已知高度(沒有量)的次數。
        var cacheHits = 0
    }

    private(set) var counts = Counts()

    func reset() { counts = Counts() }

    func noteFit(milliseconds: Double, heightChanged: Bool) {
        counts.fits += 1
        counts.fitMilliseconds += milliseconds
        counts.longestFitMilliseconds = max(counts.longestFitMilliseconds, milliseconds)
        if heightChanged { counts.heightChanges += 1 }
    }

    func noteCacheHit() { counts.cacheHits += 1 }

    func noteLayoutAdjustment(points: Double) {
        counts.layoutAdjustments += 1
        counts.layoutAdjustmentPoints += abs(points)
    }

    func noteProgrammaticOffset(points: Double) {
        counts.programmaticOffsets += 1
        counts.programmaticOffsetPoints += abs(points)
    }
}

/// 聊天列表的單欄 layout(ADR-0014):全寬自適應高度的列，內容比畫面矮時貼著底部。
/// 列高在量到實際高度(preferred attributes)的同一次排版內補 contentOffset,位移的算法在 `ChatListLayoutMath`。
final class ChatListLayout: UICollectionViewFlowLayout {
    /// 跟隨最新時任何一列變高都保持底部不動;閱讀中只補可見範圍上方的變化。
    var isFollowingLatest = true
    var probe: ChatListSizingProbe?

    override init() {
        super.init()
        scrollDirection = .vertical
        minimumLineSpacing = 12
        minimumInteritemSpacing = 0
        sectionInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        estimatedItemSize = CGSize(width: 1, height: 60)
    }

    required init?(coder: NSCoder) {
        fatalError("ChatListLayout 只用程式碼建立")
    }

    /// 列的估計寬度要等於實際寬度,自適應才只改高度。
    func updateWidth(_ width: CGFloat) {
        let size = CGSize(width: max(1, width - sectionInset.left - sectionInset.right), height: 60)
        if estimatedItemSize != size { estimatedItemSize = size }
    }

    // MARK: - 底部錨定

    private var visibleHeight: CGFloat {
        guard let collectionView else { return 0 }
        let inset = collectionView.adjustedContentInset
        return collectionView.bounds.height - inset.top - inset.bottom
    }

    private var bottomShift: CGFloat {
        CGFloat(ChatListLayoutMath.bottomAnchorShift(contentHeight: super.collectionViewContentSize.height, visibleHeight: visibleHeight))
    }

    override var collectionViewContentSize: CGSize {
        var size = super.collectionViewContentSize
        size.height += bottomShift
        return size
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        let shift = bottomShift
        return super.layoutAttributesForElements(in: rect.offsetBy(dx: 0, dy: -shift))?.compactMap { Self.shifted($0, by: shift) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        super.layoutAttributesForItem(at: indexPath).flatMap { Self.shifted($0, by: bottomShift) }
    }

    private static func shifted(_ attributes: UICollectionViewLayoutAttributes, by shift: CGFloat) -> UICollectionViewLayoutAttributes? {
        guard shift != 0 else { return attributes }
        guard let copy = attributes.copy() as? UICollectionViewLayoutAttributes else { return attributes }
        copy.frame = attributes.frame.offsetBy(dx: 0, dy: shift)
        return copy
    }

    // MARK: - 列高改變時同一次排版補位置

    override func invalidationContext(
        forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
        withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forPreferredLayoutAttributes: preferredAttributes, withOriginalAttributes: originalAttributes)
        guard let collectionView, preferredAttributes.indexPath.item >= 0 else { return context }
        let adjustment = ChatListLayoutMath.offsetAdjustment(
            rowMinY: originalAttributes.frame.minY,
            oldHeight: originalAttributes.frame.height,
            newHeight: preferredAttributes.frame.height,
            visibleTop: collectionView.contentOffset.y + collectionView.adjustedContentInset.top,
            contentHeight: super.collectionViewContentSize.height,
            visibleHeight: visibleHeight,
            isFollowingLatest: isFollowingLatest)
        if adjustment != 0 {
            probe?.noteLayoutAdjustment(points: adjustment)
            context.contentOffsetAdjustment.y += CGFloat(adjustment)
        }
        return context
    }
}
#endif
