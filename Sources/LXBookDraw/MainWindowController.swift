import AppKit
import UniformTypeIdentifiers

final class MainWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSMenuItemValidation {
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

    // AutoCAD-style chrome: ribbon on top, command line and status bar at the bottom
    private let ribbon = NSStackView()
    private var historyView: NSTextView? = nil
    private let promptLabel = NSTextField(labelWithString: "Command:")
    let commandField = NSTextField(string: "")
    private let coordsLabel = NSTextField(labelWithString: "")
    private var statusButtons: [String: ClosureButton] = [:]

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
        window.appearance = NSAppearance(named: .darkAqua)
        window.delegate = self
        let content = NSView()
        window.contentView = content

        let left = Panel.make()
        let right = Panel.make()
        leftView = left.view
        leftStack = left.stack
        rightView = right.view
        rightStack = right.stack
        canvas.controller = self

        // Ribbon: every button just runs the command you could also type.
        ribbon.orientation = .horizontal
        ribbon.spacing = 4
        ribbon.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        let groups: [(String, [(String, String)])] = [
            ("Draw", [("Line", "line"), ("Polyline", "pline"), ("Circle", "circle"), ("Rectangle", "rectang"), ("Text", "text")]),
            ("Lighting", [("Truss", "truss"), ("Fixture", "fixture")]),
            ("Modify", [("Move", "move"), ("Copy", "copy"), ("Rotate", "rotate"), ("Erase", "erase")]),
            ("View", [("Zoom Extents", "ze"), ("Zoom Window", "zoom")])
        ]
        for (title, buttons) in groups {
            let label = NSTextField(labelWithString: title.uppercased())
            label.font = NSFont.boldSystemFont(ofSize: 9)
            label.textColor = NSColor.tertiaryLabelColor
            ribbon.addArrangedSubview(label)
            for (name, command) in buttons {
                let b = ClosureButton(title: name) { [weak self] _ in self?.runCommand(command) }
                b.controlSize = .small
                b.font = NSFont.systemFont(ofSize: 11)
                b.toolTip = "Command: " + command.uppercased()
                ribbon.addArrangedSubview(b)
            }
            let gap = NSView()
            gap.translatesAutoresizingMaskIntoConstraints = false
            gap.widthAnchor.constraint(equalToConstant: 10).isActive = true
            ribbon.addArrangedSubview(gap)
        }

