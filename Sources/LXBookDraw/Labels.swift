import AppKit

/// Automatic label placement. A fixture's label normally sits just above its symbol. When that would
/// run into a neighbour's label or symbol, the label is moved on its own: up a row, up two rows, or
/// to the other side of the fixture, whichever is the first free place. Labels you have moved
/// yourself are left where you put them and everything else works round them.
enum LabelLayout {
    private static var keyObjects: [DrawObject] = []
    private static var keyLayers: [Layer] = []
    private static var keySize = 0.0
    private static var keyOn = true
    private static var keyParts: [LabelPart]? = nil
    private static var result: [UUID: CGFloat] = [:]

    /// Works out the layout for a drawing; cheap to call again when nothing changed.
    static func prepare(_ d: Drawing) {
        let on = (d.autoLabels ?? true) && d.showLabels
        if on == keyOn && d.labelSize == keySize && d.labelParts == keyParts && d.layers == keyLayers && d.objects == keyObjects { return }
        keyParts = d.labelParts
        keyObjects = d.objects
        keyLayers = d.layers
        keySize = d.labelSize
        keyOn = on
        result = on ? compute(d) : [:]
    }

    /// How far (mm, in the fixture's own frame, + is away from the symbol) the label has been moved.
    static func shift(_ id: UUID) -> CGFloat { result[id] ?? 0 }

    /// A fixture's label lines from the bottom of the stack upward, as set in Fixture Label Config.
    static func lines(_ o: DrawObject, _ d: Drawing) -> [(field: String, text: String, color: RGBA, italic: Bool, size: CGFloat)] {
        var out: [(field: String, text: String, color: RGBA, italic: Bool, size: CGFloat)] = []
        for part in d.effectiveLabelParts.reversed() where part.on {
            let size = CGFloat(max(part.size, 1))
            switch part.field {
            case "unit": out.append(("unit", o.unit, RGBA.black, false, size))
            case "patch":
                let both = !o.universe.isEmpty && !o.address.isEmpty
                out.append(("patch", both ? o.universe + "/" + o.address : o.universe + o.address, RGBA.red, true, size))
            case "circuit": out.append(("circuit", o.circuit, RGBA.blue, false, size))
            case "position": out.append(("position", o.position, RGBA.green, false, size))
            case "type": out.append(("type", d.fixtureType(o.typeID).name, RGBA.grey, false, size))
            case "note": out.append(("note", o.note, RGBA.grey, true, size))
            default: break
            }
        }
        return out
    }

    static func font(_ size: CGFloat, italic: Bool) -> NSFont {
        let f = NSFont.systemFont(ofSize: size)
        return italic ? NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) : f
    }

    /// Width and height of a fixture's label stack.
    static func blockSize(_ o: DrawObject, _ d: Drawing) -> CGSize {
        var w: CGFloat = 0
        var h: CGFloat = 0
        for line in lines(o, d) where !line.text.isEmpty {
            let s = NSAttributedString(string: line.text, attributes: [.font: font(line.size, italic: line.italic)]).size()
            w = max(w, s.width)
            h += s.height * 0.95
        }
        return CGSize(width: w, height: h)
    }

    static func isManual(_ o: DrawObject) -> Bool {
        (o.labelDX ?? 0) != 0 || (o.labelDY ?? 0) != 0 || o.labelLevel == true
    }

    /// The four corners of a label in drawing coordinates.
    private static func labelQuad(_ o: DrawObject, _ block: CGSize, _ size: CGFloat, shift: CGFloat) -> [CGPoint] {
        let base = CGFloat(o.h) / 2 + size * 0.35
        let half = block.width * 0.47   // a touch narrower, so labels that only just touch don't count
        let dx = CGFloat(o.labelDX ?? 0)
        let dy = CGFloat(o.labelDY ?? 0)
        if o.labelLevel == true {
            let a = CGPoint(x: 0, y: base).applying(o.transform)
            let x = a.x + dx
            let y = a.y + dy
            return [CGPoint(x: x - half, y: y), CGPoint(x: x + half, y: y),
                    CGPoint(x: x + half, y: y + block.height), CGPoint(x: x - half, y: y + block.height)]
        }
        let y0 = base + shift
        let local = [CGPoint(x: -half, y: y0), CGPoint(x: half, y: y0),
                     CGPoint(x: half, y: y0 + block.height), CGPoint(x: -half, y: y0 + block.height)]
        return local.map { p in
            let w = p.applying(o.transform)
            return CGPoint(x: w.x + dx, y: w.y + dy)
        }
    }

    private static func symbolQuad(_ o: DrawObject) -> [CGPoint] {
        let b = o.localBox()
        return [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)].map { $0.applying(o.transform) }
    }

    /// Do two convex shapes overlap? (Separating axis test.)
    static func overlap(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
        for shape in [a, b] {
            for i in 0..<shape.count {
                let p = shape[i]
                let q = shape[(i + 1) % shape.count]
                let nx = -(q.y - p.y)
                let ny = q.x - p.x
                var minA = CGFloat.greatestFiniteMagnitude, maxA = -CGFloat.greatestFiniteMagnitude
                var minB = CGFloat.greatestFiniteMagnitude, maxB = -CGFloat.greatestFiniteMagnitude
                for v in a {
                    let t = v.x * nx + v.y * ny
                    minA = min(minA, t); maxA = max(maxA, t)
                }
                for v in b {
                    let t = v.x * nx + v.y * ny
                    minB = min(minB, t); maxB = max(maxB, t)
                }
                if maxA <= minB || maxB <= minA { return false }
            }
        }
        return true
    }

    private static func compute(_ d: Drawing) -> [UUID: CGFloat] {
        let size = CGFloat(d.labelSize)
        let fixtures = d.objects.filter { $0.kind == .fixture && d.isVisible($0) }
        let symbols: [(id: UUID, quad: [CGPoint])] = fixtures.map { ($0.id, symbolQuad($0)) }
        var placed: [[CGPoint]] = []
        var pending: [(o: DrawObject, block: CGSize)] = []
        for o in fixtures {
            let block = blockSize(o, d)
            if block.width <= 0 { continue }
            if isManual(o) {
                placed.append(labelQuad(o, block, size, shift: 0))
            } else {
                pending.append((o, block))
            }
        }
        // Work along each row in order, so neighbours take turns.
        pending.sort { a, b in
            if a.o.pos.x != b.o.pos.x { return a.o.pos.x < b.o.pos.x }
            return a.o.pos.y < b.o.pos.y
        }
        var out: [UUID: CGFloat] = [:]
        for item in pending {
            let o = item.o
            let block = item.block
            let base = CGFloat(o.h) / 2 + size * 0.35
            let row = block.height + size * 0.15
            let otherSide = -(2 * base + block.height)
            let candidates: [CGFloat] = [0, row, 2 * row, otherSide, otherSide - row, 3 * row]
            var chosen: CGFloat = 0
            for c in candidates {
                let q = labelQuad(o, block, size, shift: c)
                if placed.contains(where: { overlap($0, q) }) { continue }
                if symbols.contains(where: { $0.id != o.id && overlap($0.quad, q) }) { continue }
                chosen = c
                break
            }
            if chosen != 0 { out[o.id] = chosen }
            placed.append(labelQuad(o, block, size, shift: chosen))
        }
        return out
    }
}

