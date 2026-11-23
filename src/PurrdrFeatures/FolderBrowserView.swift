import PurrdrAgentFeatures
import PurrdrCore
import PurrdrSSH
import SwiftUI
import UniformTypeIdentifiers

/// 檔案瀏覽(行為規格 F13):檔案 tab 的頁面。共用頂列(#500):大標題「檔案」、右側 [電腦圖示｜＋](電腦圖示選看哪台主機、
/// 「＋」上傳到這裡)與頭像;搜尋欄篩目前資料夾的項目。目前在哪一層看列表最上面的路徑麵包屑(#273)。
/// 資料夾在前,點資料夾或 symlink 打開,檔案只顯示大小與修改時間;下拉重新整理。
public struct FolderBrowserView: View {
    let model: FolderBrowserModel
    let hostPicker: HostPickerModel
    let actions: TabTopBarActions
    @State private var importing = false
    @FocusState private var searchFocused: Bool

    init(model: FolderBrowserModel, hostPicker: HostPickerModel, actions: TabTopBarActions) {
        self.model = model
        self.hostPicker = hostPicker
        self.actions = actions
    }

    public var body: some View {
        content
            .topBarPage(topBarContent)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                guard case .success(let url) = result else { return }
                Task { await model.upload(fileAt: url) }
            }
            .alert("Can’t Upload", isPresented: Binding(get: { model.notice != nil }, set: { _ in })) {
                Button("OK", role: .cancel) { model.notice = nil }
            } message: {
                Text(model.notice ?? "")
            }
            .task {
                if model.path == nil { await model.load() }
            }
    }

    private var topBarContent: TopBarContent {
        @Bindable var model = model
        return TopBarContent(
            tab: .files, title: "Files",
            hostScope: .selected(hostName: hostPicker.selectedOption?.name),
            hostMenu: AnyView(HostSelectionMenu(model: hostPicker, addHost: actions.addHost)),
            hostIdentifier: "files.host",
            plus: AnyView(uploadControl),
            account: actions.account,
            search: TopBarContent.Search(text: $model.query, focus: $searchFocused, identifier: "files.search"))
    }

    @ViewBuilder
    private var uploadControl: some View {
        if let name = model.uploading {
            ProgressView()
                .accessibilityLabel(Text("Uploading \(name)"))
                .accessibilityIdentifier("files.uploading")
        } else {
            TopBarPlusButton(title: "Upload File", identifier: "files.upload") { importing = true }
                .disabled(model.path == nil)
        }
    }

    /// 路徑麵包屑(#273):列表最上面、第一個區段的標頭,每段可點回那一層。
    @ViewBuilder
    private var breadcrumbBar: some View {
        if !model.breadcrumbs.isEmpty {
            FolderBreadcrumbBar(crumbs: model.breadcrumbs, showsBar: false) { crumb in Task { await model.go(to: crumb) } }
                .frame(height: 44)
                .textCase(nil)
                .listRowInsets(EdgeInsets())
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            // 第一次列這個資料夾:同形狀的列骨架,列數取上次的數量(#496)。
            List {
                Section {
                    VStack(spacing: 0) {
                        ForEach(0..<model.loadingRowCount, id: \.self) { index in
                            FolderEntryRow(entry: .skeletonPlaceholder(index), open: {})
                                .padding(.vertical, 10)
                        }
                    }
                    .skeleton(identifier: "files.loading")
                } header: { breadcrumbBar }
            }
            .appGroupedList()
        case .failed(let message):
            List {
                Section { EmptyView() } header: { breadcrumbBar }
                ContentUnavailableView {
                    Label("Can’t Show This Folder", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await model.load() } }
                        .accessibilityIdentifier("files.retry")
                }
                .accessibilityIdentifier("files.error")
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .appGroupedList()
        case .loaded(let listing):
            List {
                Section {
                    if listing.entries.isEmpty {
                        Text("This folder is empty.")
                            .foregroundStyle(.secondaryText)
                            .accessibilityIdentifier("files.empty")
                    } else if model.visibleEntries.isEmpty {
                        Text("No Results")
                            .foregroundStyle(.secondaryText)
                            .accessibilityIdentifier("files.noResults")
                    }
                    ForEach(model.visibleEntries, id: \.name) { entry in
                        FolderEntryRow(entry: entry) {
                            Task { await model.open(entry) }
                        }
                    }
                } header: { breadcrumbBar }
            }
            .appGroupedList()
            .refreshable { await model.load() }
            .accessibilityIdentifier("files.list")
        }
    }
}

