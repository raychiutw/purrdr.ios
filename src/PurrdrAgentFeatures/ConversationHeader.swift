import Foundation
import PurrdrCore

/// 對話標題下一行的資訊(行為規格 F5.7;#44、G11)。只依輸入推導，不記任何狀態。
///
/// 狀態(字與點)永遠在最前面，其後以「 · 」串接：非選取中主機時的主機名、workspace 名稱(不同於標題時)、
/// agent 名稱、模型、「<effort> effort」、資料夾(不與 workspace 或標題重複時)。
/// 畫面寬度不夠時從後面整段拿掉，不截斷任何一段;VoiceOver 念 `accessibilityText`(完整內容)。
public struct ConversationHeader: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case offline
        case working
        case needsYou
        case done
        /// 連得上、agent 閒置或狀態不明。
        case online
    }

    public var status: Status
    public var segments: [String]

    public init(status: Status, segments: [String]) {
        self.status = status
        self.segments = segments
    }

    /// 畫面寬度不夠時依序嘗試的文字：最長的在前，每次從後面整段拿掉，最後只剩狀態。
    public var displayVariants: [String] {
        (0...segments.count).reversed().map { count in
            ([status.title] + segments.prefix(count)).joined(separator: " · ")
        }
    }

    /// 完整內容(VoiceOver)。
    public var accessibilityText: String {
        ([status.title] + segments).joined(separator: ", ")
    }

    package init(agent: Agent?, title: String, metadata: TranscriptMetadata, status: AgentStatus?, isOffline: Bool, hostName: String?) {
        self.status = if isOffline {
            .offline
        } else {
            switch status {
            case .working: .working
            case .blocked: .needsYou
            case .done: .done
            case .idle, .unknown, nil: .online
            }
        }
        var parts: [String] = []
        if let hostName, !hostName.isEmpty { parts.append(hostName) }
        let label = agent?.workspaceLabel
        if let label, !label.isEmpty, label != title { parts.append(label) }
        if let kind = agent?.kind { parts.append(AgentKind.displayName(kind) ?? kind) }
        if let model = metadata.model, !model.isEmpty { parts.append(TranscriptMetadata.displayName(ofModel: model)) }
        if let effort = metadata.effort, !effort.isEmpty { parts.append(String(localized: "\(effort) effort")) }
        if let folder = agent?.cwd.flatMap(HostPathSyntax.lastComponent).map(String.init), !folder.isEmpty,
           folder.lowercased() != label?.lowercased(), folder != title {
            parts.append(folder)
        }
        segments = parts
    }
}

extension ConversationHeader.Status {
    public var title: String {
        switch self {
        case .offline: String(localized: "Offline")
        // 與列表共用 Agent 狀態的狀態字。
        case .working: String(localized: AgentStatus.working.title)
        case .needsYou: String(localized: AgentStatus.blocked.title)
        case .done: String(localized: AgentStatus.done.title)
        case .online: String(localized: "Online")
        }
    }
}

/// 標題列的動作鈕：不在工作中「重新載入」,工作中「停止」(F5.7、F6.7)。
public enum HeaderAction: Equatable, Sendable {
    case reload
    case stop
}

/// 工作中指示的經過時間：「12s」「11m 43s」「1h 5m」(行為規格 F5.11)。
public enum WorkingElapsed {
    public static func text(seconds: Int) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }
}

/// 工作中指示的 3×3 點陣(行為規格 F5.11)。動畫時亮點沿對角線輪轉;Reduce Motion 時固定(HIG 20.2、20.4)。
public enum WorkingDots {
    public static let count = 9

    /// 第 `frame` 格畫面時各點的不透明度(由左上往右下)。
    public static func opacities(frame: Int, reduceMotion: Bool) -> [Double] {
        (0..<count).map { index in
            let diagonal = index / 3 + index % 3
            if reduceMotion { return diagonal.isMultiple(of: 2) ? 0.9 : 0.4 }
            // 對角線 0–4 共 5 條，每格亮一條，前後兩條半亮。
            let distance = abs(((frame % 5) + 5) % 5 - diagonal)
            return distance == 0 ? 1 : distance == 1 ? 0.55 : 0.25
        }
    }
}
