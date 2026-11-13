import AppKit

// Improvement notes, the Lx Book way, for a one-person Mac app: write a note where you are, with
// what was on screen saved alongside and, if you like, a screenshot of the bit that needs fixing.
// Notes are kept on this Mac; "Copy for Claude" or "Export" hands them over for the next version,
// and a new version clears the notes it dealt with.

struct Note: Codable, Equatable {
    var id: String
    var ts: String
    var kind: String
    var text: String
    var context: [String]
    var version: String
    var shot: String? = nil     // file name of the screenshot, in the notes folder
    var done = false
}

enum NoteStore {
    static let kinds = ["Bug", "Idea", "Change", "Question"]

    static var dir: URL {
        let d = GDTFShare.supportDir.appendingPathComponent("notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static var file: URL { dir.appendingPathComponent("notes.json") }

    static func load() -> [Note] {
        guard let data = try? Data(contentsOf: file), let notes = try? JSONDecoder().decode([Note].self, from: data) else { return [] }
        return notes
    }

    static func save(_ notes: [Note]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(notes) { try? data.write(to: file, options: .atomic) }
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date())
    }

    static func add(kind: String, text: String, context: [String], shot: NSImage?) {
        var note = Note(id: UUID().uuidString, ts: stamp(), kind: kinds.contains(kind) ? kind : "Idea",
                        text: String(text.prefix(5000)), context: Array(context.prefix(12)).map { String($0.prefix(300)) },
                        version: "\(AppInfo.version) build \(AppInfo.build)")
        if let image = shot, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            let name = "note-" + String(note.id.prefix(8)) + ".png"
            if (try? png.write(to: dir.appendingPathComponent(name))) != nil { note.shot = name }
        }
        var all = load()
        all.insert(note, at: 0)
        save(all)
    }

    static func delete(_ ids: Set<String>) {
        var all = load()
        for n in all where ids.contains(n.id) {
            if let s = n.shot { try? FileManager.default.removeItem(at: dir.appendingPathComponent(s)) }
        }
        all.removeAll { ids.contains($0.id) }
        save(all)
    }

    /// The notes as one Markdown file, in the same shape Lx Book exports.
    static func markdown(_ notes: [Note]) -> String {
        let day = String(stamp().prefix(10))
        var out = "# LX Book Draw improvement notes\n\n"
        out += "Please work through these improvement notes for LX Book Draw (currently version \(AppInfo.version) build \(AppInfo.build)). "
        out += "They were written in the app; each one says what was on screen at the time.\n\n"
        out += "Exported \(day) · \(notes.count) note\(notes.count == 1 ? "" : "s").\n\n"
        for (i, n) in notes.enumerated() {
            let lines = n.text.components(separatedBy: "\n")
            out += "\(i + 1). **\(n.kind)**: \(lines.first ?? "")\n"
            for extra in lines.dropFirst() { out += "   \(extra)\n" }
            if !n.context.isEmpty {
                out += "   Where in the app:\n"
                for c in n.context { out += "   - \(c)\n" }
            }
            if let s = n.shot { out += "   Screenshot: \(s)\n" }
            out += "   _(\(n.ts) · v\(n.version))_\n\n"
        }
        return out
    }

    private static func normal(_ s: String) -> String {
        var t = s.lowercased().split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
        while let last = t.last, ".,;:!? ".contains(last) { t.removeLast() }
        return t
    }

