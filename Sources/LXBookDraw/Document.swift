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

    override func makeWindowControllers() {
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
        PDFExporter.export(drawing, to: dir.appendingPathComponent(name))
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
