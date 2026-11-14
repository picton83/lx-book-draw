import AppKit

/// Draws a Drawing into a CGContext whose units are millimetres.
/// NSGraphicsContext.current must wrap the same context (needed for text).
enum Renderer {
    static let pointsPerMM: CGFloat = 2.835

    /// On screen the drawing sits on a dark background, AutoCAD style: black ink is shown white and
    /// white fills take the background colour. PDF output is unaffected.
    static var screen = false
    static let screenBackground = RGBA(0.059, 0.071, 0.086)   // Lx Book's dark background, #0F1216

    static func ink(_ c: RGBA) -> RGBA {
        if !screen { return c }
        let top = max(c.r, c.g, c.b)
        if top < 0.35 { return RGBA(1 - c.r, 1 - c.g, 1 - c.b, c.a) }
        let lum = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
        if lum < 0.35 { return RGBA(c.r + (1 - c.r) * 0.45, c.g + (1 - c.g) * 0.45, c.b + (1 - c.b) * 0.45, c.a) }
        return c
    }

    static func paper(_ c: RGBA) -> RGBA {
        if screen && min(c.r, c.g, c.b) > 0.92 { return screenBackground }
        return c
    }

    static func draw(_ d: Drawing, in ctx: CGContext, pxPerMM: CGFloat, selection: Set<UUID>) {
        LabelLayout.prepare(d)
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
        ctx.setStrokeColor(ink(o.stroke).cg)
        ctx.setLineJoin(.round)

        switch o.kind {
        case .line, .polyline:
            if o.pts.count >= 2 {
                ctx.beginPath()
                ctx.move(to: o.pts[0].cg)
                for p in o.pts.dropFirst() { ctx.addLine(to: p.cg) }
                if o.closed { ctx.closePath() }
                if o.closed, let f = o.fill {
                    ctx.setFillColor(paper(f).cg)
                    ctx.drawPath(using: .fillStroke)
                } else {
                    ctx.strokePath()
                }
            }
        case .rect:
            ctx.concatenate(o.transform)
            let r = CGRect(x: 0, y: 0, width: o.w, height: o.h)
            if let f = o.fill {
                ctx.setFillColor(paper(f).cg)
                ctx.fill(r)
            }
            ctx.stroke(r)
        case .ellipse:
            ctx.concatenate(o.transform)
            let r = CGRect(x: 0, y: 0, width: o.w, height: o.h)
            if let f = o.fill {
                ctx.setFillColor(paper(f).cg)
                ctx.fillEllipse(in: r)
            }
            ctx.strokeEllipse(in: r)
        case .text:
            ctx.concatenate(o.transform)
            if o.tag == true {
                Tag.draw(o, d, ctx, lw)
            } else {
                o.textAttr().draw(at: CGPoint.zero)
            }
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
        ctx.setStrokeColor(ink(.black).cg)
        ctx.stroke(box)

        // Zoomed out, a truss is its outline with single-line chords and bracing. Zoomed in, the chords and
        // braces are drawn as tubes (50 mm chords, 30 mm braces) with end frames, as they look from above.
        let pxPerMM = (ctx.ctm.a * ctx.ctm.a + ctx.ctm.b * ctx.ctm.b).squareRoot()
        let detailed = pxPerMM * 30 >= 2.5
        let chord: CGFloat = 50
        let brace: CGFloat = 30
        let inset = min(chord, W * 0.12)
        let bays = max(2, Int((L / W).rounded()))
        let step = L / CGFloat(bays)
        ctx.setLineWidth(lw * 0.7)

        func tube(_ a: CGPoint, _ b: CGPoint, _ dia: CGFloat) {
            let dx = b.x - a.x, dy = b.y - a.y
            let len = (dx * dx + dy * dy).squareRoot()
            if len < 1 { return }
            let nx = -dy / len * dia / 2, ny = dx / len * dia / 2
            let quad = [CGPoint(x: a.x + nx, y: a.y + ny), CGPoint(x: b.x + nx, y: b.y + ny),
                        CGPoint(x: b.x - nx, y: b.y - ny), CGPoint(x: a.x - nx, y: a.y - ny)]
            ctx.beginPath()
            ctx.addLines(between: quad)
            ctx.closePath()
            ctx.setFillColor(paper(.white).cg)
            ctx.drawPath(using: .fillStroke)
        }

        if detailed {
            let top = W / 2 - chord / 2, bottom = -W / 2 + chord / 2
            for i in 0..<bays {
                let x0 = CGFloat(i) * step, x1 = x0 + step
                let up = i % 2 == 0
                tube(CGPoint(x: x0, y: up ? bottom : top), CGPoint(x: x1, y: up ? top : bottom), brace)
                if i > 0 { tube(CGPoint(x: x0, y: bottom), CGPoint(x: x0, y: top), brace) }
            }
            tube(CGPoint(x: chord / 2, y: bottom), CGPoint(x: chord / 2, y: top), chord)
            tube(CGPoint(x: L - chord / 2, y: bottom), CGPoint(x: L - chord / 2, y: top), chord)
            tube(CGPoint(x: 0, y: top), CGPoint(x: L, y: top), chord)
            tube(CGPoint(x: 0, y: bottom), CGPoint(x: L, y: bottom), chord)
        } else {
            ctx.beginPath()
            ctx.move(to: CGPoint(x: 0, y: W / 2 - inset)); ctx.addLine(to: CGPoint(x: L, y: W / 2 - inset))
            ctx.move(to: CGPoint(x: 0, y: -W / 2 + inset)); ctx.addLine(to: CGPoint(x: L, y: -W / 2 + inset))
            for i in 0..<bays {
                let x0 = CGFloat(i) * step, x1 = x0 + step
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
    }

    static func drawPrims(_ prims: [SymPrim], _ ctx: CGContext, _ lw: CGFloat) {
        ctx.setLineWidth(lw)
        ctx.setStrokeColor(ink(.black).cg)
        for p in prims {
            switch p.k {
            case .circle:
                let r = CGRect(x: p.a - p.c, y: p.b - p.c, width: p.c * 2, height: p.c * 2)
                if let f = p.fill {
                    ctx.setFillColor(paper(f).cg)
                    ctx.fillEllipse(in: r)
                }
                ctx.strokeEllipse(in: r)
            case .rect:
                let r = CGRect(x: p.a, y: p.b, width: p.c, height: p.d)
                if let f = p.fill {
                    ctx.setFillColor(paper(f).cg)
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
                        ctx.setFillColor(paper(f).cg)
                        ctx.drawPath(using: .fillStroke)
                    } else {
                        ctx.strokePath()
                    }
                }
            case .text:
                let a = NSAttributedString(string: p.s, attributes: [
                    .font: NSFont.boldSystemFont(ofSize: CGFloat(p.c)),
                    .foregroundColor: ink(.black).ns
                ])
                let s = a.size()
                a.draw(at: CGPoint(x: CGFloat(p.a) - s.width / 2, y: CGFloat(p.b) - s.height / 2))
            }
        }
    }

    /// Where a fixture's label stack sits when it has not been moved: just above the symbol, in the fixture's own frame.
    static func defaultLabelAnchor(_ o: DrawObject, _ d: Drawing) -> CGPoint {
        CGPoint(x: 0, y: CGFloat(o.h) / 2 + CGFloat(d.labelSize) * 0.35).applying(o.transform)
    }

    /// Label legend: circuit (blue), universe/address (red), unit ID (black), stacked above the fixture.
    /// A label can be moved (labelDX/DY, in drawing axes), drawn level, and given a leader arrow.
    static func drawLabels(_ o: DrawObject, _ d: Drawing, _ ctx: CGContext) {
        let lines = LabelLayout.lines(o, d)
        let backed = d.labelBackground ?? true
        let size = CGFloat(d.labelSize)

        // The move is stored in drawing axes; turn it into the fixture's frame, which is what ctx is in.
        let dx = CGFloat(o.labelDX ?? 0)
        let dy = CGFloat(o.labelDY ?? 0)
        let moved = dx != 0 || dy != 0
        // Automatic placement: only for labels that haven't been moved or levelled by hand.
        let auto = LabelLayout.isManual(o) ? 0 : LabelLayout.shift(o.id)
        let a = -degToRad(o.rot)
        let anchor = CGPoint(x: dx * cos(a) - dy * sin(a),
                             y: CGFloat(o.h) / 2 + size * 0.35 + auto + dx * sin(a) + dy * cos(a))

        ctx.saveGState()
        ctx.translateBy(x: anchor.x, y: anchor.y)
        if o.labelLevel == true { ctx.rotate(by: a) }
        var y: CGFloat = 0
        for line in lines {
            if line.text.isEmpty { continue }
            let text = NSAttributedString(string: line.text, attributes: [
                .font: LabelLayout.font(line.size, italic: line.italic), .foregroundColor: ink(line.color).ns
            ])
            let sz = text.size()
            if backed {
                // A patch of paper behind the text, so it reads over truss and other lines
                ctx.setFillColor(paper(.white).cg)
                ctx.fill(CGRect(x: -sz.width / 2 - line.size * 0.08, y: y + sz.height * 0.04, width: sz.width + line.size * 0.16, height: sz.height * 0.9))
            }
            text.draw(at: CGPoint(x: -sz.width / 2, y: y))
            y += sz.height * 0.95
        }
        ctx.restoreGState()

        if auto != 0 {
            // A label the app moved gets a thin tie line back to its fixture.
            let from = auto > 0 ? CGFloat(o.h) / 2 : -CGFloat(o.h) / 2
            let block = LabelLayout.blockSize(o, d)
            let to = auto > 0 ? anchor.y - size * 0.1 : anchor.y + block.height + size * 0.1
            ctx.saveGState()
            ctx.setStrokeColor(ink(.grey).cg)
            ctx.setLineWidth(size * 0.03)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: 0, y: from))
            ctx.addLine(to: CGPoint(x: 0, y: to))
            ctx.strokePath()
            ctx.restoreGState()
        }

        if moved && o.labelArrow == true {
            // Leader from the label to the edge of the symbol, arrowhead at the fixture.
            let len = (anchor.x * anchor.x + anchor.y * anchor.y).squareRoot()
            let reach = CGFloat(min(o.w, o.h)) / 2
            if len > reach + size {
                let ux = anchor.x / len
                let uy = anchor.y / len
                let tip = CGPoint(x: ux * reach, y: uy * reach)
                let tail = CGPoint(x: anchor.x - ux * size * 0.3, y: anchor.y - uy * size * 0.3)
                let head = size * 0.7
                let spread: CGFloat = 0.42
                ctx.setStrokeColor(ink(.black).cg)
                ctx.beginPath()
                ctx.move(to: tail)
                ctx.addLine(to: tip)
                for side in [spread, -spread] {
                    let hx = ux * cos(side) - uy * sin(side)
                    let hy = ux * sin(side) + uy * cos(side)
                    ctx.move(to: tip)
                    ctx.addLine(to: CGPoint(x: tip.x + hx * head, y: tip.y + hy * head))
                }
                ctx.strokePath()
            }
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
