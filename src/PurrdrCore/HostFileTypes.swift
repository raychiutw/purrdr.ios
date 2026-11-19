// 主機檔案的領域型別(路徑、版本、狀態、變更);經主機通道讀寫的實作在 PurrdrSSH 的 `HostFiles`。
import Foundation

/// 主機上的一個檔案路徑，相對於家目錄(例如 `.claude/settings.json`)。
public struct HostPath: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let relative: String

    public init(_ relative: String) { self.relative = relative }
    public init(stringLiteral value: String) { self.init(value) }
    public var description: String { "~/" + relative }
}

/// 讀到的檔案版本：主機上 `cksum` 的結果(CRC 與大小)。只用來比對「讀取之後有沒有被改過」。
public struct HostFileVersion: Hashable, Sendable {
    public let checksum: String
    public init(checksum: String) { self.checksum = checksum }
}

/// 主機上一個檔案的狀態。
public enum HostFileState: Equatable, Sendable {
    /// 不存在，但所在的資料夾存在。
    case missing
    /// 不存在，連所在的資料夾也不存在。
    case missingDirectory
    case file(Data, version: HostFileVersion)
    /// 是資料夾、FIFO、裝置等，不是一般檔案(讀 FIFO 會卡住 SSH,行為規格 R-F03)。
    case notRegularFile
    case unreadable
    case tooLarge

    public var contents: Data? {
        if case .file(let data, _) = self { return data }
        return nil
    }
}

/// 一次讀取的結果。
public struct HostFileRead: Equatable, Sendable {
    /// 執行指令的主機使用者(同意畫面要說明「以哪個使用者」修改)。
    public var user: String
    public var files: [HostPath: HostFileState]
    /// 家目錄的絕對路徑(分隔符號一律 `/`)。只有 Windows 主機的腳本回報(`C:/Users/<帳號>`),POSIX 主機是 `nil`。
    public var home: String?
    /// 回報這份結果的腳本是哪種作業系統的:Windows 版(`WindowsScripts`)是 `.windows`;POSIX 版分不出 macOS／Linux,是 `nil`。
    public var operatingSystem: HostOperatingSystem?
    /// 條件式讀取時，版本與已知版本相同、沒回傳內容的檔案(不在 `files` 裡)。
    public var unchanged: Set<HostPath>

    public init(user: String, files: [HostPath: HostFileState], home: String? = nil, operatingSystem: HostOperatingSystem? = nil,
                unchanged: Set<HostPath> = []) {
        self.user = user
        self.files = files
        self.home = home
        self.operatingSystem = operatingSystem
        self.unchanged = unchanged
    }

    /// 主機是 Windows。
    public var isWindows: Bool { operatingSystem == .windows }

    public subscript(path: HostPath) -> HostFileState? { files[path] }
}

/// 條件式讀取的結果：檔案與已知版本相同，或變了(新的值與版本;不是一般檔案時版本是 `nil`)。
public enum HostFileUpdate<Value: Sendable>: Sendable {
    case unchanged
    case changed(Value, version: HostFileVersion?)
}

extension HostFileUpdate: Equatable where Value: Equatable {}

/// 寫入前對檔案目前版本的預期。
public enum HostFileExpectation: Equatable, Sendable {
    /// 不管目前是什麼(只用在 Purrdr 自己的檔案)。
    case anything
    case missing
    case version(HostFileVersion)
}

/// 一個檔案變更。
public enum HostFileChange: Equatable, Sendable {
    case write(HostPath, Data, executable: Bool = false, expecting: HostFileExpectation)
    case delete(HostPath, expecting: HostFileExpectation)
    /// 移除 Purrdr 自己的資料夾(必須在 `.purrdr/` 底下);`.purrdr` 因此變空時一起移除。
    case removeDirectory(HostPath)
    /// 建立一個原本不存在的資料夾(例如 Codex 啟動器的 `~/.local/bin`)。已經存在 → 整批不寫(`changedSinceRead`)。
    /// 同一批之後寫在它底下的檔案視為資料夾存在。
    case makeDirectory(HostPath)
    /// 資料夾是空的才移除(還原時拿掉自己建的資料夾);使用者後來放了東西就保留，不算失敗。
    case removeEmptyDirectory(HostPath)

    public var path: HostPath {
        switch self {
        case .write(let path, _, _, _), .delete(let path, _), .removeDirectory(let path), .makeDirectory(let path), .removeEmptyDirectory(let path): path
        }
    }
}

public enum HostFilesError: Error, Equatable {
    /// 路徑必須相對於家目錄、不含 `..`、只用安全字元。
    case invalidPath(String)
    /// 指令(含 base64 內容)超過 sshd 單一參數的上限(行為規格 §3.2)。
    case tooLarge
    /// 讀取之後檔案被改過(或預期不存在卻存在):整批都沒寫。
    case changedSinceRead(HostPath)
    /// 要寫的檔案所在的資料夾不存在(只有 `.purrdr/` 底下會自動建立;其他地方要同一批先 `makeDirectory`)。
    case missingDirectory(HostPath)
    /// 主機上的輸出不是預期的格式。
    case malformedOutput
    /// 主機腳本失敗(非零 exit)。
    case failed(exitCode: Int32, message: String)

    /// 通道結束卻沒有結束狀態(例如斷線)時 `failed` 帶的 exit code。
    public static let unknownExitCode: Int32 = -1
}

extension HostFileChange {
    package func validate() throws {
        try path.validate()
        if case .removeDirectory(let path) = self, !path.relative.hasPrefix(".purrdr/") { throw HostFilesError.invalidPath(path.relative) }
    }

    /// 主機腳本的參數：每個變更固定五個(種類、路徑、預期、base64 內容、是否可執行)。
    package var scriptArguments: [String] {
        switch self {
        case .write(let path, let data, let executable, let expectation):
            ["put", path.relative, expectation.scriptArgument, data.base64EncodedString(), executable ? "1" : "0"]
        case .delete(let path, let expectation):
            ["del", path.relative, expectation.scriptArgument, "", "0"]
        case .removeDirectory(let path):
            ["rmtree", path.relative, "any", "", "0"]
        case .makeDirectory(let path):
            ["mkdir", path.relative, "missing", "", "0"]
        case .removeEmptyDirectory(let path):
            ["rmdir", path.relative, "any", "", "0"]
        }
    }
}

extension HostFileExpectation {
    var scriptArgument: String {
        switch self {
        case .anything: "any"
        case .missing: "missing"
        case .version(let version): version.checksum
        }
    }
}

extension HostPath {
    /// 只接受家目錄底下、由安全字元組成的相對路徑。這些路徑會原樣交給主機腳本。
    package func validate() throws {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/")
        let segments = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, relative.allSatisfy(allowed.contains),
              segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw HostFilesError.invalidPath(relative) }
    }
}
