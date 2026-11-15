import CryptoKit
import Foundation
import PurrdrCore

/// Google 登入：OAuth 2.0 authorization code + PKCE(原生 app 流程，不需要 client secret,也不需要 Google 的 SDK)。
///
/// 系統瀏覽器(`ASWebAuthenticationSession`)由畫面以 `Browser` 提供;這裡負責組授權網址、檢查回呼、
/// 向 Google 換 ID token。拿到的 ID token 交給 Purrdr 後台驗證。
/// https://developers.google.com/identity/protocols/oauth2/native-app
public struct GoogleSignIn: Sendable {
    public struct Configuration: Sendable {
        /// iOS 類型的 OAuth client ID(`<數字>-<字串>.apps.googleusercontent.com`)。
        public var clientID: String
        public var authorizationEndpoint: URL
        public var tokenEndpoint: URL

        public init(
            clientID: String,
            authorizationEndpoint: URL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL = URL(string: "https://oauth2.googleapis.com/token")!
        ) {
            self.clientID = clientID
            self.authorizationEndpoint = authorizationEndpoint
            self.tokenEndpoint = tokenEndpoint
        }

        /// iOS client 的 redirect URI 用反轉的 client ID 當 scheme。
        public var callbackScheme: String {
            "com.googleusercontent.apps." + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        }

        var redirectURI: String { "\(callbackScheme):/oauthredirect" }
    }

    /// 以系統瀏覽器打開授權網址，回傳 Google 導回 app 的網址。使用者取消時丟 `GoogleSignInError.canceled`。
    public typealias Browser = @MainActor (_ url: URL, _ callbackScheme: String) async throws -> URL

    private let configuration: Configuration
    private let session: URLSession

    public init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    /// 走一次 Google 登入，回傳要交給後台的憑證。
    public func credential(browser: Browser) async throws -> SignInCredential {
        let nonce = Self.randomString()
        let state = Self.randomString()
        let verifier = Self.randomString()
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

        var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        let callback = try await browser(components.url!, configuration.callbackScheme)

        let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        if value("error") == "access_denied" { throw GoogleSignInError.canceled }
        guard value("state") == state, let code = value("code") else { throw GoogleSignInError.failed }

        let idToken = try await exchange(code: code, verifier: verifier)
        return SignInCredential(method: .google, idToken: idToken, nonce: nonce)
    }

    private func exchange(code: String, verifier: String) async throws -> String {
        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: verifier),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
        ]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BackendError.unreachable
        }
        struct TokenResponse: Decodable {
            var id_token: String
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw GoogleSignInError.failed
        }
        return token.id_token
    }

    /// 32 bytes 隨機值的 base64url。
    static func randomString() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum GoogleSignInError: Error, Equatable {
    /// 使用者取消，不需要顯示錯誤。
    case canceled
    /// Google 回應不對(state 不符、沒有 code、換 token 失敗)。
    case failed
}
