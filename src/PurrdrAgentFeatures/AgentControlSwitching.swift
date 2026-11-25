import Foundation
import Observation
import PurrdrCore

/// 切換程序要用到聊天 model 的哪些東西(#561 第二步):送按鍵、讀畫面、面板、提示。
/// 切換程序本身(順序、驗證、失敗原因)只在 `AgentControlSwitcher`;聊天 model 只提供這些「手」。
@MainActor
package protocol AgentControlSwitchingHost: AnyObject {
    /// 目前的控制(值、可選項、停用原因);每次呼叫都是最新的答案。
    var controls: AgentControls { get }
    var isReadOnly: Bool { get }
    var isOffline: Bool { get }
    /// 有自己輪替的 Agent(Antigravity)的模式輪替;沒有是 `nil`。
    var permissionModeCycle: [AgentPermissionMode]? { get }
    /// 能開模型選擇(聊天 model 看送出中、問題、面板等狀態)。
    var canChooseModel: Bool { get }
    var panel: SlashPanel? { get }
    var isOperatingPanel: Bool { get }
    /// 面板監看期還沒結束。
    var isWatchingPanel: Bool { get }

    /// 送面板操作(方向鍵或面板自己的動作鍵,永不數字);回傳按鍵是否送出。
    @discardableResult
    func operatePanel(_ input: SlashPanel.Input) async -> Bool
    func clearPanel()
    /// 送 slash 指令(不產生回音)並開始監看面板;沒送出時已把原因放進提示,回傳 `false`。
    func sendPanelCommand(_ text: String) async -> Bool
    func cancelPanelWatch()
    func setNotice(_ notice: SendNotice?)
    func refreshModelCatalog()
    /// 讀畫面認出目前的權限模式;`verifying` 為真(切換後確認)一律重讀。讀不到是 `nil`。
    func readScreenPermissionMode(verifying: Bool) async -> AgentPermissionMode?
    /// 切換過程中讀到的模式(記成看過的模式與畫面補的空檔)。
    func recordSwitchedScreenMode(_ mode: AgentPermissionMode)
    /// 探測讀到的模式(對話紀錄已有模式時只記「看過」)。
    func recordProbedScreenMode(_ mode: AgentPermissionMode)
    /// 送 Shift+Tab;帶 `expected_session`,對話已換掉主機會擋。
    func sendShiftTab() async throws
    func pause(_ duration: Duration) async throws
    func play(_ feedback: HapticFeedback)
}

