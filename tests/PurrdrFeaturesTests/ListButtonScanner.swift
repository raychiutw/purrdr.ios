import Foundation

/// 原始碼掃描:找出 `src/PurrdrFeatures` 裡位於 List／Section(清單)內的 Button(#639)。
/// 以大括號深度追蹤區塊,祖先有 Menu／swipeActions／contextMenu／toolbar／alert／confirmationDialog 等
/// 系統自己畫的容器就不算清單列(不改)。守門測試共用,新增的動作列會被自動發現。
struct ListButton {
    let file: String
    /// 1 起算的行號。
    let line: Int
    /// Button 起頭那一行。
    let head: String
    /// Button 起頭到修飾鏈結束(含 label 閉包與後面以 `.` 開頭的修飾行)。
    let text: String

    var location: String { "\(file):\(line)" }
    var isDestructive: Bool { head.contains("role: .destructive") }
    var isCancel: Bool { head.contains("role: .cancel") }
}

enum ListButtonScanner {
    private static let listOpeners = ["List {", "List(", "Form {", "Section {", "Section("]
    private static let systemDrawn = [
        "Menu {", "Menu(", ".swipeActions", ".contextMenu", ".toolbar", "ToolbarItem", ".alert(", ".confirmationDialog(",
        ".sheet(", ".fullScreenCover(", ".popover(", ".overlay", ".safeAreaInset", ".background",
    ]

    static func sourceFiles() throws -> [(name: String, lines: [String])] {
        let folder = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "src/PurrdrFeatures")
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var result: [(String, [String])] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            result.append((url.lastPathComponent, source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)))
        }
        return result
    }

    private struct Frame {
        var opensList: Bool
        var systemDrawn: Bool
    }

    /// 清單內的 Button(包含破壞性與 cancel;呼叫端自己篩)。
    static func listButtons() throws -> [ListButton] {
        try sourceFiles().flatMap { scan(name: $0.name, lines: $0.lines) }
    }

    /// 掃單一檔案(合成原始碼的測試也用這個)。
    static func scan(name: String, lines: [String]) -> [ListButton] {
        var buttons: [ListButton] = []
        var stack: [Frame] = []
        var pendingSystem = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            if trimmed.hasPrefix("Button(") || trimmed.hasPrefix("Button {") {
                if stack.contains(where: \.opensList), !stack.contains(where: \.systemDrawn) {
                    buttons.append(ListButton(file: name, line: index + 1, head: trimmed, text: chain(lines, from: index)))
                }
            }
            let opens = line.filter { $0 == "{" }.count
            let closes = line.filter { $0 == "}" }.count
            let namesSystemContainer = systemDrawn.contains { trimmed.contains($0) }
            if opens > 0 {
                // 同一行第一個 `{` 代表該行的角色,其餘視為一般。
                // 參數寫成多行的 `.confirmationDialog(` / `.alert(` 等,內容閉包的 `{` 在後面幾行:靠 pendingSystem 接續。
                stack.append(Frame(
                    opensList: listOpeners.contains { trimmed.contains($0) },
                    systemDrawn: namesSystemContainer || (pendingSystem && opens > closes)))
                if opens > closes { pendingSystem = false }
                for _ in 1 ..< max(opens, 1) { stack.append(Frame(opensList: false, systemDrawn: false)) }
            }
            if opens == 0, namesSystemContainer, trimmed.hasSuffix("(") { pendingSystem = true }
            for _ in 0 ..< closes where !stack.isEmpty { stack.removeLast() }
        }
        return buttons
    }

    private static func braceDelta(_ line: String) -> Int {
        line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
    }

    /// 從 Button 起頭行取到它的 label／action 閉包結束,再接後面以 `.` 開頭的修飾行。
    private static func chain(_ lines: [String], from start: Int) -> String {
        var depth = 0
        var end = start
        var index = start
        var opened = false
        while index < lines.count {
            let line = lines[index]
            depth += braceDelta(line)
            if line.contains("{") { opened = true }
            end = index
            // 閉包都收完;沒有閉包的單行 Button(action: x)也在括號收完時結束。
            if opened ? depth <= 0 : (line.contains(")") && !line.hasSuffix(",")) { break }
            index += 1
        }
        var next = end + 1
        while next < lines.count {
            let trimmed = lines[next].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("."), !trimmed.hasPrefix("..") else { break }
            end = next
            var open = braceDelta(lines[next])
            while open > 0, end + 1 < lines.count {
                end += 1
                open += braceDelta(lines[end])
            }
            next = end + 1
        }
        return lines[start ... end].joined(separator: "\n")
    }
}
