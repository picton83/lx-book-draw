import Foundation

// Real fixture symbols from a GDTF file.
// 1. thumbnail.svg, the manufacturer's own plan-view drawing, read line for line.
// 2. If there is none, the outline of each part's 3D model (glb or 3ds) as seen from above.

/// One outline read from the symbol drawing.
struct SymbolShape {
    var pts: [Pt]
    var closed: Bool
    var filled: Bool
}

/// A 2D transform as SVG writes it: x' = a x + c y + e, y' = b x + d y + f.
private struct M2 {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0, e = 0.0, f = 0.0

    /// self applied after other.
    func times(_ o: M2) -> M2 {
        M2(a: a * o.a + c * o.b, b: b * o.a + d * o.b,
           c: a * o.c + c * o.d, d: b * o.c + d * o.d,
           e: a * o.e + c * o.f + e, f: b * o.e + d * o.f + f)
    }

    func apply(_ p: Pt) -> Pt { Pt(a * p.x + c * p.y + e, b * p.x + d * p.y + f) }
}

private final class SVGNode {
    let name: String
    let attrs: [String: String]
    var children: [SVGNode] = []
    init(name: String, attrs: [String: String]) {
        self.name = name
        self.attrs = attrs
    }
}

private final class SVGBuilder: NSObject, XMLParserDelegate {
    var root: SVGNode? = nil
    var stack: [SVGNode] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        var name = elementName
        if let colon = name.lastIndex(of: ":") { name = String(name[name.index(after: colon)...]) }
        let node = SVGNode(name: name, attrs: attributeDict)
        if let top = stack.last {
            top.children.append(node)
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }
}

