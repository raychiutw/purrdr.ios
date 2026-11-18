#if canImport(UIKit)
import PurrdrCore
import UIKit

/// 組字浮層(#140):在遠端游標格子上畫組字中的文字，終端機字型、每格對齊、組字段畫底線。
final class TerminalCompositionOverlay: UIView {
    private(set) var markedText = ""
    /// 輸入法目前選取的組字段(UTF-16);有長度時畫粗底線。
    private var selectedRange = NSRange(location: 0, length: 0)
    private var font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var textColor = UIColor.white
    private var cellWidth: CGFloat = 8

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = true
        isHidden = true
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Composing")
        accessibilityIdentifier = "terminal.composition"
        accessibilityTraits = .updatesFrequently
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 更新內容;沒有組字時隱藏。
    func show(
        _ markedText: String, selectedRange: NSRange, frame: CGRect,
        font: UIFont, cellWidth: CGFloat, textColor: UIColor, backgroundColor: UIColor
    ) {
        self.markedText = markedText
        self.selectedRange = selectedRange
        self.font = font
        self.cellWidth = cellWidth
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.frame = frame
        accessibilityValue = markedText
        isHidden = markedText.isEmpty
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        var column = 0
        var utf16Offset = 0
        for character in markedText {
            let columns = TerminalCompositionLayout.columns(of: String(character))
            let cell = CGRect(x: CGFloat(column) * cellWidth, y: 0, width: CGFloat(columns) * cellWidth, height: bounds.height)
            let glyph = String(character) as NSString
            let size = glyph.size(withAttributes: attributes)
            glyph.draw(at: CGPoint(x: cell.midX - size.width / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)

            let isSelected = selectedRange.length > 0 && NSLocationInRange(utf16Offset, selectedRange)
            let thickness: CGFloat = isSelected ? 2 : 1
            context.setFillColor(textColor.cgColor)
            context.fill(CGRect(x: cell.minX, y: bounds.height - thickness, width: cell.width, height: thickness))

            column += columns
            utf16Offset += character.utf16.count
        }
    }
}
#endif
