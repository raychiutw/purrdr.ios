import PurrdrCore
import Testing

/// 把片段接成一個字串(陣列字面值裡用 `+` 相接，型別推斷會太慢)。
private func j(_ parts: String...) -> String { parts.joined() }

/// 機密偵測的規則(#302):每種類別的正例與反例。
/// 測試用的假密鑰以字串相接組成，原始碼裡不出現完整的 token 字面值(避免被 secret scanning 當成真的)。
@Suite("機密偵測的規則")
struct SecretDetectionTests {
    static func kinds(_ text: String) -> [SecretKind] {
        SecretDetection.scan(text).map(\.kind)
    }

    // MARK: - Private key

    @Test("private key:各種 PEM 開頭都算", arguments: [
        j("-----BEGIN ", "RSA PRIVATE KEY-----"),
        j("-----BEGIN ", "OPENSSH PRIVATE KEY-----"),
        j("-----BEGIN ", "EC PRIVATE KEY-----"),
        j("-----BEGIN ", "PRIVATE KEY-----"),
        j("-----BEGIN ", "ENCRYPTED PRIVATE KEY-----"),
        j("-----BEGIN ", "PGP PRIVATE KEY BLOCK-----"),
    ])
    func privateKeyDetected(_ header: String) {
        #expect(Self.kinds("金鑰如下\n\(header)\nMIIEpAIBAAKCAQEA\n") == [.privateKey])
    }

    @Test("private key:公鑰、憑證與口語不算", arguments: [
        "-----BEGIN PUBLIC KEY-----",
        "-----BEGIN CERTIFICATE-----",
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl ray@mac",
        "請幫我產生一把 private key",
    ])
    func privateKeyNotDetected(_ text: String) {
        #expect(Self.kinds(text).isEmpty)
    }

    // MARK: - GitHub token

    @Test("GitHub token:ghp_／gho_／ghs_ 等前綴加 36 字以上，與 github_pat_", arguments: [
        j("gh", "p_", "8fK2mQ9xL4vB7nR1tY6uW3zA5cD0eH2jG8sP"),
        j("token: gh", "o_", "abcdefghijklmnopqrstuvwxyzABCDEFGH1234"),
        j("gh", "s_", "16C7e42F292c6912E7710c838347Ae178B4a"),
        j("github", "_pat_", "11ABCDEFG0123456789abcdefghijklmnopqrstuvwxyz"),
    ])
    func gitHubTokenDetected(_ text: String) {
        #expect(Self.kinds(text) == [.gitHubToken])
    }

    @Test("GitHub token:太短或只是提到前綴不算", arguments: [
        j("gh", "p_", "short123"),
        "設定 ghp_ 開頭的 token",
        "github_pat_ 是 fine-grained token 的前綴",
    ])
    func gitHubTokenNotDetected(_ text: String) {
        #expect(Self.kinds(text).isEmpty)
    }

    // MARK: - sk- 金鑰

    @Test("sk- 金鑰:OpenAI、Anthropic、Stripe 形式", arguments: [
        j("OPENAI_API_KEY: ", "sk", "-proj-", "Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4z"),
        j("sk", "-ant-api03-", "Zx9Yw8Vu7Ts6Rq5Po4Nm3Lk2Ji1Hg0Fe"),
        j("sk", "-", "4f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c"),
        j("sk", "_live_", "51HqLyjWDarjtT1zdp7dc2a3b4c5d6e7"),
        j("rk", "_live_", "51HqLyjWDarjtT1zdp7dc2a3b4c5d6e7"),
        j("STRIPE_KEY=", "rk", "_test_", "51HqLyjWDarjtT1zdp7dc2a3b4c5d6e7"),
    ])
    func skKeyDetected(_ text: String) {
        #expect(Self.kinds(text) == [.skKey])
    }

    @Test("sk- 金鑰:套件名、短字與沒有數字的字詞不算", arguments: [
        "pip install scikit-learn sk-video",
        "sk-1234",
        "sk-this-is-not-really-a-key-at-all",
        "desk-0123456789abcdefghijklmnop",
        "rk_live_ 是 Stripe restricted key 的前綴",
        "rk_live_1234",
        "work_live_0123456789abcdefghijklmnop",
    ])
    func skKeyNotDetected(_ text: String) {
        #expect(Self.kinds(text).isEmpty)
    }

    // MARK: - AWS

    @Test("AWS:access key id 與 secret access key", arguments: [
        j("AK", "IA", "IOSFODNN7EXAMPLE"),
        j("AS", "IA", "ZX3Q7RL2M5N8P0K4"),
        j("aws_secret_access_key = ", "wJalrXUtnFEMI/K7MDENG/bPxRfiCY", "EXAMPLEKEY"),
    ])
    func awsKeyDetected(_ text: String) {
        #expect(Self.kinds(text) == [.awsKey])
    }

