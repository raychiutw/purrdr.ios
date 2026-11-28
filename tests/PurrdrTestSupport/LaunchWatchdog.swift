import Foundation

// UI 測試啟動看門狗的決策與流程(#718、spec #717)。
//
// 只依賴 Foundation:UI 測試以符號連結(`tests/PurrdrUITests/LaunchWatchdog.swift`)編進同一份檔案,
// `swift test` 則經 PurrdrTestSupport 驗證流程。XCUIApplication 的細節(啟動、結束、就緒判斷、崩潰報告)以閉包注入。

/// 看門狗的規則。就緒:app 啟動後 `readinessTimeout` 秒內主視窗出現(app 仍在前景執行)。
struct LaunchWatchdogPolicy: Equatable {
    /// 每次啟動等待就緒的秒數(只算 app 有回應的時間,見 `UITestWait.until`)。
    var readinessTimeout: TimeInterval = 30
    /// 最多啟動幾次(1 = 不重來)。預設重來一次。
    var maxAttempts = 2
}

/// 一次沒有就緒的啟動,當下能蒐集到的原因。
struct LaunchDiagnosis: Equatable {
    /// app 目前的狀態描述(例如 notRunning、runningForeground)。
    var appState: String
    /// app 已經不在執行(崩潰或自己結束)。
    var appIsGone: Bool
    /// 啟動之後出現了 Purrdr 的崩潰報告檔(nil = 沒辦法檢查)。
    var crashReportFound: Bool?
}

enum LaunchWatchdogDecision: Equatable {
    case retry
    case fail
}

enum LaunchWatchdog {
    /// 一次啟動沒就緒之後:有崩潰報告就是真的崩潰,不重來(重來會掩蓋它);否則在上限內重來。
    static func decide(afterFailedAttempt attempt: Int, policy: LaunchWatchdogPolicy, diagnosis: LaunchDiagnosis) -> LaunchWatchdogDecision {
        if diagnosis.crashReportFound == true { return .fail }
        return attempt < policy.maxAttempts ? .retry : .fail
    }

    /// 單行的記錄(每次失敗都寫進測試輸出,偶發問題才不會被默默吞掉)。
    static func logLine(attempt: Int, policy: LaunchWatchdogPolicy, diagnosis: LaunchDiagnosis, decision: LaunchWatchdogDecision) -> String {
        let action = decision == .retry ? "結束 app 後重來" : "不再重來"
        return "[launch-watchdog] 第 \(attempt)/\(policy.maxAttempts) 次啟動在 \(Int(policy.readinessTimeout)) 秒內沒有就緒"
            + "(\(describe(diagnosis))),\(action)"
    }

    /// 最後失敗的訊息:寫明是啟動沒就緒、不是找不到某個元素,並帶每次失敗的原因。
    static func failureMessage(policy: LaunchWatchdogPolicy, diagnoses: [LaunchDiagnosis]) -> String {
        let crashed = diagnoses.contains { $0.crashReportFound == true }
        let headline = crashed
            ? "app 啟動後崩潰(有崩潰報告),不是單純卡住"
            : "app 啟動卡住:每次都在 \(Int(policy.readinessTimeout)) 秒內沒有就緒"
        let details = diagnoses.enumerated().map { "第 \($0.offset + 1) 次:\(describe($0.element))" }.joined(separator: ";")
        return "\(headline)(啟動 \(diagnoses.count) 次,上限 \(policy.maxAttempts) 次)。\(details)"
    }

    private static func describe(_ diagnosis: LaunchDiagnosis) -> String {
        let crash = switch diagnosis.crashReportFound {
        case true?: "有崩潰報告"
        case false?: "沒有崩潰報告"
        case nil: "無法檢查崩潰報告"
        }
        return "app 狀態 \(diagnosis.appState)\(diagnosis.appIsGone ? "、已不在執行" : "")、\(crash)"
    }

    /// 流程:啟動 → 等就緒 → 沒就緒就診斷、決定、結束 app 後重來。回傳 nil 表示就緒;否則是失敗訊息。
    /// 每次啟動沒就緒都呼叫 `log`。
    static func run(
        policy: LaunchWatchdogPolicy,
        launch: () -> Void,
        awaitReady: (_ attempt: Int, _ timeout: TimeInterval) -> Bool,
        diagnose: () -> LaunchDiagnosis,
        terminate: () -> Void,
        log: (String) -> Void
    ) -> String? {
        var diagnoses: [LaunchDiagnosis] = []
        var attempt = 1
        while true {
            launch()
            if awaitReady(attempt, policy.readinessTimeout) { return nil }
            let diagnosis = diagnose()
            diagnoses.append(diagnosis)
            let decision = decide(afterFailedAttempt: attempt, policy: policy, diagnosis: diagnosis)
            log(logLine(attempt: attempt, policy: policy, diagnosis: diagnosis, decision: decision))
            terminate()
            if decision == .fail { return failureMessage(policy: policy, diagnoses: diagnoses) }
            attempt += 1
        }
    }
}
