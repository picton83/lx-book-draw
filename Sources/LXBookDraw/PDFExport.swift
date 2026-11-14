import AppKit

/// One A3 landscape sheet: the drawing fitted to the page, with an automatic key and a title block.
enum PDFExporter {
    static func export(_ d: Drawing, to url: URL) {
        var box = CGRect(x: 0, y: 0, width: 1190.55, height: 841.89)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

        // With sheets, each sheet is a page at its own paper size.
        // Without, one page per scene; a drawing without scenes is one page of whatever is showing.
        let scenes = d.scenes ?? []
        let sheets = d.sheets ?? []
        if !sheets.isEmpty {
            let k = Renderer.pointsPerMM
            for sheet in sheets {
                var pageBox = CGRect(x: 0, y: 0, width: CGFloat(sheet.w) * k, height: CGFloat(sheet.h) * k)
                let boxData = NSData(bytes: &pageBox, length: MemoryLayout<CGRect>.size)
                let pageInfo: [String: Any] = [kCGPDFContextMediaBox as String: boxData]
                ctx.beginPDFPage(pageInfo as CFDictionary)
                ctx.saveGState()
                ctx.scaleBy(x: k, y: k)
                drawSheet(sheet, d, in: ctx, pxPerMM: k, onScreen: false)
                ctx.restoreGState()
                ctx.endPDFPage()
            }
        } else if scenes.isEmpty {
            page(d, ctx, box)
        } else {
            for scene in scenes {
                var view = d
                view.applyScene(scene.id)
                view.info.drawingTitle = d.info.drawingTitle + " - " + scene.name
                page(view, ctx, box)
            }
        }

        NSGraphicsContext.restoreGraphicsState()
        ctx.closePDF()
    }

    /// Draws one sheet. The context is in millimetres on the paper, Y up; pxPerMM says how many device
    /// points one millimetre is, so line weights come out right on screen and in the PDF alike.
    static func drawSheet(_ sheet: Sheet, _ d: Drawing, in ctx: CGContext, pxPerMM: CGFloat, onScreen: Bool) {
        let paper = CGRect(x: 0, y: 0, width: sheet.w, height: sheet.h)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(paper)

        for v in sheet.viewports {
            let r = CGRect(x: v.x, y: v.y, width: v.w, height: v.h)
            if r.width <= 0 || r.height <= 0 || v.scale <= 0 { continue }
            let s = CGFloat(1 / v.scale)
            ctx.saveGState()
            ctx.clip(to: r.intersection(paper))
            ctx.translateBy(x: r.midX, y: r.midY)
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: CGFloat(-v.cx), y: CGFloat(-v.cy))
            Renderer.draw(v.view(of: d), in: ctx, pxPerMM: pxPerMM * s, selection: [])
            ctx.restoreGState()
            if v.frame != false {
                ctx.setStrokeColor(NSColor.black.cgColor)
                ctx.setLineWidth(0.5 / pxPerMM)
                ctx.stroke(r)
            } else if onScreen {
                // An edge that will not print still shows while editing
                ctx.setStrokeColor(NSColor(white: 0.6, alpha: 1).cgColor)
                ctx.setLineWidth(1 / pxPerMM)
                ctx.setLineDash(phase: 0, lengths: [4 / pxPerMM, 3 / pxPerMM])
                ctx.stroke(r)
                ctx.setLineDash(phase: 0, lengths: [])
            }
        }

        for o in sheet.objects {
            Renderer.drawObject(o, d, ctx, pxPerMM)
        }

