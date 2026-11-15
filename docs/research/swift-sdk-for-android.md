# Swift SDK for Android 現況調查(截至 2026-11-15)

> 目的:評估「把 Drover Chat 的核心邏輯(含 SSH:swift-nio-ssh + swift-crypto)做成可在 Android 編譯的 Swift package」是否可行。
>
> 標記:**【一手】** = 直接引自 swift.org／swiftlang／apple GitHub repo 原文或檔案;**【實測】** = 本次在本機實際下載／執行驗證;**【推論】** = 根據一手資料推出、未直接驗證的判斷。第三方文章只作線索，不作論據。

## TL;DR

- Swift SDK for Android 已隨 **Swift 6.3(2026-03-24)正式釋出**;目前最新是 **6.4.2**,官方 SDK 支援 **aarch64 / x86_64 / armv7** 三種架構、**API 23–37** 的 target triple。
- Foundation(swift-foundation 的 `FoundationEssentials` + swift-corelibs-foundation 的 `Foundation` / `FoundationNetworking` / `FoundationXML`)與 Dispatch 都隨 SDK 一起提供。
- swift-nio 在官方 CI 中**有** Android 建置(只 build、不跑測試);swift-crypto 的 `Package.swift` 明列 `.android`,在 Android 上走 vendored BoringSSL,且官方範例 app 就是用 swift-crypto;**swift-nio-ssh 與 swift-crypto 自己的 CI 都沒有 Android job**。
- Kotlin/Java 互通的官方方案是 **swift-java**(`jextract --mode=jni` 支援 Android),但仍在 0.x、明言 1.0 前不保證 API 穩定。

- 【實測】本機用**開源 Swift 6.4.2 toolchain + 官方 SDK 6.4.2 + NDK r30**,把一個依賴 `NIOSSH`(swift-nio-ssh 0.15.1)、`NIOPosix`(swift-nio 2.105.0)、`Crypto`(swift-crypto 5.1.1)的 dynamic library **成功交叉編譯**到 `aarch64`、`x86_64`、`armv7`(`-android28`),0 個 warning、不需任何 patch。**只驗證「編得過」,沒有在裝置／模擬器上跑**。詳見下方「本次實測」。

### 本次實測(2026-11-15,macOS arm64)

| 項目 | 值 |
|---|---|
| Toolchain | `swift-6.4.2-RELEASE-osx.pkg`(Apple 簽章 + notarized),`pkgutil --expand-full` 解開使用，未安裝到系統 |
| SDK | `swift-6.4.2-RELEASE_android.artifactbundle.tar.gz`,checksum 與官方頁相符;`swift sdk install --swift-sdks-path <scratch>` 後跑 bundle 內 `setup-android-sdk.sh` 連結 NDK |
| NDK | `android-ndk-r30-Darwin.zip` |
| 探針 package | `swift-tools-version: 6.0`,一個 `.dynamic` library target,依賴 `NIOSSH`、`NIOPosix`、`Crypto`;程式碼建立 Ed25519／P256 `NIOSSHPrivateKey`、`MultiThreadedEventLoopGroup`、`SHA256` |
| 指令 | `swift build --swift-sdk swift-6.4.2-RELEASE_android --triple <arch>-unknown-linux-android28 --static-swift-stdlib`(SwiftPM 預設 build system,沒有像 NIO CI 那樣加 `--build-system native`) |
| 結果 | aarch64 debug 冷建置 27.9 s「Build complete!」;x86_64 20.2 s、armv7 21.1 s 皆成功;release 0 個 warning |
| 產物 | `libProbe.so` 為 ELF aarch64 shared object;`NEEDED` 只有 `libm`、`libdl`、`liblog`、`libc++_shared`、`libc`;內含 3055 個 `CCryptoBoringSSL_` 前綴的 dynamic symbol(證實 Android 走 vendored BoringSSL,且符號有前綴) |
| 體積 | release `libProbe.so` 96.0 MB,`llvm-strip` 後 **57.8 MB**;`.rodata` 約 36 MB |

