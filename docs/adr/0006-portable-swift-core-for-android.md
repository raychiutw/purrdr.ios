# 核心邏輯做成可在 Android 編譯的 Swift package

之後會有 Android 版。為了不像 herdrchat 當初那樣「同一個功能寫兩次」,又要維持原生 UI,我們把協定、對話紀錄解析、slash 清單整理等核心邏輯放進一個不依賴 Apple 專屬 framework 的 Swift package(只用 Foundation、swift-nio、swift-nio-ssh、swift-crypto),Apple 專屬的部分(SwiftData、Security／Keychain、Secure Enclave、StoreKit、UI)隔離在 app 層。Android 版用官方 Swift SDK for Android(Swift 6.3 起正式釋出)編譯核心，UI 另用 Compose 寫。

可行性已實測：依賴 swift-nio-ssh 0.15.1、swift-nio、swift-crypto 的 package 可用 Swift 6.4.2 + NDK r30 交叉編譯到 aarch64／x86_64／armv7,零 warning、不需 patch(只驗證到編得過，見 `docs/research/swift-sdk-for-android.md`)。

## Consequences

- 上游的 swift-nio-ssh 與 swift-crypto 沒有 Android CI,我們要自己建 Android 編譯(之後加模擬器測試)的 CI,把可攜性守住。
- Kotlin 互通要用 swift-java(0.x,API 不穩)的 JNI 模式。
- 帶入完整 Foundation 與 ICU,Android 的 .so 約 58 MB(strip 後)。
- 最低 Android API 以 28 規劃。

後來加入 HTTPS 連線方式(ADR-0010):核心另需 WSS 的 TLS 相依(例如 swift-nio-ssl),以及由 JSON Schema 產生的協定型別;同樣要在 Android 交叉編譯驗證。

實作時(#57)WSS 改用 Foundation 的 `URLSessionWebSocketTask`(非 Apple 平台經 FoundationNetworking／libcurl),放在可攜的 `PurrdrHTTPS`,傳輸以 protocol 注入：不需要 swift-nio-ssl,也不帶入第三方加密(出口合規維持只用系統加密)。Android 在執行期的 WebSocket 與 CA 憑證路徑還沒實測，只驗證到編得過。
