// swift-tools-version: 6.2
// 主機並行輪詢的回歸工具(#86、#91):以可攜核心連真主機，模擬 app 同時開著的事件訂閱與輪詢中的畫面。
// 用法見 run.sh。
import PackageDescription

let package = Package(
    name: "HostPollRepro",
    platforms: [.macOS(.v26)],
    dependencies: [.package(name: "Purrdr", path: "../..")],
    targets: [
        // 主機通道(SSHHostChannel)與它的捷徑(HerdrClient(channel:)、HostOperatingSystem.detect)在 PurrdrSSH(#89)。
        .executableTarget(
            name: "host-poll-repro",
            dependencies: [.product(name: "PurrdrCore", package: "Purrdr"), .product(name: "PurrdrSSH", package: "Purrdr")]
        ),
    ]
)