    @Test("AWS:長度不對或小寫不算", arguments: [
        "AKIA1234",
        "akiaiosfodnn7example",
        j("AK", "IA", "IOSFODNN7EXAMPLEEXTRA"),
        "aws_secret_access_key = <your secret>",
    ])
    func awsKeyNotDetected(_ text: String) {
        #expect(Self.kinds(text).isEmpty)
    }

    // MARK: - Slack

    @Test("Slack:xoxb／xoxp token 與 incoming webhook", arguments: [
        j("xo", "xb-", "2233445566-7788990011-AbCdEfGhIjKlMnOpQrStUvWx"),
        j("xo", "xp-", "1234567890-0987654321-1122334455-abcdef0123456789"),
        j("https://hooks.slack.com/services/", "T01ABCDEF/B02GHIJKL/", "aBcDeFgHiJkLmNoPqRsTuVwX"),
    ])
    func slackTokenDetected(_ text: String) {
        #expect(Self.kinds(text) == [.slackToken])
    }

    @Test("Slack:太短或只有文件網址不算", arguments: [
        "xoxb-123",
        "請看 https://api.slack.com/authentication/token-types",
    ])
    func slackTokenNotDetected(_ text: String) {
        #expect(Self.kinds(text).isEmpty)
    }

    // MARK: - Google API key

    @Test("Google API key:AIza 加 35 字")
    func googleAPIKeyDetected() {
        #expect(Self.kinds("key: " + "AI" + "za" + "SyDdI0hCZtE6vySjMm-WEfRq3CPzqKqqsHI") == [.googleAPIKey])
    }

    @Test("Google API key:長度不對不算", arguments: [
        "AIzaShort",
        j("AI", "za", "SyDdI0hCZtE6vySjMm-WEfRq3CPzqKqqsHIextra"),
    ])
    func googleAPIKeyNotDetected(_ text: String) {
        #expect(Self.kinds(text).isEmpty)
    }

    // MARK: - JWT

    @Test("JWT:三段 base64url、前兩段是 eyJ 開頭")
    func jwtDetected() {
        let token = "ey" + "JhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" + ".ey" + "JzdWIiOiIxMjM0NTY3ODkwIn0"
            + ".SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        #expect(Self.kinds("Authorization: Bearer \(token)") == [.jwt])
    }

    @Test("JWT:只有兩段或不是 eyJ 開頭不算", arguments: [
        j("ey", "JhbGciOiJIUzI1NiJ9", ".ey", "JzdWIiOiIxMjM0In0"),
        "version.1.2.3.4.5",
        "abcdefghijkl.mnopqrstuvwx.yzABCDEFGHIJ",
    ])
    func jwtNotDetected(_ text: String) {
        #expect(Self.kinds(text).isEmpty)
    }

    // MARK: - password=

    @Test("password=:指定值的寫法", arguments: [
        "DB_PASSWORD=hunter2024",
        "mysql -u root password=S3cr3t!",
        "passwd = 'correct-horse'",
        #"{"password": "p@ssw0rd!"}"#,
        "pwd=Tr0ub4dor",
    ])
    func passwordDetected(_ text: String) {
        #expect(Self.kinds(text) == [.password])
    }

    @Test("password=:沒有值、佔位符、變數與口語不算", arguments: [
        "password=",
        "password=$DB_PASSWORD",
        "password=${PASSWORD}",
        "password=<your password>",
        "password=****",
        "forgot password? reset it",
        "password: please reset it",
        "if password == expected",
    ])
    func passwordNotDetected(_ text: String) {
        #expect(Self.kinds(text).isEmpty)
    }

    // MARK: - 行號與多種

    @Test("一則訊息有多種：依行號列出，同一行同一類只算一次")
    func multipleFindingsWithLines() {
        let text = "部署失敗\ntoken 是 " + "gh" + "p_" + "8fK2mQ9xL4vB7nR1tY6uW3zA5cD0eH2jG8sP"
            + "\n\n\nDB_PASSWORD=hunter2024 password=again99"
        #expect(SecretDetection.scan(text) == [
            SecretFinding(kind: .gitHubToken, line: 2),
            SecretFinding(kind: .password, line: 5),
        ])
    }

    @Test("一般訊息沒有任何偵測結果")
    func ordinaryTextIsClean() {
        #expect(SecretDetection.scan("幫 CSV 匯出加上引號處理，然後跑 swift test").isEmpty)
    }
}
