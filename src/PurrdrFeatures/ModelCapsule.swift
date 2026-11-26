import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 模型膠囊(#350、#382):輸入列展開時下方一列、附加鈕右邊。顯示目前的模型與 effort 加 `▾`(不被截斷，版面給理想寬度),
/// 高度與底色同附加鈕(DESIGN.md「選單膠囊」);點一下送 `/model`,sheet 裡用勾選列選(同「選擇控制」)。
/// 狀態(#384):切換中(膠囊內轉圈)、停用(Agent 等你回覆、工作中、唯讀、離線、Codex:仍可點開,sheet 只顯示目前模型與原因)、
/// 失敗(對話維持原模型,輸入列上方的 notice 說明)。
struct ModelCapsule: View {
    let model: ConversationModel

    static let height: Double = 34

    @State private var isPresented = false

    /// 模型名稱加 effort(「Opus 5.5 · 中」);還沒讀到時是「Model」。
    private var title: String { model.modelSummary ?? String(localized: "Model") }

    private var isDimmed: Bool { model.modelChoiceLock != nil }

    var body: some View {
        Button {
            isPresented = true
            Task { await model.beginChoosingModel() }
        } label: {
            HStack(spacing: 4) {
                if model.isSwitchingModel {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityIdentifier("composer.model.switching")
                }
                Text(verbatim: title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isDimmed ? Color.secondaryText : Color.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(height: Self.height)
        }
        .composerSecondaryButtonStyle()
        .buttonBorderShape(.capsule)
        .frame(minHeight: 44)
        .disabled(model.isSwitchingModel)
        .accessibilityLabel(Text("Model"))
        .accessibilityValue(Text(verbatim: model.modelSummary ?? ""))
        .accessibilityHint(Text("Opens the list of models."))
        .accessibilityIdentifier("composer.model")
        .sheet(isPresented: $isPresented, onDismiss: { Task { await model.finishChoosingModel() } }) {
            ModelSheet(model: model)
        }
    }
}

/// 模型選擇 sheet(#384,原型 Model):模型列(名稱、一行描述、勾選)、「投入程度」列與子頁、Ultracode 開關。
/// medium detent(可拉到 large),關閉在左上 xmark。面板讀不到、Agent 忙或不能切換時只顯示目前模型與原因。
struct ModelSheet: View {
    let model: ConversationModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ModelContentView(model: model)
                .navigationTitle("Choose Model")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { SheetCloseToolbar(identifier: "model.close") }
                .modelEffortDestination(model)
        }
        .appSheet(detents: [.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// 「投入程度」子頁的路由(列是系統 `NavigationLink`,spec #612、#627)。
struct ModelEffortRoute: Hashable {}

extension View {
    /// 「投入程度」子頁的導覽目的地:模型 sheet 與聊天面板的模型頁共用。
    /// 進入時才送 `/effort` 讀滑桿(`openEffortPage`),離開(返回、左緣滑回、關掉 sheet)時確認或取消(`closeEffortPage`)。
    func modelEffortDestination(_ model: ConversationModel) -> some View {
        navigationDestination(for: ModelEffortRoute.self) { _ in
            EffortDestination(model: model)
        }
    }
}

/// 子頁的進出對應 model 的狀態機:先顯示「讀取中」,讀到滑桿後才有層級;進入途中就返回時,讀完立刻收尾。
private struct EffortDestination: View {
    let model: ConversationModel
    @State private var isShowing = true

    var body: some View {
        EffortPage(model: model)
            .task {
                await model.openEffortPage()
                if !isShowing { await model.closeEffortPage() }
            }
            .onDisappear {
                isShowing = false
                Task { await model.closeEffortPage() }
            }
    }
}

/// 模型清單內容(#515):可單獨嵌入——不含 NavigationStack 與關閉鈕(sheet 與聊天面板共用)。
struct ModelContentView: View {
    let model: ConversationModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let panel = model.panel, !panel.options.isEmpty, model.isChoosingModel {
                Section {
                    Picker(String(localized: "Model"), selection: selection(panel)) {
                        ForEach(panel.options) { option in
                            ModelRow(option: option, entry: model.catalogEntry(for: option))
                                .tag(option.index)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .disabled(model.isOperatingPanel)
                    .accessibilityIdentifier("model.picker")
                }
                Section {
                    NavigationLink(value: ModelEffortRoute()) {
                        LabeledContent("Effort") {
                            HStack {
                                if let badge = model.metadata.effort.flatMap({ model.effortOption($0)?.badge }) {
                                    CatalogBadgeView(badge: badge)
                                }
                                Text(verbatim: model.effortDisplayName ?? "")
                            }
                        }
                    }
                    .disabled(model.isOperatingPanel)
                    .accessibilityIdentifier("model.effort")
                }
            } else if model.isChoosingModel && !model.modelPanelUnreadable {
                Section {
                    HStack {
                        ProgressView()
                        Text("Reading the model list…")
                            .foregroundStyle(.secondaryText)
                    }
                    .accessibilityIdentifier("model.loading")
                }
            } else {
                currentOnly
            }
        }
        .appSheetList()
    }

    /// 只顯示目前模型與原因(停用、Codex、面板讀不到)。
    @ViewBuilder
    private var currentOnly: some View {
        Section {
            HStack {
                Text(verbatim: model.modelSummary ?? String(localized: "Model"))
                Spacer()
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            .accessibilityIdentifier("model.current")
        } footer: {
            if let lock = model.modelChoiceLock {
                Text(lock.explanation)
                    .accessibilityIdentifier("model.lock")
            } else {
                ErrorLabel(String(localized: "Couldn’t open the model list. Try again, or check the terminal."), area: "ModelCapsule",
                           error: ErrorDescriptor(category: "ModelPanel", code: "modelListUnavailable"))
                    .font(.footnote)
                    .accessibilityIdentifier("model.failure")
            }
        }
    }

    private func selection(_ panel: SlashPanel) -> Binding<Int> {
        Binding(
            get: { panel.options.first(where: \.isCurrent)?.index ?? panel.options.first(where: \.isCursor)?.index ?? -1 },
            set: { index in
                guard let option = panel.options.first(where: { $0.index == index }) else { return }
                Task {
                    await model.chooseModel(option)
                    dismiss()
                }
            }
        )
    }
}

/// 投入程度子頁:層級勾選列(中為推薦、最高有用量提醒)與 Ultracode 開關(僅目前模型支援 xhigh 時出現)。
/// 點層級只移動面板的滑桿,按返回(或關閉 sheet)才確認。
private struct EffortPage: View {
    let model: ConversationModel

    var body: some View {
        List {
            if let slider = model.effortSlider {
                Section {
                    Picker(String(localized: "Effort"), selection: selection(slider)) {
                        ForEach(Array(slider.levels.enumerated()), id: \.offset) { index, level in
                            HStack(spacing: 8) {
                                Text(verbatim: ConversationModel.effortName(of: level) ?? level)
                                if let badge = model.effortOption(level)?.badge {
                                    CatalogBadgeView(badge: badge)
                                }
                            }
                            .tag(index)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .disabled(model.isOperatingPanel)
                    .accessibilityIdentifier("effort.picker")
                }
                if model.showsUltracode {
                    Section {
                        Toggle("Ultracode", isOn: Binding(
                            get: { model.ultracodeIsOn },
                            set: { _ in Task { await model.toggleUltracode() } }
                        ))
                        .disabled(model.isOperatingPanel)
                        .accessibilityIdentifier("effort.ultracode")
                    } footer: {
                        explanation
                    }
                } else {
                    Section {
                    } footer: {
                        explanation
                    }
                }
            } else if model.modelPanelUnreadable {
                Section {
                    ErrorLabel(String(localized: "Couldn’t open the effort settings. Go back and try again, or check the terminal."), area: "ModelCapsule",
                               error: ErrorDescriptor(category: "ModelPanel", code: "effortPanelUnreadable"))
                        .font(.footnote)
                        .accessibilityIdentifier("effort.failure")
                }
            } else {
                Section {
                    HStack {
                        ProgressView()
                        Text("Reading the effort settings…")
                            .foregroundStyle(.secondaryText)
                    }
                    .accessibilityIdentifier("effort.loading")
                }
            }
        }
        .appSheetList()
        .navigationTitle("Effort")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var explanation: some View {
        Text("Higher effort answers more thoroughly, but takes longer and uses your quota faster. Changes become the default for new sessions.")
    }

    private func selection(_ slider: SlashPanelSlider) -> Binding<Int> {
        Binding(
            get: { slider.current ?? -1 },
            set: { level in Task { await model.chooseEffortLevel(level) } }
        )
    }
}

/// 模型列:名稱、一行描述(目錄的描述,繁中依模型 id 對照內建表;對不到目錄用面板自己的描述)與目錄的模型徽章。
private struct ModelRow: View {
    let option: SlashPanelOption
    let entry: ModelCatalogEntry?

    private var detail: String? {
        entry.flatMap(ModelCatalogText.description(for:)) ?? option.detail
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: option.label)
                if let detail {
                    Text(verbatim: detail)
                        .font(.footnote)
                        .foregroundStyle(.secondaryText)
                }
            }
            if let badge = entry?.badge {
                Spacer(minLength: 8)
                CatalogBadgeView(badge: badge)
            }
        }
    }
}

/// 目錄的徽章(#385):一般徽章是次要文字色的小膠囊;警示(使用量倍率)是主要色文字配橙色三角形,不用橙色文字。
private struct CatalogBadgeView: View {
    let badge: ModelBadge

    var body: some View {
        Group {
            if badge.variant == .warning {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(verbatim: ModelCatalogText.badge(badge.message))
                        .foregroundStyle(.primary)
                }
            } else {
                Text(verbatim: ModelCatalogText.badge(badge.message))
                    .foregroundStyle(Color.secondaryText)
            }
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.fill.tertiary, in: Capsule())
    }
}

/// 目錄文字的在地化(#385):已知模型的描述依**模型 id** 取 String Catalog 的字串(英文與繁中都在 Features,不比對目錄文字);
/// 不認得的模型顯示目錄附的英文描述。徽章文字只翻已知的兩句,其他原文顯示。
enum ModelCatalogText {
    static func description(for entry: ModelCatalogEntry) -> String? {
        switch entry.id {
        case "claude-opus-5-5": String(localized: "For complex work and everyday tasks")
        case "claude-sonnet-5-5": String(localized: "Most efficient for simpler tasks")
        case "claude-fable-5-2": String(localized: "For your toughest challenges")
        case "claude-haiku-5-5": String(localized: "Fastest for quick answers")
        default: entry.description
        }
    }

    static func badge(_ message: String) -> String {
        switch message {
        case "Recommended": String(localized: "Recommended")
        case "3.5× or more usage": String(localized: "3.5× or more usage")
        case "Requires usage credits": String(localized: "Requires usage credits")
        default: message
        }
    }
}

extension ConversationModel.ModelChoiceLock {
    /// 模型選項停用時說明為什麼(說明同權限模式)。
    var explanation: LocalizedStringKey {
        switch self {
        case .readOnlyDevice: "This device is paired read-only, so it can’t change the model."
        case .offline: "Can’t reach the host, so the model can’t be changed."
        case .waitingForYou: "The agent is waiting for your reply. Answer first, then change the model."
        case .working: "The agent is working. Change the model once it’s done."
        case .agentLacksFeature: "This agent doesn’t support changing the model from Purrdr. Change it in its terminal."
        case .notVerified: "Changing this agent’s model from Purrdr isn’t verified yet. Change it in its terminal."
        case .hostCannot: "This host can’t change the model."
        }
    }
}
