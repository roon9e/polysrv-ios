import XCTest
@testable import TelegramCore

/// Covers the server registry's pure logic: the merged list, per-datacenter
/// address fallback, per-account binding and the pending selection, the
/// `host:port` scope that decides a datacenter-state reset, the retention of a
/// server the published list dropped while an account still uses it, and the
/// lenient JSON decoding a published list depends on.
final class PolySrvServersTests: XCTestCase {
    private func makeStore() -> (PolySrvServers, UserDefaults) {
        let suite = "polysrv.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (PolySrvServers(defaults: defaults), defaults)
    }

    private func publishedServer(id: String, host: String = "10.0.0.1", port: Int = 443) -> PolySrvServer {
        return PolySrvServer(id: id, name: id, host: host, port: port, rsaPublicKey: "key", isOfficial: true, restrictToTcp: true)
    }

    private func addCustomServer(_ store: PolySrvServers, host: String = "10.0.0.1", port: Int = 1234) -> PolySrvServer {
        return store.addCustomServer(name: "Test", host: host, port: port, rsaPublicKey: "", multiDc: false, mainDcId: 2)
    }

    func testBundledListCarriesOnlyOfficialTelegram() {
        let (store, _) = self.makeStore()
        // The additional servers live on gh-pages and are fetched at runtime;
        // the bundled fallback is the official cloud alone.
        let servers = store.allServers()
        XCTAssertEqual(servers.map { $0.id }, [PolySrvServers.telegramServerId])
        let telegram = store.server(id: PolySrvServers.telegramServerId)
        XCTAssertEqual(telegram?.isTelegram, true)
        XCTAssertEqual(telegram?.multiDc, true)
    }

    func testDataCenterAddressFallsBackToPrimary() {
        // A single-machine server answers its one address for every datacenter.
        let server = PolySrvServer(id: "single", name: "Single", host: "10.0.0.1", port: 1234)
        for dcId in 1...5 {
            XCTAssertEqual(server.host(forDataCenterId: dcId), server.host)
            XCTAssertEqual(server.port(forDataCenterId: dcId), server.port)
        }
    }

    func testPerAccountBinding() {
        let (store, _) = self.makeStore()
        let accountId = generateAccountRecordId()
        let created = self.addCustomServer(store)

        XCTAssertNil(store.server(forAccount: accountId))
        store.setServer(id: created.id, forAccount: accountId)
        XCTAssertEqual(store.server(forAccount: accountId)?.id, created.id)
    }

    func testPendingSelectionAppliesBeforeBinding() {
        let (store, _) = self.makeStore()
        let created = self.addCustomServer(store)
        store.selectedServerIdForNextAccount = created.id
        let accountId = generateAccountRecordId()
        XCTAssertEqual(store.server(forAccount: accountId)?.id, created.id)

        // An explicit binding wins over the pending selection.
        store.setServer(id: PolySrvServers.telegramServerId, forAccount: accountId)
        XCTAssertEqual(store.server(forAccount: accountId)?.id, PolySrvServers.telegramServerId)
    }

    /// A server chosen before the account existed sticks to the first account
    /// that builds a network, and is not handed to the next one as well.
    func testPendingSelectionBindsToTheFirstAccount() {
        let (store, _) = self.makeStore()
        let created = self.addCustomServer(store)
        store.selectedServerIdForNextAccount = created.id

        let first = generateAccountRecordId()
        store.bindPendingIfNeeded(forAccount: first)
        XCTAssertEqual(store.server(forAccount: first)?.id, created.id)

        // Consumed: a later unbound account falls back to the official cloud
        // rather than inheriting the choice.
        XCTAssertNil(store.selectedServerIdForNextAccount)
        XCTAssertNil(store.server(forAccount: generateAccountRecordId()))
    }

    func testCustomServerCRUD() {
        let (store, _) = self.makeStore()
        let created = self.addCustomServer(store)
        XCTAssertTrue(store.isCustomServer(created.id))
        XCTAssertNotNil(store.server(id: created.id))
        XCTAssertEqual(created.restrictToTcp, true)
        XCTAssertEqual(created.description, "")

        store.removeCustomServer(id: created.id)
        XCTAssertFalse(store.isCustomServer(created.id))
        XCTAssertNil(store.server(id: created.id))
    }

