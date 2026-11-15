import AppKit

// The drawing kept inside the show in Lx Book.
//
// A drawing opened with File > Open Show from Lx Book has no file of its own that the user looks after. It is
// stored in the show as rows in six lists (drawmeta, drawlayers, drawscenes, drawsheets, drawtypes, drawobjects)
// and saved with the same PUT api/state the web app uses, so Lx Book merges it row by row and keeps it in the
// change history. Fixture symbols are not in the show: they are in Lx Book's symbol library.
//
// A hidden working copy on this Mac (Application Support / LX Book Draw / shows) holds the drawing and what
// Lx Book last agreed to, so work carries on with no signal and is sent when it comes back.
//
// The row layout here must stay the same as lxdraw_pdf.py (split_drawing / join_drawing) on the server.

typealias ShowRowSet = [String: [[String: Any]]]

enum ShowRows {
    static let collections = ["drawmeta", "drawlayers", "drawscenes", "drawsheets", "drawtypes", "drawobjects"]
    static let metaKeys = ["info", "labelSize", "labelParts", "labelBackground", "autoLabels", "showLabels", "gridSize",
                           "snapGrid", "viewerLink", "nextUnit", "formatVersion"]
    static let lxFields = ["unit", "universe", "address", "position", "note", "circuit"]

    /// The same text for the same content, whatever order the keys came in.
    static func canon(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func rowID(_ row: [String: Any]) -> String {
        (row["_id"] as? String) ?? ""
    }

    static func dictionary(_ d: Drawing) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(d) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func renamed(_ item: [String: Any], from: String, to: String) -> [String: Any]? {
        var row = item
        guard let id = row.removeValue(forKey: from) else { return nil }
        row[to] = id
        return row
    }

    /// The drawing as the rows Lx Book keeps. A fixture linked to Lx Book carries only where it sits.
    static func split(_ drawing: Drawing) -> ShowRowSet? {
        guard let d = dictionary(drawing) else { return nil }
        var rows: ShowRowSet = [:]
        for c in collections { rows[c] = [] }

        var meta: [String: Any] = ["_id": "meta"]
        for k in metaKeys {
            if let v = d[k] { meta[k] = v }
        }
        rows["drawmeta"] = [meta]

        for (key, name) in [("layers", "drawlayers"), ("scenes", "drawscenes"), ("sheets", "drawsheets")] {
            var list: [[String: Any]] = []
            for item in (d[key] as? [[String: Any]]) ?? [] {
                if let row = renamed(item, from: "id", to: "_id") { list.append(row) }
            }
            rows[name] = list
        }

        let styles = (d["typeStyles"] as? [String: Any]) ?? [:]
        var types: [[String: Any]] = []
        var known = Set<String>()
        for t in (d["fixtureTypes"] as? [[String: Any]]) ?? [] {
            guard let id = t["id"] as? String else { continue }
            var row = t
            row.removeValue(forKey: "prims")
            row.removeValue(forKey: "id")
            row["_id"] = id
            row["symbol"] = id
            if let st = styles[id] as? [String: Any] {
                if let c = st["color"] { row["color"] = c }
                if let e = st["easyID"] { row["easyID"] = e }
            }
            types.append(row)
            known.insert(id)
        }
        for id in styles.keys.sorted() where !known.contains(id) {
            // A colour or Easy ID on a built-in symbol (a hoist, say)
            guard let st = styles[id] as? [String: Any], st["color"] != nil || st["easyID"] != nil else { continue }
            var row: [String: Any] = ["_id": id, "builtIn": true]
            if let c = st["color"] { row["color"] = c }
            if let e = st["easyID"] { row["easyID"] = e }
            types.append(row)
        }
        rows["drawtypes"] = types

        var objects: [[String: Any]] = []
        for item in (d["objects"] as? [[String: Any]]) ?? [] {
            guard var row = renamed(item, from: "id", to: "_id") else { continue }
            if (row["kind"] as? String) == "fixture", let fx = row["lxID"] as? String, !fx.isEmpty {
                row["fx"] = fx
                row.removeValue(forKey: "lxID")
                for k in lxFields { row.removeValue(forKey: k) }
            }
            objects.append(row)
        }
        rows["drawobjects"] = objects
        return rows
    }

    /// The symbols of the drawing's fixture types, as the library keeps them.
    static func symbols(of drawing: Drawing) -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        guard let d = dictionary(drawing) else { return out }
        for t in (d["fixtureTypes"] as? [[String: Any]]) ?? [] {
            guard let id = t["id"] as? String else { continue }
            var sym: [String: Any] = ["id": id, "prims": t["prims"] ?? [Any]()]
            sym["name"] = ((t["manufacturer"] as? String ?? "") + " " + (t["name"] as? String ?? "")).trimmingCharacters(in: .whitespaces)
            sym["width"] = t["width"] ?? 400
            sym["depth"] = t["depth"] ?? 400
            out[id] = sym
        }
        return out
    }

