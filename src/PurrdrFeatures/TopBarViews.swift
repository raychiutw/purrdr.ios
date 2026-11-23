import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

// 共用頂列的畫面(#499、spec #491):大標題在左,右側是長型玻璃膠囊 [電腦圖示｜＋] 加獨立頭像圓鈕;
// 往下滑時標題列淡出,有搜尋的 tab 搜尋欄變成貼頂玻璃膠囊,其餘 tab 顯示置中小標題膠囊。
// 邏輯與尺寸在 `TopBarModel.swift`。顏色一律系統單色(`.primary`),不吃外層 tint、也不吃主機主題。

/// 檔案、主機、流量 tab 的頂列動作(#500):由 `TopNavigationView` 提供,畫面本身不知道有哪些 sheet。
package struct TabTopBarActions {
    var addHost: () -> Void
    var account: AnyView

    package init(addHost: @escaping () -> Void, account: AnyView) {
        self.addHost = addHost
        self.account = account
    }
}

/// 一個 tab 的頂列內容。畫面狀態(捲動、搜尋焦點)在 `TopBarModifier` 裡。
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
    /// 最右側的頭像圓鈕。
    var account: AnyView
    /// 有搜尋的 tab 才有:搜尋字串與焦點。
    var search: Search?

    struct Search {
        var text: Binding<String>
        var focus: FocusState<Bool>.Binding
        /// 搜尋欄的提示文字(聊天:搜尋 Tab、Workspace、主機)。
        var prompt: LocalizedStringKey = "Search"
    }
}

extension View {
    /// 共用頁面(#500):第一階 tab 的頁面骨架。頁面底色、iPad 寬視窗的內容寬度上限、導覽標題(返回鈕用,導覽列本身隱藏)與共用頂列
    /// (大標題、捲動收合、右側控制項)都在這裡,各 tab 不再各自設定。內容是含捲動視圖的畫面(List 或 ScrollView)。
    func topBarPage(_ content: TopBarContent) -> some View {
        appPageContentWidth()
            .background(AppSurface.groupedPage)
            .topBar(content)
            .navigationTitle(content.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
    }

    /// 套上共用頂列:內容(列表)從頂列下面開始,往下滑時頂列收合。要放在含有捲動視圖的內容上。
    func topBar(_ content: TopBarContent) -> some View {
        modifier(TopBarModifier(content: content))
    }
}

private struct TopBarModifier: ViewModifier {
    let content: TopBarContent
    @State private var offset: CGFloat = 0
    @ScaledMetric(relativeTo: .largeTitle) private var typeScale: CGFloat = 1
    @Environment(\.scenePhase) private var scenePhase

    private var spec: TopBarSpec { content.tab.topBar ?? TopBarSpec(plus: nil, hasHostScope: false, hasSearch: false) }
    private var layout: TopBarLayout { TopBarLayout(hasSearch: spec.hasSearch, typeScale: typeScale) }

    func body(content view: Content) -> some View {
        let scroll = TopBarScroll(offset: offset)
        view
            .contentMargins(.top, layout.contentInset, for: .scrollContent)
            // 往下捲的距離(靜止時為 0)。前景才追蹤(#492:背景不更新畫面狀態)。
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, new in
                guard scenePhase == .active else { return }
                offset = new
            }
            #if os(iOS)
            .toolbarVisibility(.hidden, for: .navigationBar)
            #endif
            .overlay(alignment: .top) {
                TopBarOverlay(content: content, layout: layout, spec: spec, scroll: scroll)
            }
    }
}

/// 頂列本體:標題列(標題、控制項、頭像)、搜尋欄或小標題膠囊,與內容從狀態列下滑過時的漸層遮罩。
private struct TopBarOverlay: View {
    let content: TopBarContent
    let layout: TopBarLayout
    let spec: TopBarSpec
    let scroll: TopBarScroll

