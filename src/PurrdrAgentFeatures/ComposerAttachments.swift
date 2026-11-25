import Foundation
import Observation
import PurrdrCore

/// 輸入列的附件 module(#562,延伸 ADR-0015):附件清單、背景準備(圖片縮圖、影片壓縮)、數量與大小上限、
/// 行動網路確認、逐檔上傳、草稿保存與送出後收尾,都收在這裡。
/// 聊天 model 只在送出時向它要路徑(`upload()`),並依安全送出的結果(`SafeSend.Result`)呼叫 `settle` 收尾。
///
/// **與安全送出的契約**:`SafeSend.Result.sentNothing` 為真(主機什麼都沒收到)⇔ 附件、手機副本與已上傳的路徑全部保留,
/// 重送不重傳;其餘結果(含「不確定」)都當作可能已送出,附件收尾。這條只在 `settle(sent:after:)` 判斷。
///
/// 需要聊天狀態的判斷(唯讀裝置)由呼叫端以參數帶入;要給使用者看的提示以 `takeNotice()` 取走。
@MainActor
@Observable
public final class ComposerAttachments {
    /// 一則最多幾個附件(圖片與檔案合計,#352)。
    public static let maximumCount = 10
    /// 影片大到行動網路上傳前要先提醒的大小(10 MiB)。
    public nonisolated static let cellularWarningBytes = 10 * 1024 * 1024

    /// 附加功能的依賴:上傳到主機、手機副本、檔名產生器、影片壓縮與網路狀態。
    public struct Dependencies: Sendable {
        public let uploader: any HostUploading
        public let store: any AttachmentStore
        public let makeName: @Sendable () -> UploadFileName
        /// 一般檔案(#286):原始檔名 → 上傳檔名。
        public let makeFileName: @Sendable (String) -> HostUploadName
        /// 影片壓縮(#474);`nil` 時沒有「影片」。
        public let videoCompressor: (any VideoCompressing)?
        /// 目前是不是只能用行動網路(大影片上傳前提醒用,#474)。
        public let isOnCellular: @Sendable () -> Bool

        public init(
            uploader: any HostUploading, store: any AttachmentStore,
            makeName: @escaping @Sendable () -> UploadFileName = Dependencies.randomName,
            makeFileName: @escaping @Sendable (String) -> HostUploadName = Dependencies.randomFileName,
            videoCompressor: (any VideoCompressing)? = nil, isOnCellular: @escaping @Sendable () -> Bool = { false }
        ) {
            self.uploader = uploader
            self.store = store
            self.makeName = makeName
            self.makeFileName = makeFileName
            self.videoCompressor = videoCompressor
            self.isOnCellular = isOnCellular
        }

        public static let randomName: @Sendable () -> UploadFileName = {
            var random = SystemRandomNumberGenerator()
            return UploadFileName.make(date: Date(), random: &random)
        }

        public static let randomFileName: @Sendable (String) -> HostUploadName = { original in
            var random = SystemRandomNumberGenerator()
            return HostUploadName.make(original: original, date: Date(), random: &random)
        }
    }

    /// 輸入列上的附件(送出被主機收下或可能收下時才清)。
    public private(set) var items: [ComposerAttachment] = []
    /// 正在讀取、準備加成附件的檔案(原始檔名);沒有時是 `nil`。
    public private(set) var loadingFileName: String?
    /// 影片準備中(取出、壓縮)的進度;沒有時是 `nil`。
    public private(set) var videoPreparation: VideoPreparation?
    /// 送出時上傳中的附件進度;沒有在上傳時是 `nil`。
    public private(set) var uploadProgress: UploadProgress?
    /// 等使用者確認的行動網路上傳提醒(這次要上傳的影片位元組數);沒有提醒時是 `nil`。
    public private(set) var cellularUploadWarning: Int?

    @ObservationIgnored private let dependencies: Dependencies?
    @ObservationIgnored private let drafts: DraftStore
    @ObservationIgnored private let chatKey: String
    @ObservationIgnored private var notice: SendNotice?
    @ObservationIgnored private var cellularConfirmed = false
    @ObservationIgnored private var videoTask: Task<VideoOutcome, Never>?
    /// 目前這一次準備的識別;取消或換新一次後,舊的結果回來(挑選器不回應取消)就丟掉。
    @ObservationIgnored private var videoToken: UUID?
    @ObservationIgnored private var uploadTask: Task<[String], any Error>?

    /// `dependencies` 為 `nil` 時不能附加任何東西(沒有上傳器的主機);有的話還原這個聊天上次留在草稿的附件。
    public init(dependencies: Dependencies?, drafts: DraftStore, chatKey: String) {
        self.dependencies = dependencies
        self.drafts = drafts
        self.chatKey = chatKey
        if dependencies != nil { items = drafts.attachments(chatKey: chatKey) }
    }

