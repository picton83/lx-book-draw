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
    private var rev: Any? = nil
    private var rows: [String: [String: Any]] = [:]       // Lx Book fixture rows by _id, as last read
    private var known: [String: LxFields] = [:]           // what both sides agreed on at the last sync
    private var ways: [String: [String]] = [:]            // power ways by fixture number
    private var pushScheduled = false

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
                        completion: @escaping (Result<[String: Any], LxError>) -> Void) {
        guard let url = URL(string: server + "/" + path) else {
            completion(.failure(LxError(message: "That Lx Book address isn't valid.")))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(key, forHTTPHeaderField: "X-LxBook-Key")
        req.setValue("LX Book Draw", forHTTPHeaderField: "User-Agent")
        if let body = body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        session.dataTask(with: req) { data, response, error in
            var result: Result<[String: Any], LxError>
            let json = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error = error {
                result = .failure(LxError(message: "Can't reach Lx Book (\(error.localizedDescription))"))
            } else if code == 401 {
                result = .failure(LxError(message: "Lx Book didn't accept the key."))
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

    private func call(_ method: String, _ path: String, body: [String: Any]? = nil,
                      completion: @escaping (Result<[String: Any], LxError>) -> Void) {
        guard let key = LxSettings.key(for: link.server) else {
            completion(.failure(LxError(message: "No Lx Book key saved for this server.")))
            return
        }
        LxBookSync.request(server: link.server, key: key, session: session, method: method, path: path, body: body, completion: completion)
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
                    self.setStatus("Lx Book: synced with \"\(self.link.showName)\"")
                    self.pushIfNeeded()
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
        ways = newWays
        applyToDrawing()
    }

    private func applyToDrawing() {
        guard let doc = controller?.doc else { return }
        var agreed = known
        let rows = self.rows
        let ways = self.ways
        doc.applyRemote { d in
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
                d.objects[i] = o
            }
        }
        known = agreed
    }

    // MARK: Sending changes

    /// Called whenever the drawing changes; sends linked fixtures that differ from what Lx Book has.
    func drawingChanged() {
        if pushScheduled { return }
        pushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.pushScheduled = false
            self?.pushIfNeeded()
        }
    }

    private func pushIfNeeded() {
        guard !busy, rev != nil, let doc = controller?.doc else { return }
        var items: [[String: Any]] = []
        var sent: [String: (row: [String: Any], fields: LxFields)] = [:]
        var details: [String] = []
        for o in doc.drawing.objects where o.kind == .fixture {
            guard let id = o.lxID, let before = rows[id], let was = known[id], sent[id] == nil else { continue }
            let now = LxFields(unit: o.unit, universe: o.universe, address: o.address, position: o.position, note: o.note)
            if now == was { continue }
            var after = before
            if now.unit != was.unit {
                if before["fid"] is NSNumber, let n = Int(now.unit) { after["fid"] = n } else { after["fid"] = now.unit }
            }
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
