import Foundation
import UIKit
import AsyncDisplayKit
import Display
import Network
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import GlassBackgroundComponent

/// What the picker needs from whoever presents it, because a deletion has to log
/// out the accounts that are bound to the server being deleted and that is a
/// decision only the presenter can take.
public struct PolySrvServerPickerEnvironment {
    /// Ask the user to confirm, running `action` if they do.
    public let confirmDeletion: (String, @escaping () -> Void) -> Void
    /// Log an account out, so its server can be removed.
    public let logOut: (AccountRecordId) -> Void
    /// Open the add/edit form. The presenter shows it the way the app shows its
    /// own input screens (presented on the window, not dropped into an overlay),
    /// which is what gives it a keyboard; `completion` gets the saved server, or
    /// nil when the form was cancelled. The picker is dismissed before this is
    /// called and the presenter puts it back when the form closes.
    public let presentEditor: (PolySrvServer?, @escaping (PolySrvServer?) -> Void) -> Void

    public init(confirmDeletion: @escaping (String, @escaping () -> Void) -> Void, logOut: @escaping (AccountRecordId) -> Void, presentEditor: @escaping (PolySrvServer?, @escaping (PolySrvServer?) -> Void) -> Void) {
        self.confirmDeletion = confirmDeletion
        self.logOut = logOut
        self.presentEditor = presentEditor
    }
}

/// The node hosts a plain `UITableView`. Display's controllers are node-based,
/// so the table is wrapped rather than written as a node list: it is a small,
/// self-contained screen and this keeps it obviously correct.
private final class PolySrvServerSelectControllerNode: ASDisplayNode {
    private let theme: PresentationTheme

    let tableView: UITableView
    let leftButton: UIButton
    let addButton: UIButton
    private let header = UIView()
    private let barGlass = GlassBackgroundView()
    private let titleLabel = UILabel()
    private let diagnosticLabel = UILabel()

    init(theme: PresentationTheme, leftButtonTitle: String) {
        self.theme = theme
        self.tableView = UITableView(frame: .zero, style: .insetGrouped)
        self.leftButton = UIButton(type: .system)
        self.addButton = UIButton(type: .system)
        super.init()
        // A back chevron and a plus, like the rest of the app's navigation bars,
        // instead of the words "Cancel" and "Add".
        self.leftButton.setImage(UIImage(systemName: "chevron.backward"), for: .normal)
        self.leftButton.accessibilityLabel = leftButtonTitle
        self.addButton.setImage(UIImage(systemName: "plus"), for: .normal)
        self.addButton.accessibilityLabel = "Add"
    }

    override func didLoad() {
        super.didLoad()

        self.view.backgroundColor = self.theme.list.plainBackgroundColor
        self.header.backgroundColor = .clear

        self.view.addSubview(self.barGlass)
        self.view.addSubview(self.header)

        self.titleLabel.text = "Servers"
        self.titleLabel.font = UIFont.systemFont(ofSize: 17.0, weight: .semibold)
        self.titleLabel.textColor = self.theme.list.itemPrimaryTextColor

        self.diagnosticLabel.font = UIFont.monospacedSystemFont(ofSize: 11.0, weight: .regular)
        self.diagnosticLabel.textColor = self.theme.list.itemSecondaryTextColor
        self.diagnosticLabel.textAlignment = .center
        self.diagnosticLabel.numberOfLines = 2

        self.leftButton.tintColor = self.theme.list.itemAccentColor
        self.addButton.tintColor = self.theme.list.itemAccentColor

        self.header.addSubview(self.titleLabel)
        self.header.addSubview(self.leftButton)
        self.header.addSubview(self.addButton)
        self.header.addSubview(self.diagnosticLabel)

        self.tableView.backgroundColor = self.theme.list.plainBackgroundColor
        self.view.addSubview(self.tableView)
    }

    func setDiagnostic(_ text: String) {
        self.diagnosticLabel.text = text
    }

