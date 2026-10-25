import Foundation
import UIKit
import Network
import TelegramCore
import TelegramPresentationData

/// The pre-login server picker: one flat list in registry order (Telegram first,
/// then the servers published on gh-pages), each row with a logo, its endpoint
/// and a live TCP reachability check.
///
/// Deliberately a plain `UITableView` rather than a Display node: it is a small,
/// self-contained screen and standard UIKit is the least fragile way to build it.
///
/// The list is refreshed from the published `servers.json` when the screen
/// appears, so a server added there shows up on a first build without shipping a
/// new one. Selecting the official Telegram row binds the account to Telegram and
/// stops the picker appearing again.
public final class PolySrvServerSelectController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private var servers: [PolySrvServer]
    private let theme: PresentationTheme
    private let onSelect: (PolySrvServer) -> Void
    private let onCancel: () -> Void

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let loadingLabel = UILabel()
    private var statusByServerId: [String: String] = [:]
    private var isLoadingRemote = false

    public init(servers: [PolySrvServer], theme: PresentationTheme, onSelect: @escaping (PolySrvServer) -> Void, onCancel: @escaping () -> Void) {
        self.servers = servers
        self.theme = theme
        self.onSelect = onSelect
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    public required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        self.title = "Servers"
        self.view.backgroundColor = self.theme.list.plainBackgroundColor
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(self.cancelPressed))

        self.loadingLabel.text = "Loading servers…"
        self.loadingLabel.font = UIFont.systemFont(ofSize: 14.0)
        self.loadingLabel.textColor = self.theme.list.itemSecondaryTextColor
        self.loadingLabel.textAlignment = .center
        self.loadingLabel.frame = CGRect(x: 0.0, y: 0.0, width: self.view.bounds.width, height: 44.0)
        self.loadingLabel.isHidden = true
        self.tableView.tableFooterView = self.loadingLabel

        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.tableView.backgroundColor = self.theme.list.plainBackgroundColor
        self.tableView.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(self.tableView)
        NSLayoutConstraint.activate([
            self.tableView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            self.tableView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            self.tableView.topAnchor.constraint(equalTo: self.view.topAnchor),
            self.tableView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
        ])
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // Pull the published list so servers that are not bundled appear.
        self.isLoadingRemote = true
        self.loadingLabel.isHidden = false
        PolySrvServers.shared.refreshRemote { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else {
                    return
                }
                self.isLoadingRemote = false
                self.loadingLabel.isHidden = true
                self.servers = PolySrvServers.shared.allServers()
                self.tableView.reloadData()
                for server in self.servers {
                    self.ping(server)
                }
            }
        }

        for server in self.servers {
            self.ping(server)
        }
    }

    @objc private func cancelPressed() {
        self.onCancel()
    }

    // MARK: - Table

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.servers.count
    }

    public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return "Sign in to a server"
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
        self.onSelect(self.servers[indexPath.row])
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
        let start = Date()
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: server.port)) else {
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(server.host), port: port, using: .tcp)
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
                    self.tableView.reloadRows(at: [IndexPath(row: row, section: 0)], with: .none)
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
