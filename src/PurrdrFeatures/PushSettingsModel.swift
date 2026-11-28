import Foundation
import Observation
import PurrdrCore

/// 某台主機判斷通知種類能不能開所需的資訊。
public struct PushKindContext: Sendable, Equatable {
    /// HTTPS 主機(經主機服務);`false` 是 SSH 主機。
    public var installsViaHostService: Bool
    /// HTTPS 主機回報的主機服務版本;還沒連上是 `nil`(不擋)。
    public var hostServiceVersion: HostServiceVersion?
    /// SSH 主機已安裝的外掛版本;app 目前讀不到,是 `nil`(不擋)。
    public var pluginVersion: HostServiceVersion?

    public init(installsViaHostService: Bool, hostServiceVersion: HostServiceVersion? = nil, pluginVersion: HostServiceVersion? = nil) {
        self.installsViaHostService = installsViaHostService
        self.hostServiceVersion = hostServiceVersion
        self.pluginVersion = pluginVersion
    }

    /// 沒有額外資訊時用:SSH 主機。
    public static let ssh = PushKindContext(installsViaHostService: false)
}

/// 畫面上的一個通知種類開關:名稱、說明(依手機語言)與在這台主機能不能開。
public struct PushKindChoice: Identifiable, Equatable {
    public var kind: PushKind
    public var title: String
    public var details: String
    public var availability: PushKindAvailability

    public var id: String { kind.rawValue }
}

extension PushKindCatalog {
    /// app 內建備援:舊後台沒有清單 API、離線或還沒讀到時用;就是 0.55 以前寫死的五種(「完成」預設開,與以前一樣)。
    /// 文字是資料(與後台給的同形狀,兩種語言都在),不是畫面字串。
    public static let builtIn = PushKindCatalog(
        definitions: [
            PushKindDefinition(
                kind: .blocked, name: .init(english: "Needs You", traditionalChinese: "需要你"),
                description: .init(english: "An agent is waiting for your answer or approval.", traditionalChinese: "Agent 在等你回答或核准。"),
                defaultOn: true, order: 10),
            PushKindDefinition(
                kind: .done, name: .init(english: "Finished", traditionalChinese: "完成"),
                description: .init(english: "An agent finished its work.", traditionalChinese: "Agent 做完了。"),
                defaultOn: true, order: 20),
            PushKindDefinition(
                kind: .stuck, name: .init(english: "May Be Stuck", traditionalChinese: "可能卡住"),
                description: .init(english: "An agent seems to have stopped making progress.", traditionalChinese: "Agent 好像沒有進展了。"),
                defaultOn: false, transports: [.https], minServiceVersion: HostServiceFeature.agentObserver.minimumVersion, order: 30),
            PushKindDefinition(
                kind: .reminder, name: .init(english: "Still Waiting for You", traditionalChinese: "仍在等你"),
                description: .init(english: "A reminder when an agent has been waiting for you for a while.", traditionalChinese: "Agent 等你一陣子了,再提醒一次。"),
                defaultOn: false, transports: [.https], minServiceVersion: HostServiceFeature.agentObserver.minimumVersion, order: 40),
            PushKindDefinition(
                kind: .hostService, name: .init(english: "Host Service", traditionalChinese: "主機服務"),
                description: .init(english: "Updates to the host service on this computer.", traditionalChinese: "這台電腦上的主機服務有更新。"),
                defaultOn: false, transports: [.https], order: 50),
        ],
        source: .builtIn)
}

/// 通知設定(ADR-0016、#705):讀後台的種類清單與這支裝置的配對,照清單畫每台主機的開關,配對的種類以後台為準。
///
/// 讀不到(離線、舊後台沒有清單 API、後台回壞資料)時退回 app 內建的五種與本機記錄,整頁不空白、不擋住。
/// 後台新增的種類(app 不認得的代號)照樣顯示,名稱與說明用後台給的。
@MainActor
@Observable
public final class PushSettingsModel {
    public private(set) var catalog: PushKindCatalog = .builtIn
    /// 上次讀種類清單失敗的原因(只供診斷;畫面不顯示,因為有備援)。
    public private(set) var lastLoadFailure: (any Error)?

