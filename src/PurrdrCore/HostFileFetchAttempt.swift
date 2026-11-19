import Foundation

/// 主機取檔拿不到檔案的原因(縮圖載入與點開下載共用)。
public enum HostFileProblem: Sendable, Equatable {
    /// 超過上限(自動載入以外的上限：`HostFileFetchLimits.maximumSize`)。
    case tooLarge(size: Int)
    case missing
    case notRegularFile
    case unreadable
    /// app 端或主機端的存取規則不允許。
    case denied
    /// 這個連線方式或主機還不能取檔。
    case unsupported
    case cancelled
    case failed(String)

    /// 不是一般檔案的狀態;`.file` 回 `nil`。
    init?(status: HostFileStatus) {
        switch status {
        case .file: return nil
        case .missing: self = .missing
        case .notRegularFile: self = .notRegularFile
        case .unreadable: self = .unreadable
        case .denied: self = .denied
        case .tooLarge(let size): self = .tooLarge(size: size)
        }
    }
}

/// 載入與下載共用的流程：先過 app 端存取規則，查狀態，交給 `body` 依版本讀;
/// 分塊之間被覆寫(`HostFileFetchError.changed`)時重新查狀態再試一次。
enum HostFileFetchAttempt {
    /// `body` 拿到目標、目前版本與大小;丟出的錯誤轉成 `HostFileProblem`。
    static func run<Success>(
        _ path: String, scope: HostFileAccessScope, fetcher: any HostFileFetching, isolation: isolated (any Actor)? = #isolation,
        body: (HostFileTarget, HostFileVersion, Int) async throws -> Success
    ) async -> Result<Success, HostFileProblem> {
        guard case .allowed(let target) = HostFileAccessPolicy.decision(for: path, in: scope) else { return .failure(.denied) }
        for _ in 0..<2 {
            do {
                let status = try await fetcher.status(of: target)
                guard case .file(let version, let size) = status else { return .failure(HostFileProblem(status: status) ?? .failed("unexpected file status")) }
                return .success(try await body(target, version, size))
            } catch HostFileFetchError.changed {
                continue
            } catch HostFileFetchError.unavailable(let status) {
                return .failure(HostFileProblem(status: status) ?? .failed("unexpected file status"))
            } catch HostFileFetchError.unsupported {
                return .failure(.unsupported)
            } catch is CancellationError {
                return .failure(.cancelled)
            } catch let problem as HostFileProblem {
                return .failure(problem)
            } catch {
                return .failure(.failed(String(describing: error)))
            }
        }
        return .failure(.failed("host file kept changing"))
    }
}

extension HostFileProblem: Error {}
