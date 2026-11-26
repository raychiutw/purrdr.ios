# iOS 26／27 的深色模式與背景、文字顏色(一手來源研究)

研究日期:2026-11-26。範圍：iPhone／iPad,最低 iOS 26,Xcode 27(iOS 27.0 SDK)。

來源只用 Apple 一手資料：HIG(以 `developer.apple.com/tutorials/data/design/human-interface-guidelines/<頁>.json` 取得原文)、UIKit／SwiftUI／AppKit 文件、WWDC 逐字稿、iOS 26／27 release notes。每一條都附網址與原文引句。**HIG 與 UIKit 文件沒有公布背景色與 label 的色碼**,所以色碼表是本機實測(見 §1.2),會明確標「實測」,跟文件引句分開。

---

## 1. 深色模式的背景色

### 1.1 HIG 的建議

- **優先用系統背景色，不要自訂背景。** HIG〈Dark Mode〉iOS 段落:「Prefer the system background colors. Dark Mode is dynamic, which means that the background color automatically changes from base to elevated when an interface is in the foreground, such as a popover or modal sheet. … Using a custom background color can make it harder for people to perceive these system-provided visual distinctions.」
  — https://developer.apple.com/design/human-interface-guidelines/dark-mode
- **base 與 elevated 兩組。**「In Dark Mode, the system uses two sets of background colors — called base and elevated — to enhance the perception of depth when one dark interface is layered above another. The base colors are dimmer, making background interfaces appear to recede, and the elevated colors are brighter, making foreground interfaces appear to advance.」
  — 同上
- **elevated 由系統指定。** UIKit 文件:「Window content typically appears at the base level. … For example, the system assigns the elevated level to alerts and popovers.」
  — https://developer.apple.com/documentation/uikit/uitraitcollection/userinterfacelevel
- **深色調色盤不是淺色的反轉。**「The color palette in Dark Mode includes dimmer background colors and brighter foreground colors. It’s important to realize that these colors aren’t necessarily inversions of their light counterparts」
  — https://developer.apple.com/design/human-interface-guidelines/dark-mode
- **system 與 grouped 兩組、各三階。** HIG〈Color〉:「iOS defines two sets of dynamic background colors — system and grouped — each of which contains primary, secondary, and tertiary variants that help you convey a hierarchy of information. In general, use the grouped background colors … when you have a grouped table view; otherwise, use the system set of background colors」;三階用法是「Primary for the overall view / Secondary for grouping content or elements within the overall view / Tertiary for grouping content or elements within secondary elements」。
  — https://developer.apple.com/design/human-interface-guidelines/color
- **UIKit 文件只給用途，不給色值。** `systemBackground`:「The color for the main background of your interface.」;`secondarySystemBackground`:「The color for content layered on top of the main background.」;`systemGroupedBackground`:「The color for the main background of your grouped interface.」
  — https://developer.apple.com/documentation/uikit/uicolor/systembackground 、 https://developer.apple.com/documentation/uikit/uicolor/secondarysystembackground 、 https://developer.apple.com/documentation/uikit/uicolor/systemgroupedbackground

**關於純黑**:HIG 沒有「不要用純黑」的句子。相反地，它的示意圖明確把 base 畫成黑底、elevated 畫成近黑——〈Dark Mode〉圖說:「A diagram that shows a stack of 4 terms on top of a black background.」(base)與「… on top of a nearly black background.」(elevated)。HIG 唯一勸阻的是「自訂背景色」本身(上面第一條)。

**關於「太暗」**:HIG 沒有「深色太暗」的指引。相近的只有：
- 「Soften the color of white backgrounds. If you display a content image that includes a white background, consider slightly darkening the image to prevent the background from glowing in the surrounding Dark Mode context.」(圖片白底太亮，不是背景太暗)
  — https://developer.apple.com/design/human-interface-guidelines/dark-mode
- 「you may find places where dark text is less legible when it’s on a dark background. You might also find that turning on Increase Contrast in Dark Mode can result in reduced visual contrast between dark text and a dark background.」
  — 同上
