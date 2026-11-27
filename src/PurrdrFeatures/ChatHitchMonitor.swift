import Foundation
import PurrdrAgentFeatures
import SwiftUI

extension EnvironmentValues {
    /// 捲動卡頓記錄器(app 的 composition root 注入;沒注入時聊天列表不記錄)。
    @Entry public var hitchRecorder: DiagnosticRecorder?
}

#if os(iOS)
import MetricKit
import UIKit

/// 一列自適應高度花的時間:只在記錄器運作時才計時(不運作時 `isActive` 是 false,cell 不碰時鐘)。
@MainActor
final class HitchFitTimer {
    var isActive = false
    private weak var recorder: DiagnosticRecorder?

    init(recorder: DiagnosticRecorder) { self.recorder = recorder }

    func record(startNanoseconds: UInt64) {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- startNanoseconds
        recorder?.note(.fit(milliseconds: Double(elapsed) / 1_000_000))
    }
}

/// 聊天列表的卡頓量測橋接:`CADisplayLink` 只在列表可見、app 在前景且記錄開著時存在;
/// 回呼裡只讀幾個數字交給記錄器累加,不做 I/O(寫檔由記錄器定時交給背景佇列)。
@MainActor
final class ChatHitchMonitor {
    let recorder: DiagnosticRecorder
    let fitTimer: HitchFitTimer
    private weak var scrollView: UIScrollView?
    private let visibleCells: () -> Int
    private var link: CADisplayLink?
    private var flushTask: Task<Void, Never>?
    private var previousOffset: (y: Double, timestamp: Double)?
    private var owner: ObjectIdentifier { ObjectIdentifier(self) }

    init(recorder: DiagnosticRecorder, scrollView: UIScrollView, visibleCells: @escaping () -> Int) {
        self.recorder = recorder
        self.scrollView = scrollView
        self.visibleCells = visibleCells
        fitTimer = HitchFitTimer(recorder: recorder)
        recorder.observeRunning(owner: owner) { [weak self] running in self?.setRunning(running) }
    }

    func appear() {
        updateDisplayInfo()
        recorder.setVisible(true, owner: owner)
    }

    func disappear() { recorder.setVisible(false, owner: owner) }

    func setSceneActive(_ active: Bool) { recorder.setSceneActive(active) }

    func teardown() {
        recorder.setVisible(false, owner: owner)
        recorder.removeRunningObserver(owner: owner)
        stopLink()
    }

    // MARK: - 回報

    func note(_ kind: HitchActivityKind) { recorder.note(kind) }

    private func updateDisplayInfo() {
        guard let scrollView else { return }
        let fps = scrollView.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
        let textSize = scrollView.traitCollection.preferredContentSizeCategory.rawValue
            .replacingOccurrences(of: "UICTContentSizeCategory", with: "")
        recorder.setDisplay(maxFramesPerSecond: fps, textSize: textSize)
    }

    // MARK: - CADisplayLink

    private func setRunning(_ running: Bool) {
        fitTimer.isActive = running
        if running { startLink() } else { stopLink() }
    }

    private func startLink() {
        guard link == nil else { return }
        updateDisplayInfo()
        previousOffset = nil
        let newLink = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick(_:)))
        newLink.add(to: .main, forMode: .common)
        link = newLink
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.recorder.flush()
            }
        }
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        flushTask?.cancel()
        flushTask = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        guard let scrollView else { return }
        let state: HitchScrollState = scrollView.isDragging ? .dragging : (scrollView.isDecelerating ? .decelerating : .idle)
        let offset = Double(scrollView.contentOffset.y)
        var velocity = 0.0
        if let previousOffset, link.timestamp > previousOffset.timestamp {
            velocity = (offset - previousOffset.y) / (link.timestamp - previousOffset.timestamp)
        }
        previousOffset = (offset, link.timestamp)
        recorder.frame(
            timestamp: link.timestamp, expectedInterval: link.targetTimestamp - link.timestamp, scroll: state,
            offsetY: offset, velocityY: velocity, visibleCells: visibleCells)
    }
}

/// `CADisplayLink` 對 target 是強參考:用弱參考的轉接,離開聊天時才不會留著監控物件。
@MainActor
private final class DisplayLinkTarget: NSObject {
    private weak var monitor: ChatHitchMonitor?

    init(_ monitor: ChatHitchMonitor) { self.monitor = monitor }

    @objc func tick(_ link: CADisplayLink) {
        monitor?.tick(link)
    }
}

// MARK: - 系統狀態