- 【推論】57.8 MB 中的大頭應是 ICU 資料:NIOSSH 依賴 `NIOFoundationCompat`(→ 完整 `Foundation` → `FoundationInternationalization` + `_FoundationICU`),static link 後把 ICU 一起帶進來。要瘦身得看 NIOSSH 能否改用 `NIOFoundationEssentialsCompat`(上游議題)或接受此體積。單一 ABI(arm64-v8a)的 APK 增量約在數十 MB 等級。

---

## 1. 官方 Swift SDK for Android 的狀態

### 1.1 時間線

| 日期 | 事件 | 來源 |
|---|---|---|
| 2025-10-24 | 宣布 **nightly preview**,由新成立的 Android Workgroup 負責;Windows installer 內附,Linux/macOS 另行下載 | 【一手】 https://www.swift.org/blog/nightly-swift-sdk-for-android/ |
| 2025-12-18 | Workgroup 說明架構、`@available(Android NN, *)` 支援，並開始產出 Swift 6.3 SDK nightly | 【一手】 https://www.swift.org/blog/exploring-the-swift-sdk-for-android/ |
| 2026-03-24 | **Swift 6.3 正式版**:「Swift 6.3 includes the first official release of the Swift SDK for Android」,並感謝 Workgroup「brought the Swift SDK for Android from nightly previews to an official release in Swift 6.3」 | 【一手】 https://www.swift.org/blog/swift-6.3-released/ |
| 2026-11(現況) | Getting Started 文件以 **Swift 6.4.2** 為例,SDK bundle 為 `swift-6.4.2-RELEASE_android` | 【一手】 https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html |

### 1.2 安裝方式

依官方 Getting Started【一手】(https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html),需要三個元件:

1. **開源版 Swift toolchain**(不能用 Xcode 內建的):「using a cross-compilation Swift SDK requires using an open-source toolchain and for the Swift SDK version to match exactly」。建議用 `swiftly install latest`。
2. **Swift SDK for Android**:
   ```
   swift sdk install https://download.swift.org/swift-6.4.2-release/android-sdk/swift-6.4.2-RELEASE/swift-6.4.2-RELEASE_android.artifactbundle.tar.gz \
     --checksum 4d6ad63ea74becd58e123ff58b1b48c3be5ec0db0dff0ea5abe37ac007dd3233
   ```
3. **Android NDK LTS r30**:「The Swift SDK for Android depends on the Android NDK, LTS version 30」,並設定 `ANDROID_NDK_HOME`。

建置:`swift build --swift-sdk swift-6.4.2-RELEASE_android --triple aarch64-unknown-linux-android23 --static-swift-stdlib`。執行檔需連同 NDK 的 `libc++_shared.so` 一起推上裝置。App 形式則是把 Swift module 建成各架構的 shared library 放進 APK,再經 swift-java 由 Kotlin/Java 呼叫(同頁)。

【實測】下載該 bundle(約 340 MB),`shasum -a 256` 與官方頁面 checksum 相符(`4d6ad63e…3233`)。

### 1.3 支援的架構與 API level

