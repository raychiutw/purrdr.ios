import Foundation
import Testing

/// 清單裡的動作列顏色規則(#638、#639,spec #634)。原始碼守門,prior art:`ProminentFillUsageTests`。
/// 一般動作列:SwiftUI 的 List 會把 Button 自動染成主色,要明確 `.listAction()`(文字主要色、圖示次要色)。
/// 破壞性動作列:文字與圖示同一種紅,一律 `.destructiveListAction()`(`destructiveText`)。
/// 掃描器 `ListButtonScanner` 直接找 List／Section 內的 Button,新增的動作列會被自動發現,不用手動盤點。
@Suite("清單動作列顏色用法")
struct ListActionColorUsageTests {
    /// 已自己指定樣式的按鈕(主要動作、純圖示、自訂樣式)不吃 List 的 tint,不需要 `.listAction()`。
    /// 其餘例外要在按鈕修飾鏈上寫 `// listAction:exempt <原因>`。
    static func isStyled(_ button: ListButton) -> Bool {
        ["listAction()", ".buttonStyle(", "filledProminentButtonStyle()", "listAction:exempt"].contains { button.text.contains($0) }
    }

    static let redLiterals = [".foregroundStyle(.red)", "Color.red", ".tint(.red)", "foregroundColor(.red)"]

    // MARK: - 一般動作列

    @Test("清單內的一般動作 Button 都套 listAction(自動掃描)")
    func actionRowsUseListAction() throws {
        let buttons = try ListButtonScanner.listButtons()
        #expect(buttons.count > 20, "掃描器找不到清單內的 Button(掃描規則壞了?)")
        let violations = buttons.filter { !$0.isDestructive && !$0.isCancel && !Self.isStyled($0) }.map(\.location)
        #expect(violations.isEmpty, "清單動作列要加 .listAction()(或指定樣式、或寫 // listAction:exempt 原因):\n\(violations.joined(separator: "\n"))")
    }

    @Test("帳號與設定頁的一般 Button 都套 listAction")
    func settingsButtonsUseListAction() throws {
        let settings = try #require(try ListButtonScanner.sourceFiles().first { $0.name == "SettingsView.swift" })
        var violations: [String] = []
        for (index, line) in settings.lines.enumerated() where line.contains("Button(") && !line.contains("role:") {
            let window = settings.lines[index ... min(settings.lines.count - 1, index + 12)]
            if !window.contains(where: { $0.contains(".listAction()") }) {
                violations.append("SettingsView.swift:\(index + 1)")
            }
        }
        #expect(violations.isEmpty, "設定頁的動作 Button 要加 .listAction():\n\(violations.joined(separator: "\n"))")
    }

    // MARK: - 破壞性動作列(#639)

    @Test("清單內的破壞性 Button 用 destructiveListAction:文字與圖示同為 destructiveText,不套 listAction、不寫死紅色")
    func destructiveRowsUseDestructiveListAction() throws {
        let destructive = try ListButtonScanner.listButtons().filter(\.isDestructive)
        #expect(destructive.count >= 5, "掃描器找不到清單內的破壞性 Button")
        var violations: [String] = []
        for button in destructive {
            if !button.text.contains(".destructiveListAction()") {
                violations.append("\(button.location) 缺 .destructiveListAction()")
            }
            if button.text.contains(".listAction()") {
                violations.append("\(button.location) 破壞性按鈕不可套 .listAction()(文字與圖示會不同色)")
            }
            if let literal = Self.redLiterals.first(where: { button.text.contains($0) }) {
                violations.append("\(button.location) 不要寫死 \(literal),紅色一律 destructiveText")
            }
        }
        #expect(violations.isEmpty, "\n\(violations.joined(separator: "\n"))")
    }

    @Test("destructiveListAction 的實作:文字與圖示都是 destructiveText")
    func destructiveStyleColorsTitleAndIcon() throws {
        let file = try #require(try ListButtonScanner.sourceFiles().first { $0.name == "ListActionStyle.swift" })
        let source = file.lines.joined(separator: "\n")
        let style = try #require(source.range(of: "struct DestructiveListActionLabelStyle"))
        let body = String(source[style.lowerBound...])
        #expect(body.contains("configuration.title.foregroundStyle(Color.destructiveText)"))
        #expect(body.contains("configuration.icon.foregroundStyle(Color.destructiveText)"))
    }

    // MARK: - 掃描器本身(mutation:規則被破壞時守門要轉紅)

    private static func scan(_ source: String) -> [ListButton] {
        ListButtonScanner.scan(name: "Synthetic.swift", lines: source.components(separatedBy: "\n"))
    }

    @Test("掃描器:清單內沒套 listAction 的 Button 會被認為違規,套了就過")
    func scannerFlagsUnstyledListButton() {
        let bad = Self.scan("""
        List {
            Section {
                Button("Support") { open() }
                    .accessibilityIdentifier("x")
            }
        }
        """)
        #expect(bad.count == 1)
        #expect(bad.allSatisfy { !Self.isStyled($0) })
        let good = Self.scan("""
        List {
            Section {
                Button("Support") { open() }
                    .listAction()
            }
        }
        """)
        #expect(good.allSatisfy(Self.isStyled))
    }

    @Test("掃描器:選單、swipe、對話框裡的 Button 由系統畫,不算清單列")
    func scannerSkipsSystemDrawnContainers() {
        let buttons = Self.scan("""
        List {
            Section {
                Menu {
                    Button("A") { a() }
                }
                Row()
                    .swipeActions {
                        Button("B") { b() }
                    }
                    .contextMenu {
                        Button("C", role: .destructive) { c() }
                    }
            }
        }
        .alert("T", isPresented: $p) {
            Button("D", role: .destructive) { d() }
        }
        Button("Outside") { e() }
        """)
        #expect(buttons.isEmpty)
    }

    @Test("掃描器:破壞性按鈕缺 destructiveListAction、套 listAction、寫死紅色都辨識得出來")
    func scannerDetectsDestructiveMistakes() {
        let buttons = Self.scan("""
        Form {
            Section {
                Button("Remove", systemImage: "trash", role: .destructive) { go() }
                    .listAction()
                Button("Delete", role: .destructive) { go() }
                    .foregroundStyle(.red)
                Button("Clear", role: .destructive) { go() }
                    .destructiveListAction()
            }
        }
        """)
        #expect(buttons.count == 3)
        #expect(buttons.map { $0.text.contains(".destructiveListAction()") } == [false, false, true])
        #expect(buttons[0].text.contains(".listAction()"))
        #expect(Self.redLiterals.contains { buttons[1].text.contains($0) })
    }
}
