import PurrdrAgentFeatures
import SwiftUI

extension TerminalSizeMode {
    var title: String {
        switch self {
        case .keepDesktop: String(localized: "Keep Host Layout")
        case .fitPhone: String(localized: "Fit This Phone")
        }
    }
}

/// Pane 終端機上方的大小膠囊(#357,DESIGN.md「選單膠囊」):顯示目前的大小模式加 `▾`,
/// 點開 sheet 以 inline 勾選列選擇。
struct TerminalSizeCapsule: View {
    let model: any TerminalSessionModel

    @State private var isPresented = false

    var body: some View {
        HStack {
            Button {
                isPresented = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                        .accessibilityHidden(true)
                    Text(verbatim: model.sizeMode.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 12)
                .frame(height: 32)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .frame(minHeight: 44)
            .accessibilityLabel(Text("Size"))
            .accessibilityValue(Text(verbatim: model.sizeMode.title))
            .accessibilityHint(Text("Opens the size options."))
            .accessibilityIdentifier("terminal.size")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .sheet(isPresented: $isPresented) {
            TerminalSizeSheet(model: model)
        }
    }
}

private struct TerminalSizeSheet: View {
    let model: any TerminalSessionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker(String(localized: "Size"), selection: Binding(get: { model.sizeMode }, set: { model.setSizeMode($0) })) {
                        ForEach(TerminalSizeMode.allCases, id: \.self) { mode in
                            Text(verbatim: mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("terminal.size.picker")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.sizeMode == .fitPhone
                             ? "The layout on your computer changes to match this phone, and returns when you leave."
                             : "This phone shows the pane at your computer’s size, so the layout on your computer doesn’t change.")
                            .accessibilityIdentifier("terminal.size.note")
                        if model.sizeMode == .keepDesktop {
                            if model.keepDesktopFallback {
                                Text("Couldn’t read this pane’s size on your computer, so it opened at this phone’s size. Open it again once herdr is running there.")
                                    .accessibilityIdentifier("terminal.size.fallback")
                            } else {
                                Text("While you’re connected, the pane keeps this size, even if you resize the window on your computer.")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Size")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