    func updateLayout(size: CGSize, topInset: CGFloat) {
        let barHeight: CGFloat = 44.0
        let diagnosticHeight: CGFloat = self.diagnosticLabel.text?.isEmpty == false ? 28.0 : 0.0
        let headerTop = topInset + 8.0
        let headerHeight = headerTop + barHeight + diagnosticHeight
        self.header.frame = CGRect(x: 0.0, y: 0.0, width: size.width, height: headerHeight)

        // A glass bar behind the navigation row.
        self.barGlass.frame = CGRect(x: 0.0, y: headerTop, width: size.width, height: barHeight)
        self.barGlass.update(size: CGSize(width: size.width, height: barHeight), cornerRadius: 0.0, isDark: self.traitCollection.userInterfaceStyle == .dark, tintColor: GlassBackgroundView.TintColor(kind: .panel), isInteractive: false, isVisible: true, transition: .immediate)

        let buttonSize: CGFloat = 44.0

        self.titleLabel.sizeToFit()
        self.titleLabel.frame = CGRect(
            x: floor((size.width - self.titleLabel.bounds.width) / 2.0),
            y: headerTop + floor((barHeight - self.titleLabel.bounds.height) / 2.0),
            width: self.titleLabel.bounds.width,
            height: self.titleLabel.bounds.height
        )

        self.leftButton.frame = CGRect(x: 8.0, y: headerTop, width: buttonSize, height: barHeight)
        self.addButton.frame = CGRect(x: size.width - buttonSize - 8.0, y: headerTop, width: buttonSize, height: barHeight)

        self.diagnosticLabel.frame = CGRect(x: 12.0, y: headerTop + barHeight, width: size.width - 24.0, height: diagnosticHeight)

        self.tableView.frame = CGRect(x: 0.0, y: headerHeight, width: size.width, height: max(0.0, size.height - headerHeight))
    }
}

/// The server picker: the official cloud, the servers the user added, and the
/// servers published on gh-pages, each row with its own image, its endpoint and
/// a live TCP reachability check. The published ones are read-only; the user's
/// own can be edited and deleted in place.
///
/// A Display `ViewController`, not a UIKit one: it is shown with
/// `presentOverlay`, and Display's `NavigationController` deliberately traps on
/// UIKit `present`. The list is refreshed from the published `servers.json` when
/// the screen appears, so a server added there shows up on a first build without
/// shipping a new one.
public final class PolySrvServerSelectController: ViewController, UITableViewDataSource, UITableViewDelegate {
    private enum Section: Int, CaseIterable, Equatable {
        case telegram
        case custom
        case published
    }

    private var servers: [PolySrvServer]
    private let account: UnauthorizedAccount?
    private let theme: PresentationTheme
    private let environment: PolySrvServerPickerEnvironment?
    private let onSelect: (PolySrvServer) -> Void
    private let onCancel: () -> Void
    private let leftButtonTitle: String

    private var visibleSections: [Section] = [.telegram, .custom]
    /// Whether each server was reachable on the last probe. A green or red dot,
    /// not a millisecond count: the TCP connect is answered by a local VPN/proxy
    /// when one is in use, so the number measured the tunnel, not the server.
    private var reachabilityByServerId: [String: Bool] = [:]
    private var diagnosticText: String = ""
    private var validLayout: ContainerViewLayout?
    private let statusDisposable = MetaDisposable()

    private var controllerNode: PolySrvServerSelectControllerNode {
        return self.displayNode as! PolySrvServerSelectControllerNode
    }

    public init(servers: [PolySrvServer], account: UnauthorizedAccount?, theme: PresentationTheme, leftButtonTitle: String = "Cancel", environment: PolySrvServerPickerEnvironment? = nil, onSelect: @escaping (PolySrvServer) -> Void, onCancel: @escaping () -> Void) {
        self.servers = servers
        self.account = account
        self.theme = theme
        self.environment = environment
        self.onSelect = onSelect
        self.onCancel = onCancel
        self.leftButtonTitle = leftButtonTitle
        super.init(navigationBarPresentationData: nil)
    }

