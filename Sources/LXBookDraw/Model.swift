import Foundation
import CoreGraphics

// All drawing coordinates are millimetres, Y up (same as DXF).

struct Pt: Codable, Equatable {
    var x: Double
    var y: Double
    init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    init(_ p: CGPoint) { self.x = Double(p.x); self.y = Double(p.y) }
    var cg: CGPoint { CGPoint(x: x, y: y) }
}

struct RGBA: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double
    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    var cg: CGColor { CGColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a)) }

    static let black = RGBA(0, 0, 0)
    static let white = RGBA(1, 1, 1)
    static let red = RGBA(0.90, 0.10, 0.10)
    static let blue = RGBA(0.15, 0.25, 0.90)
    static let yellow = RGBA(1.0, 0.92, 0.0)
    static let orange = RGBA(1.0, 0.55, 0.0)
    static let green = RGBA(0.10, 0.65, 0.20)
    static let grey = RGBA(0.55, 0.55, 0.55)
    static let pink = RGBA(1.0, 0.80, 0.82)
    static let purple = RGBA(0.75, 0.35, 0.85)

    static let presets: [(name: String, color: RGBA)] = [
        ("Black", .black), ("Red", .red), ("Blue", .blue), ("Yellow", .yellow),
        ("Orange", .orange), ("Green", .green), ("Grey", .grey), ("Pink", .pink), ("White", .white)
    ]
}

enum Kind: String, Codable {
    case line, rect, ellipse, polyline, text, truss, fixture
}

struct Layer: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var visible = true
    var locked = false
}

/// One piece of a 2D symbol, in millimetres around the symbol's insertion point.
struct SymPrim: Codable, Equatable {
    enum K: String, Codable { case circle, rect, line, text, poly }
    var k: K
    var a = 0.0
    var b = 0.0
    var c = 0.0
    var d = 0.0
    var fill: RGBA? = nil
    var s = ""
    var pts: [Pt] = []

    static func circle(_ cx: Double, _ cy: Double, _ r: Double, fill: RGBA? = nil) -> SymPrim {
        SymPrim(k: .circle, a: cx, b: cy, c: r, d: 0, fill: fill)
    }
    static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, fill: RGBA? = nil) -> SymPrim {
        SymPrim(k: .rect, a: x, b: y, c: w, d: h, fill: fill)
    }
    static func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> SymPrim {
        SymPrim(k: .line, a: x1, b: y1, c: x2, d: y2)
    }
    static func poly(_ pts: [Pt], fill: RGBA? = nil) -> SymPrim {
        SymPrim(k: .poly, fill: fill, pts: pts)
    }
}

/// A fixture type (one GDTF fixture in one DMX mode) or a built-in symbol. Stored inside the drawing
/// so a file opens the same on any machine.
struct FixtureDef: Codable, Equatable, Identifiable {
    var id: String
    var manufacturer = ""
    var name: String
    var mode = ""
    var channels = 0
    var weight = 0.0        // kg
    var watts = 0.0
    var category = "fixture"   // "fixture" or "hoist"
    var width = 400.0       // mm
    var depth = 400.0       // mm
    var prims: [SymPrim] = []
    var source = "builtin"  // "gdtf" or "builtin"
    var gdtfRID = 0
    var revision = ""

    var displayName: String {
        manufacturer.isEmpty ? name : manufacturer + " " + name
    }
}

