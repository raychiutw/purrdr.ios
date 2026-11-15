#if os(macOS)
import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 可還原的主機寫入(ADR-0002):安裝會記下改過的使用者檔案原本的樣子，還原後主機與安裝前完全相同。
///
/// 用一個玩具功能測：在 `.toolrc` 末尾加一行，並在 `~/.purrdr/toy/` 放一支腳本。
@Suite("可還原的主機寫入")
struct ReversibleHostWriteTests {
    static let rc: HostPath = ".toolrc"
    let host: LocalShellHost
    let toy: ReversibleHostWrite

    init() throws {
        host = try LocalShellHost()
        toy = ReversibleHostWrite(channel: host, feature: HostWriteFeature(id: "toy", userFiles: [Self.rc]))
    }

    func write(_ text: String, to path: String, mode: Int = 0o644) throws {
        let url = host.url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    func contents(_ path: String) throws -> String {
        try String(contentsOf: host.url(path), encoding: .utf8)
    }

    /// 在原本的內容(沒有就是空的)末尾加一行。
    func installToy() async throws {
        try await toy.install { inspection in
            let current = inspection.read[Self.rc]?.contents ?? Data()
            return HostWritePlan(userFiles: [Self.rc: current + Data("source ~/.purrdr/toy/hook.sh\n".utf8)],
                                 ownFiles: ["hook.sh": .init(Data("echo hook\n".utf8), executable: true)])
        }
    }

    @Test("安裝後還原：整個家目錄與安裝前完全相同(內容、權限)")
    func restoreLeavesHomeExactlyAsBefore() async throws {
        try write("alias ll='ls -l'\n", to: ".toolrc", mode: 0o640)
        try write("unrelated", to: "notes.txt")
        let before = try DirectorySnapshot(of: host.home)

        try await installToy()
        #expect(try contents(".toolrc") == "alias ll='ls -l'\nsource ~/.purrdr/toy/hook.sh\n")
        #expect(FileManager.default.isExecutableFile(atPath: host.url(".purrdr/toy/hook.sh").path))
        #expect(try await toy.inspect().isInstalled)

        try await toy.restore { _, current, _ in current }

        let after = try DirectorySnapshot(of: host.home)
        #expect(after == before, "還原後不同:\n\(after)\n---\n\(before)")
        #expect(try await !toy.inspect().isInstalled)
    }

    @Test("安裝時才建立的檔案，還原時刪除")
    func restoreDeletesFileCreatedByInstall() async throws {
        let before = try DirectorySnapshot(of: host.home)

        try await installToy()
        #expect(try contents(".toolrc") == "source ~/.purrdr/toy/hook.sh\n")
        try await toy.restore { _, current, _ in current }

        #expect(try DirectorySnapshot(of: host.home) == before)
    }

    @Test("重複安裝：原本的內容永遠是第一次安裝前的樣子，不會把安裝後的內容存成原本的")
    func reinstallKeepsFirstOriginal() async throws {
        try write("original\n", to: ".toolrc")
        let before = try DirectorySnapshot(of: host.home)

        try await installToy()
        try await toy.install { inspection in
            #expect(inspection.original(of: Self.rc) == Data("original\n".utf8))
            return HostWritePlan(userFiles: [Self.rc: Data("original\nsource v2\n".utf8)], ownFiles: [:])
        }
        try await toy.restore { _, current, _ in current }

        #expect(try DirectorySnapshot(of: host.home) == before)
    }

    @Test("安裝後使用者又改了檔案：交給功能合併，保留使用者的修改")
    func restoreMergesUserChanges() async throws {
        try write("original\n", to: ".toolrc")
        try await installToy()
        try write("original\nsource ~/.purrdr/toy/hook.sh\nexport EDITOR=vim\n", to: ".toolrc")

        try await toy.restore { path, current, original in
            #expect(path == Self.rc)
            #expect(original == Data("original\n".utf8))
            let kept = String(decoding: current, as: UTF8.self).split(separator: "\n").filter { !$0.contains(".purrdr") }
            return Data((kept.joined(separator: "\n") + "\n").utf8)
        }

        #expect(try contents(".toolrc") == "original\nexport EDITOR=vim\n")
        #expect(!FileManager.default.fileExists(atPath: host.url(".purrdr").path))
    }

    @Test("沒安裝時還原：什麼都不改")
    func restoreWithoutInstallChangesNothing() async throws {
        try write("original\n", to: ".toolrc")
        let before = try DirectorySnapshot(of: host.home)

        try await toy.restore { _, current, _ in current }

        #expect(try DirectorySnapshot(of: host.home) == before)
    }

    @Test("讀取與寫入之間檔案被改了：整批不寫，主機維持原狀")
    func installRefusesWhenFileChangesMidway() async throws {
        try write("original\n", to: ".toolrc")
        let racing = ReversibleHostWrite(channel: host, feature: HostWriteFeature(id: "toy", userFiles: [Self.rc]))

        await #expect(throws: HostFilesError.changedSinceRead(Self.rc)) {
            try await racing.install { inspection in
                // 讀完之後、寫入之前，使用者在主機上改了檔案。
                try write("edited meanwhile\n", to: ".toolrc")
                return HostWritePlan(userFiles: [Self.rc: (inspection.read[Self.rc]?.contents ?? Data()) + Data("x\n".utf8)], ownFiles: [:])
            }
        }

        #expect(try contents(".toolrc") == "edited meanwhile\n")
        #expect(!FileManager.default.fileExists(atPath: host.url(".purrdr").path))
    }
}
#endif