    @ObservationIgnored private weak var service: PushService?
    @ObservationIgnored package var preferredLanguages: @MainActor () -> [String]

    /// - Parameter preferredLanguages: 顯示語言;正式是 app 實際使用的在地化(`Bundle.main.preferredLocalizations`)。
    init(service: PushService, preferredLanguages: @escaping @MainActor () -> [String] = { Bundle.main.preferredLocalizations }) {
        self.service = service
        self.preferredLanguages = preferredLanguages
    }

    /// 讀後台的種類清單與這支裝置的配對:清單換掉備援,配對的種類寫回本機紀錄並通知各主機開關。
    /// 兩者各自失敗各自退回;沒登入或連不上都不丟錯。
    public func load() async {
        guard let service else { return }
        do {
            let loaded = try await service.session.pushKinds()
            // 空清單不能拿來畫(整頁會空白):當作沒讀到。
            if loaded.definitions.isEmpty {
                lastLoadFailure = BackendError.invalidResponse
            } else {
                catalog = loaded
                lastLoadFailure = nil
            }
        } catch {
            lastLoadFailure = error
        }
        await syncPairings()
    }

    /// 配對以後台為準:這支裝置每組配對的種類寫回本機紀錄。後台沒給種類(空)的不覆蓋,保留舊版 app 的升級行為。
    func syncPairings() async {
        guard let service, let device = try? service.device(),
              let records = try? await service.session.pushPairings(deviceID: device.id) else { return }
        for record in records where !record.kinds.isEmpty && service.store.host(forKeyHash: record.keyHash) != nil {
            service.store.setKinds(record.kinds, forKeyHash: record.keyHash)
        }
        service.kindsChanged()
    }

    /// 後台的種類清單在用(不是內建備援):改種類走 `PATCH`,代號以清單為準。
    public var usesBackendKinds: Bool { catalog.source == .backend }

    /// 這台主機的開關:連線方式不符且沒有下一步的不列;其餘照清單順序,不能開的附原因(`availability`)。
    public func choices(for context: PushKindContext) -> [PushKindChoice] {
        let languages = preferredLanguages()
        return catalog.definitions.compactMap { definition in
            let availability = definition.availability(
                installsViaHostService: context.installsViaHostService, hostServiceVersion: context.hostServiceVersion,
                pluginVersion: context.pluginVersion)
            guard availability != .unsupportedConnection else { return nil }
            return PushKindChoice(
                kind: definition.kind, title: definition.name.resolved(preferredLanguages: languages),
                details: definition.description.resolved(preferredLanguages: languages), availability: availability)
        }
    }

    /// 新開啟的主機預設收的種類(清單的預設開、這台主機現在就能用的);一個都沒有時至少收「需要你」。
    public func defaultKinds(for context: PushKindContext) -> Set<PushKind> {
        let kinds = catalog.defaultKinds(installsViaHostService: context.installsViaHostService, hostServiceVersion: context.hostServiceVersion)
        return kinds.isEmpty ? [.blocked] : kinds
    }

    /// 清單裡有的代號;改種類時只送這些(後台對未知或已停用的種類回 400)。
    func listed(_ kinds: Set<PushKind>) -> Set<PushKind> {
        guard usesBackendKinds else { return kinds }
        return kinds.filter { catalog.definition(for: $0) != nil }
    }

    /// 某種類的顯示名稱(摘要用);清單沒有時用代號。
    public func title(of kind: PushKind) -> String {
        catalog.definition(for: kind)?.name.resolved(preferredLanguages: preferredLanguages()) ?? kind.rawValue
    }
}
