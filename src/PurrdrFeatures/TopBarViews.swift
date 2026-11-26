import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

// 第一階 tab 的頂列(#499、#615、spec #612):全部是系統原生——大標題、右側 `ToolbarItemGroup` 膠囊、`ToolbarSpacer`、頭像、
// `searchable`。邏輯在 `TopBarModel.swift`。顏色一律系統單色(`.primary`),不吃外層 tint、也不吃主機主題。

/// 檔案、主機、流量 tab 的頂列動作(#500):由 `TopNavigationView` 提供,畫面本身不知道有哪些 sheet。
package struct TabTopBarActions {
    var addHost: () -> Void
    var account: AnyView

    package init(addHost: @escaping () -> Void, account: AnyView) {
        self.addHost = addHost
        self.account = account
    }
}

/// 一個 tab 的頂列內容。
struct TopBarContent {
    var tab: TopLevelTab
    var title: LocalizedStringKey
    /// 電腦圖示的主機範圍(沒有主機範圍的 tab 忽略)。
    var hostScope = TopBarHostScope(filteredHostName: nil)
    /// 點電腦圖示出現的選單內容(主機範圍有多個實作:聊天改「目前主機」、流量過濾主機)。
    var hostMenu: AnyView?
    /// 電腦圖示的 accessibility identifier(各 tab 各自的測試入口;聊天沿用 `toolbar.currentHost`)。
    var hostIdentifier = "toolbar.currentHost"
    /// 「＋」那一段:按鈕或選單(只有符號,尺寸由共用頂列給)。
    var plus: AnyView?
    /// 最右側的頭像圓鈕。`nil`:這一欄不放(寬視窗的聊天列表,頭像在對話欄工具列,#520)。
    var account: AnyView?
    /// 有搜尋的 tab 才有:搜尋字串與焦點。
    var search: Search?

    struct Search {
        var text: Binding<String>
        var focus: FocusState<Bool>.Binding
        /// 搜尋欄的 accessibility identifier(各 tab 各自明確指定:聊天 `agentList.search`、檔案 `files.search`)。
        var identifier: String
        /// 搜尋欄的提示文字(聊天:搜尋 Tab、Workspace、主機)。
        var prompt: LocalizedStringKey = "Search"
    }
}

extension View {
    /// 共用頁面(#500、#615):第一階 tab 的頁面骨架。頁面底色、iPad 寬視窗的內容寬度上限,加上系統原生頂列:
    /// 大標題(`navigationTitle`)、右側 `ToolbarItemGroup`(電腦圖示與「＋」由系統合成一顆膠囊)、`ToolbarSpacer` 隔開的頭像,
    /// 有搜尋的 tab 用系統 `searchable`。尺寸、間距與捲動收合全由系統處理,這裡不自己畫、不隱藏系統導覽列。
    func topBarPage(_ content: TopBarContent) -> some View {
        modifier(TopBarPageModifier(content: content))
    }
}

private struct TopBarPageModifier: ViewModifier {
    let content: TopBarContent

    private func checkPlusConsistency() {
        assert((content.tab.topBar.plus != nil) == (content.plus != nil), "\(content.tab) 的頂列規格與內容對「＋」不一致")
    }

    func body(content view: Content) -> some View {
        // 「＋」有沒有:規格(`TopBarSpec.plus`)與內容給的按鈕要一致,不一致時開發期立刻看得到。
        let _: Void = checkPlusConsistency()
        view
            .appPageContentWidth()
            .background(AppSurface.groupedPage)
            .navigationTitle(content.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar { TopBarToolbar(content: content) }
            .modifier(TopBarSearchModifier(search: content.search))
    }
}

/// 頂列右側:[電腦圖示｜＋] 放同一個 `ToolbarItemGroup`(系統合成無分隔線膠囊),頭像是另一個項目、用固定 `ToolbarSpacer` 隔開。
/// 項目不自加寬度,交給系統排版。目前一律用 `topBarTrailing`(不依 OS 版本分流,`topBarPinnedTrailing` 尚未採用:空間不夠時系統會把項目收進 overflow,iPad 窄視窗與 tab bar 同列時要留意)。
/// 顏色一律系統單色(`.primary`),不吃外層 tint。
private struct TopBarToolbar: ToolbarContent {
    let content: TopBarContent

