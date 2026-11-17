# iPhone Duo 折疊區與鏡頭區:官方 API 與 Purrdr 的現況(截至 2026-11-17)

> 目的:#69(#31 拆出)要求主要畫面(Agent 列表、對話、終端機按鍵列)不把可互動元件放在 iPhone Duo 的折疊區與鏡頭區，且只用官方 API。本文整理官方資料、確認本機工具鏈能不能用，並記錄哪些項目「待 API／待實機」。
>
> 標記:引號內英文 = 一手原文(逐字);**【推論】** = 依原文套到 Purrdr 的判斷;**【本機驗證】** = 在本機實際跑過的結果。第三方文章只當線索，結論都回官方頁確認。

## 1. 結論

1. 官方 API 是 **`ReservedRegion`**(SwiftUI:`GeometryProxy.reservedRegions(kind:options:layoutDirectionBehavior:)`;UIKit:`UIView.reservedRegions(kind:options:)`)與 **`ArrangementView`**(UIKit:`UIArrangementViewController`),**iOS 27.1 起才有**,隨 **Xcode 27.1** 的 iOS 27.1 SDK 提供。iPhone Duo 模擬器也是 Xcode 27.1 才有。
2. 本機是 Xcode 27.0(27A266a,iOS Simulator SDK 27.0):**編譯不到這些 API,也沒有 iPhone Duo 模擬器**【本機驗證，見 §4】。本機無法驗證;但 CI 的 `xcode-27` 映像已是 Xcode 27.1(27A9275,iPhoneSimulator27.1.sdk),所以終端機按鍵列的折疊區處理已實作並由 CI 編譯把關(見 §6),模擬器與實機確認仍待辦。
3. 不用 SDK 裡的私有符號，也不寫死座標:iOS 27.0 SDK 的 SwiftUICore 二進位已經有 `ReservedRegion` 符號，但公開的 `.swiftinterface` 沒有，屬於非公開 API。
4. 用 iOS 27 SDK(包含 27.0)建置的 app,系統在 iPhone Duo 上會**避開右側的狀態列**(外螢幕前鏡頭就在這一欄);27.1 SDK 起才會延伸到全螢幕、工具列改到側邊。所以目前的建置，外鏡頭由系統處理【官方，見 §2.4】。
5. 現有畫面已經是 Apple 建議的做法：三欄 `NavigationSplitView`(系統會依折疊調整欄寬)、按 safe area 排版、主要畫面的互動元件沒有 `ignoresSafeArea`、沒有綁定裝置尺寸的固定寬度。真正需要 `ReservedRegion` 的是**自訂排版的元件**,Purrdr 裡最明顯的是終端機的按鍵列(橫向一整條)與終端機畫面(見 §3)。

## 2. 官方資料

### 2.1 HIG:Designing for iPhone Duo(2026-09-09 新頁)

來源:<https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo>

> "The reserved regions on iPhone Duo include: The outer front-facing camera. This region is always present, and expands into the Dynamic Island for Live Activities. When controls are on the side, the system automatically accounts for it and arranges elements accordingly. / The inner front-facing camera. This region is only present when the camera is active. … when the camera activates, the UI moves aside to indicate the presence of the camera. / The folding region. This region is conditional based on how a person uses the device. When the device is partially open, the folding region divides the inner display into multiple usable regions, excluding the region at the center as the display folds."

> "Many system components automatically adapt to reserved regions. Components like alerts, context menus, and sheets automatically move to account for the fold, while larger components like split views adapt their columns' width and margins to match the symmetry of the inner display. For custom components, ReservedRegion (SwiftUI) and UIView.ReservedRegion (UIKit) provide a way to reposition content away from reserved regions."

> "Use the ReservedRegion API to keep important elements clear of the center if the system doesn't move them automatically." / "Avoid extreme layout changes as people fold the device. Move only what's necessary to keep elements visible and easy to tap."

> "Build your app to resize. … Use size classes, layout margins, and safe area insets to lay out controls and content. Avoid fixed widths and display-specific dependencies."

### 2.2 SwiftUI `ReservedRegion`

來源:<https://developer.apple.com/documentation/swiftui/reservedregion>、<https://developer.apple.com/documentation/swiftui/geometryproxy/reservedregions(kind:options:layoutdirectionbehavior:)>(兩頁 availability 都是 "iOS: 27.1.0 -")

