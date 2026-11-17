// swift-tools-version: 6.2
// 只在 iOS 模擬器跑的 UIKit 行為測試(輸入框內捲、終端機捲動)。
// 獨立成 package:根 package 的 PurrdrCoreTests／PurrdrFeaturesTests 有 macOS 專用程式碼，
// 放進同一個 scheme 會讓 iOS 的 `xcodebuild test` 編不過。根目錄的 `swift test` 與 CI 都不跑這裡。
// 執行方式見 AGENTS.md「常用指令」。
import PackageDescription

let package = Package(
    name: "PurrdrIOSTests",
    platforms: [.iOS(.v26)],
    dependencies: [
        .package(name: "Purrdr", path: "../.."),
    ],
    targets: [
        .testTarget(
            name: "PurrdrIOSTests",
            dependencies: [.product(name: "PurrdrFeatures", package: "Purrdr")],
            path: "Tests"
        ),
    ]
)
