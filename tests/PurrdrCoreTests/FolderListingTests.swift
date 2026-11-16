import Foundation
import PurrdrCore
import Testing

/// 資料夾清單的解析(行為規格 F13):第一行是 `pwd`,接著是 `LC_ALL=C ls -lnA` 的長格式。
@Suite("資料夾清單解析")
struct FolderListingTests {
    /// 2026-11-16 12:00(UTC)。
    let now = Date(timeIntervalSince1970: 1_794_830_400)

    /// macOS(BSD ls)的實際輸出:在 scratchpad 的暫存資料夾建好下列項目後執行 `LC_ALL=C ls -lnA` 取得,
    /// 使用者 id 換成 501、群組 0。
    static let macOS = """
        /Users/demo/work
        total 16
        drwxr-xr-x@ 2 501  0  64 Nov 16 05:12 .config
        -rw-r--r--@ 1 501  0   1 Nov 16 05:12 .zshrc
        lrwxr-xr-x@ 1 501  0   8 Nov 16 05:12 link -> projects
        -rw-r--r--@ 1 501  0   0 Jan  2  2023 old.log
        prw-r--r--@ 1 501  0   0 Nov 16 05:12 pipe
        drwxr-xr-x@ 2 501  0  64 Nov 16 05:12 projects
        -rw-r--r--@ 1 501  0   5 Nov 16 05:12 read me.txt
        crw-rw-rw-  1 0  0  0x3000002 Nov 16 05:12 null

        """

    /// GNU coreutils `ls -lnA` 的格式(依 coreutils 的長格式:權限後可能有 `.`(SELinux)或 `+`(ACL),
    /// 裝置檔的大小欄是「主, 次」)。手寫，沒有 Linux 主機可錄。
    static let linux = """
        /home/demo
        total 8
        -rw-r--r--. 1 1000 1000 1048576 Mar  5 09:41 big.bin
        drwxr-x---+ 3 1000 1000    4096 Dec 31  2025 Documents
        crw-rw-rw-  1    0    0   1,   3 Nov 10 08:00 null

        """

    @Test("第一行不是絕對路徑：主機回應的不是資料夾清單")
    func rejectsOutputWithoutAbsolutePath() {
        for output in ["", "total 0\n", "bash: ls: command not found\n", "Last login: Mon\n/Users/demo\n", "~/demo\ntotal 0\n"] {
            #expect(throws: HostFolderError.notAFolderListing, "\(output)") { try FolderListing.parse(output, now: now) }
        }
    }

    @Test("解析 macOS 的長格式：種類、大小、名稱(含空白)、symlink 截掉「 -> 」之後;資料夾在前再依名稱")
    func parsesMacOSListing() throws {
        let listing = try FolderListing.parse(Self.macOS, now: now)

        #expect(listing.path == "/Users/demo/work")
        #expect(listing.entries.map(\.name) == [".config", "projects", ".zshrc", "link", "null", "old.log", "pipe", "read me.txt"])
        let byName = Dictionary(uniqueKeysWithValues: listing.entries.map { ($0.name, $0) })
        #expect(byName["projects"]?.kind == .folder)
        #expect(byName["read me.txt"]?.kind == .file)
        #expect(byName["read me.txt"]?.size == 5)
        #expect(byName["link"]?.kind == .symlink)
        #expect(byName["pipe"]?.kind == .other)
        #expect(byName["null"]?.kind == .other)
        #expect(byName["null"]?.size == 0)
    }

    @Test("修改時間：今年內的有時分，舊的只有年月日")
    func parsesDates() throws {
        let listing = try FolderListing.parse(Self.macOS, now: now)
        let byName = Dictionary(uniqueKeysWithValues: listing.entries.map { ($0.name, $0) })

        #expect(byName["read me.txt"]?.modified == DateComponents(year: 2026, month: 11, day: 16, hour: 5, minute: 12))
        #expect(byName["old.log"]?.modified == DateComponents(year: 2023, month: 1, day: 2))
    }

    @Test("只有時分的日期在未來時是去年(ls 對半年內的檔案只印時分)")
    func recentDateInFutureIsLastYear() throws {
        let listing = try FolderListing.parse("/tmp\n-rw-r--r-- 1 0 0 1 Dec 20 10:00 a\n", now: now)
        #expect(listing.entries.first?.modified == DateComponents(year: 2025, month: 12, day: 20, hour: 10, minute: 0))
    }

    @Test("解析 GNU ls 的長格式(權限後的 . 與 +、裝置檔的「主, 次」)")
    func parsesLinuxListing() throws {
        let listing = try FolderListing.parse(Self.linux, now: now)

        #expect(listing.path == "/home/demo")
        #expect(listing.entries == [
            FolderEntry(name: "Documents", kind: .folder, size: 4096, modified: DateComponents(year: 2025, month: 12, day: 31)),
            FolderEntry(name: "big.bin", kind: .file, size: 1_048_576, modified: DateComponents(year: 2026, month: 3, day: 5, hour: 9, minute: 41)),
            FolderEntry(name: "null", kind: .other, size: 0, modified: DateComponents(year: 2026, month: 11, day: 10, hour: 8, minute: 0)),
        ])
    }

    @Test("空資料夾")
    func emptyFolder() throws {
        let listing = try FolderListing.parse("/\ntotal 0\n", now: now)
        #expect(listing == FolderListing(path: "/", entries: []))
    }
}
