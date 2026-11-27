import PhotosUI
import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 泡泡圖片(F7;#37 故事 35)

/// 泡泡圖片要用的東西：主機路徑或副本檔名 → 手機上的副本、打開圖片檢視器(#426)。
struct BubbleImageContext {
    var localImage: (String) -> URL? = { _ in nil }
    var show: (ImageViewerItem) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var bubbleImages = BubbleImageContext()
    /// 使用者泡泡裡訊息中間要上色的 slash 指令名稱(#469);聊天畫面提供。
    @Entry var inlineSlashNames: Set<String> = []
}

/// 泡泡圖片的排版規則(#465,設計稿第 30 組;使用者送出的與本機送出的共用):
/// 單張依原圖比例(長邊 220pt);兩張以上排成兩欄 124pt 的方塊格子(iOS 訊息 app 習慣)。
struct BubbleImageLayout: Equatable {
    let count: Int

    static let longEdge: CGFloat = 220
    static let tile: CGFloat = 124
    static let gridColumns = 2
    static let gridSpacing: CGFloat = 4
    static let cornerRadius: CGFloat = 16

    var isGrid: Bool { count > 1 }

    /// 一張圖的顯示大小:格子是方塊;單張長邊 220pt、依比例;尺寸未知是 220pt 方塊。
    func size(forImage size: CGSize) -> CGSize {
        if isGrid { return CGSize(width: Self.tile, height: Self.tile) }
        guard size.width > 0, size.height > 0 else { return CGSize(width: Self.longEdge, height: Self.longEdge) }
        let scale = Self.longEdge / max(size.width, size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}

/// 泡泡裡的圖片：單張依原圖比例(長邊 220pt)、多張排成 124pt 方塊格子(#465);點開全螢幕。
/// 手機上沒有副本(例如別台裝置送的)時經主機讀回縮圖,讀不到顯示「Image」標籤(圖在主機上)。
struct BubbleImagesView: View {
    /// 每張圖的副本位置;`nil` 表示只有主機上有。
    let images: [URL?]
    /// 每張圖在主機上的路徑(依序對應 `images`);手機沒有副本時經主機取檔讀回縮圖(#428)。
    var hostPaths: [String?] = []
    @Environment(\.bubbleImages) private var context
    @Environment(\.agentImages) private var agentImages

    private var layout: BubbleImageLayout { BubbleImageLayout(count: images.count) }

    var body: some View {
        if layout.isGrid {
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(BubbleImageLayout.tile), spacing: BubbleImageLayout.gridSpacing), count: BubbleImageLayout.gridColumns),
                alignment: .trailing, spacing: BubbleImageLayout.gridSpacing
            ) { tiles }
                .frame(width: BubbleImageLayout.tile * CGFloat(BubbleImageLayout.gridColumns) + BubbleImageLayout.gridSpacing)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("conversation.imageGrid")
        } else {
            VStack(alignment: .trailing, spacing: 6) { tiles }
        }
    }

    @ViewBuilder
    private var tiles: some View {
        ForEach(Array(images.enumerated()), id: \.offset) { index, url in
            if let url, let size = BubbleImageCache.size(of: url) {
                let fitted = layout.size(forImage: size)
                Button {
                    open(tapped: index)
                } label: {
                    BubbleImageCache.image(at: url)
                        .resizable()
                        .scaledToFill()
                        .frame(width: fitted.width, height: fitted.height)
                        .clipShape(RoundedRectangle(cornerRadius: BubbleImageLayout.cornerRadius))
                }
                .buttonStyle(.pressableThumbnail(cornerRadius: BubbleImageLayout.cornerRadius))
                .accessibilityLabel(Text("Image \(index + 1)"))
                .accessibilityHint(Text("Opens the image full screen."))
                .accessibilityIdentifier("conversation.image")
            } else if index < hostPaths.count, let path = hostPaths[index] {
                HostSentImageView(path: path, index: index, layout: layout) { open(tapped: index) }
            } else {
                Label("Image", systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondaryText)
                    .accessibilityLabel(Text("Image on the host"))
            }
        }
    }

    /// 點某一張:同一則訊息的圖片一起放進圖片檢視器,從點的那張開始(#426)。
    private func open(tapped index: Int) {
        let loads = agentImages.loads
        let plan = ImageViewerPlan(images: images, hostPaths: hostPaths, tapped: index) { path in
            switch loads?.states[path] {
            case .missing, .denied, .unsupported, .tooLarge: false
            default: true
            }
        }
        guard let plan else { return }
        let sources = plan.entries.enumerated().map { id, entry -> ImageViewerSource in
            switch entry {
            case .local(let url): ImageViewerSource(id: id, name: url.lastPathComponent, origin: .file(url))
            case .host(let path):
                ImageViewerSource(id: id, name: HostPathOpenStatus.name(of: path), origin: .deferred { [agentImages] in
                    await agentImages.fullImageData(at: path)
                })
            }
        }
        context.show(ImageViewerItem(sources: sources, startIndex: plan.startIndex))
    }
}