    /// Builds the drawing from rows. Whatever the rows don't carry (the Lx Book link, a linked fixture's number
    /// and patch, the change log, which scene is showing) is kept from `old`.
    static func join(_ rows: ShowRowSet, symbols: [String: [String: Any]], keeping old: Drawing) -> Drawing? {
        guard var d = dictionary(old) else { return nil }
        if let meta = rows["drawmeta"]?.first {
            for k in metaKeys {
                if let v = meta[k], !(v is NSNull) {
                    d[k] = v
                } else if ["labelParts", "labelBackground", "autoLabels", "viewerLink"].contains(k) {
                    d.removeValue(forKey: k)
                }
            }
        }
        func list(_ name: String) -> [[String: Any]] {
            var out: [[String: Any]] = []
            for row in rows[name] ?? [] {
                if let item = renamed(row, from: "_id", to: "id") { out.append(item) }
            }
            return out
        }
        let layers = list("drawlayers")
        if !layers.isEmpty { d["layers"] = layers }
        let scenes = list("drawscenes")
        if scenes.isEmpty { d.removeValue(forKey: "scenes") } else { d["scenes"] = scenes }
        let sheets = list("drawsheets")
        if sheets.isEmpty { d.removeValue(forKey: "sheets") } else { d["sheets"] = sheets }

        var types: [[String: Any]] = []
        var styles: [String: Any] = [:]
        let white: [String: Any] = ["r": 1, "g": 1, "b": 1, "a": 1]
        for row in rows["drawtypes"] ?? [] {
            let id = rowID(row)
            if id.isEmpty { continue }
            var st: [String: Any] = [:]
            if let c = row["color"], !(c is NSNull) { st["color"] = c }
            if let e = row["easyID"], !(e is NSNull) { st["easyID"] = e }
            if !st.isEmpty { styles[id] = st }
            if (row["builtIn"] as? Bool) == true { continue }
            var t = row
            for k in ["_id", "symbol", "color", "easyID", "builtIn"] { t.removeValue(forKey: k) }
            t["id"] = id
            let defaults: [String: Any] = ["manufacturer": "", "name": id, "mode": "", "channels": 0, "weight": 0, "watts": 0,
                                           "category": "fixture", "width": 400, "depth": 400, "source": "gdtf", "gdtfRID": 0, "revision": ""]
            for (k, v) in defaults where t[k] == nil || t[k] is NSNull { t[k] = v }
            let symbolID = (row["symbol"] as? String) ?? id
            if let sym = symbols[symbolID], let prims = sym["prims"] as? [Any] {
                t["prims"] = prims
                if let w = sym["width"] as? NSNumber, w.doubleValue > 0 { t["width"] = w }
                if let h = sym["depth"] as? NSNumber, h.doubleValue > 0 { t["depth"] = h }
            } else {
                // The symbol isn't to hand: a plain box of the right size until it is
                let w = (t["width"] as? NSNumber)?.doubleValue ?? 400
                let h = (t["depth"] as? NSNumber)?.doubleValue ?? 400
                let box: [String: Any] = ["k": "rect", "a": -w / 2, "b": -h / 2, "c": w, "d": h, "s": "", "pts": [Any](), "fill": white]
                t["prims"] = [box]
            }
            types.append(t)
        }
        d["fixtureTypes"] = types
        if styles.isEmpty { d.removeValue(forKey: "typeStyles") } else { d["typeStyles"] = styles }

        var oldObjects: [String: [String: Any]] = [:]
        for o in (d["objects"] as? [[String: Any]]) ?? [] {
            if let id = o["id"] as? String { oldObjects[id] = o }
        }
        var objects: [[String: Any]] = []
        for row in rows["drawobjects"] ?? [] {
            guard var o = renamed(row, from: "_id", to: "id"), let id = o["id"] as? String else { continue }
            if let fx = o.removeValue(forKey: "fx"), !(fx is NSNull) { o["lxID"] = fx }
            let was = oldObjects[id]
            for k in lxFields where o[k] == nil || o[k] is NSNull {
                o[k] = (was?[k] as? String) ?? ""
            }
            objects.append(o)
        }
        d["objects"] = objects

        guard JSONSerialization.isValidJSONObject(d), let data = try? JSONSerialization.data(withJSONObject: d) else { return nil }
        return try? JSONDecoder().decode(Drawing.self, from: data)
    }