    public required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.statusDisposable.dispose()
    }

    public override func loadDisplayNode() {
        let node = PolySrvServerSelectControllerNode(theme: self.theme, leftButtonTitle: self.leftButtonTitle)
        node.tableView.dataSource = self
        node.tableView.delegate = self
        node.leftButton.addTarget(self, action: #selector(self.leftPressed), for: .touchUpInside)
        node.addButton.addTarget(self, action: #selector(self.addPressed), for: .touchUpInside)
        self.displayNode = node
        self.displayNodeDidLoad()
    }

    public override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.validLayout = layout
        self.controllerNode.updateLayout(size: layout.size, topInset: max(layout.safeInsets.top, layout.statusBarHeight ?? 24.0))
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        self.reloadServers()
        self.updateDiagnostic()

        if let account = self.account {
            self.statusDisposable.set((account.network.connectionStatus
            |> deliverOnMainQueue).start(next: { [weak self] status in
                guard let self = self else {
                    return
                }
                self.updateDiagnostic(status: status)
            }))
        }

        // Pull the published list so servers that are not bundled appear, and so
        // ones that were withdrawn disappear.
        PolySrvServers.shared.refreshRemote { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else {
                    return
                }
                self.reloadServers()
                self.pingAll()
            }
        }

        self.pingAll()
    }

    // MARK: - List

    private func reloadServers() {
        self.servers = PolySrvServers.shared.allServers()
        self.visibleSections = [.telegram, .custom] + (self.publishedServers.isEmpty ? [] : [.published])
        self.controllerNode.tableView.reloadData()
    }

    private func pingAll() {
        for server in self.servers {
            self.ping(server)
        }
    }

    private var telegramServer: PolySrvServer? {
        return self.servers.first(where: { $0.isTelegram })
    }

    private var customServers: [PolySrvServer] {
        return self.servers.filter { PolySrvServers.shared.isCustomServer($0.id) }
    }

    /// Published but not the official cloud and not the user's own; a server the
    /// list dropped while an account used it shows up here too, marked.
    private var publishedServers: [PolySrvServer] {
        return self.servers.filter { !$0.isTelegram && !PolySrvServers.shared.isCustomServer($0.id) }
    }

    private func server(at indexPath: IndexPath) -> PolySrvServer? {
        guard indexPath.section < self.visibleSections.count else {
            return nil
        }
        switch self.visibleSections[indexPath.section] {
            case .telegram:
                return self.telegramServer
            case .custom:
                let servers = self.customServers
                return indexPath.row < servers.count ? servers[indexPath.row] : nil
            case .published:
                let servers = self.publishedServers
                return indexPath.row < servers.count ? servers[indexPath.row] : nil
        }
    }

    private func updateDiagnostic(status: ConnectionStatus? = nil) {
        var parts: [String] = []
        if let account = self.account, let server = PolySrvServers.shared.server(forAccount: account.id) {
            parts.append("\(server.id) · \(server.endpoint) · key \(server.rsaPublicKey.count) · \(server.multiDc ? "multi" : "locked")")
        } else {
            parts.append("no server bound")
        }
        if let status = status {
            switch status {
                case .waitingForNetwork:
                    parts.append("net: waiting")
                case .connecting:
                    parts.append("net: connecting")
                case .updating:
                    parts.append("net: updating")
                case .online:
                    parts.append("net: online")
            }
        }
        self.diagnosticText = parts.joined(separator: "\n")
        self.controllerNode.setDiagnostic(self.diagnosticText)
        if let layout = self.validLayout {
            self.controllerNode.updateLayout(size: layout.size, topInset: max(layout.safeInsets.top, layout.statusBarHeight ?? 24.0))
        }
    }

    // MARK: - Actions

    @objc private func leftPressed() {
        self.dismiss()
        self.onCancel()
    }

    @objc private func addPressed() {
        self.presentEdit(server: nil)
    }

    private func select(_ server: PolySrvServer) {
        self.dismiss()
        self.onSelect(server)
    }

    private func presentEdit(server: PolySrvServer?) {
        // Open the form through the presenter, on the window (the way the app's
        // own input screens are shown). The picker steps out of the way first;
        // the presenter restores it when the form closes.
        let completion: (PolySrvServer?) -> Void = { [weak self] _ in
            guard let self = self else {
                return
            }
            self.reloadServers()
            self.pingAll()
        }
        if let environment = self.environment {
            self.dismiss()
            environment.presentEditor(server, completion)
        } else {
            let controller = PolySrvServerEditController(server: server, theme: self.theme, completion: { saved in
                completion(saved)
            })
            self.presentInGlobalOverlay(controller)
        }
    }

    private func delete(_ server: PolySrvServer) {
        let scope = PolySrvServers.scope(for: server)
        let bound = PolySrvServers.shared.accountsBound(toScope: scope)

        let performDeletion: () -> Void = { [weak self] in
            guard let self = self else {
                return
            }
            for accountId in bound {
                self.environment?.logOut(accountId)
                PolySrvServers.shared.clearServer(forAccount: accountId)
            }
            PolySrvServers.shared.removeCustomServer(id: server.id)
            self.reloadServers()
        }

        if let environment = self.environment, !bound.isEmpty {
            let noun = bound.count == 1 ? "account" : "accounts"
            environment.confirmDeletion("Delete \(server.name)? \(bound.count) \(noun) signed in to it will be logged out.", performDeletion)
        } else if self.environment == nil, !bound.isEmpty {
            // No way to log the accounts out: refuse rather than delete a server
            // an account is still pointed at.
            Logger.shared.log("PolySRV", "refusing to delete \(server.id): \(bound.count) account(s) bound and no environment to log them out")
            return
        } else {
            performDeletion()
        }
    }

    // MARK: - Table

    public func numberOfSections(in tableView: UITableView) -> Int {
        return self.visibleSections.count
    }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard section < self.visibleSections.count else {
            return 0
        }
        switch self.visibleSections[section] {
            case .telegram:
                return self.telegramServer == nil ? 0 : 1
            case .custom:
                // One row per server, then the row that adds one.
                return self.customServers.count + 1
            case .published:
                return self.publishedServers.count
        }
    }

    public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard section < self.visibleSections.count else {
            return nil
        }
        switch self.visibleSections[section] {
            case .telegram:
                return "Official"
            case .custom:
                return "Your servers"
            case .published:
                return "Published"
        }
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.textColor = self.theme.list.itemPrimaryTextColor
        cell.detailTextLabel?.textColor = self.theme.list.itemSecondaryTextColor

        // The last row of the user's own section is the one that adds a server:
        // there is always somewhere to go when the list is empty.
        let isAddRow = indexPath.section < self.visibleSections.count
            && self.visibleSections[indexPath.section] == .custom
            && indexPath.row >= self.customServers.count
        guard !isAddRow, let server = self.server(at: indexPath) else {
            cell.textLabel?.text = "Add Server"
            cell.textLabel?.textColor = self.theme.list.itemAccentColor
            cell.detailTextLabel?.text = "Address, port and RSA key"
            cell.imageView?.image = UIImage(systemName: "plus.circle.fill")?.withTintColor(self.theme.list.itemAccentColor, renderingMode: .alwaysOriginal)
            cell.imageView?.contentMode = .scaleAspectFit
            cell.accessoryType = .disclosureIndicator
            return cell
        }

        cell.textLabel?.text = server.name
        cell.imageView?.image = self.logo(for: server)
        cell.imageView?.contentMode = .scaleAspectFit

        var detail = server.isTelegram ? "Official Telegram cloud" : server.endpoint
        if !server.isTelegram && !PolySrvServers.shared.isCustomServer(server.id) && !PolySrvServers.shared.isPublished(server.id) {
            detail += " · no longer published"
        }
        cell.detailTextLabel?.text = detail
        // The reachability dot replaces the disclosure arrow (setting accessoryType
        // after accessoryView would drop the custom view).
        cell.accessoryType = .none
        cell.accessoryView = PolySrvServerSelectController.reachabilityDot(
            reachable: self.reachabilityByServerId[server.id],
            theme: self.theme
        )
        return cell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let server = self.server(at: indexPath) else {
            self.presentEdit(server: nil)
            return
        }
        self.select(server)
    }

    public func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let server = self.server(at: indexPath), PolySrvServers.shared.isCustomServer(server.id) else {
            // The official cloud and the published servers are read-only.
            return nil
        }
        let edit = UIContextualAction(style: .normal, title: "Edit", handler: { [weak self] _, _, completion in
            self?.presentEdit(server: server)
            completion(true)
        })
        let delete = UIContextualAction(style: .destructive, title: "Delete", handler: { [weak self] _, _, completion in
            self?.delete(server)
            completion(true)
        })
        return UISwipeActionsConfiguration(actions: [delete, edit])
    }

    // MARK: - Logos

    private func logo(for server: PolySrvServer) -> UIImage? {
        if server.isTelegram {
            // The app's own Telegram mark, not an SF Symbol. (Falls back to the
            // symbol if the asset is ever unavailable.)
            if let logo = UIImage(bundleImageName: "Chat/Context Menu/Telegram") {
                return logo
            }
            let plane = UIImage(systemName: "paperplane.fill")
            return plane?.withTintColor(self.theme.list.itemAccentColor, renderingMode: .alwaysOriginal)
        }
        if !server.logoPath.isEmpty, let image = UIImage(contentsOfFile: server.logoPath) {
            return image
        }
        let initial = server.name.first.map { String($0).uppercased() } ?? "?"
        return PolySrvServerSelectController.avatarImage(initial: initial)
    }

    /// A deterministic coloured circle with the server's initial, matching the
    /// desktop/Android fallback for a server without a logo.
    private static let avatarColors: [UIColor] = [
        UIColor(red: 0.36, green: 0.55, blue: 0.94, alpha: 1.0),
        UIColor(red: 0.91, green: 0.45, blue: 0.32, alpha: 1.0),
        UIColor(red: 0.29, green: 0.68, blue: 0.55, alpha: 1.0),
        UIColor(red: 0.60, green: 0.45, blue: 0.86, alpha: 1.0),
        UIColor(red: 0.85, green: 0.62, blue: 0.25, alpha: 1.0),
        UIColor(red: 0.84, green: 0.36, blue: 0.52, alpha: 1.0),
        UIColor(red: 0.35, green: 0.62, blue: 0.78, alpha: 1.0),
    ]

    private static func avatarImage(initial: String) -> UIImage {
        let size = CGSize(width: 36.0, height: 36.0)
        var hash: UInt64 = 1469598103934665603
        for byte in initial.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        let color = avatarColors[Int(hash % UInt64(avatarColors.count))]
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            color.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 17.0, weight: .semibold),
                .foregroundColor: UIColor.white,
            ]
            let text = initial as NSString
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2.0, y: (size.height - textSize.height) / 2.0), withAttributes: attributes)
        }
    }

    /// A small reachability dot: green when the last probe connected, red when it
    /// did not, grey before the first probe.
    private static func reachabilityDot(reachable: Bool?, theme: PresentationTheme) -> UIView {
        let size: CGFloat = 10.0
        let container = UIView(frame: CGRect(x: 0.0, y: 0.0, width: size + 16.0, height: size))
        let dot = UIView(frame: CGRect(x: 0.0, y: 0.0, width: size, height: size))
        dot.layer.cornerRadius = size / 2.0
        dot.backgroundColor = reachable == nil ? theme.list.itemSecondaryTextColor : (reachable == true ? UIColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1.0) : UIColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0))
        container.addSubview(dot)
        return container
    }

    // MARK: - Ping

    private func ping(_ server: PolySrvServer) {
        // For the official cloud, probe a known datacenter so the row shows whether
        // this device can reach Telegram at all (a system VPN may or may not route
        // it); a custom server is probed at its own address.
        let host: String
        let port: Int
        if server.isTelegram {
            host = "149.154.167.50"
            port = 443
        } else {
            host = server.host
            port = server.port
        }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "polysrv.ping")
        var finished = false
        let finish: (Bool) -> Void = { [weak self] ok in
            if finished {
                return
            }
            finished = true
            connection.cancel()
            DispatchQueue.main.async {
                guard let self = self else {
                    return
                }
                self.reachabilityByServerId[server.id] = ok
                for (section, kind) in self.visibleSections.enumerated() {
                    let row: Int?
                    switch kind {
                        case .telegram:
                            row = self.telegramServer?.id == server.id ? 0 : nil
                        case .custom:
                            row = self.customServers.firstIndex(where: { $0.id == server.id })
                        case .published:
                            row = self.publishedServers.firstIndex(where: { $0.id == server.id })
                    }
                    if let row = row {
                        let indexPath = IndexPath(row: row, section: section)
                        if indexPath.section < self.controllerNode.tableView.numberOfSections, indexPath.row < self.controllerNode.tableView.numberOfRows(inSection: indexPath.section) {
                            self.controllerNode.tableView.reloadRows(at: [indexPath], with: .none)
                            return
                        }
                    }
                }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3.0) {
            finish(false)
        }
    }
}
