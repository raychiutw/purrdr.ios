import SwiftUI

/// sheet 的關閉鈕(#415):左上角 `xmark`,VoiceOver 念「Close」。
/// 全 app 的 sheet 一律用它,不再有右上角「Done」;有儲存或確認語意的編輯 sheet 另在右上放主要動作(見 DESIGN.md「Sheet」)。
/// `identifier` 預設 `sheet.close`,少數畫面沿用既有識別碼。`action` 預設是 `dismiss`。
struct SheetCloseToolbar: ToolbarContent {
    var identifier = "sheet.close"
    var action: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Close", systemImage: "xmark") { (action ?? { dismiss() })() }
                .accessibilityIdentifier(identifier)
        }
    }
}

/// 帳號與設定 sheet 的關閉鈕(#503、設計稿 D-5):右上角「X」玻璃圓鈕(44×44),VoiceOver 念「Close」。
/// 帳號 sheet 沒有完成鈕;其他 sheet 仍用左上角 `SheetCloseToolbar`。
struct TrailingCloseToolbar: ToolbarContent {
    var identifier = "sheet.close"
    var action: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(role: .close) { (action ?? { dismiss() })() }
                .accessibilityLabel(Text("Close"))
                .accessibilityIdentifier(identifier)
        }
    }
}
