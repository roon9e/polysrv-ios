import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import TelegramPresentationData

/// One labelled text field. The rows are plain views laid out by hand rather
/// than cells: the form is a fixed list, so there is nothing for a table's reuse
/// to buy, and a row that lays itself out cannot double-add its field. A row
/// draws no surface of its own; the card it belongs to is the box.
private final class PolySrvServerEditFieldRow: UIView {
    let label = UILabel()
    let field = UITextField()

    init(title: String, keyboard: UIKeyboardType) {
        super.init(frame: .zero)
        self.label.text = title
        self.label.font = UIFont.systemFont(ofSize: 17.0)
        self.field.font = UIFont.systemFont(ofSize: 17.0)
        self.field.autocorrectionType = .no
        self.field.autocapitalizationType = .none
        self.field.keyboardType = keyboard
        self.addSubview(self.label)
        self.addSubview(self.field)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let labelWidth: CGFloat = 118.0
        self.label.frame = CGRect(x: 16.0, y: 0.0, width: labelWidth, height: self.bounds.height)
        self.field.frame = CGRect(x: 16.0 + labelWidth, y: 0.0, width: max(0.0, self.bounds.width - labelWidth - 32.0), height: self.bounds.height)
    }
}

/// The RSA public key: it is a PEM, pasted rather than typed. Its text area keeps
/// a visible field surface of its own, because the whole box is much taller than
/// a row and an empty one would otherwise read as blank card.
private final class PolySrvServerEditKeyRow: UIView {
    let label = UILabel()
    let textView = UITextView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.label.text = "RSA key"
        self.label.font = UIFont.systemFont(ofSize: 17.0)
        self.textView.font = UIFont.monospacedSystemFont(ofSize: 13.0, weight: .regular)
        self.textView.autocorrectionType = .no
        self.textView.autocapitalizationType = .none
        self.textView.backgroundColor = .clear
        self.addSubview(self.label)
        self.addSubview(self.textView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.label.frame = CGRect(x: 16.0, y: 0.0, width: max(0.0, self.bounds.width - 32.0), height: 34.0)
        self.textView.frame = CGRect(x: 12.0, y: 34.0, width: max(0.0, self.bounds.width - 24.0), height: max(0.0, self.bounds.height - 40.0))
    }
}

private final class PolySrvServerEditSwitchRow: UIView {
    let label = UILabel()
    let toggle = UISwitch()

    init(title: String) {
        super.init(frame: .zero)
        self.label.text = title
        self.label.font = UIFont.systemFont(ofSize: 17.0)
        self.addSubview(self.label)
        self.addSubview(self.toggle)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.label.frame = CGRect(x: 16.0, y: 0.0, width: max(0.0, self.bounds.width - 90.0), height: self.bounds.height)
        self.toggle.frame = CGRect(x: self.bounds.width - self.toggle.bounds.width - 16.0, y: floor((self.bounds.height - self.toggle.bounds.height) / 2.0), width: self.toggle.bounds.width, height: self.toggle.bounds.height)
    }
}

private final class PolySrvServerEditControllerNode: ASDisplayNode {
    private let theme: PresentationTheme
    private let identityLocked: Bool

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let messageLabel = UILabel()

    let nameRow = PolySrvServerEditFieldRow(title: "Name", keyboard: .default)
    let descriptionRow = PolySrvServerEditFieldRow(title: "Description", keyboard: .default)
    let hostRow = PolySrvServerEditFieldRow(title: "Address", keyboard: .URL)
    let portRow = PolySrvServerEditFieldRow(title: "Port", keyboard: .numberPad)
    let mainDcRow = PolySrvServerEditFieldRow(title: "Main DC", keyboard: .numberPad)
    let keyRow = PolySrvServerEditKeyRow(frame: .zero)
    let multiDcRow = PolySrvServerEditSwitchRow(title: "Multi-datacenter")

    /// The form's rows, grouped into the blocks the page draws: the rows of one
    /// group share a card, with hairline separators between them.
    private var cards: [(card: UIView, rows: [UIView], separators: [UIView])] = []

    init(theme: PresentationTheme, identityLocked: Bool) {
        self.theme = theme
        self.identityLocked = identityLocked
        super.init()
    }

