import Foundation
import PurrdrAgentFeatures
import Testing
@testable import PurrdrFeatures

/// 輸入框本體的寬度(#512 追加):收合與展開都不得比 0.51.1 窄。
struct ComposerWidthTests {
    /// 0.51.1 的版面:卡片左右各 16pt;收合時左右內距 6、「+」與送出各 44、間隙 4;展開時輸入框兩側內距 4。
    private func baselineEditorWidth(container: Double, hasAttach: Bool, expanded: Bool) -> Double {
        let card = container - 32
        if expanded { return card - 8 }
        return card - 12 - (hasAttach ? 48 : 0) - 48
    }

    private func editorWidth(container: Double, hasAttach: Bool, expanded: Bool) -> Double {
        ComposerCardLayout.editorWidth(
            cardWidth: ComposerCardLayout.cardWidth(containerWidth: container), hasAttach: hasAttach, form: expanded ? .expanded : .collapsed)
    }

    /// iPhone SE、iPhone 17、iPhone 17 Pro Max、iPad 直式對話欄、iPad 寬視窗。
    private let containers: [Double] = [375, 402, 440, 560, 820]

    @Test("收合的輸入框比 0.51.1 寬(有「+」與沒有「+」)")
    func collapsedIsWiderThanBaseline() {
        for container in containers {
            for hasAttach in [true, false] {
                #expect(
                    editorWidth(container: container, hasAttach: hasAttach, expanded: false)
                        > baselineEditorWidth(container: container, hasAttach: hasAttach, expanded: false),
                    "收合 \(container)pt hasAttach=\(hasAttach)")
            }
        }
    }

    @Test("展開的輸入框比 0.51.1 寬")
    func expandedIsWiderThanBaseline() {
        for container in containers {
            #expect(
                editorWidth(container: container, hasAttach: true, expanded: true)
                    > baselineEditorWidth(container: container, hasAttach: true, expanded: true),
                "展開 \(container)pt")
        }
    }

    @Test("按鈕觸控目標仍是 44pt")
    func controlsKeepTouchTarget() {
        #expect(ComposerCardLayout.control >= 44)
    }
}
