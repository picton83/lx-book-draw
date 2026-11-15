import AppKit

// Live link to the Lx Book web app.
//
// Lx Book already lets a program log in with a key of its own (the X-LxBook-Key header, made in
// Lx Book under Settings > Vectorworks). With that key this app reads the show (GET api/state),
// watches for changes (GET api/health gives the show's revision number) and saves fixture rows back
// (PUT api/state with item changes, the same save the web page itself makes, so it lands in Lx Book's
// change history and can be undone there).
//
// What syncs for a linked fixture: number (fid), patch (universe/address), position and notes, both
// ways. Circuit is read from Lx Book's power patch and is not written back.

struct LxError: Error {
    var message: String
    var login = false      // the key no longer works: sign in again
    var noShow = false     // the show doesn't exist or isn't shared with this account
}

enum LxSettings {
    static var server: String {
        get { UserDefaults.standard.string(forKey: "lxbookServer") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "lxbookServer") }
    }

    static func key(for server: String) -> String? {
        Keychain.get(account: "lxbook:" + server)
    }

    static func setKey(_ key: String, for server: String) {
        Keychain.set(key, account: "lxbook:" + server)
    }

    /// "myserver.com/book/" -> "https://myserver.com/book"
    static func tidy(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.isEmpty && !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        return s
    }
}

/// The fields of a fixture that are kept the same in both apps.
struct LxFields: Equatable {
    var unit = ""
    var universe = ""
    var address = ""
    var position = ""
    var note = ""
}

final class LxBookSync {
    weak var controller: MainWindowController?
    let link: LxLink
    private(set) var status = "Connecting…"
    private let session = URLSession(configuration: .ephemeral)
    private var timer: Timer? = nil
    private var busy = false
    var rev: Any? = nil
    var show: ShowStore? = nil                            // set when the drawing lives in the show itself
    private var rows: [String: [String: Any]] = [:]       // Lx Book fixture rows by _id, as last read
    private var known: [String: LxFields] = [:]           // what both sides agreed on at the last sync
    private var ways: [String: [String]] = [:]            // power ways by fixture number
    private var pushScheduled = false
    private var locations: [LxLocation] = []

    /// Lx Book's built-in tape colours (one hex, or two for striped tape).
    static let tape: [String: [String]] = [
        "white": ["#F2F2EE"], "red": ["#D32F2F"], "blue": ["#1F5FD0"], "yellow": ["#F7D417"], "orange": ["#F28C18"],
        "green": ["#23984B"], "brown": ["#7B4B2A"], "pink": ["#F4A6C8"], "purple": ["#7A3DB8"], "black": ["#1B1B1B"],
        "grey": ["#8D939A"], "gray": ["#8D939A"], "flouro green": ["#6CFF3B"], "fluoro green": ["#6CFF3B"],
        "flouro pink": ["#FF3EA5"], "fluoro pink": ["#FF3EA5"], "flouro orange": ["#FF6B1A"], "fluoro orange": ["#FF6B1A"],
        "flouro yellow": ["#E6FF2E"], "fluoro yellow": ["#E6FF2E"], "earth": ["#23984B", "#F7D417"],
        "yellow/black hazard": ["#F7D417", "#1B1B1B"], "white/red hazard": ["#F2F2EE", "#D32F2F"],
        "green/white hazard": ["#23984B", "#F2F2EE"]
    ]

    init(link: LxLink, controller: MainWindowController) {
        self.link = link
        self.controller = controller
    }