    /// A new version carries the list of notes it dealt with; they are cleared once, the first time it runs.
    static func clearCompleted() {
        guard let url = Bundle.main.url(forResource: "completed-notes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = json["version"] as? String, let list = json["notes"] as? [[String: Any]] else { return }
        var seen = UserDefaults.standard.stringArray(forKey: "notesClearedVersions") ?? []
        if seen.contains(version) { return }
        seen.append(version)
        UserDefaults.standard.set(seen, forKey: "notesClearedVersions")
        var gone = Set<String>()
        for n in load() {
            let text = normal(n.text)
            for entry in list {
                if let exact = entry["text"] as? String, normal(exact) == text { gone.insert(n.id) }
                if let phrases = entry["contains"] as? [String], !phrases.isEmpty,
                   phrases.allSatisfy({ $0.count >= 4 }), phrases.joined().count >= 10,
                   phrases.allSatisfy({ text.contains(normal($0)) }) {
                    gone.insert(n.id)
                }
            }
        }
        if !gone.isEmpty { delete(gone) }
    }
}

/// The window for writing one note.
final class NoteEditor: NSObject {
    let window: NSWindow
    private weak var owner: MainWindowController?
    private let kind = NSPopUpButton(frame: NSRect(x: 20, y: 396, width: 140, height: 26), pullsDown: false)
    private let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 190))
    private let include = NSButton(checkboxWithTitle: "Save where I am in the app with the note", target: nil, action: nil)
    private let contextLabel = NSTextField(wrappingLabelWithString: "")
    private let thumb = NSImageView(frame: NSRect(x: 400, y: 56, width: 120, height: 80))
    private let shotButton = NSButton(title: "Mark an Area on the Drawing…", target: nil, action: nil)
    private var context: [String]
    private var shot: NSImage? = nil

    init(owner: MainWindowController, context: [String]) {
        self.owner = owner
        self.context = context
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 470), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = "Improvement Note"
        guard let content = window.contentView else { return }

        let heading = NSTextField(labelWithString: "Write a note about what should be better")
        heading.font = NSFont.systemFont(ofSize: 14, weight: .heavy)
        heading.frame = NSRect(x: 20, y: 432, width: 500, height: 22)
        content.addSubview(heading)

        kind.addItems(withTitles: NoteStore.kinds)
        kind.selectItem(withTitle: "Idea")
        content.addSubview(kind)
        let hint = NSTextField(labelWithString: "Cmd-Return saves")
        hint.textColor = NSColor.secondaryLabelColor
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.frame = NSRect(x: 170, y: 400, width: 200, height: 18)
        content.addSubview(hint)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 200, width: 500, height: 190))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        text.isRichText = false
        text.font = NSFont.systemFont(ofSize: 13)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        content.addSubview(scroll)

        include.state = .on
        include.frame = NSRect(x: 20, y: 172, width: 380, height: 20)
        content.addSubview(include)
        contextLabel.stringValue = context.map { "• " + $0 }.joined(separator: "\n")
        contextLabel.font = NSFont.systemFont(ofSize: 10)
        contextLabel.textColor = NSColor.secondaryLabelColor
        contextLabel.frame = NSRect(x: 22, y: 56, width: 370, height: 112)
        contextLabel.maximumNumberOfLines = 8
        content.addSubview(contextLabel)

        shotButton.target = self
        shotButton.action = #selector(markArea(_:))
        shotButton.frame = NSRect(x: 14, y: 14, width: 240, height: 30)
        content.addSubview(shotButton)
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.imageFrameStyle = .grayBezel
        thumb.isHidden = true
        content.addSubview(thumb)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.frame = NSRect(x: 340, y: 14, width: 84, height: 30)
        cancel.keyEquivalent = "\u{1b}"
        content.addSubview(cancel)
        let save = NSButton(title: "Save Note", target: self, action: #selector(save(_:)))
        save.frame = NSRect(x: 426, y: 14, width: 100, height: 30)
        save.keyEquivalent = "\r"
        save.keyEquivalentModifierMask = [.command]
        content.addSubview(save)
        window.initialFirstResponder = text
    }

    @objc private func cancel(_ sender: Any?) {
        window.sheetParent?.endSheet(window)
        owner?.noteFinished()
    }

    @objc private func save(_ sender: Any?) {
        let body = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            NSSound.beep()
            return
        }
        NoteStore.add(kind: kind.titleOfSelectedItem ?? "Idea", text: body,
                      context: include.state == .on ? context : [], shot: shot)
        window.sheetParent?.endSheet(window)
        owner?.log("Thanks, note saved. NOTES shows them all.")
        owner?.noteFinished()
    }

    /// Hides the note, lets you drag a box on the drawing, then comes back with the picture attached.
    @objc private func markArea(_ sender: Any?) {
        guard let owner = owner, let parent = window.sheetParent else { return }
        parent.endSheet(window)
        owner.log("Drag a box round what needs fixing. A click takes the whole drawing area. Esc goes back without a picture.")
        owner.canvas.captureArea { [weak self] image in
            guard let self = self else { return }
            if let image = image {
                self.shot = image
                self.thumb.image = image
                self.thumb.isHidden = false
                self.shotButton.title = "Mark a Different Area…"
            }
            parent.beginSheet(self.window, completionHandler: nil)
        }
    }
}

