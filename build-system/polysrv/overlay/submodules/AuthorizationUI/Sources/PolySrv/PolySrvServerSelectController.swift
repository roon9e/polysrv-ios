import Foundation
import UIKit
import AsyncDisplayKit
import Display
import Network
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData

/// The node hosts a plain `UITableView`. Display's controllers are node-based,
/// so the table is wrapped rather than written as a node list: it is a small,
/// self-contained screen and this keeps it obviously correct.
private final class PolySrvServerSelectControllerNode: ASDisplayNode {
    private let theme: PresentationTheme

    let tableView: UITableView
    let cancelButton: UIButton
    private let header = UIView()
    private let titleLabel = UILabel()
    private let diagnosticLabel = UILabel()

    init(theme: PresentationTheme) {
        self.theme = theme
        self.tableView = UITableView(frame: .zero, style: .insetGrouped)
        self.cancelButton = UIButton(type: .system)
        super.init()
    }

    override func didLoad() {
        super.didLoad()

        self.view.backgroundColor = self.theme.list.plainBackgroundColor
        self.header.backgroundColor = self.theme.list.plainBackgroundColor

        self.titleLabel.text = "Servers"
        self.titleLabel.font = UIFont.systemFont(ofSize: 17.0, weight: .semibold)
        self.titleLabel.textColor = self.theme.list.itemPrimaryTextColor

        self.diagnosticLabel.font = UIFont.monospacedSystemFont(ofSize: 11.0, weight: .regular)
        self.diagnosticLabel.textColor = self.theme.list.itemSecondaryTextColor
        self.diagnosticLabel.textAlignment = .center
        self.diagnosticLabel.numberOfLines = 2

        self.cancelButton.setTitle("Cancel", for: .normal)
        self.cancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 17.0)

        self.header.addSubview(self.titleLabel)
        self.header.addSubview(self.cancelButton)
        self.view.addSubview(self.header)

        self.tableView.backgroundColor = self.theme.list.plainBackgroundColor
        self.view.addSubview(self.tableView)
    }

    func setDiagnostic(_ text: String) {
        self.diagnosticLabel.text = text
    }

    func updateLayout(size: CGSize, safeInsets: UIEdgeInsets) {
        let barHeight: CGFloat = 44.0
        let diagnosticHeight: CGFloat = self.diagnosticLabel.text?.isEmpty == false ? 30.0 : 0.0
        let headerHeight = safeInsets.top + barHeight + diagnosticHeight
        self.header.frame = CGRect(x: 0.0, y: 0.0, width: size.width, height: headerHeight)

        self.titleLabel.sizeToFit()
        self.titleLabel.frame = CGRect(
            x: floor((size.width - self.titleLabel.bounds.width) / 2.0),
            y: safeInsets.top + floor((barHeight - self.titleLabel.bounds.height) / 2.0),
            width: self.titleLabel.bounds.width,
            height: self.titleLabel.bounds.height
        )

        self.cancelButton.sizeToFit()
        self.cancelButton.frame = CGRect(
            x: 16.0,
            y: safeInsets.top + floor((barHeight - self.cancelButton.bounds.height) / 2.0),
            width: self.cancelButton.bounds.width,
            height: self.cancelButton.bounds.height
        )

        self.diagnosticLabel.frame = CGRect(x: 12.0, y: safeInsets.top + barHeight, width: size.width - 24.0, height: diagnosticHeight)

        self.tableView.frame = CGRect(x: 0.0, y: headerHeight, width: size.width, height: max(0.0, size.height - headerHeight))
    }
}