- `occlusion`:"An area where an element, such as the Dynamic Island, a camera, or window controls, covers content. Place content outside this area."
- `division`:"An area where content splits into separate regions, such as at the fold of a hinge."
- "Framework-provided views, such as split views and sheets, adjust for reserved regions for you. If you build a custom view that places its own content, find out where the reserved regions are and arrange your content around them."
- "Scrolling containers, such as lists, tables, scroll views, and collection views, don't split their content around a division by default. When the device is partially open, a row or item can run across the fold. If that makes your content harder to read or use, check for division regions and arrange the content yourself."
- "Check for reserved regions yourself in custom views where controls or other important content might end up in the fold or near the camera. For example, check in a custom overlay, a floating control, or a view that positions its content with explicit frames or a custom Layout."
- "A division is active only when the device is partially open or closed. When iPhone Duo is fully open, the division is inactive"
- `frame` 是呼叫者 view 自己的座標，已含 `margins`("extra space around the reserved area that keeps interactive content clear of it");預設只回 active 的區域，`.includeInactive` 連 inactive 的也回(可先留位置，避免折疊時版面跳動)。

### 2.3 Preparing your app for iPhone Duo

來源:<https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo>

> "Build your app with the latest version of Xcode to use all of the available screen space on iPhone Duo. When you build with Xcode 26 and earlier, your app doesn't extend under the status bar and camera."

> "Prefer system-provided layouts and containers, such as split views, tab bars, arrangement views, and navigation stacks. These handle resizing, automatically adjusting for the outer display, fully open or folded inner display, and camera occlusions."

> "Identify elements or controls in your views that appear in the fold, and are difficult to see or interact with."