    var body: some View {
        ZStack(alignment: .top) {
            // 內容從狀態列下滑過時,上緣漸層遮住(64pt,頁面底色 → 透明)。
            LinearGradient(
                stops: [.init(color: AppSurface.groupedPage, location: 0), .init(color: AppSurface.groupedPage, location: 0.6),
                        .init(color: AppSurface.groupedPage.opacity(0), location: 1)],
                startPoint: .top, endPoint: .bottom)
                .frame(height: TopBarMetrics.fadeMaskHeight)
                .ignoresSafeArea(edges: .top)
                .opacity(scroll.progress)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            // 收合後標題列整個拿掉(透明度已是 0):只靠 accessibilityHidden 時,XCUI 的樹仍留著它的元素。
            if !scroll.isCollapsed { titleRow }
            switch spec.collapsed {
            case .searchCapsule:
                if let search = content.search {
                    TopBarSearchField(search: search, layout: layout, progress: scroll.progress)
                        .padding(.top, layout.searchTop(progress: scroll.progress))
                }
            case .smallTitleCapsule:
                TopBarSmallTitle(title: content.title)
                    .padding(.top, TopBarMetrics.collapsedSearchTop)
                    .opacity(scroll.progress)
                    .allowsHitTesting(false)
                    .accessibilityHidden(!scroll.isCollapsed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        // 頂列元件採系統單色:不傳遞外層的 tint(主機主題與 app 主色都不影響)。
        .tint(Color.primary)
    }

    private var titleRow: some View {
        HStack(spacing: TopBarMetrics.controlSpacing) {
            Text(content.title)
                .font(.system(size: layout.titleSize, weight: .bold))
                .tracking(-0.01 * layout.titleSize)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                // 窄欄(iPad 內容欄 340pt)寬度不夠時標題先縮小,不截斷成「Ch…」。
                .minimumScaleFactor(0.7)
                .layoutPriority(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("topBar.title")
            Spacer(minLength: TopBarMetrics.controlSpacing)
            TopBarControls(content: content, spec: spec)
        }
        .padding(.leading, TopBarMetrics.leadingMargin)
        .padding(.trailing, TopBarMetrics.trailingMargin)
        .frame(height: layout.titleRowHeight)
        .opacity(scroll.titleOpacity)
        .offset(y: scroll.titleOffset)
        // 收合後標題列是隱形的:不能點、VoiceOver 也不讀(回到頂端就會回來)。
        .allowsHitTesting(!scroll.isCollapsed)
        .accessibilityHidden(scroll.isCollapsed)
    }
}

/// 右側控制項:[電腦圖示｜＋] 膠囊(或單顆圓鈕)加頭像圓鈕。尺寸固定,不隨 Dynamic Type 放大。
private struct TopBarControls: View {
    let content: TopBarContent
    let spec: TopBarSpec

    var body: some View {
        HStack(spacing: TopBarMetrics.controlSpacing) {
            switch spec.controls {
            case .pill:
                HStack(spacing: 0) {
                    hostScope.frame(width: TopBarMetrics.pillSegmentWidth, height: TopBarMetrics.controlHeight)
                    Rectangle().fill(.separator).frame(width: 1, height: TopBarMetrics.pillDividerHeight)
                    plus.frame(width: TopBarMetrics.pillSegmentWidth, height: TopBarMetrics.controlHeight)
                }
                .frame(width: TopBarMetrics.pillWidth, height: TopBarMetrics.controlHeight)
                .floatingGlass(in: Capsule())
            case .plusOnly:
                plus.frame(width: TopBarMetrics.circleDiameter, height: TopBarMetrics.controlHeight)
                    .floatingGlass(in: Circle())
            case .hostScopeOnly:
                hostScope.frame(width: TopBarMetrics.circleDiameter, height: TopBarMetrics.controlHeight)
                    .floatingGlass(in: Circle())
            case .none:
                EmptyView()
            }
            content.account
        }
        // 控制項尺寸固定:長按用 large content viewer 看放大版。
        .dynamicTypeSize(.large)
    }

    @ViewBuilder
    private var hostScope: some View {
        if let menu = content.hostMenu {
            Menu {
                menu
            } label: {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: TopBarMetrics.iconSize, weight: .regular))
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topTrailing) {
                        // 已篩選某台主機:圖示右上角的小圓點(沒篩選時沒有;VoiceOver 念主機名,圓點不讀)。
                        if content.hostScope.showsDot {
                            Circle()
                                .fill(Color.appAccent)
                                .frame(width: TopBarMetrics.dotDiameter, height: TopBarMetrics.dotDiameter)
                                .padding(.top, TopBarMetrics.dotInset)
                                .padding(.trailing, TopBarMetrics.dotInset)
                                .accessibilityHidden(true)
                                .accessibilityIdentifier("topBar.hostDot")
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: content.hostScope.accessibilityLabel))
            .accessibilityIdentifier(content.hostIdentifier)
        }
    }

    @ViewBuilder
    private var plus: some View {
        if let plus = content.plus { plus }
    }
}

/// 「＋」按鈕(新增聊天、新增主機等):系統 `plus` 符號。
struct TopBarPlusButton: View {
    let title: LocalizedStringKey
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: TopBarMetrics.iconSize, weight: .regular))
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier(identifier)
    }
}

/// 最右側的頭像圓鈕:會員的第一個字(沒登入是人頭符號),系統單色玻璃圓,點了開帳號。
struct TopBarAccountButton: View {
    let member: MemberModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let signedIn = signedInMember {
                    if let initial = signedIn.avatarInitial {
                        Text(verbatim: initial)
                            .font(.system(size: TopBarMetrics.avatarInitialSize, weight: .bold))
                    } else {
                        Image(systemName: "person.fill")
                    }
                } else {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: TopBarMetrics.iconSize))
                }
            }
            .foregroundStyle(Color.primary)
            .frame(width: TopBarMetrics.circleDiameter, height: TopBarMetrics.circleDiameter)
            .floatingGlass(in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Account"))
        .accessibilityIdentifier("toolbar.account")
        .task { if member.phase == .unknown { await member.restore() } }
    }

    private var signedInMember: Member? {
        if case .signedIn(let member) = member.phase { return member }
        return nil
    }
}

/// 搜尋欄:未收合是系統填色的全圓角欄,往下滑變成貼頂玻璃膠囊。
private struct TopBarSearchField: View {
    let search: TopBarContent.Search
    let layout: TopBarLayout
    let progress: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.secondaryText)
                .accessibilityHidden(true)
            TextField(text: search.text) {
                Text(search.prompt)
            }
            .focused(search.focus)
            .submitLabel(.search)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
            .accessibilityIdentifier("agentList.search")
            if !search.text.wrappedValue.isEmpty {
                Button {
                    search.text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear text"))
            }
        }
        // 搜尋欄高度最多放大 1.45 倍(`searchScaleCap`):圖示與文字也封頂,不然放大鏡會比膠囊還大。
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, 12)
        .frame(height: layout.searchHeight(progress: progress))
        .background {
            ZStack {
                Capsule().fill(.fill.tertiary).opacity(1 - progress)
                Color.clear.floatingGlass(in: Capsule()).opacity(progress)
            }
        }
        .padding(.horizontal, TopBarMetrics.searchMargin)
    }
}

/// 沒有搜尋的 tab 收合後的置中小標題:17pt Semibold 玻璃膠囊。
private struct TopBarSmallTitle: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.system(size: TopBarMetrics.smallTitleSize, weight: .semibold))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, TopBarMetrics.smallTitleInset)
            .frame(height: TopBarMetrics.smallTitleHeight)
            .floatingGlass(in: Capsule())
    }
}
