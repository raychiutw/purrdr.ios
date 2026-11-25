import Foundation
import Testing

/// 第一階頂列一律用系統元件(#615、spec #612):不隱藏系統導覽列改自繪頂列,不自畫漸層遮罩、搜尋欄或膠囊,
/// 工具列項目不自加寬度。守門原始碼,擋這些做法長回來。
@Suite("系統頂列用法")
struct SystemTopBarUsageTests {
    static let featuresFolder = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "src/PurrdrFeatures")

    static var featureFiles: [(name: String, text: String)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: featuresFolder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "swift" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in (try? String(contentsOf: url, encoding: .utf8)).map { (url.lastPathComponent, $0) } }
    }

    @Test("不隱藏系統導覽列(toolbarVisibility(.hidden, for: .navigationBar))")
    func neverHidesNavigationBar() {
        let files = Self.featureFiles
        #expect(files.count > 10, "找不到 src/PurrdrFeatures 的原始碼")
        for (name, text) in files {
            let hidden = text.contains(".toolbarVisibility(.hidden, for: .navigationBar)") || text.contains(".toolbar(.hidden, for: .navigationBar)")
            #expect(!hidden, "\(name) 隱藏了系統導覽列;頂列要用系統的 navigationTitle／toolbar／searchable")
        }
    }

    @Test("頂列檔案不自畫:沒有漸層遮罩、捲動量測、floatingGlass 膠囊、自畫搜尋欄、自訂寬度")
    func topBarFileDrawsNothing() throws {
        let text = try String(contentsOf: Self.featuresFolder.appending(path: "TopBarViews.swift"), encoding: .utf8)
        for pattern in ["LinearGradient", "onScrollGeometryChange", "floatingGlass", "TextField(", "Capsule()", ".frame(width:", ".frame(minWidth:"] {
            #expect(!text.contains(pattern), "TopBarViews.swift 不該自己畫頂列(\(pattern));交給系統")
        }
        #expect(text.contains(".searchable("), "頂列搜尋要用系統 searchable")
        #expect(text.contains("ToolbarItemGroup"), "電腦圖示與＋要放同一個 ToolbarItemGroup 讓系統合成膠囊")
        #expect(text.contains("ToolbarSpacer"), "頭像要用 ToolbarSpacer 與膠囊隔開")
    }
}

/// 選主機全 app 只有一種長相:頂列右上電腦圖示選單(#616、spec #612)。主機 tab 不再有頁面內的主機清單。
@Suite("選主機只有電腦圖示選單")
struct HostPickerSingleStyleTests {
    private func source(_ name: String) throws -> String {
        try String(contentsOf: SystemTopBarUsageTests.featuresFolder.appending(path: name), encoding: .utf8)
    }

    @Test("主機頁內沒有主機清單(hostListSection、hosts.host.<名稱> 列)")
    func overviewHasNoHostList() throws {
        let text = try source("HostOverviewView.swift")
        #expect(!text.contains("hostListSection"), "主機頁內不放主機清單,選主機在右上電腦圖示選單")
        #expect(!text.contains("\"hosts.host."), "主機頁內不放主機清單列")
    }

    @Test("主機 tab 的頂列有電腦圖示選單,並且處理需要重新確認的主機")
    func hostsTabUsesHostMenu() throws {
        let text = try source("HostsTab.swift")
        #expect(text.contains("hostMenu:"), "主機 tab 的頂列要給電腦圖示選單")
        #expect(text.contains("HostSelectionMenu("), "主機 tab 與檔案 tab 共用同一個選單")
        #expect(text.contains("reconfirm"), "需要重新確認的主機點了進編輯頁(#572)")
    }
}

/// 檔案 tab 的資料夾是 push(#620、spec #612):點資料夾推入下一層,不在原頁換內容。
@Suite("檔案資料夾用 push")
struct FilesPushUsageTests {
    private func source(_ name: String) throws -> String {
        try String(contentsOf: SystemTopBarUsageTests.featuresFolder.appending(path: name), encoding: .utf8)
    }

    @Test("資料夾瀏覽以 navigationDestination 推入下一層,不再直接 model.open 原地換內容")
    func foldersArePushed() throws {
        let view = try source("FolderBrowserView.swift")
        #expect(!view.contains("model.open("), "點資料夾要 push,不要原地換內容")
        #expect(view.contains("FolderRoute"), "每層資料夾是一個路由")
        let host = try source("HostPickerViews.swift")
        #expect(host.contains("navigationDestination(for: FolderRoute.self)"), "檔案 tab 的下一層要用 navigationDestination 推入")
        let tabs = try source("TopLevelTabs.swift")
        #expect(tabs.contains("NavigationStack(path:"), "檔案 tab 的 NavigationStack 要綁路徑,麵包屑才能跳層")
    }

