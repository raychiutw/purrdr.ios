import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrSSH
import PurrdrTestSupport
import Testing

/// HTTPS 主機的新增聊天資料夾瀏覽(#731):與 SSH 共用同一個 `FolderPickerModel`／`NewChatFolders`,背後是主機服務的 `directory.list`。
@MainActor
@Suite("HTTPS 資料夾瀏覽")
struct HTTPSFolderBrowsingTests {
    final class FakeBrowser: DirectoryBrowsing, @unchecked Sendable {
        var version: String? = "0.16.0"
        var home: String? = "/Users/demo"
        var tree: [String: [String]] = [
            "/Users/demo": ["ledger", "Notes", ".config", "app"],
            "/Users/demo/ledger": ["src"],
        ]
        var errors: [String: any Error] = [:]
        private(set) var listed: [String] = []

        func hostServiceVersion() async throws -> String? { version }
        func homeDirectory() async throws -> String? { home }
        func listDirectory(path: String) async throws -> HostServiceProtocol.DirectoryListResult {
            listed.append(path)
            if let error = errors[path] { throw error }
            guard let names = tree[path] else { throw DirectoryListError.notFound }
            return .init(requestId: "r", path: path, directories: names, truncated: false)
        }
    }

    private static func picker(_ browser: FakeBrowser, start: String? = nil) -> FolderPickerModel {
        FolderPickerModel(folders: NewChatFolders(browser: browser), start: start)
    }

    private static func newChat(_ browser: FakeBrowser) -> NewChatModel {
        let folders = NewChatFolders(browser: browser)
        let connection = FailingHostConnection(error: HostServiceError.unexpectedResponse)
        return NewChatModel(launcher: NewChatLauncher(client: HerdrClient(connection: connection), folders: folders), folders: folders)
    }

    @Test("從家目錄開始:列子資料夾(不含隱藏、不分大小寫排序)")
    func listsHome() async {
        let picker = Self.picker(FakeBrowser())
        await picker.load()
        guard case .loaded(let listing) = picker.state else { Issue.record("沒讀到"); return }
        #expect(listing.path == "/Users/demo")
        #expect(listing.folders == ["app", "ledger", "Notes"])
    }

    @Test("進入子資料夾、上一層")
    func openAndGoUp() async {
        let picker = Self.picker(FakeBrowser())
        await picker.load()
        await picker.open("ledger")
        #expect(picker.chosenPath == "/Users/demo/ledger")
        await picker.goUp()
        #expect(picker.chosenPath == "/Users/demo")
    }

    @Test("`~/ledger` 以家目錄換成絕對路徑再列")
    func tildeExpanded() async {
        let browser = FakeBrowser()
        let picker = Self.picker(browser, start: "~/ledger")
        await picker.load()
        #expect(picker.chosenPath == "/Users/demo/ledger")
        #expect(browser.listed == ["/Users/demo/ledger"])
    }

    @Test("開始前解析路徑:展開 `~`、絕對路徑照用、相對路徑要求完整路徑")
    func resolve() async throws {
        let folders = NewChatFolders(browser: FakeBrowser())
        #expect(try await folders.resolve("~/ledger") == "/Users/demo/ledger")
        #expect(try await folders.resolve("~") == "/Users/demo")
        #expect(try await folders.resolve("/srv/app") == "/srv/app")
        await #expect(throws: NewChatFolderError.absolutePathRequired("app")) { try await folders.resolve("app") }
    }

    @Test("主機沒回報家目錄:說明找不到家目錄")
    func homeUnavailable() async {
        let browser = FakeBrowser()
        browser.home = nil
        let picker = Self.picker(browser)
        await picker.load()
        guard case .failed(let error) = picker.state else { Issue.record("應失敗"); return }
        #expect(error.text == FolderPickerModel.message(for: NewChatFolderError.homeUnavailable))
    }

    @Test("錯誤對應白話說明:找不到、不能開、讀不了")
    func errors() async {
        let browser = FakeBrowser()
        browser.errors["/a"] = DirectoryListError.notAllowed
        browser.errors["/b"] = DirectoryListError.unreadable
        let cases: [(String, DirectoryListError)] = [("/gone", .notFound), ("/a", .notAllowed), ("/b", .unreadable)]
        for (path, error) in cases {
            let picker = Self.picker(browser, start: path)
            await picker.load()
            guard case .failed(let shown) = picker.state else { Issue.record("應失敗 \(path)"); continue }
            #expect(shown.text == FolderPickerModel.message(for: error))
        }
        let messages = Set(cases.map { FolderPickerModel.message(for: $0.1) })
        #expect(messages.count == 3)
    }

    @Test("主機服務 0.12.0 以上:查過版本後開放瀏覽")
    func availableAfterVersionCheck() async {
        let model = Self.newChat(FakeBrowser())
        #expect(!model.canBrowseFolders)
        await model.loadAccess()
        #expect(model.canBrowseFolders)
        #expect(!model.folderBrowsingNeedsUpdate)
    }

    @Test("主機服務比 0.12.0 舊:不開放瀏覽、事先說明要更新,不送 directory.list")
    func outdatedHostService() async {
        let browser = FakeBrowser()
        browser.version = "0.11.0"
        let model = Self.newChat(browser)
        await model.loadAccess()
        #expect(!model.canBrowseFolders)
        #expect(model.folderBrowsingNeedsUpdate)
        #expect(browser.listed.isEmpty)
    }

    @Test("讀不到版本:不開放瀏覽,但不說要更新")
    func unknownVersion() async {
        let browser = FakeBrowser()
        browser.version = nil
        let model = Self.newChat(browser)
        await model.loadAccess()
        #expect(!model.canBrowseFolders)
        #expect(!model.folderBrowsingNeedsUpdate)
    }
}
