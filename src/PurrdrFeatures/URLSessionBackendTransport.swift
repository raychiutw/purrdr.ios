import Foundation
import PurrdrCore

/// iOS 對 Purrdr 後台的 HTTP 傳輸。
public struct URLSessionBackendTransport: BackendTransport {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func send(_ request: BackendRequest) async throws -> BackendResponse {
        var url = baseURL.appending(path: request.path)
        if !request.query.isEmpty { url.append(queryItems: request.query) }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = 30
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = request.accessToken {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw BackendError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw BackendError.invalidResponse }
        return BackendResponse(status: http.statusCode, body: data)
    }
}
