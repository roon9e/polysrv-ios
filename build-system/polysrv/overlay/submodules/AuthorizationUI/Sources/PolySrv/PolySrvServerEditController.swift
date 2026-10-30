import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import TelegramPresentationData

/// One labelled text field. The rows are plain views laid out by hand rather
/// than cells: the form is a fixed list, so there is nothing for a table's reuse
/// to buy, and a row that lays itself out cannot double-add its field.
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

/// The RSA public key: it is a PEM, pasted rather than typed.
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
        self.label.frame = CGRect(x: 16.0, y: 0.0, width: self.bounds.width - 32.0, height: 34.0)
        self.textView.frame = CGRect(x: 13.0, y: 34.0, width: max(0.0, self.bounds.width - 26.0), height: max(0.0, self.bounds.height - 40.0))
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
    private let onSave: () -> Void
    private let onCancel: () -> Void

    private let header = UIView()
    private let titleLabel = UILabel()
    private let cancelButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let messageLabel = UILabel()
    private let scrollView = UIScrollView()
    private let contentView = UIView()

    let nameRow = PolySrvServerEditFieldRow(title: "Name", keyboard: .default)
    let descriptionRow = PolySrvServerEditFieldRow(title: "Description", keyboard: .default)
    let hostRow = PolySrvServerEditFieldRow(title: "Address", keyboard: .URL)
    let portRow = PolySrvServerEditFieldRow(title: "Port", keyboard: .numberPad)
    let mainDcRow = PolySrvServerEditFieldRow(title: "Main DC", keyboard: .numberPad)
    let keyRow = PolySrvServerEditKeyRow(frame: .zero)
    let multiDcRow = PolySrvServerEditSwitchRow(title: "Multi-datacenter")

    private let rows: [UIView]

    init(theme: PresentationTheme, editing: Bool, identityLocked: Bool, onSave: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.theme = theme
        self.identityLocked = identityLocked
        self.onSave = onSave
        self.onCancel = onCancel
        self.rows = [self.nameRow, self.descriptionRow, self.hostRow, self.portRow, self.mainDcRow, self.keyRow, self.multiDcRow]
        super.init()
        self.titleLabel.text = editing ? "Edit Server" : "Add Server"
    }

    override func didLoad() {
        super.didLoad()

        self.view.backgroundColor = self.theme.list.plainBackgroundColor
        self.header.backgroundColor = self.theme.list.plainBackgroundColor
        self.contentView.backgroundColor = self.theme.list.plainBackgroundColor

        self.titleLabel.font = UIFont.systemFont(ofSize: 17.0, weight: .semibold)
        self.titleLabel.textColor = self.theme.list.itemPrimaryTextColor

        self.cancelButton.setTitle("Cancel", for: .normal)
        self.cancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 17.0)
        self.cancelButton.addTarget(self, action: #selector(self.cancelPressed), for: .touchUpInside)

        self.saveButton.setTitle("Save", for: .normal)
        self.saveButton.titleLabel?.font = UIFont.systemFont(ofSize: 17.0, weight: .semibold)
        self.saveButton.addTarget(self, action: #selector(self.savePressed), for: .touchUpInside)

        self.messageLabel.font = UIFont.systemFont(ofSize: 13.0)
        self.messageLabel.numberOfLines = 0
        self.messageLabel.textColor = self.theme.list.itemSecondaryTextColor
        if self.identityLocked {
            self.messageLabel.text = "An account is signed in to this server, so its address and key cannot be changed."
        }

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

        self.header.addSubview(self.titleLabel)
        self.header.addSubview(self.cancelButton)
        self.header.addSubview(self.saveButton)
        self.header.addSubview(self.messageLabel)
        self.view.addSubview(self.header)
        self.view.addSubview(self.scrollView)
        self.scrollView.addSubview(self.contentView)
        for row in self.rows {
            self.contentView.addSubview(row)
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

    @objc private func cancelPressed() {
        self.onCancel()
    }

    @objc private func savePressed() {
        self.onSave()
    }

    @objc private func multiDcChanged() {
        self.mainDcRow.field.isEnabled = !self.multiDcRow.toggle.isOn && !self.identityLocked
    }

    func updateLayout(size: CGSize, safeInsets: UIEdgeInsets) {
        let barHeight: CGFloat = 44.0
        let messageHeight: CGFloat = self.messageLabel.text?.isEmpty == false ? 40.0 : 0.0
        let headerHeight = safeInsets.top + barHeight + messageHeight
        self.header.frame = CGRect(x: 0.0, y: 0.0, width: size.width, height: headerHeight)

        self.titleLabel.sizeToFit()
        self.titleLabel.frame = CGRect(x: floor((size.width - self.titleLabel.bounds.width) / 2.0), y: safeInsets.top + floor((barHeight - self.titleLabel.bounds.height) / 2.0), width: self.titleLabel.bounds.width, height: self.titleLabel.bounds.height)

        self.cancelButton.sizeToFit()
        self.cancelButton.frame = CGRect(x: 16.0, y: safeInsets.top + floor((barHeight - self.cancelButton.bounds.height) / 2.0), width: self.cancelButton.bounds.width, height: self.cancelButton.bounds.height)

        self.saveButton.sizeToFit()
        self.saveButton.frame = CGRect(x: size.width - self.saveButton.bounds.width - 16.0, y: safeInsets.top + floor((barHeight - self.saveButton.bounds.height) / 2.0), width: self.saveButton.bounds.width, height: self.saveButton.bounds.height)

        self.messageLabel.frame = CGRect(x: 16.0, y: safeInsets.top + barHeight, width: size.width - 32.0, height: messageHeight)

        self.scrollView.frame = CGRect(x: 0.0, y: headerHeight, width: size.width, height: max(0.0, size.height - headerHeight))

        var y: CGFloat = 8.0
        for row in self.rows {
            let height: CGFloat = row === self.keyRow ? 150.0 : 44.0
            row.frame = CGRect(x: 0.0, y: y, width: size.width, height: height)
            y += height
        }
        y += 8.0
        self.contentView.frame = CGRect(x: 0.0, y: 0.0, width: size.width, height: y)
        self.scrollView.contentSize = CGSize(width: size.width, height: y)
    }
}

/// The add/edit form for a custom server: desktop's server box, field for field.
/// The picker presents it; a save writes through `PolySrvServers` and hands the
/// saved record back so the list can be rebuilt.
public final class PolySrvServerEditController: ViewController {
    private let server: PolySrvServer?
    private let theme: PresentationTheme
    private let completion: (PolySrvServer) -> Void

    private var controllerNode: PolySrvServerEditControllerNode {
        return self.displayNode as! PolySrvServerEditControllerNode
    }

    public init(server: PolySrvServer?, theme: PresentationTheme, completion: @escaping (PolySrvServer) -> Void) {
        self.server = server
        self.theme = theme
        self.completion = completion
        super.init(navigationBarPresentationData: nil)
    }

    public required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadDisplayNode() {
        let identityLocked = self.server.map { !PolySrvServers.shared.canEditIdentity(of: $0.id) } ?? false
        let node = PolySrvServerEditControllerNode(theme: self.theme, editing: self.server != nil, identityLocked: identityLocked, onSave: { [weak self] in
            self?.savePressed()
        }, onCancel: { [weak self] in
            self?.dismiss()
        })
        self.displayNode = node
        node.apply(server: self.server)
        self.displayNodeDidLoad()
    }

    public override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.controllerNode.updateLayout(size: layout.size, safeInsets: layout.safeInsets)
    }

    private func savePressed() {
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
