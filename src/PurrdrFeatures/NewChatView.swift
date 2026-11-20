import PurrdrAgentFeatures
import PurrdrCore
import PurrdrSSH
import SwiftUI

/// 新增對話(#272,原型 purrdr-screens 定案版):標題列中間是主機挑選鈕，下面是 Agent(分段控制)、資料夾、第一則訊息，
/// 最下方「開始」。名稱由 herdr 用資料夾名，權限沿用 agent 自己的設定。
///
/// 以 sheet 開啟;資料夾瀏覽在同一個 sheet 內 push(HIG 檢核清單 20.3「多步驟在同一個 sheet 內 push」)。
/// 開始中不能滑掉 sheet(主機上正在建立 workspace)。
public struct NewChatView: View {
    @Bindable var model: NewChatModel
    /// 標題列中間的主機挑選鈕(#245)。
    let hostPicker: HostPickerModel?
    let onCancel: () -> Void
    /// 開始了：新 workspace 與沒送出的第一則訊息(agent 停在啟動問題時)。
    let onStarted: (CreatedWorkspace, String?) -> Void

    /// 原型只有這兩種(分段控制);其他 agent 的啟動另議。
    private static let agents: [NewChatAgent] = [.claude, .codex]

    public init(
        model: NewChatModel, hostPicker: HostPickerModel? = nil, onCancel: @escaping () -> Void,
        onStarted: @escaping (CreatedWorkspace, String?) -> Void
    ) {
        self.model = model
        self.hostPicker = hostPicker
        self.onCancel = onCancel
        self.onStarted = onStarted
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Agent", selection: $model.agent) {
                        ForEach(Self.agents, id: \.self) { agent in
                            Text(verbatim: agent.displayName).tag(agent)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("newChat.agent")
                } header: {
                    Text("Agent")
                        .foregroundStyle(.secondaryText)
                }

                Section {
                    TextField("Folder", text: $model.folder, prompt: Text(verbatim: "~/projects/app"))
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        #endif
                        .accessibilityIdentifier("newChat.folder")
                    NavigationLink {
                        FolderPickerView(model: model.makeFolderPicker()) { model.choose($0) }
                    } label: {
                        Label("Choose Folder on Host", systemImage: "folder")
                    }
                    .accessibilityIdentifier("newChat.chooseFolder")
                } header: {
                    Text("Folder")
                        .foregroundStyle(.secondaryText)
                }

                Section {
                    TextField("First Message", text: $model.message, prompt: Text("What should the agent do?"), axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("newChat.message")
                } header: {
                    Text("First Message")
                        .foregroundStyle(.secondaryText)
                }

                if let error = model.error {
                    Section {
                        ErrorLabel(error)
                            .accessibilityIdentifier("newChat.error")
                    }
                }

                Section {
                    Button(action: start) {
                        Group {
                            if model.isStarting {
                                ProgressView()
                                    .accessibilityLabel(Text("Starting…"))
                                    .accessibilityIdentifier("newChat.starting")
                            } else {
                                Text("Start")
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .filledProminentButtonStyle()
                    .disabled(!model.canStart)
                    .accessibilityIdentifier("newChat.start")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            .accessibilityIdentifier("sheet.newChat")
            .navigationTitle("New Chat")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .interactiveDismissDisabled(model.isStarting)
            .toolbar {
                if let hostPicker {
                    // 主機挑選鈕佔標題位置(原型);頁面只顯示標題，不放說明。
                    ToolbarItem(placement: .principal) {
                        HostPickerButton(model: hostPicker, identifier: "newChat.host")
                            .disabled(model.isStarting)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(model.isStarting)
                        .accessibilityIdentifier("newChat.cancel")
                }
            }
        }
    }

    private func start() {
        Task {
            if let created = await model.start() { onStarted(created, model.unsentMessage) }
        }
    }
}

/// 新增對話的資料夾瀏覽(行為規格 F3.3):只列子資料夾;錯誤與空資料夾分開顯示。
struct FolderPickerView: View {
    let model: FolderPickerModel
    let onChoose: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        content
            .navigationTitle("Choose Folder")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Enclosing Folder", systemImage: "arrow.up") { Task { await model.goUp() } }
                        .disabled(!model.canGoUp)
                        .accessibilityIdentifier("folderPicker.up")
                }
                ToolbarItem(placement: Self.usePlacement) {
                    Button("Use This Folder") {
                        guard let path = model.chosenPath else { return }
                        onChoose(path)
                        dismiss()
                    }
                    .filledGlassProminentButtonStyle()
                    .disabled(model.chosenPath == nil)
                    .accessibilityIdentifier("folderPicker.use")
                }
            }
            .task { await model.load() }
    }

    #if os(iOS)
    private static let usePlacement = ToolbarItemPlacement.bottomBar
    #else
    private static let usePlacement = ToolbarItemPlacement.automatic
    #endif

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("Loading folders…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("folderPicker.loading")
        case .failed(let message):
            ContentUnavailableView {
                Label("Can’t Open Folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.load() } }
                    .accessibilityIdentifier("folderPicker.retry")
            }
            .accessibilityIdentifier("folderPicker.error")
        case .loaded(let listing):
            List {
                Section {
                    if listing.folders.isEmpty {
                        Text("No folders inside this one. You can still use it.")
                            .foregroundStyle(.secondaryText)
                            .accessibilityIdentifier("folderPicker.empty")
                    }
                    ForEach(listing.folders, id: \.self) { name in
                        Button {
                            Task { await model.open(name) }
                        } label: {
                            Label {
                                Text(verbatim: name).foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: "folder")
                            }
                        }
                        .accessibilityIdentifier("folderPicker.row.\(name)")
                    }
                } header: {
                    Text(verbatim: listing.path)
                        .font(.footnote.monospaced())
                        .textCase(nil)
                        .accessibilityIdentifier("folderPicker.path")
                        .foregroundStyle(.secondaryText)
                }
            }
            .accessibilityIdentifier("folderPicker.list")
        }
    }
}

extension NewChatAgent {
    /// 產品名稱，不翻譯。
    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .grok: "Grok"
        case .agy: "Antigravity"
        case .pi: "Pi"
        case .omp: "OMP"
        }
    }
}
