import PurrdrAgentFeatures
import PurrdrCore
import PurrdrSSH
import SwiftUI
import UniformTypeIdentifiers

/// 檔案瀏覽(行為規格 F13):標題是資料夾最後一段、副標是主機;工具列有上一層、上傳到這裡(「+」);
/// 下拉重新整理。資料夾在前，點資料夾或 symlink 打開，檔案只顯示大小與修改時間。
public struct FolderBrowserView: View {
    let model: FolderBrowserModel
    /// 標題列中間的主機挑選鈕(#245);沒有時副標顯示主機名稱。
    let hostPicker: HostPickerModel?
    @State private var importing = false

    public init(model: FolderBrowserModel, hostPicker: HostPickerModel? = nil) {
        self.model = model
        self.hostPicker = hostPicker
    }

    public var body: some View {
        content
            .navigationTitle(model.title)
            .navigationSubtitle(hostPicker == nil ? model.hostName : "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if let hostPicker {
                    // 主機挑選鈕佔標題位置;目前在哪一層看下面的路徑麵包屑(#273)。
                    ToolbarItem(placement: .principal) {
                        HostPickerButton(model: hostPicker, identifier: "files.host")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let name = model.uploading {
                        ProgressView()
                            .accessibilityLabel(Text("Uploading \(name)"))
                            .accessibilityIdentifier("files.uploading")
                    } else {
                        Button("Upload File", systemImage: "plus") { importing = true }
                            .disabled(model.path == nil)
                            .accessibilityIdentifier("files.upload")
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                guard case .success(let url) = result else { return }
                Task { await model.upload(fileAt: url) }
            }
            .alert("Can’t Upload", isPresented: Binding(get: { model.notice != nil }, set: { _ in })) {
                Button("OK", role: .cancel) { model.notice = nil }
            } message: {
                Text(model.notice ?? "")
            }
            // 路徑麵包屑(#273,原型):每段可點回那一層(取代「上一層」按鈕)。
            .safeAreaInset(edge: .top, spacing: 0) {
                if !model.breadcrumbs.isEmpty {
                    FolderBreadcrumbBar(crumbs: model.breadcrumbs) { crumb in Task { await model.go(to: crumb) } }
                }
            }
            .task {
                if model.path == nil { await model.load() }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("files.loading")
        case .failed(let message):
            ContentUnavailableView {
                Label("Can’t Show This Folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.load() } }
                    .accessibilityIdentifier("files.retry")
            }
            .accessibilityIdentifier("files.error")
        case .loaded(let listing):
            List {
                if listing.entries.isEmpty {
                    Text("This folder is empty.")
                        .foregroundStyle(.secondaryText)
                        .accessibilityIdentifier("files.empty")
                }
                Section {
                    ForEach(listing.entries, id: \.name) { entry in
                        FolderEntryRow(entry: entry) {
                            Task { await model.open(entry) }
                        }
                    }
                }
            }
            .refreshable { await model.load() }
            .accessibilityIdentifier("files.list")
        }
    }
}

/// 一個項目:圖示、名稱、檔案的大小與修改時間。資料夾與 symlink 可以點。
struct FolderEntryRow: View {
    let entry: FolderEntry
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
            .accessibilityIdentifier("files.row.\(entry.name)")
        } else {
            label
                .accessibilityIdentifier("files.row.\(entry.name)")
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
                        .accessibilityIdentifier("files.crumb.\(index)")
                        .id(index)
                    }
                }
                .font(.subheadline)
                .padding(.horizontal, 16)
            }
            .onChange(of: crumbs, initial: true) { _, crumbs in proxy.scrollTo(crumbs.count - 1, anchor: .trailing) }
        }
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files.breadcrumbs")
    }
}
