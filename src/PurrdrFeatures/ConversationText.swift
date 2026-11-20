import Foundation
import PurrdrCore

extension ToolRunSummary {
    /// 收合時的一行摘要(#271,原型 purrdr-screens 定案版),例如「Edited 2 files · 3 steps」:
    /// 改了檔案時先列檔案數，再列步驟數(工具串的步驟);失敗放最後。
    func text(steps: Int) -> String {
        guard steps > 0 else { return String(localized: "Used tools") }
        var parts: [String] = []
        if editedFiles > 0 {
            parts.append(editedFiles == 1 ? String(localized: "Edited 1 file") : String(localized: "Edited \(editedFiles) files"))
        }
        parts.append(steps == 1 ? String(localized: "1 step") : String(localized: "\(steps) steps"))
        if failures > 0 {
            parts.append(failures == 1 ? String(localized: "1 failed") : String(localized: "\(failures) failed"))
        }
        return parts.joined(separator: " · ")
    }
}
