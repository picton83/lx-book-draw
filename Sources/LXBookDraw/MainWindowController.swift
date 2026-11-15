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
    let tabRow = NSStackView()
    let commandField = NSTextField(string: "")
    private let coordsLabel = NSTextField(labelWithString: "")
    private var statusButtons: [String: ClosureButton] = [:]
    private var lxSync: LxBookSync? = nil
    private var lxButton: ClosureButton? = nil
    private var noteEditor: NoteEditor? = nil
    private var notesList: NotesList? = nil

    var doc: DrawDocument? { document as? DrawDocument }

    override var document: AnyObject? {
        didSet {
            scheduleRebuild(left: true, right: true)
            DispatchQueue.main.async { [weak self] in
                self?.canvas.zoomFit()
                self?.startLxSync()
            }
        }
    }

    static func make() -> MainWindowController {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 600)
        // Drawings open as tabs of one window rather than a window each
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "LXBookDrawDrawing"
        window.center()
        let c = MainWindowController(window: window)
        c.setup()
        return c
    }

    private func setup() {
        guard let window = window else { return }
        window.delegate = self
        let content = NSView()
        window.contentView = content

        let left = Panel.make(line: .maxX)
        let right = Panel.make(line: .minX)
        leftView = left.view
        leftStack = left.stack
        rightView = right.view
        rightStack = right.stack
        canvas.controller = self

        // Ribbon: every button just runs the command you could also type.
        ribbon.orientation = .horizontal
        ribbon.spacing = 4
        ribbon.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)
        // Lx Book's name plate at the start of the bar
        let brandText = NSMutableAttributedString(string: "Lx Book ", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .heavy), .foregroundColor: LX.caseInk
        ])
        brandText.append(NSAttributedString(string: "DRAW", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .heavy), .foregroundColor: LX.hazard, .kern: 1.2
        ]))
        let brand = NSTextField(labelWithAttributedString: brandText)
        ribbon.addArrangedSubview(brand)
        let brandGap = NSView()
        brandGap.translatesAutoresizingMaskIntoConstraints = false
        brandGap.widthAnchor.constraint(equalToConstant: 12).isActive = true
        ribbon.addArrangedSubview(brandGap)
        let groups: [(String, [(String, String)])] = [
            ("Draw", [("Line", "line"), ("Polyline", "pline"), ("Circle", "circle"), ("Rectangle", "rectang"), ("Text", "text")]),
            ("Lighting", [("Truss", "truss"), ("Fixture", "fixture"), ("Labels", "labelconfig")]),
            ("Modify", [("Move", "move"), ("Copy", "copy"), ("Rotate", "rotate"), ("Scale", "scale"), ("Erase", "erase")]),
            ("Edit", [("Undo", "u"), ("Redo", "redo"), ("Log", "log")]),
            ("View", [("Fit", "ze"), ("Window", "zoom")])
        ]
        for (title, buttons) in groups {
            let label = NSTextField(labelWithString: title.uppercased())
            label.font = NSFont.boldSystemFont(ofSize: 9)
            label.textColor = LX.hazard
            ribbon.addArrangedSubview(label)
            for (name, command) in buttons {
                let b = ClosureButton(title: name) { [weak self] _ in self?.runCommand(command) }
                b.controlSize = .small
                b.font = NSFont.systemFont(ofSize: 11)
                b.toolTip = "Command: " + command.uppercased()
                LX.barButton(b)
                ribbon.addArrangedSubview(b)
            }
            let gap = NSView()
            gap.translatesAutoresizingMaskIntoConstraints = false
            gap.widthAnchor.constraint(equalToConstant: 10).isActive = true
            ribbon.addArrangedSubview(gap)
        }
        let noteButton = ClosureButton(title: "✎ Note") { [weak self] _ in self?.writeNote(nil) }
        noteButton.toolTip = "Write an improvement note about what you're looking at (NOTE)"
        LX.barButton(noteButton, primary: true)
        ribbon.addArrangedSubview(noteButton)

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
            let b = PillButton(title: name) { [weak self] sender in
                _ = self?.perform(action, with: sender)
            }
            b.setButtonType(.pushOnPushOff)
            b.isBordered = false
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
        let lx = ClosureButton(title: "Lx Book: not linked") { [weak self] _ in self?.connectLxBook(nil) }
        lx.controlSize = .small
        lx.font = NSFont.systemFont(ofSize: 10)
        lx.toolTip = "Link this drawing to a show in Lx Book"
        lx.lineBreakMode = .byTruncatingTail
        lxButton = lx
        statusRow.addArrangedSubview(lx)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusRow.addArrangedSubview(spacer)
        let version = NSTextField(labelWithString: "LX Book Draw \(AppInfo.version)  build \(AppInfo.build)")
        version.font = NSFont.systemFont(ofSize: 10)
        version.textColor = NSColor.tertiaryLabelColor
        statusRow.addArrangedSubview(version)

        tabRow.orientation = .horizontal
        tabRow.spacing = 4
        let bottom = NSStackView(views: [historyScroll, commandRow, tabRow, statusRow])
        bottom.orientation = .vertical
        bottom.alignment = .leading
        bottom.spacing = 4
        bottom.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 6, right: 8)
        for v in [historyScroll, commandRow, tabRow, statusRow] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: bottom.widthAnchor, constant: -16).isActive = true
        }
        historyScroll.heightAnchor.constraint(equalToConstant: 56).isActive = true

        // Lx Book's look: dark flight-case bar on top, soft panel behind the command line
        let ribbonBack = FillView(LX.caseBar)
        let bottomBack = FillView(LX.soft, line: .maxY)
        for v in [ribbonBack, bottomBack, ribbon, leftView, canvas, rightView, bottom] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            ribbonBack.topAnchor.constraint(equalTo: content.topAnchor),
            ribbonBack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            ribbonBack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ribbonBack.heightAnchor.constraint(equalToConstant: 40),
            bottomBack.topAnchor.constraint(equalTo: bottom.topAnchor),
            bottomBack.bottomAnchor.constraint(equalTo: bottom.bottomAnchor),
            bottomBack.leadingAnchor.constraint(equalTo: bottom.leadingAnchor),
            bottomBack.trailingAnchor.constraint(equalTo: bottom.trailingAnchor),

            ribbon.topAnchor.constraint(equalTo: content.topAnchor),
            ribbon.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            ribbon.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor),
            ribbon.heightAnchor.constraint(equalToConstant: 40),

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
        rebuildTabs()
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
        case "lxbook", "lx", "sync": connectLxBook(nil)
        case "note": writeNote(nil)
        case "notes": showNotes(nil)
        case "dxfin", "import": importDXF(nil)
        case "dxfout", "dxf": exportDXF(nil)
        case "lc", "labelconfig", "labelcfg", "fixturelabels": labelConfig(nil)
        case "log", "history", "changelog": showLog(nil)
        case "dropbox": saveToDropbox(nil)
        case "publish": choosePublishFolder(nil)
        case "unpublish":
            doc?.edit("Stop Publishing") { $0.publishFolder = nil }
            log("The PDF copy is no longer kept up to date.")
        case "autolabel", "autolabels":
            let on = !(doc?.drawing.autoLabels ?? true)
            doc?.edit("Automatic Labels") { $0.autoLabels = on }
            log("Automatic label placement \(on ? "on" : "off")")
        case "dark", "light", "auto":
            Theme.mode = name.lowercased()
            log("Appearance: " + Theme.mode)
        case "theme", "appearance":
            Theme.mode = Theme.mode == "auto" ? "dark" : Theme.mode == "dark" ? "light" : "auto"
            log("Appearance: " + Theme.mode + " (type DARK, LIGHT or AUTO to pick one)")
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
        if !live {
            rebuildTabs()
            scheduleRebuild(left: false, right: false)
            lxSync?.drawingChanged()
        }
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
        Panel.add(ClosureButton.checkbox("Move labels apart by themselves", on: d.autoLabels ?? true) { [weak self] b in
            let on = b.state == .on
            self?.doc?.edit("Automatic Labels") { $0.autoLabels = on }
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
        if let sheet = canvas.currentSheet {
            sheetInspector(sheet, d)
            return
        }
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
            infoRow("Viewer link", d.viewerLink ?? "") { dr, s in
                let link = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if link.isEmpty {
                    dr.viewerLink = nil
                } else if link.lowercased().hasPrefix("https://") {
                    dr.viewerLink = link
                }
            }
            Panel.add(Panel.note("Viewer link: paste the link behind Lx Book's view-only QR code. It is printed as a QR code on every PDF page. Anyone with the PDF can then view the show."), to: rightStack)
            infoRow("Label size", fmtNum(d.labelSize)) { d, s in
                if let v = parseNum(s), v > 0 {
                    // Sizes set per line in Fixture Label Config grow or shrink by the same amount
                    let f = d.labelSize > 0 ? v / d.labelSize : 1
                    d.labelSize = v
                    if var parts = d.labelParts {
                        for i in parts.indices { parts[i].size *= f }
                        d.labelParts = parts
                    }
                }
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
            Panel.add(ClosureButton.checkbox("Location tag (Lx Book colours)", on: first.tag ?? false) { [weak self] b in
                let on = b.state == .on
                self?.setAll("Location Tag") { o in
                    o.tag = on ? true : nil
                    if !on { o.lxID = nil }
                }
            }, to: rightStack)
            if first.tag == true {
                Panel.add(Panel.note(d.lxBook == nil
                    ? "Type the location's name as the text. Link the drawing to Lx Book and the tag takes that location's tape colours."
                    : "The text is the location's name in Lx Book. Its tape colours come from Lx Book's Locations page and follow any change there."), to: rightStack)
            }
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
            typeStyleRows(t, d)
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

            Panel.add(Panel.heading("Label"), to: rightStack)
            numRow("Move X", first.labelDX ?? 0) { $0.labelDX = $1 }
            numRow("Move Y", first.labelDY ?? 0) { $0.labelDY = $1 }
            Panel.add(ClosureButton.checkbox("Leader arrow to the fixture", on: first.labelArrow ?? false) { [weak self] b in
                let on = b.state == .on
                self?.setAll("Label Arrow") { $0.labelArrow = on ? true : nil }
            }, to: rightStack)
            Panel.add(ClosureButton.checkbox("Keep the label level", on: first.labelLevel ?? false) { [weak self] b in
                let on = b.state == .on
                self?.setAll("Level Label") { $0.labelLevel = on ? true : nil }
            }, to: rightStack)
            Panel.add(ClosureButton(title: "Move Label by Clicking…") { [weak self] _ in self?.runCommand("label") }, to: rightStack)
            if d.lxBook != nil {
                let linked = sel.allSatisfy { $0.lxID != nil }
                Panel.add(Panel.note(linked
                    ? "Linked to Lx Book: unit ID, universe, address, position and note stay the same in both, whichever you change. Circuit comes from Lx Book's power patch."
                    : "Not in the linked Lx Book show: no fixture there has this unit ID."), to: rightStack)
            }
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

    // MARK: Improvement notes

    /// What was going on when the note was started, in plain lines, saved with the note.
    private func noteContext() -> [String] {
        var lines: [String] = []
        guard let doc = doc else { return lines }
        let d = doc.drawing
        lines.append("Drawing: " + (doc.displayName ?? "Untitled"))
        if let scene = (d.scenes ?? []).first(where: { $0.id == d.activeScene }) { lines.append("Scene: " + scene.name) }
        if let layer = d.layer(activeLayerID) { lines.append("Current layer: " + layer.name) }
        lines.append("Command line: " + promptLabel.stringValue)
        let sel = d.objects.filter { canvas.selection.contains($0.id) }
        if let first = sel.first {
            var what = kindName(first.kind)
            if first.kind == .fixture { what += " unit " + first.unit + " (" + d.fixtureType(first.typeID).displayName + ")" }
            if first.kind == .truss { what += " " + Library.trussType(first.typeID).name + (first.position.isEmpty ? "" : " at " + first.position) }
            if first.kind == .text { what += " \"" + String(first.text.prefix(40)) + "\"" }
            lines.append("Selected: \(sel.count) object\(sel.count == 1 ? "" : "s"), first is " + what)
        }
        let recent = (historyView?.string ?? "").components(separatedBy: "\n").filter { !$0.isEmpty }.suffix(3)
        if !recent.isEmpty { lines.append("Just before: " + recent.joined(separator: " | ")) }
        lines.append(d.lxBook == nil ? "Lx Book: not linked" : "Lx Book: " + (lxSync?.status ?? "linked"))
        if let w = window {
            let dark = w.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            lines.append("Screen: window \(Int(w.frame.width))×\(Int(w.frame.height)), \(dark ? "dark" : "light") mode (\(Theme.mode))")
        }
        return lines
    }

    @objc func writeNote(_ sender: Any?) {
        guard let window = window, noteEditor == nil else { return }
        let editor = NoteEditor(owner: self, context: noteContext())
        noteEditor = editor
        window.beginSheet(editor.window, completionHandler: nil)
    }

    func noteFinished() {
        noteEditor = nil
        notesList?.reload()
        focusCommandLine()
    }

    @objc func showNotes(_ sender: Any?) {
        if notesList == nil { notesList = NotesList() }
        notesList?.reload()
        notesList?.window.makeKeyAndOrderFront(nil)
    }

    // MARK: DXF

    @objc func exportDXF(_ sender: Any?) {
        guard let doc = doc, let window = window else { return }
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: "dxf") { panel.allowedContentTypes = [type] }
        panel.nameFieldStringValue = (doc.displayName ?? "Plot") + ".dxf"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try DXF.export(doc.drawing).write(to: url, atomically: true, encoding: .utf8)
                self?.log("DXF saved: " + url.lastPathComponent + " (R12 format, millimetres, every layer)")
            } catch {
                self?.log("The DXF couldn't be saved: " + error.localizedDescription)
            }
        }
    }

    @objc func importDXF(_ sender: Any?) {
        guard let window = window else { return }
        let panel = NSOpenPanel()
        if let type = UTType(filenameExtension: "dxf") { panel.allowedContentTypes = [type] }
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self, let doc = self.doc else { return }
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                self.log("That file couldn't be read.")
                return
            }
            if text.hasPrefix("AutoCAD Binary DXF") {
                self.log("That is a binary DXF. Save it as an ordinary (ASCII) DXF and import that.")
                return
            }
            var result = DXF.ImportResult()
            doc.edit("Import DXF") { d in result = DXF.importText(text, into: &d) }
            var line = "DXF imported: \(result.added) objects"
            if result.layers > 0 { line += ", \(result.layers) new layers" }
            if !result.skipped.isEmpty {
                line += ". Left out: " + result.skipped.map { "\($0.value) \($0.key)" }.sorted().joined(separator: ", ")
            }
            self.log(line)
            self.canvas.zoomFit()
        }
    }

    // MARK: Groups and labels

    @objc func groupAction(_ sender: Any?) { runCommand("group") }
    @objc func ungroupAction(_ sender: Any?) { runCommand("ungroup") }
    @objc func labelAction(_ sender: Any?) { runCommand("label") }

    // MARK: Lx Book

    func lxStatusChanged() {
        let text = lxSync?.status ?? "Lx Book: not linked"
        lxButton?.title = text
        lxButton?.toolTip = text
        log(text)
    }

    func startLxSync() {
        lxSync?.stop()
        lxSync = nil
        guard let link = doc?.drawing.lxBook else {
            lxButton?.title = "Lx Book: not linked"
            return
        }
        let sync = LxBookSync(link: link, controller: self)
        if doc?.drawing.inShow == true { sync.show = ShowStore(sync: sync, showID: link.showID) }
        lxSync = sync
        lxButton?.title = "Lx Book: connecting…"
        sync.start()
    }

    func windowWillClose(_ notification: Notification) {
        lxSync?.stop()
        lxSync = nil
    }

    // MARK: Fixture Label Config

    /// Chooses what each fixture's label shows, in what order, and how big each line is.
    @objc func labelConfig(_ sender: Any?) {
        guard let doc = doc, let window = window else { return }
        let form = LabelConfigForm(parts: doc.drawing.effectiveLabelParts, background: doc.drawing.labelBackground ?? true)
        let alert = NSAlert()
        alert.messageText = "Fixture Label Config"
        alert.informativeText = "Tick what each fixture's label shows. Sizes are text heights in millimetres at full scale. The arrows change the order, top line first."
        alert.accessoryView = form.view
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response != .alertFirstButtonReturn { return }
            form.read()
            let parts = form.parts
            let backed = form.background.state == .on
            doc.edit("Fixture Label Config") { d in
                d.labelParts = parts
                d.labelBackground = backed ? nil : false
            }
        }
    }

    // MARK: Change log

    @objc func showLog(_ sender: Any?) {
        guard let doc = doc, let window = window else { return }
        let entries = doc.drawing.history ?? []
        let text = entries.isEmpty ? "Nothing yet. Every change made from now on is listed here, newest first."
            : entries.reversed().map { $0.ts + "   " + $0.what }.joined(separator: "\n")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 320))
        view.isEditable = false
        view.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        view.autoresizingMask = [.width]
        view.string = text
        scroll.documentView = view
        let alert = NSAlert()
        alert.messageText = "Change log"
        alert.informativeText = "The last \(entries.count) changes to this drawing. Undo and Redo step back and forward through them."
        alert.accessoryView = scroll
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    // MARK: Dropbox

    /// The Dropbox folder on this Mac, if the Dropbox app is installed.
    static func dropboxFolder() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let cloud = home.appendingPathComponent("Library/CloudStorage")
        if let names = try? fm.contentsOfDirectory(atPath: cloud.path),
           let name = names.sorted().first(where: { $0.hasPrefix("Dropbox") }) {
            return cloud.appendingPathComponent(name)
        }
        let old = home.appendingPathComponent("Dropbox")
        return fm.fileExists(atPath: old.path) ? old : nil
    }

    private func tell(_ title: String, _ text: String) {
        guard let window = window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    /// Saves the drawing into Dropbox. From then on every change is saved there two seconds after it is made.
    @objc func saveToDropbox(_ sender: Any?) {
        guard let doc = doc, let window = window else { return }
        guard let box = MainWindowController.dropboxFolder() else {
            tell("Dropbox", "No Dropbox folder was found on this Mac. Install the Dropbox app and sign in, then try again.")
            return
        }
        let folder = box.appendingPathComponent("LX Book Draw")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let panel = NSSavePanel()
        panel.directoryURL = folder
        panel.nameFieldStringValue = doc.fileURL?.lastPathComponent ?? "Untitled.lxdraw"
        if let type = UTType(filenameExtension: "lxdraw") { panel.allowedContentTypes = [type] }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            doc.save(to: url, ofType: lxDrawType, for: .saveAsOperation) { error in
                if let error = error {
                    self?.log("Could not save to Dropbox: " + error.localizedDescription)
                } else {
                    self?.log("Saved to Dropbox. Every change is now saved there as you work.")
                }
            }
        }
    }

    /// Picks a folder that always holds an up-to-date PDF of this drawing. Pointed at the show's folder
    /// in Dropbox (Lx Book / show name), the plot appears in Lx Book's Plots & files.
    @objc func choosePublishFolder(_ sender: Any?) {
        guard let doc = doc, let window = window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Keep a PDF Here"
        panel.message = "Choose the folder that should always hold a PDF of this drawing. For Lx Book, choose the show's folder inside Dropbox / Lx Book."
        if let box = MainWindowController.dropboxFolder() {
            let fm = FileManager.default
            let root = box.appendingPathComponent("Lx Book")
            let show = root.appendingPathComponent(doc.drawing.lxBook?.showName ?? "")
            if doc.drawing.lxBook != nil && fm.fileExists(atPath: show.path) {
                panel.directoryURL = show
            } else if fm.fileExists(atPath: root.path) {
                panel.directoryURL = root
            } else {
                panel.directoryURL = box
            }
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            doc.edit("Publish Folder") { $0.publishFolder = url.path }
            doc.publish(force: true)
            if doc.fileURL == nil {
                self?.log("PDF written to " + url.lastPathComponent + ". Save the drawing and the PDF will then follow every change.")
            } else {
                self?.log("A PDF of this drawing is now kept up to date in " + url.lastPathComponent + ". UNPUBLISH stops it.")
            }
        }
    }

    private func lxAlert(_ text: String) {
        guard let window = window else { return }
        let alert = NSAlert()
        alert.messageText = "Lx Book"
        alert.informativeText = text
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    /// Links this drawing to the show that is open in Lx Book for the key's account.
    /// File > Move This Drawing into the Lx Book Show: the linked show becomes the home of this drawing.
    @objc func moveIntoShow(_ sender: Any?) {
        guard let doc = doc else { return }
        if doc.drawing.inShow == true {
            lxAlert("This drawing already lives in its Lx Book show.")
            return
        }
        guard let link = doc.drawing.lxBook else {
            lxAlert("Link this drawing to its show first (File > Link to Lx Book), then move it in.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Move this drawing into \"\(link.showName)\" in Lx Book?"
        alert.informativeText = "The drawing will be kept in the show itself and saved there as you work. It is sent only if the show has no drawing yet. This file stays where it is, unchanged, and is no longer the one you work on."
        alert.addButton(withTitle: "Move It In")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() != .alertFirstButtonReturn { return }
        DocController.openWorkingCopy(link, starting: doc.drawing)
    }

    @objc func connectLxBook(_ sender: Any?) {
        guard let doc = doc else { return }
        if doc.drawing.inShow == true {
            lxAlert("This drawing lives in the Lx Book show \"\(doc.drawing.lxBook?.showName ?? "")\". To work on another show, open it in Lx Book and use File > Open Show from Lx Book.")
            return
        }
        let current = doc.drawing.lxBook
        let alert = NSAlert()
        alert.messageText = current == nil ? "Link this drawing to Lx Book" : "Linked to \"\(current?.showName ?? "")\" in Lx Book"
        alert.informativeText = "Enter your Lx Book address and a key. Make the key in Lx Book under Settings, in the Vectorworks card. The drawing links to the show you have open in Lx Book; fixtures are matched by unit ID."
        let server = NSTextField(string: current?.server ?? LxSettings.server)
        server.placeholderString = "https://your-server/book"
        server.frame = NSRect(x: 0, y: 30, width: 340, height: 24)
        let key = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        key.placeholderString = "Lx Book key (leave empty to use the one already saved)"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 56))
        box.addSubview(server)
        box.addSubview(key)
        alert.accessoryView = box
        alert.addButton(withTitle: current == nil ? "Link" : "Link Again")
        alert.addButton(withTitle: "Cancel")
        if current != nil { alert.addButton(withTitle: "Unlink") }
        let answer = alert.runModal()
        if answer == .alertThirdButtonReturn {
            doc.edit("Unlink from Lx Book") { d in
                d.lxBook = nil
                for i in d.objects.indices { d.objects[i].lxID = nil }
            }
            startLxSync()
            log("Lx Book: unlinked. Nothing was changed in Lx Book.")
            return
        }
        if answer != .alertFirstButtonReturn { return }
        let address = LxSettings.tidy(server.stringValue)
        if address.isEmpty {
            lxAlert("Enter the address you open Lx Book at, for example https://your-server/book.")
            return
        }
        if !key.stringValue.isEmpty { LxSettings.setKey(key.stringValue.trimmingCharacters(in: .whitespaces), for: address) }
        guard let saved = LxSettings.key(for: address) else {
            lxAlert("Enter an Lx Book key. Make one in Lx Book under Settings, in the Vectorworks card.")
            return
        }
        LxSettings.server = address
        log("Lx Book: connecting to " + address)
        LxBookSync.request(server: address, key: saved, session: URLSession.shared, method: "GET", path: "api/health") { [weak self] result in
            guard let self = self, let doc = self.doc else { return }
            switch result {
            case .failure(let e):
                self.lxAlert(e.message)
            case .success(let j):
                let id = LxBookSync.text(j["show"])
                if id.isEmpty {
                    self.lxAlert("Lx Book answered, but no show is open for this account. Open the show in Lx Book and try again.")
                    return
                }
                let link = LxLink(server: address, showID: id, showName: LxBookSync.text(j["showName"]))
                doc.edit("Link to Lx Book") { d in
                    if d.lxBook?.showID != id {
                        for i in d.objects.indices { d.objects[i].lxID = nil }
                    }
                    d.lxBook = link
                }
                self.startLxSync()
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

// MARK: - Sheets (paper space): the tabs under the command line, and Object Info for a sheet

extension MainWindowController {
    static let paperSizes: [(name: String, w: Double, h: Double)] = [
        ("A4", 297, 210), ("A3", 420, 297), ("A2", 594, 420), ("A1", 841, 594), ("A0", 1189, 841),
        ("Tabloid 11 x 17 in", 431.8, 279.4), ("Arch D 36 x 24 in", 914.4, 609.6)
    ]

    /// Model and one tab per sheet, as along the bottom of AutoCAD.
    func rebuildTabs() {
        for v in tabRow.arrangedSubviews {
            tabRow.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        let current = canvas.sheetID
        func tab(_ title: String, on: Bool, _ id: UUID?) {
            let b = PillButton(title: title) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.canvas.showSheet(id)
                    self?.rebuildTabs()
                }
            }
            b.setButtonType(.pushOnPushOff)
            b.isBordered = false
            b.state = on ? .on : .off
            b.toolTip = id == nil ? "The drawing itself" : "A sheet of the PDF"
            tabRow.addArrangedSubview(b)
        }
        tab("Model", on: current == nil, nil)
        for sheet in doc?.drawing.sheets ?? [] {
            tab(sheet.name.isEmpty ? "Sheet" : sheet.name, on: sheet.id == current, sheet.id)
        }
        let add = PillButton(title: "+") { [weak self] sender in
            guard let self = self else { return }
            let menu = NSMenu()
            let one = NSMenuItem(title: "New Sheet", action: #selector(MainWindowController.newSheet(_:)), keyEquivalent: "")
            one.target = self
            menu.addItem(one)
            if !(self.doc?.drawing.scenes ?? []).isEmpty {
                let all = NSMenuItem(title: "A Sheet for Every Scene", action: #selector(MainWindowController.sheetsFromScenes(_:)), keyEquivalent: "")
                all.target = self
                menu.addItem(all)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
            sender.state = .off
        }
        add.isBordered = false
        add.toolTip = "Add a sheet"
        tabRow.addArrangedSubview(add)
        let hint = NSTextField(labelWithString: (doc?.drawing.sheets ?? []).isEmpty ? "Sheets are the pages of the PDF. + adds one." : "")
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = LX.muted
        tabRow.addArrangedSubview(hint)
    }

    func sheetChanged() {
        rebuildTabs()
        selectionChanged()
    }

    @objc func newSheet(_ sender: Any?) {
        guard let doc = doc else { return }
        let count = (doc.drawing.sheets ?? []).count
        let sheet = Sheet.make(name: "Sheet \(count + 1)", layers: nil, for: doc.drawing)
        doc.edit("New Sheet") { d in
            var sheets = d.sheets ?? []
            sheets.append(sheet)
            d.sheets = sheets
        }
        canvas.showSheet(sheet.id)
        rebuildTabs()
        log("Sheet made with one viewport showing the whole drawing. Double-click inside the viewport to slide the view; MV adds another viewport; T adds text. The sheets are the pages of the PDF.")
    }

    @objc func sheetsFromScenes(_ sender: Any?) {
        guard let doc = doc else { return }
        let scenes = doc.drawing.scenes ?? []
        if scenes.isEmpty { return }
        var made: [Sheet] = []
        for scene in scenes {
            made.append(Sheet.make(name: scene.name, layers: scene.visibleLayers, for: doc.drawing))
        }
        doc.edit("Sheets from Scenes") { d in
            var sheets = d.sheets ?? []
            sheets.append(contentsOf: made)
            d.sheets = sheets
        }
        if let first = made.first { canvas.showSheet(first.id) }
        rebuildTabs()
        log("Made \(made.count) sheets, one for each scene.")
    }

    private func editViewport(_ id: UUID, _ name: String, _ change: @escaping (inout Viewport) -> Void) {
        canvas.editSheet(name) { s in
            if let i = s.viewports.firstIndex(where: { $0.id == id }) { change(&s.viewports[i]) }
        }
    }

    /// Object Info while a sheet is showing: the sheet itself, or the viewport or text selected on it.
    fileprivate func sheetInspector(_ sheet: Sheet, _ d: Drawing) {
        if let v = sheet.viewports.first(where: { $0.id == canvas.sheetSel }) {
            viewportInspector(v, sheet, d)
            return
        }
        if let o = sheet.objects.first(where: { $0.id == canvas.sheetSel }) {
            Panel.add(Panel.heading("Text on the Sheet"), to: rightStack)
            let id = o.id
            Panel.add(Panel.row("Text", ClosureField(value: o.text) { [weak self] s in
                self?.canvas.editSheet("Change Text") { sh in
                    if let i = sh.objects.firstIndex(where: { $0.id == id }) { sh.objects[i].text = s }
                }
            }), to: rightStack)
            Panel.add(Panel.row("Height mm", ClosureField(value: fmtNum(o.textSize)) { [weak self] s in
                guard let v = parseNum(s), v > 0 else { return }
                self?.canvas.editSheet("Change Text Size") { sh in
                    if let i = sh.objects.firstIndex(where: { $0.id == id }) { sh.objects[i].textSize = v }
                }
            }), to: rightStack)
            Panel.add(ClosureButton(title: "Erase") { [weak self] _ in self?.canvas.eraseSelection() }, to: rightStack)
            return
        }

        Panel.add(Panel.heading("Sheet"), to: rightStack)
        Panel.add(Panel.note("A page of the PDF. This is what Lx Book shows once the drawing is linked."), to: rightStack)
        Panel.add(Panel.row("Name", ClosureField(value: sheet.name) { [weak self] s in
            let name = s.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { return }
            self?.canvas.editSheet("Rename Sheet") { $0.name = name }
        }), to: rightStack)

        let sizes = MainWindowController.paperSizes
        let long = max(sheet.w, sheet.h)
        let short = min(sheet.w, sheet.h)
        let sizeIndex = sizes.firstIndex { abs($0.w - long) < 1 && abs($0.h - short) < 1 } ?? 1
        let portrait = sheet.h > sheet.w
        Panel.add(Panel.row("Paper", ClosurePopup(items: sizes.map { $0.name }, selected: sizeIndex) { [weak self] i in
            let size = sizes[i]
            self?.canvas.editSheet("Paper Size") { s in
                s.w = portrait ? size.h : size.w
                s.h = portrait ? size.w : size.h
            }
            self?.canvas.zoomFit()
        }), to: rightStack)
        Panel.add(Panel.row("Turned", ClosurePopup(items: ["Landscape", "Portrait"], selected: portrait ? 1 : 0) { [weak self] i in
            self?.canvas.editSheet("Paper Direction") { s in
                let a = max(s.w, s.h)
                let b = min(s.w, s.h)
                s.w = i == 1 ? b : a
                s.h = i == 1 ? a : b
            }
            self?.canvas.zoomFit()
        }), to: rightStack)
        Panel.add(ClosureButton.checkbox("Key and title block", on: sheet.panel != false) { [weak self] b in
            let on = b.state == .on
            self?.canvas.editSheet("Key and Title Block") { $0.panel = on ? nil : false }
        }, to: rightStack)

        Panel.add(Panel.heading("Viewport Layout"), to: rightStack)
        Panel.add(Panel.note("Replaces this sheet's viewports. Each takes the next scene in turn."), to: rightStack)
        let grids: [(String, Int, Int)] = [("One", 1, 1), ("Two Side by Side", 2, 1), ("Two Top and Bottom", 1, 2), ("Four", 2, 2)]
        for (title, cols, rows) in grids {
            Panel.add(ClosureButton(title: title) { [weak self] _ in
                guard let self = self, let now = self.doc?.drawing else { return }
                self.canvas.editSheet("Viewport Layout") { $0.setGrid(columns: cols, rows: rows, for: now) }
            }, to: rightStack)
        }

        Panel.add(Panel.heading("Add"), to: rightStack)
        Panel.add(ClosureButton(title: "Viewport (MV)") { [weak self] _ in self?.runCommand("mv") }, to: rightStack)
        Panel.add(ClosureButton(title: "Text (T)") { [weak self] _ in self?.runCommand("text") }, to: rightStack)

        Panel.add(Panel.heading("This Sheet"), to: rightStack)
        let sheetID = sheet.id
        Panel.add(ClosureButton(title: "Duplicate") { [weak self] _ in
            guard let self = self, let doc = self.doc else { return }
            var copy = sheet
            copy.id = UUID()
            copy.name = sheet.name + " copy"
            for i in copy.viewports.indices { copy.viewports[i].id = UUID() }
            for i in copy.objects.indices { copy.objects[i].id = UUID() }
            doc.edit("Duplicate Sheet") { d in
                var sheets = d.sheets ?? []
                sheets.append(copy)
                d.sheets = sheets
            }
            self.canvas.showSheet(copy.id)
            self.rebuildTabs()
        }, to: rightStack)
        Panel.add(ClosureButton(title: "Move Earlier") { [weak self] _ in
            self?.doc?.edit("Reorder Sheets") { d in
                guard var sheets = d.sheets, let i = sheets.firstIndex(where: { $0.id == sheetID }), i > 0 else { return }
                sheets.swapAt(i, i - 1)
                d.sheets = sheets
            }
            self?.rebuildTabs()
        }, to: rightStack)
        Panel.add(ClosureButton(title: "Delete Sheet") { [weak self] _ in
            guard let self = self else { return }
            self.canvas.showSheet(nil)
            self.doc?.edit("Delete Sheet") { d in
                guard var sheets = d.sheets else { return }
                sheets.removeAll { $0.id == sheetID }
                d.sheets = sheets.isEmpty ? nil : sheets
            }
            self.rebuildTabs()
        }, to: rightStack)
    }

    private func viewportInspector(_ v: Viewport, _ sheet: Sheet, _ d: Drawing) {
        Panel.add(Panel.heading("Viewport"), to: rightStack)
        Panel.add(Panel.note("A window onto the drawing. Double-click inside it to slide the view; drag its corners to resize it."), to: rightStack)
        let id = v.id
        var scales = Viewport.scales
        if !scales.contains(where: { abs($0 - v.scale) < 0.01 }) {
            scales.append(v.scale)
            scales.sort()
        }
        let scaleIndex = scales.firstIndex { abs($0 - v.scale) < 0.01 } ?? 0
        Panel.add(Panel.row("Scale", ClosurePopup(items: scales.map { "1:" + fmtNum(($0 * 10).rounded() / 10) }, selected: scaleIndex) { [weak self] i in
            let picked = scales[i]
            self?.editViewport(id, "Viewport Scale") { $0.scale = picked }
        }), to: rightStack)
        Panel.add(Panel.row("Scale 1:", ClosureField(value: fmtNum((v.scale * 10).rounded() / 10)) { [weak self] s in
            guard let n = parseNum(s), n >= 1 else { return }
            self?.editViewport(id, "Viewport Scale") { $0.scale = n }
        }), to: rightStack)
        Panel.add(ClosureButton.checkbox("Locked (view can't be slid or zoomed)", on: v.locked == true) { [weak self] b in
            let on = b.state == .on
            self?.editViewport(id, "Lock Viewport") { $0.locked = on ? true : nil }
        }, to: rightStack)
        Panel.add(ClosureButton.checkbox("Print the edge", on: v.frame != false) { [weak self] b in
            let on = b.state == .on
            self?.editViewport(id, "Viewport Edge") { $0.frame = on ? nil : false }
        }, to: rightStack)
        Panel.add(Panel.row("Width mm", ClosureField(value: fmtNum(v.w.rounded())) { [weak self] s in
            guard let n = parseNum(s), n >= 10 else { return }
            self?.editViewport(id, "Viewport Size") { $0.w = n }
        }), to: rightStack)
        Panel.add(Panel.row("Height mm", ClosureField(value: fmtNum(v.h.rounded())) { [weak self] s in
            guard let n = parseNum(s), n >= 10 else { return }
            self?.editViewport(id, "Viewport Size") { $0.h = n }
        }), to: rightStack)
        let area = sheet.drawArea
        Panel.add(ClosureButton(title: "Fit the Drawing in It") { [weak self] _ in
            self?.editViewport(id, "Fit Viewport") { $0.fit(d) }
        }, to: rightStack)
        Panel.add(ClosureButton(title: "Fill the Sheet") { [weak self] _ in
            self?.editViewport(id, "Fill Sheet") { vp in
                vp.x = Double(area.minX)
                vp.y = Double(area.minY)
                vp.w = Double(area.width)
                vp.h = Double(area.height)
                vp.fit(d)
            }
        }, to: rightStack)

        // The scene this viewport shows. It is the viewport's own setting: the Model tab can show something else.
        let shown = Set(v.layers ?? d.layers.filter { $0.visible }.map { $0.id })
        let scenes = d.scenes ?? []
        if !scenes.isEmpty {
            var sceneNames = scenes.map { $0.name }
            sceneNames.append("Own choice of layers")
            let sceneIndex = scenes.firstIndex { Set($0.visibleLayers) == shown } ?? scenes.count
            Panel.add(Panel.row("Scene", ClosurePopup(items: sceneNames, selected: sceneIndex) { [weak self] i in
                if i >= scenes.count { return }
                let layers = scenes[i].visibleLayers
                self?.editViewport(id, "Viewport Scene") { vp in
                    vp.layers = layers
                    if vp.locked != true { vp.fit(d) }
                }
            }), to: rightStack)
        }

        Panel.add(Panel.heading("Layers Showing Here"), to: rightStack)
        let order = d.layers.map { $0.id }
        for layer in d.layers {
            let layerID = layer.id
            Panel.add(ClosureButton.checkbox(layer.name, on: shown.contains(layerID)) { [weak self] b in
                let on = b.state == .on
                self?.editViewport(id, "Viewport Layers") { vp in
                    var set = shown
                    if on { set.insert(layerID) } else { set.remove(layerID) }
                    vp.layers = order.filter { set.contains($0) }
                }
            }, to: rightStack)
        }
        Panel.add(ClosureButton(title: "Erase Viewport") { [weak self] _ in self?.canvas.eraseSelection() }, to: rightStack)
    }

    /// Colour and Easy ID of a fixture type, shown for a selected fixture.
    fileprivate func typeStyleRows(_ t: FixtureDef, _ d: Drawing) {
        let typeID = t.id
        let style = d.typeStyles?[typeID] ?? TypeStyle()
        var names = ["None"]
        var colors: [RGBA?] = [nil]
        for tint in TypeStyle.tints {
            names.append(tint.name)
            colors.append(tint.color)
        }
        let index = colors.firstIndex { $0 == style.color } ?? 0
        Panel.add(Panel.row("Symbol colour", ClosurePopup(items: names, selected: index) { [weak self] i in
            let picked = colors[i]
            self?.doc?.edit("Symbol Colour") { dr in
                var styles = dr.typeStyles ?? [:]
                var s = styles[typeID] ?? TypeStyle()
                s.color = picked
                styles[typeID] = s
                dr.typeStyles = styles
            }
        }), to: rightStack)
        Panel.add(Panel.row("Easy ID", ClosureField(value: style.easyID ?? "") { [weak self] text in
            let letters = String(text.trimmingCharacters(in: .whitespaces).prefix(4))
            self?.doc?.edit("Easy ID") { dr in
                var styles = dr.typeStyles ?? [:]
                var s = styles[typeID] ?? TypeStyle()
                s.easyID = letters.isEmpty ? nil : letters
                styles[typeID] = s
                dr.typeStyles = styles
            }
        }), to: rightStack)
        Panel.add(Panel.note("Colour and Easy ID apply to every " + t.displayName + " in the drawing. Easy ID is a letter or two in a box on the symbol, such as K."), to: rightStack)
    }
}
