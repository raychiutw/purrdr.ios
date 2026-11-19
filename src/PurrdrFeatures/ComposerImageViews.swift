import PhotosUI
import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI
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

/// 輸入框上方的縮圖：64pt 方塊，可移除(上傳中停用)。
struct AttachmentStrip: View {
    let model: ConversationModel
    /// accessibility identifier 的前綴(展開畫面用 `composer.expanded`)。
    var identifierPrefix = "composer"

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(model.attachments.enumerated()), id: \.element.id) { index, attachment in
                    thumbnail(attachment, index: index)
                }
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(identifierPrefix).attachments")
    }

    private func thumbnail(_ attachment: ComposerAttachment, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let url = model.localImage(named: attachment.fileName.value) {
                    BubbleImageCache.image(at: url).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 64)
            .background(.fill.tertiary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                if model.isSending && attachment.uploadedPath == nil {
                    ProgressView()
                        .frame(width: 64, height: 64)
                        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text("Attached image \(index + 1)"))
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
            .accessibilityLabel(Text("Remove Image \(index + 1)"))
            .accessibilityIdentifier("\(identifierPrefix).attachment.remove.\(index)")
        }
        .padding(.top, 8)
        .padding(.trailing, 8)
    }
}

// MARK: - 加入圖片

/// 「加入圖片」(HIG 20.6:照片 symbol、系統 out-of-process PhotosPicker,不要求相簿權限)。
///
/// 點一下：滿 4 張 → 提示;剪貼簿有圖 → 先問「相簿／貼上圖片」;否則直接開相簿(#37 故事 34)。
/// 長按：完整選單(相簿、拍照、貼上圖片)。
struct AddImageButton: View {
    let model: ConversationModel
    var identifier = "composer.addImage"
    /// 放在輸入列的玻璃卡片裡(#187):不再疊玻璃。
    var isInCard = false
    @State private var showsLibrary = false
    @State private var showsCamera = false
    @State private var asksSource = false
    @State private var selection: [PhotosPickerItem] = []

    var body: some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { open(.library) }
            if ImageSources.cameraAvailable {
                Button("Take Photo", systemImage: "camera") { open(.camera) }
            }
            if ImageSources.pasteboardHasImages {
                Button("Paste Image", systemImage: "doc.on.clipboard") { open(.paste) }
            }
        } label: {
            Image(systemName: "photo.badge.plus")
                .frame(width: 30, height: 30)
        } primaryAction: {
            switch ComposerPaste.addImageAction(pasteboardHasImages: ImageSources.pasteboardHasImages, remainingSlots: model.remainingImageSlots) {
            case .openLibrary: showsLibrary = true
            case .askSource: asksSource = true
            case .showLimit: model.noteImageLimit()
            }
        }
        .composerSecondaryButtonStyle(isInCard: isInCard)
        .buttonBorderShape(.circle)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(model.isSending)
        .accessibilityLabel(Text("Add Image"))
        .accessibilityIdentifier(identifier)
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
        .confirmationDialog("Add Image", isPresented: $asksSource, titleVisibility: .hidden) {
            Button("Photo Library") { open(.library) }
            Button("Paste Image") { open(.paste) }
            if ImageSources.cameraAvailable {
                Button("Take Photo") { open(.camera) }
            }
            Button("Cancel", role: .cancel) {}
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

    private enum Source { case library, camera, paste }

    private func open(_ source: Source) {
        guard model.remainingImageSlots > 0 else {
            model.noteImageLimit()
            return
        }
        switch source {
        case .library: showsLibrary = true
        case .camera: showsCamera = true
        case .paste:
            let images = ImageSources.pasteboardImages()
            Task { await model.addImages(images) }
        }
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
