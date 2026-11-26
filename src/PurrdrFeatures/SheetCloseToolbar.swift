import SwiftUI

/// modal 的關閉鈕(#415、#613):左上角 `xmark`,VoiceOver 念「Close」。
/// 全 app 的 modal 一律用它(沒有右上關閉的元件);有確認動作的 modal 另在右上放唯一的 ✓(`ModalConfirmToolbar`)。
/// `identifier` 預設 `sheet.close`,少數畫面沿用既有識別碼。`action` 預設是 `dismiss`。
struct SheetCloseToolbar: ToolbarContent {
    var identifier = "sheet.close"
    var action: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Close", systemImage: "xmark") { (action ?? { dismiss() })() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(identifier)
        }
    }
}

/// 有確認動作的 modal 右上角唯一的 ✓(#613):prominent 樣式,底色經 `prominentFill`(主機主題色優先),
/// 還不能按時停用、不填色。明確指定樣式,不依賴系統是否自動把確認角色變 prominent。
/// `title` 是 VoiceOver 念的具體動作名(信任、儲存、建立、合併),不是「確定」。
struct ModalConfirmToolbar: ToolbarContent {
    let title: LocalizedStringKey
    var identifier: String
    var isEnabled = true
    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button(action: action) {
                Label(title, systemImage: "checkmark")
            }
            .labelStyle(.iconOnly)
            .filledProminentButtonStyle()
            .disabled(!isEnabled)
            .accessibilityIdentifier(identifier)
        }
    }
}
