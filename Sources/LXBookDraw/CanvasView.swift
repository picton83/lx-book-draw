import AppKit

enum Tool: Int, CaseIterable {
    case select, pan, line, rect, ellipse, polyline, text, truss, fixture

    var title: String {
        switch self {
        case .select: return "Select  (X)"
        case .pan: return "Pan  (H)"
        case .line: return "Line  (2)"
        case .rect: return "Rectangle  (4)"
        case .ellipse: return "Ellipse  (6)"
        case .polyline: return "Polyline  (5)"
        case .text: return "Text  (1)"
        case .truss: return "Truss  (T)"
        case .fixture: return "Fixture / Hoist  (F)"
        }
    }
}

final class CanvasView: NSView {
    weak var controller: MainWindowController?
    var doc: DrawDocument? { controller?.doc }

    // View: screen point = (drawing mm - offset) * scale
    var scale: CGFloat = 0.05
    var offset = CGPoint(x: -2000, y: -2000)

    var tool: Tool = .select {
        didSet {
            cancelInProgress()
            controller?.toolChanged()
            needsDisplay = true
        }
    }

    var selection = Set<UUID>() {
        didSet {
            if selection != oldValue {
                controller?.selectionChanged()
                needsDisplay = true
            }
        }
    }

    private enum Mode { case idle, move, marquee, create, pan }
    private var mode = Mode.idle
    private var dragStart = CGPoint.zero
    private var dragCurrent = CGPoint.zero
    private var snapshot: Drawing? = nil
    private var moveIDs = Set<UUID>()
    private var didMove = false
    private var panLast = CGPoint.zero
    private var spaceDown = false
    private var shiftDrag = false
    private var addDrag = false   // Shift or Command held: add to / remove from the selection
    private var polyPts: [Pt] = []
    private var polyHover: CGPoint? = nil
    private var tracking: NSTrackingArea? = nil

    static let pasteType = NSPasteboard.PasteboardType("com.picton.lxbookdraw.objects")

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    // MARK: Coordinates

    func toWorld(_ vp: CGPoint) -> CGPoint {
        CGPoint(x: vp.x / scale + offset.x, y: vp.y / scale + offset.y)
    }

    private func eventPoint(_ e: NSEvent) -> CGPoint {
        convert(e.locationInWindow, from: nil)
    }

    private func snapGrid(_ p: CGPoint) -> CGPoint {
        guard let d = doc?.drawing, d.snapGrid, d.gridSize > 0 else { return p }
        let g = CGFloat(d.gridSize)
        return CGPoint(x: (p.x / g).rounded() * g, y: (p.y / g).rounded() * g)
    }

    /// Truss ends snap to the ends of truss already drawn, so runs join up.
    private func snapTrussEnd(_ p: CGPoint) -> CGPoint {
        guard let d = doc?.drawing else { return p }
        let reach = 14 / scale
        var best = p
        var bestDist = reach
        for t in d.objects where t.kind == .truss && d.isVisible(t) {
            let len = CGFloat(Library.trussType(t.typeID).length)
            let ends = [t.pos.cg, CGPoint(x: len, y: 0).applying(t.transform)]
            for e in ends {
                let dist = distance(p, e)
                if dist < bestDist {
                    bestDist = dist
                    best = e
                }
            }
        }
        if bestDist < reach { return best }
        return snapGrid(p)
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

    func zoomFit() {
        var r = doc?.drawing.extents() ?? CGRect.null
        if r.isNull || r.width < 1 || r.height < 1 {
            r = CGRect(x: -2000, y: -2000, width: 24000, height: 14000)
        }
        if bounds.width < 10 || bounds.height < 10 { return }
        let s = min(bounds.width / r.width, bounds.height / r.height) * 0.9
        scale = max(0.002, min(5, s))
        offset = CGPoint(x: r.midX - bounds.width / (2 * scale), y: r.midY - bounds.height / (2 * scale))
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.white.setFill()
        bounds.fill()
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -offset.x, y: -offset.y)
        drawGrid(ctx)
        if let d = doc?.drawing {
            Renderer.draw(d, in: ctx, pxPerMM: scale, selection: selection)
        }
        drawInProgress(ctx)
        ctx.restoreGState()
    }

