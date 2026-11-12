import AppKit

/// Draws a Drawing into a CGContext whose units are millimetres.
/// NSGraphicsContext.current must wrap the same context (needed for text).
enum Renderer {
    static let pointsPerMM: CGFloat = 2.835

    static func draw(_ d: Drawing, in ctx: CGContext, pxPerMM: CGFloat, selection: Set<UUID>) {
        for o in d.objects where d.isVisible(o) {
            drawObject(o, d, ctx, pxPerMM)
        }
        if selection.isEmpty { return }
        for o in d.objects where selection.contains(o.id) && d.isVisible(o) {
            drawSelection(o, ctx, pxPerMM)
        }
    }

    static func lineWidth(_ o: DrawObject, _ pxPerMM: CGFloat) -> CGFloat {
        max(0.6, CGFloat(o.lineWeight) * pointsPerMM) / pxPerMM
    }

    static func drawObject(_ o: DrawObject, _ d: Drawing, _ ctx: CGContext, _ pxPerMM: CGFloat) {
        ctx.saveGState()
        let lw = lineWidth(o, pxPerMM)
        ctx.setLineWidth(lw)
        ctx.setStrokeColor(o.stroke.cg)
        ctx.setLineJoin(.round)

        switch o.kind {
        case .line, .polyline:
            if o.pts.count >= 2 {
                ctx.beginPath()
                ctx.move(to: o.pts[0].cg)
                for p in o.pts.dropFirst() { ctx.addLine(to: p.cg) }
                if o.closed { ctx.closePath() }
                if o.closed, let f = o.fill {
                    ctx.setFillColor(f.cg)
                    ctx.drawPath(using: .fillStroke)
                } else {
                    ctx.strokePath()
                }
            }
        case .rect:
            ctx.concatenate(o.transform)
            let r = CGRect(x: 0, y: 0, width: o.w, height: o.h)
            if let f = o.fill {
                ctx.setFillColor(f.cg)
                ctx.fill(r)
            }
            ctx.stroke(r)
        case .ellipse:
            ctx.concatenate(o.transform)
            let r = CGRect(x: 0, y: 0, width: o.w, height: o.h)
            if let f = o.fill {
                ctx.setFillColor(f.cg)
                ctx.fillEllipse(in: r)
            }
            ctx.strokeEllipse(in: r)
        case .text:
            ctx.concatenate(o.transform)
            o.textAttr().draw(at: CGPoint.zero)
        case .truss:
            ctx.concatenate(o.transform)
            drawTruss(o, ctx, lw)
        case .fixture:
            ctx.concatenate(o.transform)
            let f = d.fixtureType(o.typeID)
            drawPrims(f.prims, ctx, lw)
            if d.showLabels { drawLabels(o, d, ctx) }
        }
        ctx.restoreGState()
    }

