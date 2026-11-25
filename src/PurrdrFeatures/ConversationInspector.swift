import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 對話右側的 Inspector(#521,spec #517,原型 B):寬視窗是右側欄、窄視窗由系統變成 sheet。
///
/// 內容是「⋯」選單各 sheet 的內容元件(用量、權限模式、做完再送、待辦、背景子 Agent),不重寫行為;
/// 模型與投入程度在同一個 Inspector 裡推入一頁(`InspectorModelPage`),生命週期同模型 sheet。
/// 有沒有哪一段由聊天狀態決定,規則同「⋯」選單(`ConversationMoreMenuPlan`):沒資料的項目不列。
struct ConversationInspectorView: View {
    let model: ConversationModel
    let usageSection: UsageSectionModel?
    let display: PlanUsageModel.Display
    /// 窄視窗變成 sheet 時給關閉鈕;寬視窗的右側欄沒有(開關在對話頂列)。
    var close: (() -> Void)?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    UsageContentView(model: model, section: usageSection, display: display, scrolls: false)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .accessibilityIdentifier("inspector.usage")
                if model.showsModelCapsule {
                    Section {
                        NavigationLink(value: InspectorPage.model) {
                            LabeledContent("Model & Effort") {
                                Text(verbatim: model.modelSummary ?? "")
                                    .foregroundStyle(.secondaryText)
                            }
                        }
                        .accessibilityIdentifier("inspector.model")
                    }
                }
                PermissionModeSections(model: model)
                    .accessibilityIdentifier("inspector.permissionMode")
                SendWhenDoneSections(model: model, showsHeader: true)
                let sheet = model.statusSummary.sheet
                if sheet.progress.todoTotal > 0 {
                    Section("Todos") {
                        TodoRows(progress: sheet.progress)
                    }
                    .accessibilityIdentifier("inspector.todos")
                }
                if let pane = sheet.backgroundAgents, !pane.rows.isEmpty {
                    Section("Background Agents") {
                        BackgroundAgentRows(model: model, pane: pane)
                    }
                    .accessibilityIdentifier("inspector.backgroundAgents")
                }
            }
            .appSheetList()
            .navigationTitle("Inspector")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if let close {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark", action: close)
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("inspector.close")
                    }
                }
            }
            .navigationDestination(for: InspectorPage.self) { page in
                switch page {
                case .model: InspectorModelPage(model: model)
                }
            }
            .navigationDestination(for: DelegationRoute.self) { route in
                DelegationDestination(route: route, conversation: model)
            }
        }
        .accessibilityIdentifier("inspector")
    }
}

enum InspectorPage: Hashable {
    case model
}

/// Inspector 裡的模型與投入程度頁:進入時送 `/model` 讀面板、離開時收掉(同 `ModelSheet` 的呈現與關閉)。
private struct InspectorModelPage: View {
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

/// 把 Inspector 掛在對話上(只在有視窗導覽的 split view 對話欄)。
///
/// 對話欄夠寬(≥ `columnMinimumWidth`,橫式 iPad 或寬視窗)用系統 `.inspector` 右側欄,開關是 `window.isInspectorShown`(存本機偏好);
/// 不夠寬(直式、縮小的視窗、size class 為 compact)改成 sheet,開關是這個畫面自己的暫時狀態——偏好是「顯示」時
/// 不會在窄視窗每開一個聊天就跳出 sheet,也不會把對話擠成一條。
struct ConversationInspectorModifier: ViewModifier {
    /// 側欄加對話至少要這麼寬才放得下(對話欄本身約 420pt 以上才好讀)。
    static let columnMinimumWidth: CGFloat = 720

    let window: TopNavigationModel?
    let model: ConversationModel
    let usageSection: UsageSectionModel?
    let display: PlanUsageModel.Display
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isSheetShown = false
    @State private var availableWidth: CGFloat = 0

    private var usesColumn: Bool { horizontalSizeClass != .compact && availableWidth >= Self.columnMinimumWidth }

    private var isShown: Bool { usesColumn ? window?.isInspectorShown ?? false : isSheetShown }

    private func toggle() {
        if usesColumn { window?.toggleInspector() } else { isSheetShown.toggle() }
    }

    private var columnBinding: Binding<Bool> {
        Binding(get: { usesColumn && window?.isInspectorShown == true }, set: { window?.isInspectorShown = $0 })
    }

    private var sheetBinding: Binding<Bool> {
        Binding(get: { !usesColumn && isSheetShown }, set: { isSheetShown = $0 })
    }

    func body(content: Content) -> some View {
        if window != nil {
            content
                .inspector(isPresented: columnBinding) {
                    ConversationInspectorView(model: model, usageSection: usageSection, display: display)
                        // 右側欄是欄不是 sheet,維持不透明底色(#547);窄視窗的 sheet 版用系統玻璃(#614)。
                        .background(AppSurface.sheet.ignoresSafeArea())
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
                }
                .sheet(isPresented: sheetBinding) {
                    ConversationInspectorView(
                        model: model, usageSection: usageSection, display: display, close: { isSheetShown = false })
                    .appSheet(detents: [.medium, .large])
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button(isShown ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing", action: toggle)
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("conversation.inspectorToggle")
                    }
                }
        } else {
            content
        }
    }
}