/// 圖片與尺寸的快取：每個副本記住比例，回收列時不會先方後跳(F7)。
@MainActor
enum BubbleImageCache {
    #if canImport(UIKit)
    private static var images: [URL: UIImage] = [:]

    private static func load(_ url: URL) -> UIImage? {
        if let cached = images[url] { return cached }
        guard let image = UIImage(contentsOfFile: url.path(percentEncoded: false)) else { return nil }
        images[url] = image
        return image
    }

    static func size(of url: URL) -> CGSize? { load(url)?.size }
    static func image(at url: URL) -> Image { load(url).map(Image.init(uiImage:)) ?? Image(systemName: "photo") }
    #else
    static func size(of url: URL) -> CGSize? { nil }
    static func image(at url: URL) -> Image { Image(systemName: "photo") }
    #endif
}

// MARK: - 輸入列的附件

/// 輸入框裡的附件小卡(#352):圖片是 64pt 方形縮圖，檔案是圖示＋檔名＋大小;都可個別移除(送出中停用)。
struct AttachmentStrip: View {
    let model: ConversationModel
    /// accessibility identifier 的前綴(展開畫面用 `composer.expanded`)。
    var identifierPrefix = "composer"

    @State private var showsVideoNote = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(model.attachments.enumerated()), id: \.element.id) { index, attachment in
                        card(attachment, index: index)
                    }
                }
                .padding(.top, 6)
                .padding(.trailing, 6)
            }
            .scrollIndicators(.hidden)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("\(identifierPrefix).attachments")
            // 進階說明預設收起(HIG Disclosure controls):影片附加後才出現。
            if model.attachments.contains(where: { $0.duration != nil }) {
                DisclosureGroup("About videos", isExpanded: $showsVideoNote) {
                    Text("Agents may not be able to watch videos.")
                        .font(.footnote)
                        .foregroundStyle(.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.footnote)
                .accessibilityIdentifier("\(identifierPrefix).videoNote")
            }
        }
    }

    private func card(_ attachment: ComposerAttachment, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            content(attachment)
                .overlay {
                    if model.isSending && attachment.uploadedPath == nil {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .accessibilityElement()
                .accessibilityLabel(label(attachment, index: index))
                .accessibilityIdentifier("\(identifierPrefix).attachment.\(index)")

            Button {
                model.removeAttachment(attachment.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .offset(x: 14, y: -14)
            .disabled(model.isSending)
            .accessibilityLabel(removeLabel(attachment, index: index))
            .accessibilityIdentifier("\(identifierPrefix).attachment.remove.\(index)")
        }
        .padding(.top, 8)
        .padding(.trailing, 8)
    }

    @ViewBuilder
    private func content(_ attachment: ComposerAttachment) -> some View {
        switch attachment.kind {
        case .image:
            Group {
                if let url = model.localImage(named: attachment.fileName.value) {
                    BubbleImageCache.image(at: url).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 64)
            .background(.fill.tertiary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        case .file:
            HStack(spacing: 8) {
                fileIcon(attachment)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: attachment.displayName)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: Self.sizeAndDuration(attachment))
                        .font(.caption)
                        .foregroundStyle(.secondaryText)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: 190, minHeight: 64, alignment: .leading)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    /// 檔案圖示;影片是第一格縮圖。
    @ViewBuilder
    private func fileIcon(_ attachment: ComposerAttachment) -> some View {
        if let name = attachment.thumbnailFileName, let url = model.localImage(named: name) {
            BubbleImageCache.image(at: url)
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .overlay { Image(systemName: "play.fill").font(.caption).foregroundStyle(.white).shadow(radius: 2) }
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            Image(systemName: attachment.duration == nil ? "doc.fill" : "video.fill")
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private static func sizeAndDuration(_ attachment: ComposerAttachment) -> String {
        guard let duration = attachment.duration else { return size(attachment) }
        let seconds = Int(duration.rounded())
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60)) · \(size(attachment))"
    }

    private static func size(_ attachment: ComposerAttachment) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file)
    }

    private func label(_ attachment: ComposerAttachment, index: Int) -> Text {
        switch attachment.kind {
        case .image: Text("Attached image \(index + 1)")
        case .file: Text("Attached file \(attachment.displayName), \(Self.size(attachment))")
        }
    }

    private func removeLabel(_ attachment: ComposerAttachment, index: Int) -> Text {
        switch attachment.kind {
        case .image: Text("Remove Image \(index + 1)")
        case .file: Text("Remove \(attachment.displayName)")
        }
    }
}

// MARK: - 附加

/// 輸入列的「＋」(#352):VoiceOver 念「附加」,點了從下方升起面板(最近的照片可多選，相機、所有照片、檔案、貼上四顆按鈕)。
struct AttachButton: View {
    let model: ConversationModel
    var identifier = "composer.attach"
    @Environment(\.recentPhotoSource) private var recentPhotos
    @State private var showsPanel = false
    @State private var next: AttachPanel.Choice?
    @State private var showsLibrary = false
    @State private var showsCamera = false
    @State private var showsFiles = false
    @State private var selection: [PhotosPickerItem] = []
    @State private var showsVideos = false
    @State private var videoSelection: [PhotosPickerItem] = []
    @Environment(\.videoSource) private var videoSource

    var body: some View {
        Button {
            // 離線時停用外觀但仍可點:點了說明「連上後才能加入附件」(#382)。
            if model.requestAttach() { showsPanel = true }
        } label: {
            Image(systemName: "plus")
                .frame(width: 30, height: 30)
        }
        .composerCircleButtonStyle()
        .frame(minWidth: 44, minHeight: 44)
        .opacity(model.attachAvailability.isDimmed ? 0.4 : 1)
        .disabled(model.isSending || model.loadingFileName != nil || model.videoPreparation != nil)
        .accessibilityLabel(Text("Attach"))
        .accessibilityHint(model.attachAvailability == .offline ? Text("Attachments can be added once you’re connected.") : Text(verbatim: ""))
        .accessibilityIdentifier(identifier)
        .sheet(isPresented: $showsPanel, onDismiss: presentNext) {
            AttachPanel(model: model, source: recentPhotos) { choice in
                next = choice
                showsPanel = false
            }
            .appSheet(detents: [.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .photosPicker(
            isPresented: $showsLibrary, selection: $selection, maxSelectionCount: max(1, model.remainingImageSlots),
            selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current
        )
        .onChange(of: selection) {
            let items = selection
            guard !items.isEmpty else { return }
            selection = []
            Task {
                var loaded: [Data] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) { loaded.append(data) }
                }
                await model.addImages(loaded)
            }
        }
        .photosPicker(
            isPresented: $showsVideos, selection: $videoSelection, maxSelectionCount: 1, selectionBehavior: .default,
            matching: .videos, preferredItemEncoding: .current
        )
        .onChange(of: videoSelection) {
            guard let item = videoSelection.first else { return }
            videoSelection = []
            Task {
                await model.addPickedVideo(displayName: String(localized: "Video") + ".mov") {
                    guard let picked = try await item.loadTransferable(type: PickedVideo.self) else { throw CocoaError(.fileReadNoSuchFile) }
                    return VideoSourceFile(picked.url, discarding: picked.folder)
                }
            }
        }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { for url in urls { await ComposerFiles.add(url, to: model) } }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showsCamera) {
            CameraPicker { data in
                Task { await model.addImages([data]) }
            }
            .ignoresSafeArea()
        }
        #endif
    }

    /// 面板關掉之後才開系統畫面(同時換掉兩個呈現會被吃掉)。
    private func presentNext() {
        guard let choice = next else { return }
        next = nil
        switch choice {
        case .camera: showsCamera = true
        case .library: showsLibrary = true
        case .files: showsFiles = true
        case .video:
            if videoSource == .simulated {
                Task { await model.addVideo(displayName: "Demo.mov") { try await GeneratedVideo.make() } }
            } else {
                showsVideos = true
            }
        }
    }
}

/// 「＋」升起的面板:上方最近的照片(可多選)，下方相機、所有照片、檔案、貼上。沒有相簿權限時只有按鈕。
struct AttachPanel: View {
    enum Choice { case camera, library, video, files }

    let model: ConversationModel
    let source: RecentPhotoSource
    let choose: (Choice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pager = RecentPhotoPager(columns: Self.columns, fetch: { _, _ in [] })
    @State private var panelSize = CGSize.zero
    @State private var selection = AttachSelection()

    private static let columns = 4
    private static let spacing: CGFloat = 4
    private var photos: [RecentPhoto] { pager.photos }

    var body: some View {
        // 一次只開一個 sheet(#386):關閉在左上 xmark，選檔案或拍照由呼叫端先關掉這張再開系統畫面。
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    HStack(alignment: .top) {
                        if ImageSources.cameraAvailable { action("Take Photo", symbol: "camera", id: "camera", .camera) }
                        action("All Photos", symbol: "photo.on.rectangle", id: "photos", .library)
                        if model.canAttachVideos { action("Video", symbol: "video", id: "video", .video) }
                        if model.canAttachFiles { action("Files", symbol: "doc", id: "files", .files) }
                        pasteTile
                    }
                    if !photos.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Recent Photos")
                                Spacer()
                                Text("Selected \(selection.count)")
                                    .monospacedDigit()
                                    .accessibilityIdentifier("attach.selectedCount")
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondaryText)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: Self.columns), spacing: Self.spacing) {
                                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                                    tile(photo, index: index)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
                .appScrollTopEdge()
            .safeAreaInset(edge: .bottom) {
                if selection.count > 0 {
                    Button {
                        addSelected()
                    } label: {
                        Text("Add \(selection.count)")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .filledProminentButtonStyle()
                    .padding([.horizontal, .bottom])
                    .accessibilityIdentifier("attach.add")
                }
            }
            .navigationTitle("Add")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { SheetCloseToolbar(identifier: "attach.close") }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attach.panel")
        // 最近照片依 sheet 高度填滿、捲到底繼續載入(#475);量到尺寸後才讀第一頁。
        .onGeometryChange(for: CGSize.self, of: \.size) { panelSize = $0 }
        .task(id: panelSize == .zero) {
            guard panelSize != .zero else { return }
            let side = (panelSize.width - 32 - Self.spacing * CGFloat(Self.columns - 1)) / CGFloat(Self.columns)
            let source = source
            pager = RecentPhotoPager(columns: Self.columns) { offset, limit in await source.recent(offset: offset, limit: limit) }
            await pager.loadFirstPage(
                count: RecentPhotoPager.firstPageCount(
                    availableHeight: panelSize.height, tileSide: side, spacing: Self.spacing, columns: Self.columns))
        }
    }

    /// 固定的正方形格子:照片填滿並裁掉多的部分，直幅、橫幅都不會依原始比例溢出而蓋住按鈕(#386)。
    private func tile(_ photo: RecentPhoto, index: Int) -> some View {
        let number = selection.number(of: photo.id)
        return Button {
            if selection.toggle(photo.id, limit: model.remainingImageSlots) == .overLimit {
                model.noteImageLimit()
            }
        } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { ThumbnailImage(data: photo.thumbnail) }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) { selectionMark(number: number).padding(4) }
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.pressableThumbnail(cornerRadius: 8))
        .accessibilityLabel(Text("Photo \(index + 1)"))
        .accessibilityAddTraits(number != nil ? .isSelected : [])
        .accessibilityIdentifier("attach.recent.\(index)")
        .task { await pager.tileAppeared(at: index) }
    }

    /// 選取圈:未選是半透明深底加白邊與陰影(對任何照片 ≥ 3:1),已選是主色圓加編號。
    @ViewBuilder
    private func selectionMark(number: Int?) -> some View {
        if let number {
            Text(verbatim: "\(number)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.onProminentFill)
                .frame(width: 24, height: 24)
                .background(.prominentFill, in: .circle)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.5), radius: 2)
        } else {
            Circle()
                .fill(.black.opacity(0.35))
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                .frame(width: 24, height: 24)
                .shadow(color: .black.opacity(0.5), radius: 2)
        }
    }

    /// 貼上用系統的 `PasteButton`(HIG):使用者按的就是系統按鈕，不會跳「允許貼上」的詢問;剪貼簿沒有圖片時系統自己停用。
    private var pasteTile: some View {
        VStack(spacing: 6) {
            #if canImport(UIKit)
            PasteButton(supportedContentTypes: [.image]) { providers in
                Task { @MainActor in
                    let images = await ImageSources.imageData(from: providers)
                    dismiss()
                    await model.addImages(images)
                }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.roundedRectangle(radius: 16))
            .tint(.secondary)
            .frame(width: 52, height: 52)
            .accessibilityIdentifier("attach.paste")
            #endif
            Text("Paste")
                .font(.caption)
                .multilineTextAlignment(.center)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }

    private func action(_ title: LocalizedStringKey, symbol: String, id: String, _ choice: Choice) -> some View {
        Button {
            choose(choice)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: 52, height: 52)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 16))
                Text(title)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.pressableThumbnail(cornerRadius: 16))
        .accessibilityIdentifier("attach.\(id)")
    }

    private func addSelected() {
        let ids = selection.ids
        dismiss()
        Task { await model.addImages(await source.imageData(for: ids)) }
    }
}