        // Border, key and title block, drawn in points as on the classic page
        let k = Renderer.pointsPerMM
        ctx.saveGState()
        ctx.scaleBy(x: 1 / k, y: 1 / k)
        let m = CGFloat(Sheet.margin) * k
        let frame = CGRect(x: m, y: m, width: CGFloat(sheet.w) * k - 2 * m, height: CGFloat(sheet.h) * k - 2 * m)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(frame)
        if sheet.panel != false {
            let pw = CGFloat(Sheet.panelWidth) * k
            let panel = CGRect(x: frame.maxX - pw, y: frame.minY, width: pw, height: frame.height)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(panel)
            ctx.stroke(panel)
            // The key counts what the sheet's viewports show
            var shown = d
            if !sheet.viewports.isEmpty {
                var ids = Set<UUID>()
                for v in sheet.viewports {
                    let view = v.view(of: d)
                    for l in view.layers where l.visible { ids.insert(l.id) }
                }
                for i in shown.layers.indices { shown.layers[i].visible = ids.contains(shown.layers[i].id) }
            }
            shown.info.drawingTitle = d.info.drawingTitle.isEmpty ? sheet.name : d.info.drawingTitle + " - " + sheet.name
            var scaleText = "As shown"
            let scales = Set(sheet.viewports.map { $0.scale })
            if scales.count == 1, let one = scales.first { scaleText = "1:" + fmtNum(one.rounded()) }
            drawPanel(shown, panel, ctx, scaleText: scaleText)
        }
        ctx.restoreGState()
    }

    private static func page(_ d: Drawing, _ ctx: CGContext, _ box: CGRect) {
        ctx.beginPDFPage(nil)
        let frame = box.insetBy(dx: 20, dy: 20)
        let panelWidth: CGFloat = 215
        let panel = CGRect(x: frame.maxX - panelWidth, y: frame.minY, width: panelWidth, height: frame.height)
        let area = CGRect(x: frame.minX, y: frame.minY, width: frame.width - panelWidth, height: frame.height).insetBy(dx: 14, dy: 14)

        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(frame)
        ctx.stroke(panel)

        // Drawing, fitted
        var ext = d.extents()
        if ext.isNull || ext.width < 1 || ext.height < 1 {
            ext = CGRect(x: 0, y: 0, width: 10000, height: 7000)
        }
        let s = min(area.width / ext.width, area.height / ext.height)
        ctx.saveGState()
        ctx.clip(to: area)
        ctx.translateBy(x: area.midX, y: area.midY)
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -ext.midX, y: -ext.midY)
        Renderer.draw(d, in: ctx, pxPerMM: s, selection: [])
        ctx.restoreGState()

        drawPanel(d, panel, ctx, scaleText: "Fit to page, about 1:\(Int(Double(Renderer.pointsPerMM / s).rounded()))")
        ctx.endPDFPage()
    }

    private static func text(_ s: String, _ at: CGPoint, size: CGFloat, bold: Bool = false, color: NSColor = NSColor.black) {
        let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]).draw(at: at)
    }

    private static func textRight(_ s: String, _ right: CGPoint, size: CGFloat, bold: Bool = false) {
        let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.black])
        a.draw(at: CGPoint(x: right.x - a.size().width, y: right.y))
    }

    private static func drawPanel(_ d: Drawing, _ panel: CGRect, _ ctx: CGContext, scaleText: String) {
        let left = panel.minX + 10
        let right = panel.maxX - 10
        var y = panel.maxY - 22

        // Key: every fixture type and symbol in use, counted.
        var counts: [String: Int] = [:]
        for o in d.objects where o.kind == .fixture && d.isVisible(o) {
            counts[o.typeID, default: 0] += 1
        }
        let used = d.allFixtureTypes.filter { counts[$0.id] != nil }
        for category in ["fixture", "hoist"] {
            let group = used.filter { $0.category == category }
            if group.isEmpty { continue }
            text(category == "fixture" ? "FIXTURES" : "HOISTS", CGPoint(x: left, y: y), size: 10, bold: true)
            y -= 8
            for f in group {
                y -= 34
                let cell = CGRect(x: left, y: y, width: 34, height: 30)
                ctx.saveGState()
                ctx.translateBy(x: cell.midX, y: cell.midY)
                let k = 28 / CGFloat(max(f.width, f.depth, 1))
                ctx.scaleBy(x: k, y: k)
                Renderer.drawFixture(f, d, ctx, 0.6 / k)
                ctx.restoreGState()
                text(f.displayName.uppercased(), CGPoint(x: left + 42, y: y + 15), size: 7.5, bold: true)
                var sub = f.mode
                if f.channels > 0 { sub += sub.isEmpty ? "\(f.channels)ch" : " (\(f.channels)ch)" }
                text(sub, CGPoint(x: left + 42, y: y + 5), size: 6.5, color: NSColor.darkGray)
                textRight(String(counts[f.id] ?? 0), CGPoint(x: right, y: y + 10), size: 9, bold: true)
            }
            y -= 16
        }

        // Truss count
        var trussCounts: [String: Int] = [:]
        for o in d.objects where o.kind == .truss && d.isVisible(o) {
            trussCounts[o.typeID, default: 0] += 1
        }
        let trussUsed = Library.truss.filter { trussCounts[$0.id] != nil }
        if !trussUsed.isEmpty {
            text("TRUSS", CGPoint(x: left, y: y), size: 10, bold: true)
            y -= 4
            for t in trussUsed {
                y -= 13
                text(t.name.uppercased(), CGPoint(x: left, y: y), size: 7.5)
                textRight(String(trussCounts[t.id] ?? 0), CGPoint(x: right, y: y), size: 9, bold: true)
            }
        }

        // Title block, from the bottom up
        let rows: [(String, String)] = [
            ("SCALE", scaleText),
            ("DATE", d.info.date),
            ("DRAWN BY", d.info.drawnBy),
            ("VENUE", d.info.venue),
            ("LIGHTING DESIGNER", d.info.designer),
            ("SHOW", d.info.show)
        ]
        var by = panel.minY
        ctx.setLineWidth(0.5)

        let versionBox = CGRect(x: panel.minX, y: by, width: panel.width, height: 22)
        text(d.info.drawingTitle.uppercased(), CGPoint(x: left, y: by + 6), size: 9, bold: true)
        ctx.stroke(versionBox)
        by += 22

        let red = CGRect(x: panel.minX, y: by, width: panel.width, height: 34)
        ctx.setFillColor(RGBA.red.cg)
        ctx.fill(red)
        ctx.stroke(red)
        let v = NSAttributedString(string: d.info.version, attributes: [
            .font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.white
        ])
        v.draw(at: CGPoint(x: red.midX - v.size().width / 2, y: red.midY - v.size().height / 2))
        by += 34

        for (label, value) in rows {
            let r = CGRect(x: panel.minX, y: by, width: panel.width, height: 18)
            ctx.stroke(r)
            text(label, CGPoint(x: left, y: by + 5), size: 6, color: NSColor.darkGray)
            text(value.uppercased(), CGPoint(x: left + 78, y: by + 5), size: 7)
            by += 18
        }
        if !d.info.show.isEmpty {
            let a = NSAttributedString(string: d.info.show, attributes: [
                .font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.black
            ])
            a.draw(at: CGPoint(x: panel.midX - a.size().width / 2, y: by + 10))
        }
    }
}
