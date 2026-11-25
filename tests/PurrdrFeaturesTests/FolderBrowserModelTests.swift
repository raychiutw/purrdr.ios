import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 檔案瀏覽的 model:經假主機回應清單與上傳指令。
@MainActor
@Suite("檔案瀏覽")
struct FolderBrowserModelTests {
    static let home = """
        /Users/demo
        total 8
        drwxr-xr-x  3 501  20   96 Nov 16 05:12 ledger
        -rw-r--r--  1 501  20   12 Nov 16 05:12 .zshrc

        """

    static let ledger = """
        /Users/demo/ledger
        total 0
        -rw-r--r--  1 501  20  2048 Nov 16 05:12 export.csv

        """

    static func model(_ host: FakeHost) -> FolderBrowserModel {
        FolderBrowserModel(folders: HostFolders(channel: host), hostName: "Studio Mac")
    }

    static func listed(_ model: FolderBrowserModel) -> [String] {
        if case .loaded(let listing) = model.phase { return listing.entries.map(\.name) }
        return []
    }

    @Test("搜尋只比對目前資料夾的項目名稱(不分大小寫、前後空白不算);清掉搜尋回到全部(#500)")
    func searchFiltersCurrentFolder() async throws {
        let host = FakeHost()
        await host.expect(HostFolderCommand.list(nil), reply: FakeReply(stdout: Data(Self.home.utf8)))
        let model = Self.model(host)
        await model.load()
        #expect(model.visibleEntries.map(\.name) == ["ledger", ".zshrc"])
        model.query = "  LED "
        #expect(model.visibleEntries.map(\.name) == ["ledger"])
        model.query = "zzz"
        #expect(model.visibleEntries.isEmpty)
        #expect(model.isSearching)
        model.query = ""
        #expect(model.visibleEntries.count == 2)
        #expect(!model.isSearching)
    }