/// 一個項目:圖示、名稱、檔案的大小與修改時間。資料夾與 symlink 可以點。
struct FolderEntryRow: View {
    let entry: FolderEntry
    /// UI 測試的識別字開頭(檔案頁 `files.row.`、新增聊天的資料夾瀏覽 `folderPicker.row.`)。
    var identifierPrefix = "files.row."
    let open: () -> Void

    var body: some View {
        if entry.kind == .folder || entry.kind == .symlink {
            Button(action: open) {
                HStack {
                    label
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("\(identifierPrefix)\(entry.name)")
        } else {
            label
                .accessibilityIdentifier("\(identifierPrefix)\(entry.name)")
        }
    }

    private var label: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.name)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let detail {
                    Text(verbatim: detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondaryText)
                }
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(entry.kind == .folder ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .accessibilityLabel(kindLabel)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch entry.kind {
        case .folder: "folder.fill"
        case .file: AgentFileKind(fileExtension: (entry.name as NSString).pathExtension.lowercased()) == .image ? "photo" : "doc"
        case .symlink: "arrow.up.forward.square"
        case .other: "questionmark.square.dashed"
        }
    }

    private var kindLabel: Text {
        switch entry.kind {
        case .folder: Text("Folder")
        case .file: Text("File")
        case .symlink: Text("Link")
        case .other: Text("Other")
        }
    }

    private var detail: String? {
        let date = entry.modified.flatMap { components -> String? in
            guard let date = Calendar.current.date(from: components) else { return nil }
            return date.formatted(date: .abbreviated, time: components.hour == nil ? .omitted : .shortened)
        }
        switch entry.kind {
        case .file:
            return [entry.size.formatted(.byteCount(style: .file)), date].compactMap { $0 }.joined(separator: " · ")
        default:
            return date
        }
    }
}

/// 檔案頁的路徑麵包屑(#273,原型 purrdr-screens 定案版:「~ › Projects › ledger」):可橫捲，捲到最後一段。
/// 每段是以資料夾命名的按鈕(VoiceOver 可以逐層往上);最後一段是目前的資料夾，不能點。
struct FolderBreadcrumbBar: View {
    let crumbs: [FolderBreadcrumb]
    /// UI 測試的識別字開頭(檔案頁 `files.crumb.`、資料夾瀏覽 `folderPicker.crumb.`)。
    var identifierPrefix = "files.crumb."
    /// 檔案頁的列表內不畫底(跟列表同一個頁面底色);sheet 內的資料夾瀏覽用系統 bar 材質。
    var showsBar = true
    let go: (FolderBreadcrumb) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(crumbs.enumerated()), id: \.element) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.forward")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondaryText)
                                .accessibilityHidden(true)
                        }
                        let isCurrent = index == crumbs.count - 1
                        Button { go(crumb) } label: {
                            Text(verbatim: crumb.title)
                                .fontWeight(isCurrent ? .semibold : .regular)
                                .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondaryText))
                                .frame(minHeight: 44)
                                .padding(.horizontal, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressableRow(cornerRadius: 8))
                        .disabled(isCurrent)
                        .accessibilityLabel(crumb.isHome ? Text("Home Folder") : Text(verbatim: crumb.title))
                        .accessibilityIdentifier("\(identifierPrefix)\(index)")
                        .id(index)
                    }
                }
                .font(.subheadline)
                .padding(.horizontal, 16)
            }
            .onChange(of: crumbs, initial: true) { _, crumbs in proxy.scrollTo(crumbs.count - 1, anchor: .trailing) }
        }
        .background { if showsBar { Rectangle().fill(.bar) } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files.breadcrumbs")
    }
}

extension FolderEntry {
    /// 列表骨架的佔位項目(`redacted` 畫成灰條)。
    static func skeletonPlaceholder(_ index: Int) -> FolderEntry {
        FolderEntry(name: "Folder name placeholder", kind: .folder, size: 1024, modified: nil)
    }
}
