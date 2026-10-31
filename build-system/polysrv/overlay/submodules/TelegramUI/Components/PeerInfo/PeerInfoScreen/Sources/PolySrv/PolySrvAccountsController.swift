import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext

/// One group of accounts: a server and the accounts bound to it.
private struct PolySrvAccountsGroup {
    let name: String
    let isTelegram: Bool
    var accounts: [AccountWithInfo]
}

private final class PolySrvAccountsControllerNode: ASDisplayNode {
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

        // The app's block grey behind the list, so each server's group is its own
        // white card instead of white on white.
        self.view.backgroundColor = self.theme.list.blocksBackgroundColor
        self.tableView.backgroundColor = .clear
        self.view.addSubview(self.tableView)
    }

    // The app's navigation bar (the screen is pushed into a NavigationController)
    // supplies the title and the back button; the list simply starts below it.
    func updateLayout(size: CGSize, topInset: CGFloat) {
        self.tableView.frame = CGRect(x: 0.0, y: topInset, width: size.width, height: max(0.0, size.height - topInset))
    }
}

/// Every account this client holds, from every server, grouped by server under
/// the server's name. The native Settings list shows the same grouping; this is
/// the single screen that always lists them all and switches between them, so
/// an account on another server is never unreachable.
public final class PolySrvAccountsController: ViewController, UITableViewDataSource, UITableViewDelegate {
    private let context: AccountContext
    private var groups: [PolySrvAccountsGroup] = []
    private var primaryId: AccountRecordId?
    private var validLayout: ContainerViewLayout?
    private let disposable = MetaDisposable()

    private var controllerNode: PolySrvAccountsControllerNode {
        return self.displayNode as! PolySrvAccountsControllerNode
    }

    public init(context: AccountContext) {
        self.context = context
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(theme: NavigationBarTheme(rootControllerTheme: presentationData.theme), strings: NavigationBarStrings(presentationStrings: presentationData.strings)))
        self.title = "Accounts"
    }

    public required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.disposable.dispose()
    }

    public override func loadDisplayNode() {
        let node = PolySrvAccountsControllerNode(theme: self.context.sharedContext.currentPresentationData.with { $0 }.theme)
        node.tableView.dataSource = self
        node.tableView.delegate = self
        self.displayNode = node
        self.displayNodeDidLoad()
    }

    public override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.validLayout = layout
        let navigationHeight = self.navigationLayout(layout: layout).navigationFrame.maxY
        self.controllerNode.updateLayout(size: layout.size, topInset: max(navigationHeight, layout.safeInsets.top))
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        self.disposable.set((self.context.sharedContext.activeAccountsWithInfo
        |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self = self else {
                return
            }
            self.primaryId = value.primary
            self.groups = PolySrvAccountsController.groups(for: value.accounts)
            self.controllerNode.tableView.reloadData()
        }))
    }

    private static func groups(for accounts: [AccountWithInfo]) -> [PolySrvAccountsGroup] {
        var groups: [PolySrvAccountsGroup] = []
        for info in accounts {
            let isTelegram = PolySrvServers.shared.boundScope(forAccount: info.account.id) == PolySrvServers.telegramServerId
            let name = PolySrvServers.shared.boundServerName(forAccount: info.account.id)
            if let index = groups.firstIndex(where: { $0.name == name && $0.isTelegram == isTelegram }) {
                groups[index].accounts.append(info)
            } else {
                groups.append(PolySrvAccountsGroup(name: name, isTelegram: isTelegram, accounts: [info]))
            }
        }
        groups.sort { lhs, rhs in
            if lhs.isTelegram != rhs.isTelegram {
                return lhs.isTelegram
            }
            return lhs.name < rhs.name
        }
        return groups
    }

    // MARK: - Table

    public func numberOfSections(in tableView: UITableView) -> Int {
        return self.groups.count + 1
    }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == self.groups.count {
            return 1
        }
        return self.groups[section].accounts.count
    }

    public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == self.groups.count {
            return nil
        }
        return self.groups[section].name
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.textColor = presentationData.theme.list.itemPrimaryTextColor
        cell.detailTextLabel?.textColor = presentationData.theme.list.itemSecondaryTextColor

        // The last section is the row that adds an account.
        if indexPath.section == self.groups.count {
            cell.textLabel?.text = "Add Account"
            cell.textLabel?.textColor = presentationData.theme.list.itemAccentColor
            cell.detailTextLabel?.text = "Choose a server"
            cell.accessoryType = .disclosureIndicator
            return cell
        }

        let info = self.groups[indexPath.section].accounts[indexPath.row]
        cell.textLabel?.text = info.peer.compactDisplayTitle
        cell.detailTextLabel?.text = info.peer.addressName.flatMap { "@\($0)" } ?? ""
        cell.accessoryType = info.account.id == self.primaryId ? .checkmark : .disclosureIndicator
        return cell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        if indexPath.section == self.groups.count {
            // The same cap as everywhere else: min(premium + 20, 50), not the
            // official cloud's 3-or-4.
            let accounts = self.groups.flatMap { $0.accounts }
            let premiumCount = accounts.filter { $0.peer.isPremium }.count
            let totalCount = accounts.count + (self.primaryId != nil ? 1 : 0)
            guard totalCount < PolySrvServers.maximumAccountCount(premiumCount: premiumCount) else {
                return
            }
            self.context.sharedContext.beginNewAuth(testingEnvironment: self.context.account.testingEnvironment)
            self.dismiss()
            return
        }

        let info = self.groups[indexPath.section].accounts[indexPath.row]
        if info.account.id == self.primaryId {
            self.dismiss()
            return
        }
        self.context.sharedContext.switchToAccount(id: info.account.id, fromSettingsController: nil, withChatListController: nil)
        self.dismiss()
    }

    public func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section < self.groups.count else {
            return nil
        }
        let info = self.groups[indexPath.section].accounts[indexPath.row]
        guard info.account.id != self.primaryId else {
            return nil
        }
        let logout = UIContextualAction(style: .destructive, title: "Log Out", handler: { [weak self] _, _, completion in
            guard let self = self else {
                completion(false)
                return
            }
            let _ = logoutFromAccount(id: info.account.id, accountManager: self.context.sharedContext.accountManager, alreadyLoggedOutRemotely: false).startStandalone()
            completion(true)
        })
        return UISwipeActionsConfiguration(actions: [logout])
    }

    @objc private func closePressed() {
        self.dismiss()
    }
}
