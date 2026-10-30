import Foundation

/// Where the published server list lives.
public enum PolySrvRemote {
    public static let serversURL = "https://roon9e.github.io/polysrv-ios/servers.json"
    public static let serversFallbackURL = "https://raw.githubusercontent.com/roon9e/polysrv-ios/gh-pages/servers.json"
    /// How long a fetched list is trusted before it is fetched again.
    public static let cacheTTL: TimeInterval = 3600.0
}

/// The device's server registry. It merges, in order, the built-in list, the
/// cached remote list and the user's custom servers, and remembers which server
/// each account was signed in to.
///
/// It is deliberately process-wide (`shared`): `initializedNetwork` is a free
/// function in this module and reads the selection by account id, exactly as it
/// reads the datacenter id today. A selection for an account is a device-local
/// fact, like the proxy settings, not part of the account's own state.
public final class PolySrvServers {
    public static let shared = PolySrvServers()

    public static let telegramServerId = "telegram"

    /// The scope of a server is its address, `host:port`, so two entries that
    /// name different ports of one host stay apart, and the same `host:port`
    /// under two local ids is one scope. The official Telegram cloud is the one
    /// reserved scope, so an account moving to it is a scope change too.
    public static func scope(for server: PolySrvServer?) -> String {
        guard let server = server, !server.isTelegram else {
            return PolySrvServers.telegramServerId
        }
        return server.host.lowercased() + ":" + String(server.port)
    }

    private let defaults: UserDefaults
    private let lock = NSLock()

    private var builtinServers: [PolySrvServer] = []
    private var remoteServers: [PolySrvServer] = []
    private var customServers: [PolySrvServer] = []
    private var bindings: [String: String] = [:]
    /// The address (`host:port`) each account's network was last built against.
    /// A change here is a server switch, and the network's persisted datacenter
    /// state must not be carried over to the new server.
    private var appliedScopes: [String: String] = [:]
    private var pendingServerId: String?
    private var lastRemoteFetch: Date?

