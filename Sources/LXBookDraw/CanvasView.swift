import AppKit

/// Commands that can be running, AutoCAD style: a command prompts for points or values on the
/// command line until it is finished with Enter or cancelled with Esc.
enum Cmd {
    case none, line, pline, circle, rect, text, move, copy, rotate, erase, truss, fixture, zoom, zoomWindow, layer, scene

    var name: String {
        switch self {
        case .none: return ""
        case .line: return "LINE"
        case .pline: return "PLINE"
        case .circle: return "CIRCLE"
        case .rect: return "RECTANG"
        case .text: return "TEXT"
        case .move: return "MOVE"
        case .copy: return "COPY"
        case .rotate: return "ROTATE"
        case .erase: return "ERASE"
        case .truss: return "TRUSS"
        case .fixture: return "FIXTURE"
        case .zoom, .zoomWindow: return "ZOOM"
        case .layer: return "LAYER"
        case .scene: return "SCENE"
        }
    }
}

final class CanvasView: NSView {
    weak var controller: MainWindowController?
    var doc: DrawDocument? { controller?.doc }

    // View: screen point = (drawing mm - offset) * scale
    var scale: CGFloat = 0.05
    var offset = CGPoint(x: -2000, y: -2000)

    var selection = Set<UUID>() {
        didSet {
            if selection != oldValue {
                controller?.selectionChanged()
                needsDisplay = true
            }
        }
    }

    // Running command
    private(set) var cmd = Cmd.none
    private var lastCmd = Cmd.none
    private var pts: [CGPoint] = []
    private var step = 0
    private var selecting = false
    private var made: [UUID] = []
    private var snapOverride: SnapKind? = nil
    private var textHeight = 250.0

    // Cursor
    private var mouseView: CGPoint? = nil
    private var cursor = CGPoint.zero
    private var snapHit: SnapHit? = nil
    private var tracking: NSTrackingArea? = nil

    // Selection window (two clicks or a drag)
    private var windowStart: CGPoint? = nil
    private var windowEnd = CGPoint.zero

    // Press and drag
    private var pressView = CGPoint.zero
    private var pressWorld = CGPoint.zero
    private var pressedObject = false
    private var pressedEmpty = false
    private var draggingWindow = false
    private var panning = false
    private var panLast = CGPoint.zero
    private var snapshot: Drawing? = nil
    private var moveIDs = Set<UUID>()
    private var didMove = false