    private func drawGrid(_ ctx: CGContext) {
        let visible = CGRect(x: offset.x, y: offset.y, width: bounds.width / scale, height: bounds.height / scale)
        let minor = CGFloat(doc?.drawing.gridSize ?? 100)
        let major: CGFloat = 1000
        func lines(_ step: CGFloat, _ color: NSColor) {
            if step <= 0 || step * scale < 7 { return }
            ctx.setStrokeColor(color.cgColor)
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
        lines(minor, NSColor(white: 0.93, alpha: 1))
        lines(major, NSColor(white: 0.82, alpha: 1))

        // Origin marker
        ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.5).cgColor)
        ctx.setLineWidth(1 / scale)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: -300, y: 0)); ctx.addLine(to: CGPoint(x: 300, y: 0))
        ctx.move(to: CGPoint(x: 0, y: -300)); ctx.addLine(to: CGPoint(x: 0, y: 300))
        ctx.strokePath()
    }

    private func trussRun(from a: CGPoint, to b: CGPoint) -> (angle: Double, count: Int, length: Double) {
        let type = Library.trussType(controller?.currentTrussType ?? "")
        var angle = Double(atan2(b.y - a.y, b.x - a.x)) * 180 / Double.pi
        let step = shiftDrag ? 45.0 : 5.0
        angle = (angle / step).rounded() * step
        let count = max(1, Int((Double(distance(a, b)) / type.length).rounded()))
        return (angle, count, type.length)
    }

    private func drawInProgress(_ ctx: CGContext) {
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(1.5 / scale)
        ctx.setLineDash(phase: 0, lengths: [6 / scale, 4 / scale])
        switch mode {
        case .marquee:
            ctx.stroke(rectBetween(dragStart, dragCurrent))
        case .create:
            switch tool {
            case .line:
                ctx.beginPath()
                ctx.move(to: dragStart)
                ctx.addLine(to: dragCurrent)
                ctx.strokePath()
            case .rect:
                ctx.stroke(rectBetween(dragStart, dragCurrent))
            case .ellipse:
                ctx.strokeEllipse(in: rectBetween(dragStart, dragCurrent))
            case .truss:
                let run = trussRun(from: dragStart, to: dragCurrent)
                let type = Library.trussType(controller?.currentTrussType ?? "")
                ctx.saveGState()
                ctx.translateBy(x: dragStart.x, y: dragStart.y)
                ctx.rotate(by: degToRad(run.angle))
                for i in 0..<run.count {
                    ctx.stroke(CGRect(x: Double(i) * type.length, y: -type.width / 2, width: type.length, height: type.width))
                }
                ctx.restoreGState()
            default:
                break
            }
        default:
            break
        }
        if tool == .polyline && !polyPts.isEmpty {
            ctx.beginPath()
            ctx.move(to: polyPts[0].cg)
            for p in polyPts.dropFirst() { ctx.addLine(to: p.cg) }
            if let h = polyHover { ctx.addLine(to: h) }
            ctx.strokePath()
        }
        ctx.setLineDash(phase: 0, lengths: [])
    }

    private func rectBetween(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        guard let doc = doc, let controller = controller else { return }
        let vp = eventPoint(e)
        let wp = toWorld(vp)
        shiftDrag = e.modifierFlags.contains(.shift)
        addDrag = shiftDrag || e.modifierFlags.contains(.command)

        if spaceDown || tool == .pan {
            mode = .pan
            panLast = vp
            return
        }

        switch tool {
        case .select:
            let d = doc.drawing
            if let hitID = d.topObject(at: wp, tol: 6 / scale) {
                if addDrag {
                    if selection.contains(hitID) { selection.remove(hitID) } else { selection.insert(hitID) }
                } else if !selection.contains(hitID) {
                    selection = [hitID]
                }
                if selection.contains(hitID) {
                    mode = .move
                    dragStart = wp
                    snapshot = d
                    moveIDs = selection.union(d.attachedFixtures(to: selection))
                    didMove = false
                }
            } else {
                if !addDrag { selection = [] }
                mode = .marquee
                dragStart = wp
                dragCurrent = wp
            }
        case .line, .rect, .ellipse:
            mode = .create
            dragStart = snapGrid(wp)
            dragCurrent = dragStart
        case .truss:
            mode = .create
            dragStart = snapTrussEnd(wp)
            dragCurrent = dragStart
        case .polyline:
            if e.clickCount >= 2 {
                finishPolyline()
            } else {
                polyPts.append(Pt(snapGrid(wp)))
                needsDisplay = true
            }
        case .text:
            var o = DrawObject(kind: .text, layer: controller.activeLayerID)
            o.pos = Pt(snapGrid(wp))
            o.text = "Text"
            doc.edit("Add Text") { $0.objects.append(o) }
            selection = [o.id]
            tool = .select
        case .fixture:
            placeFixture(at: wp)
        case .pan:
            break
        }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let doc = doc else { return }
        let vp = eventPoint(e)
        let wp = toWorld(vp)
        shiftDrag = e.modifierFlags.contains(.shift)

        switch mode {
        case .pan:
            offset.x -= (vp.x - panLast.x) / scale
            offset.y -= (vp.y - panLast.y) / scale
            panLast = vp
            needsDisplay = true
        case .move:
            guard let snap = snapshot else { return }
            var dx = Double(wp.x - dragStart.x)
            var dy = Double(wp.y - dragStart.y)
            if snap.snapGrid && snap.gridSize > 0 {
                dx = (dx / snap.gridSize).rounded() * snap.gridSize
                dy = (dy / snap.gridSize).rounded() * snap.gridSize
            }
            if dx == 0 && dy == 0 && !didMove { return }
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
        case .marquee, .create:
            if tool == .truss || tool == .select {
                dragCurrent = wp
            } else {
                dragCurrent = snapGrid(wp)
            }
            needsDisplay = true
        case .idle:
            break
        }
    }

    override func mouseUp(with e: NSEvent) {
        guard let doc = doc, let controller = controller else {
            mode = .idle
            return
        }
        let finished = mode
        mode = .idle
        switch finished {
        case .move:
            if didMove, let snap = snapshot { doc.commitLive(from: snap, name: "Move") }
            snapshot = nil
        case .marquee:
            let r = rectBetween(dragStart, dragCurrent)
            if r.width > 0 || r.height > 0 {
                var picked = addDrag ? selection : Set<UUID>()
                let d = doc.drawing
                for o in d.objects where d.isVisible(o) && !d.isLocked(o) {
                    if r.intersects(o.worldBounds()) { picked.insert(o.id) }
                }
                selection = picked
            }
        case .create:
            let layer = controller.activeLayerID
            var made: [DrawObject] = []
            switch tool {
            case .line:
                if distance(dragStart, dragCurrent) > 1 {
                    var o = DrawObject(kind: .line, layer: layer)
                    o.pts = [Pt(dragStart), Pt(dragCurrent)]
                    made = [o]
                }
            case .rect, .ellipse:
                let r = rectBetween(dragStart, dragCurrent)
                if r.width > 1 && r.height > 1 {
                    var o = DrawObject(kind: tool == .rect ? .rect : .ellipse, layer: layer)
                    o.pos = Pt(r.origin)
                    o.w = Double(r.width)
                    o.h = Double(r.height)
                    made = [o]
                }
            case .truss:
                let run = trussRun(from: dragStart, to: dragCurrent)
                let a = run.angle * Double.pi / 180
                for i in 0..<run.count {
                    var o = DrawObject(kind: .truss, layer: layer)
                    o.typeID = controller.currentTrussType
                    o.rot = run.angle
                    o.pos = Pt(Double(dragStart.x) + cos(a) * run.length * Double(i),
                               Double(dragStart.y) + sin(a) * run.length * Double(i))
                    made.append(o)
                }
            default:
                break
            }
            if !made.isEmpty {
                doc.edit("Draw") { $0.objects.append(contentsOf: made) }
                selection = Set(made.map { $0.id })
            }
        case .pan, .idle:
            break
        }
        needsDisplay = true
    }

    override func mouseMoved(with e: NSEvent) {
        if tool == .polyline && !polyPts.isEmpty {
            polyHover = snapGrid(toWorld(eventPoint(e)))
            needsDisplay = true
        }
    }

    override func otherMouseDown(with e: NSEvent) {
        mode = .pan
        panLast = eventPoint(e)
    }

    override func otherMouseDragged(with e: NSEvent) {
        mouseDragged(with: e)
    }

    override func otherMouseUp(with e: NSEvent) {
        mode = .idle
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

    // MARK: Creating

    private func placeFixture(at wp: CGPoint) {
        guard let doc = doc, let controller = controller else { return }
        let type = doc.drawing.fixtureType(controller.currentFixtureType)
        var o = DrawObject(kind: .fixture, layer: controller.activeLayerID)
        o.typeID = type.id
        o.w = type.width
        o.h = type.depth
        o.pos = Pt(snapGrid(wp))
        Geometry.attach(&o, in: doc.drawing, maxDist: 600)
        let numbered = type.category != "hoist"
        if numbered { o.unit = String(doc.drawing.nextUnit) }
        doc.edit("Place " + type.name) { d in
            d.objects.append(o)
            if numbered { d.nextUnit += 1 }
        }
        selection = [o.id]
    }

    private func finishPolyline() {
        guard let doc = doc, let controller = controller else { return }
        if polyPts.count >= 2 {
            var o = DrawObject(kind: .polyline, layer: controller.activeLayerID)
            o.pts = polyPts
            doc.edit("Draw Polyline") { $0.objects.append(o) }
            selection = [o.id]
        }
        polyPts = []
        polyHover = nil
        needsDisplay = true
    }

    func cancelInProgress() {
        polyPts = []
        polyHover = nil
        if mode == .move, let snap = snapshot { doc?.setLive(snap) }
        snapshot = nil
        mode = .idle
    }

    func pruneSelection() {
        guard let d = doc?.drawing else { return }
        let ids = Set(d.objects.map { $0.id })
        let kept = selection.intersection(ids)
        if kept != selection { selection = kept }
    }

    // MARK: Keyboard

    override func keyDown(with e: NSEvent) {
        if !e.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            super.keyDown(with: e)
            return
        }
        switch e.keyCode {
        case 49:
            spaceDown = true
        case 51, 117:
            deleteSelection(nil)
        case 53:
            cancelInProgress()
            if tool != .select { tool = .select } else { selection = [] }
            needsDisplay = true
        case 36, 76:
            if tool == .polyline { finishPolyline() }
        case 123:
            nudge(-1, 0)
        case 124:
            nudge(1, 0)
        case 125:
            nudge(0, -1)
        case 126:
            nudge(0, 1)
        default:
            switch (e.charactersIgnoringModifiers ?? "").lowercased() {
            case "x": tool = .select
            case "h": tool = .pan
            case "2": tool = .line
            case "4": tool = .rect
            case "6": tool = .ellipse
            case "5": tool = .polyline
            case "1": tool = .text
            case "t": tool = .truss
            case "f": tool = .fixture
            default: super.keyDown(with: e)
            }
        }
    }

    override func keyUp(with e: NSEvent) {
        if e.keyCode == 49 { spaceDown = false }
    }

    private func nudge(_ x: Double, _ y: Double) {
        guard let doc = doc, !selection.isEmpty else { return }
        let step = doc.drawing.gridSize > 0 ? doc.drawing.gridSize : 100
        let ids = selection.union(doc.drawing.attachedFixtures(to: selection))
        doc.edit("Nudge") { d in
            for i in d.objects.indices where ids.contains(d.objects[i].id) {
                d.objects[i].translate(dx: x * step, dy: y * step)
            }
        }
    }

    // MARK: Edit menu

    @objc func deleteSelection(_ sender: Any?) {
        guard let doc = doc, !selection.isEmpty else { return }
        let ids = selection
        doc.edit("Delete") { d in
            d.objects.removeAll { ids.contains($0.id) }
            for i in d.objects.indices {
                if let a = d.objects[i].attachedTo, ids.contains(a) { d.objects[i].attachedTo = nil }
            }
        }
        selection = []
    }

    override func selectAll(_ sender: Any?) {
        guard let d = doc?.drawing else { return }
        selection = Set(d.objects.filter { d.isVisible($0) && !d.isLocked($0) }.map { $0.id })
    }

    @objc func copy(_ sender: Any?) {
        guard let d = doc?.drawing, !selection.isEmpty else { return }
        let objs = d.objects.filter { selection.contains($0.id) }
        guard let data = try? JSONEncoder().encode(objs) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: CanvasView.pasteType)
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        deleteSelection(sender)
    }

    @objc func paste(_ sender: Any?) {
        guard let data = NSPasteboard.general.data(forType: CanvasView.pasteType),
              let objs = try? JSONDecoder().decode([DrawObject].self, from: data) else { return }
        insertCopies(of: objs, name: "Paste")
    }

    @objc func duplicateSelection(_ sender: Any?) {
        guard let d = doc?.drawing, !selection.isEmpty else { return }
        insertCopies(of: d.objects.filter { selection.contains($0.id) }, name: "Duplicate")
    }

    /// Copies keep their data but get new IDs, sit one grid step away, and take the next unit numbers.
    private func insertCopies(of objs: [DrawObject], name: String) {
        guard let doc = doc, !objs.isEmpty else { return }
        let step = max(doc.drawing.gridSize, 100) * 5
        var idMap: [UUID: UUID] = [:]
        var copies: [DrawObject] = []
        for o in objs {
            var c = o
            c.id = UUID()
            idMap[o.id] = c.id
            c.translate(dx: step, dy: -step)
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
        selection = Set(copies.map { $0.id })
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
}
