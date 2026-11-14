import AppKit

// Small controls that call a closure, so panels can be built in code without outlets.

final class ClosureField: NSTextField {
    var onCommit: ((String) -> Void)? = nil
    private var initial = ""

    convenience init(value: String, onCommit: @escaping (String) -> Void) {
        self.init(string: value)
        self.initial = value
        self.onCommit = onCommit
        self.font = NSFont.systemFont(ofSize: 12)
        self.target = self
        self.action = #selector(fire(_:))
    }

    @objc private func fire(_ sender: Any?) {
        // Also fires when the field loses focus; only pass on real changes.
        if stringValue == initial { return }
        initial = stringValue
        onCommit?(stringValue)
    }
}

final class ClosurePopup: NSPopUpButton {
    var onPick: ((Int) -> Void)? = nil

    convenience init(items: [String], selected: Int, onPick: @escaping (Int) -> Void) {
        self.init(frame: NSRect.zero, pullsDown: false)
        self.font = NSFont.systemFont(ofSize: 12)
        // Add through the menu so two items with the same name both stay.
        for title in items {
            menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        }
        if selected >= 0 && selected < items.count { selectItem(at: selected) }
        self.onPick = onPick
        self.target = self
        self.action = #selector(fire(_:))
    }

    @objc private func fire(_ sender: Any?) {
        onPick?(indexOfSelectedItem)
    }
}

class ClosureButton: NSButton {
    var onClick: ((ClosureButton) -> Void)? = nil

    convenience init(title: String, onClick: @escaping (ClosureButton) -> Void) {
        self.init(frame: NSRect.zero)
        self.title = title
        self.bezelStyle = .rounded
        self.font = NSFont.systemFont(ofSize: 12)
        self.onClick = onClick
        self.target = self
        self.action = #selector(fire(_:))
    }

    static func checkbox(_ title: String, on: Bool, onClick: @escaping (ClosureButton) -> Void) -> ClosureButton {
        let b = ClosureButton(title: title, onClick: onClick)
        b.setButtonType(.switch)
        b.state = on ? .on : .off
        return b
    }

    @objc private func fire(_ sender: Any?) {
        onClick?(self)
    }
}

/// An on/off button drawn the Lx Book way: a flat pill, hazard yellow when on.
final class PillButton: ClosureButton {
    private var label: NSAttributedString {
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: state == .on ? LX.hazardInk : LX.muted
        ])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: label.size().width + 18, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        let on = state == .on
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        (on ? LX.hazard : LX.panel).setFill()
        path.fill()
        (on ? LX.hazard : LX.line).setStroke()
        path.stroke()
        let text = label
        let s = text.size()
        text.draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2))
    }
}

enum Panel {
    /// A side panel: a container with a vertical stack pinned to its top.
    static func make(line: NSRectEdge? = nil) -> (view: NSView, stack: NSStackView) {
        let view = FillView(LX.panel, line: line)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -8)
        ])
        return (view, stack)
    }

    static func clear(_ stack: NSStackView) {
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
    }

    /// Adds a view at full panel width.
    static func add(_ v: NSView, to stack: NSStackView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    static func heading(_ s: String) -> NSTextField {
        // Lx Book's section heading: a hazard-yellow marker, then small spaced capitals
        let text = NSMutableAttributedString(string: "\u{258C} ", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: LX.hazard
        ])
        text.append(NSAttributedString(string: s.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .heavy), .foregroundColor: LX.muted, .kern: 0.9
        ]))
        let l = NSTextField(labelWithAttributedString: text)
        return l
    }

    static func note(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = NSFont.systemFont(ofSize: 11)
        l.textColor = NSColor.secondaryLabelColor
        return l
    }

    static func row(_ label: String, _ control: NSView) -> NSView {
        let l = NSTextField(labelWithString: label)
        l.font = NSFont.systemFont(ofSize: 11)
        l.textColor = NSColor.secondaryLabelColor
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: 74).isActive = true
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let s = NSStackView(views: [l, control])
        s.orientation = .horizontal
        s.spacing = 6
        return s
    }
}