    /// The changes that turn `acked` into `local`, as items for PUT api/state.
    static func diff(from acked: ShowRowSet, to local: ShowRowSet) -> [[String: Any]] {
        var items: [[String: Any]] = []
        for c in collections {
            let a = acked[c] ?? []
            let l = local[c] ?? []
            var aBy: [String: [String: Any]] = [:]
            for row in a { aBy[rowID(row)] = row }
            var lIDs = Set<String>()
            for row in l { lIDs.insert(rowID(row)) }
            for row in a where !lIDs.contains(rowID(row)) {
                items.append(["c": c, "id": rowID(row), "before": row, "after": NSNull()])
            }
            for (i, row) in l.enumerated() {
                let id = rowID(row)
                if id.isEmpty { continue }
                if let before = aBy[id] {
                    if canon(before) != canon(row) { items.append(["c": c, "id": id, "before": before, "after": row]) }
                } else {
                    items.append(["c": c, "id": id, "after": row, "apos": i])
                }
            }
            let aOrder = a.map { rowID($0) }
            let lOrder = l.map { rowID($0) }
            if aOrder != lOrder && !lOrder.isEmpty {
                items.append(["c": c, "order": true, "after": lOrder])
            }
        }
        return items
    }
}

/// Fixture symbols kept on this Mac so a show can be drawn without fetching them again.
enum SymbolStore {
    private static var memory: [String: [String: Any]] = [:]

    private static func file(_ id: String) -> URL {
        let safe = id.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics) ?? "symbol"
        return ShowStore.folder("symbols").appendingPathComponent(safe + ".json")
    }

    static func get(_ id: String) -> [String: Any]? {
        if let m = memory[id] { return m }
        guard let data = try? Data(contentsOf: file(id)),
              let sym = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        memory[id] = sym
        return sym
    }

    static func put(_ id: String, _ symbol: [String: Any]) {
        memory[id] = symbol
        if JSONSerialization.isValidJSONObject(symbol), let data = try? JSONSerialization.data(withJSONObject: symbol) {
            try? data.write(to: file(id), options: .atomic)
        }
    }
}

final class ShowStore {
    weak var sync: LxBookSync?
    let showID: String
    var lastChange = Date.distantPast
    private(set) var note = ""

    private var acked: ShowRowSet = [:]
    private var hasAcked = false          // false until this drawing has been read from or sent to Lx Book once
    private var pendingImport = false     // a drawing being moved into the show: it goes up only if the show has none
    private var blocked = false
    private var drawRev: String? = nil
    private var loaded = false
    private var busy = false
    private var libraryIDs: Set<String>? = nil
    private var checked: Drawing? = nil   // the drawing as it was when it last matched Lx Book

