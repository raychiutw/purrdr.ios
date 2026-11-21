import Foundation
import Network
import PurrdrCore

/// 把目前的網路類型(Wi-Fi／行動網路／其他)告訴流量計量(#353,Seam 3 平台服務)。
/// 只看路徑實際使用的介面;不產生任何網路流量。
public final class TrafficNetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()

    public init(meter: TrafficMeter) {
        monitor.pathUpdateHandler = { path in
            meter.setNetwork(
                TrafficNetwork(usesWiFi: path.usesInterfaceType(.wifi), usesCellular: path.usesInterfaceType(.cellular)))
        }
        monitor.start(queue: DispatchQueue(label: "com.raychiu.purrdr.traffic-network"))
    }

    deinit { monitor.cancel() }
}
