import XCTest

/// 無障礙稽核的共用部分(#35):跑 `performAccessibilityAudit`,把每一筆問題印出來，套用排除清單。
extension XCTestCase {
    /// 對目前畫面跑 accessibility audit。排除清單以外的問題一律記成測試失敗(`performAccessibilityAudit` 自己記)。
    @MainActor
    func audit(
        _ app: XCUIApplication, _ screen: String, contentSize: String? = nil,
        types: XCUIAccessibilityAuditType = .all
    ) throws {
        let size = contentSize == nil ? "預設字級" : "AX5"
        let context = AccessibilityAuditContext(app: app, screen: screen, isAccessibilitySize: contentSize != nil)
        try app.performAccessibilityAudit(for: types) { issue in
            let summary = AccessibilityAuditExclusions.describe(issue)
            if let reason = AccessibilityAuditExclusions.reason(for: issue, in: context) {
                print("[a11y-audit] 排除 \(screen)(\(size)):\(summary) — 理由：\(reason)")
                return true
            }
            print("[a11y-audit] 問題 \(screen)(\(size)):\(summary)")
            return false
        }
    }
}

/// 稽核當下的畫面資訊：哪些區域被系統的玻璃列蓋住。
@MainActor
final class AccessibilityAuditContext {
    let app: XCUIApplication
    let screen: String
    let isAccessibilitySize: Bool

    init(app: XCUIApplication, screen: String, isAccessibilitySize: Bool) {
        self.app = app
        self.screen = screen
        self.isAccessibilitySize = isAccessibilitySize
    }

    /// 導覽列(含 iPad 各欄的導覽列)。
    lazy var navigationBars: [CGRect] = app.navigationBars.allElementsBoundByIndex.map(\.frame).filter { !$0.isEmpty }

    /// 畫面底部蓋在內容上的玻璃層：搜尋欄(Agent 列表)、輸入列(對話)、工具列、終端機按鍵列。
    lazy var bottomBars: [CGRect] = {
        var frames = app.searchFields.allElementsBoundByIndex.map(\.frame)
        frames += app.toolbars.allElementsBoundByIndex.map(\.frame)
        // slash 選單浮在輸入列上方(.bar 材質),也蓋住後面的訊息。
        let menu = app.descendants(matching: .any)["slash.menu"].firstMatch
        if menu.exists { frames.append(menu.frame) }
        for identifier in ["composer.text", "terminal.key.esc"] {
            let element = app.descendants(matching: .any)[identifier].firstMatch
            if element.exists {
                // 輸入列／按鍵列整條：元素上緣往下到視窗底。
                let top = element.frame.minY - 12
                frames.append(CGRect(x: window.minX, y: top, width: window.width, height: window.maxY - top))
            }
        }
        return frames.filter { !$0.isEmpty }
    }()

    lazy var window: CGRect = app.windows.firstMatch.frame

    /// 元素在導覽列裡(導覽列標題、工具列按鈕)。
    func isInNavigationBar(_ frame: CGRect) -> Bool {
        navigationBars.contains { $0.insetBy(dx: 0, dy: -4).contains(CGPoint(x: frame.midX, y: frame.midY)) }
    }

    /// 元素有一部分被導覽列或底部玻璃層蓋住，或捲到視窗外。
    func isPartlyCovered(_ frame: CGRect) -> Bool {
        guard !frame.isEmpty else { return false }
        if !window.contains(frame) { return true }
        return (navigationBars + bottomBars).contains { $0.intersects(frame) }
    }
}

/// 確定是系統元件造成或屬於誤報的 audit 問題。每一筆都寫明理由;不在這裡的問題都要修。
@MainActor
enum AccessibilityAuditExclusions {
    struct Rule {
        let types: XCUIAccessibilityAuditType
        let reason: String
        let matches: (XCUIAccessibilityAuditIssue, AccessibilityAuditContext) -> Bool
    }

