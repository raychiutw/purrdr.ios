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
