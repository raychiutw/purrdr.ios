import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// #713:回答送出後，只有「看不到提示」這種反面跡象(重新連線時狀態未知、讀到空白畫面)不算送達;
/// 不能先顯示「你選了」,之後題目還在時又讓人以為答過了。
@Suite("回答送達要有正面證據")
struct AnswerDeliveryEvidenceTests {
    typealias T = AnswerFlowTests

    /// 讀到問題卡、選了第一個、按鍵回報已送出。
    static func sentQuestion() -> (AnswerFlow, PromptAnswer) {
        var flow = AnswerFlow(agentKind: "claude")
        T.poll(&flow, screen: T.question)
        let answer = PromptAnswer.option(flow.prompt!.options[0])
        _ = flow.begin(answer: answer, isReadOnly: false)
        _ = flow.finish(answer, result: .sent(lastEntryID: "e1", at: T.t0))
        return (flow, answer)
    }

    @Test("送出後狀態讀成不是 blocked 也不在工作中(重新連線時的未知或過時):不算送達，題目還在時卡片仍在")
    func unknownStatusIsNotDelivery() {
        var (flow, _) = Self.sentQuestion()
        T.poll(&flow, screen: nil, blocked: false, working: false, at: 2)
        #expect(flow.lastAnswer == nil, "狀態未知卻顯示了「你選了」")
        T.poll(&flow, screen: T.question, at: 4)
        #expect(flow.prompt != nil, "題目還在，卡片卻不見了")
        #expect(flow.lastAnswer == nil)
    }

    @Test("送出後讀到空白畫面(重新連線時):不算送達")
    func blankScreenIsNotDelivery() {
        var (flow, _) = Self.sentQuestion()
        T.poll(&flow, screen: "", at: 2)
        #expect(flow.lastAnswer == nil, "空白畫面卻顯示了「你選了」")
        T.poll(&flow, screen: T.question, at: 4)
        #expect(flow.prompt != nil, "題目還在，卡片卻不見了")
    }

    @Test("對照：送出後 Agent 進入工作中，是送達的正面證據")
    func workingIsDelivery() {
        var (flow, _) = Self.sentQuestion()
        T.poll(&flow, screen: nil, blocked: false, working: true, at: 2)
        #expect(flow.lastAnswer != nil, "Agent 已經開始工作，卻沒有算送達")
    }
}