    static let rules: [Rule] = [
        Rule(
            types: [.contrast, .dynamicType],
            reason: "系統導覽列／工具列的 Liquid Glass 按鈕(Done、Cancel、Save、Start 等):顏色與字級由系統繪製，"
                + "AX 字級時系統固定工具列字級、改用 Large Content Viewer(長按放大),app 無法調整"
        ) { issue, context in
            guard let element = issue.element else { return false }
            return element.elementType == .button && context.isInNavigationBar(element.frame)
        },
        Rule(
            types: [.textClipped, .dynamicType],
            reason: "導覽列標題(聊天名稱等使用者資料):導覽列高度固定，長標題由系統截斷並固定字級;"
                + "完整標題在 VoiceOver label、列表與 Large Content Viewer 都讀得到"
        ) { issue, context in
            guard let element = issue.element else { return false }
            return element.elementType == .staticText && context.isInNavigationBar(element.frame)
        },
        Rule(
            types: [.contrast, .textClipped, .hitRegion],
            reason: "內容元素捲到導覽列底下，或有一部分在搜尋欄、輸入列或按鍵列的 Liquid Glass 底下(scroll edge effect),或捲出視窗外;"
                + "audit 量到的是被玻璃模糊或裁掉的那一塊，捲到可見處時不是問題"
        ) { issue, context in
            guard let element = issue.element else { return false }
            return context.isPartlyCovered(element.frame)
        },
        Rule(
            types: [.dynamicType, .textClipped],
            reason: "預設字級的 audit 以模擬放大判斷，對 List／Form 裡用 text style 的 SwiftUI Text 會誤報「部分不支援」;"
                + "同一個測試緊接著以 AX5 實際啟動同一畫面，AX5 段落沒有回報的文字確實放大且未截斷"
        ) { issue, context in
            guard !context.isAccessibilitySize else { return false }
            guard let element = issue.element else {
                // 對應不到元素的「放大後可能被截斷」:同上，以 AX5 段落為準。
                return issue.auditType == .textClipped
            }
            return issue.auditType == .dynamicType && [.staticText, .button].contains(element.elementType)
        },
        Rule(
            types: .dynamicType,
            reason: "AX5 段落裡已實際放大的文字(一行高度 ≥ 50pt,預設字級約 20pt):audit 對 Button 內合併成一個元素的 SwiftUI Text"
                + "回報「部分不支援」,但畫面上確實隨字級放大"
        ) { issue, context in
            guard context.isAccessibilitySize, let element = issue.element, element.elementType == .staticText else { return false }
            return element.frame.height >= 50
        },
        Rule(
            types: .contrast,
            reason: "對應不到 XCUIElement 的 SwiftUI 節點(detailedDescription 是「SwiftUI.AccessibilityNode」):已對 VoiceOver 隱藏的裝飾"
                + "(Spaces 卡片下列的軌道線、狀態點、種類圖示等)。承載意義的狀態都另有文字;只在有這類裝飾的畫面出現(Agents 檢視、"
                + "工作中的 Codex 對話沒有)"
        ) { issue, _ in
            issue.element == nil && issue.detailedDescription.contains("SwiftUI.AccessibilityNode")
        },
        Rule(
            types: [.dynamicType, .textClipped, .contrast],
            reason: "版面圖是依 Pane 實際比例畫的示意圖，方塊大小固定，文字放大會被方塊裁掉;每個方塊的 VoiceOver label 有完整名稱，"
                + "同一批 Agent 與終端機在 Spaces 卡片下也以完整文字列出。版面圖 sheet 在 medium 高度是系統的 Liquid Glass 背景"
        ) { issue, context in
            guard context.screen.contains("版面圖") else { return false }
            guard let element = issue.element else { return false }
            return element.elementType == .staticText
        },
        Rule(
            types: .contrast,
            reason: "「Contrast nearly passed」是系統語意色 secondaryLabel(.secondary)與 tint 文字按鈕：DESIGN.md 規定用系統外觀，"
                + "這些顏色在「增加對比」開啟時由系統加深;Apple 自己的 List 副標也是同一色"
        ) { issue, _ in
            issue.compactDescription.localizedCaseInsensitiveContains("nearly passed")
        },
        Rule(
            types: .textClipped,
            reason: "TextField 的 placeholder 由系統單行繪製;輸入的文字在欄位內可橫捲，不會遺失(AX5 截圖確認欄位標籤完整換行)"
        ) { issue, _ in
            issue.element?.elementType == .textField
        },
        Rule(
            types: .textClipped,
            reason: "截圖確認完整顯示(Label 的圖示 + 換行文字);audit 以單行寬度判定的誤報"
        ) { issue, _ in
            guard let label = issue.element?.label else { return false }
            return ["Choose Folder on Host", "1 note for you"].contains(label)
        },
        Rule(
            types: .sufficientElementDescription,
            reason: "markdown 表格的數字格(例如「12.50」):數值本身就是內容"
        ) { issue, _ in
            guard let label = issue.element?.label else { return false }
            return Double(label) != nil
        },
    ]

    static func reason(for issue: XCUIAccessibilityAuditIssue, in context: AccessibilityAuditContext) -> String? {
        rules.first { rule in rule.types.contains(issue.auditType) && rule.matches(issue, context) }?.reason
    }

    static func describe(_ issue: XCUIAccessibilityAuditIssue) -> String {
        let element = issue.element.map { "\($0.elementType.rawValue) id=\($0.identifier) label=\($0.label) frame=\($0.frame)" } ?? "(無元素)"
        return "[\(name(of: issue.auditType))] \(issue.compactDescription) — \(element) — \(issue.detailedDescription)"
    }

    static func name(of type: XCUIAccessibilityAuditType) -> String {
        switch type {
        case .contrast: "contrast"
        case .elementDetection: "elementDetection"
        case .hitRegion: "hitRegion"
        case .sufficientElementDescription: "sufficientElementDescription"
        case .dynamicType: "dynamicType"
        case .textClipped: "textClipped"
        case .trait: "trait"
        default: "other(\(type.rawValue))"
        }
    }
}