- **架構**:【實測】bundle 內 `swift-android/swift-sdk.json` 共 45 個 target triple,架構只有 `aarch64`、`x86_64`、`armv7` 三種(沒有 i686)。各架構各有一份 `usr/lib/swift-<arch>/android/` 執行期函式庫。
- **API level**:【實測】同檔的 triple 涵蓋 `android23` 到 `android37`。
- **不一致之處**:swift.org Platform Support 頁的「Minimum deployment version」寫 **Android 9 (API 28)**【一手】(https://www.swift.org/platform-support/);官方 CI 範本預設 triple 也是 `aarch64/x86_64-unknown-linux-android28`【一手】(https://github.com/swiftlang/github-workflows/blob/main/.github/workflows/swift_package_test.yml);swift-nio 的建置腳本預設 `android28`【一手】(https://github.com/apple/swift-nio/blob/main/scripts/swift-build-with-android-sdk.sh)。但 Getting Started 範例用 `android23`。
  - 【推論】SDK 技術上能 target API 23,但**官方承諾的最低部署版本是 API 28**;規劃時以 minSdk 28 為準較安全。
- **多 API level**:Swift 6.3 起支援 `@available(Android 33, *)` 與 `#available(Android 33, *)`【一手】(https://www.swift.org/blog/exploring-the-swift-sdk-for-android/)。
- **armv7(32 位元)**:swift-nio 有一張仍開著的 issue「Some tests crash on 32-bit Android armv7」(2024-10)【一手】(https://github.com/apple/swift-nio/issues/2908)。【推論】32 位元是次等支援，產品可只出 arm64-v8a + x86_64(模擬器)。

### 1.4 Foundation 在 Android 上的可用程度

- 【一手】Workgroup 說明:「Swift apps on Android bundle a native runtime that implements many of its features, including its standard library and core libraries, like Dispatch and Foundation」(https://www.swift.org/blog/exploring-the-swift-sdk-for-android/)。
- 【實測】bundle 內每個架構都有:`libFoundationEssentials.so`、`libFoundationInternationalization.so`、`lib_FoundationICU.so`(以上屬 swift-foundation)、`libFoundation.so`、`libFoundationNetworking.so`、`libFoundationXML.so`(屬 swift-corelibs-foundation)、`libdispatch.so`、`libswiftDispatch.so`、`libswiftObservation.so`、`libswiftSynchronization.so`、`libTesting.so`、`libXCTest.so`;static 版另附 `libcurl.a`、`libssl.a`、`libcrypto.a`、`libxml2.a`(`URLSession` 底層走 libcurl)。
- 【一手】官方 DocC:非 Apple 平台要 `#if canImport(FoundationNetworking) import FoundationNetworking` 才能用網路型別(https://github.com/swiftlang/swift-android-examples/blob/main/Sources/SwiftAndroid/SwiftAndroid.docc/BuildingForAndroid.md)。
- 體積【實測】(aarch64、未 strip 的 .so):`lib_FoundationICU.so` 43.7 MB、`libFoundationNetworking.so` 15.7 MB、`libswiftCore.so` 11.1 MB、`libFoundationEssentials.so` 10.0 MB、`libFoundation.so` 8.6 MB。【推論】只 `import FoundationEssentials`(不拉完整 `Foundation`)可避開 ICU 那 40+ MB;實際 APK 增量需 strip／static link 後再量。
- 已知未解問題(皆為 swift-corelibs-foundation 的 open issue,一手):
  - Android 上發網路請求時 `_MultiHandle deallocated with non-zero retain count` 崩潰(回報者為正式上架的 MediQuo app)— https://github.com/swiftlang/swift-corelibs-foundation/issues/5203
  - Android 的 `libFoundationXML.so` 缺 `libz.so` 依賴宣告，載入失敗 — https://github.com/swiftlang/swift-corelibs-foundation/issues/5271
  - `NSPredicate(format:)` 在非 Apple 平台不可用(文件化 issue)— https://github.com/swiftlang/swift-corelibs-foundation/issues/5345
  - swift-foundation:「Implement Android shims in Swift instead of C」— https://github.com/swiftlang/swift-foundation/issues/1769
- 【推論】`Data`、`Date`、`JSONEncoder/Decoder`、`UUID`、`FileManager` 等 Essentials 層級 API 可放心用;`URLSession`、`XMLParser`、`Bundle` 資源、`UserDefaults` 這類依賴系統整合的部分要個別驗證。Drover Chat 核心走 SwiftNIO 自己的 socket,不依賴 `URLSession`,受影響較小。

---

## 2. swift-nio / swift-nio-ssh / swift-crypto 能否為 Android 編譯

### 2.1 swift-nio:官方 CI 有 Android build(只編譯、不測試)

- 【一手】`apple/swift-nio` 有 `.github/workflows/android_swift_sdk.yml`,並在 `main.yml`(push 到 main + 每日排程)與 `pull_request.yml` 中以 `android-sdk` job 呼叫(https://github.com/apple/swift-nio/blob/main/.github/workflows/android_swift_sdk.yml、https://github.com/apple/swift-nio/blob/main/.github/workflows/main.yml)。
- 【一手】該 job 只跑 `swift build --build-system native --swift-sdk … --triple <arch>-unknown-linux-android28`(https://github.com/apple/swift-nio/blob/main/scripts/swift-build-with-android-sdk.sh);matrix 只有一組 `swift_version: "main"`(nightly),NDK 預設 `r27d`(https://github.com/apple/swift-nio/blob/main/scripts/install_android_ndk.sh)。
  - 【推論】也就是說 NIO 只保證「用 nightly main toolchain 編得過」,**沒有在正式版 SDK(6.3/6.4)上建置，也沒有跑測試**。
- 【一手】「CI: run the tests in an Android emulator」issue 仍 open(2026-02):社群維護者表示自己在外部 CI 對六個 API level 跑 NIO 測試，但需要 patch 掉部分 filesystem 測試;NIO 維護者回應「reluctant to disable test」(https://github.com/apple/swift-nio/issues/3512)。
- 【一手】過去已修的 Android 建置問題(顯示有人持續在追):#3180 `signal` unused 錯誤、#3154 armv7 測試無法建置、#3622 Swift System 1.7.0 讓 Linux/Android 測試壞掉(https://github.com/apple/swift-nio/issues/3180、/3154、/3622)。
- 最新版 2.105.0(2026-11-03)【一手】(https://github.com/apple/swift-nio/releases)。

### 2.2 swift-nio-ssh:沒有 Android CI

- 【一手】`apple/swift-nio-ssh` 的 workflows 只有 `main.yml`、`pull_request.yml`、`pull_request_label.yml`,內容是 Linux unit tests、benchmarks、cxx-interop、Static SDK、macOS、release builds,**沒有 Android(也沒有 Wasm)job**(https://github.com/apple/swift-nio-ssh/tree/main/.github/workflows)。
- 【一手】repo 內搜尋 "android" 的 issue/PR:0 筆。
- 【一手】依賴:`swift-nio`(`NIOCore`、`NIOConcurrencyHelpers`、`NIOFoundationCompat`)、`swift-crypto`(`"1.0.0"..<"6.0.0"`)、`swift-atomics`(https://github.com/apple/swift-nio-ssh/blob/main/Package.swift)。最新版 0.15.1(2026-10-26)。
- 【推論】NIOSSH 是純 Swift 協定實作，只碰 NIOCore 抽象與 Crypto API,不直接碰 OS socket;只要上游三者能編，自己能編的機率很高。但「沒人在 CI 守」意味著任何一版都可能悄悄壞掉。

### 2.3 swift-crypto:`Package.swift` 明列 Android,走 vendored BoringSSL

- 【一手】README:在有 CryptoKit 的 Apple 平台上，swift-crypto「compiles its entire API surface down to nothing and simply re-exports the API of CryptoKit」;其他平台則編入「A vendored copy of BoringSSL's libcrypto」以及 XKCP,API 層與 CryptoKit 相同(https://github.com/apple/swift-crypto/blob/main/README.md)。
- 【一手】`Package.swift` 的 `nonDarwinPlatforms` 明列 `.linux, .android, .windows, .wasi, .openbsd, .custom("freebsd")`,`CCryptoBoringSSL`、`CryptoBoringWrapper`、`CXKCP` 只在這些平台被連入(https://github.com/apple/swift-crypto/blob/main/Package.swift)。目前 vendored BoringSSL commit `0226f30467f540a3f62ef48d453f93927da199b6`。
- 【一手】但 README 第一段仍寫「suitable for use on Linux and ARM64 Windows platforms」,未提 Android;CI(`main.yml`/`pull_request.yml`)有 Linux、Windows、macOS、Static SDK、CMake,**沒有 Android job**(https://github.com/apple/swift-crypto/tree/main/.github/workflows)。
- 【一手】正面證據:官方範例 `swiftlang/swift-android-examples` 的推薦範例 `hello-swift-java/hashing-lib` 就是「A Swift package that uses `swift-crypto` to provide SHA256 hashing」,依賴範圍 `"1.0.0"..<"4.0.0"`(https://github.com/swiftlang/swift-android-examples/blob/main/README.md、https://github.com/swiftlang/swift-android-examples/blob/main/hello-swift-java/hashing-lib/Package.swift)。
- 最新版 5.1.1(2026-11-03)【一手】。
- 【推論】對 Drover Chat 的影響:
  - iOS 版的 swift-crypto 等於 CryptoKit;Android 版是 BoringSSL,**兩邊是不同實作**,行為一致性靠 swift-crypto 測試保證，但 Android 上沒人跑這些測試。
  - ADR 0003 提到的 **Secure Enclave P256 金鑰是 CryptoKit 專屬**(`SecureEnclave.P256`),swift-crypto 在非 Apple 平台沒有對應;Android 版需改用 Android Keystore(經 JNI)或軟體金鑰，這部分不能放進共用 package 的 Android 編譯路徑。
  - SDK 本身也附 `libcrypto.a`/`libssl.a`(給 libcurl 用);swift-crypto 的 BoringSSL 符號有前綴(`CCryptoBoringSSL_…`)避免衝突 —— 此點未逐一驗證。

---

## 3. Swift ↔ Kotlin/Java 互通(swift-java / JNI)

- 【一手】Swift 6.3 release:「use Swift Java and Swift Java JNI Core to integrate Swift code into existing Android applications written in Kotlin/Java」(https://www.swift.org/blog/swift-6.3-released/)。
- 【一手】`swiftlang/swift-java`:
  - 兩個方向:`SwiftJava` 函式庫 + 巨集(Swift 呼叫 Java,`@JavaClass`、`@JavaMethod`);`swift-java jextract` 產生 Java 綁定(Java 呼叫 Swift)。
  - `jextract --mode=ffm`(預設)需 JDK 22+ 的 FFM API,**Android 不可用**;`--mode=jni`「works on older JVMs as well as on Android」(https://github.com/swiftlang/swift-java/blob/main/README.md)。
  - 建置 swift-java 本身需 JDK 25。
  - 「There is no guarantee of API stability until the project reaches a 1.0 release.」最新版 **0.7.0(2026-10-14)**,約每 1–2 個月一個 minor(https://github.com/swiftlang/swift-java/releases)。
  - Android 專屬注意事項(https://github.com/swiftlang/swift-java/blob/main/Sources/SwiftJavaDocumentation/Documentation.docc/Android.md):
    - **Main actor 預設不會被執行**:「work submitted to Swift's main executor is not executed by default … asynchronous work that switches to the main actor may stop making progress」,需自行整合(文件舉第三方 swift-android-native 為例)。
    - 必須寫 R8/Proguard keep 規則，否則被包裝的型別會被移除、執行期崩潰。
    - 使用 Core Library Desugaring 時要開 `AndroidCoreLibraryDesugaring` trait。
- 【一手】`swiftlang/swift-java-jni-core`:低階 JNI 包裝，README 明說「Most developers should prefer to use the SwiftJava package」(https://github.com/swiftlang/swift-java-jni-core)。
- 【一手】也可以完全不用 swift-java,用 `@_cdecl("Java_…")` 手寫 JNI(官方 DocC 與 `hello-swift-raw-jni*` 範例)(https://github.com/swiftlang/swift-android-examples)。
- 【一手】Workgroup 不提供 UI 方案:「The workgroup is not providing a single GUI solution」,主打的用途是「sharing core business logic, algorithms, and data models」(https://www.swift.org/blog/exploring-the-swift-sdk-for-android/)。

---

## 4. 已知限制與風險

| # | 風險 | 依據 | 嚴重度(推論) |
|---|---|---|---|
| 1 | **swift-nio-ssh、swift-crypto 沒有 Android CI**;swift-nio 只在 nightly main 做 build-only。本次實測目前版本可編，但上游任一版都可能在 Android 上悄悄壞掉,**執行期行為完全沒人驗證** | 2.1–2.3 節的 workflow 檔、本次實測 | 高 → 需自建 Android CI(含模擬器測試) |
| 2 | **沒有官方在 Android 上跑 NIO 測試**;社群需 patch filesystem 測試才過 | swift-nio#3512 | 中(Drover 不用 NIOFileSystem) |
| 3 | **swift-java 0.x、API 不穩定**;Android 上 main actor 預設不跑 | swift-java README、Android.md | 高(影響 async/`@MainActor` 設計) |
| 4 | **Secure Enclave 金鑰是 CryptoKit 專屬**,Android 需另走 Keystore | 2.3 節 + ADR 0003 | 中(要把金鑰存取抽成 protocol) |
| 5 | **Toolchain 綁定**:SDK 必須與開源 toolchain 版本完全一致，不能用 Xcode toolchain;iOS 與 Android 建置可能用不同編譯器版本 | Getting Started | 中 |
| 6 | **除錯工具未成熟**:Workgroup 自承 debugging「now a high priority … While it may work for small examples, we need to expand and test it more」;Platform Support 的 Debugger/REPL 表沒有 Android | exploring 部落格、platform-support | 中 |
| 7 | **最低 API level 文件不一致**(SDK 有 23,官方表寫 28) | 1.3 節 | 低(以 28 規劃) |
| 8 | **體積**:完整 Foundation 帶 40+ MB 的 ICU;NIOSSH 經 `NIOFoundationCompat` 拉進完整 Foundation,探針 strip 後仍 57.8 MB | 1.4 節、本次實測 | 中～高(核心自身只用 FoundationEssentials,但擋不住 NIOSSH 的依賴) |
| 9 | **Foundation 個別功能 bug**(URLSession 崩潰、FoundationXML 缺 libz) | corelibs-foundation#5203、#5271 | 低～中(Drover 核心不依賴) |
| 10 | **armv7 測試崩潰** | swift-nio#2908 | 低(只出 64 位元) |
| 11 | **NDK 版本分歧**:文件要求 r30,NIO CI 用 r27d;SwiftPM 新預設 build system(swiftbuild)的 Android 支援與 SDK 內建 NDK 連結方式不同，NIO 被迫 `--build-system native` | NIO 腳本註解 | 低～中 |

## 5. 建議的下一步(推論)

1. 在 repo 內加一個 GitHub Actions job,用 `swiftlang/github-workflows` 的 `swift_package_test.yml`(`enable_android_sdk_build: true`,可選 `enable_android_sdk_checks: true` 跑模擬器測試)對核心 package 建置 + 測試(https://github.com/swiftlang/github-workflows/blob/main/.github/workflows/swift_package_test.yml)。
2. 核心 package 的設計約束:只 `import FoundationEssentials`(`#if canImport`)、平台相關能力(Secure Enclave/Keystore、Keychain、推播)抽成 protocol 由 app 層注入、避免在對外 API 依賴 `@MainActor`。
3. 先做一個「Kotlin 透過 swift-java 開 SSH 連線、跑一條 exec」的 spike,驗證 NIO event loop 執行緒、async 與 JNI 回呼的互動。
