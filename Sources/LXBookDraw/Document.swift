import AppKit

let lxDrawType = "com.picton.lxbookdraw.drawing"

extension Notification.Name {
    static let drawingChanged = Notification.Name("LXDrawingChanged")
}

/// Makes the app document-based without relying on Info.plist lookups.
final class DocController: NSDocumentController {
    override var defaultType: String? { lxDrawType }

    override func documentClass(forType typeName: String) -> AnyClass? { DrawDocument.self }

    override func typeForContents(of url: URL) throws -> String { lxDrawType }

    private static func tell(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Lx Book"
        alert.informativeText = text
        alert.runModal()
    }

    /// File > Open Show from Lx Book: sign in if needed, pick a show, open its drawing.
    @objc func openShow(_ sender: Any?) {
        LxAccount.openShow()
    }

    @objc func signIn(_ sender: Any?) {
        LxAccount.signIn { server, shows, open in
            LxAccount.pickShow(server: server, shows: shows, open: open, title: "Signed in. Open a show?") { show in
                DocController.openWorkingCopy(LxLink(server: server, showID: show.id, showName: show.name))
            }
        }
    }

    @objc func signOut(_ sender: Any?) {
        LxAccount.signOut()
    }

    /// The old way in: the show the browser has open, with a pasted key. Kept for keys saved before sign-in existed.
    @objc func openShowWithKey(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Open the show from Lx Book"
        alert.informativeText = "The drawing is kept in the show itself, and every change is saved there. Enter your Lx Book address and a key (Lx Book, Settings, Vectorworks card). It opens the show you have open in Lx Book."
        let server = NSTextField(string: LxSettings.server)
        server.placeholderString = "https://your-server/book"
        server.frame = NSRect(x: 0, y: 30, width: 340, height: 24)
        let key = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        key.placeholderString = "Lx Book key (leave empty to use the one already saved)"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 56))
        box.addSubview(server)
        box.addSubview(key)
        alert.accessoryView = box
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() != .alertFirstButtonReturn { return }
        let address = LxSettings.tidy(server.stringValue)
        if address.isEmpty {
            DocController.tell("Enter the address you open Lx Book at, for example https://your-server/book.")
            return
        }
        if !key.stringValue.isEmpty { LxSettings.setKey(key.stringValue.trimmingCharacters(in: .whitespaces), for: address) }
        guard let saved = LxSettings.key(for: address) else {
            DocController.tell("Enter an Lx Book key. Make one in Lx Book under Settings, in the Vectorworks card.")
            return
        }
        LxSettings.server = address
        LxBookSync.request(server: address, key: saved, session: URLSession.shared, method: "GET", path: "api/health") { result in
            switch result {
            case .failure(let e):
                // No signal: a show worked on before can still be opened from its working copy.
                if let last = UserDefaults.standard.string(forKey: "lastShowID"), !last.isEmpty,
                   FileManager.default.fileExists(atPath: ShowStore.workingCopy(last).path) {
                    DocController.shared.openDocument(withContentsOf: ShowStore.workingCopy(last), display: true) { _, _, _ in }
                } else {
                    DocController.tell(e.message)
                }
            case .success(let j):
                let id = LxBookSync.text(j["show"])
                if id.isEmpty {
                    DocController.tell("Lx Book answered, but no show is open for this account. Open the show in Lx Book and try again.")
                    return
                }
                DocController.openWorkingCopy(LxLink(server: address, showID: id, showName: LxBookSync.text(j["showName"])))
            }
        }
    }

    /// Opens the working copy of a show's drawing, making it first if there isn't one. `starting` is a drawing
    /// being moved into the show: it replaces the working copy and is sent only if the show has no drawing yet.
    static func openWorkingCopy(_ link: LxLink, starting: Drawing? = nil) {
        let url = ShowStore.workingCopy(link.showID)
        let exists = FileManager.default.fileExists(atPath: url.path)
        if starting != nil || !exists {
            if let open = NSDocumentController.shared.document(for: url) { open.close() }
            var d = starting ?? Drawing.blank()
            d.lxBook = link
            d.inShow = true
            d.publishFolder = nil
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? enc.encode(d), (try? data.write(to: url, options: .atomic)) != nil else {
                tell("The working copy of this show couldn't be made on this Mac.")
                return
            }
            ShowStore.resetSidecar(link.showID, pendingImport: starting != nil)
        }
        UserDefaults.standard.set(link.showID, forKey: "lastShowID")
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error = error { tell(error.localizedDescription) }
        }
    }
}

final class DrawDocument: NSDocument {
    var drawing = Drawing.blank()

