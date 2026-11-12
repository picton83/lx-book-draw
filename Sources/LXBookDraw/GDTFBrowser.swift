import AppKit

/// Sheet for finding a fixture on GDTF Share and adding it to the drawing.
final class GDTFBrowser: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window: NSWindow
    private weak var owner: MainWindowController?
    private let search = NSSearchField()
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private var all: [GDTFEntry] = []
    private var results: [GDTFEntry] = []

    init(owner: MainWindowController) {
        self.owner = owner
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 480),
                          styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        build()
        if GDTFShare.shared.hasAccount {
            loadList(refresh: false)
        } else {
            status.stringValue = "Add your GDTF Share username and password with Account… to search."
        }
    }

    private func build() {
        let content = NSView()
        window.contentView = content

        search.placeholderString = "Search GDTF Share, e.g. khamsin or robe forte"
        search.target = self
        search.action = #selector(searchChanged(_:))

        let account = NSButton(title: "Account…", target: self, action: #selector(editAccount(_:)))
        let refresh = NSButton(title: "Refresh List", target: self, action: #selector(refreshList(_:)))
        let top = NSStackView(views: [search, account, refresh])
        top.orientation = .horizontal
        top.spacing = 8

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("fixture"))
        column.title = "Fixture"
        column.width = 600
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(addSelected(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        status.textColor = NSColor.secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        let close = NSButton(title: "Done", target: self, action: #selector(closeSheet(_:)))
        let add = NSButton(title: "Add to Drawing", target: self, action: #selector(addSelected(_:)))
        add.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [status, spacer, close, add])
        bottom.orientation = .horizontal
        bottom.spacing = 8

        for v in [top, scroll, bottom] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),

            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -10),

            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
    }

    // MARK: Data

    private func loadList(refresh: Bool) {
        status.stringValue = refresh ? "Fetching the fixture list from GDTF Share…" : "Loading the fixture list…"
        GDTFShare.shared.list(refresh: refresh) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e):
                self.status.stringValue = e.message
            case .success(let list):
                self.all = list
                self.status.stringValue = "\(list.count) fixture revisions on GDTF Share. Type to search."
                self.runSearch()
            }
        }
    }

    private func runSearch() {
        results = GDTFShare.search(search.stringValue, in: all)
        table.reloadData()
        if !search.stringValue.isEmpty && !all.isEmpty {
            status.stringValue = results.isEmpty ? "Nothing found." : "\(results.count) fixtures found."
        }
    }

    @objc private func searchChanged(_ sender: Any?) {
        runSearch()
    }

    @objc private func refreshList(_ sender: Any?) {
        loadList(refresh: true)
    }

    @objc private func closeSheet(_ sender: Any?) {
        window.sheetParent?.endSheet(window)
    }

    @objc private func editAccount(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "GDTF Share account"
        alert.informativeText = "Your own gdtf-share.com username and password (the username is case sensitive). The password is kept in your Mac's Keychain."
        let user = NSTextField(string: GDTFShare.shared.username)
        user.placeholderString = "Username"
        user.frame = NSRect(x: 0, y: 30, width: 280, height: 24)
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        pass.placeholderString = "Password"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 56))
        box.addSubview(user)
        box.addSubview(pass)
        alert.accessoryView = box
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() != .alertFirstButtonReturn { return }
        let u = user.stringValue.trimmingCharacters(in: .whitespaces)
        if u.isEmpty || pass.stringValue.isEmpty { return }
        GDTFShare.shared.setAccount(user: u, password: pass.stringValue)
        loadList(refresh: true)
    }

    @objc private func addSelected(_ sender: Any?) {
        let row = table.selectedRow
        if row < 0 || row >= results.count {
            status.stringValue = "Pick a fixture in the list first."
            return
        }
        let entry = results[row]
        status.stringValue = "Downloading \(entry.fixture)…"
        GDTFShare.shared.download(rid: entry.rid) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e):
                self.status.stringValue = e.message
            case .success(let url):
                do {
                    let file = try GDTFReader.load(url, listed: entry)
                    guard let mode = MainWindowController.pickMode(file.modes, title: file.manufacturer + " " + file.name) else {
                        self.status.stringValue = ""
                        return
                    }
                    let def = GDTFReader.fixtureDef(from: file, mode: mode, listed: entry)
                    self.owner?.addFixtureType(def)
                    self.status.stringValue = "Added \(def.displayName) - \(def.mode)."
                } catch let e as GDTFError {
                    self.status.stringValue = e.message
                } catch {
                    self.status.stringValue = error.localizedDescription
                }
            }
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let label: NSTextField
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField {
            label = reused
        } else {
            label = NSTextField(labelWithString: "")
            label.identifier = id
            label.lineBreakMode = .byTruncatingTail
        }
        let x = results[row]
        var text = x.manufacturer + "  " + x.fixture
        if !x.revision.isEmpty { text += "   (" + x.revision + ")" }
        if !x.uploader.isEmpty { text += "   " + x.uploader }
        label.stringValue = text
        return label
    }
}