extension HitchSystemState {
    /// 目前的系統狀態(畫面更新率上限與字級由記錄器補上)。
    @MainActor
    public static func current() -> HitchSystemState {
        let info = ProcessInfo.processInfo
        let thermal: String
        switch info.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        let environment = DiagnosticEnvironment.current
        return HitchSystemState(
            thermal: thermal, lowPower: info.isLowPowerModeEnabled,
            reduceTransparency: UIAccessibility.isReduceTransparencyEnabled, reduceMotion: UIAccessibility.isReduceMotionEnabled,
            device: environment.device, os: environment.os, app: environment.app, textSize: "", maxFramesPerSecond: 0)
    }
}

extension DiagnosticEnvironment {
    /// 這支裝置、這個 app 目前的版本與機型。
    public static var current: DiagnosticEnvironment {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let info = Bundle.main.infoDictionary ?? [:]
        return DiagnosticEnvironment(
            app: "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))",
            os: "iOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)", device: deviceIdentifier)
    }

    /// 機型代碼(模擬器用它模擬的機型),不是裝置名稱。
    private static var deviceIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
    }
}

// MARK: - MetricKit

/// 訂閱 MetricKit 的每日 payload,把 `scrollHitchTimeRatio` 與當機掛起(hang)診斷的摘要寫進同一份記錄(只有數字)。
public final class HitchMetricKitSubscriber: NSObject, MXMetricManagerSubscriber {
    private let recorder: DiagnosticRecorder
    private let crashIntake: MetricKitCrashIntake
    private let hangIntake: MetricKitHangIntake

    @MainActor
    public init(recorder: DiagnosticRecorder) {
        self.recorder = recorder
        crashIntake = MetricKitCrashIntake(recorder: recorder)
        hangIntake = MetricKitHangIntake(recorder: recorder)
        super.init()
    }

    @MainActor
    public func start() { MXMetricManager.shared.add(self) }

    public func didReceive(_ payloads: [MXMetricPayload]) {
        let digests = payloads.map { payload in
            // 卡頓次數與最長秒數取自指標的卡頓時間直方圖(沒有時是 0,真的沒卡頓)。
            let buckets = payload.applicationResponsivenessMetrics.map { metrics -> [(start: Double, end: Double, count: Int)] in
                var result: [(start: Double, end: Double, count: Int)] = []
                for bucket in metrics.histogrammedApplicationHangTime.bucketEnumerator {
                    guard let bucket = bucket as? MXHistogramBucket<UnitDuration> else { continue }
                    result.append((
                        bucket.bucketStart.converted(to: .seconds).value, bucket.bucketEnd.converted(to: .seconds).value, bucket.bucketCount))
                }
                return result
            } ?? []
            let hangs = HangHistogramSummary(buckets: buckets)
            return HitchMetricsDigest(
                periodStart: payload.timeStampBegin, periodEnd: payload.timeStampEnd,
                scrollHitchTimeRatio: payload.animationMetrics?.scrollHitchTimeRatio.value, hangCount: hangs.count, longestHangSeconds: hangs.longestSeconds,
                app: payload.metaData?.applicationBuildVersion ?? "?", os: payload.metaData?.osVersion ?? "?")
        }
        deliver(digests)
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        // 閃退診斷:以報告的 JSON 表示轉成記錄(沒有閃退的 payload 轉出來是空的)。
        let crashJSON = payloads.filter { ($0.crashDiagnostics ?? []).isEmpty == false }.map { $0.jsonRepresentation() }
        if !crashJSON.isEmpty {
            Task { @MainActor [crashIntake] in
                for json in crashJSON { crashIntake.ingest(payloadJSON: json) }
            }
        }
        // 卡頓診斷:次數、最長秒數與主執行緒堆疊一律記錄(比照閃退,不看操作記錄開關)。
        let hangJSON = payloads.filter { ($0.hangDiagnostics ?? []).isEmpty == false }.map { $0.jsonRepresentation() }
        if !hangJSON.isEmpty {
            Task { @MainActor [hangIntake] in
                for json in hangJSON { hangIntake.ingest(payloadJSON: json) }
            }
        }
        let digests = payloads.compactMap { payload -> HitchMetricsDigest? in
            let hangs = payload.hangDiagnostics ?? []
            guard !hangs.isEmpty else { return nil }
            let longest = hangs.map { $0.hangDuration.converted(to: .seconds).value }.max() ?? 0
            return HitchMetricsDigest(
                periodStart: payload.timeStampBegin, periodEnd: payload.timeStampEnd, scrollHitchTimeRatio: nil,
                hangCount: hangs.count, longestHangSeconds: longest,
                app: hangs.first?.metaData.applicationBuildVersion ?? "?", os: hangs.first?.metaData.osVersion ?? "?")
        }
        deliver(digests)
    }

    private func deliver(_ digests: [HitchMetricsDigest]) {
        guard !digests.isEmpty else { return }
        Task { @MainActor [recorder] in
            for digest in digests { recorder.recordMetrics(digest) }
        }
    }
}
#endif
