import Foundation
import PurrdrAgentFeatures

/// 安裝 Objective-C 未捕捉例外處理器:中止前交給 `CrashReporter` 寫標記,再轉呼叫原本的處理器。
/// 處理器是 C 函式指標、不能捕捉變數,所以用全域狀態(只在啟動時設定一次)。
public enum CrashExceptionHandler {
    nonisolated(unsafe) private static var reporter: CrashReporter?
    nonisolated(unsafe) private static var previous: (@convention(c) (NSException) -> Void)?

    @MainActor
    public static func install(_ reporter: CrashReporter) {
        guard Self.reporter == nil else { return }
        Self.reporter = reporter
        previous = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            CrashExceptionHandler.reporter?.exceptionWillTerminate(name: exception.name.rawValue, reason: exception.reason)
            CrashExceptionHandler.previous?(exception)
        }
    }
}

/// 待處理閃退標記檔(`pending-crash.json`):中止前的處理器直接同步寫,不經佇列(下次啟動即刪除)。
public final class FileCrashMarkerStore: CrashMarkerStoring, @unchecked Sendable {
    public static let fileName = "pending-crash.json"
    /// 安裝時先建好資料夾與路徑字串,處理器裡只做一次寫檔。
    private let path: String

    public init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent(Self.fileName).path
    }

    public static func applicationSupport() -> FileCrashMarkerStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return FileCrashMarkerStore(directory: base)
    }

    public func write(_ data: Data) {
        _ = FileManager.default.createFile(atPath: path, contents: data)
    }

    public func read() -> Data? { FileManager.default.contents(atPath: path) }

    public func remove() { try? FileManager.default.removeItem(atPath: path) }
}

#if os(iOS)
extension CrashExceptionHandler {
    /// 啟動時呼叫:先把上次留下的待處理閃退標記轉成記錄,再安裝例外處理器。
    @MainActor
    public static func installAtLaunch(recorder: DiagnosticRecorder) {
        let reporter = CrashReporter(
            store: FileCrashMarkerStore.applicationSupport(), environment: .current)
        reporter.recoverPending(into: recorder)
        install(reporter)
    }
}

extension DiagnosticRecorder {
    /// UI 測試旗標 `-uiTestingCrashRecord`:預放一筆「上次異常結束」的閃退記錄。
    /// 時間固定,重新啟動後還是同一筆(才測得出「已提示過就不再提示」)。
    public func recordUITestingCrash() {
        recordCrash(CrashRecord(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), name: "NSInternalInconsistencyException", reasonHash: DiagnosticHash.reason("UI testing"),
            environment: .current))
    }
}
#endif