/// Agent 控制的切換程序(#561 第二步,延伸 ADR-0013):權限模式輪替、模型與 effort 的 sheet 流程。
/// 值與停用原因在 `AgentControls`;這裡只有「把鍵序列送給 Agent 並確認結果」。
/// 狀態(切換中、失敗原因、sheet 頁面)由它持有,標題列、膠囊與面板都經聊天 model 轉發讀同一份。
@MainActor
@Observable
package final class AgentControlSwitcher {
    @ObservationIgnored package weak var host: (any AgentControlSwitchingHost)?

    package init() {}

    // MARK: 狀態

    /// 正在切到這個模式(膠囊顯示進行中)。
    package private(set) var switchingPermissionMode: AgentPermissionMode?
    /// 最近一次切換失敗的原因(#306);切換成功、再試或換 Agent 時清掉。
    package private(set) var permissionModeFailure: PermissionModeFailure?
    /// 模型選擇 sheet 開著(從送出 `/model` 到選定或取消)。
    package private(set) var isChoosingModel = false
    package private(set) var modelSheetPage: ConversationModel.ModelSheetPage = .models
    /// 模型切換的按鍵送出中(膠囊顯示「切換中」)。
    package private(set) var isSwitchingModel = false
    /// 面板監看期滿還是讀不到:sheet 只顯示目前模型,不開自己的選單。
    package private(set) var modelPanelUnreadable = false

    private struct EffortBaseline {
        var level: Int?
        var ultracode: Bool?
    }

    @ObservationIgnored private var effortBaseline: EffortBaseline?
    @ObservationIgnored private var permissionModeProbed = false

    package var isSwitchingPermissionMode: Bool { switchingPermissionMode != nil }

    /// 按了 Shift+Tab 後畫面沒變時最多再讀幾次(每次隔 0.3 秒)才再按。
    private static let staleModeRereads = 2

    // MARK: 權限模式(#306、#383)

    /// 讀一次畫面:對話紀錄還沒有模式時用它當目前模式,紀錄有值就以紀錄為準;認不出沿用上次。
    package func readPermissionModeFromScreen() async {
        guard let host, host.controls.supportsPermissionMode, let mode = await host.readScreenPermissionMode(verifying: false) else { return }
        host.recordProbedScreenMode(mode)
    }

    /// 每次 `run` 第一輪輪詢後讀一次(平常的輪詢不讀畫面,指令預算)。
    package func probePermissionModeIfNeeded() async {
        guard let host, !permissionModeProbed, host.controls.supportsPermissionMode, !host.isReadOnly, !host.isOffline else { return }
        permissionModeProbed = true
        await readPermissionModeFromScreen()
    }

    /// 對上次失敗的目標再切一次。
    package func retryPermissionMode() async {
        guard let target = permissionModeFailure?.target else { return }
        await setPermissionMode(target)
    }

    /// 送 Shift+Tab 到畫面顯示目標模式,最多 `maximumSwitchAttempts` 次。
    /// 目標是略過權限或自動時,輪替一圈回到看過的模式就停(這個 session 沒開,再按也不會出現)。
    /// 失敗記在 `permissionModeFailure`,可再試;離開聊天(取消)時直接結束、不算失敗。
    package func setPermissionMode(_ target: AgentPermissionMode) async {
        guard let host, host.controls.supportsPermissionMode, !isSwitchingPermissionMode, target.isSwitchable else { return }
        // 有自己輪替的 Agent:目標不在輪替裡(例如略過權限)按不出來,一個鍵都不送。
        if let cycle = host.permissionModeCycle, !cycle.contains(target) { return }
        guard !host.isReadOnly else {
            host.setNotice(.readOnlyDevice)
            return
        }
        // 離線,或 Agent 在等你回覆(這時 Shift+Tab 會變成「核准」):一個鍵都不送。
        guard host.controls.permissionModeLock == nil else { return }
        permissionModeFailure = nil
        switchingPermissionMode = target
        defer { switchingPermissionMode = nil }
        guard var current = await host.readScreenPermissionMode(verifying: true) else {
            permissionModeFailure = .unreadable(target: target)
            return
        }
        host.recordSwitchedScreenMode(current)
        var visited: Set<AgentPermissionMode> = [current]
        var attempts = 0
        while current != target, attempts < AgentPermissionMode.maximumSwitchAttempts {
            do {
                try await host.sendShiftTab()
            } catch is CancellationError {
                return
            } catch {
                permissionModeFailure = error as? HostServiceError == .paneChanged
                    ? .paneChanged(target: target) : .keysFailed(target: target)
                host.play(.error)
                return
            }
            attempts += 1
            do { try await host.pause(.milliseconds(300)) } catch { return }
            guard var read = await host.readScreenPermissionMode(verifying: true) else { break }
            // 有自己輪替的 Agent:畫面可能還沒重畫(讀到的模式沒變),先再讀幾次,不要重複按而跳過目標。
            var rereads = 0
            while host.permissionModeCycle != nil, read == current, rereads < Self.staleModeRereads {
                rereads += 1
                do { try await host.pause(.milliseconds(300)) } catch { return }
                guard let again = await host.readScreenPermissionMode(verifying: true) else { break }
                read = again
            }
            let wrapped = read != current && !visited.insert(read).inserted
            current = read
            host.recordSwitchedScreenMode(read)
            if wrapped, current != target {
                permissionModeFailure = .modeUnavailable(target)
                host.play(.error)
                return
            }
        }
        if current != target {
            permissionModeFailure = .notReached(attempts: attempts, target: target)
            host.play(.error)
        } else {
            host.play(.selection)
        }
    }

    // MARK: 模型 sheet(#350、#384)

    /// 點模型膠囊:送 `/model`(不產生回音泡泡),之後由既有的面板監看讀到畫面上的面板。
    /// 什麼都沒送出(Agent 不在、對話已變更、唯讀…)時 sheet 只顯示目前模型與原因,原因放在提示。
    package func beginChoosingModel() async {
        guard let host, host.canChooseModel else { return }
        isChoosingModel = true
        modelSheetPage = .models
        modelPanelUnreadable = false
        effortBaseline = nil
        host.setNotice(nil)
        host.refreshModelCatalog()
        await sendModelCommand()
    }

    private func sendModelCommand() async {
        guard let host else { return }
        if await host.sendPanelCommand("/model") { return }
        isChoosingModel = false
    }

    /// 在 sheet 點選一個模型:移動面板游標到那一列,再按面板自己的 `s`(只用在這個 session;永不送數字)。
    /// 按鍵送不出去就維持原模型,提示說明。
    package func chooseModel(_ option: SlashPanelOption) async {
        guard let host, let panel = host.panel, isChoosingModel, modelSheetPage == .models else { return }
        isSwitchingModel = true
        defer { isSwitchingModel = false }
        guard await host.operatePanel(.select(option)) else {
            host.setNotice(.modelSwitchFailed)
            isChoosingModel = false
            return
        }
        // 面板的 Enter 是「設為預設」(寫進使用者設定);膠囊只改這個 session,所以有 `s`(只用在這個 session)就按它。
        if let confirm = panel.actions.first(where: { $0.key == "s" }) ?? panel.actions.first(where: { $0.key == "enter" }) {
            guard await host.operatePanel(.action(confirm)) else {
                host.setNotice(.modelSwitchFailed)
                isChoosingModel = false
                return
            }
        }
        isChoosingModel = false
    }

    /// sheet 關閉(選定後或使用者下滑／按完成):面板還開著就取消(在投入程度子頁且有改動則確認),不改模型。
    package func finishChoosingModel() async {
        guard let host, isChoosingModel else { return }
        isChoosingModel = false
        let key = modelSheetPage == .effort && effortChanged ? "enter" : "esc"
        modelSheetPage = .models
        effortBaseline = nil
        if let action = host.panel?.actions.first(where: { $0.key == key }) {
            await host.operatePanel(.action(action))
        }
    }

    // MARK: 投入程度子頁(#384)

    /// 子頁上的層級滑桿(讀到 `/effort` 面板後才有)。
    package var effortSlider: SlashPanelSlider? { modelSheetPage == .effort ? host?.panel?.slider : nil }

    /// Ultracode 開關只在目前模型支援 xhigh 時出現:面板有開關,且層級含 xhigh。
    package var showsUltracode: Bool {
        guard modelSheetPage == .effort, let panel = host?.panel, panel.ultracode != nil, let slider = panel.slider else { return false }
        return slider.levels.contains { $0.lowercased() == "xhigh" }
    }

    package var ultracodeIsOn: Bool { host?.panel?.ultracode == true }

    /// 子頁開著後層級或 Ultracode 與剛進來時不同。
    package var effortChanged: Bool {
        guard modelSheetPage == .effort, let baseline = effortBaseline, let panel = host?.panel, let slider = panel.slider else { return false }
        return slider.current != baseline.level || panel.ultracode != baseline.ultracode
    }

    /// 點「投入程度」列:先 Esc 收掉 `/model` 面板(不改模型),再送 `/effort` 讀滑桿面板。
    package func openEffortPage() async {
        guard let host, isChoosingModel, modelSheetPage == .models, !host.isOperatingPanel else { return }
        if let esc = host.panel?.actions.first(where: { $0.key == "esc" }) {
            await host.operatePanel(.action(esc))
        }
        host.clearPanel()
        modelSheetPage = .effort
        effortBaseline = nil
        modelPanelUnreadable = false
        host.setNotice(nil)
        if await !host.sendPanelCommand("/effort") {
            host.cancelPanelWatch()
            updatePanelReadability()
        }
    }

    /// 點一個層級:只移動滑桿(送方向鍵),離開子頁時才確認。
    package func chooseEffortLevel(_ level: Int) async {
        guard let host, modelSheetPage == .effort else { return }
        await host.operatePanel(.level(level))
    }

    /// 切換 Ultracode(Tab)。
    package func toggleUltracode() async {
        guard let host, showsUltracode else { return }
        await host.operatePanel(.toggleUltracode)
    }

    /// 離開子頁:有改動就按 Enter 確認(成為新 session 的預設),沒有就 Esc;接著重開 `/model` 回到模型列。
    package func closeEffortPage() async {
        guard let host, modelSheetPage == .effort else { return }
        let key = effortChanged ? "enter" : "esc"
        let action = host.panel?.slider != nil ? host.panel?.actions.first(where: { $0.key == key }) : nil
        modelSheetPage = .models
        effortBaseline = nil
        if let action { await host.operatePanel(.action(action)) }
        host.clearPanel()
        modelPanelUnreadable = false
        await sendModelCommand()
    }

    /// 面板 sheet 被使用者關掉(下滑或「完成」)時:面板還開著就按 Esc 取消,不改設定(#366)。
    package func dismissPanel() async {
        guard let host, !isChoosingModel, let esc = host.panel?.actions.first(where: { $0.key == "esc" }) else { return }
        await host.operatePanel(.action(esc))
    }

    // MARK: 面板讀取回報

    /// 聊天 model 讀到新的面板:子頁剛開還沒有基準時,以第一次讀到的滑桿為基準。
    package func notePanelRead(_ panel: SlashPanel?) {
        if modelSheetPage == .effort, effortBaseline == nil, let panel, let slider = panel.slider {
            effortBaseline = EffortBaseline(level: slider.current, ultracode: panel.ultracode)
        }
    }

    /// 模型選擇 sheet 在等面板、監看期已滿還是沒讀到面板:sheet 改成只顯示目前模型(#384)。
    package func updatePanelReadability() {
        guard let host else { return }
        let unreadable = isChoosingModel && host.panel == nil && !host.isWatchingPanel
        if unreadable != modelPanelUnreadable { modelPanelUnreadable = unreadable }
    }
}
