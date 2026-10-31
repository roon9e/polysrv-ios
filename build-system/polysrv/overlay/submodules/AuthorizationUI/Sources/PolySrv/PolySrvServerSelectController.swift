import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import AppBundle

/// What the picker needs from whoever presents it, because a deletion has to log
/// out the accounts that are bound to the server being deleted and that is a
/// decision only the presenter can take.
public struct PolySrvServerPickerEnvironment {
    /// Ask the user to confirm, running `action` if they do.
    public let confirmDeletion: (String, @escaping () -> Void) -> Void
    /// Log an account out, so its server can be removed.
    public let logOut: (AccountRecordId) -> Void
    /// Open the add/edit form. The presenter pushes it on top of the picker, so
    /// the form's back swipe returns here; `completion` gets the saved server, or
    /// nil when the form was cancelled.
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

    init(theme: PresentationTheme) {
        self.theme = theme
        self.tableView = UITableView(frame: .zero, style: .insetGrouped)
        super.init()
        self.tableView.contentInsetAdjustmentBehavior = .never
    }

    override func didLoad() {
        super.didLoad()

        // The app's block grey behind the list, so each section is one of the
        // app's white cards instead of white on white.
        self.view.backgroundColor = self.theme.list.blocksBackgroundColor
        self.tableView.backgroundColor = .clear
        self.view.addSubview(self.tableView)
    }

    /// The pushed controller's navigation bar supplies the title, the back button
    /// and the plus; the list simply starts below the bar.
    func updateLayout(size: CGSize, topInset: CGFloat) {
        self.tableView.frame = CGRect(x: 0.0, y: topInset, width: size.width, height: max(0.0, size.height - topInset))
    }
}

/// The server picker: the official cloud, the servers the user added, and the
/// servers published on gh-pages, each row with its own image, its endpoint and
/// the app's own connection state for the accounts that live on it. The
/// published ones are read-only; the user's own can be edited and deleted in
/// place.
///
/// A Display `ViewController`, pushed onto the presenter's navigation controller
/// like the app's own settings screens, so it has the app's navigation bar and
/// the interactive back swipe. The list is refreshed from the published
/// `servers.json` when the screen appears, so a server added there shows up on a
/// first build without shipping a new one.
public final class PolySrvServerSelectController: ViewController, UITableViewDataSource, UITableViewDelegate {
    private enum Section: Int, CaseIterable, Equatable {
        case telegram
        case custom
        case published
    }

    private var servers: [PolySrvServer]
    private let theme: PresentationTheme
    private let environment: PolySrvServerPickerEnvironment?
    private let sharedContext: SharedAccountContext?
    /// Whether picking a server pops the picker. The pre-login flow has the
    /// presenter replace it by setting the auth state instead, which a pop here
    /// would flash the splash before.
    private let dismissOnSelect: Bool
    private let onSelect: (PolySrvServer) -> Void

    private var visibleSections: [Section] = [.telegram, .custom]
    /// What the app's own network says about each server, for the accounts that
    /// are signed in to it. A TCP connect cannot tell a blocked server from a
    /// reachable one (the handshake completes either way), so the dot shows what
    /// the app itself is experiencing: online, still connecting, or no network.
    /// A server nobody is signed in to is grey, not green.
    private var connectionStatuses: [String: ConnectionStatus] = [:]
    private var validLayout: ContainerViewLayout?
    private let statusDisposable = MetaDisposable()

    private var controllerNode: PolySrvServerSelectControllerNode {
        return self.displayNode as! PolySrvServerSelectControllerNode
    }

