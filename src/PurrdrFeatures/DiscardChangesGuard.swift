import SwiftUI

extension View {
    /// push 進來的編輯頁有沒存的修改時,離開前先問要不要放棄(#622、spec #612 使用者故事 11)。
    func discardChangesGuard(hasChanges: Bool, title: LocalizedStringKey) -> some View {
        modifier(DiscardChangesGuard(hasChanges: hasChanges, title: title))
    }
}

/// push 頁的返回沒有系統的攔截 API:iOS 27 的 `dismissalConfirmationDialog` 只管 sheet 與視窗,
/// 實測(iOS 27 模擬器)push 的返回鈕不會被它攔下。所以**有未存修改時**才把系統返回鈕換成自己放的返回鈕,
/// 點了先問;沒有修改時仍是系統返回鈕(DESIGN.md「編輯主機的導覽與離開確認」例外)。
struct DiscardChangesGuard: ViewModifier {
    let hasChanges: Bool
    let title: LocalizedStringKey
    @State private var confirming = false
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(hasChanges)
            .toolbar {
                if hasChanges {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Back", systemImage: "chevron.backward") { confirming = true }
                            .accessibilityIdentifier("discardGuard.back")
                            // 確認對話框掛在觸發的返回鈕上,錨定在鈕(#625)。
                            .confirmationDialog(title, isPresented: $confirming, titleVisibility: .visible) {
                                Button("Discard Changes", role: .destructive) { dismiss() }
                                Button("Keep Editing", role: .cancel) {}
                            }
                    }
                }
            }
    }
}