    static let pasteType = NSPasteboard.PasteboardType("com.picton.lxbookdraw.objects")
    private static let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in true },
                                              hotSpot: NSPoint(x: 8, y: 8))

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: CanvasView.blankCursor)
    }

    // MARK: Coordinates

    func toWorld(_ vp: CGPoint) -> CGPoint {
        CGPoint(x: vp.x / scale + offset.x, y: vp.y / scale + offset.y)
    }

    func toView(_ wp: CGPoint) -> CGPoint {
        CGPoint(x: (wp.x - offset.x) * scale, y: (wp.y - offset.y) * scale)
    }

    private func eventPoint(_ e: NSEvent) -> CGPoint {
        convert(e.locationInWindow, from: nil)
    }

    /// True while the running command is asking for a point.
    private var wantsPoint: Bool {
        if selecting { return false }
        switch cmd {
        case .none, .erase, .zoom, .layer, .scene: return false
        case .text: return step == 0
        default: return true
        }
    }

    /// True while typed spaces are part of the answer (text, names) rather than Enter.
    var wantsRawText: Bool {
        (cmd == .text && step == 2) || cmd == .layer || cmd == .scene
    }

    /// Turns a raw cursor position into the point a click would give: object snap first,
    /// then ortho, then grid snap. Same order of precedence as AutoCAD.
    private func resolve(_ raw: CGPoint) -> CGPoint {
        snapHit = nil
        guard let d = doc?.drawing else { return raw }
        var modes = Set<SnapKind>()
        if let o = snapOverride {
            modes = [o]
        } else if Drafting.osnap {
            modes = Drafting.modes
        }
        if let hit = Snapper.find(near: raw, in: d, aperture: 11 / scale, modes: modes, from: pts.last) {
            snapHit = hit
            return hit.point
        }
        if Drafting.ortho, let ref = pts.last {
            if abs(raw.x - ref.x) >= abs(raw.y - ref.y) {
                return CGPoint(x: raw.x, y: ref.y)
            }
            return CGPoint(x: ref.x, y: raw.y)
        }
        if d.snapGrid && d.gridSize > 0 {
            let g = CGFloat(d.gridSize)
            return CGPoint(x: (raw.x / g).rounded() * g, y: (raw.y / g).rounded() * g)
        }
        return raw
    }

    // MARK: Zoom

    func zoom(by factor: CGFloat, at vp: CGPoint) {
        let w = toWorld(vp)
        scale = max(0.002, min(5, scale * factor))
        offset = CGPoint(x: w.x - vp.x / scale, y: w.y - vp.y / scale)
        needsDisplay = true
    }

    func zoomCentre(by factor: CGFloat) {
        zoom(by: factor, at: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    func zoomTo(_ rect: CGRect) {
        var r = rect
        if r.isNull || r.width < 1 || r.height < 1 {
            r = CGRect(x: -2000, y: -2000, width: 24000, height: 14000)
        }
        if bounds.width < 10 || bounds.height < 10 { return }
        let s = min(bounds.width / r.width, bounds.height / r.height) * 0.92
        scale = max(0.002, min(5, s))
        offset = CGPoint(x: r.midX - bounds.width / (2 * scale), y: r.midY - bounds.height / (2 * scale))
        needsDisplay = true
    }

    func zoomFit() {
        zoomTo(doc?.drawing.extents() ?? CGRect.null)
    }

    // MARK: Command line plumbing

    private func log(_ s: String) {
        controller?.log(s)
    }

    private func refreshPrompt() {
        controller?.setPrompt(promptText)
        needsDisplay = true
    }

    private var promptText: String {
        if windowStart != nil { return "Specify opposite corner:" }
        if selecting { return "\(cmd.name)  Select objects (\(selection.count) selected), then press Enter:" }
        switch cmd {
        case .none: return "Command:"
        case .line: return pts.isEmpty ? "LINE  Specify first point:" : "LINE  Specify next point or [Close/Undo]:"
        case .pline: return pts.isEmpty ? "PLINE  Specify start point:" : "PLINE  Specify next point or [Close/Undo]:"
        case .circle: return pts.isEmpty ? "CIRCLE  Specify center point:" : "CIRCLE  Specify radius:"
        case .rect: return pts.isEmpty ? "RECTANG  Specify first corner point:" : "RECTANG  Specify other corner point:"
        case .text:
            if step == 0 { return "TEXT  Specify start point:" }
            if step == 1 { return "TEXT  Specify height <\(fmtNum(textHeight))>:" }
            return "TEXT  Enter text:"
        case .move: return pts.isEmpty ? "MOVE  Specify base point:" : "MOVE  Specify second point:"
        case .copy: return pts.isEmpty ? "COPY  Specify base point:" : "COPY  Specify second point or <exit>:"
        case .rotate: return pts.isEmpty ? "ROTATE  Specify base point:" : "ROTATE  Specify rotation angle:"
        case .erase: return "ERASE"
        case .truss:
            let type = Library.trussType(controller?.currentTrussType ?? "").name
            return pts.isEmpty ? "TRUSS (\(type))  Specify start point or <exit>:" : "TRUSS (\(type))  Specify end point:"
        case .fixture:
            let type = doc?.drawing.fixtureType(controller?.currentFixtureType ?? "").displayName ?? ""
            return "FIXTURE (\(type))  Specify insertion point or <exit>:"
        case .zoom: return "ZOOM  [Extents/Window] <Extents>:"
        case .zoomWindow: return pts.isEmpty ? "ZOOM  Specify first corner:" : "ZOOM  Specify opposite corner:"
        case .layer: return "LAYER  Enter layer name to make current:"
        case .scene:
            let names = (doc?.drawing.scenes ?? []).map { $0.name }.joined(separator: "/")
            return "SCENE  Enter scene name [\(names)]:"
        }
    }

    static let helpText = """
    Draw: L line, PL polyline, C circle, REC rectangle, T text, TR truss, FX fixture
    Modify: M move, CO copy, RO rotate, E erase, U undo, REDO
    View: Z zoom (E extents, W window), ZE zoom extents, LA layer, SC scene
    Points: click, or type x,y  @dx,dy  @dist<angle  or a distance in the cursor's direction
    Snaps: F3 osnap, F8 ortho, F9 grid snap, F7 grid. Type END MID CEN INS QUA INT PER NEA at a point prompt for one pick
    Other: GDTF, PDF, UPDATE, SAVE. Space or Enter repeats the last command, Esc cancels
    """

    /// Starts a command by name or alias. Returns false if the name is not a canvas command.
    @discardableResult
    func run(_ name: String) -> Bool {
        let n = name.lowercased()
        var next: Cmd? = nil
        switch n {
        case "l", "line": next = .line
        case "pl", "pline", "polyline": next = .pline
        case "c", "circle": next = .circle
        case "rec", "rectang", "rectangle": next = .rect
        case "t", "dt", "mt", "text", "mtext": next = .text
        case "m", "move": next = .move
        case "co", "cp", "copy": next = .copy
        case "ro", "rotate": next = .rotate
        case "e", "erase", "del", "delete": next = .erase
        case "tr", "truss": next = .truss
        case "fx", "f", "fixture", "ld", "hoist": next = .fixture
        case "z", "zoom": next = .zoom
        case "la", "layer": next = .layer
        case "sc", "scene", "view": next = .scene
        default: break
        }
        if let c = next {
            start(c)
            return true
        }
        switch n {
        case "ze":
            zoomFit()
        case "u", "undo":
            doc?.undoManager?.undo()
        case "redo":
            doc?.undoManager?.redo()
        case "os", "osnap":
            Drafting.osnap = !Drafting.osnap
            log("Object snap \(Drafting.osnap ? "on" : "off")")
        case "ortho":
            Drafting.ortho = !Drafting.ortho
            log("Ortho \(Drafting.ortho ? "on" : "off")")
        case "grid":
            Drafting.showGrid = !Drafting.showGrid
        case "help", "?":
            log(CanvasView.helpText)
        default:
            return false
        }
        controller?.refreshStatus()
        needsDisplay = true
        return true
    }

    private func start(_ c: Cmd) {
        if cmd != .none { endCommand() }
        cmd = c
        lastCmd = c
        pts = []
        step = 0
        made = []
        snapOverride = nil
        windowStart = nil
        selecting = false
        switch c {
        case .move, .copy, .rotate:
            selecting = selection.isEmpty
        case .erase:
            if selection.isEmpty {
                selecting = true
            } else {
                eraseSelection()
                endCommand()
                return
            }
        default:
            break
        }
        refreshPrompt()
    }

    private func endCommand() {
        cmd = .none
        pts = []
        step = 0
        made = []
        selecting = false
        snapOverride = nil
        snapHit = nil
        windowStart = nil
        refreshPrompt()
    }

    /// True while the command line is waiting for words rather than a command or coordinates,
    /// so Space must type a space instead of acting as Enter.
    var wantsFreeText: Bool {
        (cmd == .text && step == 2) || cmd == .layer || cmd == .scene
    }

    /// Esc: cancel the command, or the selection window, or clear the selection.
    func escape() {
        if pressedObject, let snap = snapshot { doc?.setLive(snap) }
        pressedObject = false
        pressedEmpty = false
        snapshot = nil
        if cmd != .none {
            if cmd == .pline { pts = [] }
            log("*Cancel*")
            endCommand()
        } else if windowStart != nil {
            windowStart = nil
            refreshPrompt()
        } else {
            selection = []
        }
    }

    /// Reads typed coordinates: x,y  @dx,dy  @dist<angle  dist<angle.
    private func parsePoint(_ text: String) -> CGPoint? {
        var s = text.replacingOccurrences(of: " ", with: "")
        var relative = false
        if s.hasPrefix("@") {
            relative = true
            s.removeFirst()
        }
        let ref = pts.last ?? CGPoint.zero
        if s.contains("<") {
            let parts = s.split(separator: "<", omittingEmptySubsequences: false)
            guard parts.count == 2, let dist = Double(String(parts[0])), let ang = Double(String(parts[1])) else { return nil }
            let a = ang * Double.pi / 180
            return CGPoint(x: Double(ref.x) + cos(a) * dist, y: Double(ref.y) + sin(a) * dist)
        }
        let parts = s.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, let x = Double(String(parts[0])), let y = Double(String(parts[1])) else { return nil }
        if relative { return CGPoint(x: Double(ref.x) + x, y: Double(ref.y) + y) }
        return CGPoint(x: x, y: y)
    }

    /// Enter on the command line (also Space, and right-click), with whatever was typed.
    func enter(_ raw: String) {
        guard let doc = doc else { return }
        let t = raw.trimmingCharacters(in: .whitespaces).lowercased()

        // Free text answers
        if cmd == .text && step == 2 {
            let content = raw.trimmingCharacters(in: .whitespaces)
            if !content.isEmpty, let p = pts.first, let controller = controller {
                var o = DrawObject(kind: .text, layer: controller.activeLayerID)
                o.pos = Pt(p)
                o.text = content
                o.textSize = textHeight
                doc.edit("Text") { $0.objects.append(o) }
            }
            endCommand()
            return
        }
        if cmd == .layer {
            let name = raw.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { controller?.makeLayerCurrent(named: name) }
            endCommand()
            return
        }
        if cmd == .scene {
            if let scene = (doc.drawing.scenes ?? []).first(where: { $0.name.lowercased() == t }) {
                selection = []
                doc.edit("Show Scene") { $0.applyScene(scene.id) }
                zoomFit()
            } else if !t.isEmpty {
                log("No scene called \"\(raw)\".")
            }
            endCommand()
            return
        }

        // Plain Enter
        if t.isEmpty {
            if windowStart != nil {
                windowStart = nil
                refreshPrompt()
                return
            }
            if selecting {
                if selection.isEmpty {
                    endCommand()
                } else if cmd == .erase {
                    eraseSelection()
                    endCommand()
                } else {
                    selecting = false
                    refreshPrompt()
                }
                return
            }
            switch cmd {
            case .none:
                if lastCmd != .none { start(lastCmd) }
            case .pline:
                finishPolyline(closed: false)
            case .text:
                if step == 1 {
                    step = 2
                    refreshPrompt()
                } else {
                    endCommand()
                }
            case .zoom:
                zoomFit()
                endCommand()
            default:
                endCommand()
            }
            return
        }

        // A new command
        if cmd == .none {
            if !run(t) && controller?.appCommand(t) != true {
                log("Unknown command \"\(raw.trimmingCharacters(in: .whitespaces))\". Type HELP for the list.")
            }
            return
        }

        // One-pick object snap override
        if wantsPoint, let kind = SnapKind.allCases.first(where: { $0.abbreviation == t || $0.rawValue == t }) {
            snapOverride = kind
            log("\(kind.label) of")
            return
        }

        // Options of the running command
        switch cmd {
        case .line:
            if t == "c" || t == "close" {
                if pts.count >= 3, let last = pts.last, let first = pts.first { addLine(last, first) }
                endCommand()
                return
            }
            if t == "u" || t == "undo" {
                if let id = made.popLast() {
                    doc.edit("Undo Segment") { d in d.objects.removeAll { $0.id == id } }
                    if pts.count > 1 { pts.removeLast() }
                }
                refreshPrompt()
                return
            }
        case .pline:
            if t == "c" || t == "close" {
                finishPolyline(closed: true)
                return
            }
            if t == "u" || t == "undo" {
                if pts.count > 1 { pts.removeLast() }
                refreshPrompt()
                return
            }
        case .zoom:
            if t == "w" || t == "window" {
                cmd = .zoomWindow
                pts = []
                refreshPrompt()
            } else {
                zoomFit()
                endCommand()
            }
            return
        default:
            break
        }

        // Coordinates
        if wantsPoint, let p = parsePoint(t) {
            point(p)
            return
        }

        // A bare number: radius, angle, height, or a distance in the cursor's direction
        if let v = parseNum(t) {
            if cmd == .text && step == 1 {
                if v > 0 { textHeight = v }
                step = 2
                refreshPrompt()
                return
            }
            if cmd == .circle, let c = pts.first {
                addCircle(c, radius: abs(v))
                endCommand()
                return
            }
            if cmd == .rotate, let base = pts.first {
                rotateSelection(about: base, degrees: v)
                endCommand()
                return
            }
            if wantsPoint, let ref = pts.last {
                let dx = Double(cursor.x - ref.x)
                let dy = Double(cursor.y - ref.y)
                let len = (dx * dx + dy * dy).squareRoot()
                if len > 0 {
                    point(CGPoint(x: Double(ref.x) + dx / len * v, y: Double(ref.y) + dy / len * v))
                    return
                }
            }
        }
        log("Invalid input.")
    }

    /// A point for the running command, from a click or from typed coordinates.
    private func point(_ p: CGPoint) {
        guard let doc = doc, let controller = controller else { return }
        snapOverride = nil
        switch cmd {
        case .line:
            if let last = pts.last { addLine(last, p) }
            pts.append(p)
        case .pline:
            pts.append(p)
        case .circle:
            if let c = pts.first {
                addCircle(c, radius: Double(distance(c, p)))
                endCommand()
                return
            }
            pts = [p]
        case .rect:
            if let a = pts.first {
                let r = rectBetween(a, p)
                if r.width > 0 && r.height > 0 {
                    var o = DrawObject(kind: .rect, layer: controller.activeLayerID)
                    o.pos = Pt(r.origin)
                    o.w = Double(r.width)
                    o.h = Double(r.height)
                    doc.edit("Rectangle") { $0.objects.append(o) }
                }
                endCommand()
                return
            }
            pts = [p]
        case .text:
            pts = [p]
            step = 1
        case .move:
            if let base = pts.first {
                let dx = Double(p.x - base.x)
                let dy = Double(p.y - base.y)
                let ids = selection.union(doc.drawing.attachedFixtures(to: selection))
                doc.edit("Move") { d in
                    for i in d.objects.indices where ids.contains(d.objects[i].id) {
                        d.objects[i].translate(dx: dx, dy: dy)
                    }
                }
                endCommand()
                return
            }
            pts = [p]
        case .copy:
            if let base = pts.first {
                let d = doc.drawing
                let ids = selection.union(d.attachedFixtures(to: selection))
                insertCopies(of: d.objects.filter { ids.contains($0.id) }, dx: Double(p.x - base.x), dy: Double(p.y - base.y),
                             name: "Copy", select: false)
            } else {
                pts = [p]
            }
        case .rotate:
            if let base = pts.first {
                let a = Double(atan2(p.y - base.y, p.x - base.x)) * 180 / Double.pi
                rotateSelection(about: base, degrees: a)
                endCommand()
                return
            }
            pts = [p]
        case .truss:
            if let a = pts.first {
                let run = trussRun(from: a, to: p)
                let rad = run.angle * Double.pi / 180
                var sections: [DrawObject] = []
                for i in 0..<run.count {
                    var o = DrawObject(kind: .truss, layer: controller.activeLayerID)
                    o.typeID = controller.currentTrussType
                    o.rot = run.angle
                    o.pos = Pt(Double(a.x) + cos(rad) * run.length * Double(i), Double(a.y) + sin(rad) * run.length * Double(i))
                    sections.append(o)
                }
                doc.edit("Truss") { $0.objects.append(contentsOf: sections) }
                pts = []
            } else {
                pts = [p]
            }
        case .fixture:
            placeFixture(at: p)
        case .zoomWindow:
            if let a = pts.first {
                zoomTo(rectBetween(a, p))
                endCommand()
                return
            }
            pts = [p]
        default:
            break
        }
        refreshPrompt()
    }

    // MARK: Making and changing objects

    private func addLine(_ a: CGPoint, _ b: CGPoint) {
        guard let doc = doc, let controller = controller, distance(a, b) > 0.01 else { return }
        var o = DrawObject(kind: .line, layer: controller.activeLayerID)
        o.pts = [Pt(a), Pt(b)]
        doc.edit("Line") { $0.objects.append(o) }
        made.append(o.id)
    }

    private func addCircle(_ c: CGPoint, radius: Double) {
        guard let doc = doc, let controller = controller, radius > 0 else { return }
        var o = DrawObject(kind: .ellipse, layer: controller.activeLayerID)
        o.pos = Pt(Double(c.x) - radius, Double(c.y) - radius)
        o.w = radius * 2
        o.h = radius * 2
        doc.edit("Circle") { $0.objects.append(o) }
    }

    private func finishPolyline(closed: Bool) {
        if let doc = doc, let controller = controller, pts.count >= 2 {
            var o = DrawObject(kind: .polyline, layer: controller.activeLayerID)
            o.pts = pts.map { Pt($0) }
            o.closed = closed
            doc.edit("Polyline") { $0.objects.append(o) }
        }
        endCommand()
    }

    private func trussRun(from a: CGPoint, to b: CGPoint) -> (angle: Double, count: Int, length: Double) {
        let type = Library.trussType(controller?.currentTrussType ?? "")
        let angle = Double(atan2(b.y - a.y, b.x - a.x)) * 180 / Double.pi
        let count = max(1, Int((Double(distance(a, b)) / type.length).rounded()))
        return (angle, count, type.length)
    }

    /// The fixture a click at `p` would place, hung on the nearest truss if one is in reach.
    private func fixtureGhost(at p: CGPoint) -> DrawObject? {
        guard let doc = doc, let controller = controller else { return nil }
        let type = doc.drawing.fixtureType(controller.currentFixtureType)
        var o = DrawObject(kind: .fixture, layer: controller.activeLayerID)
        o.typeID = type.id
        o.w = type.width
        o.h = type.depth
        o.pos = Pt(p)
        Geometry.attach(&o, in: doc.drawing, maxDist: 600)
        return o
    }

    private func placeFixture(at p: CGPoint) {
        guard let doc = doc, var o = fixtureGhost(at: p) else { return }
        let type = doc.drawing.fixtureType(o.typeID)
        let numbered = type.category != "hoist"
        if numbered { o.unit = String(doc.drawing.nextUnit) }
        doc.edit("Place " + type.name) { d in
            d.objects.append(o)
            if numbered { d.nextUnit += 1 }
        }
    }

    private func rotateSelection(about base: CGPoint, degrees: Double) {
        guard let doc = doc else { return }
        let ids = selection.union(doc.drawing.attachedFixtures(to: selection))
        doc.edit("Rotate") { d in
            for i in d.objects.indices where ids.contains(d.objects[i].id) {
                d.objects[i].rotate(about: base, degrees: degrees)
            }
        }
    }

    func eraseSelection() {
        guard let doc = doc, !selection.isEmpty else { return }
        let ids = selection
        doc.edit("Erase") { d in
            d.objects.removeAll { ids.contains($0.id) }
            for i in d.objects.indices {
                if let a = d.objects[i].attachedTo, ids.contains(a) { d.objects[i].attachedTo = nil }
            }
        }
        selection = []
    }

    /// Copies keep their data but get new IDs; fixtures take the next unit numbers.
    private func insertCopies(of objs: [DrawObject], dx: Double, dy: Double, name: String, select: Bool) {
        guard let doc = doc, !objs.isEmpty else { return }
        var idMap: [UUID: UUID] = [:]
        var copies: [DrawObject] = []
        for o in objs {
            var c = o
            c.id = UUID()
            idMap[o.id] = c.id
            c.translate(dx: dx, dy: dy)
            if doc.drawing.layer(c.layer) == nil, let first = doc.drawing.layers.first { c.layer = first.id }
            copies.append(c)
        }
        var next = doc.drawing.nextUnit
        for i in copies.indices {
            if let a = copies[i].attachedTo { copies[i].attachedTo = idMap[a] }
            if copies[i].kind == .fixture && !copies[i].unit.isEmpty {
                copies[i].unit = String(next)
                next += 1
            }
        }
        doc.edit(name) { d in
            d.objects.append(contentsOf: copies)
            d.nextUnit = next
        }
        if select { selection = Set(copies.map { $0.id }) }
    }

    func copyObjects() {
        guard let d = doc?.drawing, !selection.isEmpty else { return }
        let objs = d.objects.filter { selection.contains($0.id) }
        guard let data = try? JSONEncoder().encode(objs) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: CanvasView.pasteType)
    }

    func pasteObjects() {
        guard let doc = doc, let data = NSPasteboard.general.data(forType: CanvasView.pasteType),
              let objs = try? JSONDecoder().decode([DrawObject].self, from: data) else { return }
        let step = max(doc.drawing.gridSize, 100) * 5
        insertCopies(of: objs, dx: step, dy: -step, name: "Paste", select: true)
    }

    func duplicateSelection() {
        guard let doc = doc, !selection.isEmpty else { return }
        let step = max(doc.drawing.gridSize, 100) * 5
        insertCopies(of: doc.drawing.objects.filter { selection.contains($0.id) }, dx: step, dy: -step, name: "Duplicate", select: true)
    }

    func selectAllObjects() {
        guard let d = doc?.drawing else { return }
        selection = Set(d.objects.filter { d.isVisible($0) && !d.isLocked($0) }.map { $0.id })
    }

    func arrange(toFront: Bool) {
        guard let doc = doc, !selection.isEmpty else { return }
        let ids = selection
        doc.edit(toFront ? "Send to Front" : "Send to Back") { d in
            let picked = d.objects.filter { ids.contains($0.id) }
            let rest = d.objects.filter { !ids.contains($0.id) }
            d.objects = toFront ? rest + picked : picked + rest
        }
    }

    func pruneSelection() {
        guard let d = doc?.drawing else { return }
        let ids = Set(d.objects.map { $0.id })
        let kept = selection.intersection(ids)
        if kept != selection { selection = kept }
    }

    // MARK: Selection window

    private func rectBetween(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Left to right is a window (objects wholly inside); right to left is crossing (anything touched).
    private func finishWindow(_ a: CGPoint, _ b: CGPoint) {
        windowStart = nil
        guard let d = doc?.drawing else { return }
        let r = rectBetween(a, b)
        let crossing = b.x < a.x
        var picked = selection
        for o in d.objects where d.isVisible(o) && !d.isLocked(o) {
            let box = o.worldBounds()
            if box.isNull { continue }
            let inside = crossing ? r.intersects(box) : r.contains(box)
            if inside { picked.insert(o.id) }
        }
        selection = picked
        refreshPrompt()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Renderer.screenBackground.ns.setFill()
        bounds.fill()

        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -offset.x, y: -offset.y)
        if Drafting.showGrid { drawGrid(ctx) }
        if let d = doc?.drawing {
            Renderer.screen = true
            Renderer.draw(d, in: ctx, pxPerMM: scale, selection: selection)
            drawPreview(ctx, d)
            Renderer.screen = false
        }
        ctx.restoreGState()

        // Overlays in screen points
        if let a = windowStart {
            let va = toView(a)
            let vb = toView(windowEnd)
            let r = rectBetween(va, vb)
            let crossing = windowEnd.x < a.x
            let color = crossing ? NSColor.systemGreen : NSColor.systemBlue
            ctx.setFillColor(color.withAlphaComponent(0.15).cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1)
            if crossing { ctx.setLineDash(phase: 0, lengths: [5, 4]) }
            ctx.stroke(r)
            ctx.setLineDash(phase: 0, lengths: [])
        }
        if wantsPoint, let hit = snapHit {
            Snapper.drawMarker(hit.kind, at: toView(hit.point), in: ctx)
        }
        if let m = mouseView {
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: m.x - 45, y: m.y)); ctx.addLine(to: CGPoint(x: m.x + 45, y: m.y))
            ctx.move(to: CGPoint(x: m.x, y: m.y - 45)); ctx.addLine(to: CGPoint(x: m.x, y: m.y + 45))
            ctx.strokePath()
            if !wantsPoint { ctx.stroke(CGRect(x: m.x - 4, y: m.y - 4, width: 8, height: 8)) }
        }
    }

    private func drawGrid(_ ctx: CGContext) {
        let visible = CGRect(x: offset.x, y: offset.y, width: bounds.width / scale, height: bounds.height / scale)
        let minor = CGFloat(doc?.drawing.gridSize ?? 100)
        let major: CGFloat = 1000
        func lines(_ step: CGFloat, _ alpha: CGFloat) {
            if step <= 0 || step * scale < 7 { return }
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)
            ctx.setLineWidth(1 / scale)
            ctx.beginPath()
            var x = (visible.minX / step).rounded(.down) * step
            while x <= visible.maxX {
                ctx.move(to: CGPoint(x: x, y: visible.minY))
                ctx.addLine(to: CGPoint(x: x, y: visible.maxY))
                x += step
            }
            var y = (visible.minY / step).rounded(.down) * step
            while y <= visible.maxY {
                ctx.move(to: CGPoint(x: visible.minX, y: y))
                ctx.addLine(to: CGPoint(x: visible.maxX, y: y))
                y += step
            }
            ctx.strokePath()
        }
        lines(minor, 0.05)
        lines(major, 0.11)

        // Origin: X red, Y green, like the UCS icon
        ctx.setLineWidth(1.5 / scale)
        ctx.setStrokeColor(NSColor.systemRed.cgColor)
        ctx.beginPath()
        ctx.move(to: CGPoint.zero); ctx.addLine(to: CGPoint(x: 600, y: 0))
        ctx.strokePath()
        ctx.setStrokeColor(NSColor.systemGreen.cgColor)
        ctx.beginPath()
        ctx.move(to: CGPoint.zero); ctx.addLine(to: CGPoint(x: 0, y: 600))
        ctx.strokePath()
    }

    /// Rubber-band preview of what the running command will draw.
    private func drawPreview(_ ctx: CGContext, _ d: Drawing) {
        if !wantsPoint { return }
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1 / scale)
        switch cmd {
        case .line, .pline, .move, .copy, .rotate:
            if cmd == .pline && pts.count >= 2 {
                ctx.beginPath()
                ctx.move(to: pts[0])
                for p in pts.dropFirst() { ctx.addLine(to: p) }
                ctx.strokePath()
            }
            if let last = pts.last {
                ctx.setLineDash(phase: 0, lengths: [6 / scale, 4 / scale])
                ctx.beginPath()
                ctx.move(to: last)
                ctx.addLine(to: cursor)
                ctx.strokePath()
            }
        case .circle:
            if let c = pts.first {
                let r = distance(c, cursor)
                ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            }
        case .rect, .zoomWindow:
            if let a = pts.first { ctx.stroke(rectBetween(a, cursor)) }
        case .truss:
            if let a = pts.first {
                let run = trussRun(from: a, to: cursor)
                let type = Library.trussType(controller?.currentTrussType ?? "")
                ctx.saveGState()
                ctx.translateBy(x: a.x, y: a.y)
                ctx.rotate(by: degToRad(run.angle))
                for i in 0..<run.count {
                    ctx.stroke(CGRect(x: Double(i) * type.length, y: -type.width / 2, width: type.length, height: type.width))
                }
                ctx.restoreGState()
            }
        case .fixture:
            if let ghost = fixtureGhost(at: cursor) {
                ctx.saveGState()
                ctx.concatenate(ghost.transform)
                ctx.setStrokeColor(NSColor.systemYellow.cgColor)
                Renderer.drawPrims(d.fixtureType(ghost.typeID).prims, ctx, 1 / scale)
                ctx.restoreGState()
            }
        default:
            break
        }
        ctx.setLineDash(phase: 0, lengths: [])
    }

    // MARK: Mouse

    private func track(_ e: NSEvent) -> (view: CGPoint, world: CGPoint) {
        let vp = eventPoint(e)
        let raw = toWorld(vp)
        mouseView = vp
        cursor = wantsPoint ? resolve(raw) : raw
        controller?.setCoords(cursor)
        return (vp, raw)
    }

    override func mouseDown(with e: NSEvent) {
        controller?.focusCommandLine()
        let m = track(e)
        guard let doc = doc else { return }
        pressView = m.view
        pressWorld = m.world
        pressedObject = false
        pressedEmpty = false
        draggingWindow = false

        if wantsPoint {
            point(cursor)
            return
        }
        if let a = windowStart {
            finishWindow(a, m.world)
            return
        }

        // Picking: a click adds to the selection, Shift removes, Command toggles.
        let d = doc.drawing
        let flags = e.modifierFlags
        if let hitID = d.topObject(at: m.world, tol: 6 / scale) {
            if flags.contains(.shift) {
                selection.remove(hitID)
            } else if flags.contains(.command) {
                if selection.contains(hitID) { selection.remove(hitID) } else { selection.insert(hitID) }
            } else {
                selection.insert(hitID)
                if cmd == .none {
                    pressedObject = true
                    snapshot = d
                    moveIDs = selection.union(d.attachedFixtures(to: selection))
                    didMove = false
                }
            }
            refreshPrompt()
        } else {
            pressedEmpty = true
        }
    }

    override func mouseDragged(with e: NSEvent) {
        let m = track(e)
        if panning {
            offset.x -= (m.view.x - panLast.x) / scale
            offset.y -= (m.view.y - panLast.y) / scale
            panLast = m.view
            needsDisplay = true
            return
        }
        guard let doc = doc else { return }
        if pressedObject, let snap = snapshot {
            if !didMove && distance(m.view, pressView) < 4 { return }
            var dx = Double(m.world.x - pressWorld.x)
            var dy = Double(m.world.y - pressWorld.y)
            if snap.snapGrid && snap.gridSize > 0 {
                dx = (dx / snap.gridSize).rounded() * snap.gridSize
                dy = (dy / snap.gridSize).rounded() * snap.gridSize
            }
            didMove = true
            var d = snap
            for i in d.objects.indices where moveIDs.contains(d.objects[i].id) {
                d.objects[i].translate(dx: dx, dy: dy)
            }
            // A fixture dragged on its own hangs itself on the nearest truss.
            for i in d.objects.indices {
                let o = d.objects[i]
                if o.kind != .fixture || !selection.contains(o.id) { continue }
                if let a = o.attachedTo, moveIDs.contains(a) { continue }
                var moved = o
                Geometry.attach(&moved, in: d, maxDist: 600)
                d.objects[i] = moved
            }
            doc.setLive(d)
        } else if pressedEmpty {
            if draggingWindow || distance(m.view, pressView) >= 4 {
                draggingWindow = true
                windowStart = pressWorld
                windowEnd = m.world
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        let m = track(e)
        if pressedObject {
            if didMove, let snap = snapshot { doc?.commitLive(from: snap, name: "Move") }
            snapshot = nil
        } else if pressedEmpty {
            if draggingWindow {
                finishWindow(pressWorld, m.world)
            } else {
                // A click on empty space starts a selection window; the next click finishes it.
                windowStart = pressWorld
                windowEnd = pressWorld
                refreshPrompt()
            }
        }
        pressedObject = false
        pressedEmpty = false
        draggingWindow = false
        needsDisplay = true
    }

    override func mouseMoved(with e: NSEvent) {
        let m = track(e)
        if windowStart != nil { windowEnd = m.world }
        needsDisplay = true
    }

    override func mouseExited(with e: NSEvent) {
        mouseView = nil
        needsDisplay = true
    }

    /// Right-click is Enter, the common AutoCAD setting.
    override func rightMouseDown(with e: NSEvent) {
        controller?.focusCommandLine()
        enter("")
    }

    override func otherMouseDown(with e: NSEvent) {
        panning = true
        panLast = eventPoint(e)
    }

    override func otherMouseDragged(with e: NSEvent) {
        mouseDragged(with: e)
    }

    override func otherMouseUp(with e: NSEvent) {
        panning = false
    }

    override func scrollWheel(with e: NSEvent) {
        let zooming = !e.hasPreciseScrollingDeltas || e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option)
        if zooming {
            let amount = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY * 0.01 : e.scrollingDeltaY * 0.1
            zoom(by: max(0.5, min(2, 1 + amount)), at: eventPoint(e))
        } else {
            offset.x -= e.scrollingDeltaX / scale
            offset.y += e.scrollingDeltaY / scale
            needsDisplay = true
        }
    }

    override func magnify(with e: NSEvent) {
        zoom(by: 1 + e.magnification, at: eventPoint(e))
    }

    /// Keys pressed while the canvas has focus go to the command line.
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 {
            escape()
            return
        }
        if !e.modifierFlags.intersection([.command, .control]).isEmpty {
            super.keyDown(with: e)
            return
        }
        controller?.focusCommandLine(typing: e.characters ?? "")
    }
}
