import PurrdrAgentFeatures
import PurrdrCore
import Testing

/// 狀態色對照表(#237):需要你＝系統橙、工作中＝主色、錯誤＝系統紅、其他＝中性;只上在符號與圓點。
@Suite("狀態色對照表")
struct StatusToneTests {
    @Test("Agent 狀態：需要你橙、工作中主色，完成、閒置、未知都是中性")
    func agentStatusTones() {
        #expect(AgentStatus.blocked.tone == .attention)
        #expect(AgentStatus.working.tone == .accent)
        #expect(AgentStatus.done.tone == .neutral)
        #expect(AgentStatus.idle.tone == .neutral)
        #expect(AgentStatus.unknown.tone == .neutral)
    }

    @Test("Agent 狀態字不上狀態色：需要你用主要色，其他用次要文字色")
    func agentStatusTextIsNeverTinted() {
        #expect(AgentStatus.blocked.textEmphasis == .primary)
        #expect(AgentStatus.working.textEmphasis == .secondary)
        #expect(AgentStatus.done.textEmphasis == .secondary)
        #expect(AgentStatus.idle.textEmphasis == .secondary)
        #expect(AgentStatus.unknown.textEmphasis == .secondary)
    }

    @Test("聊天標頭狀態點與列表同色：線上、完成、離線都是中性")
    func conversationHeaderTones() {
        #expect(ConversationHeader.Status.needsYou.tone == .attention)
        #expect(ConversationHeader.Status.working.tone == .accent)
        #expect(ConversationHeader.Status.done.tone == .neutral)
        #expect(ConversationHeader.Status.online.tone == .neutral)
        #expect(ConversationHeader.Status.offline.tone == .neutral)
    }

    @Test("終端機狀態點：已連線主色、連線中與結束中性、中斷與被占用紅")
    func terminalStatusTones() {
        #expect(TerminalStatus.connected.tone == .accent)
        #expect(TerminalStatus.waitingForSize.tone == .neutral)
        #expect(TerminalStatus.connecting.tone == .neutral)
        #expect(TerminalStatus.ended.tone == .neutral)
        #expect(TerminalStatus.disconnected.tone == .error)
        #expect(TerminalStatus.inUse.tone == .error)
        #expect(TerminalStatus.takenOver.tone == .error)
        #expect(TerminalStatus.unavailable("no herdr").tone == .error)
    }

    @Test("委派圖示：執行中與完成中性、失敗紅")
    func delegationStatusTones() {
        #expect(DelegationStatus.running.tone == .neutral)
        #expect(DelegationStatus.completed.tone == .neutral)
        #expect(DelegationStatus.failed.tone == .error)
    }
}
