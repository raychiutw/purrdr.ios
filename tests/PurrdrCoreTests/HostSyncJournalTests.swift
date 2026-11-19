import Foundation
import PurrdrCore
import Testing

/// 主機同步的修改紀錄(#30):哪些變更要上傳、後台的結果怎麼併回這支裝置。
@Suite("主機同步：修改紀錄")
struct HostSyncJournalTests {
    static let studio = HostConfiguration(
        id: UUID(uuidString: "6F1C2A4E-3B7D-4C8E-9A10-2B3C4D5E6F70")!, name: "Studio Mac",
        endpoint: SSHEndpoint(host: "studio-mac", username: "ray"), openSSH: .password,
        herdr: HerdrInstallation(path: "/opt/herdr", session: "work"), operatingSystem: .macOS,
        hostKeyPin: HostKeyFingerprint(stored: "nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8"))
    static let t1 = Date(timeIntervalSince1970: 1_793_000_000)
    static let t2 = t1.addingTimeInterval(60)
    static let t3 = t1.addingTimeInterval(120)

    static func remote(_ host: HostConfiguration = studio, name: String? = nil, at date: Date) -> SyncedHost {
        var synced = SyncedHost(host, modifiedAt: date)
        if let name { synced.name = name }
        return synced
    }

    @Test("新增的主機要上傳，修改時間是存的時間")
    func newHostIsPending() {
        var journal = HostSyncJournal()
        journal.recordSave(Self.studio.id, at: Self.t1)

        let changes = journal.pendingChanges(hosts: [Self.studio], now: Self.t3)

        #expect(changes == [.upsert(Self.remote(at: Self.t1))])
    }