struct DrawObject: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: Kind
    var layer: UUID

    // Placement. rect/ellipse: local box 0...w, 0...h from pos. truss: starts at pos, runs along local X.
    // fixture: centred on pos, w and h hold the symbol size. text: bottom-left at pos.
    var pos = Pt(0, 0)
    var rot = 0.0            // degrees, anticlockwise
    var w = 0.0
    var h = 0.0
    var pts: [Pt] = []       // line / polyline, absolute
    var closed = false

    // Attributes
    var stroke = RGBA.black
    var fill: RGBA? = nil
    var lineWeight = 0.25    // mm on paper

    // Text
    var text = ""
    var textSize = 250.0     // mm, drawing scale

    // Truss / fixture
    var typeID = ""
    var unit = ""
    var universe = ""
    var address = ""
    var circuit = ""
    var position = ""
    var note = ""
    var attachedTo: UUID? = nil

    // Added in 0.4.0. Optional so drawings saved by older versions still open.
    var group: UUID? = nil          // objects with the same group select and move together
    var labelDX: Double? = nil      // label moved from its usual place, mm along the drawing's X and Y
    var labelDY: Double? = nil
    var labelArrow: Bool? = nil     // leader arrow from a moved label back to its fixture
    var labelLevel: Bool? = nil     // label drawn level instead of turned with the fixture
    var lxID: String? = nil         // this fixture's row in Lx Book, once linked

    init(kind: Kind, layer: UUID) {
        self.kind = kind
        self.layer = layer
    }

    mutating func translate(dx: Double, dy: Double) {
        pos.x += dx
        pos.y += dy
        for i in pts.indices {
            pts[i].x += dx
            pts[i].y += dy
        }
    }
}

/// A scene is a saved view: a named set of layers to show (for example Flown and Floor).
struct PlotScene: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var visibleLayers: [UUID]
}

/// The Lx Book show a drawing is linked to.
struct LxLink: Codable, Equatable {
    var server: String
    var showID: String
    var showName: String
}

struct TitleInfo: Codable, Equatable {
    var show = ""
    var drawingTitle = "LX Plot"
    var designer = ""
    var venue = ""
    var drawnBy = ""
    var version = "V0.1"
    var date = ""
}

struct Drawing: Codable, Equatable {
    var formatVersion = 1
    var layers: [Layer]
    var objects: [DrawObject] = []
    var fixtureTypes: [FixtureDef] = []
    var info = TitleInfo()
    var gridSize = 100.0
    var snapGrid = true
    var showLabels = true
    var labelSize = 130.0
    var nextUnit = 1
    // Optional so drawings saved before scenes existed still open.
    var scenes: [PlotScene]? = nil
    var activeScene: UUID? = nil
    var lxBook: LxLink? = nil

    static func blank() -> Drawing {
        Drawing(layers: [
            Layer(name: "Truss"),
            Layer(name: "Lighting"),
            Layer(name: "Rigging"),
            Layer(name: "Stage & Notes")
        ])
    }

    func layer(_ id: UUID) -> Layer? { layers.first { $0.id == id } }
    func isVisible(_ o: DrawObject) -> Bool { layer(o.layer)?.visible ?? true }
    func isLocked(_ o: DrawObject) -> Bool { layer(o.layer)?.locked ?? false }
    func index(of id: UUID) -> Int? { objects.firstIndex { $0.id == id } }

    /// The given objects plus every other member of the groups they belong to.
    func withGroups(_ ids: Set<UUID>) -> Set<UUID> {
        let groups = Set(objects.filter { ids.contains($0.id) }.compactMap { $0.group })
        if groups.isEmpty { return ids }
        var out = ids
        for o in objects {
            if let g = o.group, groups.contains(g) { out.insert(o.id) }
        }
        return out
    }

    /// Shows exactly the layers a scene lists and makes it the active scene.
    mutating func applyScene(_ id: UUID) {
        guard let scene = (scenes ?? []).first(where: { $0.id == id }) else { return }
        for i in layers.indices {
            layers[i].visible = scene.visibleLayers.contains(layers[i].id)
        }
        activeScene = id
    }

    /// Everything that can be placed with the fixture tool: this drawing's GDTF types, then built-in symbols.
    var allFixtureTypes: [FixtureDef] { fixtureTypes + Library.builtIn }

    func fixtureType(_ id: String) -> FixtureDef {
        if let f = fixtureTypes.first(where: { $0.id == id }) { return f }
        if let f = Library.builtIn.first(where: { $0.id == id }) { return f }
        return Library.builtIn[0]
    }
}
