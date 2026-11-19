import Foundation
import PurrdrCore
import Testing

/// 帳號鈕與帳號頁顯示的會員名稱與頭像字(#246)。
@Suite("帳號頭像")
struct MemberAccountTests {
    static func member(_ emails: (SignInMethod, String?)...) -> Member {
        Member(id: "m1", identities: emails.map { MemberIdentity(method: $0.0, email: $0.1, linkedAt: Date(timeIntervalSince1970: 0)) })
    }

    @Test("名稱用第一個有 email 的登入方式，頭像是它的第一個字母大寫")
    func usesFirstEmail() {
        let member = Self.member((.apple, nil), (.google, "ray@example.com"))

        #expect(member.accountName == "ray@example.com")
        #expect(member.avatarInitial == "R")
    }

    @Test("都沒有 email:沒有名稱也沒有頭像字(畫面改用人像符號)")
    func noEmail() {
        let member = Self.member((.apple, nil))

        #expect(member.accountName == nil)
        #expect(member.avatarInitial == nil)
    }

    @Test("空白 email 視為沒有")
    func blankEmailIgnored() {
        let member = Self.member((.apple, "  "), (.google, "chen@example.com"))

        #expect(member.accountName == "chen@example.com")
        #expect(member.avatarInitial == "C")
    }
}