/// The pre-login server picker: one flat list in registry order (Telegram first,
/// then the servers published on gh-pages), each row with a logo, its endpoint
/// and a live TCP reachability check.
///
/// A Display `ViewController`, not a UIKit one: it is shown with
/// `presentOverlay`, and Display's `NavigationController` deliberately traps on
/// UIKit `present`. The list is refreshed from the published `servers.json` when
/// the screen appears, so a server added there shows up on a first build without
/// shipping a new one.
public final class PolySrvServerSelectController: ViewController, UITableViewDataSource, UITableViewDelegate {
    private var servers: [PolySrvServer]
    private let account: UnauthorizedAccount?
    private let theme: PresentationTheme
    private let onSelect: (PolySrvServer) -> Void
    private let onCancel: () -> Void

    private var statusByServerId: [String: String] = [:]
    private var diagnosticText: String = ""
    private var validLayout: ContainerViewLayout?
    private let statusDisposable = MetaDisposable()

    private var controllerNode: PolySrvServerSelectControllerNode {
        return self.displayNode as! PolySrvServerSelectControllerNode
    }

    public init(servers: [PolySrvServer], account: UnauthorizedAccount?, theme: PresentationTheme, onSelect: @escaping (PolySrvServer) -> Void, onCancel: @escaping () -> Void) {
        self.servers = servers
        self.account = account
        self.theme = theme
        self.onSelect = onSelect
        self.onCancel = onCancel
        super.init(navigationBarPresentationData: nil)
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
        node.cancelButton.addTarget(self, action: #selector(self.cancelPressed), for: .touchUpInside)
        self.displayNode = node
        self.displayNodeDidLoad()
    }

    public override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.validLayout = layout
        self.controllerNode.updateLayout(size: layout.size, safeInsets: layout.safeInsets)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // A diagnostic readout of the account's current server and live network
        // status: "net: connecting" forever means the transport/handshake never
        // completes; "net: online" means it did and the failure is above it.
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

        // Pull the published list so servers that are not bundled appear.
        PolySrvServers.shared.refreshRemote { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else {
                    return
                }
                self.servers = PolySrvServers.shared.allServers()
                self.controllerNode.tableView.reloadData()
                for server in self.servers {
                    self.ping(server)
                }
            }
        }

        for server in self.servers {
            self.ping(server)
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
        self.controllerNode.tableView.reloadData()
        if let layout = self.validLayout {
            self.controllerNode.updateLayout(size: layout.size, safeInsets: layout.safeInsets)
        }
    }

    @objc private func cancelPressed() {
        self.dismiss()
        self.onCancel()
    }

    // MARK: - Table

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.servers.count
    }

    public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if self.diagnosticText.isEmpty {
            return "Sign in to a server"
        }
        return "Sign in to a server\n" + self.diagnosticText
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let server = self.servers[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = server.name
        cell.textLabel?.textColor = self.theme.list.itemPrimaryTextColor
        cell.imageView?.image = self.logo(for: server)
        cell.imageView?.contentMode = .scaleAspectFit

        var detail = server.isTelegram ? "Official Telegram cloud" : server.endpoint
        if let status = self.statusByServerId[server.id] {
            detail += "  ·  " + status
        }
        cell.detailTextLabel?.text = detail
        cell.detailTextLabel?.textColor = self.theme.list.itemSecondaryTextColor
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let server = self.servers[indexPath.row]
        self.dismiss()
        self.onSelect(server)
    }

    // MARK: - Logos

    private func logo(for server: PolySrvServer) -> UIImage? {
        if server.isTelegram {
            let plane = UIImage(systemName: "paperplane.fill")
            return plane?.withTintColor(self.theme.list.itemAccentColor, renderingMode: .alwaysOriginal)
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
        let start = Date()
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
            let elapsed = Int(Date().timeIntervalSince(start) * 1000.0)
            DispatchQueue.main.async {
                guard let self = self else {
                    return
                }
                self.statusByServerId[server.id] = ok ? "\(elapsed) ms" : "unreachable"
                if let row = self.servers.firstIndex(where: { $0.id == server.id }) {
                    self.controllerNode.tableView.reloadRows(at: [IndexPath(row: row, section: 0)], with: .none)
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
