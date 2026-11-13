import AppKit

func degToRad(_ deg: Double) -> CGFloat { CGFloat(deg * Double.pi / 180.0) }

func fmtNum(_ v: Double) -> String {
    if v == v.rounded() { return String(Int(v)) }
    return String(format: "%.1f", v)
}

func parseNum(_ s: String) -> Double? {
    Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
}

func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = a.x - b.x
    let dy = a.y - b.y
    return (dx * dx + dy * dy).squareRoot()
}

func distToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let len2 = dx * dx + dy * dy
    if len2 == 0 { return distance(p, a) }
    var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
    t = max(0, min(1, t))
    return distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
}

extension RGBA {
    var ns: NSColor { NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a)) }
}

extension DrawObject {
    /// Local frame to drawing coordinates: rotate, then move to pos.
    var transform: CGAffineTransform {
        CGAffineTransform(translationX: CGFloat(pos.x), y: CGFloat(pos.y)).rotated(by: degToRad(rot))
    }

    func textAttr() -> NSAttributedString {
        NSAttributedString(string: text.isEmpty ? " " : text, attributes: [
            .font: NSFont.systemFont(ofSize: CGFloat(max(textSize, 1))),
            .foregroundColor: Renderer.ink(stroke).ns
        ])
    }

    mutating func rotate(about c: CGPoint, degrees: Double) {
        let a = degrees * Double.pi / 180
        let cs = cos(a)
        let sn = sin(a)
        func turn(_ p: Pt) -> Pt {
            let dx = p.x - Double(c.x)
            let dy = p.y - Double(c.y)
            return Pt(Double(c.x) + dx * cs - dy * sn, Double(c.y) + dx * sn + dy * cs)
        }
        pos = turn(pos)
        pts = pts.map { turn($0) }
        rot += degrees
    }

    var usesPoints: Bool { kind == .line || kind == .polyline }

    /// Box in the object's own frame. Not used for lines and polylines.
    func localBox() -> CGRect {
        switch kind {
        case .rect, .ellipse:
            return CGRect(x: 0, y: 0, width: w, height: h)
        case .truss:
            let t = Library.trussType(typeID)
            return CGRect(x: 0, y: -t.width / 2, width: t.length, height: t.width)
        case .fixture:
            return CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        case .text:
            if tag == true {
                let box = Tag.size(self)
                return CGRect(x: 0, y: 0, width: box.width, height: box.height)
            }
            let s = textAttr().size()
            return CGRect(x: 0, y: 0, width: s.width, height: s.height)
        case .line, .polyline:
            return CGRect.zero
        }
    }

    func worldBounds() -> CGRect {
        if usesPoints {
            guard let first = pts.first else { return CGRect.null }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in pts {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        return localBox().applying(transform)
    }

    func hit(_ p: CGPoint, tol: CGFloat) -> Bool {
        if usesPoints {
            var ps = pts.map { $0.cg }
            if closed, let f = ps.first { ps.append(f) }
            if ps.count < 2 { return false }
            for i in 0..<(ps.count - 1) {
                if distToSegment(p, ps[i], ps[i + 1]) <= tol { return true }
            }
            return false
        }
        let lp = p.applying(transform.inverted())
        return localBox().insetBy(dx: -tol, dy: -tol).contains(lp)
    }
}

extension Drawing {
    func topObject(at p: CGPoint, tol: CGFloat) -> UUID? {
        for o in objects.reversed() {
            if !isVisible(o) || isLocked(o) { continue }
            if o.hit(p, tol: tol) { return o.id }
        }
        return nil
    }

    /// Bounds of everything visible, padded to leave room for fixture labels.
    func extents() -> CGRect {
        var r = CGRect.null
        for o in objects where isVisible(o) {
            var b = o.worldBounds()
            if o.kind == .fixture && showLabels {
                b = b.insetBy(dx: -CGFloat(labelSize) * 2, dy: -CGFloat(labelSize) * 4)
            }
            r = r.union(b)
        }
        return r
    }

    /// Fixtures hung on any of these objects.
    func attachedFixtures(to ids: Set<UUID>) -> Set<UUID> {
        var out = Set<UUID>()
        for o in objects where o.kind == .fixture {
            if let a = o.attachedTo, ids.contains(a) { out.insert(o.id) }
        }
        return out
    }
}

enum Geometry {
    /// Snaps a fixture onto the nearest truss centreline within maxDist, taking its rotation and position name.
    static func attach(_ o: inout DrawObject, in d: Drawing, maxDist: Double) {
        var bestDist = Double.greatestFiniteMagnitude
        var best: DrawObject? = nil
        var bestX = 0.0
        for t in d.objects where t.kind == .truss && d.isVisible(t) {
            let type = Library.trussType(t.typeID)
            let lp = o.pos.cg.applying(t.transform.inverted())
            let lx = Double(lp.x)
            let ly = Double(lp.y)
            if lx < -150 || lx > type.length + 150 { continue }
            if abs(ly) > maxDist { continue }
            if abs(ly) < bestDist {
                bestDist = abs(ly)
                best = t
                bestX = max(0, min(type.length, lx))
            }
        }
        if let t = best {
            let wp = CGPoint(x: bestX, y: 0).applying(t.transform)
            o.pos = Pt(wp)
            o.rot = t.rot
            o.attachedTo = t.id
            if !t.position.isEmpty { o.position = t.position }
        } else {
            o.attachedTo = nil
        }
    }
}