    private let configKey = "polysrv.servers.config"
    private let configDateKey = "polysrv.servers.config.date"
    private let customKey = "polysrv.servers.custom"
    private let bindingsKey = "polysrv.servers.bindings"
    private let appliedScopesKey = "polysrv.servers.appliedScopes"
    private let pendingKey = "polysrv.servers.pending"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.reload()
    }

    // MARK: - Loading

    private func reload() {
        self.lock.lock()
        defer { self.lock.unlock() }

        self.builtinServers = PolySrvServers.parseServers(Data(base64Encoded: polySrvDefaultServersJSONBase64))
        if let cached = self.defaults.data(forKey: self.configKey), !PolySrvServers.parseServers(cached).isEmpty {
            self.remoteServers = PolySrvServers.parseServers(cached)
        } else {
            self.remoteServers = []
        }
        if let data = self.defaults.data(forKey: self.customKey) {
            self.customServers = (try? JSONDecoder().decode([PolySrvServer].self, from: data)) ?? []
        } else {
            self.customServers = []
        }
        if let data = self.defaults.data(forKey: self.bindingsKey) {
            self.bindings = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        } else {
            self.bindings = [:]
        }
        if let data = self.defaults.data(forKey: self.appliedScopesKey) {
            self.appliedScopes = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        } else {
            self.appliedScopes = [:]
        }
        self.pendingServerId = self.defaults.string(forKey: self.pendingKey)
        self.lastRemoteFetch = self.defaults.object(forKey: self.configDateKey) as? Date
    }

    private static func parseServers(_ data: Data?) -> [PolySrvServer] {
        guard let data = data else {
            return []
        }
        if let config = try? JSONDecoder().decode(PolySrvServersConfig.self, from: data) {
            return config.servers
        }
        return []
    }

    // MARK: - The list

    /// Built-in, then remote, then custom; first occurrence of an id wins.
    public func allServers() -> [PolySrvServer] {
        self.lock.lock()
        defer { self.lock.unlock() }

        var seen = Set<String>()
        var result: [PolySrvServer] = []
        for server in self.builtinServers + self.remoteServers + self.customServers {
            if seen.insert(server.id).inserted {
                result.append(server)
            }
        }
        return result
    }

    public func server(id: String) -> PolySrvServer? {
        return self.allServers().first(where: { $0.id == id })
    }

    public func isCustomServer(_ id: String) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.customServers.contains(where: { $0.id == id })
    }

    // MARK: - Per-account selection

    private func accountKey(_ id: AccountRecordId) -> String {
        return "\(id.int64)"
    }

    /// The server an account talks to, or nil for the official Telegram cloud.
    public func server(forAccount id: AccountRecordId) -> PolySrvServer? {
        self.lock.lock()
        let bound = self.bindings[self.accountKey(id)]
        let pending = self.pendingServerId
        self.lock.unlock()

        if let bound = bound, let server = self.server(id: bound) {
            return server
        }
        if let pending = pending, let server = self.server(id: pending) {
            return server
        }
        return nil
    }

    public func setServer(id: String, forAccount accountId: AccountRecordId) {
        self.lock.lock()
        self.bindings[self.accountKey(accountId)] = id
        self.defaults.set(try? JSONEncoder().encode(self.bindings), forKey: self.bindingsKey)
        self.lock.unlock()
    }

    /// Bind the pending selection to an account that has no binding yet, and
    /// clear it, so a server chosen before the account was created sticks to
    /// exactly one account. Called when a network is built for the account:
    /// until this runs, `server(forAccount:)` would hand the pending value to
    /// every account that has no binding of its own.
    public func bindPendingIfNeeded(forAccount accountId: AccountRecordId) {
        self.lock.lock()
        guard self.bindings[self.accountKey(accountId)] == nil, let pending = self.pendingServerId else {
            self.lock.unlock()
            return
        }
        self.bindings[self.accountKey(accountId)] = pending
        self.pendingServerId = nil
        self.defaults.set(try? JSONEncoder().encode(self.bindings), forKey: self.bindingsKey)
        self.defaults.removeObject(forKey: self.pendingKey)
        self.lock.unlock()
    }

    /// The `host:port` the account's network was last built against, or nil
    /// before its first network. A network that finds a different scope must
    /// drop the previous server's persisted datacenter state.
    public func appliedScope(forAccount accountId: AccountRecordId) -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.appliedScopes[self.accountKey(accountId)]
    }

    public func setAppliedScope(_ scope: String, forAccount accountId: AccountRecordId) {
        self.lock.lock()
        self.appliedScopes[self.accountKey(accountId)] = scope
        self.defaults.set(try? JSONEncoder().encode(self.appliedScopes), forKey: self.appliedScopesKey)
        self.lock.unlock()
    }

    /// The server chosen before the first account exists. It is applied to an
    /// account until that account is bound explicitly.
    public var selectedServerIdForNextAccount: String? {
        get {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.pendingServerId
        }
        set {
            self.lock.lock()
            self.pendingServerId = newValue
            if let newValue = newValue {
                self.defaults.set(newValue, forKey: self.pendingKey)
            } else {
                self.defaults.removeObject(forKey: self.pendingKey)
            }
            self.lock.unlock()
        }
    }

    // MARK: - Custom servers

    @discardableResult
    public func addCustomServer(name: String, host: String, port: Int, rsaPublicKey: String, multiDc: Bool, mainDcId: Int, dataCenters: [PolySrvServerDataCenter]) -> PolySrvServer {
        let server = PolySrvServer(
            id: UUID().uuidString,
            name: name,
            host: host,
            port: port,
            rsaPublicKey: rsaPublicKey,
            isTelegram: false,
            isOfficial: false,
            multiDc: multiDc,
            mainDcId: mainDcId,
            dataCenters: dataCenters
        )
        self.lock.lock()
        self.customServers.append(server)
        self.persistCustomServersLocked()
        self.lock.unlock()
        return server
    }

    public func updateCustomServer(_ server: PolySrvServer) {
        self.lock.lock()
        if let index = self.customServers.firstIndex(where: { $0.id == server.id }) {
            self.customServers[index] = server
            self.persistCustomServersLocked()
        }
        self.lock.unlock()
    }

    public func removeCustomServer(id: String) {
        self.lock.lock()
        self.customServers.removeAll(where: { $0.id == id })
        self.persistCustomServersLocked()
        self.lock.unlock()
    }

    private func persistCustomServersLocked() {
        self.defaults.set(try? JSONEncoder().encode(self.customServers), forKey: self.customKey)
    }

    // MARK: - Remote list

    /// Fetch the published list if the cached one is older than the TTL. Best
    /// effort: a failure leaves the bundled + cached lists in place.
    public func refreshRemote(completion: (() -> Void)? = nil) {
        self.lock.lock()
        let last = self.lastRemoteFetch
        self.lock.unlock()
        if let last = last, Date().timeIntervalSince(last) < PolySrvRemote.cacheTTL {
            completion?()
            return
        }
        self.fetch(URL(string: PolySrvRemote.serversURL), fallback: true, completion: completion)
    }

    private func fetch(_ url: URL?, fallback: Bool, completion: (() -> Void)?) {
        guard let url = url else {
            completion?()
            return
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 5.0
        URLSession.shared.dataTask(with: request) { [weak self] data, _response, error in
            guard let self = self else {
                return
            }
            if let data = data, !PolySrvServers.parseServers(data).isEmpty {
                let servers = PolySrvServers.parseServers(data)
                self.lock.lock()
                self.remoteServers = servers
                self.lastRemoteFetch = Date()
                self.defaults.set(data, forKey: self.configKey)
                self.defaults.set(Date(), forKey: self.configDateKey)
                self.lock.unlock()
                completion?()
            } else if fallback {
                self.fetch(URL(string: PolySrvRemote.serversFallbackURL), fallback: false, completion: completion)
            } else {
                let _ = error
                completion?()
            }
        }.resume()
    }
}
