// swift-tools-version: 6.2
// 依賴方向由 target 宣告強制(#89):
//   App → Features → AgentFeatures → Core
//   App → Features → SSH → Core;App → Demo → SSH
// - 可攜核心(PurrdrCore、PurrdrSSH、PurrdrDemo)不依賴任何 Apple 專屬 framework(ADR-0006),
//   CI 用 Swift SDK for Android 編譯它們把關;`PortableCoreImportTests` 在本機先擋一次。
// - 上層功能(PurrdrAgentFeatures:Agent 列表、對話、Pane 終端機)只依賴核心的主機連線 HostConnection,
//   看不到主機通道 HostChannel(在 PurrdrSSH);SSH 專屬功能在 PurrdrFeatures。
// - Features 不依賴 Demo:畫面只透過核心與主機通道的介面拿資料，不知道背後是誰。
// CI 另外用 `swift build --build-system native --build-tests --explicit-target-dependency-import-check error` 把關，
// 避免增量建置放過「沒宣告依賴卻 import」的違規。
import PackageDescription

/// warning 一律當 error(AGENTS.md 完成定義)。
///
/// 只在 macOS(`swift test`)套用：Xcode 建置 app 時會對 package target 加上 `-suppress-warnings`,
/// 跟 `-warnings-as-errors` 同時出現會直接建置失敗。iOS 才編譯的程式碼由 CI 在 package 根目錄
/// 另外跑一次 `xcodebuild build SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` 把關。
let strictSettings: [SwiftSetting] = [.treatAllWarnings(as: .error, .when(platforms: [.macOS]))]

let package = Package(
    name: "Purrdr",
    // 加上 macOS 26,才能在 Mac 上直接跑 `swift test`(Observation 需要)。
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "PurrdrCore", targets: ["PurrdrCore"]),
        .library(name: "PurrdrSSH", targets: ["PurrdrSSH"]),
        .library(name: "PurrdrDemo", targets: ["PurrdrDemo"]),
        .library(name: "PurrdrAgentFeatures", targets: ["PurrdrAgentFeatures"]),
        .library(name: "PurrdrFeatures", targets: ["PurrdrFeatures"]),
        .library(name: "PurrdrTestSupport", targets: ["PurrdrTestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.11.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        // 終端機模擬器(MIT)。固定最新穩定版 1.19.0(1.20 是 prerelease;1.99.x 是 2.0 前的破壞性系列，暫不採用):
        // - 1.12 起帶 Metal shader:Xcode 27 要先裝 Metal Toolchain(`xcodebuild -downloadComponent MetalToolchain`);
        // - 1.19 起帶 build-tool plugin(SwiftTermBuildInfoPlugin):命令列 xcodebuild 要加 `-skipPackagePluginValidation`。
        // 本機與 CI 的步驟見 AGENTS.md「常用指令」。
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0"),
    ],
    targets: [
        // 可攜核心：主機連線、herdr client、領域型別。只用 Foundation 與 swift-nio／swift-nio-ssh／swift-crypto。
        .target(
            name: "PurrdrCore",
            dependencies: [
                // 只用 NIOSSH 的私鑰型別(`SSHCredential`、OpenSSH 私鑰匯入);連線在 PurrdrSSH。
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                // 出口合規：只用系統加密(CryptoKit 介面;swift-crypto 在 Apple 平台就是轉呼叫 CryptoKit)。
                // 不加入 `_CryptoExtras` 或任何自寫的加密演算法，見 docs/launch/checklist.md。
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "src/PurrdrCore",
            swiftSettings: strictSettings
        ),
        // 主機通道(HostChannel)與只有 SSH 連線方式才有的主機功能。可攜，限制同核心。
        .target(
            name: "PurrdrSSH",
            dependencies: [
                "PurrdrCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ],
            path: "src/PurrdrSSH",
            swiftSettings: strictSettings
        ),
        // Demo 主機：不連網路的主機通道實作。App Review 與 UI 測試都靠它，所以 Release 也會帶。
        .target(
            name: "PurrdrDemo",
            dependencies: ["PurrdrCore", "PurrdrSSH"],
            path: "src/PurrdrDemo",
            swiftSettings: strictSettings
        ),
        // 上層功能(Agent 列表、對話、Pane 終端機)的畫面 model:只經主機連線，看不到主機通道(不依賴 PurrdrSSH)。
        .target(
            name: "PurrdrAgentFeatures",
            dependencies: ["PurrdrCore"],
            path: "src/PurrdrAgentFeatures",
            swiftSettings: strictSettings
        ),
        // SwiftUI 畫面、SSH 專屬功能(主機管理、登入 Shell、推播外掛、主題、資料夾…)與它們的 model。
        .target(
            name: "PurrdrFeatures",
            dependencies: [
                "PurrdrAgentFeatures", "PurrdrCore", "PurrdrSSH", .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "src/PurrdrFeatures",
            swiftSettings: strictSettings
        ),
        // 假主機與錄製回應：核心與畫面 model 的測試共用(Seam 1)。
        .target(
            name: "PurrdrTestSupport",
            dependencies: ["PurrdrCore", "PurrdrSSH"],
            path: "tests/PurrdrTestSupport",
            resources: [.copy("Fixtures")],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "PurrdrCoreTests",
            dependencies: [
                "PurrdrCore", "PurrdrSSH", "PurrdrDemo", "PurrdrTestSupport",
                // 測試用 SSH 伺服器(swift-nio-ssh server 角色)。
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "tests/PurrdrCoreTests",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "PurrdrFeaturesTests",
            dependencies: [
                "PurrdrFeatures", "PurrdrAgentFeatures", "PurrdrCore", "PurrdrSSH", "PurrdrTestSupport",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "tests/PurrdrFeaturesTests",
            swiftSettings: strictSettings
        ),
    ]
)