    @Test("路徑麵包屑(#273,原型):家目錄底下以「~」開頭，每段可點回那一層;家目錄外從根目錄開始")
    func breadcrumbs() async throws {
        let host = FakeHost()
        await host.expect(HostFolderCommand.list(nil), reply: FakeReply(stdout: Data(Self.home.utf8)))
        await host.expect(HostFolderCommand.list("/Users/demo/ledger"), reply: FakeReply(stdout: Data(Self.ledger.utf8)))
        await host.expect(HostFolderCommand.list("/Users/demo"), reply: FakeReply(stdout: Data(Self.home.utf8)))
        await host.expect(HostFolderCommand.list("/Users"), reply: FakeReply(stdout: Data("/Users\ntotal 0\n".utf8)))
        let model = Self.model(host)

        await model.load()
        #expect(model.breadcrumbs.map(\.title) == ["~"])
        await model.open(FolderEntry(name: "ledger", kind: .folder, size: 96))
        #expect(model.breadcrumbs.map(\.title) == ["~", "ledger"])
        #expect(model.breadcrumbs.map(\.path) == ["/Users/demo", "/Users/demo/ledger"])

        await model.go(to: try #require(model.breadcrumbs.first))
        #expect(model.path == "/Users/demo")
        await model.goUp()
        #expect(model.breadcrumbs.map(\.title) == ["/", "Users"])
        #expect(model.breadcrumbs.map(\.path) == ["/", "/Users"])
        #expect(await host.unmetExpectations.isEmpty)
    }

    @Test("資料夾是 push(#620):子層的 model 從那個資料夾開始、沿用家目錄,麵包屑立刻有完整路徑;route 來自項目名稱")
    func childLevelStartsAtFolder() async throws {
        let host = FakeHost()
        await host.expect(HostFolderCommand.list(nil), reply: FakeReply(stdout: Data(Self.home.utf8)))
        await host.expect(HostFolderCommand.list("/Users/demo/ledger"), reply: FakeReply(stdout: Data(Self.ledger.utf8)))
        let root = Self.model(host)
        await root.load()
        #expect(root.childPath(for: FolderEntry(name: "export.csv", kind: .file, size: 1)) == nil, "檔案不能打開")
        let path = try #require(root.childPath(for: FolderEntry(name: "ledger", kind: .folder, size: 96)))
        #expect(path == "/Users/demo/ledger")

        let child = root.child(at: path)
        #expect(child.breadcrumbs.map(\.title) == ["~", "ledger"], "還沒載入也看得到路徑")
        #expect(child.title == "ledger")
        await child.load()
        #expect(Self.listed(child) == ["export.csv"])
        #expect(root.path == "/Users/demo", "子層不改動上一層")
        #expect(await host.unmetExpectations.isEmpty)
    }

    @Test("骨架(#496):第一次列資料夾時是載入中,骨架列數取上次列過的項目數;列完記住新的數量")
    func skeletonRowCountFollowsLastListing() async throws {
        let store = InMemorySkeletonRowCountStore()
        store.save(5, for: .files)
        let host = FakeHost()
        await host.expect(HostFolderCommand.list(nil), reply: FakeReply(stdout: Data(Self.home.utf8)))
        let model = FolderBrowserModel(folders: HostFolders(channel: host), hostName: "Studio Mac", skeletonRowCounts: store)
        #expect(model.phase == .loading)
        #expect(model.loadingRowCount == 5)

        await model.load()
        #expect(Self.listed(model).count == 2)
        #expect(model.loadingRowCount == SkeletonLoading.rowCountRange.lowerBound)
        #expect(store.load(.files) == 2)
    }

    @Test("骨架(#496):下拉重新整理已經列出的資料夾,讀取中仍顯示原本的列,不退回骨架")
    func refreshKeepsContent() async throws {
        let host = FakeHost()
        await host.expect(HostFolderCommand.list(nil), reply: FakeReply(stdout: Data(Self.home.utf8)))
        await host.expect(HostFolderCommand.list("/Users/demo"), reply: FakeReply(keepsOpen: true))
        let model = Self.model(host)
        await model.load()
        let before = Self.listed(model)

        let refreshing = Task { await model.load() }
        defer { refreshing.cancel() }
        _ = await host.waitUntilClosed(execution: 1, timeout: .milliseconds(300))
        #expect(model.phase != .loading)
        #expect(Self.listed(model) == before)
    }

    @Test("先列家目錄：標題是資料夾最後一段，副標是主機")
    func listsHome() async throws {
        let host = FakeHost()
        await host.expect(HostFolderCommand.list(nil), reply: FakeReply(stdout: Data(Self.home.utf8)))
        let model = Self.model(host)

        await model.load()

        #expect(Self.listed(model) == ["ledger", ".zshrc"])
        #expect(model.path == "/Users/demo")
        #expect(model.title == "demo")
        #expect(model.hostName == "Studio Mac")
        #expect(model.canGoUp)
    }

    @Test("主機回應的不是資料夾清單：顯示錯誤")
    func showsErrorForNonListing() async throws {
        let host = FakeHost()
        await host.expect(HostFolderCommand.list(nil), reply: FakeReply(stdout: Data("Welcome!\n/Users/demo\n".utf8)))
        let model = Self.model(host)

        await model.load()

        #expect(model.phase == .failed("The host didn’t respond with a folder listing."))
    }

    @Test("打開資料夾、回上一層")
    func opensFolderAndGoesUp() async throws {
        let host = FakeHost()
        await host.expect(HostFolderCommand.list(nil), reply: FakeReply(stdout: Data(Self.home.utf8)))
        await host.expect(HostFolderCommand.list("/Users/demo/ledger"), reply: FakeReply(stdout: Data(Self.ledger.utf8)))
        await host.expect(HostFolderCommand.list("/Users/demo"), reply: FakeReply(stdout: Data(Self.home.utf8)))
        let model = Self.model(host)
        await model.load()

        await model.open(FolderEntry(name: "ledger", kind: .folder, size: 96))
        #expect(model.title == "ledger")
        #expect(Self.listed(model) == ["export.csv"])

        await model.goUp()
        #expect(model.path == "/Users/demo")
        #expect(await host.unmetExpectations.isEmpty)
    }

    @Test("根目錄沒有上一層;根目錄底下的資料夾路徑不重複斜線")
    func rootHasNoParent() async throws {
        let host = FakeHost()
        await host.expect(HostFolderCommand.list(nil), reply: FakeReply(stdout: Data("/\ndrwxr-xr-x 2 0 0 64 Nov 16 05:12 tmp\n".utf8)))
        await host.expect(HostFolderCommand.list("/tmp"), reply: FakeReply(stdout: Data("/tmp\n".utf8)))
        let model = Self.model(host)
        await model.load()

        #expect(model.title == "/")
        #expect(!model.canGoUp)
        await model.open(FolderEntry(name: "tmp", kind: .folder, size: 64))
        #expect(model.path == "/tmp")
    }

    @Test("檔案不能打開(不送指令)")
    func filesDoNotOpen() async throws {
        let host = FakeHost()
        await host.expect(HostFolderCommand.list(nil), reply: FakeReply(stdout: Data(Self.home.utf8)))
        let model = Self.model(host)
        await model.load()

        await model.open(FolderEntry(name: ".zshrc", kind: .file, size: 12))

        #expect(await host.executions.count == 1)
        #expect(model.path == "/Users/demo")
    }

    @Test("上傳到目前的資料夾，成功後重新整理清單")
    func uploadsAndReloads() async throws {
        let host = FakeHost()
        await host.expect(HostFolderCommand.list(nil), reply: FakeReply(stdout: Data(Self.home.utf8)))
        await host.expect(
            HostFolderCommand.upload(folder: "/Users/demo", name: "notes.txt", size: 5),
            reply: FakeReply(stdout: Data("/Users/demo/notes.txt\n".utf8)))
        await host.expect(HostFolderCommand.list("/Users/demo"), reply: FakeReply(stdout: Data(Self.home.utf8)))
        let model = Self.model(host)
        await model.load()

        await model.upload(Data("hello".utf8), named: "notes.txt")

        #expect(await host.executions[1].stdin == Data("hello".utf8))
        #expect(await host.executions[1].closedStdin)
        #expect(await host.unmetExpectations.isEmpty)
        #expect(model.notice == nil)
        #expect(model.uploading == nil)
    }

    @Test("超過 25 MB 的檔案拒絕上傳：不讀檔、不送指令，說明上限")
    func rejectsLargeFileBeforeReading() async throws {
        let host = FakeHost()
        await host.expect(HostFolderCommand.list(nil), reply: FakeReply(stdout: Data(Self.home.utf8)))
        let model = Self.model(host)
        await model.load()
        let file = FileManager.default.temporaryDirectory.appending(path: "purrdr-big-\(UUID().uuidString).bin")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(HostFolders.maximumUploadSize + 1))
        try handle.close()

        await model.upload(fileAt: file)

        #expect(model.notice == "Files over 25 MB can’t be uploaded.")
        #expect(await host.executions.count == 1)
    }

    @Test("同名檔案已存在：說明不會覆寫")
    func explainsExistingName() async throws {
        let host = FakeHost()
        await host.expect(HostFolderCommand.list(nil), reply: FakeReply(stdout: Data(Self.home.utf8)))
        await host.expect(HostFolderCommand.upload(folder: "/Users/demo", name: ".zshrc", size: 1), reply: FakeReply(exitCode: 73))
        let model = Self.model(host)
        await model.load()

        await model.upload(Data("x".utf8), named: ".zshrc")

        #expect(model.notice == "There’s already an item named “.zshrc” in this folder. Rename the file and try again.")
    }
}