    /// A server's scope is its address, `host:port`: two ports of one host are
    /// two servers, the same address under two ids is one server, and the
    /// official cloud is a scope of its own.
    func testScopeIsHostPort() {
        let a = PolySrvServer(id: "a", name: "A", host: "Example.COM", port: 443)
        let b = PolySrvServer(id: "b", name: "B", host: "example.com", port: 8443)
        let c = PolySrvServer(id: "c", name: "C", host: "example.com", port: 443)

        XCTAssertEqual(PolySrvServers.scope(for: a), "example.com:443")
        XCTAssertEqual(PolySrvServers.scope(for: b), "example.com:8443")
        XCTAssertNotEqual(PolySrvServers.scope(for: a), PolySrvServers.scope(for: b))
        XCTAssertEqual(PolySrvServers.scope(for: a), PolySrvServers.scope(for: c))

        XCTAssertEqual(PolySrvServers.scope(for: nil), PolySrvServers.telegramServerId)
        let telegram = PolySrvServer(id: "telegram", name: "Telegram", host: "149.154.167.51", port: 443, isTelegram: true)
        XCTAssertEqual(PolySrvServers.scope(for: telegram), PolySrvServers.telegramServerId)
    }

    func testAppliedScopeRoundTripsPerAccount() {
        let (store, defaults) = self.makeStore()
        let first = generateAccountRecordId()
        let second = generateAccountRecordId()

        XCTAssertNil(store.appliedScope(forAccount: first))
        store.setAppliedScope("example.com:443", forAccount: first)
        store.setAppliedScope("example.com:8443", forAccount: second)
        XCTAssertEqual(store.appliedScope(forAccount: first), "example.com:443")
        XCTAssertEqual(store.appliedScope(forAccount: second), "example.com:8443")

        // Persisted, so a rebuilt registry sees the same scopes.
        let reloaded = PolySrvServers(defaults: defaults)
        XCTAssertEqual(reloaded.appliedScope(forAccount: first), "example.com:443")
        XCTAssertEqual(reloaded.appliedScope(forAccount: second), "example.com:8443")
    }

    /// Changing the address or the key under a bound account would point it at
    /// another server while it kept the old server's keys.
    func testIdentityIsLockedWhileAnAccountIsBound() {
        let (store, _) = self.makeStore()
        let created = self.addCustomServer(store)
        XCTAssertTrue(store.canEditIdentity(of: created.id))

        store.setServer(id: created.id, forAccount: generateAccountRecordId())
        XCTAssertFalse(store.canEditIdentity(of: created.id))
    }

    func testAccountsBoundToScope() {
        let (store, _) = self.makeStore()
        let created = self.addCustomServer(store, host: "Example.COM", port: 45789)
        let account = generateAccountRecordId()
        store.setServer(id: created.id, forAccount: account)

        XCTAssertEqual(store.accountsBound(toScope: "example.com:45789"), [account])
        XCTAssertEqual(store.accountsBound(toScope: "example.com:443"), [])
    }

    /// A published server an account uses survives its removal from the list;
    /// once nothing is bound to it, it really is gone.
    func testUnpublishedBoundServerIsRetained() {
        let (store, _) = self.makeStore()
        let account = generateAccountRecordId()
        store.setRemoteServersForTesting([self.publishedServer(id: "one"), self.publishedServer(id: "two", port: 444)])
        store.setServer(id: "one", forAccount: account)

        store.setRemoteServersForTesting([self.publishedServer(id: "two", port: 444)])
        XCTAssertFalse(store.isPublished("one"))
        XCTAssertNotNil(store.server(id: "one"))
        XCTAssertEqual(store.server(forAccount: account)?.id, "one")

        store.pruneAccounts(keeping: [])
        XCTAssertNil(store.server(id: "one"))
    }

    /// An emptied servers.json empties the published list instead of reading as
    /// a failed fetch, and leaves the official cloud and the custom servers.
    func testEmptyPublishedListIsAnAnswer() {
        let (store, _) = self.makeStore()
        let created = self.addCustomServer(store)

        store.setRemoteServersForTesting([self.publishedServer(id: "one")])
        XCTAssertEqual(store.allServers().map { $0.id }, [PolySrvServers.telegramServerId, "one", created.id])

        store.setRemoteServersForTesting([])
        XCTAssertEqual(store.allServers().map { $0.id }, [PolySrvServers.telegramServerId, created.id])
    }

    func testDecodeInfersMultiDcFromDataCenters() throws {
        let json = """
        {"id":"multi","name":"Multi","host":"h","port":443,"dc":[{"id":1,"host":"a","port":1},{"id":2,"host":"b","port":2}]}
        """.data(using: .utf8)!
        let server = try JSONDecoder().decode(PolySrvServer.self, from: json)
        XCTAssertTrue(server.multiDc)
        XCTAssertEqual(server.mainDcId, 2)
        XCTAssertEqual(server.host(forDataCenterId: 1), "a")
        XCTAssertEqual(server.port(forDataCenterId: 2), 2)
        // An address the table does not name falls back to the primary.
        XCTAssertEqual(server.host(forDataCenterId: 5), "h")
        // A list written before logoPath existed still decodes.
        XCTAssertEqual(server.logoPath, "")
    }
}
