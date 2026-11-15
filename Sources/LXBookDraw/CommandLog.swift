import AppKit

/// One line of the command line's history, with what kind of line it is, so lines can be coloured and filtered.
struct CommandLine2Entry {
    var time: Date
    var text: String
    var kind: Kind

    enum Kind: String, CaseIterable {
        case command = "Commands you typed"
        case lxbook = "Lx Book"
        case problem = "Problems"
        case measure = "Measurements"
        case notes = "Notes"
        case info = "Everything else"

        var color: NSColor {
            switch self {
            case .command: return LX.ink
            case .lxbook: return NSColor.systemBlue
            case .problem: return NSColor.systemRed
            case .measure: return NSColor.systemGreen
            case .notes: return NSColor.systemPurple
            case .info: return NSColor.secondaryLabelColor
            }
        }

        var tag: String {
            switch self {
            case .command: return "CMD"
            case .lxbook: return "LXB"
            case .problem: return "!!!"
            case .measure: return "DIM"
            case .notes: return "NTE"
            case .info: return "   "
            }
        }
    }

    /// Sorts a line into its kind by what it says.
    static func kind(of s: String) -> Kind {
        let l = s.lowercased()
        if s.hasPrefix("Command:") || s.range(of: #"^[A-Z]{2,}  "#, options: .regularExpression) != nil { return .command }
        if l.contains("can't") || l.contains("couldn't") || l.contains("unknown command") || l.contains("failed")
            || l.contains("not saved") || l.contains("error") || l.contains("no longer") || l.contains("wasn't") { return .problem }
        if l.hasPrefix("distance =") || l.hasPrefix("scaled by") { return .measure }
        if l.hasPrefix("lx book") || l.contains("lx book:") { return .lxbook }
        if l.contains("note saved") || l.hasPrefix("notes") { return .notes }
        return .info
    }

    func styled(withTime: Bool) -> NSAttributedString {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let out = NSMutableAttributedString()
        if withTime {
            out.append(NSAttributedString(string: f.string(from: time) + "  ", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor
            ]))
        }
        out.append(NSAttributedString(string: kind.tag + "  ", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold), .foregroundColor: kind.color
        ]))
        out.append(NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: kind == .command ? .semibold : .regular),
            .foregroundColor: kind == .info ? NSColor.secondaryLabelColor : kind.color
        ]))
        return out
    }
}

/// The big command line window: everything the command line has said, with search, a filter by kind, and Export.
final class CommandLogWindow: NSWindowController, NSSearchFieldDelegate {
    private let entries: () -> [CommandLine2Entry]
    private let text = NSTextView()
    private let search = NSSearchField()
    private let filter = NSPopUpButton(frame: .zero, pullsDown: false)

    init(entries: @escaping () -> [CommandLine2Entry]) {
        self.entries = entries
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Command Line"
        w.minSize = NSSize(width: 480, height: 300)
        super.init(window: w)
        build()
        refresh()
        w.center()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func build() {
        guard let content = window?.contentView else { return }
        search.placeholderString = "Search the log"
        search.delegate = self
        filter.addItem(withTitle: "All lines")
        for k in CommandLine2Entry.Kind.allCases { filter.addItem(withTitle: k.rawValue) }
        filter.target = self
        filter.action = #selector(changed(_:))
        let export = ClosureButton(title: "Export…") { [weak self] _ in self?.exportLog() }
        let refresh = ClosureButton(title: "Refresh") { [weak self] _ in self?.refresh() }
        let bar = NSStackView(views: [search, filter, refresh, export])
        bar.spacing = 8
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        text.isEditable = false
        text.autoresizingMask = [.width]
        text.textContainerInset = NSSize(width: 6, height: 6)
        for v in [bar, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -10),
            search.widthAnchor.constraint(equalToConstant: 260),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }

    private func shown() -> [CommandLine2Entry] {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let pick = filter.indexOfSelectedItem
        let kinds = CommandLine2Entry.Kind.allCases
        return entries().filter { e in
            if pick > 0 && pick - 1 < kinds.count && e.kind != kinds[pick - 1] { return false }
            return q.isEmpty || e.text.lowercased().contains(q)
        }
    }

    func refresh() {
        let out = NSMutableAttributedString()
        for e in shown() { out.append(e.styled(withTime: true)) }
        text.textStorage?.setAttributedString(out)
        text.scrollToEndOfDocument(nil)
    }

    func controlTextDidChange(_ obj: Notification) {
        refresh()
    }

    @objc private func changed(_ sender: Any?) {
        refresh()
    }

    private func exportLog() {
        guard let window = window else { return }
        let panel = NSSavePanel()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        panel.nameFieldStringValue = "LX Book Draw command log " + f.string(from: Date()) + ".txt"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            let t = DateFormatter()
            t.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let body = self.shown().map { t.string(from: $0.time) + "  " + $0.kind.tag + "  " + $0.text }.joined(separator: "\n")
            try? body.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
