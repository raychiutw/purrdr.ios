import SwiftUI

extension View {
    /// push 進來的編輯頁有沒存的修改時,離開(左上系統返回鈕、左緣滑回)前先問要不要放棄(#622、spec #612 使用者故事 11)。
    func discardChangesGuard(hasChanges: Bool, title: LocalizedStringKey) -> some View {
        modifier(DiscardChangesGuard(hasChanges: hasChanges, title: title))
    }
}

/// iOS 27 有系統的離開前確認(`dismissalConfirmationDialog`),返回鈕與左緣滑回都由系統攔下並出確認。
/// iOS 26 沒有系統做法(push 的返回沒有攔截 API),只能把返回鈕換成自己放的(DESIGN.md「編輯頁離開確認」例外)。
struct DiscardChangesGuard: ViewModifier {
    let hasChanges: Bool
    let title: LocalizedStringKey
    @State private var confirming = false
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content
                .dismissalConfirmationDialog(title, shouldPresent: hasChanges) {
                    Button("Discard Changes", role: .destructive) {}
                    Button("Keep Editing", role: .cancel) {}
                }
        } else {
            content
                .navigationBarBackButtonHidden(hasChanges)
                .toolbar {
                    if hasChanges {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Back", systemImage: "chevron.backward") { confirming = true }
                                .accessibilityIdentifier("discardGuard.back")
                        }
                    }
                }
                .confirmationDialog(title, isPresented: $confirming, titleVisibility: .visible) {
                    Button("Discard Changes", role: .destructive) { dismiss() }
                    Button("Keep Editing", role: .cancel) {}
                }
        }
    }
}
