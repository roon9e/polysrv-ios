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

    /// How many accounts this client may hold, desktop's policy:
    /// `min(premiumCount + 20, 50)`. The upstream 3-or-4 limit belongs to the
    /// official cloud, and on this client an account normally belongs to a
    /// different server, so it cannot be the client's own cap.
    public static let freeAccountCount = 20
    public static let premiumAccountCeiling = 50

    public static func maximumAccountCount(premiumCount: Int) -> Int {
        return min(premiumCount + PolySrvServers.freeAccountCount, PolySrvServers.premiumAccountCeiling)
    }

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
    /// Servers the published list no longer names but an account is still bound
    /// to. They stay resolvable - and visible - so such an account never falls
    /// back to the official cloud silently, and they go away once nothing is
    /// bound to them.
    private var retainedServers: [PolySrvServer] = []
    private var customServers: [PolySrvServer] = []
    private var bindings: [String: String] = [:]
    /// The address (`host:port`) each account's network was last built against.
    /// A change here is a server switch, and the network's persisted datacenter
    /// state must not be carried over to the new server.
    private var appliedScopes: [String: String] = [:]
    private var pendingServerId: String?
    /// The account a pending selection was chosen for. A selection with an owner
    /// is handed only to that account; one without an owner (a first run, before
    /// any account exists) may be handed to the first account that is built.
    private var pendingServerOwner: String?
    private var lastRemoteFetch: Date?
    /// The `me_url_prefix` the running account's server last broadcast.
    private var broadcastLinkPrefix: String?

    private let configKey = "polysrv.servers.config"
    private let configDateKey = "polysrv.servers.config.date"
    private let customKey = "polysrv.servers.custom"
    private let bindingsKey = "polysrv.servers.bindings"
    private let appliedScopesKey = "polysrv.servers.appliedScopes"
    private let retainedKey = "polysrv.servers.retained"
    private let pendingKey = "polysrv.servers.pending"
    private let pendingOwnerKey = "polysrv.servers.pendingOwner"
    private let broadcastLinkPrefixKey = "polysrv.servers.broadcastLinkPrefix"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.reload()
    }

    // MARK: - Loading

    private func reload() {
        self.lock.lock()
        defer { self.lock.unlock() }

        self.builtinServers = PolySrvServers.parseServers(Data(base64Encoded: polySrvDefaultServersJSONBase64))
        // A cached list is honoured even when it is empty: an emptied
        // servers.json is a real answer, not a failed fetch.
        if let cached = self.defaults.data(forKey: self.configKey), let config = PolySrvServers.parseServersConfig(cached) {
            self.remoteServers = config.servers
        } else {
            self.remoteServers = []
        }
        if let data = self.defaults.data(forKey: self.retainedKey) {
            self.retainedServers = (try? JSONDecoder().decode([PolySrvServer].self, from: data)) ?? []
        } else {
            self.retainedServers = []
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
        self.pendingServerOwner = self.defaults.string(forKey: self.pendingOwnerKey)
        self.lastRemoteFetch = self.defaults.object(forKey: self.configDateKey) as? Date
        self.broadcastLinkPrefix = self.defaults.string(forKey: self.broadcastLinkPrefixKey)
    }

    /// The decoded envelope, or nil when the bytes are not a server list at
    /// all. Distinguished from an empty list on purpose: a published
    /// `{"servers": []}` is an answer, and it has to be able to empty the list.
    private static func parseServersConfig(_ data: Data?) -> PolySrvServersConfig? {
        guard let data = data else {
            return nil
        }
        return try? JSONDecoder().decode(PolySrvServersConfig.self, from: data)
    }

    private static func parseServers(_ data: Data?) -> [PolySrvServer] {
        return PolySrvServers.parseServersConfig(data)?.servers ?? []
    }

    // MARK: - The list

    /// Built-in, then remote, then custom; first occurrence of an id wins.
    public func allServers() -> [PolySrvServer] {
        self.lock.lock()
        defer { self.lock.unlock() }

        var seen = Set<String>()
        var result: [PolySrvServer] = []
        for server in self.builtinServers + self.remoteServers + self.retainedServers + self.customServers {
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

    /// Whether the published list currently names this server. A server can be
    /// listed while not published: it is retained because an account is bound
    /// to it.
    public func isPublished(_ id: String) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.remoteServers.contains(where: { $0.id == id })
    }

    // MARK: - Per-account selection

    private func accountKey(_ id: AccountRecordId) -> String {
        return "\(id.int64)"
    }

    /// The server an account talks to, or nil for the official Telegram cloud.
    public func server(forAccount id: AccountRecordId) -> PolySrvServer? {
        self.lock.lock()
        let key = self.accountKey(id)
        let bound = self.bindings[key]
        let pending = self.pendingServerId
        let pendingOwner = self.pendingServerOwner
        self.lock.unlock()

        if let bound = bound, let server = self.server(id: bound) {
            return server
        }
        // A pending selection belongs only to the account it was chosen for (or
        // to the first account built, when it has no owner). Without that an
        // unrelated account - the official Telegram one - reads as the custom
        // server while a picker is open, and the scope change that follows wipes
        // its keys.
        if let pending = pending, pendingOwner == nil || pendingOwner == key, let server = self.server(id: pending) {
            return server
        }
        return nil
    }

    /// The scope an account's network is bound to, from its own binding only.
    /// `server(forAccount:)` also considers a pending selection, which is right
    /// when choosing a network and wrong for identity: two accounts that share a
    /// user id are two accounts exactly when their bound servers differ.
    public func boundScope(forAccount id: AccountRecordId) -> String {
        self.lock.lock()
        let bound = self.bindings[self.accountKey(id)]
        self.lock.unlock()
        return PolySrvServers.scope(for: bound.flatMap { self.server(id: $0) })
    }

    /// The name to group an account under, in the account lists. The official
    /// cloud is the built-in server's name, so a list reads "Telegram" / the
    /// custom server's name.
    public func boundServerName(forAccount id: AccountRecordId) -> String {
        self.lock.lock()
        let bound = self.bindings[self.accountKey(id)]
        self.lock.unlock()
        if let bound = bound, let server = self.server(id: bound) {
            return server.name
        }
        return self.allServers().first(where: { $0.isTelegram })?.name ?? "Telegram"
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
        let key = self.accountKey(accountId)
        guard self.bindings[key] == nil, let pending = self.pendingServerId else {
            self.lock.unlock()
            return
        }
        if let owner = self.pendingServerOwner, owner != key {
            self.lock.unlock()
            return
        }
        self.bindings[key] = pending
        self.pendingServerId = nil
        self.pendingServerOwner = nil
        self.defaults.set(try? JSONEncoder().encode(self.bindings), forKey: self.bindingsKey)
        self.defaults.removeObject(forKey: self.pendingKey)
        self.defaults.removeObject(forKey: self.pendingOwnerKey)
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

    // MARK: - The server's public URL

    /// The public URL prefix the server of the account in use broadcasts
    /// (`me_url_prefix` in `help.getConfig`). The official cloud sends its own
    /// t.me one; a private server sends one of its own or none at all.
    ///
    /// Only the account whose network is running is handed a config - the rest
    /// are paused - and that is the account on screen, so the last prefix stored
    /// is the one whose links are being looked at. It is kept across launches, so
    /// a link shown before the first config of a session still has a host.
    public func setBroadcastLinkPrefix(_ prefix: String) {
        self.lock.lock()
        self.broadcastLinkPrefix = prefix
        self.defaults.set(prefix, forKey: self.broadcastLinkPrefixKey)
        self.lock.unlock()
    }

    /// The host to build a link with, from what the server broadcast: "t.me" for
    /// the official cloud, the private server's own host when it names one, and
    /// nil when there is nothing to go on - the caller then keeps the host this
    /// build was branded with.
    public var broadcastLinkHost: String? {
        self.lock.lock()
        let prefix = self.broadcastLinkPrefix
        self.lock.unlock()
        return PolySrvServers.host(fromUrlPrefix: prefix)
    }

    /// The host part of a `me_url_prefix`. The field is a URL ("https://t.me/"),
    /// but a bare host, a scheme-less "t.me/" and a host with a port are accepted
    /// too, because a private server may write any of them.
    public static func host(fromUrlPrefix prefix: String?) -> String? {
        guard var value = prefix?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let range = value.range(of: "://") {
            value = String(value[range.upperBound...])
        }
        if let index = value.firstIndex(of: "/") {
            value = String(value[..<index])
        }
        if let index = value.firstIndex(of: ":") {
            value = String(value[..<index])
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return value.isEmpty ? nil : value
    }

    /// Bind a pending selection to the exact account it was chosen for, so it
    /// can never be handed to a different account that has no binding of its
    /// own (the official cloud's account, typically).
    public func setPendingServer(id: String, forAccount accountId: AccountRecordId) {
        self.lock.lock()
        self.pendingServerId = id
        self.pendingServerOwner = self.accountKey(accountId)
        self.defaults.set(id, forKey: self.pendingKey)
        self.defaults.set(self.pendingServerOwner, forKey: self.pendingOwnerKey)
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
            self.pendingServerOwner = nil
            self.defaults.removeObject(forKey: self.pendingOwnerKey)
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
    public func addCustomServer(name: String, description: String = "", host: String, port: Int, rsaPublicKey: String, multiDc: Bool, mainDcId: Int, restrictToTcp: Bool = true, logoPath: String = "", dataCenters: [PolySrvServerDataCenter] = []) -> PolySrvServer {
        let server = PolySrvServer(
            id: UUID().uuidString,
            name: name,
            description: description,
            host: host,
            port: port,
            rsaPublicKey: rsaPublicKey,
            isTelegram: false,
            isOfficial: false,
            multiDc: multiDc,
            mainDcId: mainDcId,
            restrictToTcp: restrictToTcp,
            logoPath: logoPath,
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

    /// Whether a server's address or key may still be edited. Changing either
    /// while an account is bound to it would point that account at a different
    /// server while it kept the keys and state it made for the old one - the
    /// handshake that never completes. Name, description and logo stay editable
    /// because none of them reaches the connection.
    public func canEditIdentity(of id: String) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return !self.bindings.values.contains(id)
    }

    /// The accounts bound to the server whose scope is `host:port`, for the
    /// confirmation a deletion needs.
    public func accountsBound(toScope scope: String) -> [AccountRecordId] {
        self.lock.lock()
        defer { self.lock.unlock() }
        var result: [AccountRecordId] = []
        for (key, id) in self.bindings {
            guard let server = self.serverLocked(id: id), PolySrvServers.scope(for: server) == scope, let value = Int64(key) else {
                continue
            }
            result.append(AccountRecordId(rawValue: value))
        }
        return result
    }

    /// Unbind an account, so a server it used cannot stay referenced by it.
    public func clearServer(forAccount accountId: AccountRecordId) {
        self.lock.lock()
        self.bindings.removeValue(forKey: self.accountKey(accountId))
        self.appliedScopes.removeValue(forKey: self.accountKey(accountId))
        self.defaults.set(try? JSONEncoder().encode(self.bindings), forKey: self.bindingsKey)
        self.defaults.set(try? JSONEncoder().encode(self.appliedScopes), forKey: self.appliedScopesKey)
        self.lock.unlock()
    }

    /// Drop the bindings of accounts that no longer exist, and any retained
    /// server nothing points at any more, so an unpublished server really does
    /// go away once the accounts that used it are gone.
    public func pruneAccounts(keeping accountIds: Set<AccountRecordId>) {
        self.lock.lock()
        defer { self.lock.unlock() }

        let keys = Set(accountIds.map { self.accountKey($0) })
        let stale = self.bindings.keys.filter { !keys.contains($0) }
        guard !stale.isEmpty else {
            return
        }
        for key in stale {
            self.bindings.removeValue(forKey: key)
            self.appliedScopes.removeValue(forKey: key)
        }
        self.defaults.set(try? JSONEncoder().encode(self.bindings), forKey: self.bindingsKey)
        self.defaults.set(try? JSONEncoder().encode(self.appliedScopes), forKey: self.appliedScopesKey)

        let boundIds = Set(self.bindings.values)
        let remaining = self.retainedServers.filter { boundIds.contains($0.id) }
        if remaining.count != self.retainedServers.count {
            self.retainedServers = remaining
            self.defaults.set(try? JSONEncoder().encode(remaining), forKey: self.retainedKey)
        }
    }

    private func serverLocked(id: String) -> PolySrvServer? {
        for server in self.builtinServers + self.remoteServers + self.retainedServers + self.customServers where server.id == id {
            return server
        }
        return nil
    }

    private func persistCustomServersLocked() {
        self.defaults.set(try? JSONEncoder().encode(self.customServers), forKey: self.customKey)
    }

    /// Install a published list without the network, so the retention rules can
    /// be exercised directly.
    func setRemoteServersForTesting(_ servers: [PolySrvServer]) {
        self.lock.lock()
        self.applyRemoteServersLocked(servers)
        self.lock.unlock()
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

    /// Replace the published list, carrying over the servers an account is
    /// still bound to that the list no longer names: dropping one would make
    /// `server(forAccount:)` resolve to nil and send that account to the
    /// official cloud.
    private func applyRemoteServersLocked(_ servers: [PolySrvServer]) {
        let fetchedIds = Set(servers.map { $0.id })
        let boundIds = Set(self.bindings.values)
        var retained: [PolySrvServer] = []
        var seen = Set<String>()
        for server in self.remoteServers + self.retainedServers where boundIds.contains(server.id) && !fetchedIds.contains(server.id) {
            if seen.insert(server.id).inserted {
                retained.append(server)
            }
        }
        self.remoteServers = servers
        self.retainedServers = retained
        self.defaults.set(try? JSONEncoder().encode(retained), forKey: self.retainedKey)
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
            // A valid envelope is accepted even when it names no servers: that
            // is how a server is unpublished. Only a failed request or bytes
            // that are not a list at all fall through to the fallback URL.
            if let data = data, let config = PolySrvServers.parseServersConfig(data) {
                self.lock.lock()
                self.applyRemoteServersLocked(config.servers)
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

/// The host a link should show, as the server itself declares it.
///
/// Upstream builds every link out of a literal ("https://t.me/…") and this fork's
/// branding sweep rewrites that literal to the brand host, so one build carried
/// one host for every server. The host a server broadcasts takes precedence
/// instead: the official cloud names t.me and a private server names its own (or
/// nothing). The labelled sites in apply_branding.py read it here and fall back
/// to the branded host when it is nil.
public enum PolySrvPublicLink {
    /// nil: the server named no public URL, so the caller keeps the host this
    /// build was branded with.
    public static var host: String? {
        return PolySrvServers.shared.broadcastLinkHost
    }
}
