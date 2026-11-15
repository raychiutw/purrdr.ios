import Foundation
import PurrdrCore

extension ToolRunSummary {
    /// 收合時的一行摘要(行為規格 F5.8),例如「Ran 3 commands · Edited 2 files」。
    /// 英文是開發語言;繁中翻譯在 String Catalog 那張票(#30)以複數規則處理。
    var text: String {
        var parts: [String] = []
        func add(_ count: Int, _ singular: String, _ plural: String) {
            guard count > 0 else { return }
            parts.append(count == 1 ? singular : plural.replacingOccurrences(of: "%d", with: String(count)))
        }
        add(thoughts, String(localized: "Thought 1 time"), String(localized: "Thought %d times"))
        add(commands, String(localized: "Ran 1 command"), String(localized: "Ran %d commands"))
        add(editedFiles, String(localized: "Edited 1 file"), String(localized: "Edited %d files"))
        add(readFiles, String(localized: "Read 1 file"), String(localized: "Read %d files"))
        add(searches, String(localized: "Searched 1 time"), String(localized: "Searched %d times"))
        add(fetches, String(localized: "Fetched 1 page"), String(localized: "Fetched %d pages"))
        if updatedTodos { parts.append(String(localized: "Updated todos")) }
        add(questions, String(localized: "Asked 1 question"), String(localized: "Asked %d questions"))
        add(otherTools, String(localized: "Called 1 tool"), String(localized: "Called %d tools"))
        add(failures, String(localized: "1 failed"), String(localized: "%d failed"))
        return parts.isEmpty ? String(localized: "Used tools") : parts.joined(separator: " · ")
    }
}