/// 以 JPEG bytes 顯示縮圖。
private struct ThumbnailImage: View {
    let data: Data

    var body: some View {
        #if canImport(UIKit)
        if let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Color.clear
        }
        #else
        Color.clear
        #endif
    }
}

/// 從「檔案」挑的檔案(#286):在安全範圍存取期間讀大小與內容，交給對話 model 加成附件卡。
enum ComposerFiles {
    @MainActor static func add(_ url: URL, to model: ConversationModel) async {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        await model.addFile(named: url.lastPathComponent, size: size) {
            try Data(contentsOf: url, options: .mappedIfSafe)
        }
    }
}

/// iPad 拖放(#352):從其他 app 拖進來的檔案或照片加成附件。
enum ComposerDrop {
    static let types: [UTType] = [.fileURL, .image]

    @MainActor static func handle(_ providers: [NSItemProvider], into model: ConversationModel) -> Bool {
        guard model.canAttachImages, model.typedAnswer == nil else { return false }
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    // 拖來的檔案只有回呼期間能存取:先複製出來。
                    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
                    let copy = folder.appending(path: url.lastPathComponent)
                    do {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: url, to: copy)
                    } catch { return }
                    Task { @MainActor in
                        await ComposerFiles.add(copy, to: model)
                        try? FileManager.default.removeItem(at: folder)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in await model.addImages([data]) }
                }
            }
        }
        return true
    }
}