    init(sync: LxBookSync, showID: String) {
        self.sync = sync
        self.showID = showID
        if let data = try? Data(contentsOf: ShowStore.sidecar(showID)),
           let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let a = j["acked"] as? [String: Any] {
                for c in ShowRows.collections { acked[c] = (a[c] as? [[String: Any]]) ?? [] }
                hasAcked = true
            }
            pendingImport = (j["pendingImport"] as? Bool) ?? false
        }
    }

    // MARK: Where the working copies are

    static func folder(_ name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("LX Book Draw").appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func safe(_ showID: String) -> String {
        showID.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics) ?? "show"
    }

    static func workingCopy(_ showID: String) -> URL {
        folder("shows").appendingPathComponent(safe(showID) + ".lxdraw")
    }

    static func sidecar(_ showID: String) -> URL {
        folder("shows").appendingPathComponent(safe(showID) + ".sync.json")
    }

    /// Starts a working copy afresh: nothing agreed with Lx Book yet.
    static func resetSidecar(_ showID: String, pendingImport: Bool) {
        let j: [String: Any] = ["pendingImport": pendingImport]
        if let data = try? JSONSerialization.data(withJSONObject: j) {
            try? data.write(to: sidecar(showID), options: .atomic)
        }
    }

    private func saveSidecar() {
        var j: [String: Any] = ["pendingImport": pendingImport]
        if hasAcked { j["acked"] = acked }
        if JSONSerialization.isValidJSONObject(j), let data = try? JSONSerialization.data(withJSONObject: j) {
            try? data.write(to: ShowStore.sidecar(showID), options: .atomic)
        }
    }

    private func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }

    // MARK: The loop (called every few seconds with Lx Book's health answer)

    func tick(_ health: [String: Any]) {
        if busy || blocked { return }
        let version = (health["draw"] as? NSNumber)?.intValue ?? 0
        if version < 2 {
            note = " · this Lx Book can't keep drawings yet (it needs its update). Your changes are safe on this Mac."
            return
        }
        let rev = LxBookSync.text(health["drawRev"])
        if !loaded || rev != drawRev {
            fetch(rev)
        } else {
            push()
        }
    }

    private func fetch(_ rev: String) {
        guard let sync = sync else { return }
        busy = true
        sync.call("GET", "api/draw/state") { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e):
                self.busy = false
                self.note = " · plot not read from Lx Book: " + e.message
            case .success(let j):
                var remote: ShowRowSet = [:]
                for c in ShowRows.collections { remote[c] = (j[c] as? [[String: Any]]) ?? [] }
                self.fetchSymbols(for: remote) {
                    self.merge(remote)
                    self.drawRev = rev
                    self.loaded = true
                    self.busy = false
                    self.push()
                }
            }
        }
    }

    /// The symbols a set of rows needs: this drawing's own, then the ones kept on this Mac.
    private func symbols(for rows: ShowRowSet, drawing: Drawing) -> [String: [String: Any]] {
        var out = ShowRows.symbols(of: drawing)
        for row in rows["drawtypes"] ?? [] {
            let id = (row["symbol"] as? String) ?? ShowRows.rowID(row)
            if out[id] == nil, let s = SymbolStore.get(id) { out[id] = s }
        }
        return out
    }

    private func fetchSymbols(for remote: ShowRowSet, then: @escaping () -> Void) {
        guard let sync = sync, let doc = sync.controller?.doc else {
            then()
            return
        }
        let have = symbols(for: remote, drawing: doc.drawing)
        var missing: [String] = []
        for row in remote["drawtypes"] ?? [] where (row["builtIn"] as? Bool) != true {
            let id = (row["symbol"] as? String) ?? ShowRows.rowID(row)
            if !id.isEmpty && have[id] == nil && !missing.contains(id) { missing.append(id) }
        }
        if missing.isEmpty {
            then()
            return
        }
        let ids = missing.map { $0.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics) ?? "" }.joined(separator: ",")
        sync.call("GET", "api/draw/symbols?ids=" + ids) { result in
            if case .success(let j) = result, let found = j["symbols"] as? [String: Any] {
                for (id, value) in found {
                    if let sym = value as? [String: Any] { SymbolStore.put(id, sym) }
                }
            }
            then()
        }
    }

    /// Brings what Lx Book has together with what is here. A row changed here and not yet sent stays as it is
    /// here (it is sent next, and Lx Book merges it field by field); everything else follows Lx Book.
    private func merge(_ remote: ShowRowSet) {
        guard let sync = sync, let doc = sync.controller?.doc, let local = ShowRows.split(doc.drawing) else { return }
        let remoteEmpty = (remote["drawobjects"] ?? []).isEmpty && (remote["drawlayers"] ?? []).isEmpty
        var merged: ShowRowSet = [:]

        if !hasAcked {
            if pendingImport {
                if !remoteEmpty {
                    blocked = true
                    note = " · this show already has a drawing in Lx Book, so nothing was sent. Use File > Open Show from Lx Book to work on it."
                    sync.controller?.log("This show already has a drawing in Lx Book. Nothing was sent, and nothing in Lx Book was changed.")
                    return
                }
                pendingImport = false
            }
            hasAcked = true
            acked = [:]
            if remoteEmpty {
                // Lx Book has no drawing for this show yet: the one here goes up.
                saveSidecar()
                return
            }
            merged = remote          // first time on this Mac: Lx Book's drawing is the drawing
        } else {
            for c in ShowRows.collections {
                let l = local[c] ?? []
                let r = remote[c] ?? []
                var lBy: [String: [String: Any]] = [:]
                for row in l { lBy[ShowRows.rowID(row)] = row }
                var aCanon: [String: String] = [:]
                for row in acked[c] ?? [] { aCanon[ShowRows.rowID(row)] = ShowRows.canon(row) }
                var rIDs = Set<String>()
                var out: [[String: Any]] = []
                for row in r {
                    let id = ShowRows.rowID(row)
                    rIDs.insert(id)
                    if let mine = lBy[id] {
                        out.append(ShowRows.canon(mine) == aCanon[id] ? row : mine)
                    } else if aCanon[id] == nil {
                        out.append(row)          // added in Lx Book
                    }                            // else: erased here, not sent yet
                }
                for row in l {
                    let id = ShowRows.rowID(row)
                    if !rIDs.contains(id) && aCanon[id] == nil { out.append(row) }   // added here, not sent yet
                }
                merged[c] = out
            }
        }

        let syms = symbols(for: merged, drawing: doc.drawing)
        // What Lx Book has, in this app's own wording, is what later changes are measured against.
        if let asDrawing = ShowRows.join(remote, symbols: syms, keeping: doc.drawing), let normal = ShowRows.split(asDrawing) {
            acked = normal
        } else {
            acked = remote
        }
        saveSidecar()
        guard let next = ShowRows.join(merged, symbols: syms, keeping: doc.drawing) else {
            note = " · the plot from Lx Book couldn't be read. Nothing here was changed."
            return
        }
        if let after = ShowRows.split(next), ShowRows.canon(after) == ShowRows.canon(local) { return }
        doc.applyRemote { $0 = next }
        sync.reapply()
    }

    private func push() {
        guard let sync = sync, let doc = sync.controller?.doc, loaded, hasAcked, !blocked, !busy else { return }
        if Date().timeIntervalSince(lastChange) < 1.2 { return }
        if checked == doc.drawing { return }
        let drawing = doc.drawing
        guard let local = ShowRows.split(drawing) else { return }

        // Symbols the library doesn't have yet go up before the rows that use them.
        guard let library = libraryIDs else {
            busy = true
            sync.call("GET", "api/draw/symbols/list") { [weak self] result in
                guard let self = self else { return }
                var ids = Set<String>()
                if case .success(let j) = result {
                    if let list = j["symbols"] as? [[String: Any]] {
                        for s in list { if let id = s["id"] as? String { ids.insert(id) } }
                    } else if let map = j["symbols"] as? [String: Any] {
                        ids = Set(map.keys)
                    }
                    if let list = j["ids"] as? [String] { ids.formUnion(list) }
                }
                self.libraryIDs = ids
                self.busy = false
            }
            return
        }
        let mine = ShowRows.symbols(of: drawing)
        if let id = mine.keys.sorted().first(where: { !library.contains($0) }), let sym = mine[id] {
            busy = true
            let path = "api/draw/symbols/" + (id.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics) ?? "")
            sync.call("PUT", path, body: sym) { [weak self] result in
                guard let self = self else { return }
                self.busy = false
                switch result {
                case .success:
                    self.libraryIDs?.insert(id)
                    SymbolStore.put(id, sym)
                case .failure(let e):
                    self.note = " · a symbol couldn't be saved to the library yet: " + e.message
                    self.lastChange = Date().addingTimeInterval(20)
                }
            }
            return
        }

        let items = ShowRows.diff(from: acked, to: local)
        if items.isEmpty {
            checked = drawing
            if note.contains("waiting") || note.contains("not saved") { note = " · plot saved to Lx Book " + stamp() }
            return
        }
        busy = true
        let what = drawing.history?.last?.what ?? "changed"
        let rowCount = items.filter { ($0["order"] as? Bool) != true }.count
        let summary = "Plot: " + what + (rowCount > 1 ? " (\(rowCount) items)" : "")
        var body: [String: Any] = [
            "show": sync.link.showID,
            "items": items,
            "change": ["kind": "edit", "summary": summary, "details": ["Changed in LX Book Draw"], "items": items,
                       "tz": TimeZone.current.identifier] as [String: Any]
        ]
        if let r = sync.rev { body["baseRev"] = r }
        sync.call("PUT", "api/state", body: body) { [weak self] result in
            guard let self = self else { return }
            self.busy = false
            switch result {
            case .failure(let e):
                self.note = " · plot not saved yet, \(rowCount) changes waiting: " + e.message
                self.lastChange = Date().addingTimeInterval(8)
            case .success(let j):
                self.acked = local
                self.saveSidecar()
                if let r = j["rev"] { self.sync?.rev = r }
                self.drawRev = nil           // read it back at the next check, in case Lx Book merged someone else's work in
                self.loaded = true
                self.note = " · plot saved to Lx Book " + self.stamp()
            }
        }
    }
}
