import AppKit

/// The layer list that drops down from the layer button, as AutoCAD's layer drop-down: each layer with its
/// show/hide and freeze switches, its colour, and whether things on it take the layer's colour or keep their own.
/// Clicking a layer's name makes it the current layer (new objects go on it).
final class LayerPanel: NSViewController {
    weak var owner: MainWindowController?
    private let grid = NSStackView()

    init(owner: MainWindowController) {
        self.owner = owner
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 4
        grid.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        view = grid
        rebuild()
    }

    static let colours: [(name: String, color: RGBA?)] = [
        ("No colour", nil), ("Red", RGBA(0.85, 0.1, 0.1)), ("Orange", RGBA(0.95, 0.5, 0.05)), ("Yellow", RGBA(0.85, 0.7, 0.0)),
        ("Green", RGBA(0.1, 0.6, 0.15)), ("Cyan", RGBA(0.0, 0.62, 0.75)), ("Blue", RGBA(0.1, 0.25, 0.9)),
        ("Magenta", RGBA(0.75, 0.1, 0.75)), ("Grey", RGBA(0.5, 0.5, 0.5)), ("Black", RGBA(0, 0, 0))
    ]

    private func label(_ s: String, width: CGFloat, bold: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = NSFont.systemFont(ofSize: 11, weight: bold ? .bold : .regular)
        l.textColor = bold ? LX.muted : LX.ink
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: width).isActive = true
        return l
    }

    private func edit(_ name: String, _ id: UUID, _ change: @escaping (inout Layer) -> Void) {
        owner?.doc?.edit(name) { d in
            if let i = d.layers.firstIndex(where: { $0.id == id }) { change(&d.layers[i]) }
        }
        rebuild()
    }

    func rebuild() {
        for v in grid.arrangedSubviews {
            grid.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        guard let owner = owner, let d = owner.doc?.drawing else { return }
        let current = owner.activeLayerID

        let head = NSStackView(views: [label("Layer", width: 150, bold: true), label("Show", width: 40, bold: true),
                                       label("Lock", width: 46, bold: true), label("Colour", width: 104, bold: true),
                                       label("Things on it use", width: 120, bold: true)])
        head.spacing = 8
        grid.addArrangedSubview(head)

        for layer in d.layers {
            let id = layer.id
            let mark = id == current ? "\u{2713} " : "    "
            let name = ClosureButton(title: mark + layer.name) { [weak self] _ in
                guard let self = self else { return }
                self.owner?.setActiveLayer(id)
                self.rebuild()
            }
            name.alignment = .left
            name.translatesAutoresizingMaskIntoConstraints = false
            name.widthAnchor.constraint(equalToConstant: 150).isActive = true
            name.toolTip = "Make this the current layer: new objects go on it"

            let show = ClosureButton.checkbox("", on: layer.visible) { [weak self] b in
                let on = b.state == .on
                self?.edit(on ? "Show Layer" : "Hide Layer", id) { $0.visible = on }
            }
            show.toolTip = "Show or hide this layer. A hidden layer still takes part in Select All."
            show.translatesAutoresizingMaskIntoConstraints = false
            show.widthAnchor.constraint(equalToConstant: 40).isActive = true

            let freeze = ClosureButton.checkbox("", on: layer.locked) { [weak self] b in
                let on = b.state == .on
                self?.edit(on ? "Lock Layer" : "Unlock Layer", id) { l in
                    l.locked = on
                    l.frozen = nil
                }
            }
            freeze.toolTip = "Lock: the layer stays showing (faded on screen, normal in the PDF) but nothing on it can be selected, moved or changed. You can still snap to it."
            freeze.translatesAutoresizingMaskIntoConstraints = false
            freeze.widthAnchor.constraint(equalToConstant: 46).isActive = true

            let colours = LayerPanel.colours
            let colourIndex = colours.firstIndex { $0.color == layer.color } ?? 0
            let colour = ClosurePopup(items: colours.map { $0.name }, selected: colourIndex) { [weak self] i in
                let picked = colours[i].color
                self?.edit("Layer Colour", id) { l in
                    l.color = picked
                    if picked != nil && l.colorBy == nil { l.colorBy = "layer" }
                }
            }
            colour.controlSize = .small
            colour.translatesAutoresizingMaskIntoConstraints = false
            colour.widthAnchor.constraint(equalToConstant: 104).isActive = true

            let by = ClosurePopup(items: ["Layer colour", "Their own colour"], selected: layer.colorBy == "layer" ? 0 : 1) { [weak self] i in
                self?.edit("Layer Colour", id) { $0.colorBy = i == 0 ? "layer" : nil }
            }
            by.controlSize = .small
            by.toolTip = "Layer colour: lines, truss and fixture symbols on this layer are drawn in the layer's colour. Their own colour: each keeps its own (a fixture keeps its symbol colour)."
            by.isEnabled = layer.color != nil
            by.translatesAutoresizingMaskIntoConstraints = false
            by.widthAnchor.constraint(equalToConstant: 120).isActive = true

            let row = NSStackView(views: [name, show, freeze, colour, by])
            row.spacing = 8
            grid.addArrangedSubview(row)
        }

        let rename = ClosureField(value: d.layer(current)?.name ?? "") { [weak self] s in
            let n = s.trimmingCharacters(in: .whitespaces)
            if n.isEmpty { return }
            self?.edit("Rename Layer", current) { $0.name = n }
        }
        rename.translatesAutoresizingMaskIntoConstraints = false
        rename.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let add = ClosureButton(title: "Add Layer") { [weak self] _ in
            guard let self = self, let doc = self.owner?.doc else { return }
            let layer = Layer(name: "Layer \(doc.drawing.layers.count + 1)")
            doc.edit("Add Layer") { $0.layers.append(layer) }
            self.owner?.setActiveLayer(layer.id)
            self.rebuild()
        }
        let foot = NSStackView(views: [label("Rename current:", width: 100), rename, add])
        foot.spacing = 8
        grid.addArrangedSubview(foot)
        view.needsLayout = true
        preferredContentSize = grid.fittingSize
    }
}