/// Location tags: a text object marked as a tag is drawn as a box with the location's name and its
/// tape colours from Lx Book, each with the colour's name written on it.
enum Tag {
    static func nameAttr(_ o: DrawObject, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: o.text.isEmpty ? " " : o.text, attributes: [
            .font: NSFont.systemFont(ofSize: CGFloat(max(o.textSize, 1)), weight: .heavy),
            .foregroundColor: color
        ])
    }

    static func size(_ o: DrawObject) -> CGSize {
        let s = CGFloat(max(o.textSize, 1))
        let name = nameAttr(o, NSColor.black).size()
        return CGSize(width: max(name.width + s * 0.8, s * 6.6), height: name.height + s * 1.15)
    }

    static func color(hex: String) -> RGBA {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = Int(h, radix: 16) else { return RGBA.grey }
        return RGBA(Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255)
    }

    static func draw(_ o: DrawObject, _ d: Drawing, _ ctx: CGContext, _ lw: CGFloat) {
        let s = CGFloat(max(o.textSize, 1))
        let box = CGRect(origin: CGPoint.zero, size: size(o))
        let band = s * 0.95
        let key = o.text.trimmingCharacters(in: .whitespaces).lowercased()
        let location = (d.locations ?? []).first { $0.name.lowercased() == key || (!$0.short.isEmpty && $0.short.lowercased() == key) }
        let tapes = location?.tapes ?? []

        ctx.setFillColor(Renderer.paper(RGBA.white).cg)
        ctx.fill(box)

        // Colour bands along the bottom, each labelled with its colour name
        if tapes.isEmpty {
            let note = NSAttributedString(string: location == nil ? "not in Lx Book" : "no colours set", attributes: [
                .font: NSFont.systemFont(ofSize: s * 0.36), .foregroundColor: Renderer.ink(RGBA.grey).ns
            ])
            note.draw(at: CGPoint(x: box.midX - note.size().width / 2, y: (band - note.size().height) / 2))
        } else {
            let w = box.width / CGFloat(tapes.count)
            for (i, tape) in tapes.enumerated() {
                let r = CGRect(x: CGFloat(i) * w, y: 0, width: w, height: band)
                let a = color(hex: tape.a)
                ctx.setFillColor(a.cg)
                ctx.fill(r)
                if let second = tape.b {
                    // Two-colour tape: second colour on the right-hand half
                    ctx.setFillColor(color(hex: second).cg)
                    ctx.fill(CGRect(x: r.midX, y: 0, width: w / 2, height: band))
                }
                let lum = 0.299 * a.r + 0.587 * a.g + 0.114 * a.b
                let label = NSAttributedString(string: tape.name.uppercased(), attributes: [
                    .font: NSFont.systemFont(ofSize: s * 0.34, weight: .bold),
                    .foregroundColor: lum > 0.6 ? NSColor.black : NSColor.white
                ])
                let ls = label.size()
                if ls.width < w * 1.6 {
                    label.draw(at: CGPoint(x: r.midX - ls.width / 2, y: (band - ls.height) / 2))
                }
                ctx.setStrokeColor(Renderer.ink(RGBA.black).cg)
                ctx.setLineWidth(lw * 0.6)
                ctx.stroke(r)
            }
        }

        let name = nameAttr(o, Renderer.ink(RGBA.black).ns)
        let ns = name.size()
        name.draw(at: CGPoint(x: box.midX - ns.width / 2, y: band + (box.height - band - ns.height) / 2))
        ctx.setStrokeColor(Renderer.ink(RGBA.black).cg)
        ctx.setLineWidth(lw * 1.4)
        ctx.stroke(box)
    }
}
