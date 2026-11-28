import Foundation
import PurrdrCore
import Testing
@testable import PurrdrSSH

/// #670 重構的行為不變守門:預覽與定位腳本改由 `TranscriptLocator.all` 產生之前,手寫版本的輸出存在
/// `tests/PurrdrTestSupport/Fixtures/golden-scripts/`;產生出來的腳本要與它相同(PowerShell 函式只比對每一行,不比順序)。
@Suite("對話紀錄腳本:產生版與手寫版相同")
struct TranscriptScriptGoldenTests {
    static func golden(_ name: String) throws -> String {
        let folder = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "PurrdrTestSupport/Fixtures/golden-scripts")
        return try String(contentsOf: folder.appending(path: name), encoding: .utf8)
    }

    @Test("POSIX 預覽腳本")
    func posixPreviews() throws {
        #expect(TranscriptCommand.previewsScript == (try Self.golden("posix.previews.sh")))
    }

    @Test("Windows 預覽腳本")
    func windowsPreviews() throws {
        #expect(WindowsScripts.previews == (try Self.golden("windows.previews.ps1")))
    }

    @Test("Windows 對話紀錄函式:每一行(每個函式、PFind)都與手寫版相同")
    func windowsFunctions() throws {
        let legacyLines = try Self.golden("windows.transcriptFunctions.ps1").split(separator: "\n").map(String.init)
        let generatedLines = WindowsScripts.transcriptFunctions.split(separator: "\n").map(String.init)

        #expect(generatedLines.sorted() == legacyLines.sorted())
    }

    @Test("每個位置規則的 POSIX 定位、Windows 定位與開啟腳本不變", arguments: TranscriptLocator.all)
    func locateAndOpenScripts(_ locator: TranscriptLocator) throws {
        #expect(TranscriptCommand.locateScript(locator) == (try Self.golden("posix.locate.\(locator.name).sh")))
        #expect(WindowsScripts.locate(type: locator.lookupName, header: locator.readsHeader) == (try Self.golden("windows.locate.\(locator.name).ps1")))
        #expect(WindowsScripts.open(locator) == (try Self.golden("windows.open.\(locator.name).ps1")))
    }
}