    override class var autosavesInPlace: Bool { true }
    override class var readableTypes: [String] { [lxDrawType] }
    override class var writableTypes: [String] { [lxDrawType] }
    override class func isNativeType(_ type: String) -> Bool { true }

    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        "lxdraw"
    }

    /// A drawing that lives in an Lx Book show is named after the show, not after its hidden working copy.
    override var displayName: String! {
        get {
            if drawing.inShow == true, let link = drawing.lxBook { return link.showName + " (Lx Book)" }
            return super.displayName
        }
        set { super.displayName = newValue }
    }

    /// Cmd-S on a show: nothing to save to a file, so anything waiting is sent to Lx Book now.
    override func save(_ sender: Any?) {
        if drawing.inShow == true {
            flushToLxBook()
            return
        }
        super.save(sender)
    }

    func flushToLxBook() {
        for wc in windowControllers {
            (wc as? MainWindowController)?.flushLxBook()
        }
    }

    override func makeWindowControllers() {
        if let url = fileURL { Recents.add(url, name: displayName ?? url.lastPathComponent) }
        addWindowController(MainWindowController.make())
    }

    override func data(ofType typeName: String) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(drawing)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        drawing = try JSONDecoder().decode(Drawing.self, from: data)
    }

    // MARK: Editing with undo (whole-drawing snapshots; drawings are small)

    func changed(live: Bool = false) {
        NotificationCenter.default.post(name: .drawingChanged, object: self, userInfo: ["live": live])
        if !live { scheduleSave() }
    }

    // MARK: Change log

    /// Adds a line to the drawing's change log (kept in the file, newest last, last 400 changes).
    func logChange(_ what: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var h = drawing.history ?? []
        h.append(LogEntry(ts: f.string(from: Date()), what: what))
        if h.count > 400 { h.removeFirst(h.count - 400) }
        drawing.history = h
    }

    // MARK: Constant saving

    private var saveTimer: Timer? = nil
    private var published: Drawing? = nil

    /// Two seconds after the last change the drawing is saved to its file, so the file (in Dropbox
    /// or anywhere else) is always up to date. A drawing that has never been saved has no file yet.
    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            self?.saveNow()
        }
    }

    private func saveNow() {
        if fileURL == nil { return }
        if isDocumentEdited {
            autosave(withImplicitCancellability: false) { [weak self] _ in self?.publish() }
        } else {
            publish()
        }
    }

    /// Keeps a PDF of the drawing in the chosen folder (for example the show's folder in Dropbox, where Lx Book shows it).
    func publish(force: Bool = false) {
        guard let folder = drawing.publishFolder, !folder.isEmpty else { return }
        if !force && published == drawing { return }
        let dir = URL(fileURLWithPath: folder)
        if !FileManager.default.fileExists(atPath: dir.path) { return }
        let name = (fileURL?.deletingPathExtension().lastPathComponent ?? "Plot") + ".pdf"
        PDFExporter.export(drawing, to: dir.appendingPathComponent(name), forLxBook: true)
        published = drawing
    }

    override func close() {
        saveTimer?.invalidate()
        saveTimer = nil
        super.close()
    }

    private func registerUndo(restoring old: Drawing, name: String) {
        undoManager?.registerUndo(withTarget: self) { doc in
            let current = doc.drawing
            var restored = old
            restored.history = current.history
            doc.drawing = restored
            doc.logChange(((doc.undoManager?.isRedoing ?? false) ? "Redo: " : "Undo: ") + name)
            doc.registerUndo(restoring: current, name: name)
            doc.changed()
        }
        undoManager?.setActionName(name)
    }

    /// One undoable change.
    func edit(_ name: String, _ body: (inout Drawing) -> Void) {
        let old = drawing
        body(&drawing)
        if drawing == old { return }
        logChange(name)
        registerUndo(restoring: old, name: name)
        changed()
    }

    /// A change that came from Lx Book: shown and saved, but not put on the undo list.
    func applyRemote(_ body: (inout Drawing) -> Void) {
        let old = drawing
        body(&drawing)
        if drawing == old { return }
        logChange("Update from Lx Book")
        updateChangeCount(.changeDone)
        changed()
    }

    /// While dragging: show the change without recording undo.
    func setLive(_ d: Drawing) {
        drawing = d
        changed(live: true)
    }

    /// End of a drag: record one undo step back to where the drag started.
    func commitLive(from old: Drawing, name: String) {
        if drawing == old { return }
        logChange(name)
        registerUndo(restoring: old, name: name)
        changed()
    }
}
