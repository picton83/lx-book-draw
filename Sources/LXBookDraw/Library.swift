import Foundation

// Built-in resources. Fixtures are not built in: they come from GDTF (see GDTF.swift) and are stored
// in the drawing. Truss comes from the Good Charlotte 4Wall UK plot; widths are approximate and will
// become editable in a later stage.

struct TrussType {
    var id: String
    var name: String
    var length: Double   // mm
    var width: Double    // mm
}

enum Library {
    static let truss: [TrussType] = [
        TrussType(id: "lopro-2.5", name: "Lopro Prerig 2.5m", length: 2500, width: 660),
        TrussType(id: "lopro-3", name: "Lopro Prerig 3m", length: 3000, width: 660),
        TrussType(id: "mlt3-3", name: "MLT Three 3m", length: 3000, width: 500),
        TrussType(id: "mlt3-1.2", name: "MLT Three 1.2m", length: 1200, width: 500),
        TrussType(id: "tyler-gt-8", name: "Tyler GT Prerig 8'", length: 2438, width: 762),
        TrussType(id: "tomcat-sp-3", name: "Tomcat 20.5\" Spigotted 3m", length: 3000, width: 521),
        TrussType(id: "tomcat-bo-3", name: "Tomcat 20.5\" Bolted 3m", length: 3000, width: 521),
        TrussType(id: "tomcat-bo-1", name: "Tomcat 20.5\" Bolted 1m", length: 1000, width: 521)
    ]

    /// Symbols that have no GDTF file: a stand-in fixture and the hoists.
    static let builtIn: [FixtureDef] = [
        FixtureDef(id: "generic", name: "Generic fixture", width: 400, depth: 400, prims: [
            .circle(0, 0, 200, fill: .white),
            .line(-200, 0, 200, 0), .line(0, -200, 0, 200)
        ]),
        FixtureDef(id: "hoist-1000", name: "1000kg EXE D8+ 25m", mode: "LX", category: "hoist",
                   width: 320, depth: 320, prims: [
                    .circle(0, 0, 160, fill: .white),
                    .rect(-113, 0, 113, 113, fill: .red), .rect(0, -113, 113, 113, fill: .red),
                    .line(-160, 0, 160, 0), .line(0, -160, 0, 160),
                    .circle(0, 0, 160)
                   ]),
        FixtureDef(id: "hoist-500-dd", name: "500kg EXE D8+ DD 25m", mode: "Subhung", category: "hoist",
                   width: 300, depth: 300, prims: [
                    .poly([Pt(-150, -130), Pt(150, -130), Pt(0, 150)], fill: .white),
                    .line(0, -130, 0, 150),
                    .rect(-40, -130, 80, 80, fill: .red)
                   ]),
        FixtureDef(id: "hoist-2000", name: "2000kg Lodestar", mode: "Video", category: "hoist",
                   width: 320, depth: 320, prims: [
                    .rect(-160, -160, 320, 320, fill: .white),
                    .rect(-160, 0, 160, 160, fill: .purple),
                    .rect(0, -160, 160, 160, fill: .purple),
                    .rect(-160, -160, 320, 320)
                   ])
    ]

    static func trussType(_ id: String) -> TrussType {
        truss.first { $0.id == id } ?? truss[0]
    }
}
