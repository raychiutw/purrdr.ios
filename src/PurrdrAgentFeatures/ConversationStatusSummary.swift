import Foundation
import PurrdrCore

/// 聊天狀態摘要(#347,spec #336):頂列、工作中膠囊、狀態 sheet、目前橫幅都從這一份讀，
/// 取代畫面各處各自判斷;每種資訊只出現在其中一處。只依輸入推導，不記任何狀態。
public struct ConversationStatusSummary: Equatable {
    /// 輸入框上方的工作中膠囊:停止鈕與停止進度、結果也在裡面;背景子 Agent 併進這裡。
    public struct Working: Equatable {
        /// 工作中指示的開始時間(經過時間從這裡起算)。
        public var since: Date?
        /// 有即時預覽(「Writing…」)。
        public var isWriting: Bool
        /// 停止進度或結果;一般工作中是 `nil`。
        public var stopPhase: StopPhase?
        /// 執行中的背景子 Agent 數。
        public var runningBackgroundAgents: Int
    }

    /// 點標題開出的狀態 sheet 的內容。
    public struct Sheet: Equatable {
        /// context 百分比與待辦。
        public var progress: AgentProgress
        /// 背景子 Agent 窗格;沒有時是 `nil`。
        public var backgroundAgents: AgentsPane?
        /// 這個對話有「做完再送」開關(開關在 sheet 裡，不在輸入列)。
        public var hasSendWhenDone: Bool
        /// 點標題一律打得開(context、待辦、背景子 Agent、開關都在裡面;沒有內容時 sheet 顯示空狀態)。
        public var isOpenable: Bool { true }
    }

    /// 目前唯一的一條提醒。
    public enum Banner: Equatable {
        /// 對話紀錄讀取問題(權限、失敗、不明確、被壓縮)。
        case transcript(ConversationModel.Banner)
        /// 這支裝置是唯讀。
        case readOnly
        /// 主機服務版本不足，說明已是畫面文字。
        case hostServiceUpdateRequired(String)
    }

    public var header: ConversationHeader
    /// 工作中膠囊;不需要時是 `nil`。
    public var working: Working?
    public var sheet: Sheet
    /// 目前橫幅，優先順序:對話紀錄 > 唯讀 > 主機服務版本。離線不顯示橫幅(#540):背景自動重連，頂列第二行說「重新連線中…」。
    public var banner: Banner?

    public init(
        header: ConversationHeader, banner: ConversationModel.Banner?, isOffline: Bool, isReadOnly: Bool,
        hostServiceUpdateMessage: String?, workingSince: Date?, stopPhase: StopPhase?,
        isWritingLive: Bool, progress: AgentProgress, agentsPane: AgentsPane?, hasSendWhenDone: Bool = false
    ) {
        self.header = header
        sheet = Sheet(progress: progress, backgroundAgents: agentsPane, hasSendWhenDone: hasSendWhenDone)
        // 與原本的停止列相同：唯讀、離線沒有;工作中或停止進度還在時才有。
        if !isReadOnly, !isOffline, header.status == .working || stopPhase != nil {
            working = Working(
                since: workingSince, isWriting: isWritingLive, stopPhase: stopPhase,
                runningBackgroundAgents: agentsPane?.rows.filter { $0.state == .running }.count ?? 0)
        }
        if let banner, banner != .offline {
            self.banner = .transcript(banner)
        } else if isReadOnly {
            self.banner = .readOnly
        } else if let hostServiceUpdateMessage {
            self.banner = .hostServiceUpdateRequired(hostServiceUpdateMessage)
        }
    }
}

/// 待送項目(#347):撤回倒數、離線佇列、做完再送是同一種「還沒送出」的訊息，畫面用同一個元件畫，標籤與動作依種類。
public struct PendingItem: Equatable, Identifiable {
    public enum Kind: Equatable {
        /// 撤回倒數中(還在本機)。
        case undoCountdown(remainingSeconds: Int)
        /// 離線排隊中，連上後補送。
        case offlineQueued
        /// 離線佇列裡沒有補送的訊息，附原因。
        case offlineProblem(QueuedPrompt.Problem)
        /// 做完再送;`position` 從 1 起算。
        case sendWhenDone(position: Int)
    }

    public var id: String
    public var text: String
    public var kind: Kind

    /// 依畫面順序：離線佇列、做完再送、撤回倒數。
    public static func items(queued: [QueuedPrompt], sendWhenDone: [SendWhenDoneItem], undo: UndoSendCountdown.Pending?) -> [PendingItem] {
        var items = queued.map {
            PendingItem(id: "queued-\($0.id.uuidString)", text: $0.text, kind: $0.problem.map(Kind.offlineProblem) ?? .offlineQueued)
        }
        items += sendWhenDone.enumerated().map {
            PendingItem(id: "sendWhenDone-\($0.element.id)", text: $0.element.text, kind: .sendWhenDone(position: $0.offset + 1))
        }
        if let undo {
            items.append(PendingItem(id: "undo", text: undo.text, kind: .undoCountdown(remainingSeconds: undo.remainingSeconds)))
        }
        return items
    }
}

extension ConversationModel {
    /// 聊天狀態摘要:畫面的頂列、工作中膠囊、狀態 sheet 與橫幅都讀它。
    public var statusSummary: ConversationStatusSummary {
        ConversationStatusSummary(
            header: header, banner: banner, isOffline: isOffline, isReadOnly: isReadOnly,
            hostServiceUpdateMessage: screenUpdateRequiredMessage, workingSince: workingSince,
            stopPhase: stopPhase, isWritingLive: livePreview != nil, progress: progress, agentsPane: agentsPane,
            hasSendWhenDone: sendWhenDone != nil)
    }

    /// 還沒送出的訊息，統一成一份清單。
    public var pendingItems: [PendingItem] {
        PendingItem.items(queued: queuedPrompts, sendWhenDone: sendWhenDone?.items ?? [], undo: undoSend?.pending)
    }
}
