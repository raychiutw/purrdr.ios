# Apple HIG 規範研究:Drover Chat 的 App 圖示與畫面視覺設計(截至 2026-11-15)

> 目的:把 Apple Human Interface Guidelines(HIG)現行版、Liquid Glass／Icon Composer 官方文件、WWDC 影片與 App Store Review Guidelines(僅視覺／付費牆相關)整理成 Drover Chat(iPhone + iPad universal、最低 iOS 26、Xcode 27／iOS 27 SDK)的 App 圖示與畫面視覺設計必須遵守的規範，最後轉成可勾選的檢核清單。
>
> 標記:
> - 引號內英文 = 一手原文(逐字引用);緊接的中文是繁中說明，不是官方翻譯。
> - **【推論】** = 依一手原文套到 Drover Chat 的判斷，原文沒有直接講到這個情境。
> - **【HIG 未規定】** = 查過相關頁面，HIG 沒有這方面的規範。
> - 第三方文章一律不採用。

## 研究方法

- **HIG 讀法**:HIG 網頁是 JavaScript 動態載入，本次直接讀官方 DocC JSON(`https://developer.apple.com/tutorials/data/design/human-interface-guidelines/<slug>.json`),內容與網頁 `https://developer.apple.com/design/human-interface-guidelines/<slug>` 相同。每頁都讀到底(含 Change log),確認是現行內容。
- **開發者文件**:同樣讀 DocC JSON(`/tutorials/data/documentation/...`),包括 *Adopting Liquid Glass*、*Creating your app icon using Icon Composer*。
- **WWDC 影片**:讀 developer.apple.com/videos 影片頁上的官方逐字稿。
- **App Store Review Guidelines**:讀 https://developer.apple.com/app-store/review/guidelines/ 全文(頁面標示 *Last Updated: October 16, 2026*),只摘視覺、登入、付費牆、推播相關條款。另外讀了 3.1.2(c) 指向的 *Apple Developer Program License Agreement* Schedule 2 第 3.8 條(訂閱揭露)。
- **既有筆記**:`/Users/ray/Projects/my-money.ios/docs/research/*apple-hig*` 與 `my-money.ios/DESIGN.md` 只拿來當目錄地圖，本文每一條都回原頁重新確認，沒有從筆記轉抄任何結論。
- **一個意外發現**:HIG 在 2026-09-09 新增了 **Designing for iPhone Duo** 頁(雙螢幕、可折疊的 iPhone)。Drover Chat 是 iPhone app、用 iOS 27 SDK,會跑在這台裝置上，所以一併納入(見 §5.4)。

### 本次讀到的頁面版本(Change log 最新一筆)

| 頁面 | 最新更新 | 內容 |
|---|---|---|
| App icons | 2026-10-28 | Added guidance for app icon format options |
| Layout | 2026-09-09 | Updated guidance to reflect current best practices |
| Designing for iPhone Duo | 2026-09-09 | New page |
| Apple In-App Purchase | 2026-09-17 | Rebranded as Apple In-App Purchase… |
| Branding | 2026-09-09 | Refined guidance for using brand color |
| Menus | 2026-06-08 | Updated guidance for menu item icons |
| Scroll views | 2026-06-08 | Updated guidance for scroll edge effects |
| Sidebars／Tab bars | 2026-06-08 | sidebar icon colors／terminology and art |
| Sheets | 2026-03-24 | Updated guidance for button placement |
| Color／Toolbars／Buttons／Typography | 2025-12-16 | Updated guidance for Liquid Glass(Typography:emphasized weights) |
| Materials／Motion | 2025-09-09 | Updated guidance for Liquid Glass |
| Accessibility | 2025-06-09 | Assistive Access、Switch Control、Accessibility Nutrition Labels |
| Virtual keyboards | 2025-06-09 | Added guidance for displaying custom controls above the keyboard |
| Windows／Multitasking／The menu bar | 2025-06-09 | iPadOS 可調整大小視窗、iPadOS menu bar |

---

## TL;DR:10 條最關鍵的規範

