import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 聊天頂列用量環開的面板(#617,spec #612;合併原本的用量 sheet 與 iPad 右側 Inspector):
/// iPad／寬視窗是錨在用量環下方的 popover(系統寬度),iPhone(compact)是 sheet(medium／large、左上 X)。
///
/// 內容只有方案用量與這個 session 的 Context(#712);模型與思考深度、權限模式、做完再送、待辦、背景子 Agent
/// 只從「⋯」選單進入,不在面板重複。
struct ConversationPanelView: View {
    let model: ConversationModel
    let usageSection: UsageSectionModel?
    let display: PlanUsageModel.Display
    /// 重新整理方案用量中。
    @State private var isRefreshing = false
    /// compact(iPhone、窄視窗)是 sheet,左上放 X;popover 點外面就收,不放。
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        NavigationStack {
            List {
                UsageContentView(model: model, section: usageSection, display: display)
            }
            .appSheetList()
            .navigationTitle("Usage & Context")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if horizontalSizeClass == .compact {
                    SheetCloseToolbar(identifier: "panel.close")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { refresh() }
                        .disabled(isRefreshing || usageSection == nil)
                        .accessibilityIdentifier("panel.refresh")
                }
            }
        }
        .accessibilityIdentifier("conversation.panel")
    }
}

extension ConversationPanelView {
    fileprivate func refresh() {
        guard let usageSection else { return }
        isRefreshing = true
        Task {
            await usageSection.refresh()
            isRefreshing = false
        }
    }
}

extension View {
    /// regular(iPad／寬視窗):把面板掛在用量環按鈕上,以 popover(系統寬度)從按鈕展開(#617)。
    /// compact 改走 `conversationPanelSheet`(掛在聊天畫面上),兩者由畫面以 size class 決定哪一個開。
    func conversationPanelPopover(
        isPresented: Binding<Bool>, model: ConversationModel, usageSection: UsageSectionModel?, display: PlanUsageModel.Display
    ) -> some View {
        popover(isPresented: isPresented) {
            ConversationPanelView(model: model, usageSection: usageSection, display: display)
                // popover 內容是 List,沒有固有尺寸:`presentationSizing(.form)` 單獨用時 iPad 實測 popover 縮成 68×68
                // (內容全被擠掉,g1 傾印)。明確給寬度與理想高度,內容多時 List 自己捲動。
                .frame(minWidth: 360, idealWidth: 400, maxWidth: 440, minHeight: 400, idealHeight: 600)
                .presentationSizing(.form)
        }
    }

    /// compact(iPhone、窄視窗、分割視窗):面板是 sheet(medium／large、左上 X)。
    func conversationPanelSheet(
        isPresented: Binding<Bool>, model: ConversationModel, usageSection: UsageSectionModel?, display: PlanUsageModel.Display
    ) -> some View {
        sheet(isPresented: isPresented) {
            ConversationPanelView(model: model, usageSection: usageSection, display: display)
                .appSheet(detents: [.medium, .large])
        }
    }
}