    override func didLoad() {
        super.didLoad()

        // The app's block grey behind the form, so each card is a visible box.
        self.view.backgroundColor = self.theme.list.blocksBackgroundColor
        self.scrollView.backgroundColor = .clear
        self.scrollView.contentInsetAdjustmentBehavior = .never
        self.contentView.backgroundColor = .clear

        self.messageLabel.font = UIFont.systemFont(ofSize: 13.0)
        self.messageLabel.numberOfLines = 0
        self.messageLabel.textColor = self.theme.list.itemSecondaryTextColor
        if self.identityLocked {
            self.messageLabel.text = "An account is signed in to this server, so its address and key cannot be changed."
        }

        self.nameRow.field.placeholder = "Name"
        self.descriptionRow.field.placeholder = "Optional"
        self.hostRow.field.placeholder = "example.com"
        self.portRow.field.placeholder = "443"
        self.mainDcRow.field.placeholder = "2"

        // The tall key area keeps a field surface of its own, in the block grey
        // that contrasts with the card it sits on.
        self.keyRow.textView.backgroundColor = self.theme.list.blocksBackgroundColor
        self.keyRow.textView.layer.cornerRadius = 8.0
        self.keyRow.textView.clipsToBounds = true

        for row in [self.nameRow, self.descriptionRow, self.hostRow, self.portRow, self.mainDcRow] {
            row.label.textColor = self.theme.list.itemPrimaryTextColor
            row.field.textColor = self.theme.list.itemPrimaryTextColor
        }
        self.keyRow.label.textColor = self.theme.list.itemPrimaryTextColor
        self.keyRow.textView.textColor = self.theme.list.itemPrimaryTextColor
        self.multiDcRow.label.textColor = self.theme.list.itemPrimaryTextColor

        // An account's keys were made for the address it was bound to; moving
        // either under it is the handshake that never completes.
        self.hostRow.field.isEnabled = !self.identityLocked
        self.portRow.field.isEnabled = !self.identityLocked
        self.keyRow.textView.isEditable = !self.identityLocked
        self.mainDcRow.field.isEnabled = !self.multiDcRow.toggle.isOn
        self.multiDcRow.toggle.addTarget(self, action: #selector(self.multiDcChanged), for: .valueChanged)

        self.view.addSubview(self.scrollView)
        self.scrollView.addSubview(self.contentView)
        self.contentView.addSubview(self.messageLabel)

        let groups: [[UIView]] = [
            [self.nameRow, self.descriptionRow],
            [self.hostRow, self.portRow, self.mainDcRow],
            [self.keyRow],
            [self.multiDcRow],
        ]
        for group in groups {
            let card = UIView()
            card.backgroundColor = self.theme.list.itemBlocksBackgroundColor
            card.layer.cornerRadius = 12.0
            card.clipsToBounds = true
            var separators: [UIView] = []
            for (index, row) in group.enumerated() {
                row.backgroundColor = .clear
                card.addSubview(row)
                if index != 0 {
                    let separator = UIView()
                    separator.backgroundColor = self.theme.list.itemBlocksSeparatorColor
                    card.addSubview(separator)
                    separators.append(separator)
                }
            }
            self.cards.append((card: card, rows: group, separators: separators))
            self.contentView.addSubview(card)
        }
    }

    func apply(server: PolySrvServer?) {
        guard let server = server else {
            self.portRow.field.text = "443"
            self.mainDcRow.field.text = "2"
            return
        }
        self.nameRow.field.text = server.name
        self.descriptionRow.field.text = server.description
        self.hostRow.field.text = server.host
        self.portRow.field.text = String(server.port)
        self.mainDcRow.field.text = String(server.mainDcId)
        self.keyRow.textView.text = server.rsaPublicKey
        self.multiDcRow.toggle.isOn = server.multiDc
        self.mainDcRow.field.isEnabled = !server.multiDc && !self.identityLocked
    }

    /// The form's message line: the identity lock, or the reason a save was
    /// refused. Kept in the form so no alert has to be threaded through.
    func setMessage(_ text: String, isError: Bool) {
        self.messageLabel.text = text
        self.messageLabel.textColor = isError ? self.theme.list.itemDestructiveColor : self.theme.list.itemSecondaryTextColor
    }

    @objc private func multiDcChanged() {
        self.mainDcRow.field.isEnabled = !self.multiDcRow.toggle.isOn && !self.identityLocked
    }

    func updateLayout(size: CGSize, topInset: CGFloat, bottomInset: CGFloat) {
        self.scrollView.frame = CGRect(x: 0.0, y: topInset, width: size.width, height: max(0.0, size.height - topInset))
        self.scrollView.contentInset = UIEdgeInsets(top: 0.0, left: 0.0, bottom: bottomInset, right: 0.0)

        let rowInset: CGFloat = 16.0
        let cardWidth = max(0.0, size.width - rowInset * 2.0)
        var y: CGFloat = 12.0

        let messageHeight: CGFloat = self.messageLabel.text?.isEmpty == false ? 40.0 : 0.0
        if messageHeight > 0.0 {
            self.messageLabel.frame = CGRect(x: rowInset + 4.0, y: y, width: max(0.0, size.width - (rowInset + 4.0) * 2.0), height: messageHeight)
            y = self.messageLabel.frame.maxY + 4.0
        } else {
            self.messageLabel.frame = .zero
        }

        let separatorHeight: CGFloat = 1.0 / max(1.0, UIScreen.main.scale)
        for card in self.cards {
            var rowFrames: [CGRect] = []
            var cardHeight: CGFloat = 0.0
            for row in card.rows {
                let height: CGFloat = row === self.keyRow ? 210.0 : 44.0
                rowFrames.append(CGRect(x: 0.0, y: cardHeight, width: cardWidth, height: height))
                cardHeight += height
            }
            card.card.frame = CGRect(x: rowInset, y: y, width: cardWidth, height: cardHeight)
            for (index, row) in card.rows.enumerated() {
                row.frame = rowFrames[index]
            }
            for (index, separator) in card.separators.enumerated() {
                separator.frame = CGRect(x: rowInset, y: rowFrames[index].maxY, width: max(0.0, cardWidth - rowInset), height: separatorHeight)
            }
            y = card.card.frame.maxY + 16.0
        }

        y += 8.0
        self.contentView.frame = CGRect(x: 0.0, y: 0.0, width: size.width, height: y)
        self.scrollView.contentSize = CGSize(width: size.width, height: y)
    }
}

/// The add/edit form for a custom server: desktop's server box, field for field.
/// The picker pushes it on top of itself; a save writes through `PolySrvServers`
/// and hands the saved record back so the list can be rebuilt.
public final class PolySrvServerEditController: ViewController {
    private let server: PolySrvServer?
    private let theme: PresentationTheme
    /// The saved server, or nil when the form was cancelled.
    private let completion: (PolySrvServer?) -> Void

