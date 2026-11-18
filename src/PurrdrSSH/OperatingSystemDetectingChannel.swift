import Foundation
import PurrdrCore

/// 作業系統未知的主機(例如主機同步帶來的新主機，同步內容不含作業系統)的主機通道(#26)。
///
/// 第一個指令前先偵測作業系統(`HostOperatingSystem.detect(on:)`),Windows 換成 `WindowsHostChannel`,
/// 其他原樣;偵測完成前不送出任何呼叫端的 POSIX 指令。偵測結果交給 `onDetected`(存回主機設定，下次不必再偵測)。
/// 偵測失敗(連不上等)不記住，下一個指令再試一次。登入 Shell(PTY 不帶指令)不必知道作業系統，直接開。
public actor OperatingSystemDetectingChannel: HostChannel {
    private let base: any HostChannel
    private let onDetected: @Sendable (HostOperatingSystem) async -> Void
    private var resolved: (any HostChannel)?
    private var detecting: Task<any HostChannel, any Error>?

    public init(_ base: any HostChannel, onDetected: @escaping @Sendable (HostOperatingSystem) async -> Void) {
        self.base = base
        self.onDetected = onDetected
    }

    public func execute(_ command: String) async throws -> any ExecSession {
        try await channel().execute(command)
    }

    public func openPTY(_ request: PTYRequest) async throws -> any PTYSession {
        guard request.command != nil else { return try await base.openPTY(request) }
        return try await channel().openPTY(request)
    }

    public func disconnect() async {
        await base.disconnect()
    }

    public func beginQuickDisconnectDetection() async {
        await base.beginQuickDisconnectDetection()
    }

    public func endQuickDisconnectDetection() async {
        await base.endQuickDisconnectDetection()
    }

    /// 偵測過就用結果;同時有好幾個指令時只偵測一次。
    private func channel() async throws -> any HostChannel {
        if let resolved { return resolved }
        let task = detecting ?? Task { [base, onDetected] in
            let operatingSystem = try await HostOperatingSystem.detect(on: base)
            await onDetected(operatingSystem)
            return operatingSystem.channel(base)
        }
        detecting = task
        do {
            let channel = try await task.value
            resolved = channel
            return channel
        } catch {
            detecting = nil
            throw error
        }
    }
}