    func start() {
        stop()
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func setStatus(_ s: String) {
        if s == status { return }
        status = s
        controller?.lxStatusChanged()
    }

    // MARK: Requests

    static func request(server: String, key: String, session: URLSession, method: String, path: String, body: [String: Any]? = nil,
                        show: String? = nil, raw: Data? = nil,
                        completion: @escaping (Result<[String: Any], LxError>) -> Void) {
        guard let url = URL(string: server + "/" + path) else {
            completion(.failure(LxError(message: "That Lx Book address isn't valid.")))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if !key.isEmpty { req.setValue(key, forHTTPHeaderField: "X-LxBook-Key") }
        if let show = show, !show.isEmpty { req.setValue(show, forHTTPHeaderField: "X-LxBook-Show") }
        req.setValue("LXBookDraw/" + AppInfo.version, forHTTPHeaderField: "User-Agent")
        if let raw = raw {
            req.httpBody = raw
            req.timeoutInterval = 120
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        } else if let body = body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        session.dataTask(with: req) { data, response, error in
            var result: Result<[String: Any], LxError>
            let json = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error = error {
                result = .failure(LxError(message: "Can't reach Lx Book (\(error.localizedDescription))"))
            } else if code == 401 && (json?["login"] as? Bool) == true {
                result = .failure(LxError(message: "Lx Book no longer accepts this Mac's sign-in. Use File > Sign In to Lx Book.", login: true))
            } else if code == 401 && key.isEmpty {
                result = .failure(LxError(message: (json?["error"] as? String) ?? "Wrong username or password."))
            } else if code == 401 {
                result = .failure(LxError(message: (json?["error"] as? String) ?? "Lx Book didn't accept the key.", login: true))
            } else if code == 404 && (json?["noShow"] as? Bool) == true {
                result = .failure(LxError(message: (json?["error"] as? String) ?? "That show isn't in Lx Book any more.", noShow: true))
            } else if code >= 400 {
                result = .failure(LxError(message: (json?["error"] as? String) ?? "Lx Book answered \(code)."))
            } else if let json = json {
                result = .success(json)
            } else {
                result = .failure(LxError(message: "That address didn't answer like Lx Book."))
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    func call(_ method: String, _ path: String, body: [String: Any]? = nil, raw: Data? = nil,
                      completion: @escaping (Result<[String: Any], LxError>) -> Void) {
        guard let key = LxSettings.key(for: link.server) else {
            completion(.failure(LxError(message: "Not signed in to Lx Book. Use File > Sign In to Lx Book.")))
            return
        }
        LxBookSync.request(server: link.server, key: key, session: session, method: method, path: path, body: body,
                           show: link.showID, raw: raw) { [weak self] result in
            if case .failure(let e) = result, let self = self {
                if e.login {
                    LxAccount.dropKey(self.link.server)
                    self.stop()
                    self.setStatus("Lx Book: signed out. Use File > Sign In to Lx Book, then open the show again.")
                } else if e.noShow {
                    self.stop()
                    self.setStatus("Lx Book: " + e.message + " Use File > Open Show from Lx Book to pick another.")
                }
            }
            completion(result)
        }
    }

    // MARK: Watching for changes

    private func tick() {
        if busy { return }
        busy = true
        call("GET", "api/health") { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e):
                self.busy = false
                self.setStatus("Lx Book: " + e.message)
            case .success(let j):
                let show = LxBookSync.text(j["show"])
                if show != self.link.showID {
                    self.busy = false
                    let name = LxBookSync.text(j["showName"])
                    self.setStatus("Lx Book has \"\(name)\" open, not \"\(self.link.showName)\". Open the linked show there, or link again.")
                    return
                }
                if self.rev != nil && LxBookSync.text(j["rev"]) == LxBookSync.text(self.rev) {
                    self.busy = false
                    // draw 1: Lx Book takes a drawing file and PDF. draw 2: the drawing lives in the show.
                    self.canStore = ((j["draw"] as? NSNumber)?.intValue ?? 0) == 1
                    self.show?.tick(j)
                    self.setStatus("Lx Book: synced with \"\(self.link.showName)\"" + (self.show?.note ?? self.storeNote))
                    self.pushIfNeeded()
                    if self.show == nil { self.storeIfNeeded() }
                    return
                }
                self.pull()
            }
        }
    }

    private func pull() {
        call("GET", "api/state") { [weak self] result in
            guard let self = self else { return }
            self.busy = false
            switch result {
            case .failure(let e):
                self.setStatus("Lx Book: " + e.message)
            case .success(let state):
                self.take(state)
                self.setStatus("Lx Book: synced with \"\(self.link.showName)\"")
                self.pushIfNeeded()
            }
        }
    }

    /// Reads a whole show state and brings the drawing's linked fixtures into line with it.
    private func take(_ state: [String: Any]) {
        rev = state["_rev"]
        var newRows: [String: [String: Any]] = [:]
        for f in (state["fixtures"] as? [[String: Any]]) ?? [] {
            let id = LxBookSync.text(f["_id"])
            if !id.isEmpty { newRows[id] = f }
        }
        var newWays: [String: [String]] = [:]
        for m in (state["multis"] as? [[String: Any]]) ?? [] {
            let name = LxBookSync.text(m["name"])
            for (i, w) in ((m["ways"] as? [[String: Any]]) ?? []).enumerated() {
                for u in (w["units"] as? [Any]) ?? [] {
                    let k = LxBookSync.keyOf(u)
                    if !k.isEmpty { newWays[k, default: []].append("\(name)-\(i + 1)") }
                }
            }
        }
        rows = newRows

        // Locations and their tape colours, for location tags
        var custom: [String: LxTape] = [:]
        for c in ((state["settings"] as? [String: Any])?["customColours"] as? [[String: Any]]) ?? [] {
            let name = LxBookSync.text(c["name"])
            let a = LxBookSync.text(c["a"])
            let b = LxBookSync.text(c["b"])
            if !name.isEmpty && !a.isEmpty { custom[name.lowercased()] = LxTape(name: name, a: a, b: b.isEmpty ? nil : b) }
        }
        var found: [LxLocation] = []
        for l in (state["locations"] as? [[String: Any]]) ?? [] {
            var tapes: [LxTape] = []
            for key in ["c1", "c2", "c3"] {
                let name = LxBookSync.text(l[key]).trimmingCharacters(in: .whitespaces)
                if name.isEmpty { continue }
                if let known = LxBookSync.tape[name.lowercased()] {
                    tapes.append(LxTape(name: name, a: known[0], b: known.count > 1 ? known[1] : nil))
                } else if let made = custom[name.lowercased()] {
                    tapes.append(made)
                } else {
                    tapes.append(LxTape(name: name, a: "#8D939A"))
                }
            }
            found.append(LxLocation(id: LxBookSync.text(l["_id"]), name: LxBookSync.text(l["name"]),
                                    short: LxBookSync.text(l["short"]), tapes: tapes))
        }
        locations = found
        ways = newWays
        applyToDrawing()
    }

    /// Fills in Lx Book's values again, after the drawing has been rebuilt from the show.
    func reapply() {
        applyToDrawing()
    }

    private func applyToDrawing() {
        guard let doc = controller?.doc else { return }
        var agreed = known
        let rows = self.rows
        let ways = self.ways
        let locations = self.locations
        doc.applyRemote { d in
            // Location tags follow Lx Book: colours always, and the name if the location is renamed there.
            d.locations = locations
            for i in d.objects.indices where d.objects[i].kind == .text && d.objects[i].tag == true {
                let name = d.objects[i].text.trimmingCharacters(in: .whitespaces).lowercased()
                if let id = d.objects[i].lxID, let l = locations.first(where: { $0.id == id }) {
                    if !l.name.isEmpty { d.objects[i].text = l.name }
                } else if let l = locations.first(where: { $0.name.lowercased() == name || (!$0.short.isEmpty && $0.short.lowercased() == name) }) {
                    d.objects[i].lxID = l.id
                }
            }
            // Fixtures not linked yet are linked by their number.
            let taken = Set(d.objects.compactMap { $0.lxID })
            var free: [String: String] = [:]
            for (id, row) in rows where !taken.contains(id) {
                let k = LxBookSync.keyOf(row["fid"])
                if !k.isEmpty { free[k] = id }
            }
            for i in d.objects.indices where d.objects[i].kind == .fixture {
                var o = d.objects[i]
                if o.lxID == nil {
                    let k = LxBookSync.keyOf(o.unit)
                    if d.fixtureType(o.typeID).category != "hoist", !k.isEmpty, let id = free[k] {
                        o.lxID = id
                        free[k] = nil
                    }
                }
                guard let id = o.lxID, let row = rows[id] else {
                    d.objects[i] = o
                    continue
                }
                let remote = LxBookSync.fields(of: row)
                if agreed[id] != nil {
                    // Already in step: Lx Book's values are the news.
                    o.unit = remote.unit; o.universe = remote.universe; o.address = remote.address
                    o.position = remote.position; o.note = remote.note
                    agreed[id] = remote
                } else {
                    // First meeting: Lx Book wins where it has a value; the drawing fills in the blanks
                    // (those blanks are then sent to Lx Book as changes).
                    if !remote.unit.isEmpty { o.unit = remote.unit }
                    if !remote.universe.isEmpty || !remote.address.isEmpty {
                        o.universe = remote.universe
                        o.address = remote.address
                    }
                    if !remote.position.isEmpty { o.position = remote.position }
                    if !remote.note.isEmpty { o.note = remote.note }
                    agreed[id] = remote
                }
                if let w = ways[LxBookSync.keyOf(row["fid"])], !w.isEmpty { o.circuit = w.joined(separator: ", ") }
                let isSpot = (row["fs"] as? Bool) ?? ((row["fs"] as? NSNumber)?.boolValue ?? false)
                o.fs = isSpot ? true : nil
                d.objects[i] = o
            }
        }
        known = agreed
    }

    // MARK: Sending changes

    // MARK: Saving the drawing into the show's Lx Book folder

    private var canStore = false              // this Lx Book takes drawings (its health answer says "draw")
    private var storeNote = ""
    private var storing = false
    private var stored: Drawing? = nil        // the drawing as last sent
    private var lastChange = Date.distantPast
    private var toldNoStore = false

    /// The name the drawing is kept under in the show's folder.
    private func storeName() -> String {
        guard let doc = controller?.doc else { return "Plot" }
        var base = doc.fileURL?.deletingPathExtension().lastPathComponent ?? ""
        if base.isEmpty { base = link.showName + " LX" }
        let bad = CharacterSet(charactersIn: "\\/:*?\"<>|")
        base = base.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? "Plot" : base
    }

    /// Sends one file to Lx Book, which puts it in the open show's own folder in its cloud storage,
    /// in place of any file there with the same name.
    private func send(_ name: String, _ data: Data, completion: @escaping (LxError?) -> Void) {
        let safe = name.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics) ?? "Plot"
        guard let key = LxSettings.key(for: link.server), let url = URL(string: link.server + "/api/draw/save?name=" + safe) else {
            completion(LxError(message: "No Lx Book key saved for this server."))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue(key, forHTTPHeaderField: "X-LxBook-Key")
        req.setValue("LXBookDraw/" + AppInfo.version, forHTTPHeaderField: "User-Agent")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        session.uploadTask(with: req, from: data) { body, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = body.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            var failure: LxError? = nil
            if let error = error {
                failure = LxError(message: "Can't reach Lx Book (\(error.localizedDescription))")
            } else if code >= 400 || code == 0 {
                failure = LxError(message: (json?["error"] as? String) ?? "Lx Book answered \(code).")
            }
            DispatchQueue.main.async { completion(failure) }
        }.resume()
    }

    /// A few seconds after the last change, the drawing and a PDF of it go to the show's folder.
    private func storeIfNeeded() {
        guard let doc = controller?.doc, !storing else { return }
        let drawing = doc.drawing
        if stored == drawing { return }
        if Date().timeIntervalSince(lastChange) < 6 { return }
        if !canStore {
            if !toldNoStore {
                toldNoStore = true
                controller?.log("This Lx Book can't keep drawings yet. Once Lx Book has its update, the drawing is saved into the show's folder by itself.")
            }
            return
        }
        guard let file = try? doc.data(ofType: lxDrawType) else { return }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("lxdraw-" + UUID().uuidString + ".pdf")
        PDFExporter.export(drawing, to: temp)
        let pdf = try? Data(contentsOf: temp)
        try? FileManager.default.removeItem(at: temp)
        let name = storeName()
        storing = true
        send(name + ".lxdraw", file) { [weak self] failed in
            guard let self = self else { return }
            if let e = failed {
                self.storing = false
                self.storeNote = " · drawing not saved to the show folder: " + e.message
                self.lastChange = Date().addingTimeInterval(54)   // try again in a minute
                return
            }
            let done: (LxError?) -> Void = { [weak self] failedPDF in
                guard let self = self else { return }
                self.storing = false
                if let e = failedPDF {
                    self.storeNote = " · PDF not saved to the show folder: " + e.message
                    self.lastChange = Date().addingTimeInterval(54)
                    return
                }
                self.stored = drawing
                let f = DateFormatter()
                f.dateFormat = "HH:mm"
                self.storeNote = " · drawing saved to the show folder " + f.string(from: Date())
            }
            if let pdf = pdf {
                self.send(name + ".pdf", pdf, completion: done)
            } else {
                done(nil)
            }
        }
    }

    /// Called whenever the drawing changes; sends linked fixtures that differ from what Lx Book has.
    func drawingChanged() {
        lastChange = Date()
        show?.lastChange = Date()
        if pushScheduled { return }
        pushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.pushScheduled = false
            self?.pushIfNeeded()
        }
    }

    /// The fixture ID is what ties a fixture on the plot to Lx Book, and Lx Book's numbering is never changed from here.
    /// Typing a new ID on a linked fixture makes it Lx Book's fixture with that ID, with all of that fixture's data;
    /// if Lx Book has no such fixture free, the plot fixture keeps the typed ID and stops being linked.
    private func relinkChangedIDs() {
        guard let doc = controller?.doc else { return }
        let changed = doc.drawing.objects.filter { o in
            guard o.kind == .fixture, let id = o.lxID, let was = known[id] else { return false }
            return LxBookSync.keyOf(o.unit) != LxBookSync.keyOf(was.unit)
        }
        if changed.isEmpty { return }
        let rows = self.rows
        let agreed = self.known
        var messages: [String] = []
        var linked: [String] = []
        var dropped: [String] = []
        doc.applyRemote { d in
            var taken = Set(d.objects.compactMap { $0.kind == .fixture ? $0.lxID : nil })
            for c in changed {
                guard let i = d.index(of: c.id), let old = d.objects[i].lxID else { continue }
                let unit = d.objects[i].unit.trimmingCharacters(in: .whitespaces)
                let key = LxBookSync.keyOf(unit)
                if key.isEmpty {
                    // A linked fixture always has an ID: put Lx Book's back.
                    d.objects[i].unit = agreed[old]?.unit ?? ""
                    messages.append("A linked fixture needs its ID, so it was put back to \(agreed[old]?.unit ?? ""). Lx Book was not changed.")
                    continue
                }
                taken.remove(old)
                dropped.append(old)
                if !key.isEmpty, let hit = rows.first(where: { LxBookSync.keyOf($0.value["fid"]) == key && !taken.contains($0.key) }) {
                    d.objects[i].lxID = hit.key
                    taken.insert(hit.key)
                    linked.append(hit.key)
                    messages.append("This fixture is now Lx Book's fixture \(unit), with its patch, position and notes. Lx Book was not changed.")
                } else {
                    d.objects[i].lxID = nil
                    messages.append("Lx Book has no free fixture \(unit), so this one is no longer linked. Lx Book was not changed.")
                }
            }
        }
        for id in dropped { known[id] = nil }
        for id in linked {
            if let row = rows[id] { known[id] = LxBookSync.fields(of: row) }
        }
        applyToDrawing()
        for m in messages { controller?.log(m) }
    }

    private func pushIfNeeded() {
        guard !busy, rev != nil, let doc = controller?.doc else { return }
        relinkChangedIDs()
        var items: [[String: Any]] = []
        var sent: [String: (row: [String: Any], fields: LxFields)] = [:]
        var details: [String] = []
        for o in doc.drawing.objects where o.kind == .fixture {
            guard let id = o.lxID, let before = rows[id], let was = known[id], sent[id] == nil else { continue }
            // The ID itself is never sent: it is the link, not data to change (see relinkChangedIDs).
            let now = LxFields(unit: was.unit, universe: o.universe, address: o.address, position: o.position, note: o.note)
            if now == was { continue }
            var after = before
            if now.universe != was.universe || now.address != was.address {
                after["patch"] = LxBookSync.patchText(now.universe, now.address, like: LxBookSync.text(before["patch"]))
            }
            if now.position != was.position { after["pos"] = now.position }
            if now.note != was.note { after["notes"] = now.note }
            items.append(["c": "fixtures", "id": id, "before": before, "after": after])
            sent[id] = (after, now)
            details.append("Fixture \(now.unit): changed in LX Book Draw")
        }
        if items.isEmpty { return }
        busy = true
        setStatus("Lx Book: saving…")
        let summary = items.count == 1 ? details[0] : "\(items.count) fixtures changed in LX Book Draw"
        var body: [String: Any] = [
            "show": link.showID,
            "items": items,
            "change": ["kind": "edit", "summary": summary, "details": Array(details.prefix(80)), "items": items,
                       "tz": TimeZone.current.identifier] as [String: Any]
        ]
        if let r = rev { body["baseRev"] = r }
        call("PUT", "api/state", body: body) { [weak self] result in
            guard let self = self else { return }
            self.busy = false
            switch result {
            case .failure(let e):
                self.setStatus("Lx Book: not saved. " + e.message)
            case .success(let j):
                for (id, s) in sent {
                    self.rows[id] = s.row
                    self.known[id] = s.fields
                }
                if let r = j["rev"] { self.rev = r }
                if let state = j["state"] as? [String: Any] {
                    // Someone else saved at the same time: Lx Book merged both and sent the result.
                    var merged = state
                    if merged["_rev"] == nil { merged["_rev"] = j["rev"] }
                    self.take(merged)
                }
                self.setStatus("Lx Book: synced with \"\(self.link.showName)\"")
            }
        }
    }

    // MARK: Reading Lx Book's values

    static func text(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber {
            let d = n.doubleValue
            return d == d.rounded() ? String(Int(d)) : n.stringValue
        }
        return ""
    }

    /// The way Lx Book compares fixture numbers: as text, trimmed, ignoring case.
    static func keyOf(_ v: Any?) -> String {
        text(v).trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func fields(of row: [String: Any]) -> LxFields {
        var f = LxFields()
        f.unit = text(row["fid"]).trimmingCharacters(in: .whitespaces)
        f.position = text(row["pos"])
        f.note = text(row["notes"])
        let patch = text(row["patch"]).trimmingCharacters(in: .whitespaces)
        let parts = patch.split(whereSeparator: { !$0.isNumber }).map { String($0) }
        let onlyPatchCharacters = patch.allSatisfy { $0.isNumber || "./:- ".contains($0) }
        if parts.count == 2, onlyPatchCharacters, let u = Int(parts[0]), let a = Int(parts[1]) {
            f.universe = String(u)
            f.address = String(a)
        } else {
            f.address = patch
        }
        return f
    }

    /// Writes a patch the way the show already writes them ("51/1" or "51.001").
    static func patchText(_ universe: String, _ address: String, like old: String) -> String {
        if universe.isEmpty || address.isEmpty { return universe + address }
        if old.contains("."), let a = Int(address) {
            return universe + "." + String(format: "%03d", a)
        }
        let separator = old.trimmingCharacters(in: .whitespaces).first(where: { !$0.isNumber }).map { String($0) } ?? "/"
        return universe + separator + address
    }
}
