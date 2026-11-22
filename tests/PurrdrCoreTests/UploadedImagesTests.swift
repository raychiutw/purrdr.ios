import Foundation
import PurrdrCore
import Testing

/// 讀回對話紀錄時的圖片(行為規格 F6.6、F7):路徑行變成圖片，`[Image #N]` 移除，剩下的必須是使用者打的字。
@Suite("對話紀錄中的上傳圖片")
struct UploadedImagesTests {
    func bubble(_ parts: [TranscriptPart]) -> UserBubble? {
        let items = Conversation.items(from: [TranscriptMessage(id: "u1", role: .user, date: nil, parts: parts)])
        guard case .user(let bubble)? = items.first else { return nil }
        return bubble
    }

    @Test("Claude:`[Image #N]` 移除，`[Image: source: <路徑>]` 變成圖片;圖片區塊與來源不重複計算")
    func claudeForm() throws {
        let bubble = try #require(bubble([
            .text("Look at this\n\n[Image #1]"),
            .text("[Image: source: /Users/me/.purrdr/uploads/mh1-abc.jpg]"),
            .images(1),
        ]))
        #expect(bubble.text == "Look at this")
        #expect(bubble.imageCount == 1)
        #expect(bubble.imagePaths == ["/Users/me/.purrdr/uploads/mh1-abc.jpg"])
    }

    @Test("Codex:保留原行;上傳資料夾下的圖片路徑行變成圖片")
    func codexForm() throws {
        let bubble = try #require(bubble([
            .text("Compare these\n\n/home/me/.purrdr/uploads/a-1.jpg\n/home/me/.purrdr/uploads/b-2.png"),
        ]))
        #expect(bubble.text == "Compare these")
        #expect(bubble.imageCount == 2)
        #expect(bubble.imagePaths == ["/home/me/.purrdr/uploads/a-1.jpg", "/home/me/.purrdr/uploads/b-2.png"])
    }

    @Test("使用者送出的非圖片檔案:上傳資料夾底下的路徑行是檔案卡片(#429),顯示文字拿掉路徑行,文字本身不變(回音配對用)")
    func userFilePaths() throws {
        let report = "/var/folders/zz/demo/T/purrdr-uploads-501/report-1.pdf"
        let notes = "/Users/me/.purrdr/uploads/notes-2.txt"
        let bubble = try #require(bubble([.text("Please read these\n\n\(report)\n\(notes)\n/Users/me/other/secret.pdf")]))
        #expect(bubble.filePaths == [report, notes])
        #expect(bubble.displayText == "Please read these\n\n/Users/me/other/secret.pdf")
        #expect(bubble.text.contains(report))
        #expect(bubble.imageCount == 0)
    }

    @Test("Windows 使用者資料夾名稱有空白的上傳檔案也認得;沒有檔案時 filePaths 為空")
    func windowsAndNone() throws {
        let path = #"C:\Users\Demo User\AppData\Local\Temp\purrdr-uploads\data-3.csv"#
        let bubble = try #require(bubble([.text("Data\n\n\(path)")]))
        #expect(bubble.filePaths == [path])
        let plain = try #require(self.bubble([.text("hello")]))
        #expect(plain.filePaths.isEmpty)
        #expect(plain.displayText == "hello")
    }

    @Test("新的上傳資料夾(暫存目錄底下的 purrdr-uploads、Unix 後接 uid、Windows 在 %TEMP%)與舊的 .purrdr/uploads 都認得")
    func newAndLegacyFolders() throws {
        let paths = [
            "/var/folders/zz/demo/T/purrdr-uploads-501/a-1.jpg", "/tmp/purrdr-uploads-1000/b-2.png",
            #"C:\Users\Demo User\AppData\Local\Temp\purrdr-uploads\c-3.jpg"#, "/Users/me/.purrdr/uploads/d-4.jpg",
        ]
        let bubble = try #require(bubble([.text("Compare\n\n" + paths.joined(separator: "\n"))]))
        #expect(bubble.text == "Compare")
        #expect(bubble.imagePaths == paths)
    }

    @Test("名稱只是像的資料夾、非圖片副檔名不是上傳的圖片")
    func lookalikeFoldersStayText() throws {
        let lines = ["/tmp/purrdr-uploads-abc/a-1.jpg", "/tmp/purrdr-uploads-501x/a-1.jpg", "/tmp/my-purrdr-uploads/a-1.jpg", "/tmp/purrdr-uploads-501/a-1.pdf"]
        let bubble = try #require(bubble([.text(lines.joined(separator: "\n"))]))
        #expect(bubble.imageCount == 0)
        #expect(bubble.text == lines.joined(separator: "\n"))
    }

    @Test("上傳資料夾外的路徑、句中的路徑是文字，不是圖片")
    func otherPathsStayText() throws {
        let bubble = try #require(bubble([
            .text("open /Users/me/.purrdr/uploads/a-1.jpg please\n/Users/me/Pictures/cat.jpg"),
        ]))
        #expect(bubble.text == "open /Users/me/.purrdr/uploads/a-1.jpg please\n/Users/me/Pictures/cat.jpg")
        #expect(bubble.imageCount == 0)
    }

    @Test("只有圖片：文字是空的，仍是一則使用者訊息")
    func imageOnly() throws {
        let bubble = try #require(bubble([.text("/Users/me/.purrdr/uploads/a-1.jpg")]))
        #expect(bubble.text == "")
        #expect(bubble.imageCount == 1)
    }

    @Test("送出的 prompt 文字 = 打的字 + 空一行 + 每張一行絕對路徑;只有圖片時就是路徑")
    func composesPrompt() {
        #expect(UploadedImages.prompt(text: "hi", paths: []) == "hi")
        #expect(UploadedImages.prompt(text: "hi", paths: ["/a/x.jpg", "/a/y.jpg"]) == "hi\n\n/a/x.jpg\n/a/y.jpg")
        #expect(UploadedImages.prompt(text: "", paths: ["/a/x.jpg"]) == "/a/x.jpg")
    }

    @Test("列表預覽不顯示圖片路徑")
    func previewHidesPaths() {
        let preview = Conversation.preview(of: [TranscriptMessage(id: "u1", role: .user, date: nil, parts: [
            .text("Look\n\n[Image #1]"), .text("[Image: source: /Users/me/.purrdr/uploads/mh1-abc.jpg]"), .images(1),
        ])])
        #expect(preview?.text == "Look")
    }
}
