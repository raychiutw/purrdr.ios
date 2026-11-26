import Foundation

/// herdr 回報的 session 參照:id 或路徑。
public enum TranscriptReference: Sendable, Equatable, Hashable {
    case id(String)
    case path(String)

    public var value: String {
        switch self {
        case .id(let value), .path(let value): value
        }
    }
}

/// 對話紀錄在主機上的位置:位置規則加 herdr 回報的參照(核心的主機連線只認得這個通用的定位請求)。
public struct TranscriptLocation: Sendable, Equatable, Hashable {
    public var locator: TranscriptLocator
    public var reference: TranscriptReference
    /// Agent 的工作資料夾(只有 `usesProjectFolder` 的位置規則用)。
    public var cwd: String

    public init(locator: TranscriptLocator, reference: TranscriptReference, cwd: String = "") {
        self.locator = locator
        self.reference = reference
        self.cwd = cwd
    }

    /// 主機服務協定的 session 參照。
    public var sessionReference: HostServiceProtocol.SessionReference {
        switch reference {
        case .id(let id): .init(kind: "id", value: id)
        case .path(let path): .init(kind: "path", value: path)
        }
    }

    /// 這個位置的 id 或路徑是否安全到可以交給主機(R-I12:不安全就拒絕，不進 shell)。
    package var isSafe: Bool {
        switch reference {
        case .id(let id): ClaudeTranscript.isSafeSessionID(id)
        case .path(let path): TranscriptReader.isValidPath(path)
        }
    }
}

/// 要讀的對話紀錄：方言與位置。由 herdr 回報的 session 參照決定，**永不猜檔**(R-I02)。
public struct TranscriptTarget: Sendable, Equatable, Hashable {
    public var dialect: TranscriptDialect
    public var location: TranscriptLocation
    /// 聊天的身分(R-I01):herdr 回報的 session 參照值(id 或路徑)。改變就是另一個聊天。
    public var sessionKey: String

    public init(dialect: TranscriptDialect, location: TranscriptLocation, sessionKey: String) {
        self.dialect = dialect
        self.location = location
        self.sessionKey = sessionKey
    }
}

extension Agent {
    /// 這個 Agent 的對話紀錄;還不知道是哪個 session、參照不安全或這種 agent 沒有可讀的對話紀錄時為 `nil`。
    ///
    /// - kind `id`:必須是安全字元(`^[A-Za-z0-9-]+$`),不符合就拒絕而不是引號化(R-I12)。
    /// - kind `path`:只有設定檔接受路徑參照的 Agent(agy、Pi、OMP),且必須是絕對、`.jsonl` 結尾、沒有 `..` 段與 NUL／CR／LF 的路徑(§4.0)。
    public var transcriptTarget: TranscriptTarget? {
        guard let dialect = AgentCatalog.profile(forHerdrName: kind).transcript, let session else { return nil }
        guard let location = dialect.location(kind: session.kind, value: session.value, cwd: cwd ?? ""), location.isSafe else { return nil }
        return TranscriptTarget(dialect: dialect, location: location, sessionKey: session.value)
    }
}
