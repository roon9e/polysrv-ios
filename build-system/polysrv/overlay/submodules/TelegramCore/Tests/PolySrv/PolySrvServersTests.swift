import XCTest
@testable import TelegramCore

/// Covers the server registry's pure logic: the merged list, per-datacenter
/// address fallback, per-account binding, the pre-login pending selection and
/// the lenient JSON decoding a published list depends on.
final class PolySrvServersTests: XCTestCase {
    private func makeStore() -> (PolySrvServers, UserDefaults) {
        let suite = "polysrv.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (PolySrvServers(defaults: defaults), defaults)
    }

    func testDefaultListContainsTelegramAndPolySrv() {
        let (store, _) = self.makeStore()
        let servers = store.allServers()
        XCTAssertNotNil(servers.first(where: { $0.id == PolySrvServers.telegramServerId }))
        let telegram = store.server(id: PolySrvServers.telegramServerId)
        XCTAssertEqual(telegram?.isTelegram, true)
        XCTAssertEqual(telegram?.multiDc, true)

        let custom = store.server(id: "polysrv-default")
        XCTAssertNotNil(custom)
        XCTAssertEqual(custom?.isTelegram, false)
        XCTAssertEqual(custom?.restrictToTcp, true)
        XCTAssertFalse(custom?.rsaPublicKey.isEmpty ?? true)
    }

    func testDataCenterAddressFallsBackToPrimary() {
        let (store, _) = self.makeStore()
        guard let server = store.server(id: "polysrv-default") else {
            return XCTFail("missing default server")
        }
        // A single-machine server answers its one address for every datacenter.
        for dcId in 1...5 {
            XCTAssertEqual(server.host(forDataCenterId: dcId), server.host)
            XCTAssertEqual(server.port(forDataCenterId: dcId), server.port)
        }
    }

    func testPerAccountBinding() {
        let (store, _) = self.makeStore()
        let accountId = generateAccountRecordId()

        XCTAssertNil(store.server(forAccount: accountId))
        store.setServer(id: "polysrv-default", forAccount: accountId)
        XCTAssertEqual(store.server(forAccount: accountId)?.id, "polysrv-default")
    }

    func testPendingSelectionAppliesBeforeBinding() {
        let (store, _) = self.makeStore()
        store.selectedServerIdForNextAccount = "polysrv-default"
        let accountId = generateAccountRecordId()
        XCTAssertEqual(store.server(forAccount: accountId)?.id, "polysrv-default")

        // An explicit binding wins over the pending selection.
        store.setServer(id: PolySrvServers.telegramServerId, forAccount: accountId)
        XCTAssertEqual(store.server(forAccount: accountId)?.id, PolySrvServers.telegramServerId)
    }

    func testCustomServerCRUD() {
        let (store, _) = self.makeStore()
        let created = store.addCustomServer(name: "Test", host: "10.0.0.1", port: 1234, rsaPublicKey: "", multiDc: false, mainDcId: 2, dataCenters: [])
        XCTAssertTrue(store.isCustomServer(created.id))
        XCTAssertNotNil(store.server(id: created.id))

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
    }
}