    @Test("HTTPS 主機上傳名稱、連線方式與主機服務位址")
    func httpsHostIsPendingWithAddress() throws {
        var journal = HostSyncJournal()
        let address = try #require(HostServiceAddress("studio.tail1234.ts.net"))
        let https = HostConfiguration(name: "Studio Mac", hostService: address)
        journal.recordSave(https.id, at: Self.t1)

        let changes = journal.pendingChanges(hosts: [https], now: Self.t3)

        #expect(changes == [.upsert(SyncedHost(
            id: https.id, name: "Studio Mac", endpoint: SSHEndpoint(host: "studio.tail1234.ts.net", port: 443, username: ""),
            connectionMethod: .https, hostKeyPin: nil, hostService: address, modifiedAt: Self.t1))])
    }

    @Test("帶埠號的 HTTPS 主機同步出去、別台裝置收回來都保留埠(#218)")
    func httpsPortSurvivesSync() throws {
        var journal = HostSyncJournal()
        let address = try #require(HostServiceAddress("https://studio.tail1234.ts.net:8443"))
        let https = HostConfiguration(name: "Studio Mac", hostService: address)
        journal.recordSave(https.id, at: Self.t1)

        let changes = journal.pendingChanges(hosts: [https], now: Self.t3)
        var other = HostSyncJournal()
        let outcome = other.reconcile(
            hosts: [], sent: [], snapshot: HostSyncSnapshot(hosts: [SyncedHost(https, modifiedAt: Self.t1)], deletedHostIDs: []))

        #expect(changes == [.upsert(SyncedHost(
            id: https.id, name: "Studio Mac", endpoint: SSHEndpoint(host: "studio.tail1234.ts.net", port: 8443, username: ""),
            connectionMethod: .https, hostKeyPin: nil, hostService: address, modifiedAt: Self.t1))])
        #expect(outcome.saves.first?.hostService?.description == "https://studio.tail1234.ts.net:8443")
    }

    @Test("別台裝置新增的 HTTPS 主機：存成有主機服務位址的 HTTPS 主機(權杖要在這支裝置重新配對)")
    func remoteHTTPSHostIsAdded() throws {
        var journal = HostSyncJournal()
        let address = try #require(HostServiceAddress("studio.tail1234.ts.net"))
        let remote = SyncedHost(
            id: UUID(), name: "Studio", endpoint: SSHEndpoint(host: "studio.tail1234.ts.net", port: 443, username: ""),
            connectionMethod: .https, hostKeyPin: nil, hostService: address, modifiedAt: Self.t1)

        let outcome = journal.reconcile(hosts: [], sent: [], snapshot: HostSyncSnapshot(hosts: [remote], deletedHostIDs: []))

        #expect(outcome.saves == [HostConfiguration(id: remote.id, name: "Studio", hostService: address)])
    }

    @Test("別台裝置把 SSH 主機改成 HTTPS:換成主機服務位址，SSH 登入方式清掉;改回 SSH 時位址清掉")
    func connectionMethodSwitchesBetweenSSHAndHTTPS() throws {
        var journal = HostSyncJournal()
        let address = try #require(HostServiceAddress("studio.tail1234.ts.net"))
        let toHTTPS = SyncedHost(
            id: Self.studio.id, name: "Studio Mac", endpoint: SSHEndpoint(host: "studio.tail1234.ts.net", port: 443, username: ""),
            connectionMethod: .https, hostKeyPin: nil, hostService: address, modifiedAt: Self.t2)

        let outcome = journal.reconcile(hosts: [Self.studio], sent: [], snapshot: HostSyncSnapshot(hosts: [toHTTPS], deletedHostIDs: []))
        let https = try #require(outcome.saves.first)

        #expect(https.connectionMethod == .https)
        #expect(https.hostService == address)
        #expect(https.authentication == nil)
        #expect(https.ssh == nil)

        let backToSSH = Self.remote(at: Self.t3)
        let second = journal.reconcile(hosts: [https], sent: [], snapshot: HostSyncSnapshot(hosts: [backToSSH], deletedHostIDs: []))
        let ssh = try #require(second.saves.first)
        #expect(ssh.connectionMethod == .openSSH)
        #expect(ssh.hostService == nil)
        #expect(ssh.authentication == .deviceKey)
    }

    @Test("標成 HTTPS 卻沒有主機服務位址的同步資料：不套用(不改成別的連線方式、不改名)，下次同步再處理")
    func httpsWithoutAddressIsNotApplied() throws {
        var journal = HostSyncJournal()
        let missingAddress = { (id: UUID) in
            SyncedHost(
                id: id, name: "Renamed", endpoint: SSHEndpoint(host: "studio.tail1234.ts.net", port: 443, username: ""),
                connectionMethod: .https, hostKeyPin: nil, hostService: nil, modifiedAt: Self.t2)
        }
        let added = missingAddress(UUID())
        let changed = missingAddress(Self.studio.id)

        let outcome = journal.reconcile(
            hosts: [Self.studio], sent: [], snapshot: HostSyncSnapshot(hosts: [added, changed], deletedHostIDs: []))

        #expect(outcome == HostSyncOutcome())
        #expect(journal.synced[added.id] == nil)
        #expect(journal.synced[changed.id] == nil)
    }

    @Test("後台確認之後就不再上傳")
    func confirmedHostIsNotPending() {
        var journal = HostSyncJournal()
        journal.recordSave(Self.studio.id, at: Self.t1)
        let sent = journal.pendingChanges(hosts: [Self.studio], now: Self.t3)

        let outcome = journal.reconcile(
            hosts: [Self.studio], sent: sent, snapshot: HostSyncSnapshot(hosts: [Self.remote(at: Self.t1)], deletedHostIDs: []))

        #expect(outcome == HostSyncOutcome())
        #expect(journal.pendingChanges(hosts: [Self.studio], now: Self.t3).isEmpty)
    }

    @Test("開啟同步前就存在的主機(沒有修改紀錄)以開啟的時間上傳")
    func hostWithoutRecordUsesNow() {
        var journal = HostSyncJournal()

        let changes = journal.pendingChanges(hosts: [Self.studio], now: Self.t2)

        #expect(changes == [.upsert(Self.remote(at: Self.t2))])
        #expect(journal.pendingChanges(hosts: [Self.studio], now: Self.t3) == changes, "第二次仍是同一個修改時間")
    }

    @Test("衝突：別台裝置較新的修改勝出，只換同步的欄位，這支裝置的登入方式與 herdr 設定不動")
    func newerRemoteWins() {
        var journal = HostSyncJournal()
        journal.recordSave(Self.studio.id, at: Self.t1)
        let sent = journal.pendingChanges(hosts: [Self.studio], now: Self.t3)
        var newer = Self.remote(name: "Renamed on iPad", at: Self.t2)
        newer.endpoint = SSHEndpoint(host: "studio.tailnet", port: 2222, username: "ray2")
        newer.hostKeyPin = HostKeyFingerprint(stored: "AAAAg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8")

        let outcome = journal.reconcile(hosts: [Self.studio], sent: sent, snapshot: HostSyncSnapshot(hosts: [newer], deletedHostIDs: []))

        var expected = Self.studio.editingSSH {
            $0.endpoint = newer.endpoint
            $0.hostKeyPin = newer.hostKeyPin
        }
        expected.name = "Renamed on iPad"
        #expect(outcome == HostSyncOutcome(saves: [expected]))
        #expect(journal.pendingChanges(hosts: [expected], now: Self.t3).isEmpty, "採用後台的版本後不再上傳")
    }

    @Test("別台裝置新增的主機：存成新主機;OpenSSH 預設用這支裝置的金鑰(祕密不同步)")
    func remoteHostIsAdded() {
        var journal = HostSyncJournal()
        let remote = SyncedHost(
            id: UUID(), name: "Linux box", endpoint: SSHEndpoint(host: "100.64.0.9", port: 2222, username: "ops"),
            connectionMethod: .openSSH, hostKeyPin: nil, modifiedAt: Self.t1)

        let outcome = journal.reconcile(hosts: [], sent: [], snapshot: HostSyncSnapshot(hosts: [remote], deletedHostIDs: []))

        #expect(outcome.saves == [
            HostConfiguration(
                id: remote.id, name: "Linux box", endpoint: remote.endpoint, openSSH: .deviceKey)
        ])
        #expect(journal.pendingChanges(hosts: outcome.saves, now: Self.t3).isEmpty)
    }

    @Test("這支裝置刪除的主機上傳刪除;後台確認後不再上傳")
    func localDeletionIsSentOnce() {
        var journal = HostSyncJournal()
        journal.recordSave(Self.studio.id, at: Self.t1)
        journal.recordDeletion(Self.studio.id)

        let sent = journal.pendingChanges(hosts: [], now: Self.t3)
        #expect(sent == [.delete(Self.studio.id)])

        let outcome = journal.reconcile(hosts: [], sent: sent, snapshot: HostSyncSnapshot(hosts: [], deletedHostIDs: [Self.studio.id]))
        #expect(outcome == HostSyncOutcome())
        #expect(journal.pendingChanges(hosts: [], now: Self.t3).isEmpty)
    }

    @Test("別台裝置刪除的主機：這支裝置也刪，而且不會再上傳回去")
    func remoteDeletionIsNotSyncedBack() {
        var journal = HostSyncJournal()
        journal.recordSave(Self.studio.id, at: Self.t1)
        let sent = journal.pendingChanges(hosts: [Self.studio], now: Self.t3)

        let outcome = journal.reconcile(
            hosts: [Self.studio], sent: sent, snapshot: HostSyncSnapshot(hosts: [], deletedHostIDs: [Self.studio.id]))

        #expect(outcome == HostSyncOutcome(deletions: [Self.studio.id]))
        #expect(journal.pendingChanges(hosts: [], now: Self.t3).isEmpty)
        #expect(journal.modified[Self.studio.id] == nil)
    }

    @Test("沒有這台主機的刪除紀錄不用動")
    func unknownDeletionIsIgnored() {
        var journal = HostSyncJournal()

        let outcome = journal.reconcile(hosts: [], sent: [], snapshot: HostSyncSnapshot(hosts: [], deletedHostIDs: [UUID()]))

        #expect(outcome == HostSyncOutcome())
    }

    @Test("同步途中又修改的主機：不被後台的舊版本蓋掉，下次再上傳")
    func changedDuringSyncIsKept() {
        var journal = HostSyncJournal()
        journal.recordSave(Self.studio.id, at: Self.t1)
        let sent = journal.pendingChanges(hosts: [Self.studio], now: Self.t3)
        var renamed = Self.studio
        renamed.name = "Renamed meanwhile"
        journal.recordSave(Self.studio.id, at: Self.t2)

        let outcome = journal.reconcile(
            hosts: [renamed], sent: sent, snapshot: HostSyncSnapshot(hosts: [Self.remote(at: Self.t1)], deletedHostIDs: []))

        #expect(outcome == HostSyncOutcome())
        #expect(journal.pendingChanges(hosts: [renamed], now: Self.t3) == [.upsert(SyncedHost(renamed, modifiedAt: Self.t2))])
    }

    @Test("同步途中刪除的主機：後台還列著也不加回來")
    func deletedDuringSyncIsNotReadded() {
        var journal = HostSyncJournal()
        journal.recordSave(Self.studio.id, at: Self.t1)
        let sent = journal.pendingChanges(hosts: [Self.studio], now: Self.t3)
        journal.recordDeletion(Self.studio.id)

        let outcome = journal.reconcile(
            hosts: [], sent: sent, snapshot: HostSyncSnapshot(hosts: [Self.remote(at: Self.t1)], deletedHostIDs: []))

        #expect(outcome == HostSyncOutcome())
        #expect(journal.pendingChanges(hosts: [], now: Self.t3) == [.delete(Self.studio.id)])
    }

    // MARK: - 主機圖示(#243)

    @Test("上傳的修改帶這支裝置替主機選的圖示")
    func pendingChangeCarriesIcon() {
        var journal = HostSyncJournal()
        journal.recordSave(Self.studio.id, at: Self.t1)

        let changes = journal.pendingChanges(hosts: [Self.studio], icons: [Self.studio.id: "macMini"], now: Self.t3)

        #expect(changes == [.upsert(SyncedHost(Self.studio, modifiedAt: Self.t1, icon: "macMini"))])
    }

    @Test("採用別台裝置的版本時，連同它的圖示一起交給這支裝置")
    func appliedRemoteReportsIcon() {
        var journal = HostSyncJournal()
        let renamed = SyncedHost(Self.studio, modifiedAt: Self.t2, icon: "rack")

        let outcome = journal.reconcile(
            hosts: [Self.studio], sent: [], snapshot: HostSyncSnapshot(hosts: [renamed], deletedHostIDs: []))

        #expect(outcome.icons == [Self.studio.id: "rack"])
    }

    @Test("後台沒有圖示資料(舊版 app 上傳的主機):不交圖示，這支裝置沿用自己的")
    func remoteWithoutIconReportsNothing() {
        var journal = HostSyncJournal()

        let outcome = journal.reconcile(
            hosts: [Self.studio], sent: [], snapshot: HostSyncSnapshot(hosts: [Self.remote(at: Self.t2)], deletedHostIDs: []))

        #expect(outcome.icons.isEmpty)
    }

    @Test("同步途中又修改的主機：後台的舊圖示也不蓋掉")
    func changedDuringSyncKeepsIcon() {
        var journal = HostSyncJournal()
        journal.recordSave(Self.studio.id, at: Self.t1)
        let sent = journal.pendingChanges(hosts: [Self.studio], icons: [Self.studio.id: "rack"], now: Self.t3)
        journal.recordSave(Self.studio.id, at: Self.t2)

        let outcome = journal.reconcile(
            hosts: [Self.studio], sent: sent,
            snapshot: HostSyncSnapshot(hosts: [SyncedHost(Self.studio, modifiedAt: Self.t1, icon: "rack")], deletedHostIDs: []))

        #expect(outcome.icons.isEmpty)
    }

    @Test("修改時間只到毫秒(與後台相同),後台回來的時間才對得上")
    func timesAreMilliseconds() {
        var journal = HostSyncJournal()
        journal.recordSave(Self.studio.id, at: Self.t1.addingTimeInterval(0.000_7))

        #expect(journal.modified[Self.studio.id] == Self.t1)
    }
}