    private var placement: ToolbarItemPlacement {
        #if os(iOS)
        return .topBarTrailing
        #else
        return .automatic
        #endif
    }

    var body: some ToolbarContent {
        if content.hostMenu != nil || content.plus != nil {
            ToolbarItemGroup(placement: placement) {
                if let menu = content.hostMenu { TopBarHostScopeMenu(content: content, menu: menu) }
                if let plus = content.plus { plus }
            }
        }
        if let account = content.account {
            ToolbarSpacer(.fixed, placement: placement)
            ToolbarItem(placement: placement) { account }
        }
    }
}

/// 有搜尋的 tab 用系統 `searchable`(含往下滑收合);焦點接 `searchFocused`。
private struct TopBarSearchModifier: ViewModifier {
    let search: TopBarContent.Search?

    /// 搜尋欄放在導覽列大標題下面(iOS 26 的預設會移到底部工具列);平常收起、往下拉才出現(與系統「訊息」「備忘錄」一致),
    /// 所以聊天與其他 tab 一樣是正常大標題(#615)。
    private var searchPlacement: SearchFieldPlacement {
        #if os(iOS)
        .navigationBarDrawer(displayMode: .automatic)
        #else
        .automatic
        #endif
    }

    @ViewBuilder
    func body(content view: Content) -> some View {
        if let search {
            view
                .searchable(text: search.text, placement: searchPlacement, prompt: Text(search.prompt))
                .searchFocused(search.focus)
        } else {
            view
        }
    }
}

/// 電腦圖示:系統選單按鈕。已篩選某台主機時圖示右上角有小圓點(VoiceOver 念主機名,圓點不讀)。
private struct TopBarHostScopeMenu: View {
    let content: TopBarContent
    let menu: AnyView

    var body: some View {
        Menu {
            menu
        } label: {
            Image(systemName: "desktopcomputer")
                .overlay(alignment: .topTrailing) {
                    if content.hostScope.showsDot {
                        // 系統符號當小圓點(隨字級縮放,不寫死直徑,#615)。
                        Image(systemName: "circle.fill")
                            .font(.caption2)
                            .imageScale(.small)
                            .foregroundStyle(Color.appAccent)
                            .offset(x: 3, y: -3)
                            .accessibilityHidden(true)
                            .accessibilityIdentifier("topBar.hostDot")
                    }
                }
        }
        .accessibilityLabel(Text(verbatim: content.hostScope.accessibilityLabel))
        .accessibilityIdentifier(content.hostIdentifier)
    }
}

/// 「＋」按鈕(新增聊天、新增主機等):系統 `plus` 符號,尺寸交給系統工具列。
struct TopBarPlusButton: View {
    let title: LocalizedStringKey
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
        }
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier(identifier)
    }
}

/// 最右側的頭像鈕:會員的第一個字(沒登入是人頭符號),系統工具列按鈕,點了開帳號。
struct TopBarAccountButton: View {
    let member: MemberModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let signedIn = signedInMember {
                if let initial = signedIn.avatarInitial {
                    Text(verbatim: initial).fontWeight(.bold)
                } else {
                    Image(systemName: "person.fill")
                }
            } else {
                Image(systemName: "person.crop.circle")
            }
        }
        .accessibilityLabel(Text("Account"))
        .accessibilityIdentifier("toolbar.account")
        .task { if member.phase == .unknown { await member.restore() } }
    }

    private var signedInMember: Member? {
        if case .signedIn(let member) = member.phase { return member }
        return nil
    }
}
