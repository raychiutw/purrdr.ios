// swift-tools-version: 6.2
// 只在 iOS 模擬器跑的 UIKit 行為測試(輸入框內捲、終端機接管鍵盤輸入;終端機捲動要真的手指滑動，在 PurrdrUITests 的 PaneTerminalUITests)。
// 獨立成 package:根 package 的 PurrdrCoreTests／PurrdrFeaturesTests 有 macOS 專用程式碼，
// 放進同一個 scheme 會讓 iOS 的 `xcodebuild test` 編不過。根目錄的 `swift test` 與 CI 都不跑這裡。
// 執行方式見 AGENTS.md「常用指令」。
import PackageDescription

let package = Package(
    name: "PurrdrIOSTests",
    platforms: [.iOS(.v26)],
    dependencies: [
        .package(name: "Purrdr", path: "../.."),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0"),
    ],
    targets: [
        .testTarget(
            name: "PurrdrIOSTests",
            dependencies: [
                .product(name: "PurrdrFeatures", package: "Purrdr"),
                .product(name: "PurrdrCore", package: "Purrdr"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Tests"
        ),
    ]
)
