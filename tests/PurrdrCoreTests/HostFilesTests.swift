#if os(macOS)
import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 主機檔案(讀取與 compare-and-swap 寫入)。在本機用真的 `/bin/sh` 跑主機腳本，家目錄是暫存資料夾。
@Suite("主機檔案")
struct HostFilesTests {
    let host: LocalShellHost
    let files: HostFiles

    init() throws {
        host = try LocalShellHost()
        files = HostFiles(channel: host)
    }

    func write(_ text: String, to path: String) throws {
        let url = host.url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func contents(_ path: String) throws -> String {
        try String(contentsOf: host.url(path), encoding: .utf8)
    }

    @Test("讀取：回報執行的使用者、一般檔案的內容、不存在的檔案")
    func readsFilesAndUser() async throws {
        try write("{\"a\":1}\n", to: ".claude/settings.json")

        let read = try await files.read([".claude/settings.json", ".claude/missing.json"])

        #expect(read.user == NSUserName())
        #expect(read[".claude/settings.json"]?.contents == Data("{\"a\":1}\n".utf8))
        #expect(read[".claude/missing.json"] == .missing)
    }

    @Test("讀取跟隨 symlink;資料夾、FIFO 不是一般檔案;所在資料夾不存在另外回報")
    func readsThroughSymlinksAndRejectsSpecialFiles() async throws {
        try write("dotfiles", to: "dotfiles/claude.json")
        try FileManager.default.createDirectory(at: host.url(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: host.url(".claude/settings.json").path, withDestinationPath: "../dotfiles/claude.json")
        #expect(mkfifo(host.url("pipe").path, 0o600) == 0)

        let read = try await files.read([".claude/settings.json", "pipe", "dotfiles", "nowhere/file.json"])

        #expect(read[".claude/settings.json"]?.contents == Data("dotfiles".utf8))
        #expect(read["pipe"] == .notRegularFile)
        #expect(read["dotfiles"] == .notRegularFile)
        #expect(read["nowhere/file.json"] == .missingDirectory)
    }

    @Test("路徑只接受家目錄底下的安全相對路徑")
    func rejectsUnsafePaths() async throws {
        for path in ["../etc/passwd", "/etc/passwd", "a/../b", "", "a b", "a'b"] {
            await #expect(throws: HostFilesError.invalidPath(path)) { try await files.read([HostPath(path)]) }
        }
        #expect(host.commands.isEmpty)
    }

    @Test("主機腳本不含反斜線(fish 在單引號內仍會處理反斜線)")
    func scriptsHaveNoBackslash() async throws {
        _ = try await files.read([".claude/settings.json"])
        try await files.apply([.write(".purrdr/x", Data("a'b\\c".utf8), expecting: .anything)])
        for command in host.commands {
            #expect(!command.contains("\\"), "指令含反斜線:\(command)")
        }
    }

    @Test("寫入：版本相符才寫，寫到 symlink 指向的真正檔案，保留權限")
    func writesThroughSymlinkKeepingMode() async throws {
        try write("old", to: "dotfiles/claude.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: host.url("dotfiles/claude.json").path)
        try FileManager.default.createDirectory(at: host.url(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: host.url(".claude/settings.json").path, withDestinationPath: "../dotfiles/claude.json")
        let read = try await files.read([".claude/settings.json"])
        guard case .file(_, let version)? = read[".claude/settings.json"] else { Issue.record("讀不到"); return }

        try await files.apply([
            .write(".purrdr/feature/journal.json", Data("{}".utf8), expecting: .anything),
            .write(".claude/settings.json", Data("new".utf8), expecting: .version(version)),
        ])

        #expect(try contents("dotfiles/claude.json") == "new")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: host.url(".claude/settings.json").path) == "../dotfiles/claude.json")
        let mode = try FileManager.default.attributesOfItem(atPath: host.url("dotfiles/claude.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o640)
        #expect(try contents(".purrdr/feature/journal.json") == "{}")
    }

    @Test("讀取之後檔案被改過：整批都不寫，回報是哪個檔案")
    func refusesWhenChangedSinceRead() async throws {
        try write("old", to: ".claude/settings.json")
        let read = try await files.read([".claude/settings.json"])
        guard case .file(_, let version)? = read[".claude/settings.json"] else { Issue.record("讀不到"); return }
        try write("changed by someone", to: ".claude/settings.json")
        let before = try DirectorySnapshot(of: host.home)

        await #expect(throws: HostFilesError.changedSinceRead(".claude/settings.json")) {
            try await files.apply([
                .write(".purrdr/feature/journal.json", Data("{}".utf8), expecting: .anything),
                .write(".claude/settings.json", Data("new".utf8), expecting: .version(version)),
            ])
        }
        #expect(try DirectorySnapshot(of: host.home) == before)
    }

    @Test("預期不存在卻已存在、或所在資料夾不存在：不寫")
    func refusesUnexpectedExistenceOrMissingDirectory() async throws {
        try write("there", to: ".claude/settings.json")

        await #expect(throws: HostFilesError.changedSinceRead(".claude/settings.json")) {
            try await files.apply([.write(".claude/settings.json", Data("new".utf8), expecting: .missing)])
        }
        await #expect(throws: HostFilesError.missingDirectory("nowhere/settings.json")) {
            try await files.apply([.write("nowhere/settings.json", Data("new".utf8), expecting: .missing)])
        }
        #expect(try contents(".claude/settings.json") == "there")
        #expect(!FileManager.default.fileExists(atPath: host.url("nowhere").path))
    }

    @Test("刪除檔案、移除 Purrdr 自己的資料夾(.purrdr 空了也一起移除)")
    func deletesAndRemovesOwnDirectory() async throws {
        try write("a", to: "keep.json")
        try write("b", to: "gone.json")
        try write("c", to: ".purrdr/feature/journal.json")

        try await files.apply([.delete("gone.json", expecting: .anything), .removeDirectory(".purrdr/feature")])

        #expect(try DirectorySnapshot(of: host.home).entries.keys.sorted() == ["keep.json"])
    }

    @Test("指令超過 126 KiB(sshd 單一參數上限):不送出")
    func refusesTooLargeCommand() async throws {
        await #expect(throws: HostFilesError.tooLarge) {
            try await files.apply([.write(".purrdr/feature/big", Data(count: 100 * 1024), expecting: .anything)])
        }
        #expect(host.commands.isEmpty)
    }

    @Test("寫入可執行檔")
    func writesExecutable() async throws {
        try await files.apply([.write(".purrdr/feature/run.sh", Data("#!/bin/sh".utf8), executable: true, expecting: .missing)])

        #expect(FileManager.default.isExecutableFile(atPath: host.url(".purrdr/feature/run.sh").path))
    }
}
#endif