        // Command history, command line and status bar
        let historyScroll = NSScrollView()
        historyScroll.hasVerticalScroller = true
        historyScroll.borderType = .noBorder
        historyScroll.drawsBackground = false
        let history = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 56))
        history.isEditable = false
        history.drawsBackground = false
        history.autoresizingMask = [.width]
        history.isVerticallyResizable = true
        history.textContainer?.widthTracksTextView = true
        historyScroll.documentView = history
        historyView = history

        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        promptLabel.font = mono
        promptLabel.textColor = NSColor.labelColor
        promptLabel.setContentHuggingPriority(.required, for: .horizontal)
        commandField.font = mono
        commandField.delegate = self
        commandField.focusRingType = .none
        commandField.placeholderString = "Type a command (HELP for the list)"
        commandField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let commandRow = NSStackView(views: [promptLabel, commandField])
        commandRow.orientation = .horizontal
        commandRow.spacing = 6

        coordsLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        coordsLabel.textColor = NSColor.secondaryLabelColor
        coordsLabel.translatesAutoresizingMaskIntoConstraints = false
        coordsLabel.widthAnchor.constraint(equalToConstant: 170).isActive = true
        let statusRow = NSStackView(views: [coordsLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 4
        let toggles: [(String, String, Selector)] = [
            ("GRID", "Show the grid (F7)", #selector(toggleGrid(_:))),
            ("SNAP", "Snap to the grid (F9)", #selector(toggleGridSnap(_:))),
            ("ORTHO", "Lock to horizontal and vertical (F8)", #selector(toggleOrtho(_:))),
            ("OSNAP", "Object snap (F3)", #selector(toggleOsnap(_:)))
        ]
        for (name, tip, action) in toggles {
            let b = ClosureButton(title: name) { [weak self] sender in
                _ = self?.perform(action, with: sender)
            }
            b.setButtonType(.pushOnPushOff)
            b.controlSize = .small
            b.font = NSFont.boldSystemFont(ofSize: 10)
            b.toolTip = tip
            statusButtons[name] = b
            statusRow.addArrangedSubview(b)
        }
        let snapMenu = NSPopUpButton(frame: NSRect.zero, pullsDown: true)
        snapMenu.controlSize = .small
        snapMenu.font = NSFont.systemFont(ofSize: 10)
        snapMenu.addItem(withTitle: "Object Snaps")
        for kind in SnapKind.allCases {
            let item = NSMenuItem(title: kind.label, action: #selector(toggleSnapMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            snapMenu.menu?.addItem(item)
        }
        statusRow.addArrangedSubview(snapMenu)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusRow.addArrangedSubview(spacer)
        let version = NSTextField(labelWithString: "LX Book Draw \(AppInfo.version)  build \(AppInfo.build)")
        version.font = NSFont.systemFont(ofSize: 10)
        version.textColor = NSColor.tertiaryLabelColor
        statusRow.addArrangedSubview(version)

        let bottom = NSStackView(views: [historyScroll, commandRow, statusRow])
        bottom.orientation = .vertical
        bottom.alignment = .leading
        bottom.spacing = 4
        bottom.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 6, right: 8)
        for v in [historyScroll, commandRow, statusRow] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: bottom.widthAnchor, constant: -16).isActive = true
        }
        historyScroll.heightAnchor.constraint(equalToConstant: 56).isActive = true

        for v in [ribbon, leftView, canvas, rightView, bottom] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            ribbon.topAnchor.constraint(equalTo: content.topAnchor),
            ribbon.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            ribbon.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor),
            ribbon.heightAnchor.constraint(equalToConstant: 34),

            leftView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            leftView.topAnchor.constraint(equalTo: ribbon.bottomAnchor),
            leftView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            leftView.widthAnchor.constraint(equalToConstant: 220),

            rightView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rightView.topAnchor.constraint(equalTo: ribbon.bottomAnchor),
            rightView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            rightView.widthAnchor.constraint(equalToConstant: 270),

            bottom.leadingAnchor.constraint(equalTo: leftView.trailingAnchor),
            bottom.trailingAnchor.constraint(equalTo: rightView.leadingAnchor),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            canvas.leadingAnchor.constraint(equalTo: leftView.trailingAnchor),
            canvas.trailingAnchor.constraint(equalTo: rightView.leadingAnchor),
            canvas.topAnchor.constraint(equalTo: ribbon.bottomAnchor),
            canvas.bottomAnchor.constraint(equalTo: bottom.topAnchor)
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(drawingChanged(_:)), name: .drawingChanged, object: nil)
        refreshStatus()
        log("LX Book Draw \(AppInfo.version). Type a command or HELP. Space or Enter repeats the last command, Esc cancels.")
        DispatchQueue.main.async { [weak self] in self?.focusCommandLine() }
    }

    // MARK: Command line

    func log(_ s: String) {
        guard let history = historyView else { return }
        let line = NSAttributedString(string: s + "\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        history.textStorage?.append(line)
        history.scrollToEndOfDocument(nil)
    }

    func setPrompt(_ s: String) {
        promptLabel.stringValue = s
    }

    func setCoords(_ p: CGPoint) {
        coordsLabel.stringValue = String(format: "%.0f, %.0f", Double(p.x), Double(p.y))
    }

    func refreshStatus() {
        statusButtons["GRID"]?.state = Drafting.showGrid ? .on : .off
        statusButtons["SNAP"]?.state = (doc?.drawing.snapGrid ?? false) ? .on : .off
        statusButtons["ORTHO"]?.state = Drafting.ortho ? .on : .off
        statusButtons["OSNAP"]?.state = Drafting.osnap ? .on : .off
        canvas.needsDisplay = true
    }

    /// Runs a command from a button or menu, exactly as if it had been typed.
    func runCommand(_ name: String) {
        log("Command: " + name.uppercased())
        if !canvas.run(name) { _ = appCommand(name) }
        focusCommandLine()
    }

    /// Commands that belong to the app rather than the drawing area.
    func appCommand(_ name: String) -> Bool {
        switch name.lowercased() {
        case "gdtf": addFromGDTF(nil)
        case "pdf", "plot", "export": exportPDF(nil)
        case "update", "updates": Updater.shared.check(userInitiated: true)
        case "save", "qsave": doc?.save(nil)
        default: return false
        }
        return true
    }

    func makeLayerCurrent(named name: String) {
        guard let d = doc?.drawing else { return }
        if let layer = d.layers.first(where: { $0.name.lowercased() == name.lowercased() }) {
            activeLayer = layer.id
            log("Current layer: " + layer.name)
            scheduleRebuild(left: true, right: false)
        } else {
            log("No layer called \"\(name)\". Layers: " + d.layers.map { $0.name }.joined(separator: ", "))
        }
    }

    /// Puts the typing cursor on the command line, optionally adding keys pressed over the drawing.
    func focusCommandLine(typing: String = "") {
        guard let window = window else { return }
        if commandField.currentEditor() == nil { window.makeFirstResponder(commandField) }
        var text = commandField.stringValue
        var submit = false
        for ch in typing.unicodeScalars {
            if ch.value == 13 || ch.value == 3 {
                submit = true
            } else if ch.value == 127 || ch.value == 8 {
                if !text.isEmpty { text.removeLast() }
            } else if ch.value >= 32 && !(ch.value >= 0xF700 && ch.value <= 0xF8FF) {
                text.unicodeScalars.append(ch)
            }
        }
        commandField.stringValue = text
        if let editor = commandField.currentEditor() {
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
        if submit { submitCommandLine() } else if !typing.isEmpty { commandTextChanged() }
    }

    private func submitCommandLine() {
        let raw = commandField.stringValue
        commandField.stringValue = ""
        if !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            log(promptLabel.stringValue + " " + raw)
        }
        canvas.enter(raw)
    }

    /// Space works as Enter, as in AutoCAD, except while typing free text.
    private func commandTextChanged() {
        if canvas.wantsFreeText { return }
        if commandField.stringValue.hasSuffix(" ") { submitCommandLine() }
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === commandField { commandTextChanged() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control !== commandField { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            submitCommandLine()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            commandField.stringValue = ""
            canvas.escape()
            return true
        }
        if commandSelector == #selector(NSResponder.deleteBackward(_:)) || commandSelector == #selector(NSResponder.deleteForward(_:)) {
            if commandField.stringValue.isEmpty {
                canvas.eraseSelection()
                return true
            }
        }
        return false
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

        Panel.add(Panel.heading("Truss"), to: leftStack)
        let trussIndex = Library.truss.firstIndex { $0.id == currentTrussType } ?? 0
        Panel.add(ClosurePopup(items: Library.truss.map { $0.name }, selected: trussIndex) { [weak self] i in
            self?.currentTrussType = Library.truss[i].id
            self?.runCommand("truss")
        }, to: leftStack)

        Panel.add(Panel.heading("Fixtures"), to: leftStack)
        let types = d.allFixtureTypes
        let fixIndex = types.firstIndex { $0.id == currentFixtureType } ?? 0
        let names = types.map { $0.mode.isEmpty ? $0.displayName : $0.displayName + " - " + $0.mode }
        Panel.add(ClosurePopup(items: names, selected: fixIndex) { [weak self] i in
            self?.currentFixtureType = types[i].id
            self?.runCommand("fixture")
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

        Panel.add(Panel.heading("Scenes"), to: leftStack)
        let scenes = d.scenes ?? []
        let activeScene = scenes.first { $0.id == d.activeScene }
        for scene in scenes {
            let sid = scene.id
            if sid == activeScene?.id {
                Panel.add(ClosureField(value: scene.name) { [weak self] s in
                    self?.doc?.edit("Rename Scene") { d in
                        if let i = d.scenes?.firstIndex(where: { $0.id == sid }) { d.scenes?[i].name = s }
                    }
                }, to: leftStack)
            } else {
                Panel.add(ClosureButton(title: scene.name) { [weak self] _ in
                    self?.canvas.selection = []
                    self?.doc?.edit("Show Scene") { $0.applyScene(sid) }
                    self?.canvas.zoomFit()
                }, to: leftStack)
            }
        }
        Panel.add(ClosureButton(title: "Save View as New Scene") { [weak self] _ in
            let scene = PlotScene(name: "Scene \(scenes.count + 1)", visibleLayers: d.layers.filter { $0.visible }.map { $0.id })
            self?.doc?.edit("New Scene") { d in
                d.scenes = (d.scenes ?? []) + [scene]
                d.activeScene = scene.id
            }
        }, to: leftStack)
        if let current = activeScene {
            let sid = current.id
            Panel.add(ClosureButton(title: "Update Scene from View") { [weak self] _ in
                self?.doc?.edit("Update Scene") { d in
                    let shown = d.layers.filter { $0.visible }.map { $0.id }
                    if let i = d.scenes?.firstIndex(where: { $0.id == sid }) { d.scenes?[i].visibleLayers = shown }
                }
            }, to: leftStack)
            Panel.add(ClosureButton(title: "Delete Scene") { [weak self] _ in
                self?.doc?.edit("Delete Scene") { d in
                    d.scenes?.removeAll { $0.id == sid }
                    d.activeScene = nil
                }
            }, to: leftStack)
        }
        Panel.add(Panel.note("A scene remembers which layers are showing. The scene shown as a text box is the current one. Each scene becomes a page in the PDF."), to: leftStack)

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
    @objc func duplicateAction(_ sender: Any?) { canvas.duplicateSelection() }
    @objc func deleteAction(_ sender: Any?) { canvas.eraseSelection() }

    /// True while the user is typing in a side-panel field, where Copy, Paste and Select All mean text.
    private var editingPanelText: Bool {
        guard let r = window?.firstResponder as? NSView else { return false }
        return r.isDescendant(of: leftView) || r.isDescendant(of: rightView)
    }

    @objc func copyAction(_ sender: Any?) {
        if editingPanelText { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: sender) } else { canvas.copyObjects() }
    }

    @objc func cutAction(_ sender: Any?) {
        if editingPanelText {
            NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: sender)
        } else {
            canvas.copyObjects()
            canvas.eraseSelection()
        }
    }

    @objc func pasteAction(_ sender: Any?) {
        let hasObjects = NSPasteboard.general.data(forType: CanvasView.pasteType) != nil
        if editingPanelText || !hasObjects {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: sender)
        } else {
            canvas.pasteObjects()
        }
    }

    @objc func selectAllAction(_ sender: Any?) {
        if editingPanelText { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: sender) } else { canvas.selectAllObjects() }
    }

    // MARK: Drafting aids (status bar, function keys, Drafting menu)

    @objc func toggleOsnap(_ sender: Any?) {
        Drafting.osnap = !Drafting.osnap
        log("<Osnap \(Drafting.osnap ? "on" : "off")>")
        refreshStatus()
    }

    @objc func toggleOrtho(_ sender: Any?) {
        Drafting.ortho = !Drafting.ortho
        log("<Ortho \(Drafting.ortho ? "on" : "off")>")
        refreshStatus()
    }

    @objc func toggleGrid(_ sender: Any?) {
        Drafting.showGrid = !Drafting.showGrid
        refreshStatus()
    }

    @objc func toggleGridSnap(_ sender: Any?) {
        doc?.edit("Snap to Grid") { $0.snapGrid = !$0.snapGrid }
        log("<Snap \((doc?.drawing.snapGrid ?? false) ? "on" : "off")>")
        refreshStatus()
    }

    @objc func toggleSnapMode(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let raw = item.representedObject as? String, let kind = SnapKind(rawValue: raw) else { return }
        Drafting.toggle(kind)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let action = item.action
        if action == #selector(toggleOsnap(_:)) { item.state = Drafting.osnap ? .on : .off }
        if action == #selector(toggleOrtho(_:)) { item.state = Drafting.ortho ? .on : .off }
        if action == #selector(toggleGrid(_:)) { item.state = Drafting.showGrid ? .on : .off }
        if action == #selector(toggleGridSnap(_:)) { item.state = (doc?.drawing.snapGrid ?? false) ? .on : .off }
        if action == #selector(toggleSnapMode(_:)), let raw = item.representedObject as? String, let kind = SnapKind(rawValue: raw) {
            item.state = Drafting.modes.contains(kind) ? .on : .off
        }
        return true
    }

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
        runCommand("fixture")
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