    // MARK: 狀態

    /// 這台主機能不能附加圖片(有上傳器;目前只有 Unix 主機)。
    public var isAvailable: Bool { dependencies != nil }
    public var remainingSlots: Int { max(0, Self.maximumCount - items.count) }
    public func canAttachFiles(isReadOnly: Bool) -> Bool { isAvailable && !isReadOnly }
    /// 能附加檔案、又有壓縮器。
    public func canAttachVideos(isReadOnly: Bool) -> Bool { canAttachFiles(isReadOnly: isReadOnly) && dependencies?.videoCompressor != nil }

    /// 取走最近一次操作要給使用者看的提示(取走後清掉)。
    public func takeNotice() -> SendNotice? {
        defer { notice = nil }
        return notice
    }

    /// 已滿時點「附加」:提示上限。
    public func noteLimit() { notice = .attachmentLimit }

    /// 泡泡裡的圖片檔名 → 手機上的副本(找不到是 `nil`)。
    public func localImage(named name: String) -> URL? {
        dependencies?.store.url(of: name)
    }

    private func persist() {
        drafts.saveAttachments(items, chatKey: chatKey)
    }

    // MARK: 圖片

    /// 加入圖片(相簿、相機、貼上):長邊縮到 2048px、JPEG,存手機副本。超過額度的部分、原始大小超過單張上限的不加入並提示。
    public func addImages(_ data: [Data]) async {
        guard let dependencies, !data.isEmpty else { return }
        if data.count > remainingSlots { notice = .attachmentLimit }
        for item in data.prefix(remainingSlots) {
            // 單張上限以使用者挑的原始圖片判斷，不因縮小而改變(#76)。
            guard item.count <= ImageUploadLimit.maximumSize else {
                notice = .imageTooLarge
                continue
            }
            let prepared = await Task.detached(priority: .userInitiated) { ImagePreparation.prepare(item) }.value
            guard let prepared, remainingSlots > 0 else {
                if prepared == nil { notice = .imageUnreadable }
                continue
            }
            let name = dependencies.makeName()
            do {
                try dependencies.store.save(prepared.jpeg, as: name.value)
            } catch {
                notice = .imageUnreadable
                continue
            }
            items.append(
                ComposerAttachment(
                    fileName: HostUploadName(name), byteCount: prepared.jpeg.count, pixelWidth: prepared.width, pixelHeight: prepared.height))
            persist()
        }
    }

    // MARK: 檔案

    /// 附加一般檔案:讀進來存手機副本、成一張附件卡,送出時才上傳(#352)。已知大小超過上限時不讀內容。
    /// 圖片檔(副檔名 png、jpg…)走圖片附件,與相簿一致。
    public func addFile(named originalName: String, size: Int?, isReadOnly: Bool, load: @Sendable () async throws -> Data) async {
        guard let dependencies, canAttachFiles(isReadOnly: isReadOnly), loadingFileName == nil else { return }
        guard remainingSlots > 0 else {
            notice = .attachmentLimit
            return
        }
        let limit = HostUploadLimit.maximumFileSize
        if let size, size > limit {
            notice = .fileTooLarge(size: size, limit: limit)
            return
        }
        loadingFileName = originalName
        defer { loadingFileName = nil }
        let data: Data
        do {
            data = try await load()
        } catch {
            notice = .fileUnreadable
            return
        }
        guard data.count <= limit else {
            notice = .fileTooLarge(size: data.count, limit: limit)
            return
        }
        if UploadedImages.hasImageExtension(originalName) {
            await addImages([data])
            return
        }
        guard remainingSlots > 0 else {
            notice = .attachmentLimit
            return
        }
        let name = dependencies.makeFileName(originalName)
        do {
            try dependencies.store.save(data, as: name.value)
        } catch {
            notice = .fileUnreadable
            return
        }
        items.append(ComposerAttachment(kind: .file, fileName: name, displayName: originalName, byteCount: data.count))
        persist()
    }

    /// 移除附件。呼叫端在送出(上傳)中不能呼叫。
    public func remove(_ id: String) {
        if let removed = items.first(where: { $0.id == id }), removed.kind == .file { removeStoredCopies(of: removed) }
        items.removeAll { $0.id == id }
        persist()
    }

    /// 刪掉檔案附件的手機副本(影片連縮圖)。
    private func removeStoredCopies(of attachment: ComposerAttachment) {
        dependencies?.store.remove(attachment.fileName.value)
        if let thumbnail = attachment.thumbnailFileName { dependencies?.store.remove(thumbnail) }
    }

    // MARK: 影片(#474)

    private enum VideoOutcome: Sendable {
        /// 已經搬進手機副本。
        case ready(fileName: HostUploadName, displayName: String, byteCount: Int, duration: TimeInterval?, thumbnailFileName: String?)
        case tooLong
        case unreadable
        case cancelled
    }

