import AppKit

// DXF in and out.
//
// Export writes the oldest, plainest DXF (R12, "AC1009"), which AutoCAD, Vectorworks and everything
// else opens: layers, lines, polylines, circles, text, and one block per truss type and fixture type.
// Each fixture is a block insert carrying its data as attributes (UNIT, PATCH, CIRCUIT, POSITION, NOTE).
//
// Import reads lines, polylines, circles, arcs, ellipses, splines (as straight runs), text, and block
// inserts (opened out and grouped), on their own layers, in millimetres whatever the file's units.

enum DXF {

    // MARK: - Export

    private struct Writer {
        var lines: [String] = []
        mutating func g(_ code: Int, _ value: String) {
            lines.append(String(code))
            lines.append(value)
        }
        mutating func n(_ code: Int, _ value: CGFloat) {
            g(code, String(format: "%.4f", Double(value)))
        }
        mutating func point(_ p: CGPoint, _ base: Int = 10) {
            n(base, p.x)
            n(base + 10, p.y)
            n(base + 20, 0)
        }
    }

    /// R12 names: capitals, digits, _ - $ only, 31 characters at most.
    static func safeName(_ s: String) -> String {
        var out = ""
        for ch in s.uppercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_" || ch == "-" || ch == "$") {
                out.append(ch)
            } else {
                out.append("_")
            }
        }
        if out.isEmpty { out = "X" }
        return String(out.prefix(31))
    }

    /// AutoCAD colour index nearest to one of the app's colours.
    private static func aci(_ c: RGBA) -> Int {
        let table: [(RGBA, Int)] = [(.black, 7), (.red, 1), (.yellow, 2), (.green, 3), (.blue, 5),
                                    (.orange, 30), (.grey, 8), (.pink, 211), (.white, 7), (.purple, 6)]
        var best = 7
        var bestDist = Double.greatestFiniteMagnitude
        for (k, i) in table {
            let d = (k.r - c.r) * (k.r - c.r) + (k.g - c.g) * (k.g - c.g) + (k.b - c.b) * (k.b - c.b)
            if d < bestDist {
                bestDist = d
                best = i
            }
        }
        return best
    }

    private static func polyline(_ w: inout Writer, _ pts: [CGPoint], closed: Bool, layer: String, color: Int?) {
        if pts.count < 2 { return }
        w.g(0, "POLYLINE"); w.g(8, layer)
        if let c = color { w.g(62, String(c)) }
        w.g(66, "1"); w.g(70, closed ? "1" : "0")
        for p in pts {
            w.g(0, "VERTEX"); w.g(8, layer)
            w.point(p)
        }
        w.g(0, "SEQEND"); w.g(8, layer)
    }

    private static func line(_ w: inout Writer, _ a: CGPoint, _ b: CGPoint, layer: String, color: Int?) {
        w.g(0, "LINE"); w.g(8, layer)
        if let c = color { w.g(62, String(c)) }
        w.point(a, 10)
        w.point(b, 11)
    }

    private static func text(_ w: inout Writer, _ s: String, at p: CGPoint, height: CGFloat, rot: Double, layer: String,
                             color: Int?, entity: String = "TEXT", tag: String? = nil, hidden: Bool = false, centred: Bool = false) {
        if s.isEmpty { return }
        w.g(0, entity); w.g(8, layer)
        if let c = color { w.g(62, String(c)) }
        w.point(p)
        w.n(40, height)
        w.g(1, s.replacingOccurrences(of: "\n", with: " "))
        if let t = tag { w.g(2, t) }
        if entity == "ATTRIB" { w.g(70, hidden ? "1" : "0") }
        w.n(50, CGFloat(rot))
        if centred {
            w.g(72, "1")
            w.point(p, 11)
        }
    }

    /// The same truss picture the screen shows: outline, chords and bracing, as line pairs.
    private static func trussLines(_ t: TrussType) -> [(CGPoint, CGPoint)] {
        let L = CGFloat(t.length), W = CGFloat(t.width)
        let inset = min(50, W * 0.12)
        var out: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 0, y: -W / 2), CGPoint(x: L, y: -W / 2)), (CGPoint(x: L, y: -W / 2), CGPoint(x: L, y: W / 2)),
            (CGPoint(x: L, y: W / 2), CGPoint(x: 0, y: W / 2)), (CGPoint(x: 0, y: W / 2), CGPoint(x: 0, y: -W / 2)),
            (CGPoint(x: 0, y: W / 2 - inset), CGPoint(x: L, y: W / 2 - inset)),
            (CGPoint(x: 0, y: -W / 2 + inset), CGPoint(x: L, y: -W / 2 + inset))
        ]
        let bays = max(2, Int((L / W).rounded()))
        let step = L / CGFloat(bays)
        for i in 0..<bays {
            let x0 = CGFloat(i) * step
            let x1 = x0 + step
            if i > 0 { out.append((CGPoint(x: x0, y: -W / 2), CGPoint(x: x0, y: W / 2))) }
            if i % 2 == 0 {
                out.append((CGPoint(x: x0, y: -W / 2 + inset), CGPoint(x: x1, y: W / 2 - inset)))
            } else {
                out.append((CGPoint(x: x0, y: W / 2 - inset), CGPoint(x: x1, y: -W / 2 + inset)))
            }
        }
        return out
    }

    private static func circlePoints(_ c: CGPoint, _ r: CGFloat) -> [CGPoint] {
        (0..<48).map { i in
            let a = CGFloat(i) / 48 * 2 * CGFloat.pi
            return CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
        }
    }

    static func export(_ d: Drawing) -> String {
        var w = Writer()
        LabelLayout.prepare(d)

        var layerName: [UUID: String] = [:]
        var usedNames = Set<String>()
        for l in d.layers {
            var name = safeName(l.name)
            var k = 2
            while usedNames.contains(name) {
                name = String(safeName(l.name).prefix(28)) + "_\(k)"
                k += 1
            }
            usedNames.insert(name)
            layerName[l.id] = name
        }
        func lay(_ o: DrawObject) -> String { layerName[o.layer] ?? "0" }

        w.g(0, "SECTION"); w.g(2, "HEADER")
        w.g(9, "$ACADVER"); w.g(1, "AC1009")
        w.g(0, "ENDSEC")

        w.g(0, "SECTION"); w.g(2, "TABLES")
        w.g(0, "TABLE"); w.g(2, "LTYPE"); w.g(70, "1")
        w.g(0, "LTYPE"); w.g(2, "CONTINUOUS"); w.g(70, "0"); w.g(3, "Solid line"); w.g(72, "65"); w.g(73, "0"); w.g(40, "0.0")
        w.g(0, "ENDTAB")
        w.g(0, "TABLE"); w.g(2, "LAYER"); w.g(70, String(d.layers.count + 1))
        w.g(0, "LAYER"); w.g(2, "0"); w.g(70, "0"); w.g(62, "7"); w.g(6, "CONTINUOUS")
        for l in d.layers {
            // A layer that is hidden here is switched off there (negative colour).
            w.g(0, "LAYER"); w.g(2, layerName[l.id] ?? "0"); w.g(70, "0"); w.g(62, l.visible ? "7" : "-7"); w.g(6, "CONTINUOUS")
        }
        w.g(0, "ENDTAB")
        w.g(0, "ENDSEC")

        // Blocks: one per truss type and fixture type in use
        let trussIDs = Set(d.objects.filter { $0.kind == .truss }.map { $0.typeID })
        let fixtureIDs = Set(d.objects.filter { $0.kind == .fixture }.map { $0.typeID })
        w.g(0, "SECTION"); w.g(2, "BLOCKS")
        for id in trussIDs.sorted() {
            let name = safeName("TRUSS_" + id)
            w.g(0, "BLOCK"); w.g(8, "0"); w.g(2, name); w.g(70, "0"); w.point(CGPoint.zero); w.g(3, name)
            for (a, b) in trussLines(Library.trussType(id)) { line(&w, a, b, layer: "0", color: nil) }
            w.g(0, "ENDBLK"); w.g(8, "0")
        }
        for id in fixtureIDs.sorted() {
            let name = safeName("FIX_" + id)
            let type = d.fixtureType(id)
            w.g(0, "BLOCK"); w.g(8, "0"); w.g(2, name); w.g(70, "0"); w.point(CGPoint.zero); w.g(3, name)
            for p in type.prims {
                switch p.k {
                case .circle:
                    w.g(0, "CIRCLE"); w.g(8, "0"); w.point(CGPoint(x: p.a, y: p.b)); w.n(40, CGFloat(p.c))
                case .rect:
                    polyline(&w, [CGPoint(x: p.a, y: p.b), CGPoint(x: p.a + p.c, y: p.b),
                                  CGPoint(x: p.a + p.c, y: p.b + p.d), CGPoint(x: p.a, y: p.b + p.d)], closed: true, layer: "0", color: nil)
                case .line:
                    line(&w, CGPoint(x: p.a, y: p.b), CGPoint(x: p.c, y: p.d), layer: "0", color: nil)
                case .poly:
                    if p.bare != true { polyline(&w, p.pts.map { $0.cg }, closed: p.open != true, layer: "0", color: nil) }
                case .text:
                    text(&w, p.s, at: CGPoint(x: p.a, y: p.b - p.c * 0.36), height: CGFloat(p.c) * 0.72, rot: 0, layer: "0", color: nil, centred: true)
                }
            }
            w.g(0, "ENDBLK"); w.g(8, "0")
        }
        w.g(0, "ENDSEC")

        w.g(0, "SECTION"); w.g(2, "ENTITIES")
        let size = CGFloat(d.labelSize)
        for o in d.objects {
            let layer = lay(o)
            let color = aci(o.stroke)
            let t = o.transform
            switch o.kind {
            case .line:
                if o.pts.count >= 2 { line(&w, o.pts[0].cg, o.pts[1].cg, layer: layer, color: color) }
            case .polyline:
                polyline(&w, o.pts.map { $0.cg }, closed: o.closed, layer: layer, color: color)
            case .rect:
                let c = [CGPoint(x: 0, y: 0), CGPoint(x: o.w, y: 0), CGPoint(x: o.w, y: o.h), CGPoint(x: 0, y: o.h)].map { $0.applying(t) }
                polyline(&w, c, closed: true, layer: layer, color: color)
            case .ellipse:
                let centre = CGPoint(x: o.w / 2, y: o.h / 2).applying(t)
                if abs(o.w - o.h) < 0.001 {
                    w.g(0, "CIRCLE"); w.g(8, layer); w.g(62, String(color)); w.point(centre); w.n(40, CGFloat(o.w / 2))
                } else {
                    let pts = circlePoints(CGPoint.zero, 1).map { CGPoint(x: CGFloat(o.w / 2) * (1 + $0.x), y: CGFloat(o.h / 2) * (1 + $0.y)).applying(t) }
                    polyline(&w, pts, closed: true, layer: layer, color: color)
                }
            case .text:
                let s = CGFloat(max(o.textSize, 1))
                if o.tag == true {
                    let box = Tag.size(o)
                    let c = [CGPoint(x: 0, y: 0), CGPoint(x: box.width, y: 0), CGPoint(x: box.width, y: box.height), CGPoint(x: 0, y: box.height)].map { $0.applying(t) }
                    polyline(&w, c, closed: true, layer: layer, color: color)
                    text(&w, o.text, at: CGPoint(x: box.width / 2, y: s * 1.3).applying(t), height: s * 0.72, rot: o.rot, layer: layer, color: color, centred: true)
                } else {
                    text(&w, o.text, at: CGPoint(x: 0, y: s * 0.24).applying(t), height: s * 0.72, rot: o.rot, layer: layer, color: color)
                }
            case .truss:
                w.g(0, "INSERT"); w.g(8, layer); w.g(2, safeName("TRUSS_" + o.typeID)); w.point(o.pos.cg); w.n(50, CGFloat(o.rot))
                if !o.position.isEmpty {
                    // Position name rides along as extended text on the insert's layer, off the drawing
                    w.g(999, "POSITION " + o.position)
                }
            case .fixture:
                w.g(0, "INSERT"); w.g(8, layer); w.g(66, "1"); w.g(2, safeName("FIX_" + o.typeID)); w.point(o.pos.cg); w.n(50, CGFloat(o.rot))
                // Visible attributes, where the label shows on screen
                let level = o.labelLevel == true
                let dx = CGFloat(o.labelDX ?? 0), dy = CGFloat(o.labelDY ?? 0)
                let moved = LabelLayout.isManual(o) ? 0 : LabelLayout.shift(o.id)
                let base = CGFloat(o.h) / 2 + size * 0.35 + moved
                let anchor = CGPoint(x: 0, y: base).applying(t)
                let origin = CGPoint(x: anchor.x + dx, y: anchor.y + dy)
                let rot = level ? 0 : o.rot
                let a = degToRad(rot)
                var y: CGFloat = 0
                let colours = ["unit": 7, "patch": 1, "circuit": 5, "position": 3]
                for lineInfo in LabelLayout.lines(o, d) where !lineInfo.text.isEmpty {
                    let h = NSAttributedString(string: lineInfo.text, attributes: [.font: LabelLayout.font(lineInfo.size, italic: lineInfo.italic)]).size().height * 0.95
                    let up = y + h * 0.25
                    let p = CGPoint(x: origin.x - sin(a) * up, y: origin.y + cos(a) * up)
                    text(&w, lineInfo.text, at: p, height: lineInfo.size * 0.72, rot: rot, layer: layer, color: colours[lineInfo.field] ?? 8,
                         entity: "ATTRIB", tag: lineInfo.field.uppercased(), centred: true)
                    y += h
                }
                text(&w, o.position, at: o.pos.cg, height: size * 0.5, rot: 0, layer: layer, color: nil, entity: "ATTRIB", tag: "POSITION", hidden: true)
                text(&w, o.note, at: o.pos.cg, height: size * 0.5, rot: 0, layer: layer, color: nil, entity: "ATTRIB", tag: "NOTE", hidden: true)
                text(&w, d.fixtureType(o.typeID).displayName, at: o.pos.cg, height: size * 0.5, rot: 0, layer: layer, color: nil, entity: "ATTRIB", tag: "TYPE", hidden: true)
                w.g(0, "SEQEND"); w.g(8, layer)
            }
        }
        w.g(0, "ENDSEC")
        w.g(0, "EOF")
        return w.lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - Import

    private final class Entity {
        let type: String
        var codes: [(Int, String)] = []
        var children: [Entity] = []
        init(_ type: String) { self.type = type }

        func s(_ code: Int) -> String? { codes.first { $0.0 == code }?.1 }
        func d(_ code: Int, _ fallback: Double = 0) -> Double {
            guard let v = s(code), let n = Double(v.trimmingCharacters(in: .whitespaces)) else { return fallback }
            return n
        }
        func i(_ code: Int) -> Int { Int(d(code)) }
        func all(_ code: Int) -> [Double] {
            codes.filter { $0.0 == code }.compactMap { Double($0.1.trimmingCharacters(in: .whitespaces)) }
        }
        func p(_ base: Int = 10) -> CGPoint { CGPoint(x: d(base), y: d(base + 10)) }
    }

    private struct Block {
        var base = CGPoint.zero
        var entities: [Entity] = []
    }

    struct ImportResult {
        var added = 0
        var skipped: [String: Int] = [:]
        var layers = 0
    }

    private static func aciColor(_ i: Int) -> RGBA {
        switch abs(i) {
        case 1: return .red
        case 2: return .yellow
        case 3: return .green
        case 4: return RGBA(0.0, 0.7, 0.8)
        case 5: return .blue
        case 6: return .purple
        case 8, 9: return .grey
        case 30, 40: return .orange
        default: return .black
        }
    }

    private static func cleanMText(_ s: String) -> String {
        var out = ""
        var chars = Array(s)[...]
        while let c = chars.first {
            chars = chars.dropFirst()
            if c == "\\" , let next = chars.first {
                chars = chars.dropFirst()
                if next == "P" || next == "p" {
                    out.append(" ")
                } else if next == "\\" || next == "{" || next == "}" {
                    out.append(next)
                } else if "ACFHQTWfcahqtw".contains(next) {
                    // Formatting code: runs to the next semicolon
                    while let x = chars.first {
                        chars = chars.dropFirst()
                        if x == ";" { break }
                    }
                }
            } else if c != "{" && c != "}" {
                out.append(c)
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Adds a DXF file's contents to a drawing.
    static func importText(_ text: String, into d: inout Drawing) -> ImportResult {
        var result = ImportResult()

        // 1. Pairs of (code, value)
        let raw = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var pairs: [(Int, String)] = []
        pairs.reserveCapacity(raw.count / 2)
        var k = 0
        while k + 1 < raw.count {
            if let code = Int(raw[k].trimmingCharacters(in: .whitespaces)) {
                pairs.append((code, raw[k + 1].trimmingCharacters(in: .whitespaces)))
            }
            k += 2
        }

        // 2. Sections
        var section = ""
        var units = 1.0
        var layerColor: [String: Int] = [:]
        var blocks: [String: Block] = [:]
        var top: [Entity] = []
        var currentBlock: String? = nil
        var current: Entity? = nil
        var parent: Entity? = nil          // POLYLINE or INSERT collecting its VERTEX / ATTRIB entities
        var lastHeaderVar = ""

        func close() {
            guard let e = current else { return }
            current = nil
            if section == "TABLES" {
                if e.type == "LAYER", let name = e.s(2) { layerColor[name] = e.i(62) }
                return
            }
            if e.type == "BLOCK" {
                let name = e.s(2) ?? ""
                currentBlock = name
                blocks[name] = Block(base: e.p(), entities: [])
                return
            }
            if e.type == "ENDBLK" {
                currentBlock = nil
                parent = nil
                return
            }
            if e.type == "SEQEND" {
                parent = nil
                return
            }
            if let par = parent, e.type == "VERTEX" || e.type == "ATTRIB" {
                par.children.append(e)
                return
            }
            parent = nil
            if e.type == "POLYLINE" || (e.type == "INSERT" && e.i(66) == 1) { parent = e }
            if let b = currentBlock {
                blocks[b]?.entities.append(e)
            } else if section == "ENTITIES" {
                top.append(e)
            }
        }

        var i = 0
        while i < pairs.count {
            let (code, value) = pairs[i]
            i += 1
            if code == 0 {
                close()
                if value == "SECTION" {
                    if i < pairs.count, pairs[i].0 == 2 {
                        section = pairs[i].1
                        i += 1
                    }
                } else if value == "ENDSEC" {
                    section = ""
                } else if value == "EOF" {
                    break
                } else if section == "ENTITIES" || section == "BLOCKS" || section == "TABLES" {
                    current = Entity(value)
                }
            } else if section == "HEADER" {
                if code == 9 {
                    lastHeaderVar = value
                } else if lastHeaderVar == "$INSUNITS" && code == 70 {
                    switch Int(value) ?? 0 {
                    case 1: units = 25.4
                    case 2: units = 304.8
                    case 5: units = 10
                    case 6: units = 1000
                    default: units = 1
                    }
                }
            } else {
                current?.codes.append((code, value))
            }
        }
        close()

        // 3. Layers
        var layerID: [String: UUID] = [:]
        func layer(_ name: String) -> UUID {
            if let id = layerID[name] { return id }
            if let existing = d.layers.first(where: { $0.name.lowercased() == name.lowercased() }) {
                layerID[name] = existing.id
                return existing.id
            }
            let l = Layer(name: name.isEmpty ? "DXF" : name)
            d.layers.append(l)
            result.layers += 1
            layerID[name] = l.id
            return l.id
        }

        // 4. Entities into objects
        var made: [DrawObject] = []
        let limit = 40000

        func emit(_ e: Entity, _ t: CGAffineTransform, _ group: UUID?, _ inheritLayer: String?, _ depth: Int) {
            if made.count >= limit { return }
            var lname = e.s(8) ?? "0"
            if lname == "0", let inherit = inheritLayer { lname = inherit }
            var colorIndex = e.s(62) != nil ? e.i(62) : 256
            if colorIndex == 256 || colorIndex == 0 { colorIndex = layerColor[lname] ?? 7 }
            let scale = Double((abs(t.a * t.d - t.b * t.c)).squareRoot())
            let turn = Double(atan2(t.b, t.a)) * 180 / Double.pi

            func object(_ kind: Kind) -> DrawObject {
                var o = DrawObject(kind: kind, layer: layer(lname))
                o.stroke = aciColor(colorIndex)
                o.group = group
                return o
            }
            func addPolyline(_ pts: [CGPoint], closed: Bool) {
                if pts.count < 2 { return }
                var o = object(pts.count == 2 && !closed ? .line : .polyline)
                o.pts = pts.map { Pt($0.applying(t)) }
                o.closed = closed
                made.append(o)
            }
            func addText(_ s: String, at p: CGPoint, height: Double, rot: Double, dropBy: Double) {
                if s.isEmpty || height <= 0 { return }
                var o = object(.text)
                let size = height * scale / 0.72
                let world = p.applying(t)
                let a = (rot + turn) * Double.pi / 180
                // DXF places text by its baseline (or its top, for MTEXT); the app by the bottom of the line.
                o.pos = Pt(Double(world.x) + sin(a) * size * dropBy, Double(world.y) - cos(a) * size * dropBy)
                o.text = s
                o.textSize = size
                o.rot = rot + turn
                made.append(o)
            }

            switch e.type {
            case "LINE":
                addPolyline([e.p(10), e.p(11)], closed: false)
            case "LWPOLYLINE":
                let xs = e.all(10), ys = e.all(20)
                let n = min(xs.count, ys.count)
                addPolyline((0..<n).map { CGPoint(x: xs[$0], y: ys[$0]) }, closed: e.i(70) & 1 == 1)
            case "POLYLINE":
                if e.i(70) & 64 != 0 {
                    result.skipped["3D mesh", default: 0] += 1
                } else {
                    addPolyline(e.children.filter { $0.type == "VERTEX" }.map { $0.p() }, closed: e.i(70) & 1 == 1)
                }
            case "CIRCLE":
                let r = e.d(40) * scale
                if r > 0 {
                    var o = object(.ellipse)
                    let c = e.p().applying(t)
                    o.pos = Pt(Double(c.x) - r, Double(c.y) - r)
                    o.w = 2 * r
                    o.h = 2 * r
                    made.append(o)
                }
            case "ARC":
                let c = e.p(), r = e.d(40)
                let a0 = e.d(50)
                var a1 = e.d(51)
                if a1 <= a0 { a1 += 360 }
                let steps = max(2, Int(((a1 - a0) / 6).rounded(.up)))
                var pts: [CGPoint] = []
                for j in 0...steps {
                    let a = (a0 + (a1 - a0) * Double(j) / Double(steps)) * Double.pi / 180
                    pts.append(CGPoint(x: Double(c.x) + cos(a) * r, y: Double(c.y) + sin(a) * r))
                }
                addPolyline(pts, closed: false)
            case "ELLIPSE":
                let c = e.p(), major = e.p(11), ratio = e.d(40, 1)
                let start = e.d(41, 0)
                var end = e.d(42, 2 * Double.pi)
                if end <= start { end += 2 * Double.pi }
                let full = abs(end - start - 2 * Double.pi) < 0.001
                let minor = CGPoint(x: -major.y * ratio, y: major.x * ratio)
                let steps = 64
                var pts: [CGPoint] = []
                for j in 0..<(full ? steps : steps + 1) {
                    let a = start + (end - start) * Double(j) / Double(steps)
                    pts.append(CGPoint(x: Double(c.x) + Double(major.x) * cos(a) + Double(minor.x) * sin(a),
                                       y: Double(c.y) + Double(major.y) * cos(a) + Double(minor.y) * sin(a)))
                }
                addPolyline(pts, closed: full)
            case "SPLINE":
                var xs = e.all(11), ys = e.all(21)
                if xs.count < 2 {
                    xs = e.all(10)
                    ys = e.all(20)
                }
                let n = min(xs.count, ys.count)
                addPolyline((0..<n).map { CGPoint(x: xs[$0], y: ys[$0]) }, closed: e.i(70) & 1 == 1)
            case "TEXT", "ATTRIB":
                if e.type == "ATTRIB" && e.i(70) & 1 == 1 { break }   // invisible attribute
                let aligned = (e.i(72) != 0 || e.i(73) != 0) && e.s(11) != nil
                addText(e.s(1) ?? "", at: aligned ? e.p(11) : e.p(10), height: e.d(40), rot: e.d(50), dropBy: 0.24)
            case "MTEXT":
                let body = e.codes.filter { $0.0 == 3 }.map { $0.1 }.joined() + (e.s(1) ?? "")
                addText(cleanMText(body), at: e.p(10), height: e.d(40), rot: e.d(50), dropBy: 1.2)
            case "INSERT", "DIMENSION":
                guard depth < 8, let name = e.s(2), let block = blocks[name] else {
                    result.skipped[e.type.capitalized + " without its block", default: 0] += 1
                    break
                }
                var local = CGAffineTransform(translationX: -block.base.x, y: -block.base.y)
                if e.type == "INSERT" {
                    let sx = e.s(41) != nil ? e.d(41) : 1
                    let sy = e.s(42) != nil ? e.d(42) : sx
                    local = local.concatenating(CGAffineTransform(scaleX: CGFloat(sx), y: CGFloat(sy)))
                        .concatenating(CGAffineTransform(rotationAngle: degToRad(e.d(50))))
                        .concatenating(CGAffineTransform(translationX: e.p().x, y: e.p().y))
                }
                let g = group ?? UUID()
                let before = made.count
                for child in block.entities { emit(child, local.concatenating(t), g, lname, depth + 1) }
                for attrib in e.children where attrib.type == "ATTRIB" { emit(attrib, t, g, lname, depth + 1) }
                // A block that came out as a single object doesn't need to be a group
                if group == nil && made.count - before == 1 { made[before].group = nil }
            case "VERTEX", "SEQEND", "ATTDEF", "VIEWPORT", "POINT":
                break
            default:
                result.skipped[e.type.capitalized, default: 0] += 1
            }
        }

        let base = CGAffineTransform(scaleX: CGFloat(units), y: CGFloat(units))
        for e in top { emit(e, base, nil, nil, 0) }
        d.objects.append(contentsOf: made)
        result.added = made.count
        return result
    }
}