1. **Liquid Glass 只用在功能層(工具列、分頁列、側邊欄、輸入列這類浮在內容上的控制項),不要用在內容層。** 訊息泡泡、code block、subagent 卡片、清單列都是內容層。"Don't use Liquid Glass in the content layer." — [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
2. **不要 glass 疊 glass,自訂 Liquid Glass 要節制;能用系統元件就用系統元件。** "always avoid glass on glass" — [WWDC25 Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/);"Use Liquid Glass effects sparingly." — [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
3. **顏色要省著用、不能只靠顏色傳達狀態**:品牌色只放在主要動作與狀態指示上;「需要你／工作中／閒置」必須另有文字或符號。"Avoid relying solely on color…" — [Color](https://developer.apple.com/design/human-interface-guidelines/color)
4. **每個自訂顏色都要有淺色、深色、各自的增強對比版本;對比至少 4.5:1。** — [Color](https://developer.apple.com/design/human-interface-guidelines/color)、[Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode)、[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
5. **所有文字支援 Dynamic Type 到 AX5,不截斷;觸控目標 44×44 pt(最小 28×28 pt)。** — [Typography](https://developer.apple.com/design/human-interface-guidelines/typography)、[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
6. **依 size class 而不是裝置型號排版;iPad 視窗可任意縮放、iPhone Duo 有折疊區與側邊直式工具列,一律用 NavigationSplitView 等系統容器。** — [Layout](https://developer.apple.com/design/human-interface-guidelines/layout)、[Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)
7. **鍵盤上方的自訂控制列(終端機 accessory bar)要和任務相關，並套 Liquid Glass 或用標準 toolbar 以保持一致。** — [Virtual keyboards](https://developer.apple.com/design/human-interface-guidelines/virtual-keyboards)
8. **付費牆必須顯示:訂閱名稱、期間、每期內容、在地化的總扣款金額、免費試用結束後會自動扣款的說明、恢復購買／既有訂閱者登入、條款與隱私權政策連結;購買確認用系統的確認 sheet,不得仿製。** — [Apple In-App Purchase](https://developer.apple.com/design/human-interface-guidelines/apple-in-app-purchase)、ASRG 3.1.2(c)
9. **用 Google 登入時必須同時提供 Sign in with Apple(或同等服務),且 Sign in with Apple 按鈕不得比其他登入按鈕小、不得要捲動才看得到;提供會員就要在 app 內提供刪除帳號。** — ASRG 4.8、5.1.1(v);[Sign in with Apple](https://developer.apple.com/design/human-interface-guidelines/sign-in-with-apple)、[Managing accounts](https://developer.apple.com/design/human-interface-guidelines/managing-accounts)
10. **App 圖示用 Icon Composer 做分層圖示(1024×1024 px 方形、不預先遮罩、最多 4 個 group),同時要能在 default／dark／clear／tinted 六種外觀下辨識;不放文字、照片、UI 截圖、Apple 硬體、SF Symbols 或其他公司的商標。** — [App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)、[Icon Composer 文件](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)、ASRG 4.1(c)

---

## 1. Liquid Glass 使用原則

來源:[Materials](https://developer.apple.com/design/human-interface-guidelines/materials)、[Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)、[WWDC25 Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/)、[WWDC25 Get to know the new design system](https://developer.apple.com/videos/play/wwdc2025/356/)

### 1.1 兩層架構:功能層 vs 內容層

> "Liquid Glass forms a distinct functional layer for controls and navigation elements — like tab bars and sidebars — that floats above the content layer, establishing a clear visual hierarchy between functional elements and content."

Liquid Glass 是給控制項與導覽元素用的一層，浮在內容之上。

> "Don't use Liquid Glass in the content layer. … Instead, use Standard materials for elements in the content layer, such as app backgrounds. An exception to this is for controls in the content layer with a transient interactive element like Sliders and Toggles…"

內容層不要用 Liquid Glass,改用標準 material(ultra-thin／thin／regular／thick);唯一例外是 slider、toggle 這類互動中才暫時變成玻璃的控制項。

> "You may be tempted to use Liquid Glass everywhere but it is best reserved for the navigation layer that floats above the content of your app." … "always avoid glass on glass" — WWDC25 219 逐字稿

| Drover Chat 元素 | 層 | Liquid Glass? |
|---|---|---|
| Navigation bar／toolbar、tab bar、sidebar | 功能層 | 是(系統元件自動套用) |
| 對話畫面底部輸入列、終端機 accessory bar | 功能層(浮在內容上) | 是【推論】 |
| 訊息泡泡、markdown、code block、thinking／tool 摺疊區、subagent 卡片 | 內容層 | **否**,用系統背景色或標準 material |
| 主機清單列、Agent 列表列 | 內容層 | **否** |
| 對話內嵌的核准／拒絕按鈕 | 內容層中的控制項 | **否**,用一般 bordered／prominent 按鈕【推論】 |
| 終端機畫面本身 | 內容層 | 否 |

### 1.2 節制使用、優先用系統元件

> "Use Liquid Glass effects sparingly. Standard components from system frameworks pick up the appearance and behavior of this material automatically. … Limit these effects to the most important functional elements in your app."

> "Reduce your use of custom backgrounds in controls and navigation elements. Any custom backgrounds and appearances you use in these elements might overlay or interfere with Liquid Glass or other effects that the system provides, such as the scroll edge effect." — Adopting Liquid Glass(點名 `NavigationStack`、`NavigationSplitView`、`toolbar(content:)`)

不要替 navigation bar、split view、toolbar 加自訂背景色。

> "Check for crowding or overlapping of controls. Prefer to use standard spacing metrics instead of overriding them, and avoid overcrowding or layering Liquid Glass elements on top of each other." — Adopting Liquid Glass

> "Combine custom Liquid Glass effects to improve rendering performance. If you apply these effects to custom elements, make sure to combine them using a GlassEffectContainer…" — Adopting Liquid Glass

### 1.3 Regular 與 Clear 兩種變體

> "The regular variant blurs and adjusts the luminosity of background content to maintain legibility of text and other foreground elements. … Most system components use this variant. Use the regular variant when background content might create legibility issues, or when components have a significant amount of text…"

> "Only use clear Liquid Glass for components that appear over visually rich backgrounds." … "Use this variant for components that float above media backgrounds — such as photos and videos…"

WWDC25 219 補充 Clear 的三個條件:"First, the element you're applying it to is over media-rich content. Second, your content layer won't be negatively affected by introducing a dimming layer. And lastly, the content sitting above it is bold and bright."

【推論】Drover Chat 沒有照片／影片背景，終端機與對話都是密集文字，**一律用 Regular**,不用 Clear。

### 1.4 Liquid Glass 上的顏色

> "Apply color sparingly to the Liquid Glass material, and to symbols or text on the material. … To emphasize primary actions, apply color to the background rather than to symbols or text. … Refrain from adding color to the background of multiple controls." — [Color › Liquid Glass color](https://developer.apple.com/design/human-interface-guidelines/color)

> "Tinting should only be used to bring emphasis to primary elements and actions in the UI." … "Avoid tinting all your elements." … "If you want to imbue color into your app, do it in the content layer instead." — WWDC25 219

### 1.5 Scroll edge effect(取代實色背景與分隔線)

> "Differentiate controls from content. … Instead of applying a solid or semi-opaque background color beneath controls, use a scroll edge effect to visually elevate controls above content." — [Layout](https://developer.apple.com/design/human-interface-guidelines/layout)

> "Prefer the automatic scroll edge effect style." … "Only use a scroll edge effect when a scroll view is behind floating interface elements. Scroll edge effects aren't decorative." … "Apply one scroll edge effect per view. In split view layouts on iPad and Mac, each pane can have its own scroll edge effect; in this case, keep them consistent in height to maintain alignment." — [Scroll views](https://developer.apple.com/design/human-interface-guidelines/scroll-views)

> "If you use a custom bar with elements like controls, text, or icons that have content scrolling beneath them, you can register those views to use a scroll edge effect…(`safeAreaBar(edge:alignment:spacing:content:)`)" — Adopting Liquid Glass

【推論】對話畫面的自訂輸入列若是自訂 bar,要用 `safeAreaBar` 註冊，讓捲到下面的訊息有 scroll edge effect。

### 1.6 形狀:同心圓角(concentricity)

> "Prefer using standard components in a toolbar. By default, standard buttons, text fields, headers, and footers have corner radii that are concentric with bar corners. If you need to create a custom component, ensure that its corner radius is also concentric with the bar's corners." — [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)

> "Consider aligning the shape of controls with other rounded elements throughout the interface. … Help maintain a sense of visual continuity in your interface by using rounded shapes that are concentric to their containers…" — Adopting Liquid Glass(API:`ConcentricRectangle`、`rect(corners:isUniform:)`)

### 1.7 系統設定會改變 Liquid Glass 外觀

> "The appearance of these variants can differ in response to certain system settings, like if people choose a preferred look for Liquid Glass in their device's settings, or turn on accessibility settings that reduce transparency or increase contrast in the interface." — Materials

> "Test your interface with a variety of display and accessibility settings. … Ensure you test your app's custom elements, colors, and animations with different configurations of these settings." — Adopting Liquid Glass

### 1.8 其他 iOS 26 起的變化(Adopting Liquid Glass)

- Sheet:"half sheets are inset from the edge of the display … When a half sheet expands to full height, it transitions to a more opaque appearance." 要檢查 sheet 圓角附近的內容不要太貼邊。
- Action sheet:"originates from the element that initiates the action" — 要設定 source view／item。
- 清單:"lists, tables, and forms have a larger row height and padding" — section header **不再全大寫**,要改用 title-style capitalization。
- 選單:標準動作(剪下、拷貝、貼上)會自動帶圖示;"make sure the actions you surface at the top of your contextual menu match the swipe actions you provide for the same item."
- 隱藏工具列項目要隱藏整個 item,不是只隱藏裡面的 view(否則會留下空的玻璃膠囊)。
- `UIDesignRequiresCompatibility` 可以暫時保留舊外觀 — 【推論】Drover Chat 是新 app,不應使用。

---

## 2. App icons

來源:[App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)(2026-10-28 更新)、[Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)、[Adopting Liquid Glass › App icons](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)、[WWDC25 Say hello to the new look of app icons](https://developer.apple.com/videos/play/wwdc2025/220/)、[WWDC25 Create icons with Icon Composer](https://developer.apple.com/videos/play/wwdc2025/361/)

### 2.1 規格(硬性)

| 項目 | iOS／iPadOS 規格 | 出處 |
|---|---|---|
| 版面形狀 | 方形 | App icons › Specifications |
| 系統遮罩後 | 圓角矩形(系統套用，圓角與硬體邊框同心) | 同上 |
| 版面尺寸 | **1024×1024 px** | 同上 |
| 樣式 | Layered(分層) | 同上 |
| 外觀 | **Default、dark、clear light、clear dark、tinted light、tinted dark** | 同上 |
| 色彩空間 | sRGB、Gray Gamma 2.2、Display P3 | 同上 |
| 縮圖 | 系統自動縮放(Settings、通知等處) | 同上 |
| Icon Composer group 數 | 1 到 4 個 | Icon Composer 文件:"organize the layers … into a maximum of four groups";WWDC25 361:"By default, it'll always be one, but you can go all the way up to four." |

### 2.2 格式:用 Icon Composer 分層檔

> "Provide your icon in the Icon Composer format for more flexibility and control. If you provide a bitmap image instead, the system attempts to segment your icon … It doesn't automatically apply Liquid Glass effects to smaller, more complex elements in an icon like text and thin lines."

用 Icon Composer 檔(`.icon`)才能精確控制哪些元素有玻璃效果;給單張 PNG 由系統自動切兩層，細線與文字不會有玻璃效果。

> "If you add an Icon Composer file to your Xcode project, it replaces any existing icon asset catalog that you previously used to represent your app icon." — Icon Composer 文件

> "In iOS, iPadOS, macOS, and watchOS versions earlier than 27, specular highlights appear on when you choose Inside or Outside, and Refraction settings have no visible effect." — Icon Composer 文件

【推論】Drover Chat 最低支援 iOS 26:refraction 的效果只在 iOS 27 以上看得到，**圖示不能靠 refraction 才成立**,三個方案都要在 Icon Composer 用「26」與「27」兩種 rendering 比對(文件提到 toolbar 的 Effects 按鈕可切換世代比較)。

### 2.3 準備圖層(Icon Composer 文件 › Prepare your artwork for export)

- "Start with an app icon template that you download from Apple Design Resources that has the latest grid, shape, and canvas size."
- 畫布 1024×1024 px;"Design your app icon in layers that the system renders in the z-plane from back to front."
- "Because SVG format doesn't preserve fonts, convert text to outlines."
- "Remove blurs and shadows, and specular, opacity, and translucency settings." / "Remove background colors and gradients."(背景在 Icon Composer 裡設)
- "choose the SVG format whenever possible. For layers that contain unsupported SVG features, choose PNG…"
- "Don't export the canvas mask because the system applies that automatically to ensure a perfect crop."

App icons 頁也寫:

> "Produce appropriately shaped, unmasked layers. … provide square layers so the system can apply rounded corners. … Providing layers with pre-defined masking negatively impacts specular highlight effects and makes edges look jagged."

> "Prefer clearly defined edges in foreground layers. … avoid soft and feathered edges on foreground layer shapes."

> "Design a background that both stands out and emphasizes foreground content. … If you do import a background layer, make sure it's full-bleed and opaque."

> "Keep primary content centered to avoid truncation when the system adjusts corners or applies masking."

### 2.4 設計原則

> "Embrace simplicity in your icon design. … express it in a simple, unique way with a minimal number of shapes. Prefer a simple background, such as a solid color or gradient…"

> "Consider basing your icon design around filled, overlapping shapes."

> "Vary opacity in foreground layers to increase the sense of depth and liveliness."

> "Make sure to avoid extremely thin line weights and sharp corners, because they tend to lose detail and crispness in smaller icon sizes at lower resolutions."

WWDC25 220:"Realistic 3D objects and perspectives … can compete with the material qualities. The redesigned icon uses a frontal view and a more flat appearance." / "Ideally, sharp edges and thin lines should be avoided." / "softer light-to-dark gradients harmonize best with the direction of light. We've also developed a System Light and System Dark gradient that should be used instead of pure white or black backgrounds." / "we actually recommend leaning more into colored backgrounds, so that there is a nicer distinction when switching between modes."

> "Let the system handle blurring and other visual effects. … there's no need to include specular highlights, drop shadows between layers, beveled edges, blurs, glows, and other effects."

### 2.5 禁止事項

| 禁止 | 原文 | 出處 |
|---|---|---|
| 非必要的文字 | "Include text only when it's essential to your experience or brand. Text in icons doesn't support accessibility or localization…" | App icons |
| 照片 | "Prefer illustrations to photos" | App icons |
| 複製 UI 元件或截圖 | "don't just replicate standard UI components or use app screenshots in your icon." | App icons |
| Apple 硬體 | "Don't use replicas of Apple hardware products." | App icons |
| 預先遮罩的圖層 | 見 2.3 | App icons |
| 自製高光／陰影／斜角 | 見 2.4 | App icons |
| SF Symbols | "the prohibition against using symbols — or images that are confusingly similar — in app icons, logos, or any other trademarked use." | [SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols) |
| 其他開發者的圖示、品牌、產品名 | "You cannot use another developer's icon, brand, or product name in your app's icon or name, without approval from the developer." | ASRG 4.1(c) |
| Apple 商標 | "Apple trademarks must not appear in your app name or images." | [Branding](https://developer.apple.com/design/human-interface-guidelines/branding) |
| 非全年齡圖像 | "make sure your app and in-app purchase icons … adhere to a 4+ age rating" | ASRG 2.3.8 |

【推論】對 Drover Chat 特別要注意:**不能把 Claude、Anthropic、OpenAI／Codex 的 logo 或其近似圖形放進圖示**(4.1(c));也不建議把「終端機視窗」或「聊天泡泡畫面」畫成寫實截圖(App icons 禁止複製 UI 元件／截圖)— 可以抽象化成簡單形狀(Messages 圖示本身就是泡泡造型，抽象形狀是允許的)。「`>_`」這類提示字元屬於文字元素，要評估是否「essential」。

### 2.6 外觀變體(Appearances)

> "Keep your icon's features consistent across appearances. … Avoid creating custom icon variants that swap elements in and out with each variant…"

> "Design dark and tinted icons that feel at home beside system app icons and widgets. … dark icons are more subdued, and clear and tinted icons are even more so. A great app icon is visible, legible, and recognizable, regardless of its appearance variant."

> "Use your light app icon as the basis for your dark icon. Choose complementary colors that reflect the default design, and avoid excessively bright images. Color backgrounds generally offer the greatest contrast in dark icons."

> "You can design app icon variants for every appearance variant, and the system automatically generates variants you don't provide."

WWDC25 361:Icon Composer 的三種標註是 **default、dark、mono**,clear 與 tinted 由 mono 產生;"For mono appearances, setting at least one element to white and mapping other colors to tones of gray is recommended."

### 2.7 替代圖示(若讓使用者在 app 內換圖示)

> "Alternate app icons in iOS and iPadOS require their own dark, clear, and tinted variants. As with your default app icon, all alternate and variant icons are subject to app review…" — App icons

> "make sure each icon you design remains closely related to your content and experience. Avoid creating one someone might mistake for another app."

ASRG 2.3.8:"ensure your metadata, including app name and icons (small, large, Apple Watch app, alternate icons, etc.), are similar to avoid creating confusion."

【推論】「三個方案讓使用者挑」若是指**設計階段由使用者(產品擁有者)選一個**,不受上面限制;若是指**上架後讓 app 使用者在設定裡切換**,三個都得做齊 dark／clear／tinted 變體並送審，且三者要彼此相像。

### 2.8 一致性

> "Provide a visually consistent icon design across all the platforms your app supports." — App icons

【推論】iPhone 與 iPad 同一個圖示;App Store 頁面、通知、Settings、訂閱的 offer code 兌換畫面(未提供 promotional image 時預設用 app icon,見 §13)都會出現同一個圖示。

---

## 3. Color 與 Dark Mode

來源:[Color](https://developer.apple.com/design/human-interface-guidelines/color)、[Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode)、[Branding](https://developer.apple.com/design/human-interface-guidelines/branding)、[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)

### 3.1 一致與語意

> "Avoid using the same color to mean different things. Use color consistently throughout your interface, especially when you use it to help communicate information like status or interactivity."

> "Avoid hard-coding system color values in your app. … The actual color values may fluctuate from release to release…"

> "Avoid redefining the semantic meanings of dynamic system colors. … don't use the separator color as a text color, or secondary text label color as a background color."

iOS 背景色兩組:system(`systemBackground` 系列)與 grouped(`systemGroupedBackground` 系列),各有 primary／secondary／tertiary 表示層級;前景用 `label`／`secondaryLabel`／`tertiaryLabel`／`quaternaryLabel`／`placeholderText`／`separator`／`link`。

### 3.2 三種情境都要有

> "Make sure all your app's colors work well in light, dark, and increased contrast contexts. … If you define a custom color, make sure to supply light and dark variants, and an increased contrast option for each variant … Even if your app ships in a single appearance mode, provide both light and dark colors to support Liquid Glass adaptivity in these contexts."

### 3.3 不能只靠顏色

> "Avoid relying solely on color to differentiate between objects, indicate interactivity, or communicate essential information. … you can use text labels or glyph shapes to identify objects or states." — Color

> "people who are color blind may have particular difficulty with pairings such as red-green and blue-orange. Offer visual indicators, like distinct shapes or icons, in addition to color…" — Accessibility

【推論】Agent 狀態「需要你／工作中／閒置」:分組標題文字 + 不同形狀的 SF Symbol + 顏色，三者並用;不要只用紅綠圓點。

### 3.4 品牌色(accent color)

> "Apply your app's accent color judiciously. … Minimize its use on controls and instead use it intentionally for primary actions or status indicators, like badges for unread content or an icon for the selected tab in a tab bar. To express your brand through color, consider moving it into the content layer…" — Branding(2026-09-09 更新)

> "If your app features colorful backgrounds or visually rich content, prefer a monochromatic appearance for toolbars and tab bars … in apps with primarily monochromatic content or backgrounds, choosing your brand color as the app accent color can be an effective way…" — Color

【推論】Drover Chat 的內容以文字為主(偏單色),適合把品牌色設成 accent color,但只用在主要動作(送出、核准)與狀態。

### 3.5 對比數值

> "At a minimum, make sure the contrast ratio between colors is no lower than 4.5:1. For custom foreground and background colors, strive for a contrast ratio of 7:1, especially in small text." — Dark Mode

| 文字大小 | 粗細 | 最低對比 |
|---|---|---|
| 17 pt 以下 | 全部 | 4.5:1 |
| 18 pt | 全部 | 3:1 |
| 全部 | Bold | 3:1 |

(Accessibility 頁，出自 WCAG Level AA,Accessibility Inspector 依此判斷)

> "If your app doesn't provide this minimum contrast by default, ensure it at least provides a higher contrast color scheme when the system setting Increase Contrast is turned on." — Accessibility

### 3.6 Dark Mode

> "Avoid offering an app-specific appearance setting. An app-specific appearance mode option creates more work for people…" — Dark Mode

> "In rare cases, consider using only a dark appearance in the interface. For example, it can make sense for an app that supports immersive media viewing…"

> "Prefer the system background colors. Dark Mode is dynamic, which means that the background color automatically changes from base to elevated when an interface is in the foreground, such as a popover or modal sheet." — Dark Mode › iOS, iPadOS

> "Test your content … in Dark Mode with Increase Contrast and Reduce Transparency turned on (both separately and together)…"

【推論】app 設定裡**不要**放「淺色／深色／跟隨系統」切換。終端機配色主題(ANSI 色盤)屬於終端機內容的設定，不等同 app 外觀設定，可以提供;但主題要確保文字對比。終端機是否永遠深色:HIG 只舉「immersive media viewing」為例，終端機不屬此類，**HIG 未直接規定**,建議跟隨系統或由終端機主題決定。

---

## 4. Typography

來源:[Typography](https://developer.apple.com/design/human-interface-guidelines/typography)、[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)、[Layout](https://developer.apple.com/design/human-interface-guidelines/layout)

### 4.1 大小與字重

| 平台 | 預設 | 最小 |
|---|---|---|
| iOS、iPadOS | 17 pt | 11 pt |

> "In general, avoid light font weights. … prefer Regular, Medium, Semibold, or Bold font weights, and avoid Ultralight, Thin, and Light font weights…"

> "Minimize the number of typefaces you use, even in a highly customized interface."

### 4.2 Text styles 與 Dynamic Type

> "Consider using the built-in text styles. … Using text styles with the system fonts also ensures support for Dynamic Type and larger accessibility type sizes…"

> "Make sure your app's layout adapts to all font sizes. … turn on Larger Accessibility Text Sizes … and confirm that your app remains comfortably readable."

> "Keep text truncation to a minimum as font size increases. … Avoid truncating text in scrollable regions unless people can open a separate view to read the rest of the content."

> "Consider adjusting your layout at large font sizes. … consider using a stacked layout where text appears above secondary items."

> "Increase the size of meaningful interface icons as font size increases."

> "Support larger text sizes. … Ideally, give people the option to enlarge text by at least 200 percent … Your interface can support font size enlargement either through custom UI, or by adopting Dynamic Type." — Accessibility

> "Implement accessibility features for custom fonts. System fonts automatically support Dynamic Type … and respond when people turn on accessibility features, such as Bold Text." — Typography

### 4.3 等寬字型

> "San Francisco (SF) is a sans serif typeface family that includes the SF Pro, SF Compact, SF Arabic, SF Armenian, SF Georgian, SF Hebrew, and SF Mono variants."

> "You can use the constants defined in Font.Design to access all system fonts — don't embed system fonts in your app or game."

**【HIG 未規定】** HIG 只提到 SF Mono 存在，沒有任何「程式碼、終端機、code block 該用什麼字型」的規範。【推論】code block、SSH 公鑰、host key 指紋用 `Font.Design.monospaced`(SF Mono),並讓它跟著 Dynamic Type 縮放;不要把 SF Mono 打包進 app。

### 4.4 繁中

**【HIG 未規定】** HIG Typography 沒有針對中文(CJK)字型或行高的規範;iOS 系統字型會自動 fallback 到系統中文字型。

---

## 5. Layout、iPad、iPhone Duo

來源:[Layout](https://developer.apple.com/design/human-interface-guidelines/layout)、[Split views](https://developer.apple.com/design/human-interface-guidelines/split-views)、[Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)、[Windows](https://developer.apple.com/design/human-interface-guidelines/windows)、[Multitasking](https://developer.apple.com/design/human-interface-guidelines/multitasking)、[Designing for iPadOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ipados)、[Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)、[Pointing devices](https://developer.apple.com/design/human-interface-guidelines/pointing-devices)

### 5.1 通則

> "Determine layout based on size classes, not device type or orientation."

> "Keep functionality the same as size classes change … Don't change your app's functionality based on the space it occupies. However, you can change the amount of functionality that's visible onscreen…"

> "Respecting the safe area is essential to make sure system UI and hardware features like the Dynamic Island don't obstruct content and controls."

> "Use progressive disclosure to make layouts cleaner … Use disclosure triangles, menus, or nested views…"(適用 thinking／tool 呼叫摺疊)

> "You can test on a simulated device in Device Hub to check for clipping and other layout issues."(Xcode 27 的 Device Hub)

### 5.2 Split view 與 sidebar(iPad 三欄)

> "To support navigation, persistently highlight the current selection in each pane that leads to the detail view." — Split views

> "Account for narrow, compact, and intermediate window widths. Since iPad windows are fluidly resizable … ensure that it's possible to navigate between the various panes in a logical way." — Split views › iPadOS

> "Prefer using a split view in a regular — not a compact — environment." — Split views › iOS

> "In general, show no more than two levels of hierarchy in a sidebar. When a data hierarchy is deeper than two levels, consider using a split view interface that includes a content list between the sidebar items and detail view." — Sidebars

> "Consider letting people hide the sidebar. … in iPadOS, people expect to use the built-in edge swipe gesture … Avoid hiding the sidebar by default to ensure that it remains discoverable." — Sidebars

> "Consider using a tab bar first." … "To display a sidebar only, use NavigationSplitView…" — Sidebars › iOS, iPadOS

【推論】Drover Chat 的「主機 → Agent 列表 → 對話」正好是 sidebar + content list + detail 三欄，符合 Sidebars 對「超過兩層用 split view 中間加 content list」的建議。HIG 對 iPad 偏好 tab bar,但三層階層本身就是 split view 的典型用途，選 NavigationSplitView 有依據。

> "Use split views to allow fluid resizing of columns. … Make sure to use standard system APIs for split views to get these animations…" — Adopting Liquid Glass

### 5.3 視窗與多工

> "People expect to use multitasking on their devices, and they may think something is wrong if your app doesn't allow it." — Multitasking

> "Make sure window controls don't overlap toolbar items. When windowed, app windows include window controls at the leading edge of the toolbar." — Windows › iPadOS

> "Consider providing the option to view content in a new window. … Consider letting people view content in a new window using a command in a Context menus…" — Windows

> "Avoid opening new windows as default behavior unless it makes sense for your app." — Windows

> "Use the term window in user-facing content. … Using different terms — including scene … is likely to confuse people." — Windows(【推論】繁中 UI 一律稱「視窗」)

> "Provide a useful title for each window. … Don't title windows with your app name." — Toolbars

> "Restore the previous state when your app restarts … scroll the view to people's most recent position, and display windows in the same state and location…" — [Launching](https://developer.apple.com/design/human-interface-guidelines/launching)

### 5.4 iPhone Duo(2026-09-09 新頁)

> "Although iPhone Duo is a new form factor, keep in mind that you're still designing for iPhone…"

> "Build your app to resize. … Use size classes, layout margins, and safe area insets to lay out controls and content. Avoid fixed widths and display-specific dependencies."

> "Follow the system's vertical layout for toolbars, tab bars, and navigation controls. … If you use standard system components, you receive this layout automatically…" / "In general, don't override the default bar placement."

> "On iPhone Duo, a split view expands on the inner display and collapses to a single pane on the outer display…"

> "For custom components, ReservedRegion (SwiftUI) and UIView.ReservedRegion (UIKit) provide a way to reposition content away from reserved regions."(外螢幕前鏡頭、內螢幕前鏡頭、折疊區)

> "Provide both a title and a symbol for each toolbar item that isn't text-only. … Keep text-based buttons to a minimum. Labels that include text stay in a horizontal bar…"

> "In task-oriented experiences, minimize the tab bar to preserve the toolbar actions that are central to completing the task."

> "Use the system overflow menu. … Reserve the ellipsis symbol for overflow, and give other menus a distinct symbol."

【推論】影響 Drover Chat 的點:終端機全螢幕與 accessory bar 要避開折疊區(ReservedRegion);對話畫面的工具列項目要同時給 title 與 symbol;`ellipsis` 只用於 overflow 選單(列表工具列的「⋯」選單即屬此類，Q73),其他選單用不同符號，並優先讓系統 overflow menu 自動收納工具列項目。

### 5.5 指標裝置(iPad 觸控板／滑鼠)

> "Use highlight for a group of controls placed within a Liquid Glass container." / "Use lift for a standalone Liquid Glass control or a small element that has an opaque background." / "Use hover for large elements…" — Pointing devices › iPadOS

> "Prefer the system-provided pointer appearances for standard buttons and text-entry areas."

> "Create contiguous hit regions for custom bar buttons."(【推論】適用終端機 accessory bar 的自訂按鍵)

---

## 6. Toolbars、Tab bars、Navigation

來源:[Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)、[Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars)、[WWDC25 356](https://developer.apple.com/videos/play/wwdc2025/356/)

### 6.1 Toolbar

> "Write a concise title. … keep the title under 15 characters long so you leave enough room for other controls."

> "Use the standard Back and Close buttons. … Prefer the standard symbols for each, and don't use a text label that says Back or Close."

> "Prefer system-provided symbols without borders."(不要用帶外框圓圈的 symbol)

> "Use the `.prominent` style for key actions such as Done or Submit. … Only specify one primary action, and put it on the trailing side of the toolbar."

> "Minimize the number of groups. … In general, aim for a maximum of three."

> "Keep actions with text labels separate. Placing an action with a text label next to an action with a symbol can create the illusion of a single action…"

> "Reduce the use of toolbar backgrounds and tinted controls."

> "The system automatically adds an overflow menu in macOS or iPadOS when items no longer fit. Don't add an overflow menu manually…"

> "Use a large title to help people stay oriented as they navigate and scroll." — Toolbars › iOS

> "Avoid placing screen-specific actions here—a checkout button, for example, belongs with the content it supports." — WWDC25 356(【推論】核准／拒絕按鈕應放在該則 agent 提問旁，而不是全域工具列)

### 6.2 Tab bar(若 iPhone 版使用)

> "Use a tab bar to support navigation, not to provide actions."

> "Don't disable or hide tab bar buttons, even when their content is unavailable. … If a section is empty, explain why its content is unavailable."

> "Include tab labels … Use single words whenever possible." / "Prefer filled symbols or icons for consistency with the platform."

> "Use a badge to indicate that critical information is available. … Reserve badges for critical information…"

【推論】Drover Chat 主結構是 split view,iPhone 上會收合成 navigation stack,不一定有 tab bar;若之後加 tab(例如「主機／設定」),套用以上規則，且 iPadOS menu bar 的 View 選單應列出各 tab(見 §10.4)。

---

## 7. Lists

來源:[Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables)、[Adopting Liquid Glass › Organization and layout](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)、[Disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls)

> "Provide appropriate feedback when people select a list item. … a table that helps people navigate through a hierarchy persistently highlights the selected row…"

> "Keep item text succinct so row content is comfortable to read. … you could list item titles only, letting people choose an item to reveal its content in a detail view."

> "Sometimes, an ellipsis in the middle of text can make an item easier to distinguish because it preserves both the beginning and the end of the content."(【推論】適用長主機名稱、長路徑)

> "In iOS and iPadOS, for example, the grouped style uses headers, footers, and additional space to separate groups of data…"

> "Use an info button only to reveal more information about a row's content. … If you need to let people drill into a list or table row's subviews, use a disclosure indicator…"

> "section headers no longer render entirely in capital letters … update your section headers to title-style capitalization" — Adopting Liquid Glass

> "Use a disclosure control to hide details until they're relevant." / "Provide a descriptive label when using a disclosure triangle." — Disclosure controls(iOS 用 `DisclosureGroup`)

【推論】Agent 列表用 grouped list,三個 section「需要你／工作中／閒置」;thinking 與 tool 呼叫用 `DisclosureGroup`,收合時標籤要描述內容(例如「思考 · 12 秒」、「執行 Bash:npm test」),不要只寫「詳細資料」。

---

## 8. Sheets、Alerts、Action sheets

來源:[Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets)、[Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts)、[Action sheets](https://developer.apple.com/design/human-interface-guidelines/action-sheets)、[Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)

### 8.1 Sheets

> "In iOS and iPadOS, for sheets with a single view, the Cancel button belongs on the leading edge of the top toolbar. When present, the Done button belongs on the trailing edge."

> "Provide an alternative to the Done button. If you provide a Done button, always pair it with a Cancel button … or a Back button…" / "Avoid showing all three buttons — Cancel, Done, and Back — together."

> "Display only one sheet at a time from the main interface."

> "Support swiping to dismiss a sheet. … If people have unsaved changes in the sheet when they begin swiping to dismiss it, use an action sheet to let them confirm their action."

> "Include a grabber in a resizable sheet."

> "the compose sheets in Messages and Mail display only at full height to give people enough room to create content."

> "Prefer using the page or form sheet presentation styles in an iPadOS app."

> "For complex or prolonged user flows, consider alternatives to sheets."

【推論】「新增主機」是表單，用 full-height sheet(不提供 medium detent),Cancel 在左、新增在右;流程若有「填資料 → 顯示公鑰 → 確認指紋」多步驟，用 sheet 內的 navigation(Back),不要開第二個 sheet。

### 8.2 Alerts

> "Avoid using an alert merely to provide information." / "Avoid showing an alert when your app starts. … If your app detects a problem at startup, like no network connection … show cached or placeholder data and a nonintrusive label…"

> "Avoid writing a title that doesn't convey useful information — like "Error" or "Error 329347 occurred" — but also avoid overly long titles that wrap to more than two lines."

> "Avoid using OK as the default button title unless the alert is purely informational."

> "Use the destructive style to identify a button that performs a destructive action people didn't deliberately choose."

> "If there's a destructive action, include a Cancel button … Note that you don't want to make a Cancel button the default button."

> "Pressing Escape (Esc) or Command-Period (.) on an attached keyboard" 取消 alert(iOS、iPadOS)。

> "Don't assign the primary role to a button that performs a destructive action…" — Buttons

【推論】host key 指紋確認(首次連線)與「host key 變更」是安全決策，適合 alert:標題具體(例如「這台主機的身分與上次不同」),按鈕用動詞(「仍然連線」「取消」),不用「確定」;「仍然連線」不設為預設按鈕。

### 8.3 Action sheets

> "Use an action sheet — not an alert — to offer choices related to an intentional action."

> "Make destructive choices visually prominent. Use the destructive style … and place these buttons at the top of the action sheet…"

> "Specify the source of an action sheet. Position an action sheet's anchor next to the control it originates from." — Adopting Liquid Glass

---

## 9. Menus、Context menus、Edit menus

來源:[Menus](https://developer.apple.com/design/human-interface-guidelines/menus)、[Context menus](https://developer.apple.com/design/human-interface-guidelines/context-menus)、[Edit menus](https://developer.apple.com/design/human-interface-guidelines/edit-menus)

> "label a menu item that initiates an action using a verb or verb phrase…"

> "Append an ellipsis to a menu item's label when the action requires more information before it can complete."

> "Use menu item icons sparingly and with purpose." / "provide icons for all menu items in a group, or none of them." / "Don't display an icon if you can't find one that clearly represents the menu item."(Menus 2026-06-08 更新)

> "Limit the depth and length of submenus. … restrict them to a single level. Also, if a submenu contains more than about five items, consider creating a new menu."

> "Hide unavailable menu items, don't dim them." — Context menus(一般 menu 則相反:不可用項目要顯示為 dimmed)

> "Always make context menu items available in the main interface, too."

> "warn people about context menu items that can destroy data. … list them at the end of the menu and identify them as destructive"

> "Show keyboard shortcuts in your app's main menus, not in context menus."

> "Provide either a context menu or an edit menu for an item, but not both." — Context menus › iOS, iPadOS

> "When it makes sense, let people select and copy noneditable text. … let people copy content text, but not control labels." — Edit menus

**【HIG 未規定】** slash command 的自動完成選單沒有對應的 HIG 元件。【推論】套用 Menus 的標籤原則(動詞開頭、簡短)與 Lists 的列樣式;選單出現在輸入列上方屬於功能層暫態元素。

【推論】SSH 公鑰、指紋、訊息內容、code block 都要能選取與拷貝;code block 若另有「拷貝」按鈕，要用標準 symbol `document.on.document`(見 §17)。

---

## 10. Text fields 與鍵盤

來源:[Text fields](https://developer.apple.com/design/human-interface-guidelines/text-fields)、[Virtual keyboards](https://developer.apple.com/design/human-interface-guidelines/virtual-keyboards)、[Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards)、[The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar)、[Settings](https://developer.apple.com/design/human-interface-guidelines/settings)

### 10.1 Text fields

> "Use a text field to request a small amount of information … To let people input larger amounts of text, use a Text views instead."(【推論】訊息輸入列是多行，用 text view／`TextField(axis: .vertical)`)

> "Because placeholder text disappears when people start typing, it can also be useful to include a separate label describing the field…"

> "Use secure text fields to hide private data."(SSH 密碼)

> "In iOS, iPadOS, tvOS, and visionOS apps, show the appropriate keyboard type."(主機位址用 URL／ASCII 鍵盤、port 用 number pad)

> "Validate fields when it makes sense."

> "Display a Clear button in the trailing end of a text field…" — iOS, iPadOS

### 10.2 Virtual keyboard 與 input accessory

> "Use the keyboard layout guide to make the keyboard feel like an integrated part of your interface."

> "Place custom controls above the keyboard thoughtfully. … make sure they're relevant to the current task. If other views in your app use Liquid Glass, or if your view looks out of place above the keyboard, apply Liquid Glass to the view that contains your controls to maintain consistency. If you use a standard toolbar to contain your controls, it automatically adopts Liquid Glass. Use the keyboard layout guide and standard padding…"

> "Consider customizing the Return key type if it helps clarify the text-entry experience."(`submitLabel`)

> "Make sure your custom input view makes sense in the context of your app." / "Play the standard keyboard sound while people type."(自訂 input view;`playInputClick()`)

【推論】終端機的 Esc／Tab／Ctrl／方向鍵 bar 用 `ToolbarItemPlacement.keyboard`(標準 toolbar,自動 Liquid Glass);按鍵是同一容器內的一組，不要每顆各自做成獨立玻璃(避免 glass on glass);每顆至少 44×44 pt 或最小 28×28 pt;按下時播放鍵盤點擊音。

### 10.3 硬體鍵盤與快捷鍵

> "Support Full Keyboard Access when possible."

> "In general, don't repurpose standard keyboard shortcuts for custom actions."

> "Define custom keyboard shortcuts for only the most frequently used app-specific commands."

| Modifier | 建議 |
|---|---|
| Command | "Prefer the Command key as the main modifier key in a custom keyboard shortcut." |
| Shift | 次要 modifier |
| Option | "Use the Option modifier sparingly…" |
| Control | "**Avoid using the Control key as a modifier.** The system uses Control in many systemwide features…" |

> "If you use more than one modifier key in a custom shortcut, always list them in this order: Control, Option, Shift, Command."

標準快捷鍵(Keyboards 頁表格)中與 Drover Chat 相關的:Command-N(新文件)、Command-W(關閉視窗)、Command-F(尋找)、Command-,(設定)、Command-C／V／X／A／Z、Esc(取消目前動作)、Command-Period(取消操作)。

> "Make settings available in ways people expect. For example, when a physical keyboard is connected, people often use the standard Command-Comma (,) keyboard shortcut to open an app's settings…" — Settings

【推論】**終端機的衝突處理**:HIG 說 app 自訂快捷鍵避免用 Control,這和終端機需要把 Ctrl-C／Ctrl-D 等送進 shell 不衝突 — 終端機聚焦時 Control 組合鍵應直接送給遠端，app 自己的快捷鍵只用 Command。Esc 在終端機聚焦時也應送給遠端(vim 等需要),但 alert 出現時 Esc 仍要能取消 alert。HIG 沒有討論終端機類 app 的按鍵優先權，這是推論。

### 10.4 iPadOS menu bar

> "Keyboard shortcuts in iPadOS use the same patterns as in macOS."

> "Because the menu bar is often hidden when running an app full screen, ensure that people can access all of your app's functions through its UI. In particular, always offer other ways to accomplish tasks assigned to dynamic menu items…"

> "Reserve the YourAppName > Settings menu item for opening your app's page in iPadOS Settings. If your app includes its own internal preferences area, link to it with a separate menu item beneath Settings in the same group."

> "For apps with tab-style navigation, consider adding each tab as a menu item in the View menu. … consider assigning key bindings to each tab…"

---

## 11. Notifications

來源:[Notifications](https://developer.apple.com/design/human-interface-guidelines/notifications)、[Managing notifications](https://developer.apple.com/design/human-interface-guidelines/managing-notifications)、[Privacy](https://developer.apple.com/design/human-interface-guidelines/privacy)、ASRG 4.5.4

### 11.1 內容

> "Provide concise, informative notifications."

> "Avoid sending multiple notifications for the same thing, even if someone hasn't responded."

> "Use an alert — not a notification — to display an error message."

> "Handle notifications gracefully when your app is in the foreground. … such as incrementing a badge or subtly inserting new data into the current view."

> "Avoid including sensitive, personal, or confidential information in a notification."

> "Create a short title if it provides context … Use title-style capitalization and no ending punctuation."

> "Provide generically descriptive text to display when notification previews aren't available. … like "Friend request," "New comment,"…"(`hiddenPreviewsBodyPlaceholder`)

> "Avoid including your app name or icon."

ASRG 4.5.4:"Push Notifications must not be required for the app to function, and should not be used to send sensitive personal or confidential information."

【推論】Agent 的提問內容可能含程式碼、路徑、token,推播內文應摘要(例如「Claude Code 需要你核准一個指令」+ 主機名),不放完整指令內容;隱藏預覽時的 placeholder 例如「Agent 需要你」。

### 11.2 通知動作

> "A notification can present a customizable detail view that contains up to four buttons…"

> "Prefer nondestructive actions. If you must provide a destructive action, make sure people have enough context…"

> "Avoid providing an action that merely opens your app."

> "Provide a simple, recognizable interface icon for each notification action."

【推論】可在通知上直接放「核准」「拒絕」(≤ 4 個);拒絕是否標 destructive:HIG 的 destructive 指「can result in data destruction」,拒絕一個指令不毀損資料，**不宜**標 destructive;但核准一個會刪檔的指令，使用者需要足夠脈絡 — 若推播內文因隱私不能顯示完整指令，就不應在推播上提供一鍵核准。這是推論，需產品決定。

### 11.3 Badge

> "Use a badge only to show people how many unread notifications they have."

> "Avoid creating a custom image or component that mimics the appearance or behavior of a badge."

### 11.4 中斷等級與行銷推播

> Interruption levels:Passive／Active(預設)／Time Sensitive／Critical。

> "Use the Time Sensitive interruption level only for notifications that are relevant in the moment. … make sure the notification is about an event that's happening now or will happen within an hour."

> "Never use the Time Sensitive interruption level to send a marketing notification."

> "Make sure people can manage their notification settings within your app."(行銷推播)

【推論】「Agent 等你核准」符合 Time Sensitive(現在發生、需要立即注意);「Agent 完成工作」用 Active;Critical 需要 entitlement 且限健康安全，不適用。

### 11.5 權限請求

> "Request permission only when your app clearly needs access … Ideally, wait to request permission until people actually use an app feature that requires access." — Privacy

> Pre-alert 畫面:"Include only one button and make it clear that it opens the system alert. … Use a term like "Continue" or "Next"…" / "don't provide a way for people to leave the screen or window without viewing the system alert — like offering an option to close or cancel." — Privacy

---

## 12. Sign in 與會員帳號

來源:[Sign in with Apple](https://developer.apple.com/design/human-interface-guidelines/sign-in-with-apple)、[Managing accounts](https://developer.apple.com/design/human-interface-guidelines/managing-accounts)、ASRG 4.8、5.1.1(v)

### 12.1 何時要求登入

> "Ask people to create an account only if your core functionality requires it…" / "Delay sign-in for as long as possible." — Managing accounts

ASRG 5.1.1(v):"If your app doesn't include significant account-based features, let people use it without a login."

【推論】GLOSSARY 已定義「只有訂閱功能需要會員;聊天與終端機不需要登入」,與 HIG／ASRG 一致。

### 12.2 第三方登入(Google)必須搭配的條件

ASRG 4.8:"Apps that use a third-party or social login service (such as … Google Sign-In …) to set up or authenticate the user's primary account with the app must also offer as an equivalent option another login service with the following features: the login service limits data collection to the user's name and email address; … allows users to keep their email address private …; … does not collect interactions with your app for advertising purposes without consent."

Sign in with Apple 符合這三個條件。

### 12.3 Sign in with Apple 按鈕

> "Prominently display a Sign in with Apple button. Make a Sign in with Apple button no smaller than other sign-in buttons, and avoid making people scroll to see the button."

| 最小寬度 | 最小高度 | 最小外距 |
|---|---|---|
| 140 pt | 30 pt | 按鈕高度的 1/10 |

- 用系統 `ASAuthorizationAppleIDButton`／SwiftUI `SignInWithAppleButton`:自動在地化、VoiceOver 標籤、Apple 核准外觀。
- 樣式:white(深色背景)、white with outline(淺色背景)、black(淺色背景，**不可**放深色背景)。【推論】深淺色模式要切換樣式。
- 自訂按鈕:標題只能是 "Sign in with Apple"／"Sign up with Apple"／"Continue with Apple";logo 與文字只能黑或白;"never create a custom Apple logo";App Review 會審查自訂按鈕。
- "Adjust the corner radius to match the appearance of other buttons in your app."

**【HIG 未規定】** Google 登入按鈕的外觀規範不在 Apple HIG 範圍(屬 Google 品牌規範，本文未查)。

### 12.4 登入後

> "Indicate when people are currently signed in. … displaying a phrase like "Using Sign in with Apple" in places like a settings or account interface."

> "Don't ask people to supply a password." / "Avoid asking for a personal email address when people supply a private relay address."

> "Always identify the authentication method you offer." / "In general, avoid offering an app-specific setting for opting in to biometric authentication." / "Avoid using the term passcode to refer to account authentication." — Managing accounts

### 12.5 刪除帳號

ASRG 5.1.1(v):"If your app supports account creation, you must also offer account deletion within the app."

> "Provide a clear way to initiate account deletion within your app or game." / "Tell people when account deletion will complete, and notify them when it's finished." / "If you support in-app purchases, help people understand how billing and cancellation work when they delete their account."(訂閱帳單會持續到使用者在 Apple 取消為止)— Managing accounts

> "If people used Sign in with Apple to create an account within your app, you revoke the associated tokens when they delete their account."

---

## 13. In-App Purchase／訂閱付費牆

來源:[Apple In-App Purchase](https://developer.apple.com/design/human-interface-guidelines/apple-in-app-purchase)(2026-09-17 更新)、ASRG 3.1.1、3.1.2、[Apple Developer Program License Agreement](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/) Schedule 2 §3.8

### 13.1 訂閱畫面必須揭露的資訊(合併三個來源)

| 必須揭露 | HIG 原文 | ASRG／Schedule 2 |
|---|---|---|
| 訂閱名稱 | "The subscription name, duration, and the content or services provided during each subscription period" | Schedule 2 3.8(b):"Title of auto-renewing subscription" |
| 期間 | 同上 | "Length of subscription" |
| 每期提供的內容／服務 | 同上 | 3.1.2(c):"clearly describe what the user will get for the price" |
| 價格(總扣款金額，在地化) | "The billing amount, correctly localized for the territories and currencies…" / "Display the total billing price for each in-app purchase you offer" | "Price of subscription, and price per unit if appropriate" |
| 恢復購買／既有訂閱者登入 | "A way for existing subscribers to sign in or restore purchases" | 3.1.1:"make sure you have a restore mechanism for any restorable in-app purchases" |
| 條款與隱私權政策連結 | "including links to your Terms of Service and Privacy Policy in your app and App Store metadata" | "Links to Your Privacy Policy and Terms of Use must be accessible within Your Licensed Application." |
| 介紹價格 | "list the introductory price, the duration of the offer, and the standard price the customer pays after the offer ends" | — |
| 免費試用 | "make sure people know that when the free trial is over, a payment will be automatically initiated for the next subscription period" | — |

Schedule 2 原文:"You clearly and conspicuously disclose to users the following information regarding Your auto-renewing subscription"。

### 13.2 其他付費牆規範

> "Use the default confirmation sheet. … Don't modify or replicate this sheet."

> "Design an integrated shopping experience. … Present products and handle transactions in ways that mirror the style of your app."

> "Provide clear, distinguishable subscription options. Use short, self-explanatory names … specify the price and duration for each option."

> "Display your store only when people can make payments."(`canMakePayments`)

> "Let people experience your app before making a purchase." / "Prompt people to subscribe at relevant times…"

> "Encourage a new subscription only when someone isn't already a subscriber."

> "Include a sign-up opportunity in your app's settings."

> "Provide summaries of the customer's subscriptions. In particular, people appreciate viewing the upcoming renewal date…"

> "Consider using the system-provided subscription-management UI."(`showManageSubscriptions(in:)`)

> "Always make it easy for customers to cancel an auto-renewable subscription. If the manage subscription action is deep within an app — or hard to recognize — subscribers can feel they're being discouraged or prevented from canceling."

> "Prominently mention Family Sharing in places where people learn about the content you offer."(若開啟 Family Sharing)

ASRG 3.1.2(a):訂閱期間至少 7 天、"Subscriptions must work on all of the user's devices where the app is available."

ASRG 3.1.2:"Apps that attempt to scam users … trick users into purchasing a subscription under false pretenses or engage in bait-and-switch…" 會被下架。

### 13.3 Offer Code 兌換

> "Consider supporting offer redemption within your app. The system automatically provides screens that present the offer-redemption flow … the only custom UI you need to create is one that initiates the system-provided flow. … you could add a "Redeem Code" button to your paywall, onboarding screens, or your app's settings screen."(`offerCodeRedemption(isPresented:onCompletion:)`)

> "Supply an engaging and informative promotional image. … If you don't supply a promotional image, the code redemption screens use your app icon by default."

> "A custom code can contain only alphanumeric ASCII characters. Don't use special characters, including Chinese and Arabic characters."

> "Tell people how to redeem a custom code. Because people can't redeem a custom code by entering it in their App Store account settings…"

> "Help people benefit from unlocked content as soon as they complete the redemption flow. … be prepared to welcome people who subscribe before they open your app for the first time."

### 13.4 退款協助(選用)

> "Use a simple title for the refund action, like "Refund" or "Request a Refund"." / "avoid making people scroll or open another screen to reveal your refund-request button." / "Avoid characterizing or providing guidance on Apple's refund policies."

---

## 14. Onboarding、Launch、Demo 模式

來源:[Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding)、[Launching](https://developer.apple.com/design/human-interface-guidelines/launching)、[Branding](https://developer.apple.com/design/human-interface-guidelines/branding)、ASRG 2.1(a)

> "Ideally, people can understand your app or game simply by experiencing it, but if onboarding is necessary, design a flow that's fast, fun, and optional."

> "Teach through interactivity." / "Consider providing a collection of context-specific tips instead of a single onboarding flow."(TipKit)

> "If you let people skip the tutorial … don't present it again on subsequent launches, but make sure it's easy for people to find if they want to view it later."

> "Keep onboarding content focused on the experience you provide. People … don't need to learn how to use the system or the device."

> "Avoid displaying licensing details within your onboarding flow."

> "Postpone nonessential setup flows or customization steps."

> "Prefer letting people experience your app or game before prompting them for ratings or purchases."

> Launch screen:"Design a launch screen that's nearly identical to the first screen of your app…" / "Avoid including text on your launch screen…" / "Don't advertise. … don't include logos or other branding elements unless they're a fixed part of your app's first screen." / "make sure that your launch screen matches the device's current orientation and appearance mode."

> "If you need a splash screen, consider displaying it at the beginning of your onboarding flow."

ASRG 2.1(a):"include demo account info … if your app includes a login. If you are unable to provide a demo account due to legal or security obligations, you may include a built-in demo mode in lieu of a demo account with prior approval by Apple. Ensure the demo mode exhibits your app's full features and functionality."

【推論】Demo 模式同時滿足兩件事:讓沒有主機的新使用者「先體驗再購買」,也方便審查(審查員沒有能 SSH 的主機)。但若要以 demo 模式**取代** demo 帳號給審查，需要事先取得 Apple 同意。Demo 模式畫面要明確標示是示範資料(HIG 無直接規定，屬 Feedback 原則的推論)。

---

## 15. Loading、進度、錯誤與回饋

來源:[Loading](https://developer.apple.com/design/human-interface-guidelines/loading)、[Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators)、[Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback)、[Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)、[Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts)

> "Show something as soon as possible. … consider showing placeholder text, graphics, or animations as content loads…"

> "When possible, use a determinate progress indicator." / "Keep progress indicators moving…" / "Don't switch from the circular style to the bar style."

> "If it's helpful, display a description that provides additional context for the task. Be accurate and succinct. Avoid vague terms like loading or authenticating because they seldom add value."(【推論】「正在連線到 mac-mini…」優於「載入中…」)

> "When it's feasible, let people halt processing. … include a Cancel button."

> "Perform automatic content updates. … Don't make people responsible for initiating every update." / refresh control 標題 "don't use it to explain how to perform a refresh."

> "Configure a button to display an activity indicator when you need to provide feedback about an action that doesn't instantly complete. … the label "Checkout" could change to "Checking out…"" — Buttons

> "Consider integrating status feedback into your interface." / "Use alerts to deliver critical — and ideally actionable — information." / "Show people when a command can't be carried out and help them understand why." — Feedback

> "Warn people when they initiate a task that can cause data loss that's unexpected and irreversible. In contrast, don't warn people when data loss is the expected result of their action." — Feedback

> "Avoid showing an alert when your app starts. … If your app detects a problem at startup, like no network connection, consider … show cached or placeholder data and a nonintrusive label…" — Alerts

> "Minimize use of time-boxed interface elements. Views and controls that auto-dismiss on a timer can be problematic…" — [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)(【推論】連線中斷、送出失敗等提示不要用幾秒後自動消失的 toast 作為唯一呈現)

---

## 16. Accessibility

來源:[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)、[VoiceOver](https://developer.apple.com/design/human-interface-guidelines/voiceover)、[Motion](https://developer.apple.com/design/human-interface-guidelines/motion)、[Materials](https://developer.apple.com/design/human-interface-guidelines/materials)、[Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode)

### 16.1 觸控目標與間距

| 平台 | 預設控制項尺寸 | 最小控制項尺寸 |
|---|---|---|
| iOS、iPadOS | 44×44 pt | 28×28 pt |

> "In general, it works well to add about 12 points of padding around elements that include a bezel. For elements without a bezel, about 24 points of padding works well…"

> "a button needs a hit region of at least 44x44 pt" — Buttons

### 16.2 VoiceOver

> "Provide alternative labels for all key interface elements. … Add labels to any custom elements your app defines."

> "Exclude purely decorative images from VoiceOver."

> "Use titles and headings to help people navigate your information hierarchy."

> "Specify how elements are grouped, ordered, or linked."(【推論】一則訊息的作者、時間、內容應組成一個 element)

> "Inform VoiceOver when visible content or layout changes occur."(`AccessibilityNotification`;【推論】agent 新訊息與狀態改變要通知，但串流輸出要節流，避免每個 token 都播報 — 節流是推論)

> "Support the VoiceOver rotor when possible."(【推論】讓使用者用 rotor 在訊息、code block、需要回答的提問之間跳)

> "Provide an accessibility label for every icon." — Adopting Liquid Glass

### 16.3 系統設定

- **Reduce Motion**:"ensure your app or game responds by reducing automatic and repetitive animations, including zooming, scaling, and peripheral motion" — 並列出 "Replacing transitions in x-, y-, and z-axes with fades"、"Avoiding animating into and out of blurs"。
- **Reduce Transparency／Increase Contrast**:Liquid Glass 會自動調整(Materials);自訂元素與顏色要自己測(Adopting Liquid Glass、Dark Mode)。
- **Bold Text**:系統字型自動支援;自訂字型要自己實作(Typography)。
- **Full Keyboard Access**:"Let people use the keyboard alone to navigate and interact with your app." / "Avoid overriding system-defined keyboard shortcuts…"
- **Voice Control**:"label interface elements appropriately"。
- **Gestures**:"Offer alternatives to gestures. … if you use a swipe gesture to dismiss a view, also make a button available…"(【推論】終端機捏合縮放要另有按鈕或選單調整字級)

### 16.4 稽核

> "Use Accessibility Inspector to highlight accessibility issues…" / "communicate how accessible your app is on the App Store using Accessibility Nutrition Labels."

---

## 17. SF Symbols 與介面圖示

來源:[SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)、[Icons](https://developer.apple.com/design/human-interface-guidelines/icons)

### 17.1 標準動作圖示(Icons › Standard icons 節錄)

| 動作 | Symbol |
|---|---|
| Copy | `document.on.document` |
| Paste | `document.on.clipboard` |
| Done | `checkmark` |
| Cancel | `xmark` |
| Delete | `trash` |
| Compose | `square.and.pencil` |
| Attach | `paperclip` |
| Add | `plus` |
| More | `ellipsis` |
| Share | `square.and.arrow.up` |
| Search | `magnifyingglass` |

> "Represent common actions consistently." — Menus

### 17.2 使用原則

> "In many cases, the view that displays a symbol determines whether to use outline or fill … an iOS tab bar prefers the fill variant, whereas a toolbar takes the outline variant."

> "Symbols that use an enclosing shape — like a square or circle — can improve legibility at small sizes."

> "Use variable color to communicate change — don't use it to communicate depth."

> 動畫:Pulse "to communicate ongoing activity";Breathe "signal that an activity is taking place";Variable color "communicate progress or ongoing activity, such as … connecting";Rotate "when a task is in progress"。

> "Apply symbol animations judiciously."

> "Provide alternative text labels for custom symbols."

> "Maintain visual consistency across all interface icons in your app." / "In general, match the weights of interface icons and adjacent text." — Icons

【推論】「工作中」狀態可用 breathe／pulse 動畫，但需在 Reduce Motion 時停用(Motion 要求)。

---

## 18. Haptics 與 Motion

來源:[Playing haptics](https://developer.apple.com/design/human-interface-guidelines/playing-haptics)、[Motion](https://developer.apple.com/design/human-interface-guidelines/motion)

> "Use system-provided haptic patterns according to their documented meanings."(notification:結果成功／失敗;impact:物理比喻;selection:值在變動)

> "Use haptics consistently throughout your app…" / "Avoid overusing haptics." / "In most apps, prefer playing short haptics that complement discrete events."

> "Make haptics optional. Let people turn off or mute haptics…"

> "Prefer using haptics to complement other feedback…"

> "Add motion purposefully…" / "Make motion optional." / "In apps, generally avoid adding motion to UI interactions that occur frequently." / "Let people cancel motion."

【推論】核准／拒絕送出成功用 notification success;送出失敗用 notification error;accessory bar 每次按鍵**不要**加 haptic(頻繁互動),改用鍵盤點擊音(§10.2)。

---

## 19. 終端機、程式碼等密集文字內容

**【HIG 未規定】** 查過 Typography、Text views、Scroll views、Going full screen、Keyboards、Virtual keyboards、Accessibility,HIG **沒有**終端機模擬器、程式碼顯示、markdown 渲染、聊天泡泡的專門規範。以下是可間接套用的一手原文，以及推論:

| 需求 | 可套用的原文 | 出處 |
|---|---|---|
| code block 橫向捲動 | "Avoid putting a scroll view inside another scroll view with the same orientation. … It's alright to place a horizontal scroll view inside a vertical scroll view (or vice versa)" | [Scroll views](https://developer.apple.com/design/human-interface-guidelines/scroll-views) |
| 長文字不截斷 | "Avoid truncating text in scrollable regions unless people can open a separate view to read the rest of the content." | [Typography](https://developer.apple.com/design/human-interface-guidelines/typography) |
| 終端機捏合縮放 | "If you support zoom, set appropriate maximum and minimum scale values." | Scroll views |
| 捏合是標準手勢 | Zoom:"Zoom a view; magnify content." | [Gestures](https://developer.apple.com/design/human-interface-guidelines/gestures) |
| 終端機字級作為放大機制 | "Your interface can support font size enlargement either through custom UI, or by adopting Dynamic Type." | [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) |
| 全螢幕 | "Continue to provide access to essential features and controls…" / "Let people choose when to exit full-screen mode." / 隱藏控制項時 "let people restore the hidden elements with a familiar gesture or action" | [Going full screen](https://developer.apple.com/design/human-interface-guidelines/going-full-screen) |
| 避免誤觸離開 | "If supporting this results in unexpected exits, you can enable two swipes rather than one to exit."(`preferredScreenEdgesDeferringSystemGestures`) | Going full screen › iOS, iPadOS |
| 不要與系統手勢衝突 | "Avoid conflicting with gestures that access system UI." | Gestures |
| 自動捲動 | "automatically scroll the content only as much as necessary to help people retain context." | Scroll views |
| 文字可拷貝 | "let people select and copy noneditable text" | [Edit menus](https://developer.apple.com/design/human-interface-guidelines/edit-menus) |
| 指標形狀 | "the pointer automatically uses the familiar I-beam shape when people move it over a text-entry area." | [Pointing devices](https://developer.apple.com/design/human-interface-guidelines/pointing-devices) |

【推論】
- 終端機的前景／背景色是內容層，ANSI 色盤仍應符合 4.5:1 對比(Accessibility 原則套用)。
- 對話中 agent 輸出的文字也應能用 Dynamic Type 放大;code block 用等寬字型跟著 text style 縮放。
- 「agent 正在輸出」時自動捲到底，但使用者往上捲時不應被強制拉回(Scroll views「only as much as necessary」的精神)。

---

## 20. Drover Chat 設計檢核清單

> 格式:`- [ ] 檢核項 — 依據頁面`。標 **【推論】** 表示原文沒直接講、由規範推得;標 **【HIG 未規定】** 表示 HIG 無規範、由本專案自訂。

### 20.1 App 圖示(三個方案都要逐項過)

- [ ] 用 Icon Composer 建立 `.icon` 檔，不用單張 PNG — [App icons › Icon formats](https://developer.apple.com/design/human-interface-guidelines/app-icons)
- [ ] 從 Apple Design Resources 下載最新 iOS 圖示模板與格網起稿 — [Icon Composer 文件](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
- [ ] 畫布 1024×1024 px 方形，圖層不預先套圓角遮罩、不匯出 canvas mask — App icons › Specifications、Icon shape
- [ ] 圖層以 SVG 匯出;mesh gradient／點陣元素用 PNG;文字轉外框 — Icon Composer 文件、App icons
- [ ] Group 數 1–4 個 — Icon Composer 文件、WWDC25 361
- [ ] 背景在 Icon Composer 內用純色或漸層，不用純白／純黑(改用 System Light／System Dark 漸層或有色背景)— App icons、WWDC25 220
- [ ] 前景形狀邊緣清楚，不羽化;沒有極細線條與尖角 — App icons
- [ ] 沒有自製高光、投影、斜角、模糊、光暈 — App icons › Visual effects
- [ ] 主要內容置中，不會被圓角裁到 — App icons
- [ ] 沒有非必要文字(含 app 名稱、「Chat」等字樣);若用提示字元類符號，確認是品牌必要 — App icons
- [ ] 沒有照片、沒有 app 截圖、沒有寫實的終端機／聊天介面複製品 — App icons
- [ ] 沒有 Apple 硬體、沒有 SF Symbols 或近似圖形 — App icons、SF Symbols
- [ ] 沒有 Claude／Anthropic／OpenAI 等其他公司的 logo、品牌或近似圖形 — ASRG 4.1(c)
- [ ] 圖像適合 4+ 年齡分級 — ASRG 2.3.8
- [ ] 在 default、dark、clear light、clear dark、tinted light、tinted dark 六種外觀下都可辨識，核心元素不增減 — App icons › Appearances
- [ ] dark 版以 default 版為基礎、不過亮;mono 標註至少一個主要元素設白色 — App icons、WWDC25 361
- [ ] 在 Icon Composer 以 iOS 26 與 27 兩種 rendering 比對;不依賴 refraction 才成立 — Icon Composer 文件
- [ ] 在 Icon Composer 搭配多種桌布背景預覽 clear／tinted;在 Device Hub 或實機上看小尺寸(Settings、通知)— Icon Composer 文件、App icons
- [ ] 若上架後讓使用者切換替代圖示:每個替代圖示都有 dark／clear／tinted 變體、彼此相像、都送審 — App icons、ASRG 2.3.8
- [ ] 三個方案在 App Store 圖示、iPhone、iPad 上是同一設計 — App icons

### 20.2 全 app 共通

- [ ] 導覽與工具列用系統元件(NavigationSplitView、toolbar),沒有自訂 bar 背景色 — [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)、[Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)
- [ ] 內容層(列表列、泡泡、卡片)沒有 Liquid Glass;沒有 glass 疊 glass — [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)、WWDC25 219
- [ ] 自訂 Liquid Glass 只用 regular 變體，並包在 `GlassEffectContainer` — Materials、Adopting Liquid Glass 【推論:Drover 無媒體背景故不用 clear】
- [ ] 所有自訂顏色在 Asset Catalog 有 light／dark／各自 high contrast 四個值 — [Color](https://developer.apple.com/design/human-interface-guidelines/color)
- [ ] 文字對比 ≥ 4.5:1(小字目標 7:1),深淺色都量 — [Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode)、[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [ ] accent color 只用在主要動作與狀態;每個畫面 prominent 按鈕 ≤ 2 個 — [Branding](https://developer.apple.com/design/human-interface-guidelines/branding)、[Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)
- [ ] 沒有 app 內「淺色／深色模式」設定 — Dark Mode
- [ ] 所有文字用 text style,在 AX5 下不截斷、版面改堆疊 — [Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- [ ] 沒有 Ultralight／Thin／Light 字重;最小 11 pt — Typography
- [ ] 觸控目標 ≥ 44×44 pt(絕對最小 28×28 pt)— Accessibility
- [ ] 每個 icon-only 按鈕都有 accessibility label — Adopting Liquid Glass、[VoiceOver](https://developer.apple.com/design/human-interface-guidelines/voiceover)
- [ ] Reduce Motion、Reduce Transparency、Increase Contrast、Bold Text 各開一次逐頁檢查 — Accessibility、Dark Mode、Adopting Liquid Glass
- [ ] 標準動作用 Standard icons 表裡的 symbol — [Icons](https://developer.apple.com/design/human-interface-guidelines/icons)
- [ ] section header 用一般大小寫，不全大寫 — Adopting Liquid Glass
- [ ] Launch screen 幾乎等於第一個畫面，無文字、無 logo,跟隨深淺色 — [Launching](https://developer.apple.com/design/human-interface-guidelines/launching)
- [ ] App 重開時還原上次的主機、Agent、捲動位置 — Launching
- [ ] UI 文字稱「視窗」不稱 scene — [Windows](https://developer.apple.com/design/human-interface-guidelines/windows)

### 20.3 主機清單／新增主機

- [ ] 主機清單是內容層 list,選取列在 split view 中持續高亮 — [Split views](https://developer.apple.com/design/human-interface-guidelines/split-views)
- [ ] 長主機名稱必要時用中間省略 — [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables)
- [ ] 主機的 context menu 項目在主介面也找得到;刪除主機放最後並標 destructive — [Context menus](https://developer.apple.com/design/human-interface-guidelines/context-menus)
- [ ] context menu 頂端動作與 swipe actions 一致 — Adopting Liquid Glass
- [ ] 刪除主機是使用者刻意的動作 → 不另跳 alert,或只在不可復原時確認 — [Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback)、[Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts)
- [ ] 沒有主機時顯示說明與新增入口(空狀態)— Tab bars「If a section is empty, explain why」【推論:原文針對 tab,精神套用】
- [ ] 新增主機用 full-height sheet,Cancel 在左、新增在右,Cancel／Done／Back 不同時出現 — [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets)
- [ ] 有未存變更時 swipe 關閉 sheet 要用 action sheet 確認 — Sheets
- [ ] 多步驟在同一個 sheet 內 push,不疊第二個 sheet — Sheets
- [ ] 欄位有標籤(不只 placeholder);位址用 URL／ASCII 鍵盤、port 用數字鍵盤;密碼用 SecureField — [Text fields](https://developer.apple.com/design/human-interface-guidelines/text-fields)
- [ ] SSH 公鑰以等寬字型顯示、可選取拷貝，另提供拷貝與分享按鈕(`document.on.document`、`square.and.arrow.up`)— [Edit menus](https://developer.apple.com/design/human-interface-guidelines/edit-menus)、Icons 【推論:等寬字型 HIG 未規定】
- [ ] Host key 指紋確認用 alert:具體標題、動詞按鈕(不用「確定」)、有「取消」、接受按鈕不是預設 — Alerts 【推論:指紋確認屬安全決策】
- [ ] 指紋以等寬字型、可拷貝 — 【HIG 未規定】
- [ ] 連線中顯示具體描述(「正在連線到 …」)與可取消 — [Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators)

### 20.4 Agent 聊天列表

- [ ] 依「需要你／工作中／閒置」分 section(grouped list)— Lists and tables
- [ ] 狀態同時用文字 + symbol 形狀 + 顏色，不只靠顏色 — Color、Accessibility
- [ ] 「工作中」若用 symbol 動畫(breathe／pulse),Reduce Motion 時停用 — [SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)、Accessibility
- [ ] 新資料自動更新;若有下拉更新，標題不解釋如何下拉 — Progress indicators
- [ ] 使用者在 app 前景時，新的「需要你」不跳系統通知，改在列表中呈現 — [Notifications](https://developer.apple.com/design/human-interface-guidelines/notifications)
- [ ] Badge 只用在真正需要注意的項目 — [Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars)、Notifications
- [ ] 可用 context menu「在新視窗開啟」(iPad)— Windows

### 20.5 對話畫面

- [ ] 訊息泡泡、code block、subagent 卡片在內容層，用系統背景色／標準 material,不用 Liquid Glass — Materials
- [ ] 泡泡顏色與文字對比 ≥ 4.5:1;agent／使用者的區分不只靠顏色(位置或標示)— Accessibility 【推論:聊天泡泡 HIG 未規定】
- [ ] code block 用等寬字型、跟隨 Dynamic Type、可橫向捲動(不截斷)— Scroll views、Typography 【推論:字型選擇 HIG 未規定】
- [ ] code block 文字可選取拷貝，若有拷貝按鈕用 `document.on.document` 並有 label — Edit menus、Icons
- [ ] thinking 與 tool 呼叫用 DisclosureGroup,收合標籤具體描述內容 — [Disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls)
- [ ] 新訊息與狀態變更通知 VoiceOver,串流輸出有節流 — VoiceOver 【推論:節流】
- [ ] 一則訊息的作者／內容組成一個 VoiceOver element;提供 rotor 跳轉 — VoiceOver
- [ ] 自動捲到底只在使用者位於底部時發生 — Scroll views 【推論】
- [ ] 導覽列標題 < 15 字元、不用 app 名稱 — Toolbars
- [ ] 工具列項目同時提供 title 與 symbol(iPhone Duo 直式工具列需要)— [Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)
- [ ] 工具列 group ≤ 3,text 按鈕與 symbol 按鈕不放在同一個背景 — Toolbars、WWDC25 356
- [ ] 載入對話時先顯示快取或 placeholder — [Loading](https://developer.apple.com/design/human-interface-guidelines/loading)
- [ ] 連線中斷用畫面內非干擾式標示，不在進入畫面時跳 alert,也不只用自動消失的 toast — Alerts、Accessibility

### 20.6 輸入列(slash command、附加圖片)

- [ ] 輸入列是功能層，用 `safeAreaBar` 或標準 toolbar,捲到下方的訊息有 scroll edge effect — Adopting Liquid Glass、Scroll views
- [ ] 輸入框多行(text view 行為);送出鍵 `submitLabel` 清楚 — Text fields、[Virtual keyboards](https://developer.apple.com/design/human-interface-guidelines/virtual-keyboards)
- [ ] 用 keyboard layout guide,鍵盤出現時輸入列與最新訊息不被遮 — Virtual keyboards
- [ ] 送出按鈕是唯一 tinted 主要動作 — Color › Liquid Glass color、Toolbars
- [ ] 附加圖片用 `paperclip` 或照片相關 symbol,並用系統 out-of-process PhotosPicker(不要求完整相簿權限)— Icons、ASRG 5.1.1(iii)
- [ ] slash command 選單:項目以動詞／指令名開頭、簡短，可鍵盤上下選擇 — Menus 【HIG 未規定:自動完成元件】
- [ ] 送出中按鈕顯示 activity indicator — Buttons

### 20.7 回答 agent 的選項(核准／拒絕)

- [ ] 按鈕放在該則提問旁(內容層),不放全域工具列 — WWDC25 356
- [ ] 不用 Liquid Glass 按鈕樣式，用一般 bordered／borderedProminent — Materials 【推論】
- [ ] 同一組選項同尺寸，用樣式(prominent)而非大小區分建議選項 — Buttons
- [ ] 不把會造成破壞的選項設為 primary／預設 — Buttons
- [ ] 「拒絕」不套 destructive 紅色(拒絕不毀損資料)— Buttons › Role 【推論】
- [ ] 選項標籤用動詞、具體描述結果 — Alerts › Buttons 【推論:原文針對 alert】
- [ ] 送出結果用 notification haptic(成功／失敗),haptic 可關閉 — [Playing haptics](https://developer.apple.com/design/human-interface-guidelines/playing-haptics)
- [ ] 已回答的提問清楚顯示選了什麼(不只改顏色)— Feedback、Color

### 20.8 終端機

- [ ] 全螢幕時必要控制(離開、accessory bar)保持可用或容易叫出 — [Going full screen](https://developer.apple.com/design/human-interface-guidelines/going-full-screen)
- [ ] 不自動離開全螢幕;由使用者決定 — Going full screen
- [ ] 若常誤觸離開，才延後系統邊緣手勢(兩次滑動)— Going full screen
- [ ] Accessory bar 用標準 keyboard toolbar(自動 Liquid Glass)或對容器套 Liquid Glass;按鍵不各自做成獨立玻璃 — Virtual keyboards、WWDC25 219
- [ ] Accessory bar 每顆鍵 ≥ 44×44 pt(最小 28×28 pt)、hit region 連續 — Accessibility、Pointing devices
- [ ] 每顆鍵有 VoiceOver label(「Escape」「Tab」「Control」「向上鍵」等)— VoiceOver
- [ ] 按鍵播放標準鍵盤點擊音，不加 haptic — Virtual keyboards、Playing haptics 【推論】
- [ ] Ctrl 鍵的鎖定狀態不只用顏色表示 — Color 【推論】
- [ ] 捏合縮放設定最大／最小字級;另有按鈕或選單可調字級(手勢替代)— Scroll views、Accessibility
- [ ] 沒有與系統邊緣手勢衝突的自訂手勢 — [Gestures](https://developer.apple.com/design/human-interface-guidelines/gestures)
- [ ] 終端機配色主題對比 ≥ 4.5:1 — Accessibility 【推論】
- [ ] app 快捷鍵只用 Command;終端機聚焦時 Control 組合鍵與 Esc 送給遠端 — [Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards) 【推論:終端機按鍵優先權 HIG 未規定】
- [ ] 避開 iPhone Duo 折疊區與鏡頭區(ReservedRegion)— Designing for iPhone Duo(#69:`ReservedRegion` 要 iOS 27.1 SDK,待 Xcode 27.1 與 Duo 模擬器，見 `iphone-duo.md`)
- [ ] iPad 指標在終端機區顯示 I-beam — Pointing devices 【推論】

### 20.9 iPad(三欄、多視窗、鍵盤)

- [ ] NavigationSplitView 三欄(主機／Agent／對話),各欄選取持續高亮 — Split views、[Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [ ] sidebar 不超過兩層階層;預設不隱藏 sidebar,可用邊緣滑動隱藏 — Sidebars
- [ ] 在窄、中、寬視窗寬度都能合理切換欄位 — Split views
- [ ] 視窗化時 leading 工具列按鈕不被視窗控制鈕蓋住 — Windows
- [ ] 支援多視窗;不預設開新視窗，提供「在新視窗開啟」— Windows、[Multitasking](https://developer.apple.com/design/human-interface-guidelines/multitasking)
- [ ] 每個視窗標題可區分(例如 Agent 名稱 + 主機)— Toolbars
- [ ] 不覆寫標準快捷鍵;自訂快捷鍵只給最常用動作、以 Command 為主 — Keyboards
- [ ] Command-, 開 app 內設定;menu bar 的 Settings 項目保留給系統 Settings 頁，app 內設定另列一項 — [Settings](https://developer.apple.com/design/human-interface-guidelines/settings)、[The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar)
- [ ] menu bar 裡的功能在 UI 也都找得到 — The menu bar
- [ ] 支援 Full Keyboard Access — Keyboards、Accessibility
- [ ] 指標效果:玻璃群組用 highlight、獨立玻璃控制項用 lift — Pointing devices

### 20.10 設定

- [ ] 設定項目精簡;任務相關的選項放在該畫面 — Settings
- [ ] 不重複系統設定(外觀模式、無障礙、生物辨識開關)— Settings、Dark Mode、Managing accounts
- [ ] 推播設定可在 app 內管理(含行銷推播的同意與退出)— [Managing notifications](https://developer.apple.com/design/human-interface-guidelines/managing-notifications)、ASRG 4.5.4
- [ ] 有訂閱入口、訂閱摘要(含續訂日期)、管理訂閱(系統 UI)、兌換代碼 — [Apple In-App Purchase](https://developer.apple.com/design/human-interface-guidelines/apple-in-app-purchase)
- [ ] 顯示目前登入方式(「使用 Sign in with Apple」)— Sign in with Apple
- [ ] 刪除會員帳號入口清楚(不藏在隱私權政策裡),說明訂閱不會因刪帳號自動取消 — Managing accounts、ASRG 5.1.1(v)
- [ ] 可重新觀看教學／Demo — [Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding)
- [ ] haptics 可關閉 — Playing haptics

### 20.11 會員登入(Apple／Google)

- [ ] 只在要用訂閱功能時才要求登入 — [Managing accounts](https://developer.apple.com/design/human-interface-guidelines/managing-accounts)、ASRG 5.1.1(v)
- [ ] 登入畫面簡短說明登入的好處 — Managing accounts、Sign in with Apple
- [ ] 提供 Google 登入時同時提供 Sign in with Apple — ASRG 4.8
- [ ] Sign in with Apple 按鈕不小於 Google 按鈕、不需捲動即可看到 — [Sign in with Apple](https://developer.apple.com/design/human-interface-guidelines/sign-in-with-apple)
- [ ] 用系統 Sign in with Apple 按鈕;深淺色切換 white／black 樣式;最小 140×30 pt、外距 ≥ 高度 1/10 — Sign in with Apple
- [ ] 兩個登入按鈕圓角一致 — Sign in with Apple
- [ ] 不要求密碼、不要求 private relay 使用者提供真實 email — Sign in with Apple
- [ ] Google 按鈕外觀 — 【HIG 未規定】(依 Google 規範)

### 20.12 訂閱付費牆

- [ ] 每個方案:名稱、期間、每期內容、在地化總價(必要時單位價)— Apple In-App Purchase、Schedule 2 §3.8(b)、ASRG 3.1.2(c)
- [ ] 總扣款金額是最醒目的價格;折算月價放次要位置 — Apple In-App Purchase(Forest Explorer 範例)
- [ ] 免費試用:試用長度與結束後自動扣款的金額寫清楚 — Apple In-App Purchase
- [ ] 介紹價格:介紹價、期間、之後的原價 — Apple In-App Purchase
- [ ] 恢復購買／既有訂閱者登入按鈕 — Apple In-App Purchase、ASRG 3.1.1
- [ ] 條款(Terms of Use)與隱私權政策連結 — Apple In-App Purchase、Schedule 2 §3.8(b)
- [ ] 兌換代碼按鈕觸發系統 offer code 流程 — Apple In-App Purchase
- [ ] 購買確認用系統 sheet,不仿製 — Apple In-App Purchase
- [ ] 不能付款(家長限制)時隱藏商店或說明原因 — Apple In-App Purchase
- [ ] 已是訂閱者時不顯示訂閱推銷 — Apple In-App Purchase
- [ ] 方案名稱短、不截斷不換行 — Apple In-App Purchase
- [ ] 付費牆風格與 app 一致 — Apple In-App Purchase
- [ ] 付費牆可以關閉、不阻擋免費功能 — 【推論:依「Let people experience your app before making a purchase」與 GLOSSARY「聊天與終端機不需登入」】
- [ ] 兌換完成後立即開通並歡迎 — Apple In-App Purchase

### 20.13 推播通知

- [ ] 在使用者第一次需要推播的情境才請求權限;若有 pre-alert 畫面只有一個「繼續」按鈕 — [Privacy](https://developer.apple.com/design/human-interface-guidelines/privacy)
- [ ] app 不開推播也能正常使用 — ASRG 4.5.4
- [ ] 內文不含指令全文、路徑、token 等敏感內容 — Notifications、ASRG 4.5.4 【推論:何謂敏感】
- [ ] 提供隱藏預覽時的通用 placeholder — Notifications
- [ ] 標題簡短、不含 app 名稱 — Notifications
- [ ] 「需要你」用 Time Sensitive;「完成」用 Active;不用 Critical — Managing notifications 【推論:分級對應】
- [ ] 同一件事不重複推播 — Notifications
- [ ] 通知動作 ≤ 4 個、標籤簡短、各有 symbol;不提供「開啟 app」動作 — Notifications
- [ ] 通知上的核准動作只在推播內容足以讓使用者判斷時提供 — Notifications「make sure people have enough context」【推論】
- [ ] app icon badge 只表示未讀通知數，開啟後立即更新 — Notifications
- [ ] 錯誤用 alert,不用推播 — Notifications

### 20.14 Onboarding 與 Demo 模式

- [ ] Onboarding 短、可跳過，跳過後不再出現但可在設定找到 — [Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding)
- [ ] 不教系統操作、不放授權條款 — Onboarding
- [ ] 用互動與情境提示(TipKit)取代長篇說明 — Onboarding
- [ ] Demo 模式展示完整功能，畫面明確標示是示範 — ASRG 2.1(a) 【推論:標示】
- [ ] 若以 Demo 模式取代審查用 demo 帳號，事先取得 Apple 同意 — ASRG 2.1(a)
- [ ] Demo 結束或想用真實主機時，引導到新增主機而非直接付費牆 — Apple In-App Purchase「Let people experience your app before making a purchase」【推論】

### 20.15 iPhone Duo

- [ ] 在 Device Hub 的 iPhone Duo 各種姿態下測試 — Designing for iPhone Duo(#69:Duo 模擬器隨 Xcode 27.1 提供，本機 27.0 沒有，見 `iphone-duo.md`)
- [ ] 沒有固定寬度或綁定特定螢幕的版面 — Designing for iPhone Duo
- [ ] 不覆寫系統的直式工具列位置 — Designing for iPhone Duo
- [ ] ellipsis 只用於 overflow 選單，其他選單用不同符號;優先用系統 overflow menu — Designing for iPhone Duo
- [ ] 折疊時版面只做小幅調整，不大幅重排 — Designing for iPhone Duo

---

## 讀不到或不確定的項目

1. **系統色數值、Dynamic Type 尺寸表、tracking 表**:HIG 的這些表格在 JSON 中是圖片或另外的表格元件，本次轉文字時色值欄位是空的。本文沒有引用任何系統色 RGB 值(HIG 本身也說 "Avoid hard-coding system color values")。需要數值時請看 Apple Design Resources 或網頁。
2. **App 圖示格網的具體尺寸**:HIG 與 Icon Composer 文件都只說「用 Apple Design Resources 的模板與格網」,沒有寫出格網數字;WWDC25 220 只說格網「simpler and more evenly spaced」、圓角更圓。本文**沒有**格網的幾何數值，需下載官方模板確認。
3. **Sheets 多步驟流程的按鈕位置**:Sheets 頁(2026-03-24 更新)用分頁圖示範「First step／Subsequent step／Final step」的按鈕位置，內容在圖片裡，本次未讀到文字描述。
4. **Icon Composer 文件的 iOS 26／27 rendering 差異**:文件只說「earlier than 27 … Refraction settings have no visible effect」,沒有完整列出 26 與 27 的差異。
5. **iPhone Duo**:只讀了 HIG 頁;頁面列出的三支影片(*Design for iPhone Duo*、*Raise the bar with iPhone Duo*、*Strike a pose with adaptive layouts on iPhone Duo*)與開發者文件 *Preparing your app for iPhone Duo* 未讀。
6. **WWDC 影片**:只讀了 WWDC25 219／220／356／361 與 WWDC26 250(Principles of great design)、251(Communicate your brand identity on iOS)的逐字稿。WWDC26 其他設計場次(如 *Design intuitive search experiences*、*Craft clear names for features and labels*)未讀，與本文主題關聯較低。
7. **Schedule 2(DPLA)**:使用者限定的一手來源清單沒有列 DPLA,但 ASRG 3.1.2(c) 明文指向它，所以引用了 §3.8(b);若要嚴格限定來源，可只採 HIG 的揭露清單(內容一致)。
8. **Google 登入按鈕外觀**:屬 Google 的品牌規範，不在 Apple 來源範圍，未查。
9. **終端機／程式碼／聊天泡泡／markdown**:HIG 確定沒有專門規範(§19),相關檢核項都是推論。
10. **slash command 自動完成**:HIG 沒有自動完成／指令選單元件;WWDC26 *Design intuitive search experiences* 可能有相關搜尋建議模式，未讀。
11. **Live Activities**:HIG 有 Live activities 頁，可能適合「Agent 工作中」狀態，但不在本次要求範圍，未讀。

## 來源清單(本次實際讀取)

HIG(全部讀到 Change log;網址前綴 `https://developer.apple.com/design/human-interface-guidelines/`):
`design-principles`、`designing-for-ios`、`designing-for-ipados`、`designing-for-iphone-duo`、`materials`、`app-icons`、`color`、`dark-mode`、`typography`、`layout`、`accessibility`、`voiceover`、`sf-symbols`、`icons`、`branding`、`toolbars`、`tab-bars`、`sidebars`、`split-views`、`lists-and-tables`、`disclosure-controls`、`sheets`、`alerts`、`action-sheets`、`menus`、`context-menus`、`edit-menus`、`buttons`、`text-fields`、`virtual-keyboards`、`keyboards`、`the-menu-bar`、`windows`、`multitasking`、`pointing-devices`、`gestures`、`scroll-views`、`going-full-screen`、`notifications`、`managing-notifications`、`privacy`、`sign-in-with-apple`、`managing-accounts`、`apple-in-app-purchase`、`onboarding`、`launching`、`loading`、`progress-indicators`、`feedback`、`playing-haptics`、`motion`、`settings`

開發者文件:
- https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
- https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer

WWDC 影片(逐字稿):
- https://developer.apple.com/videos/play/wwdc2025/219/ — Meet Liquid Glass
- https://developer.apple.com/videos/play/wwdc2025/356/ — Get to know the new design system
- https://developer.apple.com/videos/play/wwdc2025/220/ — Say hello to the new look of app icons
- https://developer.apple.com/videos/play/wwdc2025/361/ — Create icons with Icon Composer
- https://developer.apple.com/videos/play/wwdc2026/250/ — Principles of great design
- https://developer.apple.com/videos/play/wwdc2026/251/ — Communicate your brand identity on iOS

App Store／協議:
- https://developer.apple.com/app-store/review/guidelines/(Last Updated: October 16, 2026)— 2.1(a)、2.3.8、3.1.1、3.1.2、4.1(c)、4.5.4、4.8、5.1.1
- https://developer.apple.com/support/terms/apple-developer-program-license-agreement/ — Schedule 2 §3.8
