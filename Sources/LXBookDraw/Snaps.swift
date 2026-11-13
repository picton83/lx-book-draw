import AppKit

// Object snaps, modelled on AutoCAD's running osnaps: a marker shows the snap point nearest the
// cursor inside the aperture, and a click takes exactly that point.

enum SnapKind: String, CaseIterable {
    case endpoint, midpoint, center, insertion, quadrant, intersection, perpendicular, nearest

    var label: String {
        switch self {
        case .endpoint: return "Endpoint"
        case .midpoint: return "Midpoint"
        case .center: return "Center"
        case .insertion: return "Insertion"
        case .quadrant: return "Quadrant"
        case .intersection: return "Intersection"
        case .perpendicular: return "Perpendicular"
        case .nearest: return "Nearest"
        }
    }

    /// The three-letter override typed at a point prompt, as in AutoCAD (END, MID, CEN...).
    var abbreviation: String {
        switch self {
        case .endpoint: return "end"
        case .midpoint: return "mid"
        case .center: return "cen"
        case .insertion: return "ins"
        case .quadrant: return "qua"
        case .intersection: return "int"
        case .perpendicular: return "per"
        case .nearest: return "nea"
        }
    }
}

struct SnapHit {
    var point: CGPoint
    var kind: SnapKind
}

/// Drafting aids. These belong to the app, not the drawing, so they stay as you left them.
enum Drafting {
    private static let defaults = UserDefaults.standard

    static var osnap: Bool {
        get { defaults.object(forKey: "osnapOn") == nil ? true : defaults.bool(forKey: "osnapOn") }
        set { defaults.set(newValue, forKey: "osnapOn") }
    }

    static var ortho: Bool {
        get { defaults.bool(forKey: "orthoOn") }
        set { defaults.set(newValue, forKey: "orthoOn") }
    }

    static var showGrid: Bool {
        get { defaults.object(forKey: "gridOn") == nil ? true : defaults.bool(forKey: "gridOn") }
        set { defaults.set(newValue, forKey: "gridOn") }
    }

    static var modes: Set<SnapKind> {
        get {
            guard let raw = defaults.array(forKey: "osnapModes") as? [String] else {
                return [.endpoint, .midpoint, .center, .insertion, .quadrant, .intersection, .perpendicular]
            }
            return Set(raw.compactMap { SnapKind(rawValue: $0) })
        }
        set { defaults.set(newValue.map { $0.rawValue }, forKey: "osnapModes") }
    }

    static func toggle(_ kind: SnapKind) {
        var m = modes
        if m.contains(kind) { m.remove(kind) } else { m.insert(kind) }
        modes = m
    }
}

