import Foundation
import Observation
import PurrdrCore

/// 聊天裡的跨聊天「需要你」通知(#528、#529):使用者在某個聊天時，別的聊天的 Agent 停下來等他，要讓他知道。
///
/// 輸入是合併 Agent 列表(所有主機，不受主機篩選)的快照、目前開著的聊天與靜音清單;
/// 呼叫端只碰輸出：`others`(返回鈕小點、列表段落)、`latest`(列表的「剛剛」)、`banner`(頂部橫幅)與 `dismiss()`。
///
/// 規則：
/// - 只有「從別的狀態變成需要你」(`effectiveStatus == .blocked`)才觸發橫幅;
///   一台主機第一次拿到快照時已經需要你的，只進 `others`、不觸發。
/// - 目前開著的聊天不算(不進 `others`、不觸發);靜音的聊天都不算。
/// - 收起後同一個轉變不再出現;新的轉變進來時橫幅換成它;離開需要你的聊天從所有輸出移除。
/// - 「變成需要你的時間」只存記憶體。
@MainActor
@Observable
public final class NeedsYouNotifications {
    /// 一個需要你的聊天。
    public struct Chat: Equatable, Sendable {
        public var route: ChatRoute
        /// 變成需要你(或第一次看到它需要你)的時間。
        public var since: Date
        /// 是不是「看著它變成需要你」的轉變(第一次快照就已經需要你的不是);列表的「剛剛」只標轉變的。
        public var isTransition: Bool
        fileprivate var order: Int
        fileprivate var isDismissed: Bool
    }

    /// 頂部橫幅:最新觸發的聊天與目前需要你的聊天總數(含它)。
    public struct Banner: Equatable, Sendable {
        public var chat: ChatRoute
        public var total: Int
        public init(chat: ChatRoute, total: Int) {
            self.chat = chat
            self.total = total
        }
    }

    /// 一台主機的輸入:哪些聊天需要你(與它的 session,看靜音)。
    package struct HostInput: Equatable, Sendable {
        package var host: HostSelection
        package var blocked: [Blocked]
        package struct Blocked: Equatable, Sendable {
            package var paneID: String
            package var isMuted: Bool
            package init(paneID: String, isMuted: Bool) {
                self.paneID = paneID
                self.isMuted = isMuted
            }
        }
        package init(host: HostSelection, blocked: [Blocked]) {
            self.host = host
            self.blocked = blocked
        }
    }

    package struct Input: Equatable, Sendable {
        /// 已經拿到快照的主機(沒有快照的不列入)。
        package var hosts: [HostInput]
        package var current: Set<ChatRoute>
        package init(hosts: [HostInput], current: Set<ChatRoute>) {
            self.hosts = hosts
            self.current = current
        }
    }

    /// 除了目前聊天之外需要你的聊天，新變成需要你的在前。
    public private(set) var others: [Chat] = []
    /// 最新「轉變」成需要你的聊天(列表標「剛剛」);沒有轉變的就是 `nil`。
    public var latest: Chat? { others.first { $0.isTransition } }
    /// 要顯示的橫幅;沒有或收起後是 `nil`。
    public var banner: Banner? {
        guard let newest = others.first, !newest.isDismissed, newest.isTransition else { return nil }
        return Banner(chat: newest.route, total: others.count)
    }

    /// 收起橫幅:目前需要你的聊天都不再觸發橫幅,之後有新的轉變才再出現。
    public func dismiss() {
        for index in others.indices { others[index].isDismissed = true }
        dismissed.formUnion(others.map(\.route))
    }

    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var seenHosts: Set<HostSelection> = []
    /// 目前還需要你的聊天的紀錄(含被目前聊天或靜音排除的,離開需要你才刪)。
    @ObservationIgnored private var tracked: [ChatRoute: Chat] = [:]
    @ObservationIgnored private var dismissed: Set<ChatRoute> = []
    @ObservationIgnored private var nextOrder = 0

    public init(now: @escaping @MainActor () -> Date = { Date() }) {
        self.now = now
    }

    /// 套用一份輸入(測試與 `run` 共用)。
    package func apply(_ input: Input) {
        var blockedNow: Set<ChatRoute> = []
        var muted: Set<ChatRoute> = []
        for host in input.hosts {
            let isFirstSnapshot = seenHosts.insert(host.host).inserted
            for item in host.blocked {
                let route = ChatRoute(host: host.host, paneID: item.paneID)
                blockedNow.insert(route)
                if item.isMuted { muted.insert(route) }
                guard tracked[route] == nil else { continue }
                // 第一次出現:這台主機的第一份快照就已經需要你的不算轉變。
                let transition = !isFirstSnapshot && !input.current.contains(route) && !item.isMuted
                tracked[route] = Chat(
                    route: route, since: now(), isTransition: transition, order: nextOrder, isDismissed: false)
                nextOrder += 1
            }
        }
        // 離開需要你(含這台主機不再有快照以外的消失):從紀錄移除,下次再變成需要你是新的轉變。
        // 沒有快照的主機(斷線)保留它的紀錄,避免重連時被當成新轉變。
        let reporting = Set(input.hosts.map(\.host))
        for route in Array(tracked.keys) where reporting.contains(route.host) && !blockedNow.contains(route) {
            tracked[route] = nil
            dismissed.remove(route)
        }
        others = tracked.values
            .filter { !input.current.contains($0.route) && !muted.contains($0.route) && reporting.contains($0.route.host) }
            .map { chat in
                var chat = chat
                chat.isDismissed = dismissed.contains(chat.route)
                return chat
            }
            .sorted { ($0.since, $0.order) > ($1.since, $1.order) }
    }

    /// 跟著合併列表的快照、目前聊天與靜音變化，直到所在的 task 被取消。
    public func run(observing merged: MergedAgentListModel) async {
        for await input in Observations({ merged.needsYouInput }) {
            apply(input)
        }
    }
}

extension MergedAgentListModel {
    /// 「需要你通知」的輸入:所有主機(不受主機篩選)需要你的聊天、目前開著的聊天、靜音清單。
    package var needsYouInput: NeedsYouNotifications.Input {
        NeedsYouNotifications.Input(
            hosts: sources.compactMap { source in
                guard let snapshot = source.list.snapshot else { return nil }
                let muted = source.actions.preferences.muted
                return NeedsYouNotifications.HostInput(
                    host: source.host,
                    blocked: snapshot.agents.filter { $0.effectiveStatus == .blocked }.map {
                        .init(paneID: $0.paneID, isMuted: $0.sessionID.map(muted.contains) ?? false)
                    })
            },
            current: visibleChats)
    }
}