    private var controllerNode: PolySrvServerEditControllerNode {
        return self.displayNode as! PolySrvServerEditControllerNode
    }

    public init(server: PolySrvServer?, theme: PresentationTheme, completion: @escaping (PolySrvServer?) -> Void) {
        self.server = server
        self.theme = theme
        self.completion = completion
        super.init(navigationBarPresentationData: NavigationBarPresentationData(theme: NavigationBarTheme(rootControllerTheme: theme), strings: NavigationBarStrings(back: "Back", close: "Cancel", more: "More")))
        self.title = server == nil ? "Add Server" : "Edit Server"
    }

    public required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadDisplayNode() {
        let identityLocked = self.server.map { !PolySrvServers.shared.canEditIdentity(of: $0.id) } ?? false
        let node = PolySrvServerEditControllerNode(theme: self.theme, identityLocked: identityLocked)
        self.displayNode = node
        node.apply(server: self.server)
        self.displayNodeDidLoad()

        // The app's navigation bar carries the title, the app's back button (and
        // the interactive back swipe, which cancels) and the check that saves.
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "checkmark"), style: .plain, target: self, action: #selector(self.savePressed))
        self.navigationItem.rightBarButtonItem?.accessibilityLabel = "Save"
    }

    public override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let navigationHeight = self.navigationLayout(layout: layout).navigationFrame.maxY
        // Display reports the keyboard as the layout's input height, not in the
        // safe insets, so the form's scroll view is inset by it and the focused
        // field can be brought above the keyboard.
        let bottomInset = max(layout.inputHeight ?? 0.0, layout.safeInsets.bottom)
        self.controllerNode.updateLayout(size: layout.size, topInset: max(navigationHeight, layout.safeInsets.top), bottomInset: bottomInset)
    }

    @objc private func savePressed() {
        let node = self.controllerNode
        let name = node.nameRow.field.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = node.descriptionRow.field.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let host = node.hostRow.field.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let port = Int(node.portRow.field.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        let mainDc = Int(node.mainDcRow.field.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        let multiDc = node.multiDcRow.toggle.isOn
        let key = node.keyRow.textView.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if name.isEmpty {
            node.setMessage("A server needs a name.", isError: true)
            return
        }
        if host.isEmpty {
            node.setMessage("A server needs an address.", isError: true)
            return
        }
        if port < 1 || port > 65535 {
            node.setMessage("The port has to be between 1 and 65535.", isError: true)
            return
        }
        if !multiDc && (mainDc < 1 || mainDc > 5) {
            node.setMessage("The main datacenter has to be between 1 and 5.", isError: true)
            return
        }

        // A multi-datacenter server discovers its addresses, so it has one home
        // datacenter, as desktop's box pins it.
        let mainDcId = multiDc ? 2 : mainDc

        let saved: PolySrvServer
        if let server = self.server {
            saved = PolySrvServer(
                id: server.id,
                name: name,
                description: description,
                host: host,
                port: port,
                rsaPublicKey: key,
                isTelegram: false,
                isOfficial: false,
                multiDc: multiDc,
                mainDcId: mainDcId,
                restrictToTcp: server.restrictToTcp,
                logoPath: server.logoPath,
                dataCenters: server.dataCenters
            )
            PolySrvServers.shared.updateCustomServer(saved)
        } else {
            saved = PolySrvServers.shared.addCustomServer(name: name, description: description, host: host, port: port, rsaPublicKey: key, multiDc: multiDc, mainDcId: mainDcId)
        }

        self.completion(saved)
        self.dismiss()
    }
}
