import XCTest

extension XCUIApplication {
    /// AX5 的 Spaces 列表每列有好幾個畫面高:一般的 `reveal` 拖得太快、次數也不夠。這裡慢慢拖(放開前停一下，不滑過頭)，
    /// 目標列出現就停;回傳列是否出現。
    @MainActor
    func slowlyReveal(_ row: XCUIElement, maxDrags: Int = 40) -> Bool {
        let list = collectionViews.matching(NSPredicate(format: "identifier != %@", "sidebar")).firstMatch
        guard list.waitUntilExists(timeout: 10) else { return false }
        for _ in 0..<maxDrags where !row.exists {
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                .press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        return row.waitUntilExists(timeout: 3)
    }

    /// 稽核用的啟動:關掉 Debug 建置才有的除錯層(順暢度量測文字),稽核只看使用者會看到的畫面(Release 沒有那一層)。
    @MainActor
    static func launchAuditing(flags: [String] = [], contentSize: String? = nil) -> XCUIApplication {
        launchUITesting(flags: flags + ["-uiTestingHidesDebugOverlay"], contentSize: contentSize)
    }
}

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
        // 轉場、捲動、玻璃面板淡入還在動時量對比會量到中間態：畫面停下來再稽核。
        app.waitForVisualSettle()
        try app.performAccessibilityAudit(for: types) { issue in
            let summary = AccessibilityAuditExclusions.describe(issue)
            if let reason = AccessibilityAuditExclusions.reason(for: issue, in: context) {
                print("[a11y-audit] 排除 \(screen)(\(size)):\(summary) — 理由：\(reason) — \(context.describeBars())")
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
    lazy var navigationBars: [CGRect] = app.navigationBars.allElementsBoundByIndex.map(\.frame)
        .filter { !$0.isEmpty && $0.height < window.height / 2 }

    /// 畫面底部蓋在內容上的玻璃層：輸入列(對話)、終端機按鍵列、新增主機引導的底部玻璃面板(使用者同意，2026-11-21)。
    lazy var bottomBars: [CGRect] = {
        // 聊天的搜尋欄在頂列(#499),不再是底部玻璃。
        var frames: [CGRect] = []
        // 新增主機引導的底部玻璃面板(`guide.panel`):表單內容捲到面板下時同樣是被玻璃模糊的那一塊(使用者同意列入，2026-11-21)。
        let guidePanel = app.descendants(matching: .any)["guide.panel"].firstMatch
        if guidePanel.exists, !guidePanel.frame.isEmpty {
            frames.append(CGRect(x: window.minX, y: guidePanel.frame.minY, width: window.width, height: window.maxY - guidePanel.frame.minY))
        }
        for identifier in ["composer.text", "terminal.key.esc"] {
            let element = app.descendants(matching: .any)[identifier].firstMatch
            if element.exists {
                // 輸入列／按鍵列整條：元素上緣往下到視窗底。
                let top = element.frame.minY - 12
                frames.append(CGRect(x: window.minX, y: top, width: window.width, height: window.maxY - top))
            }
        }
        // 軟體鍵盤出現時輸入列一路到視窗底約佔一半以上(iPhone 17 slash 選單：454／874pt);上限只是擋掉誤抓的整頁元素(#251)。
        return frames.filter { !$0.isEmpty && $0.height < window.height * 0.7 }
    }()

    /// slash 選單(浮在輸入列上方的 `.bar` 材質):蓋住後面的訊息，但選單自己的列不算被蓋住。
    lazy var slashMenu: CGRect? = {
        let menu = app.descendants(matching: .any)["slash.menu"].firstMatch
        return menu.exists ? menu.frame : nil
    }()

    /// slash 選單自己的列與文字：完全落在選單範圍內、卻不是這些的元素，是整個被選單蓋住的訊息(#251)。
    lazy var slashMenuContents: [CGRect] = {
        let menu = app.descendants(matching: .any)["slash.menu"].firstMatch
        return menu.exists ? menu.descendants(matching: .any).allElementsBoundByIndex.map(\.frame) : []
    }()

    lazy var window: CGRect = app.windows.firstMatch.frame

    /// 卡片裡的內層捲動區(slash 面板的選項清單，最高 240pt):裡面的列與它們的文字。捲出這一區的列被裁掉，
    /// 無障礙樹仍回報它們疊在下方動作鈕上的位置(#251:AX5 的「Fastest for short answers」量到的是「Cancel」那一塊)。
    lazy var innerScrollRegions: [(frame: CGRect, contents: [CGRect])] = ["panel.options"].compactMap { identifier in
        let region = app.descendants(matching: .any)[identifier].firstMatch
        guard region.exists else { return nil }
        return (region.frame, region.descendants(matching: .any).allElementsBoundByIndex.map(\.frame))
    }

    /// iPad 的側欄(系統 Liquid Glass 側欄，浮在內容上)。
    lazy var sidebar: CGRect? = {
        let list = app.collectionViews["sidebar"]
        return list.exists ? list.frame : nil
    }()

    /// 半透明填色的內容卡片(需要你、subagent、workflow)。
    lazy var cards: [CGRect] = ["prompt.card", "conversation.subagent", "conversation.workflow"].flatMap { identifier in
        app.descendants(matching: .any).matching(identifier: identifier).allElementsBoundByIndex.map(\.frame)
    }.filter { !$0.isEmpty }

    /// 鍵盤讓位時收成一行的註記與建議卡(#196):DESIGN.md 通用規則明列的截斷例外。建議卡收成一行時沒有「Suggestion」小標，
    /// 高度只有一行(AX5 約 60pt,完整卡片有小標、內容與下方的「填入」,遠高於 100pt)。
    lazy var compactAccessories: [CGRect] = {
        let note = app.descendants(matching: .any).matching(identifier: "youShouldKnow.compact").allElementsBoundByIndex.map(\.frame)
        let suggestion = app.descendants(matching: .any).matching(identifier: "conversation.suggestion").allElementsBoundByIndex
            .map(\.frame).filter { $0.height < 100 }
        return (note + suggestion).filter { !$0.isEmpty }
    }()

    /// 元素在導覽列裡(導覽列標題、工具列按鈕)。
    func isInNavigationBar(_ frame: CGRect) -> Bool {
        navigationBars.contains { $0.insetBy(dx: 0, dy: -4).contains(CGPoint(x: frame.midX, y: frame.midY)) }
    }

    /// 元素被系統的玻璃層或容器蓋住、裁掉：
    /// - 中線落在狀態列、導覽列與其下方 24pt 的 scroll edge effect、或底部玻璃層(搜尋欄、輸入列、按鍵列)底下;
    /// - 有一部分在 slash 選單的範圍外(在選單後面的訊息，或選單裡捲到圓角外被裁掉的列),或整個在選單範圍內、卻不是選單的列(整個被蓋住的訊息);
    /// - 是面板選項清單(內層捲動區)的列，卻在那一區外(捲出去被裁掉);
    /// - 超出視窗(例如可橫捲的 shell 輸出、捲到畫面外的列)。
    /// 只看中線：邊緣擦到玻璃的元素仍要受檢。
    func isCovered(_ frame: CGRect) -> Bool {
        guard !frame.isEmpty else { return false }
        if !window.insetBy(dx: -1, dy: -1).contains(frame) { return true }
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        let tops = navigationBars.map { CGRect(x: $0.minX, y: window.minY, width: $0.width, height: $0.maxY + 24 - window.minY) }
        if (tops + bottomBars).contains(where: { $0.contains(middle) }) { return true }
        if let slashMenu, slashMenu.intersects(frame), !slashMenu.contains(frame) || !slashMenuContents.contains(frame) { return true }
        // 內層捲動區裡、捲出那一區被裁掉的列(以 frame 對到該區的子元素)。
        if innerScrollRegions.contains(where: { region in
            region.contents.contains(frame) && !region.frame.insetBy(dx: -1, dy: -1).contains(frame)
        }) { return true }
        return false
    }

    /// 元素在底部玻璃層正上方的 scroll edge effect 漸層帶裡：中線在玻璃層上緣以上、一個玻璃層高度以內
    /// (漸層隨玻璃層高度變，AX 字級時玻璃層與漸層都變高)。
    func isInBottomEdgeBand(_ frame: CGRect) -> Bool {
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        return bottomBars.contains { bar in
            middle.y < bar.minY && middle.y >= bar.minY - bar.height
        }
    }

    /// 印出這次判斷用的玻璃區域(稽核紀錄)。
    func describeBars() -> String {
        "導覽列 \(navigationBars) 底部 \(bottomBars) slash \(String(describing: slashMenu)) 視窗 \(window)"
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
            reason: "內容元素(以中線判斷)捲到導覽列、搜尋欄、輸入列、終端機按鍵列或新增主機引導底部面板的 Liquid Glass 底下(scroll edge effect)、"
                + "在 slash 選單後面、捲出 slash 面板選項清單被裁掉，或捲出視窗外;audit 量到的是被玻璃模糊或裁掉的那一塊，捲到可見處時會另外受檢"
        ) { issue, context in
            guard let element = issue.element else { return false }
            return context.isCovered(element.frame)
        },
        Rule(
            types: [.dynamicType, .textClipped],
            reason: "預設字級的 audit 以模擬放大「預測」Dynamic Type 支援與截斷，對 List／Form 裡用 text style 的 SwiftUI Text 會誤報;"
                + "同一個測試緊接著以 AX5 實際啟動同一畫面，AX5 段落沒有回報的文字確實放大且未截斷"
        ) { issue, context in
            guard !context.isAccessibilitySize else { return false }
            guard let element = issue.element else {
                // 對應不到元素的「放大後可能被截斷」:同上，以 AX5 段落為準。
                return issue.auditType == .textClipped
            }
            return [.staticText, .button].contains(element.elementType)
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
            reason: "底部玻璃層正上方 scroll edge effect 漸層帶裡的文字(工作中的「Writing…」與經過時間等):audit 取樣到漸層，"
                + "但元素截圖實際量到的文字對背景 ≥ 4.5:1(截圖量測見 `measuredTextContrast`,量不到或不足一律算失敗)"
        ) { issue, context in
            guard let element = issue.element, element.elementType == .staticText,
                  context.isInBottomEdgeBand(element.frame) else { return false }
            return (measuredTextContrast(element) ?? 0) >= 4.5
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
            types: .dynamicType,
            reason: "頂列搜尋欄(聊天 `agentList.search`、檔案 `files.search`)的文字上限 xxxLarge(欄高本來就有 1.45 倍上限，避免放大鏡圖示比膠囊大):"
                + "DESIGN.md「文字一律用 text style」明列的封頂例外;audit 因此回報「部分不支援」。更大的字級靠 Large Content Viewer"
        ) { issue, _ in
            guard let element = issue.element, element.elementType == .textField else { return false }
            return ["agentList.search", "files.search"].contains(element.identifier)
        },
        Rule(
            types: .textClipped,
            reason: "TextField 的 placeholder 由系統單行繪製;輸入的文字在欄位內可橫捲，不會遺失(AX5 截圖確認欄位標籤完整換行)"
        ) { issue, _ in
            issue.element?.elementType == .textField
        },
        Rule(
            types: .textClipped,
            reason: "截圖確認完整顯示(Label 的圖示 + 文字，預設字級與 AX5 都看過);audit 以單行寬度判定的誤報"
        ) { issue, _ in
            guard let label = issue.element?.label else { return false }
            return ["Choose Folder on Host", "1 note for you", "Go to Chat"].contains(label)
        },
        Rule(
            types: .contrast,
            reason: "停用中的控制項(例如必填欄位沒填時的「Test Connection」):系統的停用樣式刻意淡化，WCAG 1.4.3 也把停用元件列為例外"
        ) { issue, _ in
            guard let element = issue.element else { return false }
            return !element.isEnabled
        },
        Rule(
            types: .contrast,
            reason: "需要你卡片、subagent／workflow 卡片裡的主要色文字(選項編號、卡片標題):截圖確認是黑字配淺灰填色(約 15:1 以上)。"
                + "這些卡片的底是半透明填色、旁邊有轉動的進度圖示，audit 的取樣在幾輪之間時過時不過(同一份程式碼前三輪通過)"
        ) { issue, context in
            guard let element = issue.element, element.elementType == .staticText else { return false }
            return context.cards.contains { $0.contains(element.frame) }
        },
        Rule(
            types: [.dynamicType, .textClipped],
            reason: "對應不到元素、說明是一般的「this element」而不是 SwiftUI 節點:UIKit 繪製的系統元件(iPad split view 的側欄切換鈕、"
                + "視窗控制等)。app 的文字都是 SwiftUI,會以「SwiftUI.AccessibilityNode」回報"
        ) { issue, _ in
            issue.element == nil && !issue.detailedDescription.contains("SwiftUI")
        },
        Rule(
            types: .contrast,
            reason: "iPad 側欄的文字(主機、workspace、標題):系統 Liquid Glass 側欄浮在內容上，audit 透過玻璃取樣，同一份程式碼"
                + "五輪裡三輪通過、兩輪失敗(.tdd-logs/35-ipad-4.log、35-ipad-final.log);截圖確認是系統主要色／次要色文字配淺色玻璃，"
                + "文字顏色全是系統語意色"
        ) { issue, context in
            guard let element = issue.element, element.elementType == .staticText, let sidebar = context.sidebar else { return false }
            return sidebar.contains(CGPoint(x: element.frame.midX, y: element.frame.midY))
        },
        Rule(
            types: .textClipped,
            reason: "鍵盤讓位時收成一行的 You should know 註記與建議卡(#196):DESIGN.md 通用規則明列的截斷例外，點了展開或填入，"
                + "完整內容在 VoiceOver label。#249 截圖(0.45.0 Mac mini,testShellCommand AX5)確認被回報的是一行建議卡的「Run the…」;"
                + "對應不到元素時只在畫面上有一行的註記或建議卡、且是 AX 字級時才算"
        ) { issue, context in
            guard !context.compactAccessories.isEmpty else { return false }
            guard let element = issue.element else {
                return context.isAccessibilitySize && issue.detailedDescription.contains("SwiftUI.AccessibilityNode")
            }
            let middle = CGPoint(x: element.frame.midX, y: element.frame.midY)
            return context.compactAccessories.contains { $0.contains(middle) }
        },
        Rule(
            types: [.dynamicType, .textClipped],
            reason: "AX 字級時 slash 選單開著、對應不到元素的 SwiftUI 節點:選單內捲到可見範圍外的列(audit 時有時無，master 上 10 輪約一半回報)。"
                + "#249/#251 截圖(0.45.0 Mac mini,testSlashMenuAndPanels AX5)確認畫面上看得到的列都隨字級放大、未截斷;"
                + "改成 LazyVStack 讓畫面外的列不進無障礙樹會使選單(fixedSize)排不出列，不可行。使用者同意此排除(2026-11-20)"
        ) { issue, context in
            context.isAccessibilitySize && context.slashMenu != nil && issue.element == nil
                && issue.detailedDescription.contains("SwiftUI.AccessibilityNode")
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

/// 元素截圖實際畫出來的文字對比：離背景最遠的像素(文字)對截圖四邊裡亮度最接近它的像素(最不利的背景)。
@MainActor
func measuredTextContrast(_ element: XCUIElement) -> Double? {
    guard let image = element.screenshot().image.cgImage else { return nil }
    let width = image.width, height = image.height
    guard width > 2, height > 2 else { return nil }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let bitmap = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { return nil }
    func luminance(_ x: Int, _ y: Int) -> Double {
        let offset = (y * width + x) * 4
        let channels = (0..<3).map { index -> Double in
            let value = Double(pixels[offset + index]) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }
    var border: [Double] = []
    for x in 0..<width {
        border.append(luminance(x, 0))
        border.append(luminance(x, height - 1))
    }
    for y in 0..<height {
        border.append(luminance(0, y))
        border.append(luminance(width - 1, y))
    }
    let background = border.sorted()[border.count / 2]
    var text = background
    for y in 0..<height {
        for x in 0..<width {
            let value = luminance(x, y)
            if abs(value - background) > abs(text - background) { text = value }
        }
    }
    guard let nearest = border.min(by: { abs($0 - text) < abs($1 - text) }) else { return nil }
    let lighter = max(text, nearest), darker = min(text, nearest)
    return (lighter + 0.05) / (darker + 0.05)
}