/// 正在讀取、準備加成附件的檔案：輸入卡片上方一列，完成或失敗就消失。
struct FileUploadProgressView: View {
    let fileName: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("Adding \(fileName)…")
                .font(.footnote)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.bar, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("composer.fileUpload")
    }
}

/// 送出時附件上傳中(#474):百分比與取消。
struct UploadProgressView: View {
    let progress: UploadProgress
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: progress.fraction)
                .progressViewStyle(.circular)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sending \(progress.displayName)…")
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(progress.fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Cancel", action: cancel)
                .font(.footnote.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("composer.upload.cancel")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .background(.bar, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.upload")
    }
}

/// 影片準備中(#474):取出、壓縮的進度與取消。
struct VideoPreparationView: View {
    let preparation: VideoPreparation
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let fraction = preparation.fraction, preparation.phase == .shrinking {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
            } else {
                ProgressView()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(preparation.phase == .shrinking ? "Shrinking video…" : "Getting video…")
                    .font(.footnote)
                if let fraction = preparation.fraction, preparation.phase == .shrinking {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Cancel", action: cancel)
                .font(.footnote.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("composer.videoPreparation.cancel")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .background(.bar, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.videoPreparation")
    }
}

/// 輸入框的貼上：剪貼簿只有圖片時加成附件(F6.3)。輸入列與展開畫面共用。
enum ComposerPasteHandler {
    @MainActor static func action(for model: ConversationModel) -> ComposerPaste.Action {
        ComposerPaste.action(
            hasImages: model.canAttachImages && ImageSources.pasteboardHasImages,
            hasStrings: ImageSources.pasteboardHasStrings, remainingSlots: model.remainingImageSlots)
    }

    @MainActor static func attachPasteboardImages(to model: ConversationModel) {
        let images = ImageSources.pasteboardImages()
        Task { await model.addImages(images) }
    }
}

/// 系統的圖片來源(剪貼簿、相機)。剪貼簿只看類型時不會跳「允許貼上」。
enum ImageSources {
    #if canImport(UIKit)
    @MainActor static var pasteboardHasImages: Bool { UIPasteboard.general.hasImages }
    @MainActor static var pasteboardHasStrings: Bool { UIPasteboard.general.hasStrings || UIPasteboard.general.hasURLs }
    @MainActor static var cameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    /// 從系統 `PasteButton` 交來的項目讀出圖片(PNG)。讀不出來的略過。
    @MainActor static func imageData(from providers: [NSItemProvider]) async -> [Data] {
        var images: [Data] = []
        for provider in providers {
            let data: Data? = await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(for: .image) { data, _ in continuation.resume(returning: data) }
            }
            if let data, let png = UIImage(data: data)?.pngData() { images.append(png) }
        }
        return images
    }

    /// 讀剪貼簿裡的圖片(使用者明確要求貼上時才呼叫)。
    @MainActor static func pasteboardImages() -> [Data] {
        (UIPasteboard.general.images ?? []).compactMap { $0.pngData() }
    }
    #else
    @MainActor static var pasteboardHasImages: Bool { false }
    @MainActor static var pasteboardHasStrings: Bool { false }
    @MainActor static var cameraAvailable: Bool { false }
    @MainActor static func pasteboardImages() -> [Data] { [] }
    #endif
}

#if canImport(UIKit)
/// 相機(系統 UIImagePickerController)。拍完回傳 JPEG。
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image"]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                parent.onCapture(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
#endif
