import Foundation
import Network

/// 網路路徑的監看(行為規格 §7.4,Seam 3 平台服務)。
///
/// 每次路徑更新送出「狀態 + 排序後的可用介面類型」:Wi-Fi↔行動網路、Tailscale 上下線(utun 是 `other`)都會改變它。
/// 判斷「改變了沒」與之後要做什麼在 `HostsModel.networkPathChanged(_:)`。
public enum NetworkPaths {
    public static func signatures() -> AsyncStream<String> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in continuation.yield(signature(of: path)) }
            monitor.start(queue: DispatchQueue(label: "com.raychiu.purrdr.network-path"))
            continuation.onTermination = { _ in monitor.cancel() }
        }
    }

    static func signature(of path: NWPath) -> String {
        let types = Set(path.availableInterfaces.map { name(of: $0.type) }).sorted()
        return "\(path.status)|" + types.joined(separator: ",")
    }

    private static func name(of type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: "wifi"
        case .cellular: "cellular"
        case .wiredEthernet: "ethernet"
        case .loopback: "loopback"
        case .other: "other"
        @unknown default: "unknown"
        }
    }
}
