import PhotosUI
import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 泡泡圖片(F7;#37 故事 35)

/// 泡泡圖片要用的東西：主機路徑或副本檔名 → 手機上的副本、打開全螢幕檢視。
struct BubbleImageContext {
    var localImage: (String) -> URL? = { _ in nil }
    var show: (URL) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var bubbleImages = BubbleImageContext()
}

/// 全螢幕檢視的圖片。
struct ViewerImage: Identifiable, Equatable {
    let url: URL
    var id: URL { url }
}

/// 泡泡裡的圖片：長邊 220pt、依比例;點開全螢幕。手機上沒有副本(例如別台裝置送的)時顯示「Image」標籤(圖在主機上)。
struct BubbleImagesView: View {
    /// 每張圖的副本位置;`nil` 表示只有主機上有。
    let images: [URL?]
    @Environment(\.bubbleImages) private var context

    static let longEdge: CGFloat = 220

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(Array(images.enumerated()), id: \.offset) { index, url in
                if let url, let size = BubbleImageCache.size(of: url) {
                    Button {
                        context.show(url)
                    } label: {
                        BubbleImageCache.image(at: url)
                            .resizable()
                            .scaledToFill()
                            .frame(width: Self.fitted(size).width, height: Self.fitted(size).height)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.pressableThumbnail(cornerRadius: 14))
                    .accessibilityLabel(Text("Image \(index + 1)"))
                    .accessibilityHint(Text("Opens the image full screen."))
                    .accessibilityIdentifier("conversation.image")
                } else {
                    Label("Image", systemImage: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondaryText)
                        .accessibilityLabel(Text("Image on the host"))
                }
            }
        }
    }

    /// 長邊 220pt,依比例。
    static func fitted(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: longEdge, height: longEdge) }
        let scale = longEdge / max(size.width, size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
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

/// 全螢幕檢視：點任一處關閉(F7)。VoiceOver 有「Close」動作，也可用兩指 Z 字手勢(escape)。
struct ImageViewer: View {
    let image: ViewerImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            BubbleImageCache.image(at: image.url)
                .resizable()
                .scaledToFit()
                .accessibilityLabel(Text("Image"))
        }
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isImage)
        .accessibilityHint(Text("Tap to close."))
        .accessibilityAction(named: Text("Close")) { dismiss() }
        .accessibilityAction(.escape) { dismiss() }
        .accessibilityIdentifier("image.viewer")
        #if os(iOS)
        .statusBarHidden()
        #endif
    }
}

extension View {
    /// 全螢幕打開泡泡圖片(macOS 只為了 `swift test` 編譯，用 sheet)。
    func imageViewer(item: Binding<ViewerImage?>) -> some View {
        #if os(iOS)
        fullScreenCover(item: item) { ImageViewer(image: $0) }
        #else
        sheet(item: item) { ImageViewer(image: $0) }
        #endif
    }
}

// MARK: - 輸入列的附件

/// 輸入框裡的附件小卡(#352):圖片是 64pt 方形縮圖，檔案是圖示＋檔名＋大小;都可個別移除(送出中停用)。
struct AttachmentStrip: View {
    let model: ConversationModel
    /// accessibility identifier 的前綴(展開畫面用 `composer.expanded`)。
    var identifierPrefix = "composer"

    var body: some View {
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
                Image(systemName: "doc.fill")
                    .foregroundStyle(.tint)
                    .frame(width: 40, height: 40)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: attachment.displayName)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: Self.size(attachment))
                        .font(.caption)
                        .foregroundStyle(.secondaryText)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: 190, minHeight: 64, alignment: .leading)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
        }
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

    var body: some View {
        Button {
            if model.remainingImageSlots > 0 { showsPanel = true } else { model.noteImageLimit() }
        } label: {
            Image(systemName: "plus")
                .frame(width: 30, height: 30)
        }
        .composerCircleButtonStyle()
        .frame(minWidth: 44, minHeight: 44)
        .disabled(model.isSending || model.loadingFileName != nil)
        .accessibilityLabel(Text("Attach"))
        .accessibilityIdentifier(identifier)
        .sheet(isPresented: $showsPanel, onDismiss: presentNext) {
            AttachPanel(model: model, source: recentPhotos) { choice in
                next = choice
                showsPanel = false
            }
            .presentationDetents([.medium, .large])
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
        }
    }
}

/// 「＋」升起的面板:上方最近的照片(可多選)，下方相機、所有照片、檔案、貼上。沒有相簿權限時只有按鈕。
struct AttachPanel: View {
    enum Choice { case camera, library, files }

    let model: ConversationModel
    let source: RecentPhotoSource
    let choose: (Choice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var photos: [RecentPhoto] = []
    @State private var selected: [String] = []

    var body: some View {
        VStack(spacing: 16) {
            if !photos.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent Photos")
                        .font(.footnote)
                        .foregroundStyle(.secondaryText)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                        ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                            tile(photo, index: index)
                        }
                    }
                }
            }
            HStack(alignment: .top) {
                if ImageSources.cameraAvailable { action("Take Photo", symbol: "camera", id: "camera", .camera) }
                action("All Photos", symbol: "photo.on.rectangle", id: "photos", .library)
                if model.canAttachFiles { action("Files", symbol: "doc", id: "files", .files) }
                pasteTile
            }
            if !selected.isEmpty {
                Button {
                    addSelected()
                } label: {
                    Text("Add \(selected.count)")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .filledProminentButtonStyle()
                .accessibilityIdentifier("attach.add")
            }
            Spacer(minLength: 0)
        }
        .padding()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attach.panel")
        .task { photos = await source.recent(limit: 12) }
    }

    private func tile(_ photo: RecentPhoto, index: Int) -> some View {
        let isSelected = selected.contains(photo.id)
        return Button {
            if isSelected {
                selected.removeAll { $0 == photo.id }
            } else if selected.count < model.remainingImageSlots {
                selected.append(photo.id)
            } else {
                model.noteImageLimit()
            }
        } label: {
            ThumbnailImage(data: photo.thumbnail)
                .aspectRatio(1, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .tint)
                            .padding(4)
                    } else {
                        // 未選的圈:白色圈框加半透明黑底,在淺色與深色的照片上都 ≥ 3:1(非文字,#379)。
                        Circle()
                            .fill(.black.opacity(0.35))
                            .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                            .frame(width: 22, height: 22)
                            .padding(4)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.pressableThumbnail(cornerRadius: 8))
        .accessibilityLabel(Text("Photo \(index + 1)"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("attach.recent.\(index)")
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
        let ids = selected
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