    public init(servers: [PolySrvServer], theme: PresentationTheme, leftButtonTitle: String = "Back", dismissOnSelect: Bool = true, sharedContext: SharedAccountContext? = nil, environment: PolySrvServerPickerEnvironment? = nil, onSelect: @escaping (PolySrvServer) -> Void) {
        self.servers = servers
        self.theme = theme
        self.environment = environment
        self.sharedContext = sharedContext
        self.dismissOnSelect = dismissOnSelect
        self.onSelect = onSelect
        super.init(navigationBarPresentationData: NavigationBarPresentationData(theme: NavigationBarTheme(rootControllerTheme: theme), strings: NavigationBarStrings(back: leftButtonTitle, close: leftButtonTitle, more: "More")))
        self.title = "Servers"
    }

    public required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.statusDisposable.dispose()
    }

    public override func loadDisplayNode() {
        let node = PolySrvServerSelectControllerNode(theme: self.theme)
        node.tableView.dataSource = self
        node.tableView.delegate = self
        self.displayNode = node
        self.displayNodeDidLoad()

        // The app's navigation bar carries the title, the app's back button (and
        // the interactive back swipe) and the plus that adds a server.
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(image: PolySrvServerSelectController.barButtonImage(name: "plus", theme: self.theme), style: .plain, target: self, action: #selector(self.addPressed))
        self.navigationItem.rightBarButtonItem?.accessibilityLabel = "Add Server"

        if let sharedContext = self.sharedContext {
            self.statusDisposable.set((PolySrvServerSelectController.connectionStatuses(sharedContext: sharedContext)
            |> deliverOnMainQueue).start(next: { [weak self] statuses in
                guard let self = self else {
                    return
                }
                if self.connectionStatuses == statuses {
                    return
                }
                self.connectionStatuses = statuses
                self.controllerNode.tableView.reloadData()
            }))
        }
    }

    /// A bar button drawn in the colour the navigation bar uses for its own
    /// buttons. The bar only tints an item image it recognises as a template and
    /// an SF Symbol does not come through as one here, so the image would
    /// otherwise take the window's accent (blue); the colour is baked in instead.
    private static func barButtonImage(name: String, theme: PresentationTheme) -> UIImage? {
        let color = NavigationBarTheme(rootControllerTheme: theme).buttonColor
        return UIImage(systemName: name)?.withTintColor(color, renderingMode: .alwaysOriginal)
    }

    /// Per server, the connection state the app has for the account bound to it.
    /// Only accounts that are signed in to a server contribute: an unbound server
    /// has nothing to report and draws grey.
    private static func connectionStatuses(sharedContext: SharedAccountContext) -> Signal<[String: ConnectionStatus], NoError> {
        return sharedContext.activeAccountsWithInfo
        |> mapToSignal { value -> Signal<[String: ConnectionStatus], NoError> in
            var signals: [Signal<(String, ConnectionStatus), NoError>] = []
            for info in value.accounts {
                guard let server = PolySrvServers.shared.server(forAccount: info.account.id) else {
                    continue
                }
                let serverId = server.id
                signals.append(info.account.network.connectionStatus
                |> map { status in
                    return (serverId, status)
                })
            }
            if signals.isEmpty {
                return .single([:])
            }
            return combineLatest(signals)
            |> map { pairs -> [String: ConnectionStatus] in
                var result: [String: ConnectionStatus] = [:]
                for (serverId, status) in pairs {
                    result[serverId] = status
                }
                return result
            }
        }
    }

    public override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.validLayout = layout
        let navigationHeight = self.navigationLayout(layout: layout).navigationFrame.maxY
        self.controllerNode.updateLayout(size: layout.size, topInset: max(navigationHeight, layout.safeInsets.top))
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        self.reloadServers()

        // Pull the published list so servers that are not bundled appear, and so
        // ones that were withdrawn disappear.
        PolySrvServers.shared.refreshRemote { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else {
                    return
                }
                self.reloadServers()
            }
        }
    }

    // MARK: - List

    private func reloadServers() {
        self.servers = PolySrvServers.shared.allServers()
        self.visibleSections = [.telegram, .custom] + (self.publishedServers.isEmpty ? [] : [.published])
        self.controllerNode.tableView.reloadData()
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

    // MARK: - Actions

    @objc private func addPressed() {
        self.presentEdit(server: nil)
    }

    private func select(_ server: PolySrvServer) {
        // A pop here is right whenever someone else is not already replacing this
        // screen (the pre-login flow sets the auth state, which rebuilds the
        // stack and would then flash the splash behind a pop).
        if self.dismissOnSelect {
            self.dismiss()
        }
        self.onSelect(server)
    }

    private func presentEdit(server: PolySrvServer?) {
        // The presenter pushes the form on top of the picker, so the picker stays
        // beneath it and the form's back swipe returns here.
        let completion: (PolySrvServer?) -> Void = { [weak self] _ in
            guard let self = self else {
                return
            }
            self.reloadServers()
        }
        if let environment = self.environment {
            environment.presentEditor(server, completion)
        } else {
            let controller = PolySrvServerEditController(server: server, theme: self.theme, completion: { saved in
                completion(saved)
            })
            self.push(controller)
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
                return self.customServers.count
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

        guard let server = self.server(at: indexPath) else {
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
        // The connection dot replaces the disclosure arrow (setting accessoryType
        // after accessoryView would drop the custom view).
        cell.accessoryType = .none
        cell.accessoryView = PolySrvServerSelectController.connectionDot(
            status: self.connectionStatuses[server.id],
            theme: self.theme
        )
        return cell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let server = self.server(at: indexPath) else {
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
            // The real Telegram icon - white paper plane on a blue circle - from
            // the app's own app-icon assets (ThemeSettingsAppIconItem's lookup),
            // drawn into a circle at the same size as a custom server's avatar.
            if let logo = UIImage(named: "BlueFilledIcon", in: getAppBundle(), compatibleWith: nil) {
                return PolySrvServerSelectController.circularImage(logo, size: PolySrvServerSelectController.avatarSize)
            }
            if let logo = UIImage(bundleImageName: "Chat/Context Menu/Telegram") {
                return PolySrvServerSelectController.circularImage(logo, size: PolySrvServerSelectController.avatarSize)
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

    /// One avatar size for every row: a custom server's letter circle and the
    /// Telegram mark are the same size and shape.
    private static let avatarSize = CGSize(width: 36.0, height: 36.0)

    /// Draw any image into a circle of `size` (aspect-filled).
    private static func circularImage(_ image: UIImage, size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let rect = CGRect(origin: .zero, size: size)
            context.cgContext.addEllipse(in: rect)
            context.cgContext.clip()
            let scale = max(size.width / max(1.0, image.size.width), size.height / max(1.0, image.size.height))
            let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (size.width - drawSize.width) / 2.0, y: (size.height - drawSize.height) / 2.0, width: drawSize.width, height: drawSize.height))
        }
    }

    private static func avatarImage(initial: String) -> UIImage {
        let size = PolySrvServerSelectController.avatarSize
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

    /// The app's own connection state for a server: green when the account on it
    /// is online, amber while it is still connecting, red with no network, and
    /// grey when nobody is signed in to it and there is nothing to report.
    private static func connectionDot(status: ConnectionStatus?, theme: PresentationTheme) -> UIView {
        let size: CGFloat = 10.0
        let container = UIView(frame: CGRect(x: 0.0, y: 0.0, width: size + 16.0, height: size))
        let dot = UIView(frame: CGRect(x: 0.0, y: 0.0, width: size, height: size))
        dot.layer.cornerRadius = size / 2.0
        let color: UIColor
        switch status {
            case .none:
                color = theme.list.itemSecondaryTextColor
            case .some(.online):
                color = UIColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1.0)
            case .some(.connecting), .some(.updating):
                color = UIColor(red: 0.98, green: 0.68, blue: 0.18, alpha: 1.0)
            case .some(.waitingForNetwork):
                color = UIColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0)
        }
        dot.backgroundColor = color
        container.addSubview(dot)
        return container
    }
}