enum SVGSymbol {
    /// Every number in a string, in order ("12.5,-3e2 4" gives 12.5, -300, 4).
    static func numbers(_ s: String) -> [Double] {
        var out: [Double] = []
        let chars = Array(s.unicodeScalars)
        var i = 0
        let n = chars.count
        func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 48 && c.value <= 57 }
        while i < n {
            let c = chars[i]
            let signed = (c == "-" || c == "+") && i + 1 < n && (isDigit(chars[i + 1]) || chars[i + 1] == ".")
            let dotted = c == "." && i + 1 < n && isDigit(chars[i + 1])
            if !(isDigit(c) || signed || dotted) {
                i += 1
                continue
            }
            var j = i
            if chars[j] == "-" || chars[j] == "+" { j += 1 }
            var seenDot = false
            while j < n && (isDigit(chars[j]) || (chars[j] == "." && !seenDot)) {
                if chars[j] == "." { seenDot = true }
                j += 1
            }
            if j < n && (chars[j] == "e" || chars[j] == "E") {
                var k = j + 1
                if k < n && (chars[k] == "-" || chars[k] == "+") { k += 1 }
                if k < n && isDigit(chars[k]) {
                    while k < n && isDigit(chars[k]) { k += 1 }
                    j = k
                }
            }
            var text = ""
            for q in i..<j { text.unicodeScalars.append(chars[q]) }
            if let v = Double(text) { out.append(v) }
            i = max(j, i + 1)
        }
        return out
    }

    /// The leading number of an attribute such as "493mm".
    private static func lead(_ s: String?) -> Double {
        numbers(s ?? "").first ?? 0
    }

    private static func transform(_ s: String?) -> M2 {
        var m = M2()
        guard let s = s else { return m }
        for piece in s.components(separatedBy: ")") {
            let parts = piece.components(separatedBy: "(")
            if parts.count != 2 { continue }
            let name = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: " ,\n\t\r"))
            let v = numbers(parts[1])
            var t: M2? = nil
            switch name {
            case "matrix":
                if v.count == 6 { t = M2(a: v[0], b: v[1], c: v[2], d: v[3], e: v[4], f: v[5]) }
            case "translate":
                if v.count >= 1 { t = M2(e: v[0], f: v.count > 1 ? v[1] : 0) }
            case "scale":
                if v.count >= 1 { t = M2(a: v[0], d: v.count > 1 ? v[1] : v[0]) }
            case "rotate":
                if v.count >= 1 {
                    let r = v[0] * Double.pi / 180
                    var turn = M2(a: cos(r), b: sin(r), c: -sin(r), d: cos(r))
                    if v.count == 3 {
                        turn = M2(e: v[1], f: v[2]).times(turn).times(M2(e: -v[1], f: -v[2]))
                    }
                    t = turn
                }
            default:
                break
            }
            if let t = t { m = m.times(t) }
        }
        return m
    }

    private static func cubic(_ p0: Pt, _ p1: Pt, _ p2: Pt, _ p3: Pt, into out: inout [Pt]) {
        let steps = 10
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let u = 1 - t
            let w0: Double = u * u * u
            let w1: Double = 3.0 * u * u * t
            let w2: Double = 3.0 * u * t * t
            let w3: Double = t * t * t
            let x: Double = w0 * p0.x + w1 * p1.x + w2 * p2.x + w3 * p3.x
            let y: Double = w0 * p0.y + w1 * p1.y + w2 * p2.y + w3 * p3.y
            out.append(Pt(x, y))
        }
    }

    private static func quad(_ p: Pt, _ q: Pt, _ e: Pt, into out: inout [Pt]) {
        let k = 2.0 / 3.0
        cubic(p, Pt(p.x + k * (q.x - p.x), p.y + k * (q.y - p.y)), Pt(e.x + k * (q.x - e.x), e.y + k * (q.y - e.y)), e, into: &out)
    }

    /// An SVG elliptical arc from p0 to p1, as short straight pieces.
    private static func arc(_ p0: Pt, _ rxIn: Double, _ ryIn: Double, _ phi: Double, _ large: Bool, _ sweep: Bool, _ p1: Pt,
                            into out: inout [Pt]) {
        var rx = abs(rxIn)
        var ry = abs(ryIn)
        if rx == 0 || ry == 0 || p0 == p1 {
            out.append(p1)
            return
        }
        let ph = phi * Double.pi / 180
        let cs = cos(ph)
        let sn = sin(ph)
        let dx = (p0.x - p1.x) / 2
        let dy = (p0.y - p1.y) / 2
        let x1 = cs * dx + sn * dy
        let y1 = -sn * dx + cs * dy
        let lam = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if lam > 1 {
            let k = lam.squareRoot()
            rx *= k
            ry *= k
        }
        let rx2: Double = rx * rx
        let ry2: Double = ry * ry
        let num: Double = rx2 * ry2 - rx2 * y1 * y1 - ry2 * x1 * x1
        let den: Double = rx2 * y1 * y1 + ry2 * x1 * x1
        var co: Double = den > 0 ? max(0.0, num / den).squareRoot() : 0.0
        if large == sweep { co = -co }
        let cx1 = co * rx * y1 / ry
        let cy1 = -co * ry * x1 / rx
        let cx = cs * cx1 - sn * cy1 + (p0.x + p1.x) / 2
        let cy = sn * cx1 + cs * cy1 + (p0.y + p1.y) / 2
        let a0 = atan2((y1 - cy1) / ry, (x1 - cx1) / rx)
        let a1 = atan2((-y1 - cy1) / ry, (-x1 - cx1) / rx)
        var da = a1 - a0
        if sweep && da < 0 { da += 2 * Double.pi }
        if !sweep && da > 0 { da -= 2 * Double.pi }
        let steps = max(2, Int(abs(da) / (Double.pi / 12)) + 1)
        for i in 1...steps {
            let a = a0 + da * Double(i) / Double(steps)
            let ex = rx * cos(a)
            let ey = ry * sin(a)
            out.append(Pt(cs * ex - sn * ey + cx, sn * ex + cs * ey + cy))
        }
    }

    private enum Tok {
        case cmd(Character)
        case num(Double)
    }

    private static func tokens(_ d: String) -> [Tok] {
        var out: [Tok] = []
        var run = ""
        func flush() {
            for v in numbers(run) { out.append(.num(v)) }
            run = ""
        }
        for ch in d {
            if ch.isLetter && ch != "e" && ch != "E" {
                flush()
                out.append(.cmd(ch))
            } else {
                run.append(ch)
            }
        }
        flush()
        return out
    }

    /// The outlines of one SVG path.
    private static func path(_ d: String) -> [(pts: [Pt], closed: Bool)] {
        let t = tokens(d)
        var subs: [(pts: [Pt], closed: Bool)] = []
        var open = false          // true while the last entry of subs is still being drawn
        var i = 0
        var cmd: Character = " "
        var p = Pt(0, 0)
        var start = Pt(0, 0)
        var last: Pt? = nil
        var lastCmd: Character = " "

        func isNum(_ k: Int) -> Bool {
            if k >= t.count { return false }
            if case .num = t[k] { return true }
            return false
        }
        func num() -> Double {
            if i < t.count, case .num(let v) = t[i] {
                i += 1
                return v
            }
            i += 1
            return 0
        }
        func add(_ q: Pt) {
            if !open {
                subs.append((pts: [p], closed: false))
                open = true
            }
            subs[subs.count - 1].pts.append(q)
        }
        func addAll(_ qs: [Pt]) {
            for q in qs { add(q) }
        }

        while i < t.count {
            if case .cmd(let c) = t[i] {
                cmd = c
                i += 1
            } else if cmd == " " {
                i += 1
                continue
            }
            let rel = cmd.isLowercase
            let C = Character(String(cmd).uppercased())
            let ox = rel ? p.x : 0
            let oy = rel ? p.y : 0
            if C == "Z" {
                if open && subs[subs.count - 1].pts.count > 1 { subs[subs.count - 1].closed = true }
                p = start
                open = false
                lastCmd = "Z"
                cmd = " "
                continue
            }
            if !isNum(i) { continue }
            switch C {
            case "M":
                let x = ox + num()
                let y = oy + num()
                p = Pt(x, y)
                start = p
                subs.append((pts: [p], closed: false))
                open = true
                cmd = rel ? "l" : "L"
                lastCmd = "M"
                continue
            case "L":
                let x = ox + num()
                let y = oy + num()
                add(Pt(x, y))
                p = Pt(x, y)
            case "H":
                let x = ox + num()
                add(Pt(x, p.y))
                p = Pt(x, p.y)
            case "V":
                let y = oy + num()
                add(Pt(p.x, y))
                p = Pt(p.x, y)
            case "C", "S":
                var a = p
                if C == "C" {
                    let ax = ox + num()
                    let ay = oy + num()
                    a = Pt(ax, ay)
                } else if let l = last, lastCmd == "C" || lastCmd == "S" {
                    a = Pt(2 * p.x - l.x, 2 * p.y - l.y)
                }
                let bx = ox + num()
                let by = oy + num()
                let ex = ox + num()
                let ey = oy + num()
                var piece: [Pt] = []
                cubic(p, a, Pt(bx, by), Pt(ex, ey), into: &piece)
                addAll(piece)
                last = Pt(bx, by)
                p = Pt(ex, ey)
            case "Q", "T":
                var q = p
                if C == "Q" {
                    let qx = ox + num()
                    let qy = oy + num()
                    q = Pt(qx, qy)
                } else if let l = last, lastCmd == "Q" || lastCmd == "T" {
                    q = Pt(2 * p.x - l.x, 2 * p.y - l.y)
                }
                let ex = ox + num()
                let ey = oy + num()
                var piece: [Pt] = []
                quad(p, q, Pt(ex, ey), into: &piece)
                addAll(piece)
                last = q
                p = Pt(ex, ey)
            case "A":
                let rx = num()
                let ry = num()
                let phi = num()
                let large = num() != 0
                let sweep = num() != 0
                let ex = ox + num()
                let ey = oy + num()
                var piece: [Pt] = []
                arc(p, rx, ry, phi, large, sweep, Pt(ex, ey), into: &piece)
                addAll(piece)
                p = Pt(ex, ey)
            default:
                i += 1
                continue
            }
            lastCmd = C
        }
        return subs.filter { $0.pts.count > 1 }
    }

    /// True when the element is drawn filled. A shape with no fill stated is treated as an outline.
    private static func isFilled(_ n: SVGNode) -> Bool {
        var fill = n.attrs["fill"]
        for part in (n.attrs["style"] ?? "").components(separatedBy: ";") {
            let kv = part.components(separatedBy: ":")
            if kv.count == 2 && kv[0].trimmingCharacters(in: .whitespacesAndNewlines) == "fill" {
                fill = kv[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard let f = fill else { return false }
        return f != "none"
    }

    /// Reads the drawing. `unit` is millimetres per drawing unit when the file states a real size, else 0.
    static func read(_ data: Data) -> (shapes: [SymbolShape], unit: Double) {
        let builder = SVGBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        guard let root = builder.root else { return ([], 0) }

        var out: [SymbolShape] = []
        let skip: Set<String> = ["defs", "metadata", "clipPath", "mask", "pattern", "symbol", "title", "style", "text", "image"]

        func walk(_ n: SVGNode, _ parent: M2, _ depth: Int) {
            if depth > 40 || out.count > 4000 || skip.contains(n.name) { return }
            let m = parent.times(transform(n.attrs["transform"]))
            var subs: [(pts: [Pt], closed: Bool)] = []
            switch n.name {
            case "path":
                subs = path(n.attrs["d"] ?? "")
            case "polyline", "polygon":
                let v = numbers(n.attrs["points"] ?? "")
                var pts: [Pt] = []
                var k = 0
                while k + 1 < v.count {
                    pts.append(Pt(v[k], v[k + 1]))
                    k += 2
                }
                if pts.count > 1 { subs = [(pts: pts, closed: n.name == "polygon")] }
            case "line":
                subs = [(pts: [Pt(lead(n.attrs["x1"]), lead(n.attrs["y1"])), Pt(lead(n.attrs["x2"]), lead(n.attrs["y2"]))], closed: false)]
            case "rect":
                let x = lead(n.attrs["x"])
                let y = lead(n.attrs["y"])
                let w = lead(n.attrs["width"])
                let h = lead(n.attrs["height"])
                if w > 0 && h > 0 { subs = [(pts: [Pt(x, y), Pt(x + w, y), Pt(x + w, y + h), Pt(x, y + h)], closed: true)] }
            case "circle", "ellipse":
                let cx = lead(n.attrs["cx"])
                let cy = lead(n.attrs["cy"])
                let rx = n.name == "circle" ? lead(n.attrs["r"]) : lead(n.attrs["rx"])
                let ry = n.name == "circle" ? rx : lead(n.attrs["ry"])
                if rx > 0 && ry > 0 {
                    var pts: [Pt] = []
                    for k in 0..<36 {
                        let a = Double(k) * Double.pi / 18
                        pts.append(Pt(cx + rx * cos(a), cy + ry * sin(a)))
                    }
                    subs = [(pts: pts, closed: true)]
                }
            default:
                break
            }
            let filled = isFilled(n)
            for s in subs {
                out.append(SymbolShape(pts: s.pts.map { m.apply($0) }, closed: s.closed, filled: filled))
            }
            for c in n.children { walk(c, m, depth + 1) }
        }
        walk(root, M2(), 0)

        // Real size: width="493mm" with a viewBox 493 wide means one unit is one millimetre.
        var unit = 0.0
        let width = (root.attrs["width"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var perUnit = 0.0
        if width.hasSuffix("mm") {
            perUnit = 1
        } else if width.hasSuffix("cm") {
            perUnit = 10
        } else if width.hasSuffix("in") {
            perUnit = 25.4
        }
        if perUnit > 0 {
            let w = lead(width)
            let box = numbers(root.attrs["viewBox"] ?? "")
            if box.count == 4 && box[2] > 0 && w > 0 {
                unit = w * perUnit / box[2]
            } else if w > 0 {
                unit = perUnit
            }
        }
        return (out, unit)
    }

    /// Turns the drawing into symbol parts in millimetres, centred on the hang point, Y up.
    /// `footprint` is the fixture's size from its GDTF dimensions, used when the drawing states no real size.
    static func prims(_ data: Data, footprint: (w: Double, h: Double)) -> (prims: [SymPrim], w: Double, h: Double)? {
        let got = read(data)
        let shapes = got.shapes
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        var count = 0
        for s in shapes {
            for p in s.pts {
                if !p.x.isFinite || !p.y.isFinite { return nil }
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
                count += 1
            }
        }
        let bw = maxX - minX
        let bh = maxY - minY
        if count < 4 || bw <= 0 || bh <= 0 { return nil }

        // Scale: the stated real size if it is believable, else fitted to the fixture's own dimensions.
        let fit = max(footprint.w, footprint.h) / max(bw, bh)
        var k = got.unit
        if k <= 0 {
            k = fit
        } else if fit > 0 {
            let ratio = k / fit
            if ratio < 0.4 || ratio > 2.5 { k = fit }
        }
        if k <= 0 || !k.isFinite { return nil }
        let cx = (minX + maxX) / 2
        let cy = (minY + maxY) / 2
        func place(_ p: Pt) -> Pt { Pt((p.x - cx) * k, -(p.y - cy) * k) }

        var prims: [SymPrim] = []
        var all: [Pt] = []
        for s in shapes {
            // Drop points closer together than half a millimetre; they only make the file bigger.
            var pts: [Pt] = []
            for raw in s.pts {
                let q = place(raw)
                if let l = pts.last, abs(l.x - q.x) < 0.5 && abs(l.y - q.y) < 0.5 { continue }
                pts.append(q)
            }
            if pts.count < 2 { continue }
            all.append(contentsOf: pts)
            let fill: RGBA? = s.filled ? RGBA.white : nil
            var prim = SymPrim.poly(pts, fill: fill)
            if !s.closed { prim.open = true }
            prims.append(prim)
        }
        if prims.isEmpty { return nil }
        // A white backing the shape of the whole symbol, so truss behind the fixture doesn't show through.
        var backing = SymPrim.poly(Outline.hull(all), fill: .white)
        backing.bare = true
        prims.insert(backing, at: 0)
        return (prims, bw * k, bh * k)
    }
}

enum Outline {
    /// The convex outline round a set of points.
    static func hull(_ input: [Pt]) -> [Pt] {
        let pts = input.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        if pts.count < 3 { return pts }
        func cross(_ o: Pt, _ a: Pt, _ b: Pt) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [Pt] = []
        for p in pts {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [Pt] = []
        for p in pts.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }
}

/// Reads the corner points of a part's 3D model, to draw its outline from above.
enum MeshReader {
    /// Points as (x, y) seen from above in the model's own units, or nil if the file can't be read.
    static func topView(archive: URL, model: String) -> [Pt]? {
        if model.isEmpty { return nil }
        if let data = try? GDTFReader.zipEntry(archive, "models/gltf/" + model + ".glb"), let pts = glb([UInt8](data)), pts.count >= 3 {
            return pts
        }
        if let data = try? GDTFReader.zipEntry(archive, "models/3ds/" + model + ".3ds") {
            let pts = tds([UInt8](data))
            if pts.count >= 3 { return pts }
        }
        return nil
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> Int {
        if o < 0 || o + 2 > b.count { return 0 }
        return Int(b[o]) | (Int(b[o + 1]) << 8)
    }

    private static func u32(_ b: [UInt8], _ o: Int) -> Int {
        if o < 0 || o + 4 > b.count { return 0 }
        return Int(b[o]) | (Int(b[o + 1]) << 8) | (Int(b[o + 2]) << 16) | (Int(b[o + 3]) << 24)
    }

    private static func f32(_ b: [UInt8], _ o: Int) -> Double {
        if o < 0 || o + 4 > b.count { return 0 }
        let bits = UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
        return Double(Float(bitPattern: bits))
    }

    private static func dbl(_ v: Any?) -> Double {
        (v as? NSNumber)?.doubleValue ?? 0
    }

    private static func int(_ v: Any?) -> Int? {
        (v as? NSNumber)?.intValue
    }

    // 3ds: a tree of chunks; 0x4110 holds a mesh's points. Z is up, as in GDTF.
    private static func tds(_ b: [UInt8]) -> [Pt] {
        var out: [Pt] = []
        func walk(_ from: Int, _ end: Int, _ depth: Int) {
            var o = from
            while o + 6 <= end && o + 6 <= b.count && depth < 12 {
                let id = u16(b, o)
                let len = u32(b, o + 2)
                if len < 6 { break }
                let stop = min(o + len, b.count)
                if id == 0x4D4D || id == 0x3D3D || id == 0x4100 {
                    walk(o + 6, stop, depth + 1)
                } else if id == 0x4000 {
                    var p = o + 6
                    while p < stop && b[p] != 0 { p += 1 }
                    walk(p + 1, stop, depth + 1)
                } else if id == 0x4110 {
                    let n = u16(b, o + 6)
                    for i in 0..<n {
                        let at = o + 8 + i * 12
                        if at + 12 > stop || out.count > 200000 { break }
                        out.append(Pt(f32(b, at), f32(b, at + 4)))
                    }
                }
                o += len
            }
        }
        walk(0, b.count, 0)
        return out
    }

    // glb: a JSON description then one block of numbers. Y is up, so GDTF's y is glTF's -z.
    private static func glb(_ b: [UInt8]) -> [Pt]? {
        if b.count < 20 || u32(b, 0) != 0x46546C67 { return nil }
        var o = 12
        var json: [String: Any]? = nil
        var binStart = 0
        var binLen = 0
        while o + 8 <= b.count {
            let len = u32(b, o)
            let type = u32(b, o + 4)
            let start = o + 8
            if len < 0 || start + len > b.count { break }
            if type == 0x4E4F534A {
                json = (try? JSONSerialization.jsonObject(with: Data(b[start..<(start + len)]))) as? [String: Any]
            } else if type == 0x004E4942 && binLen == 0 {
                binStart = start
                binLen = len
            }
            o = start + len
        }
        guard let js = json, binLen > 0 else { return nil }
        let nodes = js["nodes"] as? [[String: Any]] ?? []
        let meshes = js["meshes"] as? [[String: Any]] ?? []
        let accessors = js["accessors"] as? [[String: Any]] ?? []
        let views = js["bufferViews"] as? [[String: Any]] ?? []

        // 4x4 matrices in glTF's order (columns first).
        let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        func mul(_ a: [Double], _ c: [Double]) -> [Double] {
            var r = [Double](repeating: 0, count: 16)
            for col in 0..<4 {
                for row in 0..<4 {
                    var s = 0.0
                    for k in 0..<4 { s += a[k * 4 + row] * c[col * 4 + k] }
                    r[col * 4 + row] = s
                }
            }
            return r
        }
        func local(_ n: [String: Any]) -> [Double] {
            if let m = n["matrix"] as? [Any], m.count == 16 { return m.map { dbl($0) } }
            var t = [0.0, 0.0, 0.0]
            var q = [0.0, 0.0, 0.0, 1.0]
            var s = [1.0, 1.0, 1.0]
            if let v = n["translation"] as? [Any], v.count == 3 { t = v.map { dbl($0) } }
            if let v = n["rotation"] as? [Any], v.count == 4 { q = v.map { dbl($0) } }
            if let v = n["scale"] as? [Any], v.count == 3 { s = v.map { dbl($0) } }
            let x: Double = q[0], y: Double = q[1], z: Double = q[2], w: Double = q[3]
            var r = identity
            r[0] = (1.0 - 2.0 * (y * y + z * z)) * s[0]
            r[1] = 2.0 * (x * y + z * w) * s[0]
            r[2] = 2.0 * (x * z - y * w) * s[0]
            r[4] = 2.0 * (x * y - z * w) * s[1]
            r[5] = (1.0 - 2.0 * (x * x + z * z)) * s[1]
            r[6] = 2.0 * (y * z + x * w) * s[1]
            r[8] = 2.0 * (x * z + y * w) * s[2]
            r[9] = 2.0 * (y * z - x * w) * s[2]
            r[10] = (1.0 - 2.0 * (x * x + y * y)) * s[2]
            r[12] = t[0]
            r[13] = t[1]
            r[14] = t[2]
            return r
        }

        var out: [Pt] = []
        func addMesh(_ index: Int, _ m: [Double]) {
            if index < 0 || index >= meshes.count { return }
            for prim in meshes[index]["primitives"] as? [[String: Any]] ?? [] {
                guard let attrs = prim["attributes"] as? [String: Any], let ai = int(attrs["POSITION"]),
                      ai >= 0, ai < accessors.count else { continue }
                let acc = accessors[ai]
                guard let vi = int(acc["bufferView"]), vi >= 0, vi < views.count else { continue }
                if (int(acc["componentType"]) ?? 0) != 5126 { continue }
                let view = views[vi]
                let stride = max(int(view["byteStride"]) ?? 12, 12)
                let base = binStart + (int(view["byteOffset"]) ?? 0) + (int(acc["byteOffset"]) ?? 0)
                let n = int(acc["count"]) ?? 0
                if n <= 0 { continue }
                for i in 0..<n {
                    let at = base + i * stride
                    if at + 12 > binStart + binLen || out.count > 200000 { break }
                    let x = f32(b, at), y = f32(b, at + 4), z = f32(b, at + 8)
                    let wx = m[0] * x + m[4] * y + m[8] * z + m[12]
                    let wz = m[2] * x + m[6] * y + m[10] * z + m[14]
                    out.append(Pt(wx, -wz))
                }
            }
        }
        func visit(_ index: Int, _ parent: [Double], _ depth: Int) {
            if index < 0 || index >= nodes.count || depth > 24 { return }
            let n = nodes[index]
            let m = mul(parent, local(n))
            if let mesh = int(n["mesh"]) { addMesh(mesh, m) }
            for c in n["children"] as? [Any] ?? [] {
                if let ci = int(c) { visit(ci, m, depth + 1) }
            }
        }
        var roots: [Int] = []
        if let scenes = js["scenes"] as? [[String: Any]], !scenes.isEmpty {
            let pick = min(max(int(js["scene"]) ?? 0, 0), scenes.count - 1)
            roots = (scenes[pick]["nodes"] as? [Any] ?? []).compactMap { int($0) }
        }
        if roots.isEmpty {
            // No scene listed: every node that is nobody's child.
            var kids = Set<Int>()
            for n in nodes {
                for c in n["children"] as? [Any] ?? [] {
                    if let ci = int(c) { kids.insert(ci) }
                }
            }
            roots = (0..<nodes.count).filter { !kids.contains($0) }
        }
        for r in roots { visit(r, identity, 0) }
        return out
    }
}
