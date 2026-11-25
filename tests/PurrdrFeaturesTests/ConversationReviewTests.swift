import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 變更頁的評論送給 Agent(#310):經聊天的送出管線，輸入框裡打到一半的字不受影響。
@MainActor
@Suite("對話送出評論")
struct ConversationReviewTests {
    static let review = "README.md:3\n> +New.\n改成 New"

    static func opened(steps: [any SendStep], git: (any GitChangesReading)? = nil) async throws -> ConversationSendTests.Setup {
        try await ConversationSendTests.opened { client, transcripts, drafts in
            ConversationModel(
                client: client, transcripts: transcripts, paneID: ConversationSendTests.paneID,
                knownSessionID: ConversationModelTests.sessionID, cache: InMemoryConversationCache(),
                clock: TestClock().clock, drafts: drafts, sendStages: SendStages(custom: steps),
                links: .init(gitChanges: git))
        }
    }

    @Test("評論經送出管線送出，輸入框的草稿留著")
    func reviewGoesThroughPipeline() async throws {
        var seen: [String] = []
        let setup = try await Self.opened(steps: [SendStepClosure { prompt, _ in
            seen.append(prompt.text)
            return .proceed(prompt)
        }])
        await setup.host.bridge.expect(ConversationSendTests.bridge, reply: ConversationSendTests.snapshot())
        await setup.host.bridge.expect(ConversationSendTests.bridge, reply: ConversationSendTests.delivered)
        setup.model.draft = "還沒打完"

        #expect(setup.model.canSendReview)
        await setup.model.sendReview(Self.review)

        #expect(seen == [Self.review])
        let prompts = await ConversationSendTests.promptRequests(setup)
        #expect(prompts.count == 1)
        #expect(prompts.first?.contains("改成 New") == true)
        #expect(setup.model.echoes.map(\.text) == [Self.review])
        #expect(setup.model.draft == "還沒打完")
    }

    @Test("管線擋下(例如撤回):評論放回輸入框，接在原本的草稿前面")
    func haltedReviewReturnsToDraft() async throws {
        let setup = try await Self.opened(steps: [SendStepClosure { _, _ in .halt(SendHalt(restoresDraft: true)) }])
        setup.model.draft = "還沒打完"

        await setup.model.sendReview(Self.review)

        #expect(await ConversationSendTests.promptRequests(setup).isEmpty)
        #expect(setup.model.draft == Self.review + "\n還沒打完")
    }

    @Test("有 git 讀取且知道 Agent 的工作目錄才開得了變更頁")
    func changesNeedReaderAndWorkingDirectory() async throws {
        let setup = try await Self.opened(steps: [])
        #expect(setup.model.makeChanges() == nil)

        let reader = FakeGitChanges(status: GitWorkingTreeStatus(branch: nil, files: []), diffs: GitDiffSet(files: [], truncated: false))
        let withGit = try await Self.opened(steps: [], git: reader)
        let changes = try #require(withGit.model.makeChanges())

        await changes.load()
        // 變更清單與 diff 並行讀取(`async let`),送達順序不固定(#324):只檢查兩個請求都帶 Agent 的工作目錄。
        let requests = await reader.requests
        var cwds: [String] = []
        for request in requests {
            switch request {
            case .status(let cwd): cwds.append(cwd)
            case .diff(let cwd, _): cwds.append(cwd)
            }
        }
        #expect(requests.contains { if case .status = $0 { true } else { false } }, "沒有讀變更清單")
        #expect(cwds.count == 2 && cwds.allSatisfy { $0.hasPrefix("/") })
        #expect(changes.canSendReview)
    }

    // MARK: - 更多選單的 Git 變更項目(#381)

    @Test("Git 變更項目:沒有 git 讀取時停用，原因是這個連線讀不了")
    func gitMenuUnavailableWithoutReader() async throws {
        let setup = try await Self.opened(steps: [])
        await setup.model.refreshGitMenu()
        #expect(setup.model.gitMenu == .unavailable(.unsupported))
    }

    @Test("Git 變更項目:讀到清單後可用，帶分支與檔案數")
    func gitMenuAvailableShowsBranchAndCount() async throws {
        let setup = try await Self.opened(steps: [], git: FakeGitChanges(
            status: GitWorkingTreeStatus(branch: "fix/composer", files: [
                GitChange(path: "a", kind: .modified), GitChange(path: "b", kind: .added), GitChange(path: "c", kind: .untracked),
            ]),
            diffs: GitDiffSet(files: [], truncated: false)))
        await setup.model.refreshGitMenu()
        #expect(setup.model.gitMenu == .available(branch: "fix/composer", fileCount: 3))
    }

    @Test("Git 變更項目:不是 Git 資料夾時停用並說明原因")
    func gitMenuNotRepository() async throws {
        let setup = try await Self.opened(steps: [], git: FakeGitChanges(failing: GitChangesError.notGitRepository))
        await setup.model.refreshGitMenu()
        #expect(setup.model.gitMenu == .unavailable(.notGitRepository))
    }

    @Test("Git 變更項目:暫時讀不到(網路等)不停用，維持可點")
    func gitMenuTransientFailureStaysEnabled() async throws {
        let setup = try await Self.opened(steps: [], git: FakeGitChanges(failing: HostServiceError.connectionLost))
        await setup.model.refreshGitMenu()
        #expect(setup.model.gitMenu == .checking)
        #expect(setup.model.gitMenu.isEnabled)
    }
}