    /// 附加相簿影片(#474):沒超過上限就原樣加成附件卡;超過就由高到低壓縮,第一個放得下的畫質就是結果;
    /// 壓到最小仍超過、或太長,提示後不加入。與檔案一樣先留在輸入列,送出才上傳。可用 `cancelVideoPreparation()` 取消。
    /// 取出、壓縮與搬進手機副本都在背景做(最多 25 MiB 不佔主執行緒),副檔名依實際格式。
    public func addPickedVideo(displayName: String, isReadOnly: Bool, load: @escaping @Sendable () async throws -> VideoSourceFile) async {
        guard let dependencies, let compressor = dependencies.videoCompressor, canAttachFiles(isReadOnly: isReadOnly),
            videoPreparation == nil, loadingFileName == nil
        else { return }
        guard remainingSlots > 0 else {
            notice = .attachmentLimit
            return
        }
        videoPreparation = VideoPreparation(displayName: displayName, phase: .loading, fraction: nil)
        let token = UUID()
        videoToken = token
        let limit = HostUploadLimit.maximumFileSize
        let task = Task.detached { [weak self] () -> VideoOutcome in
            let picked: VideoSourceFile
            do { picked = try await load() } catch { return Task.isCancelled ? .cancelled : .unreadable }
            defer { try? FileManager.default.removeItem(at: picked.discard) }
            // 挑選器不回應取消:回來時已經取消就整個丟掉。
            if Task.isCancelled { return .cancelled }
            let source = picked.url
            do {
                let sourceSize = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if sourceSize <= limit {
                    let ext = source.pathExtension.lowercased()
                    return try await Self.storeVideo(
                        source, displayName: displayName, fileExtension: ext.isEmpty ? nil : ext, dependencies: dependencies, compressor: compressor)
                }
                let candidates = VideoQuality.candidates(forDuration: try await compressor.duration(of: source), limit: limit)
                await self?.setVideoPhase(.shrinking, token: token)
                for quality in candidates {
                    let output = FileManager.default.temporaryDirectory.appending(path: "purrdr-video-\(UUID().uuidString).mp4")
                    defer { try? FileManager.default.removeItem(at: output) }
                    try await compressor.compress(source, quality: quality, to: output) { fraction in
                        Task { @MainActor in self?.setVideoFraction(fraction, token: token) }
                    }
                    let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
                    if size <= limit {
                        if Task.isCancelled { return .cancelled }
                        return try await Self.storeVideo(
                            output, displayName: displayName, fileExtension: "mp4", dependencies: dependencies, compressor: compressor)
                    }
                }
                return .tooLong
            } catch {
                return Task.isCancelled || error is CancellationError ? .cancelled : .unreadable
            }
        }
        videoTask = task
        let outcome = await task.value
        // 取消(或已經換成新的一次)後回來的結果:不加入,已搬進副本的刪掉。
        guard videoToken == token else {
            if case .ready(let fileName, _, _, _, let thumbnail) = outcome {
                dependencies.store.remove(fileName.value)
                if let thumbnail { dependencies.store.remove(thumbnail) }
            }
            return
        }
        videoTask = nil
        videoToken = nil
        videoPreparation = nil
        switch outcome {
        case .cancelled: break
        case .tooLong: notice = .videoTooLong
        case .unreadable: notice = .videoUnreadable
        case .ready(let fileName, let name, let byteCount, let duration, let thumbnail):
            guard remainingSlots > 0 else {
                dependencies.store.remove(fileName.value)
                if let thumbnail { dependencies.store.remove(thumbnail) }
                notice = .attachmentLimit
                return
            }
            items.append(
                ComposerAttachment(
                    kind: .file, fileName: fileName, displayName: name, byteCount: byteCount, duration: duration, thumbnailFileName: thumbnail))
            persist()
        }
    }

    /// 把影片檔搬進手機副本(背景)。`fileExtension` 是實際格式,沒有就沿用顯示名稱的。
    private nonisolated static func storeVideo(
        _ file: URL, displayName: String, fileExtension: String?, dependencies: Dependencies, compressor: any VideoCompressing
    ) async throws -> VideoOutcome {
        var name = displayName
        if let fileExtension { name = (displayName as NSString).deletingPathExtension + "." + fileExtension }
        let byteCount = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let uploadName = dependencies.makeFileName(name)
        // 長度與縮圖在搬走檔案之前取(取不到就沒有,卡片照常顯示)。
        let duration = try? await compressor.duration(of: file)
        var thumbnailName: String?
        if let thumbnail = await compressor.thumbnail(of: file) {
            let stem = (uploadName.value as NSString).deletingPathExtension
            if (try? dependencies.store.save(thumbnail, as: stem + "-thumb.jpg")) != nil { thumbnailName = stem + "-thumb.jpg" }
        }
        do {
            try dependencies.store.save(movingFile: file, as: uploadName.value)
        } catch {
            if let thumbnailName { dependencies.store.remove(thumbnailName) }
            throw error
        }
        return .ready(fileName: uploadName, displayName: name, byteCount: byteCount, duration: duration, thumbnailFileName: thumbnailName)
    }