/// The list of notes: copy or export them for Claude, tick them done, delete them.
final class NotesList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window: NSWindow
    private let table = NSTableView()
    private var notes: [Note] = []
    private let status = NSTextField(labelWithString: "")

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = "Improvement Notes"
        window.center()
        guard let content = window.contentView else { return }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
        column.width = 680
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 40
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let copy = NSButton(title: "Copy Open Notes for Claude", target: self, action: #selector(copyNotes(_:)))
        let export = NSButton(title: "Export with Screenshots…", target: self, action: #selector(exportNotes(_:)))
        let done = NSButton(title: "Done / Not Done", target: self, action: #selector(toggleDone(_:)))
        let picture = NSButton(title: "Show Screenshot", target: self, action: #selector(showShot(_:)))
        let delete = NSButton(title: "Delete", target: self, action: #selector(deleteNotes(_:)))
        let buttons = NSStackView(views: [copy, export, done, picture, delete])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        status.textColor = NSColor.secondaryLabelColor
        status.font = NSFont.systemFont(ofSize: 11)

        for v in [scroll, buttons, status] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            buttons.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -6),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
        ])
        reload()
    }

    func reload() {
        notes = NoteStore.load()
        table.reloadData()
        let open = notes.filter { !$0.done }.count
        status.stringValue = "\(open) open, \(notes.count - open) done. Kept on this Mac in Application Support › LX Book Draw › notes."
    }

    private func picked() -> [Note] {
        table.selectedRowIndexes.compactMap { $0 < notes.count ? notes[$0] : nil }
    }

    @objc private func copyNotes(_ sender: Any?) {
        let open = notes.filter { !$0.done }
        if open.isEmpty {
            status.stringValue = "There are no open notes to copy."
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(NoteStore.markdown(open), forType: .string)
        let shots = open.filter { $0.shot != nil }.count
        status.stringValue = "Copied \(open.count) notes. Open your chat with Claude, paste (Cmd-V), send."
            + (shots > 0 ? " \(shots) have screenshots: use Export and attach the pictures too." : "")
    }

    @objc private func exportNotes(_ sender: Any?) {
        let open = notes.filter { !$0.done }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            let day = String(NoteStore.stamp().prefix(10))
            let md = folder.appendingPathComponent("LX Book Draw improvement notes \(day).md")
            try? NoteStore.markdown(open).write(to: md, atomically: true, encoding: .utf8)
            for n in open {
                guard let s = n.shot else { continue }
                let to = folder.appendingPathComponent(s)
                try? FileManager.default.removeItem(at: to)
                try? FileManager.default.copyItem(at: NoteStore.dir.appendingPathComponent(s), to: to)
            }
            self?.status.stringValue = "Exported \(open.count) notes and their screenshots. Attach that folder's files to your chat with Claude."
        }
    }

    @objc private func toggleDone(_ sender: Any?) {
        let ids = Set(picked().map { $0.id })
        if ids.isEmpty { return }
        var all = NoteStore.load()
        for i in all.indices where ids.contains(all[i].id) { all[i].done.toggle() }
        NoteStore.save(all)
        reload()
    }

    @objc private func deleteNotes(_ sender: Any?) {
        let ids = Set(picked().map { $0.id })
        if ids.isEmpty { return }
        NoteStore.delete(ids)
        reload()
    }

    @objc private func showShot(_ sender: Any?) {
        guard let s = picked().first?.shot else {
            status.stringValue = "That note has no screenshot."
            return
        }
        NSWorkspace.shared.open(NoteStore.dir.appendingPathComponent(s))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { notes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let n = notes[row]
        let label = NSTextField(wrappingLabelWithString: "")
        label.maximumNumberOfLines = 2
        label.font = NSFont.systemFont(ofSize: 12)
        let head = (n.done ? "✓ Done · " : "") + n.ts + " · " + n.kind + (n.shot != nil ? " · 📷" : "")
        label.stringValue = head + "\n" + n.text.replacingOccurrences(of: "\n", with: " ")
        label.textColor = n.done ? NSColor.tertiaryLabelColor : NSColor.labelColor
        return label
    }
}
