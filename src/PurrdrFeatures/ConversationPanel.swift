import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 聊天頂列用量環開的面板(#617,spec #612;合併原本的用量 sheet 與 iPad 右側 Inspector):
/// iPad／寬視窗是錨在用量環下方的 popover(系統寬度),iPhone(compact)是 sheet(medium／large、左上 X)。
///
/// 內容是「⋯」選單各 sheet 的內容元件(用量、權限模式、做完再送、待辦、背景子 Agent),不重寫行為;
/// 模型與投入程度在同一個面板裡推入一頁(`PanelModelPage`),生命週期同模型 sheet。
/// 有沒有哪一段由聊天狀態決定,規則同「⋯」選單(`ConversationMoreMenuPlan`):沒資料的項目不列。
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
                if model.showsModelCapsule {
                    Section {
                        NavigationLink(value: PanelPage.model) {
                            LabeledContent("Model & Effort") {
                                Text(verbatim: model.modelSummary ?? "")
                                    .foregroundStyle(.secondaryText)
                            }
                        }
                        .accessibilityIdentifier("panel.model")
                    }
                }
                PermissionModeSections(model: model)
                    .accessibilityIdentifier("panel.permissionMode")
                SendWhenDoneSections(model: model, showsHeader: true)
                let sheet = model.statusSummary.sheet
                if sheet.progress.todoTotal > 0 {
                    Section("Todos") {
                        TodoRows(progress: sheet.progress)
                    }
                    .accessibilityIdentifier("panel.todos")
                }
                if let pane = sheet.backgroundAgents, !pane.rows.isEmpty {
                    Section("Background Agents") {
                        BackgroundAgentRows(model: model, pane: pane)
                    }
                    .accessibilityIdentifier("panel.backgroundAgents")
                }
            }
            .appSheetList()
            .navigationTitle("Usage & Details")
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
            .navigationDestination(for: PanelPage.self) { page in
                switch page {
                case .model: PanelModelPage(model: model)
                }
            }
            .navigationDestination(for: DelegationRoute.self) { route in
                DelegationDestination(route: route, conversation: model)
            }
        }
        .accessibilityIdentifier("conversation.panel")
    }
}

enum PanelPage: Hashable {
    case model
}

/// 面板裡的模型與投入程度頁:進入時送 `/model` 讀面板、離開時收掉(同 `ModelSheet` 的呈現與關閉)。
private struct PanelModelPage: View {
    let model: ConversationModel

    var body: some View {
        ModelContentView(model: model)
            .navigationTitle("Choose Model")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .modelEffortDestination(model)
            .task { await model.beginChoosingModel() }
            .onDisappear { Task { await model.finishChoosingModel() } }
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
