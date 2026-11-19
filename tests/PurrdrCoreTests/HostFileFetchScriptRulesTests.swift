import Foundation
import PurrdrCore
import Testing

#if os(macOS) || os(Linux)

/// SSH 的 POSIX 取檔腳本自己的存取規則(主機端判斷):以真的 `/bin/sh` 跑 `HostFileFetchScript`,不經 SSH。
/// 共用案例 `vendor/purrdr-host/protocol/host-file-access.json` 只看路徑(檔案不存在：放行時回 `missing`,不放行回 `denied`)。
@Suite("主機取檔腳本的存取規則(POSIX)", .serialized)
struct HostFileFetchScriptRulesTests {
    /// 直接執行取檔腳本，一次送出所有請求，收齊回應。
    static func replies(to requests: [Data], environment: [String: String]) throws -> [HostFileFetchScript.Reply] {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", HostFileFetchScript.follow(idleSeconds: 30, totalSeconds: 60)]
        process.environment = environment.merging(["PATH": "/usr/bin:/bin"]) { current, _ in current }
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        let errors = Pipe()
        process.standardError = errors
        // 腳本提早結束時寫入 stdin 會收到 SIGPIPE;改成寫入失敗，由下面的回應數量與 stderr 說明。
        signal(SIGPIPE, SIG_IGN)
        try process.run()
        try? input.fileHandleForWriting.write(contentsOf: requests.reduce(Data(), +))
        try? input.fileHandleForWriting.close()
        var buffer = output.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        var replies: [HostFileFetchScript.Reply] = []
        while let reply = try HostFileFetchScript.takeReply(from: &buffer) { replies.append(reply) }
        if replies.count < requests.count { Issue.record("腳本提早結束(exit \(process.terminationStatus)):\(errorText.suffix(400))") }
        return replies
    }

    @Test("共用案例：工作目錄是家目錄或它的上層、/ 時拒絕;只因提到而放行的只有暫存、上傳與附檔資料夾;排除清單")
    func sharedCases() throws {
        let vectors = try #require(HostFileAccessSharedCasesTests.vectors)
        let environment = try #require(vectors.environment["posix"])
        let cases = vectors.accessCases.filter { $0.platform == "posix" && ($0.only?.contains("posix") ?? true) }
        #expect(cases.count >= 20)
        let requests = cases.map { HostFileFetchScript.statusRequest(HostFileTarget(path: $0.path, root: $0.root)) }

        let replies = try Self.replies(to: requests, environment: ["HOME": environment.home, "TMPDIR": "/tmp"])

        #expect(replies.count == cases.count)
        for (testCase, reply) in zip(cases, replies) {
            let isDenied = reply == .status(.denied)
            #expect(isDenied == (testCase.expected == "denied"), "\(testCase.name):\(reply)")
        }
    }

    @Test("檢查與開檔之間把資料夾換成指向工作目錄外的 symlink:一律讀不到外面的內容")
    func swappedFolderIsNeverServed() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "purrdr-fetch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appending(path: "home")
        let ledger = home.appending(path: "ledger")
        let folder = ledger.appending(path: "folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: folder.appending(path: "notes.txt"))
        try Data("SECRET".utf8).write(to: home.appending(path: "notes.txt"))
        let target = HostFileTarget(path: folder.appending(path: "notes.txt").path(percentEncoded: false), root: ledger.path(percentEncoded: false))
        let environment = ["HOME": home.path(percentEncoded: false)]
        guard case .status(.file(let insideVersion, _)) = try Self.replies(to: [HostFileFetchScript.statusRequest(target)], environment: environment).first
        else {
            Issue.record("沒有狀態")
            return
        }
        // 攻擊者知道外面那個檔案的版本(cksum),版本比對擋不住，只能靠開檔後的核對。
        let outsideVersion = try Self.checksum(of: home.appending(path: "notes.txt"))

        let swapping = FolderSwapper(folder: folder, outside: home)
        swapping.start()
        let reads = (0..<200).flatMap { _ in
            [insideVersion, outsideVersion].map { HostFileFetchScript.readRequest(target, version: $0, offset: 0, length: 100) }
        }
        let replies = try Self.replies(to: reads, environment: environment)
        swapping.stop()

        let served = replies.compactMap { reply -> String? in
            guard case .chunk(_, let data) = reply else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        #expect(!served.isEmpty, "一次都沒讀到：\(Set(replies.map { String(describing: $0).prefix(40) }))")
        #expect(served.allSatisfy { $0 == "inside" }, "讀到工作目錄以外的內容：\(served.filter { $0 != "inside" }.count) 次")
    }

    /// 與取檔腳本相同算法的版本(`cksum` 的「CRC:大小」)。
    static func checksum(of file: URL) throws -> HostFileVersion {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", #"set -- $(cksum < "$1"); printf '%s:%s' "$1" "$2""#, "checksum", file.path(percentEncoded: false)]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return HostFileVersion(checksum: text)
    }

    /// 另一個執行緒反覆把資料夾換成指向 `outside` 的 symlink 再換回來。
    final class FolderSwapper: @unchecked Sendable {
        let folder: URL
        let outside: URL
        private let lock = NSLock()
        private var isRunning = true
        private var thread: Thread?

        init(folder: URL, outside: URL) {
            self.folder = folder
            self.outside = outside
        }

        func start() {
            let parked = folder.deletingLastPathComponent().appending(path: "folder-real")
            let thread = Thread { [self] in
                let files = FileManager.default
                while lock.withLock({ isRunning }) {
                    try? files.moveItem(at: folder, to: parked)
                    try? files.createSymbolicLink(at: folder, withDestinationURL: outside)
                    usleep(2_000)
                    try? files.removeItem(at: folder)
                    try? files.moveItem(at: parked, to: folder)
                    usleep(2_000)
                }
            }
            self.thread = thread
            thread.start()
        }

        func stop() {
            lock.withLock { isRunning = false }
            while thread?.isFinished == false { usleep(1_000) }
        }
    }
}

#endif