    static func drawTruss(_ o: DrawObject, _ ctx: CGContext, _ lw: CGFloat) {
        let t = Library.trussType(o.typeID)
        let L = CGFloat(t.length)
        let W = CGFloat(t.width)
        let box = CGRect(x: 0, y: -W / 2, width: L, height: W)
        if let f = o.fill {
            ctx.setFillColor(f.cg.copy(alpha: 0.35) ?? f.cg)
            ctx.fill(box)
        }
        ctx.setStrokeColor(RGBA.black.cg)
        ctx.stroke(box)

        // Chords
        let inset = min(50, W * 0.12)
        ctx.setLineWidth(lw * 0.7)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 0, y: W / 2 - inset)); ctx.addLine(to: CGPoint(x: L, y: W / 2 - inset))
        ctx.move(to: CGPoint(x: 0, y: -W / 2 + inset)); ctx.addLine(to: CGPoint(x: L, y: -W / 2 + inset))

        // Bracing
        let bays = max(2, Int((L / W).rounded()))
        let step = L / CGFloat(bays)
        for i in 0..<bays {
            let x0 = CGFloat(i) * step
            let x1 = x0 + step
            if i > 0 {
                ctx.move(to: CGPoint(x: x0, y: -W / 2)); ctx.addLine(to: CGPoint(x: x0, y: W / 2))
            }
            if i % 2 == 0 {
                ctx.move(to: CGPoint(x: x0, y: -W / 2 + inset)); ctx.addLine(to: CGPoint(x: x1, y: W / 2 - inset))
            } else {
                ctx.move(to: CGPoint(x: x0, y: W / 2 - inset)); ctx.addLine(to: CGPoint(x: x1, y: -W / 2 + inset))
            }
        }
        ctx.strokePath()
    }

    static func drawPrims(_ prims: [SymPrim], _ ctx: CGContext, _ lw: CGFloat) {
        ctx.setLineWidth(lw)
        ctx.setStrokeColor(RGBA.black.cg)
        for p in prims {
            switch p.k {
            case .circle:
                let r = CGRect(x: p.a - p.c, y: p.b - p.c, width: p.c * 2, height: p.c * 2)
                if let f = p.fill {
                    ctx.setFillColor(f.cg)
                    ctx.fillEllipse(in: r)
                }
                ctx.strokeEllipse(in: r)
            case .rect:
                let r = CGRect(x: p.a, y: p.b, width: p.c, height: p.d)
                if let f = p.fill {
                    ctx.setFillColor(f.cg)
                    ctx.fill(r)
                }
                ctx.stroke(r)
            case .line:
                ctx.beginPath()
                ctx.move(to: CGPoint(x: p.a, y: p.b))
                ctx.addLine(to: CGPoint(x: p.c, y: p.d))
                ctx.strokePath()
            case .poly:
                if p.pts.count >= 2 {
                    ctx.beginPath()
                    ctx.move(to: p.pts[0].cg)
                    for q in p.pts.dropFirst() { ctx.addLine(to: q.cg) }
                    ctx.closePath()
                    if let f = p.fill {
                        ctx.setFillColor(f.cg)
                        ctx.drawPath(using: .fillStroke)
                    } else {
                        ctx.strokePath()
                    }
                }
            case .text:
                let a = NSAttributedString(string: p.s, attributes: [
                    .font: NSFont.boldSystemFont(ofSize: CGFloat(p.c)),
                    .foregroundColor: NSColor.black
                ])
                let s = a.size()
                a.draw(at: CGPoint(x: CGFloat(p.a) - s.width / 2, y: CGFloat(p.b) - s.height / 2))
            }
        }
    }

    /// Label legend: circuit (blue), universe/address (red), unit ID (black), stacked above the fixture.
    static func drawLabels(_ o: DrawObject, _ d: Drawing, _ ctx: CGContext) {
        var patch = ""
        if !o.universe.isEmpty && !o.address.isEmpty {
            patch = o.universe + "/" + o.address
        } else {
            patch = o.universe + o.address
        }
        let lines: [(String, NSColor, Bool)] = [
            (o.circuit, RGBA.blue.ns, false),
            (patch, RGBA.red.ns, true),
            (o.unit, NSColor.black, false)
        ]
        let size = CGFloat(d.labelSize)
        var y = CGFloat(o.h) / 2 + size * 0.35
        for (s, color, italic) in lines {
            if s.isEmpty { continue }
            var font = NSFont.systemFont(ofSize: size)
            if italic {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
            let sz = a.size()
            a.draw(at: CGPoint(x: -sz.width / 2, y: y))
            y += sz.height * 0.95
        }
    }

    static func drawSelection(_ o: DrawObject, _ ctx: CGContext, _ pxPerMM: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(2 / pxPerMM)
        if o.usesPoints {
            if o.pts.count >= 2 {
                ctx.beginPath()
                ctx.move(to: o.pts[0].cg)
                for p in o.pts.dropFirst() { ctx.addLine(to: p.cg) }
                if o.closed { ctx.closePath() }
                ctx.strokePath()
            }
        } else {
            ctx.concatenate(o.transform)
            let pad = 3 / pxPerMM
            ctx.stroke(o.localBox().insetBy(dx: -pad, dy: -pad))
        }
        ctx.restoreGState()
    }
}
