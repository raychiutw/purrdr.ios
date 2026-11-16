import Foundation
import Synchronization

/// Seam 2 的 app 端:用 `URLProtocol` 攔截 `URLSession` 送出的請求(與 my-money.ios 的 `HTTPStub` 同法)。
///
/// ```swift
/// let backend = HTTPStub()
/// backend.on("POST", "/v1/sessions", .json(200, #"{"accessToken": "…"}"#))
/// // 用 backend.urlSession、backend.baseURL 建立要測的程式
/// #expect(backend.requests(to: "/v1/sessions").first?.json?["provider"] as? String == "apple")
/// ```
///
/// 每個 stub 有自己的 host,Swift Testing 平行跑測試時不會互相干擾。沒登記的請求以網路錯誤失敗，並記在 `unexpectedRequests`。
public final class HTTPStub: Sendable {
    public struct Reply: Sendable {
        public var status: Int
        public var body: Data
        public var headers: [String: String]
        /// `true` 時不回 HTTP 回應，而是網路錯誤(連不上)。
        public var networkError: Bool

        public static func json(_ status: Int, _ body: String) -> Reply {
            Reply(status: status, body: Data(body.utf8), headers: ["Content-Type": "application/json"], networkError: false)
        }

        public static func empty(_ status: Int) -> Reply {
            Reply(status: status, body: Data(), headers: [:], networkError: false)
        }

        public static let unreachable = Reply(status: 0, body: Data(), headers: [:], networkError: true)
    }

    /// app 送出的一個請求。
    public struct Request: Sendable {
        public var method: String
        public var path: String
        public var headers: [String: String]
        public var body: Data

        /// body 當成 JSON 物件。
        public var json: [String: Any]? {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        }

        /// body 當成 `application/x-www-form-urlencoded`。
        public var form: [String: String] {
            var components = URLComponents()
            components.percentEncodedQuery = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "+", with: "%20")
            return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { _, last in last }
        }

        /// `Authorization` 標頭。
        public var authorization: String? {
            headers.first { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame }?.value
        }
    }

    public let baseURL: URL
    public let urlSession: URLSession
    private let state = Mutex<(routes: [String: [Reply]], requests: [Request], unexpected: [Request])>(([:], [], []))

    public init() {
        baseURL = URL(string: "https://\(UUID().uuidString.lowercased()).stub.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        urlSession = URLSession(configuration: configuration)
        StubURLProtocol.register(self, host: baseURL.host()!)
    }

    /// 這個方法與路徑的請求依序得到這些回應，用完之後一直回最後一個。
    public func on(_ method: String, _ path: String, _ replies: Reply...) {
        state.withLock { $0.routes["\(method) \(path)"] = replies }
    }

    /// 到目前為止收到的請求。
    public var requests: [Request] {
        state.withLock { $0.requests }
    }

    /// 某個路徑收到的請求。
    public func requests(to path: String) -> [Request] {
        requests.filter { $0.path == path }
    }

    /// 沒有登記回應的請求。
    public var unexpectedRequests: [Request] {
        state.withLock { $0.unexpected }
    }

    fileprivate func handle(_ request: Request) -> Reply? {
        state.withLock { state in
            state.requests.append(request)
            let key = "\(request.method) \(request.path)"
            guard var queue = state.routes[key], let first = queue.first else {
                state.unexpected.append(request)
                return nil
            }
            if queue.count > 1 {
                queue.removeFirst()
                state.routes[key] = queue
            }
            return first
        }
    }
}

private final class StubURLProtocol: URLProtocol {
    private static let stubs = Mutex<[String: HTTPStub]>([:])

    static func register(_ stub: HTTPStub, host: String) {
        stubs.withLock { $0[host] = stub }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let host = request.url?.host() ?? ""
        let received = HTTPStub.Request(
            method: request.httpMethod ?? "GET",
            path: request.url?.path() ?? "",
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.readBody(of: request) ?? Data()
        )
        guard
            let stub = Self.stubs.withLock({ $0[host] }),
            let reply = stub.handle(received),
            !reply.networkError,
            let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/2", headerFields: reply.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession 交給 URLProtocol 時會把 body 換成 stream,這裡讀回來方便測試比對。
    private static func readBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
