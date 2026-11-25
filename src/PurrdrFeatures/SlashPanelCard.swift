import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// slash 指令開出的 Claude 面板(`/model`、`/effort`…)的內容(#45、行為規格 F9.4;#624 版面 C「輸入框變成面板」)。
///
/// 全部用系統控制項:選項與 effort 層級是 系統 inline Picker 的勾選列,← / → 調整是 `Stepper`,其他動作是清單裡的按鈕。
/// - 點選項只移動游標(送方向鍵),由面板的 ✓ 確定;**永不送數字**(數字在模型選擇器會直接存成預設)。
/// - 目前使用中以「Current」文字標示(不只靠顏色),游標所在列由 Picker 打勾。
/// - ✓ = 面板提示行的 Enter;左 X = Esc(取消)。其餘動作(例如 `s` 只用於此 session)是清單裡的按鈕,文字取自提示行原文。
/// iPhone(窄視窗)面板取代輸入框、佔住鍵盤位置(`SlashPanelBar`);iPad 寬視窗仍是 sheet(`slashPanelSheet`),內容共用這個 view。
struct SlashPanelContent: View {
    let model: ConversationModel
    let panel: SlashPanel

    var body: some View {
        List {
            if !panel.notes.isEmpty {
                Section {
                    Text(verbatim: panel.notes.joined(separator: "\n"))
                        .font(.footnote)
                        .foregroundStyle(.secondaryText)
                        .accessibilityIdentifier("panel.notes")
                }
            }
            if !panel.options.isEmpty {
                Section { options }
            }
            if let slider = panel.slider {
                Section { levels(slider) }
            }
            if let adjustment = panel.adjustment, !adjustment.isEmpty, panel.slider == nil {
                Section { adjuster(adjustment) }
            }
            if !extraActions.isEmpty {
                Section {
                    ForEach(extraActions, id: \.self) { action in
                        Button(Self.title(of: action)) { operate(.action(action)) }
                            .listAction()
                            .accessibilityIdentifier("panel.action.\(action.key)")
                    }
                }
            }
        }
        .appSheetList()
        .disabled(model.isOperatingPanel)
        .accessibilityIdentifier("panel.card")
    }

    /// ✓ 與 X 以外的動作(例如 `s`)。
    private var extraActions: [SlashPanelAction] {
        panel.actions.filter { !$0.isCancel && $0.key != "enter" }
    }

    // MARK: - 選項

