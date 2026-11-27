import Foundation
import PurrdrCore
import PurrdrHTTPS
import PurrdrSSH

/// HTTPS 主機的方案用量(主機服務 0.12.0 起,#392):`usage.claude`／`usage.codex` 的結果換成與 SSH 相同的 `PlanUsage`,
/// 用量區與方案用量畫面都用同一份來源,不必知道連線方式。
extension PlanUsage {
    /// 沒有任何週期是沒有資料(`nil`);沒有擷取時間(或看不懂)時用 `now`。
    init?(hostServicePeriods periods: [HostServiceProtocol.PlanUsagePeriod], capturedAt: String?, now: Date) {
        guard !periods.isEmpty else { return nil }
        self.init(
            periods: periods.map { period in
                Period(
                    kind: period.kind == .fiveHour ? .fiveHour : .week, usedPercentage: period.usedPercentage,
                    resetsAt: period.resetsAt.flatMap(Self.date(from:)))
            },
            capturedAt: capturedAt.flatMap(Self.date(from:)) ?? now)
    }

    private static func date(from text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
}

extension PlanUsageSource {
    /// 經主機服務讀方案用量。Codex 不寫主機;Claude 的用量擷取以 `claude_usage.install`／`remove` 安裝與還原
    /// (與 SSH 相同,同意記在 `consent`,安裝紀錄與 SSH 路徑的 journal 相容)。
    /// 主機服務比 0.12.0 舊時讀取丟 `HostServiceError.hostServiceUpdateRequired`,畫面顯示「請更新主機服務」。
    static func hostService(
        _ connection: HTTPSHostConnection, agent: AgentID, hostID: String, hostName: String,
        consent: any HostWriteConsentStore, now: @escaping @Sendable () -> Date = Date.init
    ) -> PlanUsageSource? {
        switch agent {
        case .codex:
            return PlanUsageSource(cost: .transfer) {
                let result = try await connection.codexUsage()
                return PlanUsage(hostServicePeriods: result.periods, capturedAt: result.capturedAt, now: now())
            }
        case .claude:
            let feature = ClaudePlanUsageHost.feature.id
            let hostWrite = PlanUsageHostWrite(
                isGranted: { consent.isGranted(feature, host: hostID) },
                inspect: {
                    try await connection.requireHostService(.claudeUsageSetup)
                    return hostName
                },
                install: {
                    _ = try await connection.installClaudeUsage()
                    consent.grant(feature, host: hostID)
                },
                restore: {
                    _ = try await connection.removeClaudeUsage()
                    consent.revoke(feature, host: hostID)
                })
            return PlanUsageSource(cost: .transfer, hostWrite: hostWrite) {
                let result = try await connection.claudeUsage()
                return PlanUsage(hostServicePeriods: result.periods, capturedAt: result.capturedAt, now: now())
            }
        default:
            // 主機服務沒有其他 Agent 的方案用量(Antigravity 的 statusline 包裝只有 SSH,#448)。
            return nil
        }
    }
}
