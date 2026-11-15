import AppKit
import CoreImage

/// One A3 landscape sheet: the drawing fitted to the page, with an automatic key and a title block.
enum PDFExporter {
    static func export(_ d: Drawing, to url: URL, forLxBook: Bool = false) {
        var box = CGRect(x: 0, y: 0, width: 1190.55, height: 841.89)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

        // With sheets, each sheet is a page at its own paper size.
        // Without, one page per scene; a drawing without scenes is one page of whatever is showing.
        let scenes = d.scenes ?? []
        var sheets = d.sheets ?? []
        if forLxBook {
            // Sheets marked as not for Lx Book are left out of the PDF Lx Book shows (unless that leaves none)
            let kept = sheets.filter { $0.lxBook != false }
            if !kept.isEmpty { sheets = kept }
        }
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

    /// What this plot is and what on it can be relied on, with the QR code that opens the show in Lx Book.
    /// Drawn in the key, just above the show name; `bottom` is where it starts. Returns how tall it was.
    @discardableResult
    static func drawNotice(_ d: Drawing, x: CGFloat, bottom: CGFloat, width: CGFloat, _ ctx: CGContext) -> CGFloat {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy HH:mm"
        let when = f.string(from: Date())
        let size: CGFloat = 5.6
        let plain: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black]
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: size), .foregroundColor: NSColor.black]
        let text = NSMutableAttributedString()
        if let show = d.lxBook?.showName {
            text.append(NSAttributedString(string: "This plot was generated automatically by LX Book Draw from the Lx Book show \"\(show)\" on \(when). ", attributes: plain))
            text.append(NSAttributedString(string: "Fixture numbers, DMX addresses and power (circuits) come straight from Lx Book and are correct as of that time. ", attributes: bold))
        } else {
            text.append(NSAttributedString(string: "This plot was generated automatically by LX Book Draw on \(when). ", attributes: plain))
            text.append(NSAttributedString(string: "This drawing is not linked to Lx Book, so check fixture numbers, DMX addresses and power (circuits) against the show paperwork. ", attributes: bold))
        }
        text.append(NSAttributedString(string: "The physical placement of truss and fixtures is indicative only and may not match the lighting designer's plot; where they differ, the designer's plot is correct. Not to scale unless a scale is stated. Not for rigging, weight loading or structural use: rigging points, trim heights and loads must come from the approved rigging plot.", attributes: plain))

        var textX = x
        var textW = width
        let side: CGFloat = 56
        var modules: [[Bool]]? = nil
        let link = (d.viewerLink ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !link.isEmpty, let m = qrModules(link), (m.first?.count ?? 0) > 0 {
            modules = m
            textX = x + side + 6
            textW = width - side - 6
        }
        let textH = ceil(text.boundingRect(with: NSSize(width: textW, height: 1000), options: [.usesLineFragmentOrigin]).height)
        let qrH: CGFloat = modules == nil ? 0 : side + 18
        let height = max(textH, qrH)
        if let m = modules, let n = m.first?.count {
            let box = CGRect(x: x, y: bottom + height - side, width: side, height: side)
            let cell = side / CGFloat(n)
            ctx.setFillColor(NSColor.black.cgColor)
            for (r, row) in m.enumerated() {
                for (c, dark) in row.enumerated() where dark {
                    ctx.fill(CGRect(x: box.minX + CGFloat(c) * cell, y: box.maxY - CGFloat(r + 1) * cell, width: cell + 0.05, height: cell + 0.05))
                }
            }
            let caption = NSAttributedString(string: "Scan to view this\nshow in Lx Book", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 5.5), .foregroundColor: NSColor.black
            ])
            caption.draw(in: CGRect(x: x, y: box.minY - 16, width: side + 10, height: 15))
        }
        text.draw(in: CGRect(x: textX, y: bottom, width: textW, height: height))
        return height
    }

    /// The dark and light squares of a QR code, top row first. Nil if the text can't be made into one.
    private static var qrText = ""
    private static var qrRows: [[Bool]]? = nil

    static func qrModules(_ text: String) -> [[Bool]]? {
        if text == qrText { return qrRows }
        qrText = text
        qrRows = makeQR(text)
        return qrRows
    }

    private static func makeQR(_ text: String) -> [[Bool]]? {
        guard let data = text.data(using: .utf8), let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return nil }
        let n = Int(image.extent.width.rounded())
        if n < 10 || n > 300 { return nil }
        guard let cg = CIContext().createCGImage(image, from: image.extent),
              let bitmap = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        bitmap.interpolationQuality = .none
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: n, height: n))
        bitmap.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let raw = bitmap.data else { return nil }
        let bytes = raw.bindMemory(to: UInt8.self, capacity: n * n)
        var rows: [[Bool]] = []
        for r in 0..<n {
            var row: [Bool] = []
            for c in 0..<n { row.append(bytes[r * n + c] < 128) }
            rows.append(row)
        }
        return rows
    }

    private static func page(_ d: Drawing, _ ctx: CGContext, _ box: CGRect) {
        ctx.beginPDFPage(nil)
        let frame = box.insetBy(dx: 20, dy: 20)
        let panelWidth: CGFloat = 215
        let panel = CGRect(x: frame.maxX - panelWidth, y: frame.minY, width: panelWidth, height: frame.height)
        let noticeH = CGFloat(Sheet.noticeHeight) * Renderer.pointsPerMM
        let area = CGRect(x: frame.minX, y: frame.minY, width: frame.width - panelWidth, height: frame.height - noticeH).insetBy(dx: 14, dy: 14)

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
            // The show's name, made smaller until it fits the key's width
            var nameSize: CGFloat = 16
            var a = NSAttributedString(string: d.info.show, attributes: [.font: NSFont.boldSystemFont(ofSize: nameSize), .foregroundColor: NSColor.black])
            while a.size().width > panel.width - 16 && nameSize > 7 {
                nameSize -= 1
                a = NSAttributedString(string: d.info.show, attributes: [.font: NSFont.boldSystemFont(ofSize: nameSize), .foregroundColor: NSColor.black])
            }
            a.draw(at: CGPoint(x: panel.midX - a.size().width / 2, y: by + 10))
            by += 10 + a.size().height + 6
        } else {
            by += 6
        }
        // What this plot is, and the QR code, just above the show's name
        drawNotice(d, x: panel.minX + 8, bottom: by, width: panel.width - 16, ctx)
    }
}
