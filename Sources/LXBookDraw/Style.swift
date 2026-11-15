import AppKit

/// Lx Book's own colours (from its style sheet), light and dark, so the two apps look like one family:
/// dark "flight case" bar across the top, hazard yellow for what matters, flat panels with thin lines.
enum LX {
    static func hex(_ s: String) -> NSColor {
        let c = Tag.color(hex: s)
        return NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1)
    }

    /// A colour that changes with light and dark mode.
    static func dyn(_ light: String, _ dark: String) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(dark) : hex(light)
        }
    }

    static let bg = dyn("#E8EBEE", "#0F1216")
    static let panel = dyn("#FFFFFF", "#181C21")
    static let soft = dyn("#F3F5F7", "#20252C")
    static let ink = dyn("#15181C", "#E7EAEE")
    static let muted = dyn("#5B636D", "#9AA3AE")
    static let line = dyn("#CAD0D6", "#2E353E")
    static let caseBar = dyn("#17191C", "#090B0D")
    static let caseInk = hex("#F1F2F3")
    static let hazard = hex("#F5C400")
    static let hazardInk = hex("#1A1600")
    static let sidebar = hex("#17191C")                  // the dark menu down the left, as in Lx Book (both modes)
    static let sidebarActive = hex("#2A2E34")
    static let sidebarMuted = hex("#9AA3AE")
    static let noteFill = dyn("#FCEFB4", "#3A3416")      // the Note button: soft hazard yellow

    /// A flat button for the dark top bar.
    static func barButton(_ b: NSButton, primary: Bool = false) {
        let title = b.title
        (b as? ClosureButton)?.flat = false
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 4
        b.layer?.backgroundColor = primary ? hazard.cgColor : NSColor(white: 1, alpha: 0.09).cgColor
        b.layer?.borderWidth = primary ? 0 : 1
        b.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        b.attributedTitle = NSAttributedString(string: "  " + title + "  ", attributes: [
            .foregroundColor: primary ? hazardInk : caseInk,
            .font: NSFont.systemFont(ofSize: 12, weight: primary ? .bold : .medium)
        ])
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }
}

/// A plain coloured background, with an optional hairline along one edge.
final class FillView: NSView {
    var fill: NSColor
    var lineEdge: NSRectEdge? = nil

    init(_ fill: NSColor, line: NSRectEdge? = nil) {
        self.fill = fill
        self.lineEdge = line
        super.init(frame: NSRect.zero)
    }

    required init?(coder: NSCoder) {
        self.fill = NSColor.clear
        super.init(coder: coder)
    }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        bounds.fill()
        guard let edge = lineEdge else { return }
        LX.line.setFill()
        switch edge {
        case .minX: NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        case .maxX: NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        case .minY: NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        default: NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
    }
}
