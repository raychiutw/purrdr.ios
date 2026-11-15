import CoreImage
import CoreImage.CIFilterBuiltins
import PurrdrCore
import SwiftUI

/// 分享主機(QR code 與分享連結)。內容只有連線設定與 host key 指紋，永不含密碼或私鑰(`HostShareLink`)。
///
/// 另一支裝置用系統相機掃 QR code 或點連結就會開啟 Purrdr 並帶入新增主機表單，仍要通過連線測試才能儲存。
struct HostShareView: View {
    let name: String
    let link: URL

    var body: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    if let image = QRCodeImage.make(for: link.absoluteString) {
                        Image(decorative: image, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 260)
                            .padding(12)
                            // QR code 要黑白、留白邊才掃得到;深色模式也維持白底。
                            .background(.white, in: .rect(cornerRadius: 12))
                            .accessibilityElement()
                            .accessibilityLabel(Text("QR code for \(name)"))
                            .accessibilityIdentifier("hostShare.qr")
                    }
                    Text("Scan this with the Camera on another iPhone or iPad to add \(name) to Purrdr there.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } footer: {
                Text("Includes the address, user name, herdr settings, and host key fingerprint. Passwords and private keys are never shared.")
            }
            Section {
                ShareLink(item: link, subject: Text(name)) {
                    Label("Share Link", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("hostShare.link")
            }
        }
        .navigationTitle("Share Host")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// 以 Core Image 產生 QR code(不需要網路或第三方套件)。
public enum QRCodeImage {
    public static func make(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // 每個模組放大成 8×8 像素，縮放時不糊。
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
