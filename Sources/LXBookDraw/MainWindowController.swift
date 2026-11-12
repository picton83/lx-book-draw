import AppKit
import UniformTypeIdentifiers

final class MainWindowController: NSWindowController, NSWindowDelegate {
    let canvas = CanvasView()
    private var leftView = NSView()
    private var rightView = NSView()
    private var leftStack = NSStackView()
    private var rightStack = NSStackView()

    var currentTrussType = Library.truss[1].id
    var currentFixtureType = "generic"
    private var activeLayer: UUID? = nil

    private var rebuildPending = false
    private var forceLeft = false
    private var forceRight = false
    private var browser: GDTFBrowser? = nil

    var doc: DrawDocument? { document as? DrawDocument }

    override var document: AnyObject? {
        didSet {
            scheduleRebuild(left: true, right: true)
            DispatchQueue.main.async { [weak self] in self?.canvas.zoomFit() }
        }
    }

    static func make() -> MainWindowController {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 600)
        window.center()
        let c = MainWindowController(window: window)
        c.setup()
        return c
    }

    private func setup() {
        guard let window = window else { return }
        let content = NSView()
        window.contentView = content

        let left = Panel.make()
        let right = Panel.make()
        leftView = left.view
        leftStack = left.stack
        rightView = right.view
        rightStack = right.stack
        canvas.controller = self
        window.delegate = self

        for v in [leftView, canvas, rightView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            leftView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            leftView.topAnchor.constraint(equalTo: content.topAnchor),
            leftView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            leftView.widthAnchor.constraint(equalToConstant: 220),

            rightView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rightView.topAnchor.constraint(equalTo: content.topAnchor),
            rightView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            rightView.widthAnchor.constraint(equalToConstant: 270),

            canvas.leadingAnchor.constraint(equalTo: leftView.trailingAnchor),
            canvas.trailingAnchor.constraint(equalTo: rightView.leadingAnchor),
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(drawingChanged(_:)), name: .drawingChanged, object: nil)
        window.makeFirstResponder(canvas)
    }

    /// Undo and Redo in the Edit menu act on the drawing.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        doc?.undoManager
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var activeLayerID: UUID {
        guard let d = doc?.drawing else { return UUID() }
        if let a = activeLayer, d.layer(a) != nil { return a }
        return d.layers.first?.id ?? UUID()
    }

    // MARK: Keeping the panels up to date

    @objc private func drawingChanged(_ note: Notification) {
        guard let changed = note.object as? DrawDocument, changed === doc else { return }
        canvas.pruneSelection()
        canvas.needsDisplay = true
        let live = (note.userInfo?["live"] as? Bool) ?? false
        if !live { scheduleRebuild(left: false, right: false) }
    }

    func selectionChanged() {
        scheduleRebuild(left: false, right: true)
    }

    func toolChanged() {
        scheduleRebuild(left: true, right: false)
    }

    /// Panels are rebuilt on the next pass of the run loop. A panel the user is typing in is left
    /// alone unless forced, so tabbing between fields keeps working.
    private func scheduleRebuild(left: Bool, right: Bool) {
        if left { forceLeft = true }
        if right { forceRight = true }
        if rebuildPending { return }
        rebuildPending = true
        DispatchQueue.main.async { [weak self] in self?.rebuildPanels() }
    }

    private func rebuildPanels() {
        rebuildPending = false
        let responder = window?.firstResponder as? NSView
        let typingLeft = responder?.isDescendant(of: leftView) ?? false
        let typingRight = responder?.isDescendant(of: rightView) ?? false
        if forceLeft || !typingLeft { rebuildLeft() }
        if forceRight || !typingRight { rebuildInspector() }
        forceLeft = false
        forceRight = false
    }

    // MARK: Left panel: tools, resources, layers

    private func rebuildLeft() {
        Panel.clear(leftStack)
        guard let doc = doc else { return }
        let d = doc.drawing

        Panel.add(Panel.heading("Tools"), to: leftStack)
        for t in Tool.allCases {
            let b = ClosureButton(title: t.title) { [weak self] _ in self?.canvas.tool = t }
            b.setButtonType(.pushOnPushOff)
            b.state = canvas.tool == t ? .on : .off
            Panel.add(b, to: leftStack)
        }

        Panel.add(Panel.heading("Truss"), to: leftStack)
        let trussIndex = Library.truss.firstIndex { $0.id == currentTrussType } ?? 0
        Panel.add(ClosurePopup(items: Library.truss.map { $0.name }, selected: trussIndex) { [weak self] i in
            self?.currentTrussType = Library.truss[i].id
            self?.canvas.tool = .truss
        }, to: leftStack)

        Panel.add(Panel.heading("Fixtures"), to: leftStack)
        let types = d.allFixtureTypes
        let fixIndex = types.firstIndex { $0.id == currentFixtureType } ?? 0
        let names = types.map { $0.mode.isEmpty ? $0.displayName : $0.displayName + " - " + $0.mode }
        Panel.add(ClosurePopup(items: names, selected: fixIndex) { [weak self] i in
            self?.currentFixtureType = types[i].id
            self?.canvas.tool = .fixture
        }, to: leftStack)
        Panel.add(ClosureButton(title: "Add from GDTF Share…") { [weak self] _ in self?.addFromGDTF(nil) }, to: leftStack)
        Panel.add(ClosureButton(title: "Import GDTF File…") { [weak self] _ in self?.importGDTFFile(nil) }, to: leftStack)
        Panel.add(Panel.row("Next unit", ClosureField(value: String(d.nextUnit)) { [weak self] s in
            guard let n = Int(s.trimmingCharacters(in: .whitespaces)) else { return }
            self?.doc?.edit("Next Unit Number") { $0.nextUnit = n }
        }), to: leftStack)

        Panel.add(Panel.heading("Snapping"), to: leftStack)
        Panel.add(ClosureButton.checkbox("Snap to grid", on: d.snapGrid) { [weak self] b in
            let on = b.state == .on
            self?.doc?.edit("Snap to Grid") { $0.snapGrid = on }
        }, to: leftStack)
        Panel.add(Panel.row("Grid (mm)", ClosureField(value: fmtNum(d.gridSize)) { [weak self] s in
            guard let v = parseNum(s), v > 0 else { return }
            self?.doc?.edit("Grid Size") { $0.gridSize = v }
        }), to: leftStack)
        Panel.add(ClosureButton.checkbox("Show fixture labels", on: d.showLabels) { [weak self] b in
            let on = b.state == .on
            self?.doc?.edit("Show Labels") { $0.showLabels = on }
        }, to: leftStack)

        Panel.add(Panel.heading("Layers"), to: leftStack)
        let active = activeLayerID
        for layer in d.layers {
            let id = layer.id
            let eye = ClosureButton.checkbox("", on: layer.visible) { [weak self] b in
                let on = b.state == .on
                self?.doc?.edit("Layer Visibility") { d in
                    if let i = d.layers.firstIndex(where: { $0.id == id }) { d.layers[i].visible = on }
                }
            }
            eye.toolTip = "Show or hide this layer"
            let nameView: NSView
            if id == active {
                nameView = ClosureField(value: layer.name) { [weak self] s in
                    self?.doc?.edit("Rename Layer") { d in
                        if let i = d.layers.firstIndex(where: { $0.id == id }) { d.layers[i].name = s }
                    }
                }
            } else {
                let b = ClosureButton(title: layer.name) { [weak self] _ in
                    self?.activeLayer = id
                    self?.scheduleRebuild(left: true, right: false)
                }
                b.isBordered = false
                b.alignment = .left
                nameView = b
            }
            nameView.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [eye, nameView])
            row.orientation = .horizontal
            row.spacing = 4
            Panel.add(row, to: leftStack)
        }
        Panel.add(ClosureButton(title: "Add Layer") { [weak self] _ in
            let layer = Layer(name: "Layer \(d.layers.count + 1)")
            self?.doc?.edit("Add Layer") { $0.layers.append(layer) }
            self?.activeLayer = layer.id
            self?.scheduleRebuild(left: true, right: false)
        }, to: leftStack)
        Panel.add(Panel.note("New objects go on the layer shown as a text box. Click another layer's name to make it active."), to: leftStack)
    }

    // MARK: Right panel: Object Info

    private func setAll(_ name: String, _ change: @escaping (inout DrawObject) -> Void) {
        guard let doc = doc else { return }
        let ids = canvas.selection
        doc.edit(name) { d in
            for i in d.objects.indices where ids.contains(d.objects[i].id) {
                change(&d.objects[i])
            }
        }
    }

    private func textRow(_ label: String, _ value: String, _ change: @escaping (inout DrawObject, String) -> Void) {
        let field = ClosureField(value: value) { [weak self] s in
            self?.setAll("Change " + label) { o in change(&o, s) }
        }
        Panel.add(Panel.row(label, field), to: rightStack)
    }

    private func numRow(_ label: String, _ value: Double, _ change: @escaping (inout DrawObject, Double) -> Void) {
        let field = ClosureField(value: fmtNum(value)) { [weak self] s in
            guard let v = parseNum(s) else { return }
            self?.setAll("Change " + label) { o in change(&o, v) }
        }
        Panel.add(Panel.row(label, field), to: rightStack)
    }

    private func colorRow(_ label: String, _ current: RGBA?, allowNone: Bool, _ change: @escaping (inout DrawObject, RGBA?) -> Void) {
        var names = RGBA.presets.map { $0.name }
        var colors: [RGBA?] = RGBA.presets.map { $0.color }
        if allowNone {
            names.insert("None", at: 0)
            colors.insert(nil, at: 0)
        }
        let index = colors.firstIndex { $0 == current } ?? 0
        let popup = ClosurePopup(items: names, selected: index) { [weak self] i in
            let picked = colors[i]
            self?.setAll("Change " + label) { o in change(&o, picked) }
        }
        Panel.add(Panel.row(label, popup), to: rightStack)
    }

    /// X or Y of the selection; typing a value moves everything selected (and fixtures hung on it) by the difference.
    private func moveRow(_ label: String, x: Bool, _ first: DrawObject) {
        let b = first.worldBounds()
        let current: Double
        if x {
            current = first.usesPoints ? Double(b.minX) : first.pos.x
        } else {
            current = first.usesPoints ? Double(b.minY) : first.pos.y
        }
        let field = ClosureField(value: fmtNum(current)) { [weak self] s in
            guard let self = self, let doc = self.doc, let v = parseNum(s) else { return }
            let delta = v - current
            let ids = self.canvas.selection.union(doc.drawing.attachedFixtures(to: self.canvas.selection))
            doc.edit("Move") { d in
                for i in d.objects.indices where ids.contains(d.objects[i].id) {
                    d.objects[i].translate(dx: x ? delta : 0, dy: x ? 0 : delta)
                }
            }
        }
        Panel.add(Panel.row(label, field), to: rightStack)
    }

    private func infoRow(_ label: String, _ value: String, _ change: @escaping (inout Drawing, String) -> Void) {
        let field = ClosureField(value: value) { [weak self] s in
            self?.doc?.edit("Change " + label) { d in change(&d, s) }
        }
        Panel.add(Panel.row(label, field), to: rightStack)
    }

    private func kindName(_ k: Kind) -> String {
        switch k {
        case .line: return "Line"
        case .rect: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .polyline: return "Polyline"
        case .text: return "Text"
        case .truss: return "Truss"
        case .fixture: return "Lighting Device"
        }
    }

    private func rebuildInspector() {
        Panel.clear(rightStack)
        guard let doc = doc else { return }
        let d = doc.drawing
        let sel = d.objects.filter { canvas.selection.contains($0.id) }
        Panel.add(Panel.heading("Object Info"), to: rightStack)

        guard let first = sel.first else {
            Panel.add(Panel.note("Nothing selected. These are the drawing's title block details."), to: rightStack)
            infoRow("Show", d.info.show) { $0.info.show = $1 }
            infoRow("Drawing", d.info.drawingTitle) { $0.info.drawingTitle = $1 }
            infoRow("Designer", d.info.designer) { $0.info.designer = $1 }
            infoRow("Venue", d.info.venue) { $0.info.venue = $1 }
            infoRow("Drawn by", d.info.drawnBy) { $0.info.drawnBy = $1 }
            infoRow("Version", d.info.version) { $0.info.version = $1 }
            infoRow("Date", d.info.date) { $0.info.date = $1 }
            infoRow("Label size", fmtNum(d.labelSize)) { d, s in
                if let v = parseNum(s), v > 0 { d.labelSize = v }
            }
            return
        }

        let sameKind = sel.allSatisfy { $0.kind == first.kind }
        let title = NSTextField(labelWithString: sel.count == 1 ? kindName(first.kind) : "\(sel.count) objects")
        title.font = NSFont.boldSystemFont(ofSize: 13)
        Panel.add(title, to: rightStack)

        let layerIndex = d.layers.firstIndex { $0.id == first.layer } ?? 0
        let layers = d.layers
        Panel.add(Panel.row("Layer", ClosurePopup(items: layers.map { $0.name }, selected: layerIndex) { [weak self] i in
            let id = layers[i].id
            self?.setAll("Change Layer") { $0.layer = id }
        }), to: rightStack)

        moveRow("X", x: true, first)
        moveRow("Y", x: false, first)

        if !sameKind {
            Panel.add(Panel.note("Select objects of one kind to edit their details together."), to: rightStack)
            return
        }

        switch first.kind {
        case .line, .polyline:
            colorRow("Line colour", first.stroke, allowNone: false) { o, c in o.stroke = c ?? .black }
            numRow("Line weight", first.lineWeight) { $0.lineWeight = max(0.05, $1) }
            if first.kind == .polyline {
                Panel.add(ClosureButton.checkbox("Closed shape", on: first.closed) { [weak self] b in
                    let on = b.state == .on
                    self?.setAll("Closed Shape") { $0.closed = on }
                }, to: rightStack)
                colorRow("Fill", first.fill, allowNone: true) { o, c in o.fill = c }
            }
        case .rect, .ellipse:
            numRow("Width", first.w) { $0.w = max(1, $1) }
            numRow("Height", first.h) { $0.h = max(1, $1) }
            numRow("Rotation", first.rot) { $0.rot = $1 }
            colorRow("Line colour", first.stroke, allowNone: false) { o, c in o.stroke = c ?? .black }
            colorRow("Fill", first.fill, allowNone: true) { o, c in o.fill = c }
            numRow("Line weight", first.lineWeight) { $0.lineWeight = max(0.05, $1) }
        case .text:
            textRow("Text", first.text) { $0.text = $1 }
            numRow("Size (mm)", first.textSize) { $0.textSize = max(10, $1) }
            numRow("Rotation", first.rot) { $0.rot = $1 }
            colorRow("Colour", first.stroke, allowNone: false) { o, c in o.stroke = c ?? .black }
        case .truss:
            let index = Library.truss.firstIndex { $0.id == first.typeID } ?? 0
            Panel.add(Panel.row("Type", ClosurePopup(items: Library.truss.map { $0.name }, selected: index) { [weak self] i in
                let id = Library.truss[i].id
                self?.setAll("Change Truss Type") { $0.typeID = id }
            }), to: rightStack)
            let field = ClosureField(value: first.position) { [weak self] s in
                self?.renamePosition(s)
            }
            Panel.add(Panel.row("Position", field), to: rightStack)
            numRow("Rotation", first.rot) { $0.rot = $1 }
            colorRow("Colour code", first.fill, allowNone: true) { o, c in o.fill = c }
            Panel.add(Panel.note("Fixtures hung on a truss take its position name and move with it."), to: rightStack)
        case .fixture:
            let types = d.allFixtureTypes
            let index = types.firstIndex { $0.id == first.typeID } ?? 0
            let names = types.map { $0.mode.isEmpty ? $0.displayName : $0.displayName + " - " + $0.mode }
            Panel.add(Panel.row("Type", ClosurePopup(items: names, selected: index) { [weak self] i in
                let t = types[i]
                self?.setAll("Change Fixture Type") { o in
                    o.typeID = t.id
                    o.w = t.width
                    o.h = t.depth
                }
            }), to: rightStack)
            let t = d.fixtureType(first.typeID)
            if t.source == "gdtf" {
                var facts = "\(t.channels)ch"
                if t.weight > 0 { facts += " · " + fmtNum(t.weight) + " kg" }
                if t.watts > 0 { facts += " · " + fmtNum(t.watts) + " W" }
                Panel.add(Panel.note("GDTF: " + facts), to: rightStack)
            }
            textRow("Unit ID", first.unit) { $0.unit = $1 }
            textRow("Universe", first.universe) { $0.universe = $1 }
            textRow("Address", first.address) { $0.address = $1 }
            textRow("Circuit", first.circuit) { $0.circuit = $1 }
            textRow("Position", first.position) { $0.position = $1 }
            textRow("Note", first.note) { $0.note = $1 }
            numRow("Rotation", first.rot) { $0.rot = $1 }
        }
    }

    /// Naming a truss also names the position on every fixture hung on it.
    private func renamePosition(_ name: String) {
        guard let doc = doc else { return }
        let ids = canvas.selection
        doc.edit("Change Position") { d in
            for i in d.objects.indices {
                if d.objects[i].kind == .truss && ids.contains(d.objects[i].id) { d.objects[i].position = name }
                if let a = d.objects[i].attachedTo, ids.contains(a) { d.objects[i].position = name }
            }
        }
    }

    // MARK: Menu actions

    @objc func zoomInAction(_ sender: Any?) { canvas.zoomCentre(by: 1.4) }
    @objc func zoomOutAction(_ sender: Any?) { canvas.zoomCentre(by: 1 / 1.4) }
    @objc func zoomFitAction(_ sender: Any?) { canvas.zoomFit() }
    @objc func bringToFront(_ sender: Any?) { canvas.arrange(toFront: true) }
    @objc func sendToBack(_ sender: Any?) { canvas.arrange(toFront: false) }
    @objc func duplicateAction(_ sender: Any?) { canvas.duplicateSelection(sender) }
    @objc func deleteAction(_ sender: Any?) { canvas.deleteSelection(sender) }

    @objc func exportPDF(_ sender: Any?) {
        guard let doc = doc, let window = window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.pdf]
        let base = doc.displayName ?? "Plot"
        panel.nameFieldStringValue = base + ".pdf"
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url {
                PDFExporter.export(doc.drawing, to: url)
            }
        }
    }

    // MARK: GDTF

    func addFixtureType(_ def: FixtureDef) {
        guard let doc = doc else { return }
        doc.edit("Add " + def.name) { d in
            if let i = d.fixtureTypes.firstIndex(where: { $0.id == def.id }) {
                d.fixtureTypes[i] = def
            } else {
                d.fixtureTypes.append(def)
            }
        }
        currentFixtureType = def.id
        canvas.tool = .fixture
        scheduleRebuild(left: true, right: false)
    }

    func showError(_ message: String) {
        guard let window = window else { return }
        let alert = NSAlert()
        alert.messageText = "GDTF"
        alert.informativeText = message
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    /// Reads a .gdtf file, asks which mode if there are several, and adds it to the drawing.
    func addFixture(fromFile url: URL, listed: GDTFEntry?) {
        do {
            let file = try GDTFReader.load(url, listed: listed)
            guard let mode = MainWindowController.pickMode(file.modes, title: file.manufacturer + " " + file.name) else { return }
            addFixtureType(GDTFReader.fixtureDef(from: file, mode: mode, listed: listed))
        } catch let e as GDTFError {
            showError(e.message)
        } catch {
            showError(error.localizedDescription)
        }
    }

    static func pickMode(_ modes: [GDTFMode], title: String) -> GDTFMode? {
        if modes.isEmpty { return GDTFMode(name: "", channels: 0) }
        if modes.count == 1 { return modes[0] }
        let alert = NSAlert()
        alert.messageText = "Which mode?"
        alert.informativeText = title
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        for m in modes {
            popup.menu?.addItem(NSMenuItem(title: "\(m.name) (\(m.channels)ch)", action: nil, keyEquivalent: ""))
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() != .alertFirstButtonReturn { return nil }
        let i = popup.indexOfSelectedItem
        return i >= 0 && i < modes.count ? modes[i] : nil
    }

    @objc func importGDTFFile(_ sender: Any?) {
        guard let window = window else { return }
        let panel = NSOpenPanel()
        if let type = UTType(filenameExtension: "gdtf") { panel.allowedContentTypes = [type] }
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url {
                DispatchQueue.main.async { self?.addFixture(fromFile: url, listed: nil) }
            }
        }
    }

    @objc func addFromGDTF(_ sender: Any?) {
        guard let window = window else { return }
        let b = GDTFBrowser(owner: self)
        browser = b
        window.beginSheet(b.window) { [weak self] _ in self?.browser = nil }
    }
}
