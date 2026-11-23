import Foundation
import PurrdrCore

/// iOS 取公開模型目錄(#385):短逾時的 GET,失敗就丟錯(解析器退到內建對照表)。只讀取、不帶任何識別資訊。
public struct URLSessionPublicModelCatalog: PublicModelCatalogFetching {
    private let session: URLSession
    private let url: URL

    public init(session: URLSession = .shared, url: URL = PublicModelCatalog.url) {
        self.session = session
        self.url = url
    }

    public func fetch() async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 2_000_000 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
