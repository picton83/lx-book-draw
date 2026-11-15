import AppKit

/// The rows of the Fixture Label Config dialog: one per label line, with a tick, a size and an arrow to move it up.
final class LabelConfigForm {
    static let names: [String: String] = [
        "unit": "Fixture ID", "patch": "Address (universe/address)", "circuit": "Plug up (circuit)",
        "position": "Position", "type": "Fixture type", "note": "Note", "chain": "Chain length", "load": "Load (kg)"
    ]

    var parts: [LabelPart]
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 10))
    let background: NSButton
    private var checks: [NSButton] = []
    private var sizes: [NSTextField] = []

    init(parts: [LabelPart], background: Bool) {
        self.parts = parts
        self.background = NSButton(checkboxWithTitle: "White background behind label text", target: nil, action: nil)
        self.background.state = background ? .on : .off
        rebuild()
    }

    /// Copies what is ticked and typed back into the list.
    func read() {
        for i in parts.indices where i < checks.count && i < sizes.count {
            parts[i].on = checks[i].state == .on
            if let v = parseNum(sizes[i].stringValue), v > 0 { parts[i].size = v }
        }
    }

    private func rebuild() {
        for v in view.subviews { v.removeFromSuperview() }
        checks = []
        sizes = []
        let rowHeight: CGFloat = 28
        let height = CGFloat(parts.count) * rowHeight + 34
        view.setFrameSize(NSSize(width: 360, height: height))
        for (i, part) in parts.enumerated() {
            let y = height - CGFloat(i + 1) * rowHeight
            let check = NSButton(checkboxWithTitle: LabelConfigForm.names[part.field] ?? part.field, target: nil, action: nil)
            check.state = part.on ? .on : .off
            check.frame = NSRect(x: 0, y: y, width: 210, height: 22)
            let size = NSTextField(string: fmtNum(part.size))
            size.frame = NSRect(x: 216, y: y, width: 60, height: 22)
            size.alignment = .right
            let unit = NSTextField(labelWithString: "mm")
            unit.frame = NSRect(x: 280, y: y + 2, width: 28, height: 18)
            unit.textColor = NSColor.secondaryLabelColor
            view.addSubview(check)
            view.addSubview(size)
            view.addSubview(unit)
            if i > 0 {
                let up = ClosureButton(title: "\u{25B2}") { [weak self] _ in
                    guard let self = self else { return }
                    self.read()
                    self.parts.swapAt(i, i - 1)
                    self.rebuild()
                }
                up.controlSize = .small
                up.frame = NSRect(x: 314, y: y, width: 40, height: 22)
                up.toolTip = "Move this line up"
                view.addSubview(up)
            }
            checks.append(check)
            sizes.append(size)
        }
        background.frame = NSRect(x: 0, y: 4, width: 340, height: 22)
        view.addSubview(background)
    }
}
