import PurrdrAgentFeatures
import SwiftUI
#if os(iOS)
import AVFoundation
import UIKit
import VisionKit
#endif

/// 配對碼掃描的來源(#250)。UI 測試以 launch 旗標換成模擬，不依賴真相機。
public enum PairingCodeScanSource: Sendable, Equatable {
    /// VisionKit 資料掃描器;裝置不支援(模擬器、沒有相機)時不顯示掃描鈕，只能手動輸入。
    case camera
    /// 開掃描畫面後送出這段內容，像掃到一樣。
    case simulated(payload: String)
    /// 模擬沒有相機權限。
    case simulatedCameraDenied

    /// 這台裝置能不能開掃描。
    @MainActor
    var isAvailable: Bool {
        switch self {
        case .simulated, .simulatedCameraDenied: return true
        case .camera:
            #if os(iOS)
            return DataScannerViewController.isSupported
            #else
            return false
            #endif
        }
    }
}

extension EnvironmentValues {
    /// 加入主機頁配對碼掃描的來源。
    @Entry public var pairingCodeScanSource: PairingCodeScanSource = .camera
}

/// 全螢幕掃描配對 QR code(VisionKit 資料掃描器，只認 QR code):對準框、手電筒、取消、改手動輸入。
///
/// `onScan` 回 `true` 表示採用(是配對連結),這時震動回饋並關閉;否則繼續掃。
struct PairingCodeScannerView: View {
    let source: PairingCodeScanSource
    let onScan: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var permission: CameraPermission = .checking
    @State private var torchOn = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Scan Pairing QR Code")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .accessibilityIdentifier("scanner.cancel")
                    }
                }
        }
        .task { permission = await CameraPermission.current(for: source) }
    }

    @ViewBuilder
    private var content: some View {
        switch permission {
        case .checking:
            ProgressView()
        case .denied:
            deniedView
        case .granted:
            VStack(spacing: 0) {
                viewfinder
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("Point the camera at the QR code shown by purrdr-host-service pair.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .padding()
                HStack(spacing: 16) {
                    if hasTorch {
                        Button {
                            torchOn.toggle()
                            setTorch(torchOn)
                        } label: {
                            if torchOn {
                                Label("Turn Off Flashlight", systemImage: "flashlight.on.fill")
                            } else {
                                Label("Turn On Flashlight", systemImage: "flashlight.off.fill")
                            }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("scanner.torch")
                    }
                    Button("Enter Manually") { dismiss() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("scanner.manual")
                }
                .padding(.bottom)
            }
            .onDisappear { setTorch(false) }
        }
    }

    private var deniedView: some View {
        ContentUnavailableView {
            Label("Camera Access Is Off", systemImage: "camera.fill")
        } description: {
            Text("Allow camera access for Purrdr in Settings to scan the pairing QR code, or enter the address and pairing code yourself.")
        } actions: {
            #if os(iOS)
            if let settings = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: settings)
            }
            #endif
            Button("Enter Manually") { dismiss() }
                .accessibilityIdentifier("scanner.manual")
        }
        .accessibilityIdentifier("scanner.denied")
    }

    @ViewBuilder
    private var viewfinder: some View {
        switch source {
        case .simulated(let payload):
            Color.black
                .overlay { RoundedRectangle(cornerRadius: 28).stroke(.white, lineWidth: 4).frame(width: 230, height: 230) }
                .accessibilityIdentifier("scanner.viewfinder")
                .task {
                    try? await Task.sleep(for: .milliseconds(500))
                    deliver(payload)
                }
        case .camera:
            #if os(iOS)
            DataScannerRepresentable { deliver($0) }
                .ignoresSafeArea(edges: .horizontal)
                .accessibilityIdentifier("scanner.viewfinder")
            #else
            EmptyView()
            #endif
        case .simulatedCameraDenied:
            EmptyView()
        }
    }

    /// 是配對連結才採用：震動回饋後關閉。
    private func deliver(_ payload: String) {
        guard onScan(payload) else { return }
        #if os(iOS)
        SystemHaptics().play(.success)
        #endif
        dismiss()
    }

    private var hasTorch: Bool {
        #if os(iOS)
        guard source == .camera else { return false }
        return AVCaptureDevice.default(for: .video)?.hasTorch == true
        #else
        return false
        #endif
    }

    private func setTorch(_ on: Bool) {
        #if os(iOS)
        guard source == .camera, let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
        #endif
    }
}

/// 相機權限。
enum CameraPermission: Equatable {
    case checking
    case granted
    case denied

    /// 還沒問過時請求權限。
    @MainActor
    static func current(for source: PairingCodeScanSource) async -> CameraPermission {
        switch source {
        case .simulated: return .granted
        case .simulatedCameraDenied: return .denied
        case .camera:
            #if os(iOS)
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return .granted
            case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
            default: return .denied
            }
            #else
            return .denied
            #endif
        }
    }
}

#if os(iOS)
/// VisionKit 資料掃描器(只認 QR code)。以 `recognizedItems` 串流讀結果，不實作 delegate。
private struct DataScannerRepresentable: UIViewControllerRepresentable {
    let onPayload: @MainActor (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        context.coordinator.start(scanner, onPayload: onPayload)
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        coordinator.stop(scanner)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var reading: Task<Void, Never>?

        func start(_ scanner: DataScannerViewController, onPayload: @escaping @MainActor (String) -> Void) {
            try? scanner.startScanning()
            reading = Task { @MainActor in
                for await items in scanner.recognizedItems {
                    for item in items {
                        if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue { onPayload(payload) }
                    }
                }
            }
        }

        func stop(_ scanner: DataScannerViewController) {
            reading?.cancel()
            scanner.stopScanning()
        }
    }
}
#endif