UIKit 對應:`UIView.reservedRegions(kind:options:)`(<https://developer.apple.com/documentation/uikit/uiview/reservedregion>)。

### 2.4 Apple Developer:iPhone Duo 準備頁與上架要求

- <https://developer.apple.com/iphone-duo/prepare/>:iPhone Duo 模擬器 "in Xcode 27.1";"The iPhone Duo simulator is the best way to test the full native experience." iOS 27 SDK:"Apps built with the iOS 27 SDK resize to fill most of the inner display on iPhone Duo, but still avoid the status bar on the right edge." iOS 27.1 SDK 以後:"Apps will extend to use the full display, with toolbars and tab bars appearing vertically below the status bar." 上傳 iPhone Duo 截圖後，產品頁會標示為 iPhone Duo 最佳化。
- <https://developer.apple.com/app-store/submitting/>(App Store Connect「準備迎接 iPhone Duo」提示連到的方向):"iPhone Duo is now in the hands of customers." 2027 年 4 月起 iOS app 要用 iOS 27 SDK 以後建置(Xcode 27.0 已符合;要用 `ReservedRegion` 則需 27.1)。

### 2.5 Xcode 27.1 Release Notes

來源:<https://developer.apple.com/documentation/xcode-release-notes/xcode-27_1-release-notes>

> "Xcode 27.1 includes Swift 6.4 and SDKs for iOS 27.1 …" / "Xcode 27.1 requires a Mac running macOS Tahoe 26.6 or later."

Known Issues 有 "StandBy is unavailable in the iPhone Duo Simulator runtime." 等條目，可見 iPhone Duo 模擬器 runtime 隨 27.1 提供。

## 3. Purrdr 主要畫面對照

| 畫面 | 結構 | 折疊區 | 鏡頭區 | 狀態 |
|---|---|---|---|---|
| Agent 列表 | `NavigationSplitView` 內容欄的 `List` | 內螢幕是 regular 寬度時是三欄，系統依折疊調整欄寬(§2.1);列表本身是捲動容器，列可能橫過水平折疊(筆電姿態),Apple 說預設如此 | 按 safe area;外鏡頭目前由系統避開(§2.4) | 系統元件，**待模擬器／實機確認**三欄在折疊時的欄寬 |
| 對話 | 詳細欄的 `ScrollView` + `safeAreaBar` 輸入列 + `safeAreaInset` 橫幅 | 書本姿態:詳細欄在折疊的一側(若系統照 §2.1 調整欄寬);筆電姿態：輸入列在下半部底端，不會在中線 | 同上 | **待模擬器／實機** |
| 終端機按鍵列 | 詳細欄底部、自訂的橫向一整條(`TerminalKeyBar`) | 詳細欄單獨全寬時(例如收起其他欄、或以「Open Terminal in New Window」開在支援多視窗的環境),書本姿態的垂直折疊會穿過按鍵列中段 → 這是 Apple 說要自己用 `ReservedRegion` 處理的「自訂元件」 | 按 safe area | **已實作**(§6):以 `reservedRegions(kind: .division)` 讓按鍵不落在折疊區(小幅調整，不重排);**待模擬器／實機** |
| 終端機畫面 | SwiftTerm(UIKit),全寬 | 終端機的格子無法拆成兩半;Apple 對捲動內容的建議是「若影響閱讀才自行處理」 | 按 safe area | **待實機**判斷是否需要處理 |

【推論】iOS 27.0 SDK 下 app 不延伸到狀態列那一欄，所以外鏡頭不會蓋到 Purrdr 的元件;內鏡頭只有相機使用中才出現，Purrdr 的拍照用系統的 `UIImagePickerController`(全螢幕)。這兩點仍需在 Duo 模擬器上看過才算確認。

## 4. 本機驗證

- `xcodebuild -version`:Xcode 27.0(27A266a);`xcrun --sdk iphonesimulator --show-sdk-version`:27.0。
- `xcrun simctl list devicetypes`:沒有 iPhone Duo(iPhone 只到 iPhone 18 Pro／Pro Max、17 系列、Air);runtime 只有 iOS 27.0。
- 以 iOS Simulator 27.0 SDK typecheck 一個只呼叫官方 API 的檔案(`if #available(iOS 27.1, *)` 內):

  ```text
  error: value of type 'GeometryProxy' has no member 'reservedRegions'
  error: value of type 'UIView' has no member 'reservedRegions'
  error: cannot find 'ArrangementView' in scope
  ```

- `SwiftUICore.tbd` 匯出 `SwiftUI.ReservedRegion`、`GeometryProxy.reservedRegions(kind:options:layoutDirectionBehavior:)` 等符號，但 SwiftUI／SwiftUICore 的公開 `.swiftinterface` 都沒有 → 非公開，不使用。

## 5. 待辦(待 API／待實機)

1. 升級到 Xcode 27.1(需要 macOS Tahoe 26.6 以後，本機是 macOS 27.2.1)後:
   - 在 iPhone Duo 模擬器跑各姿態(關閉、全開、書本、筆電、直立),截主要畫面;確認三欄在折疊時的欄寬、外鏡頭與狀態列的位置。
   - 終端機按鍵列以 `GeometryReader` + `reservedRegions(kind: .division, options: .includeInactive)` 讓按鍵避開折疊區;UI 測試在 Duo 模擬器的書本姿態斷言按鍵 frame 不與折疊區重疊。
   - 同時處理 HIG 的直式工具列(27.1 SDK 起才會出現):工具列項目同時有 title 與 symbol;`principal` 的自訂標題(終端機、對話的標題)不會進直式工具列(Preparing 頁:"If your item uses a custom view rather than a title or icon, the system doesn't present it vertically.")。
2. 上架前準備 iPhone Duo 截圖(產品頁標示最佳化)。
3. CI 的 `xcode-27` 映像若預設仍是 27.0,要確認升到 27.1 後才能合併使用 27.1 API 的程式。

## 6. 實作(#69)

- `TerminalKeyBarFoldSplit`(`src/PurrdrFeatures/TerminalKeyBarFoldSplit.swift`):純計算。輸入按鍵列寬度與按鍵列座標系的 `.division` frame;只處理直向(書本姿態)且穿過按鍵列的折疊，回傳「前段寬度」與「留空寬度」;任一側放不下兩顆 44pt 按鍵就不切分。測試 `tests/PurrdrFeaturesTests/TerminalKeyBarFoldTests.swift`。
- `TerminalKeyBar`:`if #available(iOS 27.1, *)` 內以背景 `GeometryReader` 讀 `proxy.reservedRegions(kind: .division)`(官方文件的寫法，frame 已含 margins、預設依 RTL 鏡像)。切分時前段是可橫捲的按鍵、折疊區留空、後段是「貼上」與「收起鍵盤」;按鍵順序不變。只取作用中的區域(不用 `.includeInactive`):全開時不留空。iOS 27.1 以前與非 Duo 裝置維持原本單一玻璃列。
- 未處理：橫向折疊(筆電姿態)按鍵列在下半部底端，預期不會碰到中線，但鍵盤升起時的位置未確認;鏡頭區(`.occlusion`)在畫面頂端，按鍵列在底部，未讀取。
- 未驗證：沒有 Duo 模擬器與實機，各姿態截圖、`GeometryReader` 在折疊時是否即時更新，都待 Xcode 27.1 模擬器或實機確認。
