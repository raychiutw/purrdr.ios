import Foundation
import PurrdrCore
@testable import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// Shell `!` 區塊的顯示規則(行為規格 F5.9)與輸入列的 shell 模式(F6.4)。
@Suite("Shell 區塊")
struct ShellRunDisplayTests {
    static func run(_ output: ShellRun.Output, command: String = "git status") -> ShellRun {
        ShellRun(id: "r1", command: command, date: nil, output: output)
    }

    static func lines(_ count: Int, _ prefix: String) -> String {
        (1...count).map { "\(prefix)\($0)" }.joined(separator: "\n")
    }

    @Test("狀態：執行中、無輸出、沒有記錄輸出、N 行輸出(stdout 加 stderr,單複數)")
    func status() {
        #expect(ShellRunDisplay(run: Self.run(.running)).statusText == "Running…")
        #expect(ShellRunDisplay(run: Self.run(.recorded(ShellOutput(stdout: "", stderr: "")))).statusText == "No output")
        #expect(ShellRunDisplay(run: Self.run(.notRecorded)).statusText == "No output recorded")
        #expect(ShellRunDisplay(run: Self.run(.recorded(ShellOutput(stdout: "      17", stderr: "")))).statusText == "1 line of output")
        #expect(ShellRunDisplay(run: Self.run(.recorded(ShellOutput(stdout: "a\nb", stderr: "oops")))).statusText == "3 lines of output")
    }

    @Test("16 行以內全部顯示、不能折疊")
    func shortOutputIsNotFolded() {
        let display = ShellRunDisplay(run: Self.run(.recorded(ShellOutput(stdout: Self.lines(15, "o"), stderr: "e1"))))
        #expect(!display.isFoldable)
        #expect(display.visible(expanded: false).stdout.count == 15)
        #expect(display.visible(expanded: false).stderr == ["e1"])
    }

    @Test("超過 16 行折疊：有 stderr 時一半保留給 stderr,stderr 用不完的還給 stdout;展開顯示全部")
    func longOutputIsFolded() {
        let both = ShellRunDisplay(run: Self.run(.recorded(ShellOutput(stdout: Self.lines(30, "o"), stderr: Self.lines(20, "e")))))
        #expect(both.isFoldable)
        #expect(both.visible(expanded: false).stdout == (1...8).map { "o\($0)" })
        #expect(both.visible(expanded: false).stderr == (1...8).map { "e\($0)" })
        #expect(both.visible(expanded: true).stdout.count == 30)
        #expect(both.visible(expanded: true).stderr.count == 20)

        // fixture 第二組：67 行 stdout + 1 行 stderr。
        let fewErrors = ShellRunDisplay(run: Self.run(.recorded(ShellOutput(stdout: Self.lines(67, "o"), stderr: "Shell cwd was reset"))))
        #expect(fewErrors.visible(expanded: false).stdout.count == 15)
        #expect(fewErrors.visible(expanded: false).stderr == ["Shell cwd was reset"])

        let onlyErrors = ShellRunDisplay(run: Self.run(.recorded(ShellOutput(stdout: "", stderr: Self.lines(30, "e")))))
        #expect(onlyErrors.visible(expanded: false).stdout.isEmpty)
        #expect(onlyErrors.visible(expanded: false).stderr.count == 16)

        let onlyOutput = ShellRunDisplay(run: Self.run(.recorded(ShellOutput(stdout: Self.lines(30, "o"), stderr: ""))))
        #expect(onlyOutput.visible(expanded: false).stdout.count == 16)
    }

    @Test("長按複製：輸出(stdout 再 stderr)與指令;沒有輸出時不提供「複製輸出」")
    func copyTexts() {
        let display = ShellRunDisplay(run: Self.run(.recorded(ShellOutput(stdout: "a\nb", stderr: "oops")), command: "make"))
        #expect(display.copyableOutput == "a\nb\noops")
        #expect(display.command == "make")
        #expect(ShellRunDisplay(run: Self.run(.recorded(ShellOutput(stdout: "", stderr: "")))).copyableOutput == nil)
        #expect(ShellRunDisplay(run: Self.run(.running)).copyableOutput == nil)
        #expect(ShellRunDisplay(run: Self.run(.recorded(ShellOutput(stdout: "", stderr: "only")))).copyableOutput == "only")
    }

    @Test("截斷的輸出標註")
    func truncatedIsAnnotated() {
        let display = ShellRunDisplay(run: Self.run(.recorded(ShellOutput(stdout: "x", stderr: "", isTruncated: true))))
        #expect(display.truncationNote == "Output truncated at 20,000 characters")
        #expect(ShellRunDisplay(run: Self.run(.recorded(ShellOutput(stdout: "x", stderr: "")))).truncationNote == nil)
    }
}

/// 對話畫面上的 shell 模式與送出(F6.4)。herdr 走假主機，對話紀錄在本機暫存家目錄;絕不對真實 agent 送出。
@MainActor
@Suite("對話的 shell 模式")
struct ConversationShellTests {
    @Test("Claude 聊天的草稿以 `!` 開頭時是 shell 模式;其他草稿不是")
    func shellModeFollowsDraft() async throws {
        let setup = try await ConversationSendTests.opened()
        #expect(!setup.model.isShellMode)
        setup.model.draft = "!git status"
        #expect(setup.model.isShellMode)
        setup.model.draft = "run !git status"
        #expect(!setup.model.isShellMode)
    }

    @Test("非 Claude 的 agent 不是 shell 模式")
    func otherAgentsHaveNoShellMode() async throws {
        let setup = try await ConversationSendTests.setup()
        await setup.host.bridge.expect(HerdrCommand.bridge(), reply: ConversationModelTests.snapshot { $0["agent"] = "codex" })
        await setup.model.poll()
        setup.model.draft = "!git status"
        #expect(!setup.model.isShellMode)
    }

    @Test("送出 `!` 指令不等待 agent 狀態;對話紀錄出現 shell 區塊時回音被確認")
    func shellCommandEchoIsConfirmedByShellBlock() async throws {
        let setup = try await ConversationSendTests.opened()
        await setup.host.bridge.expect(HerdrCommand.bridge(), reply: ConversationSendTests.snapshot())
        await setup.host.bridge.expect(HerdrCommand.bridge(), reply: ConversationSendTests.delivered)
        setup.model.draft = "!wc -l < exports/2026-11.csv"

        await setup.model.send()

        let prompts = await ConversationSendTests.promptRequests(setup)
        #expect(prompts == [
            #"{"id":"purrdr:agent.prompt","method":"agent.prompt","params":{"target":"w1:p6","text":"!wc -l < exports/2026-11.csv"}}"# + "\n",
        ])
        #expect(setup.model.echoes.map(\.state) == [.sent])

        // 主機執行後，對話紀錄接上 shell.jsonl 的第一組(輸入行與輸出行)。
        let exchange = Fixtures.transcriptLines("shell.jsonl").prefix(2).joined(separator: "\n") + "\n"
        try setup.shell.append(Data(exchange.utf8), to: ConversationModelTests.transcriptPath)
        await setup.host.bridge.expect(HerdrCommand.bridge(), reply: ConversationSendTests.snapshot())
        await setup.model.poll()

        #expect(setup.model.echoes.isEmpty)
        guard case .item(.shell(let run))? = setup.model.entries.last else {
            Issue.record("最後一列不是 shell 區塊"); return
        }
        #expect(run.command == "wc -l < exports/2026-11.csv")
        #expect(run.output == .recorded(ShellOutput(stdout: "      17", stderr: "")))
    }
}
