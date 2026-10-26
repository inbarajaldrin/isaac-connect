// Workstations editor — master/detail. Top table names boxes and sets host/IP +
// SSH. Bottom table edits the SELECTED box's custom launch profiles: a name + a
// full remote command line (e.g. an Isaac Lab training run) that the Workstation
// menu's "Launch ▸ <name>" fires via `isaac-ctl run` over SSH. The built-in Isaac
// Sim launch is always present in the menu and is NOT listed here — this table is
// only the extra scripts you add.
//
// Edits commit straight to the shared WorkstationStore (persists to JSON, fires
// onChange so the menus rebuild).

import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let store = WorkstationStore.shared
    private var wsTable: NSTableView!
    private var profileTable: NSTableView!
    private var profileLabel: NSTextField!
    private var removeProfileButton: NSButton!
    private var addProfileButton: NSButton!
    var onClose: (() -> Void)?

    private struct Column { let id: String; let title: String; let width: CGFloat }
    private let wsColumns = [
        Column(id: "name", title: "Name",            width: 120),
        Column(id: "host", title: "Host / IP",       width: 140),
        Column(id: "ssh",  title: "SSH (user@host)", width: 190),
    ]
    private let profileColumns = [
        Column(id: "pname", title: "Profile",        width: 140),
        Column(id: "pcmd",  title: "Launch command", width: 320),
    ]

    convenience init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Workstations"
        self.init(window: win)
        win.delegate = self
        buildUI()
    }

    // Builds the table WITHOUT wiring dataSource/delegate — those are attached last,
    // in buildUI, once every ivar exists. Wiring here would make AppKit call
    // numberOfRows synchronously mid-construction, before wsTable/profileTable (and
    // the buttons refreshProfileSection touches) are assigned → nil-IUO trap.
    private func makeTable(_ columns: [Column]) -> NSTableView {
        let table = NSTableView()
        for c in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.id))
            col.title = c.title
            col.width = c.width
            table.addTableColumn(col)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        return table
    }

    private func scrolled(_ table: NSTableView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        wsTable = makeTable(wsColumns)
        let wsScroll = scrolled(wsTable)
        let wsAdd = NSButton(title: "Add", target: self, action: #selector(addRow))
        let wsRemove = NSButton(title: "Remove", target: self, action: #selector(removeRow))
        let wsBar = NSStackView(views: [wsAdd, wsRemove])
        wsBar.orientation = .horizontal; wsBar.spacing = 8
        wsBar.translatesAutoresizingMaskIntoConstraints = false

        let pLabel = NSTextField(labelWithString: "Launch profiles")
        pLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        pLabel.lineBreakMode = .byTruncatingTail
        pLabel.translatesAutoresizingMaskIntoConstraints = false
        profileLabel = pLabel

        profileTable = makeTable(profileColumns)
        let pScroll = scrolled(profileTable)
        addProfileButton = NSButton(title: "Add Profile", target: self, action: #selector(addProfile))
        removeProfileButton = NSButton(title: "Remove Profile", target: self, action: #selector(removeProfile))
        let pBar = NSStackView(views: [addProfileButton, removeProfileButton])
        pBar.orientation = .horizontal; pBar.spacing = 8
        pBar.translatesAutoresizingMaskIntoConstraints = false

        let views: [NSView] = [wsScroll, wsBar, pLabel, pScroll, pBar]
        for v in views { content.addSubview(v) }
        NSLayoutConstraint.activate([
            wsScroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            wsScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            wsScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            wsScroll.heightAnchor.constraint(equalToConstant: 150),

            wsBar.topAnchor.constraint(equalTo: wsScroll.bottomAnchor, constant: 8),
            wsBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),

            profileLabel.topAnchor.constraint(equalTo: wsBar.bottomAnchor, constant: 16),
            profileLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            profileLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            pScroll.topAnchor.constraint(equalTo: profileLabel.bottomAnchor, constant: 6),
            pScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            pScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            pBar.topAnchor.constraint(equalTo: pScroll.bottomAnchor, constant: 8),
            pBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            pBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        // Now that ALL ivars (both tables + label + buttons) exist, wire the tables.
        // Setting dataSource triggers a synchronous numberOfRows/selection pass, so
        // everything it reads must already be in place.
        for t in [wsTable, profileTable] { t?.dataSource = self; t?.delegate = self }
        refreshProfileSection()
    }

    // The workstation currently selected in the top table (drives the bottom table).
    private var selectedWorkstation: Workstation? {
        guard let table = wsTable else { return nil }   // nil during early construction
        let row = table.selectedRow
        guard row >= 0, row < store.workstations.count else { return nil }
        return store.workstations[row]
    }

    private func refreshProfileSection() {
        if let w = selectedWorkstation {
            profileLabel.stringValue = "Launch profiles for “\(w.name)”  (extra scripts; Isaac Sim launch is always available)"
            addProfileButton.isEnabled = true
        } else {
            profileLabel.stringValue = "Launch profiles  (select a workstation above)"
            addProfileButton.isEnabled = false
        }
        removeProfileButton.isEnabled = profileTable.selectedRow >= 0 && selectedWorkstation != nil
        profileTable.reloadData()
    }

    // MARK: data source
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === wsTable { return store.workstations.count }
        return selectedWorkstation?.launchProfiles.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let colID = tableColumn?.identifier.rawValue else { return nil }
        let field = NSTextField()
        field.isEditable = true
        field.isBordered = false
        field.drawsBackground = false
        field.identifier = NSUserInterfaceItemIdentifier(colID)
        field.target = self
        (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true

        if tableView === wsTable {
            guard row < store.workstations.count else { return nil }
            let w = store.workstations[row]
            field.action = #selector(wsFieldEdited(_:))
            switch colID {
            case "name": field.stringValue = w.name
            case "host": field.stringValue = w.host
            case "ssh":  field.stringValue = w.ssh
            default: break
            }
        } else {
            guard let w = selectedWorkstation, row < w.launchProfiles.count else { return nil }
            let p = w.launchProfiles[row]
            field.action = #selector(profileFieldEdited(_:))
            switch colID {
            case "pname": field.stringValue = p.name
            case "pcmd":
                field.stringValue = p.command
                field.placeholderString = "LIVESTREAM=2 <venv-python> <script> --kit_args '…'"
            default: break
            }
        }
        return field
    }

    // MARK: edits — workstations
    @objc private func wsFieldEdited(_ sender: NSTextField) {
        let row = wsTable.row(for: sender)
        guard row >= 0, row < store.workstations.count else { return }
        var w = store.workstations[row]
        switch sender.identifier?.rawValue {
        case "name": w.name = sender.stringValue
        case "host": w.host = sender.stringValue.trimmingCharacters(in: .whitespaces)
        case "ssh":  w.ssh  = sender.stringValue.trimmingCharacters(in: .whitespaces)
        default: return
        }
        store.update(w)
        if sender.identifier?.rawValue == "name" { refreshProfileSection() }  // label tracks the name
    }

    @objc private func addRow() {
        store.add(Workstation(name: "new", host: ""))
        wsTable.reloadData()
        let last = store.workstations.count - 1
        if last >= 0 {
            wsTable.selectRowIndexes(IndexSet(integer: last), byExtendingSelection: false)
            wsTable.editColumn(0, row: last, with: nil, select: true)
        }
        refreshProfileSection()
    }

    @objc private func removeRow() {
        let row = wsTable.selectedRow
        guard row >= 0, row < store.workstations.count else { return }
        store.remove(id: store.workstations[row].id)
        wsTable.reloadData()
        refreshProfileSection()
    }

    // MARK: edits — launch profiles (of the selected workstation)
    @objc private func profileFieldEdited(_ sender: NSTextField) {
        let row = profileTable.row(for: sender)
        guard var w = selectedWorkstation, row >= 0, row < w.launchProfiles.count else { return }
        switch sender.identifier?.rawValue {
        case "pname": w.launchProfiles[row].name = sender.stringValue
        case "pcmd":  w.launchProfiles[row].command = sender.stringValue
        default: return
        }
        store.update(w)
    }

    @objc private func addProfile() {
        guard var w = selectedWorkstation else { return }
        w.launchProfiles.append(LaunchProfile(name: "new profile", command: ""))
        store.update(w)
        profileTable.reloadData()
        let last = w.launchProfiles.count - 1
        if last >= 0 {
            profileTable.selectRowIndexes(IndexSet(integer: last), byExtendingSelection: false)
            profileTable.editColumn(0, row: last, with: nil, select: true)
        }
        removeProfileButton.isEnabled = true
    }

    @objc private func removeProfile() {
        let row = profileTable.selectedRow
        guard var w = selectedWorkstation, row >= 0, row < w.launchProfiles.count else { return }
        w.launchProfiles.remove(at: row)
        store.update(w)
        profileTable.reloadData()
        removeProfileButton.isEnabled = profileTable.selectedRow >= 0
    }

    // MARK: selection
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === wsTable { refreshProfileSection() }
        else if table === profileTable {
            removeProfileButton.isEnabled = profileTable.selectedRow >= 0 && selectedWorkstation != nil
        }
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
