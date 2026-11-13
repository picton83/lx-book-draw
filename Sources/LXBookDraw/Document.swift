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
    }

    private func registerUndo(restoring old: Drawing, name: String) {
        undoManager?.registerUndo(withTarget: self) { doc in
            let current = doc.drawing
            doc.drawing = old
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
        registerUndo(restoring: old, name: name)
        changed()
    }

    /// A change that came from Lx Book: shown and saved, but not put on the undo list.
    func applyRemote(_ body: (inout Drawing) -> Void) {
        let old = drawing
        body(&drawing)
        if drawing == old { return }
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
        registerUndo(restoring: old, name: name)
        changed()
    }
}