enum Snapper {
    /// Straight edges of an object, in drawing coordinates.
    static func segments(of o: DrawObject) -> [(CGPoint, CGPoint)] {
        var out: [(CGPoint, CGPoint)] = []
        switch o.kind {
        case .line, .polyline:
            let ps = o.pts.map { $0.cg }
            if ps.count >= 2 {
                for i in 0..<(ps.count - 1) { out.append((ps[i], ps[i + 1])) }
                if o.closed && ps.count > 2 { out.append((ps[ps.count - 1], ps[0])) }
            }
        case .rect, .truss:
            let b = o.localBox()
            let t = o.transform
            let c = [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                     CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)].map { $0.applying(t) }
            for i in 0..<4 { out.append((c[i], c[(i + 1) % 4])) }
            if o.kind == .truss {
                // The centreline: its ends are where sections join, its midpoint is the section centre.
                out.append((CGPoint(x: b.minX, y: 0).applying(t), CGPoint(x: b.maxX, y: 0).applying(t)))
            }
        case .ellipse, .text, .fixture:
            break
        }
        return out
    }

    private static func closest(on seg: (CGPoint, CGPoint), to p: CGPoint) -> CGPoint {
        let dx = seg.1.x - seg.0.x
        let dy = seg.1.y - seg.0.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return seg.0 }
        let t = max(0, min(1, ((p.x - seg.0.x) * dx + (p.y - seg.0.y) * dy) / len2))
        return CGPoint(x: seg.0.x + t * dx, y: seg.0.y + t * dy)
    }

    private static func intersection(_ a: (CGPoint, CGPoint), _ b: (CGPoint, CGPoint)) -> CGPoint? {
        let r = CGPoint(x: a.1.x - a.0.x, y: a.1.y - a.0.y)
        let s = CGPoint(x: b.1.x - b.0.x, y: b.1.y - b.0.y)
        let denom = r.x * s.y - r.y * s.x
        if abs(denom) < 1e-9 { return nil }
        let qp = CGPoint(x: b.0.x - a.0.x, y: b.0.y - a.0.y)
        let t = (qp.x * s.y - qp.y * s.x) / denom
        let u = (qp.x * r.y - qp.y * r.x) / denom
        if t < -1e-6 || t > 1 + 1e-6 || u < -1e-6 || u > 1 + 1e-6 { return nil }
        return CGPoint(x: a.0.x + t * r.x, y: a.0.y + t * r.y)
    }

    /// The best snap point within `aperture` (drawing units) of the cursor, or nil.
    /// `from` is the previous point of the command, used for Perpendicular.
    static func find(near p: CGPoint, in d: Drawing, aperture: CGFloat, modes: Set<SnapKind>, from ref: CGPoint?) -> SnapHit? {
        if modes.isEmpty { return nil }
        var best: SnapHit? = nil
        var bestScore = CGFloat.greatestFiniteMagnitude

        func offer(_ point: CGPoint, _ kind: SnapKind, hovering: Bool = false) {
            if !modes.contains(kind) { return }
            var dist = distance(point, p)
            if hovering {
                // Insertion and centre points are offered whenever the cursor is over the object.
                dist = min(dist, aperture * 0.8)
            }
            if dist > aperture { return }
            // Nearest only wins when nothing more specific is in reach.
            let score = dist + (kind == .nearest ? aperture : 0)
            if score < bestScore {
                bestScore = score
                best = SnapHit(point: point, kind: kind)
            }
        }

        var nearby: [(CGPoint, CGPoint)] = []
        for o in d.objects where d.isVisible(o) {
            let bounds = o.worldBounds().insetBy(dx: -aperture, dy: -aperture)
            if !bounds.contains(p) { continue }

            switch o.kind {
            case .fixture, .text:
                let inside = o.hit(p, tol: 0)
                offer(o.pos.cg, .insertion, hovering: inside)
            case .ellipse:
                let t = o.transform
                let centre = CGPoint(x: o.w / 2, y: o.h / 2).applying(t)
                offer(centre, .center, hovering: o.hit(p, tol: 0))
                let quads = [CGPoint(x: o.w, y: o.h / 2), CGPoint(x: o.w / 2, y: o.h),
                             CGPoint(x: 0, y: o.h / 2), CGPoint(x: o.w / 2, y: 0)]
                for q in quads { offer(q.applying(t), .quadrant) }
            default:
                break
            }

            for seg in segments(of: o) {
                offer(seg.0, .endpoint)
                offer(seg.1, .endpoint)
                offer(CGPoint(x: (seg.0.x + seg.1.x) / 2, y: (seg.0.y + seg.1.y) / 2), .midpoint)
                let near = closest(on: seg, to: p)
                if distance(near, p) <= aperture {
                    nearby.append(seg)
                    offer(near, .nearest)
                    if let ref = ref {
                        let foot = closest(on: seg, to: ref)
                        // Only a true perpendicular: the foot must not be clamped to an end.
                        if distance(foot, seg.0) > 1 && distance(foot, seg.1) > 1 { offer(foot, .perpendicular) }
                    }
                }
            }
        }

        if modes.contains(.intersection) && nearby.count >= 2 && nearby.count <= 40 {
            for i in 0..<(nearby.count - 1) {
                for j in (i + 1)..<nearby.count {
                    if let x = intersection(nearby[i], nearby[j]) { offer(x, .intersection) }
                }
            }
        }
        return best
    }

    /// AutoSnap marker, drawn in screen points.
    static func drawMarker(_ kind: SnapKind, at c: CGPoint, in ctx: CGContext) {
        let s: CGFloat = 6
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemGreen.cgColor)
        ctx.setLineWidth(2)
        ctx.beginPath()
        switch kind {
        case .endpoint:
            ctx.addRect(CGRect(x: c.x - s, y: c.y - s, width: s * 2, height: s * 2))
        case .midpoint:
            ctx.move(to: CGPoint(x: c.x - s, y: c.y - s))
            ctx.addLine(to: CGPoint(x: c.x + s, y: c.y - s))
            ctx.addLine(to: CGPoint(x: c.x, y: c.y + s))
            ctx.closePath()
        case .center:
            ctx.addEllipse(in: CGRect(x: c.x - s, y: c.y - s, width: s * 2, height: s * 2))
        case .insertion:
            ctx.addRect(CGRect(x: c.x - s, y: c.y - s, width: s * 1.3, height: s * 1.3))
            ctx.addRect(CGRect(x: c.x - s * 0.3, y: c.y - s * 0.3, width: s * 1.3, height: s * 1.3))
        case .quadrant:
            ctx.move(to: CGPoint(x: c.x - s, y: c.y))
            ctx.addLine(to: CGPoint(x: c.x, y: c.y + s))
            ctx.addLine(to: CGPoint(x: c.x + s, y: c.y))
            ctx.addLine(to: CGPoint(x: c.x, y: c.y - s))
            ctx.closePath()
        case .intersection:
            ctx.move(to: CGPoint(x: c.x - s, y: c.y - s)); ctx.addLine(to: CGPoint(x: c.x + s, y: c.y + s))
            ctx.move(to: CGPoint(x: c.x - s, y: c.y + s)); ctx.addLine(to: CGPoint(x: c.x + s, y: c.y - s))
        case .perpendicular:
            ctx.move(to: CGPoint(x: c.x - s, y: c.y + s))
            ctx.addLine(to: CGPoint(x: c.x - s, y: c.y - s))
            ctx.addLine(to: CGPoint(x: c.x + s, y: c.y - s))
            ctx.move(to: CGPoint(x: c.x - s, y: c.y))
            ctx.addLine(to: CGPoint(x: c.x, y: c.y))
            ctx.addLine(to: CGPoint(x: c.x, y: c.y - s))
        case .nearest:
            ctx.move(to: CGPoint(x: c.x - s, y: c.y - s))
            ctx.addLine(to: CGPoint(x: c.x + s, y: c.y - s))
            ctx.addLine(to: CGPoint(x: c.x - s, y: c.y + s))
            ctx.addLine(to: CGPoint(x: c.x + s, y: c.y + s))
            ctx.closePath()
        }
        ctx.strokePath()
        ctx.restoreGState()

        let tip = NSAttributedString(string: kind.label, attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.black,
            .backgroundColor: NSColor(calibratedRed: 1, green: 0.97, blue: 0.75, alpha: 1)
        ])
        tip.draw(at: CGPoint(x: c.x + 12, y: c.y - 22))
    }
}
