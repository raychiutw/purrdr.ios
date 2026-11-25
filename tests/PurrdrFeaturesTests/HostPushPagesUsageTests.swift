import Foundation
import Testing

/// 編輯主機與新增主機引導是 push 頁(#622、spec #612):左上是系統返回鈕,沒有另外的 Cancel,
/// 連線方式用系統 `.inline` Picker,底部不自鋪 `.bar`。唯一自放返回鈕的地方是 iOS 26 的離開確認(`DiscardChangesGuard`)。
@Suite("主機編輯與引導 push 頁用法")
struct HostPushPagesUsageTests {
    private static let featuresFolder = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "src/PurrdrFeatures")

    private static func source(_ name: String) throws -> String {
        try String(contentsOf: featuresFolder.appending(path: name), encoding: .utf8)
    }

    @Test("編輯主機與引導沒有 Cancel 鈕、不自己隱藏返回鈕(完成頁除外)")
    func noHandMadeBackOrCancel() throws {
        for file in ["HostEditorView.swift", "AddHostGuideView.swift"] {
            let text = try Self.source(file)
            #expect(!text.contains("placement: .cancellationAction"), "\(file) 左上是系統返回鈕")
            #expect(!text.contains("guide.cancel"), "\(file) 不放 Cancel")
            #expect(!text.contains("chevron.backward"), "\(file) 不自己畫返回鈕")
        }
        let editor = try Self.source("HostEditorView.swift")
        #expect(!editor.contains("navigationBarBackButtonHidden"), "編輯主機的返回鈕由系統(或 DiscardChangesGuard)負責")
        let guide = try Self.source("AddHostGuideView.swift")
        #expect(
            guide.components(separatedBy: "navigationBarBackButtonHidden").count - 1 == 1
                && guide.contains("navigationBarBackButtonHidden(step == .finished)"),
            "引導只有完成頁(主機已存好,沒有上一步)可以隱藏返回鈕")
    }

    @Test("編輯主機有未存修改時離開先確認:用 discardChangesGuard")
    func editorGuardsUnsavedChanges() throws {
        #expect(try Self.source("HostEditorView.swift").contains(".discardChangesGuard(hasChanges: model.hasChanges"))
        let guardSource = try Self.source("DiscardChangesGuard.swift")
        #expect(guardSource.contains("navigationBarBackButtonHidden(hasChanges)"), "只有未存修改時才換掉系統返回鈕")
    }

    @Test("連線方式是系統 .inline Picker,不是自畫的勾選列")
    func connectionMethodIsInlinePicker() throws {
        let editor = try Self.source("HostEditorView.swift")
        #expect(editor.contains("Picker(\"Connection\", selection: $model.connectionMethod)"))
        #expect(editor.contains(".pickerStyle(.inline)"))
        #expect(!editor.contains("\"checkmark\""), "不自己畫勾號")
    }

    @Test("引導每一步由上一頁以 navigationDestination 推出,不自鋪 .bar")
    func guideStepsArePushed() throws {
        let guide = try Self.source("AddHostGuideView.swift")
        #expect(guide.contains(".navigationDestination(isPresented: nextPagePresented)"))
        #expect(!guide.contains(".background(.bar)"))
        #expect(guide.contains("DisclosureGroup(\"Other Ways\""), "進階登入方式用系統 DisclosureGroup")
    }
}