    @Test("空資料夾與搜尋無結果用系統的 ContentUnavailableView")
    func emptyStatesAreSystem() throws {
        let view = try source("FolderBrowserView.swift")
        #expect(view.contains("ContentUnavailableView.search("), "搜尋無結果用系統搜尋版本")
        #expect(!view.contains("Text(\"This folder is empty.\")"), "空資料夾不要用純文字列")
    }
}

/// 新增聊天與登入 Shell:新增聊天是 push、選主機是右上電腦圖示選單,沒有標題膠囊(#621、spec #612)。
@Suite("新增聊天 push 與選主機選單")
struct NewChatPushUsageTests {
    private func source(_ name: String) throws -> String {
        try String(contentsOf: SystemTopBarUsageTests.featuresFolder.appending(path: name), encoding: .utf8)
    }

    @Test("標題膠囊 SheetHostPicker 不存在,新增聊天與登入 Shell 用右上電腦圖示選單")
    func hostPickerIsToolbarMenu() throws {
        for (name, text) in SystemTopBarUsageTests.featureFiles {
            #expect(!text.contains("SheetHostPicker"), "\(name) 還在用標題膠囊選主機")
        }
        #expect(try source("HostPickerViews.swift").contains("struct HostMenuButton"))
        let chat = try source("NewChatView.swift")
        #expect(chat.contains("HostMenuButton("))
        #expect(!chat.contains("placement: .principal"), "新增聊天標題用系統大標題,不放自畫的主機鈕")
        #expect(try source("PaneTerminalView.swift").contains("HostMenuButton("))
    }

    @Test("新增聊天不是 sheet:沒有 NavigationStack、presentationDetents,由導覽 push")
    func newChatIsPushed() throws {
        let view = try source("NewChatView.swift")
        for pattern in ["NavigationStack", "appSheet(", "presentationDragIndicator", "interactiveDismissDisabled"] {
            #expect(!view.contains(pattern), "新增聊天是 push,不該有 \(pattern)")
        }
        let top = try source("TopNavigationView.swift")
        #expect(top.contains(".navigationDestination(isPresented: $navigation.isNewChatOpen)"))
        #expect(!top.contains("case .newChat:"), "新增聊天不再是 sheet 的一種")
        #expect(!(try source("TopNavigationModel.swift")).contains("case newChat\n"), "TopLevelSheet 沒有 newChat")
    }

    @Test("新增聊天的資料夾瀏覽每往下一層是 push,頁面用 appGroupedList")
    func folderPickerIsPushed() throws {
        let view = try source("NewChatView.swift")
        #expect(view.contains(".navigationDestination(for: NewChatFolderRoute.self)"))
        #expect(view.contains("FolderPickerLevelView"))
        #expect(!view.contains(".appSheetList()"), "pushed 頁面用 appGroupedList")
    }

    @Test("資料夾列是系統 NavigationLink,不自放 chevron、不用 plain 按鈕(#621)")
    func folderRowsUseNavigationLink() throws {
        let text = try source("FolderBrowserView.swift")
        let start = try #require(text.range(of: "struct FolderEntryRow"))
        let end = try #require(text.range(of: "private var label", range: start.upperBound..<text.endIndex))
        let row = String(text[start.lowerBound..<end.lowerBound])
        #expect(row.contains("NavigationLink(value: route)"))
        #expect(!row.contains("chevron"), "列尾 > 由 NavigationLink 給")
        #expect(!row.contains(".buttonStyle(.plain)"))
        #expect(!text.contains("Rectangle().fill(.bar)"), "麵包屑不自鋪 .bar 材質")
        #expect(!text.contains(".alert(\"Can’t Upload\""), "上傳失敗寫在頁面上,不彈對話框")
        let chat = try source("NewChatView.swift")
        #expect(chat.contains(".safeAreaBar(edge: .top)"), "資料夾瀏覽頂部固定列用系統 safeAreaBar")
        #expect(chat.contains("ContentUnavailableView(\"No Folders\""), "空資料夾用系統空狀態")
    }

    @Test("終端機標題用系統標題＋副標題,不自畫;TopBarMetrics 不留不用的常數")
    func terminalTitleAndMetrics() throws {
        let terminal = try source("PaneTerminalView.swift")
        #expect(terminal.contains(".navigationSubtitle("))
        #expect(!terminal.contains("struct TerminalTitle"), "終端機標題不自畫兩行 principal")
        #expect(!terminal.contains("placement: .principal"))
        for (name, text) in SystemTopBarUsageTests.featureFiles {
            #expect(!text.contains("controlHeight"), "\(name) 還在用 TopBarMetrics.controlHeight")
        }
    }
}