- visionOS(不適用 iOS,僅供參考):「avoid displaying a bright object on a very dark or black background, especially if the object flashes or moves.」
  — https://developer.apple.com/design/human-interface-guidelines/color

### 1.2 色碼(實測，不是文件)

HIG〈Color〉只有 system gray 的 RGB(以圖片 alt 文字公布),深色 `systemGray6` 是「R-28,G-28,B-30」、`systemGray5`「R-44,G-44,B-46」、`systemGray4`「R-58,G-58,B-60」;增加對比的深色 `systemGray6`「R-36,G-36,B-38」、`systemGray5`「R-54,G-54,B-56」、`systemGray4`「R-68,G-68,B-70」(https://developer.apple.com/design/human-interface-guidelines/color ,Specifications › iOS, iPadOS system gray colors)。背景色本身沒有公布。

以下是 2026-11-26 在 **iOS 27.0 Simulator(runtime 24A434,Xcode 27.0 27A266a)** 用 `UIColor.resolvedColor(with:)` 對各 trait 組合解出的值(sRGB,四捨五入):

| 色 | 深色 base | 深色 elevated | 深色 base 增加對比 | 深色 elevated 增加對比 | 淺色(base／elevated 相同) | 淺色增加對比 |
|---|---|---|---|---|---|---|
| `systemBackground` | `#000000` | `#1C1C1E` | `#000000` | `#242426` | `#FFFFFF` | `#FFFFFF` |
| `secondarySystemBackground` | `#1C1C1E` | `#2C2C2E` | `#242426` | `#363638` | `#F2F2F7` | `#EBEBF0` |
| `tertiarySystemBackground` | `#2C2C2E` | `#3A3A3C` | `#363638` | `#444446` | `#FFFFFF` | `#FFFFFF` |
| `systemGroupedBackground` | `#000000` | `#1C1C1E` | `#000000` | `#242426` | `#F2F2F7` | `#EBEBF0` |
| `secondarySystemGroupedBackground` | `#1C1C1E` | `#2C2C2E` | `#242426` | `#363638` | `#FFFFFF` | `#FFFFFF` |
| `tertiarySystemGroupedBackground` | `#2C2C2E` | `#3A3A3C` | `#363638` | `#444446` | `#F2F2F7` | `#EBEBF0` |
| `label` | `#FFFFFF` | 同左 | `#FFFFFF` | 同左 | `#000000` | `#000000` |
| `secondaryLabel` | `#EBEBF5` α0.60 | 同左 | `#EBEBF5` α0.70 | 同左 | `#3C3C43` α0.60 | `#3C3C43` α0.80 |
| `tertiaryLabel` | `#EBEBF5` α0.30 | 同左 | `#EBEBF5` α0.55 | 同左 | `#3C3C43` α0.30 | `#3C3C43` α0.70 |
| `quaternaryLabel` | `#EBEBF5` α0.16 | 同左 | `#EBEBF5` α0.40 | 同左 | `#3C3C43` α0.18 | `#3C3C43` α0.55 |
| `separator` | `#545458` α0.50 | 同左 | 同左 | 同左 | `#3C3C43` α0.12 | 同左 |

重點:
- 深色 base 的 `systemBackground` 是**純黑**,grouped 的第一階也是純黑;elevated 整組往上提一階(`#1C1C1E`→`#2C2C2E`→`#3A3A3C`)。
- 增加對比在深色只把**第二、三階**拉開,base 的第一階仍是純黑。
- 深色的值與 HIG 公布的 system gray 一致(`#1C1C1E` = Gray 6、`#2C2C2E` = Gray 5、`#3A3A3C` = Gray 4)。
- 實測程式：在 scratchpad 編成 iOS Simulator 執行檔、`xcrun simctl spawn booted` 執行;沒有放進 repo。

### 1.3 iOS 26／27 有沒有改這些值

- **沒有找到一手來源說背景色或 label 改過。** HIG〈Dark Mode〉的 change log 最後一筆是「August 6, 2024 — Added art contrasting the light and dark appearances.」(https://developer.apple.com/design/human-interface-guidelines/dark-mode)。iOS & iPadOS 26 與 27 release notes 都沒有 background／label color 的項目(https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-26-release-notes 、 https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)。
- **改的是彩色系統色**(紅、橙、藍…),不是背景。HIG〈Color〉change log:「June 9, 2025 — Updated system color values, and added guidance for Liquid Glass.」;WWDC25「Get to know the new design system」:「Our family of system colors has been adjusted in subtle but meaningful ways across Light, Dark and Increased Contrast appearances, so that they work in harmony with Liquid Glass」。
  — https://developer.apple.com/design/human-interface-guidelines/color 、 https://developer.apple.com/videos/play/wwdc2025/356/
- iOS 27 的改動在 Liquid Glass 本身:「we tuned Liquid Glass so it more effectively diffuses complex content behind it」,並新增使用者設定「a new slider in settings to adjust Liquid Glass anywhere from ultra clear to fully tinted」,「Apps already using Liquid Glass get these improvements automatically」。
  — https://developer.apple.com/videos/play/wwdc2026/102/
- 限制：這台 Mac 只有 iOS 27.0 runtime,**沒有實測 iOS 26 的值做比對**。

---

## 2. 文字顏色

- **label 用系統的。** HIG〈Dark Mode〉:「Use the system-provided label colors for labels. The primary, secondary, tertiary, and quaternary label colors adapt automatically to the light and dark appearances.」
  — https://developer.apple.com/design/human-interface-guidelines/dark-mode
- **深色 `label` 是純白**(實測 `#FFFFFF`,見 §1.2)。HIG **沒有**「把白字調柔」的建議;唯一的「soften」是指內容圖片的白底(§1.1)。
- **不要重新定義系統語意色。** HIG〈Color〉:「Avoid redefining the semantic meanings of dynamic system colors. … don’t use the separator color as a text color, or secondaryLabel color as a background color.」
  — https://developer.apple.com/design/human-interface-guidelines/color
- **避免寫死色值。**「Embrace colors that adapt to the current appearance. … Avoid using hard-coded color values or colors that don’t adapt.」
  — https://developer.apple.com/design/human-interface-guidelines/dark-mode
- **用系統元件畫文字。**「Use system views to draw text fields and text views. System views and controls make your app’s text look good on all backgrounds, adjusting automatically for the presence or absence of vibrancy.」
  — 同上
- **系統元件的顏色**:文件沒有逐一列出導覽標題、alert、選單、鍵盤的色值。Liquid Glass 上的文字由系統決定:「For smaller elements like toolbars and tab bars, the system can adapt Liquid Glass between a light and dark appearance in response to the underlying content. By default, symbols and text on these elements follow a monochromatic color scheme, becoming darker when the underlying content is light, and lighter when it’s dark.」(https://developer.apple.com/design/human-interface-guidelines/color);材質上的字要用 vibrant 顏色:「Help ensure legibility by using vibrant colors on top of materials. When you use system-defined vibrant colors, you don’t need to worry about colors seeming too dark, bright, saturated, or low contrast in different contexts.」(https://developer.apple.com/design/human-interface-guidelines/materials)。WWDC25「Meet Liquid Glass」:「They flip from light to dark and vice versa, mirroring the glass’s behavior to maximize contrast.」(https://developer.apple.com/videos/play/wwdc2025/219/)
- **全 app 覆寫 `label`**:沒有找到文件直接談「全 app 改 label」。能引用的是上面「Avoid redefining the semantic meanings」與「Use the system-provided label colors」兩句;加上 Liquid Glass 上的字是系統依背景翻轉的，固定色會失去這層調整(推論，非引句)。

實測對比(WCAG 公式，半透明色先合成):深色 `label` 對 `#000000` 21:1、對 `#1C1C1E` 17.0:1;`secondaryLabel` 對黑 6.4:1、對 `#1C1C1E` 5.9:1、對 `#2C2C2E` 5.3:1;`tertiaryLabel` 約 2.2–2.5:1。淺色 `secondaryLabel` 對白只有 3.4:1、`tertiaryLabel` 1.7:1。

---

## 3. 淺色模式：米白／暖色背景

- **HIG 沒有建議用米白或暖色背景取代白色。** 淺色背景的建議同 §1.1(用系統背景色)。
- 自訂顏色時要四種變體:「If you define a custom color, make sure to supply light and dark variants, and an increased contrast option for each variant … Even if your app ships in a single appearance mode, provide both light and dark colors to support Liquid Glass adaptivity in these contexts.」
  — https://developer.apple.com/design/human-interface-guidelines/color
- 品牌色放內容層、不放在 bar 上(WWDC26「Communicate your brand identity on iOS」):「our recommendation is to move color into the content area of your app, into the scroll view. That way, Liquid Glass controls sit above the content layer and pick up your brand color dynamically.」;「When working with color, exercise restraint — use it sparingly and with intention」。
  — https://developer.apple.com/videos/play/wwdc2026/251/
- **想要「紙感」的正規做法是 True Tone 的白點調整，不是改背景色**:HIG〈Color〉:「Apps that primarily support reading, photos, video, and gaming can strengthen or weaken this effect by specifying a white point adaptivity style」;`UIWhitePointAdaptivityStyle` 的 reading 值是「A stronger adaptivity style designed for reading-focused apps.」
  — https://developer.apple.com/design/human-interface-guidelines/color 、 https://developer.apple.com/documentation/bundleresources/information-property-list/uiwhitepointadaptivitystyle
- **Apple 自家 app(備忘錄、Books、日記)用暖色**:沒有找到一手文件描述它們的背景色，不下結論。

---

## 4. 對比要求與「增加對比」

- HIG〈Accessibility〉以 WCAG AA 為準(Accessibility Inspector 用的值):「Up to 17 pts — All — 4.5:1」、「18 pts — All — 3:1」、「All — Bold — 3:1」。
  — https://developer.apple.com/design/human-interface-guidelines/accessibility
- 達不到時的底線:「If your app doesn’t provide this minimum contrast by default, ensure it at least provides a higher contrast color scheme when the system setting Increase Contrast is turned on. If your app supports Dark Mode, make sure to check the minimum contrast in both light and dark appearances.」
  — 同上
- 〈Dark Mode〉更嚴格:「At a minimum, make sure the contrast ratio between colors is no lower than 4.5:1. For custom foreground and background colors, strive for a contrast ratio of 7:1, especially in small text.」
  — https://developer.apple.com/design/human-interface-guidelines/dark-mode
- 系統色自帶增加對比變體:「Prefer system-defined colors. These colors have their own accessible variants that automatically adapt when people adjust their color preferences, such as enabling Increase Contrast」(https://developer.apple.com/design/human-interface-guidelines/accessibility);自訂色要「an increased contrast option for each variant that provides a significantly higher amount of visual differentiation」(https://developer.apple.com/design/human-interface-guidelines/color)。
- 非文字(圖示、圖形)的 3:1:HIG〈Accessibility〉表格只依「文字大小／粗細」分 4.5:1 與 3:1;**沒有**單獨的「non-text 3:1」條目(那是 WCAG 1.4.11,HIG 只說「enough contrast between foreground text and icons and background colors」)。
- Liquid Glass 的增加對比:「Increased contrast, makes elements predominantly black or white and highlights them with a contrasting border」(https://developer.apple.com/videos/play/wwdc2025/219/)。增加對比與降低透明度也改變 glass 的外觀:「The appearance of these variants can differ in response to certain system settings, like if people choose a preferred look for Liquid Glass in their device’s settings, or turn on accessibility settings that reduce transparency or increase contrast」(https://developer.apple.com/design/human-interface-guidelines/materials)。

---

## 5. 鍵盤輸入模式指示與聽寫膠囊的顏色

- **iOS 沒有文件說明它跟 `tintColor` 的關係。** UIKit 只說這些游標配件(cursor accessories,iOS 17 起包含輸入語言、聽寫等指示)由 `UITextSelectionDisplayInteraction` 提供:「UITextSelectionDisplayInteraction will then do all the heavy lifting for you, providing the cursor view and cursor accessories, as well as the range highlight and selection handles.」(https://developer.apple.com/videos/play/wwdc2023/10058/)。iOS 27 SDK 的 `UITextSelectionDisplayInteraction.h` 也只有一句提到 tint:「The highlight view. This is the blue/tinted highlight drawn behind the rendered text.」(是選取反白，不是指示膠囊)。`UITextInputTraits`、`UIStandardTextCursorView` 都沒有顏色屬性。
- `UIView.tintColor` 的定義是:「The first nondefault tint color value in the view’s hierarchy, ascending from and starting with the view itself.」(https://developer.apple.com/documentation/uikit/uiview/tintcolor)——沒有提到游標配件。
- **只有 macOS 有文件**:`NSTextInsertionIndicator`「By default the indicator’s color is textInsertionPointColor. You can set a different color.」(https://developer.apple.com/documentation/appkit/nstextinsertionindicator);WWDC23:「Its appearance is customizable. You can change the color and size. By default, it will follow the current accent color.」(https://developer.apple.com/videos/play/wwdc2023/10058/)。
- 結論：iOS 的指示膠囊顏色是否跟 tint 走**沒有一手文件**;要知道只能實機／模擬器觀察，且屬未公開行為，不能當成契約。

---

## 對 Purrdr 的建議

1. **深色頁面底(`DESIGN.md` #379 的 `#1C1C1E`)是明確偏離 HIG**:HIG 說「Prefer the system background colors」、「Using a custom background color can make it harder for people to perceive these system-provided visual distinctions」,而系統 base 就是純黑。目前三階(`#1C1C1E`／`#2C2C2E`／`#3A3A3C`)剛好等於系統 **elevated** 那組，代價是 sheet、popover 與頁面同色階(DESIGN 已記下)。若保留，在 `DESIGN.md` 該段補一句「偏離 HIG〈Dark Mode〉的 Prefer the system background colors,使用者決定」並附本文件，跟外觀設定的寫法一致。
2. **增加對比要跟上系統**:系統深色在增加對比時第二、三階變成 `#242426`／`#363638`／`#444446`(elevated 第一階也變 `#242426`)。`AppSurface` 若寫死三個值，增加對比時層次會比系統弱;建議 `AppSurface` 也給增加對比變體(或直接用 `systemGray6/5/4` 這類動態色),並把 `AccessibleColorsTests` 的背景組加上這三個值。
3. **主要文字維持系統 `label`(深色純白)**:HIG 沒有柔化白字的建議，且明說用系統 label、不要重新定義語意色;Liquid Glass 上的字由系統翻轉，覆寫會失去這層調整。
4. **次要文字**:DESIGN 的 `secondaryText` 理由成立——淺色 `secondaryLabel` 對白只有 3.4:1(實測)。深色 `secondaryLabel` 對 `#1C1C1E` 5.9:1,本身就過 4.5:1,深色端改用系統色也可以;但要達到〈Dark Mode〉「strive for 7:1, especially in small text」的自訂色目標，現行 `#AEAEB2` 的作法較穩。
5. **淺色不要改米白／暖色底**:沒有 HIG 依據。要閱讀感時考慮 Info.plist 的 `UIWhitePointAdaptivityStyle`(reading),但 Purrdr 有終端機與圖片，先別開。
6. **輸入指示膠囊的顏色不要依賴 tint**:沒有文件保證。Purrdr 的 `TerminalTextInputView` 自己實作 `UITextInput`,要不要顯示系統游標配件、顏色為何，只能在模擬器觀察後再決定，並當作未公開行為處理。
7. **全 app 一律保留 4 值(light／dark／兩種增加對比)與 4.5:1 文字底線**;Liquid Glass 上只在主要動作的**背景**上色(HIG:「apply color to the background rather than to symbols or text」),與現行 `prominentFill` 規則一致。
