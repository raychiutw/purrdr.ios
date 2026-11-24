import PurrdrCore

/// 進背景放開 Pane 終端機控制時，最多等多久(#498)。
///
/// App 進背景時以 background task 等 `released()` 把 release 送完;送不出去(網路卡住)時不能撐到系統給的
/// 約 30 秒到期，期間主執行緒與週期性工作還在跑，這時使用者滑掉 app 就是「背景中被要求結束」的看門狗情境。
/// 超過 `limit` 就放棄等待、還回 background task。
public enum BackgroundReleaseWait {
    public static let limit: Duration = .seconds(3)

    @MainActor
    public static func wait(
        for released: @escaping @MainActor () async -> Void, limit: Duration = BackgroundReleaseWait.limit,
        sleep: @escaping Sleep = Sleeping.task
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var isDone = false
            func finish() {
                guard !isDone else { return }
                isDone = true
                continuation.resume()
            }
            Task { @MainActor in
                await released()
                finish()
            }
            Task { @MainActor in
                try? await sleep(limit)
                finish()
            }
        }
    }
}
