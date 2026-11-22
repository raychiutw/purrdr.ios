import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 模型膠囊(#350):輸入列工具列、附加鈕右邊(權限模式膠囊左邊)。顯示目前的模型加 `▾`,
/// 高度與底色同附加鈕(DESIGN.md「選單膠囊」);點一下送 `/model`,sheet 裡用勾選列選(同「選擇控制」)。
struct ModelCapsule: View {
    let model: ConversationModel

    static let height: Double = 34

    @State private var isPresented = false

    private var title: String { model.modelName ?? String(localized: "Model") }

    var body: some View {
        Button {
            isPresented = true
            Task { await model.beginChoosingModel() }
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
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
        .disabled(!model.canChooseModel)
        .accessibilityLabel(Text("Model"))
        .accessibilityValue(Text(verbatim: model.modelName ?? ""))
        .accessibilityHint(Text("Opens the list of models."))
        .accessibilityIdentifier("composer.model")
        .sheet(isPresented: $isPresented, onDismiss: { Task { await model.finishChoosingModel() } }) {
            ModelSheet(model: model)
        }
    }
}

/// 模型選擇 sheet:勾選列攤開 `/model` 面板的選項;面板還沒出現時轉圈。
struct ModelSheet: View {
    let model: ConversationModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let panel = model.panel, !panel.options.isEmpty {
                    Section {
                        Picker(String(localized: "Model"), selection: selection(panel)) {
                            ForEach(panel.options) { option in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: option.label)
                                    if let detail = option.detail {
                                        Text(verbatim: detail)
                                            .font(.footnote)
                                            .foregroundStyle(.secondaryText)
                                    }
                                }
                                .tag(option.index)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        .disabled(model.isOperatingPanel)
                        .accessibilityIdentifier("model.picker")
                    }
                } else if model.isChoosingModel {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Reading the model list…")
                                .foregroundStyle(.secondaryText)
                        }
                        .accessibilityIdentifier("model.loading")
                    }
                } else {
                    Section {
                        Label("Couldn’t open the model list. Try again, or check the terminal.", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .accessibilityIdentifier("model.failure")
                    }
                }
            }
            .appGroupedList()
            .navigationTitle("Model")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("model.done")
                }
            }
        }
        .presentationDetents([.medium])
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