    private func setVideoPhase(_ phase: VideoPreparation.Phase, token: UUID) {
        guard videoToken == token else { return }
        videoPreparation?.phase = phase
    }

    private func setVideoFraction(_ fraction: Double, token: UUID) {
        guard videoToken == token else { return }
        videoPreparation?.fraction = fraction
    }

    /// 取消影片準備(取出或壓縮中):立刻恢復輸入列;不加入、不提示,暫存檔刪掉。
    public func cancelVideoPreparation() {
        videoTask?.cancel()
        videoTask = nil
        videoToken = nil
        videoPreparation = nil
    }

    // MARK: 行動網路確認(#474)

    /// 送出前呼叫:行動網路上有還沒上傳的大影片、而且這次還沒確認,就設好提醒並回傳 `true`(呼叫端停下來等使用者)。
    public func requestCellularConfirmation() -> Bool {
        guard !cellularConfirmed, let dependencies, dependencies.isOnCellular() else { return false }
        let pending = items.filter { $0.uploadedPath == nil && $0.duration != nil }
        guard pending.contains(where: { $0.byteCount >= Self.cellularWarningBytes }) else { return false }
        cellularUploadWarning = pending.reduce(0) { $0 + $1.byteCount }
        return true
    }

    /// 使用者確認用行動網路上傳:清掉提醒,到 `endConfirmedUpload()` 之前這一次不再問。
    public func beginConfirmedUpload() {
        cellularUploadWarning = nil
        cellularConfirmed = true
    }

    public func endConfirmedUpload() { cellularConfirmed = false }

    public func dismissCellularWarning() { cellularUploadWarning = nil }

    // MARK: 送出

    /// 取消送出時的上傳(使用者按取消):附件留著。SSH 主機上的暫存檔因連線提早結束而刪掉。
    public func cancelUpload() { uploadTask?.cancel() }

    /// 依序上傳還沒上傳的附件(已上傳的沿用路徑),回傳與 `items` 同順序的主機路徑。
    /// 任何一個失敗丟出那個錯誤:整則不送(F6.5);附件與已上傳的路徑留著。取消丟 `CancellationError`。
    public func upload() async throws -> [String] {
        let task = Task { try await self.uploadPending() }
        uploadTask = task
        defer { uploadTask = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func uploadPending() async throws -> [String] {
        guard let dependencies else {
            guard items.isEmpty else { throw HostServiceError.unsupported("upload") }
            return []
        }
        var paths: [String] = []
        for index in items.indices {
            if let path = items[index].uploadedPath {
                paths.append(path)
                continue
            }
            let name = items[index].fileName
            guard let url = dependencies.store.url(of: name.value) else { throw CocoaError(.fileReadNoSuchFile) }
            // 分塊讀檔上傳(影片最多 25 MiB,不整份進記憶體),回報進度。
            let source = try HostUploadSource.file(at: url)
            uploadProgress = UploadProgress(displayName: items[index].displayName, fraction: 0)
            defer { uploadProgress = nil }
            let path = try await dependencies.uploader.upload(source, named: name) { [weak self] fraction in
                Task { @MainActor in self?.uploadProgress?.fraction = fraction }
            }
            if let current = items.firstIndex(where: { $0.fileName == name }) {
                items[current].uploadedPath = path
            }
            paths.append(path)
        }
        persist()
        return paths
    }

    /// 主機服務太舊時提示更新,其他失敗是 `.uploadFailed`。
    public static func notice(forUploadError error: any Error) -> SendNotice {
        guard case .hostServiceUpdateRequired(_, let installedVersion)? = error as? HostServiceError else { return .uploadFailed }
        return .hostServiceUpdateRequired(installedVersion: installedVersion)
    }

    /// 安全送出之後收尾(與 `SafeSend` 的契約):主機什麼都沒收到就保留全部附件(已上傳的不重傳);
    /// 其餘結果(含不確定)把這次送出的附件移出清單、刪掉檔案附件的手機副本。送出期間新加的附件不動。
    public func settle(sent: [ComposerAttachment], after result: SafeSend.Result) {
        guard !result.sentNothing else { return }
        items.removeAll { attachment in sent.contains { $0.fileName == attachment.fileName } }
        for attachment in sent where attachment.kind == .file { removeStoredCopies(of: attachment) }
        persist()
    }
}