    private var options: some View {
        Picker(String(localized: "Options"), selection: Binding(
            get: { panel.options.first(where: \.isCursor)?.index ?? -1 },
            set: { index in
                guard let option = panel.options.first(where: { $0.index == index }) else { return }
                operate(.select(option))
            }
        )) {
            ForEach(panel.options) { option in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: option.label)
                        if let detail = option.detail {
                            Text(verbatim: detail)
                                .font(.footnote)
                                .foregroundStyle(.secondaryText)
                        }
                    }
                    Spacer(minLength: 8)
                    if option.isCurrent {
                        Text("Current")
                            .font(.footnote)
                            .foregroundStyle(.secondaryText)
                    }
                }
                .tag(option.index)
                .accessibilityElement(children: .combine)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        .disabled(!panel.options.contains(where: \.isCursor))
        .accessibilityIdentifier("panel.options")
    }

    // MARK: - effort

    /// 層級攤開成直排的勾選列(#313);目前的層級打勾。
    private func levels(_ slider: SlashPanelSlider) -> some View {
        Picker(String(localized: "Level"), selection: Binding(
            get: { slider.current ?? -1 },
            set: { operate(.level($0)) }
        )) {
            ForEach(Array(slider.levels.enumerated()), id: \.offset) { index, level in
                Text(verbatim: level).tag(index)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        .disabled(slider.current == nil)
        .accessibilityIdentifier("panel.levels")
    }

    /// ← / → 調整:只拿得到 agent 的一行文字,不知道有哪些值,所以用 Stepper 送方向鍵。
    private func adjuster(_ text: String) -> some View {
        Stepper {
            Text(verbatim: text)
        } onIncrement: {
            operate(.adjust(.right))
        } onDecrement: {
            operate(.adjust(.left))
        }
        .accessibilityIdentifier("panel.adjustment")
    }

    // MARK: - 動作

    /// 提示行的原文(首字大寫);面板沒有提示行時依按鍵給標籤。
    static func title(of action: SlashPanelAction) -> String {
        if let label = action.label, let first = label.first {
            return first.uppercased() + label.dropFirst()
        }
        switch action.key {
        case "esc": return String(localized: "Cancel")
        default: return String(localized: "Confirm")
        }
    }

    private func operate(_ input: SlashPanel.Input) {
        Task { await model.operatePanel(input) }
    }
}

/// slash 面板在哪裡呈現(#624):窄視窗(iPhone)取代輸入框,寬視窗(iPad)是 sheet;模型膠囊自己的 sheet 開著時由它處理,這裡不呈現。
package enum SlashPanelPresentation: Equatable {
    case none, inline, sheet

    package static func resolve(hasPanel: Bool, isChoosingModel: Bool, isRegularWidth: Bool) -> SlashPanelPresentation {
        guard hasPanel, !isChoosingModel else { return .none }
        return isRegularWidth ? .sheet : .inline
    }
}

/// 輸入框位置的面板高度(#624):同鍵盤,看過鍵盤就用最近一次的高度;沒看過(例如實體鍵盤)用預設。
enum SlashPanelLayout {
    static let defaultHeight: CGFloat = 300
    /// 小於這個高度的鍵盤框(快捷列、浮動鍵盤)不當作鍵盤高度。
    static let minimumHeight: CGFloat = 200
}

/// 面板的左 X(取消 = Esc)與右 ✓(確定 = Enter);sheet 與輸入框位置的面板共用(#624)。
package struct SlashPanelControls {
    let model: ConversationModel
    let panel: SlashPanel

    package init(model: ConversationModel, panel: SlashPanel) {
        self.model = model
        self.panel = panel
    }

    package var confirmAction: SlashPanelAction? { panel.actions.first { $0.key == "enter" } }

    /// 面板沒有 Enter 動作(例如只有「Esc to close」)時沒有 ✓。
    package var hasConfirm: Bool { confirmAction != nil }

    /// 左 X:按 Esc 取消,不改設定。
    package func cancel() async { await model.dismissPanel() }

    /// 右 ✓:按面板提示行的 Enter(不是 `s`、更不是數字)。回傳按鍵是否送出。
    @discardableResult
    package func confirm() async -> Bool {
        guard let confirmAction else { return false }
        return await model.operatePanel(.action(confirmAction))
    }
}

/// iPhone(窄視窗)的 slash 面板(#624、spec #612 原型 C「輸入框變成面板」):面板出現時輸入框收起,
/// 面板取代輸入框、佔住鍵盤的位置,對話在上方整段可見。頂列左 X = 取消(Esc)、右 ✓ = 確定(同 `ModalConfirmToolbar` 樣式)。
/// 輸入框草稿保留在 model,面板收起後輸入框回來。
struct SlashPanelBar: View {
    let model: ConversationModel
    let panel: SlashPanel
    /// 面板高度(同鍵盤;`ComposerBar` 記住最近一次的鍵盤高度)。
    let height: CGFloat

    private var controls: SlashPanelControls { SlashPanelControls(model: model, panel: panel) }

    var body: some View {
        VStack(spacing: 0) {
            header
            SlashPanelContent(model: model, panel: panel)
        }
        .frame(height: height)
        .floatingGlass(in: RoundedRectangle(cornerRadius: 28))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel.bar")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                Task { await controls.cancel() }
            } label: {
                Label("Cancel", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityIdentifier("panel.cancel")

            Text(verbatim: panel.title ?? "")
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)

            if controls.hasConfirm {
                Button {
                    Task { await controls.confirm() }
                } label: {
                    Label("Confirm", systemImage: "checkmark")
                        .labelStyle(.iconOnly)
                }
                .filledProminentButtonStyle()
                .buttonBorderShape(.circle)
                .disabled(model.isOperatingPanel)
                .accessibilityIdentifier("panel.confirm")
            } else {
                // 沒有 ✓ 時留同寬的空位,標題才會置中。
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

/// iPad 寬視窗的 slash 面板仍是底部 sheet(#366):內容同上,左上 X = Esc、右上 ✓ = Enter(#613 modal 規則)。
/// 面板關掉(選定或 Esc)時 sheet 跟著收起;使用者下滑關掉時按 Esc 取消,不改設定。從模型膠囊開的面板另有自己的 sheet(#350)。
private struct SlashPanelSheet: ViewModifier {
    let model: ConversationModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: {
                SlashPanelPresentation.resolve(
                    hasPanel: model.panel != nil, isChoosingModel: model.isChoosingModel, isRegularWidth: sizeClass == .regular) == .sheet
            },
            set: { shown in if !shown { Task { await model.dismissPanel() } } }
        )) {
            if let panel = model.panel {
                let controls = SlashPanelControls(model: model, panel: panel)
                NavigationStack {
                    SlashPanelContent(model: model, panel: panel)
                        .navigationTitle(Text(verbatim: panel.title ?? ""))
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar {
                            SheetCloseToolbar(identifier: "panel.cancel", action: { Task { await controls.cancel() } })
                            if controls.hasConfirm {
                                ModalConfirmToolbar(
                                    title: "Confirm", identifier: "panel.confirm", isEnabled: !model.isOperatingPanel,
                                    action: { Task { await controls.confirm() } })
                            }
                        }
                }
                .appSheet(detents: [.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }
}

extension View {
    func slashPanelSheet(model: ConversationModel) -> some View {
        modifier(SlashPanelSheet(model: model))
    }
}
