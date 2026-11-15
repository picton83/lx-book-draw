import Foundation
import Security

// GDTF Share (gdtf-share.com) client and GDTF file reader.
// Same API and same rules as Lx Book: the user's own GDTF Share account, the fixture list cached for a
// week, each downloaded .gdtf kept on disk.

struct GDTFError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

struct GDTFMode: Codable, Equatable {
    var name: String
    var channels: Int
}

struct GDTFEntry: Codable, Equatable {
    var rid: Int
    var fixture: String
    var manufacturer: String
    var revision: String
    var lastModified: Int
    var uploader: String
    var uuid: String
    var modes: [GDTFMode]
}

private struct GDTFListCache: Codable {
    var fetched: Double
    var list: [GDTFEntry]
}

enum Keychain {
    static let service = "LX Book Draw - GDTF Share"

    static func set(_ password: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func delete(account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

final class GDTFShare {
    static let shared = GDTFShare()

    private let api = "https://gdtf-share.com/apis/public/"
    private let session: URLSession
    private var loggedInAt: Date? = nil
    private var memoryList: [GDTFEntry]? = nil

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = true
        cfg.httpCookieAcceptPolicy = .always
        cfg.timeoutIntervalForRequest = 120
        session = URLSession(configuration: cfg)
    }

    // MARK: Account

    var username: String {
        UserDefaults.standard.string(forKey: "gdtfUser") ?? ""
    }

    var hasAccount: Bool {
        !username.isEmpty && Keychain.get(account: username) != nil
    }

    func setAccount(user: String, password: String) {
        UserDefaults.standard.set(user, forKey: "gdtfUser")
        Keychain.set(password, account: user)
        loggedInAt = nil
    }

    // MARK: Files

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LX Book Draw", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var listFile: URL { GDTFShare.supportDir.appendingPathComponent("gdtf-list.json") }

    private func fileURL(rid: Int) -> URL {
        let dir = GDTFShare.supportDir.appendingPathComponent("gdtf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(rid).gdtf")
    }

    // MARK: Requests

    private func request(_ path: String, body: Data? = nil, completion: @escaping (Result<Data, GDTFError>) -> Void) {
        guard let url = URL(string: api + path) else {
            completion(.failure(GDTFError("Bad GDTF Share address.")))
            return
        }
        var req = URLRequest(url: url)
        req.setValue("LX Book Draw", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json, */*", forHTTPHeaderField: "Accept")
        if let body = body {
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let task = session.dataTask(with: req) { data, response, error in
            var result: Result<Data, GDTFError>
            if let error = error {
                result = .failure(GDTFError("Couldn't reach GDTF Share. Check the internet connection. (\(error.localizedDescription))"))
            } else if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                result = .failure(GDTFError("GDTF Share didn't accept the username and password."))
            } else if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                result = .failure(GDTFError("GDTF Share answered \(http.statusCode)."))
            } else {
                result = .success(data ?? Data())
            }
            DispatchQueue.main.async { completion(result) }
        }
        task.resume()
    }

    private static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A small JSON answer with "result": false means GDTF Share refused (usually the session ran out).
    private static func refusal(_ data: Data) -> String? {
        if data.count > 4096 || data.first != UInt8(ascii: "{") { return nil }
        guard let j = json(data), let ok = j["result"] as? Bool, ok == false else { return nil }
        return (j["error"] as? String) ?? "it didn't give a reason"
    }

    private func login(completion: @escaping (GDTFError?) -> Void) {
        let user = username
        guard !user.isEmpty, let password = Keychain.get(account: user) else {
            completion(GDTFError("GDTF Share isn't set up yet. Add your GDTF Share username and password with the Account button."))
            return
        }
        let body = try? JSONSerialization.data(withJSONObject: ["user": user, "password": password])
        request("login.php", body: body) { result in
            switch result {
            case .failure(let e):
                completion(e)
            case .success(let data):
                guard let j = GDTFShare.json(data) else {
                    completion(GDTFError("GDTF Share sent back something unexpected when logging in."))
                    return
                }
                if (j["result"] as? Bool) == true {
                    self.loggedInAt = Date()
                    completion(nil)
                } else {
                    let msg = (j["error"] as? String) ?? "GDTF Share didn't accept that username and password (the username is case sensitive)."
                    completion(GDTFError(msg))
                }
            }
        }
    }

    /// GDTF Share keeps a session for 2 hours of inactivity, so log in again after 90 minutes.
    private func ensureLogin(force: Bool = false, completion: @escaping (GDTFError?) -> Void) {
        if !force, let at = loggedInAt, Date().timeIntervalSince(at) < 90 * 60 {
            completion(nil)
            return
        }
        login(completion: completion)
    }

    /// A logged-in GET that logs in again once if the session has run out.
    private func get(_ path: String, retry: Bool = true, completion: @escaping (Result<Data, GDTFError>) -> Void) {
        ensureLogin { err in
            if let err = err {
                completion(.failure(err))
                return
            }
            self.request(path) { result in
                switch result {
                case .failure(let e):
                    completion(.failure(e))
                case .success(let data):
                    if let why = GDTFShare.refusal(data) {
                        if retry {
                            self.loggedInAt = nil
                            self.get(path, retry: false, completion: completion)
                        } else {
                            completion(.failure(GDTFError("GDTF Share said no: \(why)")))
                        }
                        return
                    }
                    self.loggedInAt = Date()
                    completion(.success(data))
                }
            }
        }
    }

    // MARK: Fixture list

    func list(refresh: Bool = false, completion: @escaping (Result<[GDTFEntry], GDTFError>) -> Void) {
        if !refresh {
            if let m = memoryList {
                completion(.success(m))
                return
            }
            if let data = try? Data(contentsOf: listFile),
               let cached = try? JSONDecoder().decode(GDTFListCache.self, from: data),
               Date().timeIntervalSince1970 - cached.fetched < 7 * 24 * 3600 {
                memoryList = cached.list
                completion(.success(cached.list))
                return
            }
        }
        get("getList.php") { result in
            switch result {
            case .failure(let e):
                completion(.failure(e))
            case .success(let data):
                guard let j = GDTFShare.json(data), let raw = j["list"] as? [[String: Any]] else {
                    completion(.failure(GDTFError("GDTF Share's fixture list couldn't be read.")))
                    return
                }
                var keep: [GDTFEntry] = []
                for x in raw {
                    guard let rid = GDTFShare.int(x["rid"]) else { continue }
                    var modes: [GDTFMode] = []
                    if let ms = x["modes"] as? [[String: Any]] {
                        for m in ms {
                            modes.append(GDTFMode(name: GDTFShare.str(m["name"]), channels: GDTFShare.int(m["dmxfootprint"]) ?? 0))
                        }
                    }
                    keep.append(GDTFEntry(rid: rid, fixture: GDTFShare.str(x["fixture"]), manufacturer: GDTFShare.str(x["manufacturer"]),
                                          revision: GDTFShare.str(x["revision"]), lastModified: GDTFShare.int(x["lastModified"]) ?? 0,
                                          uploader: GDTFShare.str(x["uploader"]), uuid: GDTFShare.str(x["uuid"]), modes: modes))
                }
                self.memoryList = keep
                let cache = GDTFListCache(fetched: Date().timeIntervalSince1970, list: keep)
                if let out = try? JSONEncoder().encode(cache) {
                    try? out.write(to: self.listFile, options: .atomic)
                }
                completion(.success(keep))
            }
        }
    }

    private static func str(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    private static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) ?? Double(s).map { Int($0) } }
        return nil
    }

    private static func compact(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// One line per fixture: its newest revision, preferring the manufacturer's own upload.
    static func search(_ query: String, in list: [GDTFEntry], limit: Int = 60) -> [GDTFEntry] {
        let tokens = query.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map { String($0) }
        if tokens.isEmpty { return [] }
        var best: [String: (score: Int, entry: GDTFEntry)] = [:]
        for x in list {
            let man = compact(x.manufacturer)
            let fix = compact(x.fixture)
            let both = man + fix
            var all = true
            var score = 0
            for t in tokens {
                if !both.contains(t) {
                    all = false
                    break
                }
                score += t.count
                if fix.contains(t) { score += 2 * t.count }
            }
            if !all { continue }
            if fix == compact(tokens.joined()) { score += 30 }
            let key = x.uuid.isEmpty ? (man + "|" + fix) : x.uuid
            if let cur = best[key] {
                let curManuf = cur.entry.uploader.hasPrefix("Manuf")
                let newManuf = x.uploader.hasPrefix("Manuf")
                let newer = (newManuf && !curManuf) || (newManuf == curManuf && x.lastModified > cur.entry.lastModified)
                if newer { best[key] = (score, x) }
            } else {
                best[key] = (score, x)
            }
        }
        let sorted = best.values.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.entry.fixture < $1.entry.fixture
        }
        return Array(sorted.prefix(limit).map { $0.entry })
    }

    // MARK: Download

    func download(rid: Int, completion: @escaping (Result<URL, GDTFError>) -> Void) {
        let file = fileURL(rid: rid)
        if FileManager.default.fileExists(atPath: file.path) {
            completion(.success(file))
            return
        }
        get("downloadFile.php?rid=\(rid)") { result in
            switch result {
            case .failure(let e):
                completion(.failure(e))
            case .success(let data):
                // A .gdtf is a zip archive: "PK"
                if data.count < 4 || data[data.startIndex] != 0x50 || data[data.startIndex + 1] != 0x4B {
                    completion(.failure(GDTFError("GDTF Share didn't send a GDTF file for that revision.")))
                    return
                }
                do {
                    try data.write(to: file, options: .atomic)
                    completion(.success(file))
                } catch {
                    completion(.failure(GDTFError("Couldn't save the GDTF file. (\(error.localizedDescription))")))
                }
            }
        }
    }
}

// MARK: - Reading a .gdtf file

final class XNode {
    let name: String
    let attrs: [String: String]
    var children: [XNode] = []

    init(name: String, attrs: [String: String]) {
        self.name = name
        self.attrs = attrs
    }

    func child(_ n: String) -> XNode? { children.first { $0.name == n } }

    func descendants(_ n: String) -> [XNode] {
        var out: [XNode] = []
        for c in children {
            if c.name == n { out.append(c) }
            out.append(contentsOf: c.descendants(n))
        }
        return out
    }

    func num(_ key: String) -> Double {
        guard let s = attrs[key] else { return 0 }
        return Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0
    }
}

private final class XTreeBuilder: NSObject, XMLParserDelegate {
    var root: XNode? = nil
    var stack: [XNode] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let node = XNode(name: elementName, attrs: attributeDict)
        if let top = stack.last {
            top.children.append(node)
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }
}

/// What a .gdtf file says about a fixture, before a mode is chosen.
struct GDTFFile {
    var root: XNode          // the FixtureType node
    var manufacturer: String
    var name: String
    var weight: Double
    var watts: Double
    var modes: [GDTFMode]
    var archive: URL? = nil  // the .gdtf file itself, for its symbol drawing and 3D models
}

enum GDTFReader {
    /// Reads one entry out of a zip archive using the system's unzip.
    static func zipEntry(_ archive: URL, _ entry: String) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", archive.path, entry]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            throw GDTFError("Couldn't open that GDTF file.")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if data.isEmpty { throw GDTFError("That GDTF file has no \(entry) in it.") }
        return data
    }

    static func load(_ file: URL, listed: GDTFEntry? = nil) throws -> GDTFFile {
        let xml = try zipEntry(file, "description.xml")
        let builder = XTreeBuilder()
        let parser = XMLParser(data: xml)
        parser.delegate = builder
        guard parser.parse(), let top = builder.root else {
            throw GDTFError("That GDTF file's description couldn't be read.")
        }
        let found: XNode? = top.name == "FixtureType" ? top : top.descendants("FixtureType").first
        guard let ft = found else {
            throw GDTFError("That GDTF file has no fixture type in it.")
        }

        var weight = 0.0
        for w in ft.descendants("Weight") where w.num("Value") > 0 { weight = w.num("Value") }
        var watts = 0.0
        for p in ft.descendants("PowerConsumption") {
            let con = (p.attrs["Connector"] ?? "").lowercased()
            if con.contains("out") || con.contains("thru") || con.contains("through") || con.contains("link") { continue }
            watts = max(watts, p.num("Value"))
        }

        var modes: [GDTFMode] = []
        for m in ft.descendants("DMXMode") {
            let name = m.attrs["Name"] ?? ""
            var channels = listed?.modes.first(where: { $0.name == name })?.channels ?? 0
            if channels == 0 { channels = countChannels(m) }
            modes.append(GDTFMode(name: name, channels: channels))
        }

        var manufacturer = ft.attrs["Manufacturer"] ?? ""
        if manufacturer.isEmpty { manufacturer = listed?.manufacturer ?? "" }
        var name = ft.attrs["Name"] ?? ""
        if name.isEmpty { name = ft.attrs["LongName"] ?? (listed?.fixture ?? "Fixture") }
        return GDTFFile(root: ft, manufacturer: manufacturer, name: name, weight: weight, watts: watts, modes: modes, archive: file)
    }

    /// Highest DMX offset in the mode's first break. Pixel fixtures that repeat a template are
    /// under-counted here; GDTF Share's own footprint is used instead whenever it is known.
    private static func countChannels(_ mode: XNode) -> Int {
        var top = 0
        for ch in mode.descendants("DMXChannel") {
            let brk = ch.attrs["DMXBreak"] ?? "1"
            if brk != "1" && brk != "Overwrite" { continue }
            for part in (ch.attrs["Offset"] ?? "").split(separator: ",") {
                if let n = Int(part.trimmingCharacters(in: .whitespaces)), n > top { top = n }
            }
        }
        return top
    }

    // MARK: Plan symbol from the GDTF geometry

    /// 4x4 matrix, row-major, translation in the fourth column (metres).
    private static func matrix(_ s: String?) -> [Double] {
        let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        guard let s = s else { return identity }
        let cleaned = s.replacingOccurrences(of: "{", with: " ").replacingOccurrences(of: "}", with: " ")
            .replacingOccurrences(of: ",", with: " ")
        let nums = cleaned.split(separator: " ").compactMap { Double($0) }
        return nums.count == 16 ? nums : identity
    }

    private static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: 16)
        for r in 0..<4 {
            for c in 0..<4 {
                var v = 0.0
                for k in 0..<4 { v += a[r * 4 + k] * b[k * 4 + c] }
                out[r * 4 + c] = v
            }
        }
        return out
    }

    private struct Footprint {
        var prim: SymPrim
        var area: Double
    }

    /// Builds the fixture type for one DMX mode, with a top-view symbol drawn from the model sizes and
    /// positions in the GDTF geometry tree.
    static func fixtureDef(from file: GDTFFile, mode: GDTFMode, listed: GDTFEntry?) -> FixtureDef {
        let ft = file.root
        var models: [String: XNode] = [:]
        for m in ft.child("Models")?.children ?? [] {
            if let n = m.attrs["Name"] { models[n] = m }
        }
        var tops: [String: XNode] = [:]
        let topList = ft.child("Geometries")?.children ?? []
        for g in topList {
            if let n = g.attrs["Name"] { tops[n] = g }
        }
        let modeNode = ft.descendants("DMXMode").first { ($0.attrs["Name"] ?? "") == mode.name }
        let rootGeo = tops[modeNode?.attrs["Geometry"] ?? ""] ?? topList.first

        var prints: [Footprint] = []
        // The manufacturer's own plan drawing, if the file has one. Without it, each part's 3D model gives its outline.
        var drawing: Data? = nil
        if let archive = file.archive { drawing = try? zipEntry(archive, "thumbnail.svg") }
        let useMeshes = drawing == nil
        var meshes: [String: [Pt]] = [:]
        var meshTried = Set<String>()
        func mesh(_ name: String) -> [Pt]? {
            if !useMeshes || name.isEmpty { return nil }
            guard let archive = file.archive else { return nil }
            if !meshTried.contains(name) {
                meshTried.insert(name)
                if meshTried.count <= 12, let pts = MeshReader.topView(archive: archive, model: name) { meshes[name] = pts }
            }
            return meshes[name]
        }

        func addFootprint(_ g: XNode, _ m: [Double]) {
            guard let model = models[g.attrs["Model"] ?? ""] else { return }
            let length = model.num("Length") * 1000
            let width = model.num("Width") * 1000
            if length <= 1 || width <= 1 { return }
            let cx = m[3] * 1000
            let cy = m[7] * 1000
            let primitive = model.attrs["PrimitiveType"] ?? ""
            let boxy = primitive.hasPrefix("Cube")
            let round = (g.name == "Beam" && !boxy) || primitive.hasPrefix("Cylinder") || primitive.hasPrefix("Sphere")
            if round {
                let r = min(length, width) / 2
                prints.append(Footprint(prim: .circle(cx, cy, r), area: Double.pi * r * r))
                return
            }
            // Local X and Y axes as seen from above.
            let ax = Pt(m[0], m[4])
            let ay = Pt(m[1], m[5])
            if let pts = mesh(model.attrs["File"] ?? "") {
                // The 3D model's outline from above, stretched to the part's stated length and width.
                var loX = Double.greatestFiniteMagnitude, loY = Double.greatestFiniteMagnitude
                var hiX = -Double.greatestFiniteMagnitude, hiY = -Double.greatestFiniteMagnitude
                for p in pts {
                    loX = min(loX, p.x); hiX = max(hiX, p.x)
                    loY = min(loY, p.y); hiY = max(hiY, p.y)
                }
                if hiX - loX > 0 && hiY - loY > 0 {
                    let fx = length / (hiX - loX)
                    let fy = width / (hiY - loY)
                    let midX = (loX + hiX) / 2
                    let midY = (loY + hiY) / 2
                    var placed: [Pt] = []
                    for p in pts {
                        let lx = (p.x - midX) * fx
                        let ly = (p.y - midY) * fy
                        placed.append(Pt(cx + ax.x * lx + ay.x * ly, cy + ax.y * lx + ay.y * ly))
                    }
                    let outline = Outline.hull(placed)
                    if outline.count >= 3 {
                        prints.append(Footprint(prim: .poly(outline), area: length * width))
                        return
                    }
                }
            }
            let hx = length / 2
            let hy = width / 2
            let corners = [
                Pt(cx - ax.x * hx - ay.x * hy, cy - ax.y * hx - ay.y * hy),
                Pt(cx + ax.x * hx - ay.x * hy, cy + ax.y * hx - ay.y * hy),
                Pt(cx + ax.x * hx + ay.x * hy, cy + ax.y * hx + ay.y * hy),
                Pt(cx - ax.x * hx + ay.x * hy, cy - ax.y * hx + ay.y * hy)
            ]
            prints.append(Footprint(prim: .poly(corners), area: length * width))
        }

        func visit(_ g: XNode, _ parent: [Double], _ depth: Int) {
            if depth > 12 || prints.count > 80 { return }
            if g.name == "Break" { return }
            let m = multiply(parent, matrix(g.attrs["Position"]))
            if g.name == "GeometryReference" {
                if let target = tops[g.attrs["Geometry"] ?? ""] {
                    // The referenced geometry is drawn at the reference's own position.
                    addFootprint(target, m)
                    for c in target.children { visit(c, m, depth + 1) }
                }
                return
            }
            addFootprint(g, m)
            for c in g.children { visit(c, m, depth + 1) }
        }

        if let g = rootGeo {
            let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
            visit(g, identity, 0)
        }

        // Biggest outline first, filled white so truss behind it is hidden; the rest drawn on top.
        prints.sort { $0.area > $1.area }
        var prims: [SymPrim] = []
        for (i, f) in prints.enumerated() {
            var p = f.prim
            if i == 0 { p.fill = .white }
            prims.append(p)
        }

        // Size: symmetric about the hang point so the fixture stays centred on it.
        var maxX = 0.0
        var maxY = 0.0
        for p in prims {
            if p.k == .circle {
                maxX = max(maxX, abs(p.a) + p.c)
                maxY = max(maxY, abs(p.b) + p.c)
            } else {
                for q in p.pts {
                    maxX = max(maxX, abs(q.x))
                    maxY = max(maxY, abs(q.y))
                }
            }
        }
        if prims.isEmpty {
            prims = [.circle(0, 0, 200, fill: .white), .line(-200, 0, 200, 0), .line(0, -200, 0, 200)]
            maxX = 200
            maxY = 200
        }

        let key = (listed?.uuid.isEmpty == false ? listed!.uuid : file.manufacturer + "|" + file.name)
        var def = FixtureDef(id: "gdtf:" + key + ":" + mode.name, name: file.name)
        def.manufacturer = file.manufacturer
        def.mode = mode.name
        def.channels = mode.channels
        def.weight = file.weight
        def.watts = file.watts
        def.width = max(maxX * 2, 50)
        def.depth = max(maxY * 2, 50)
        def.prims = prims
        if let data = drawing, let symbol = SVGSymbol.prims(data, footprint: (w: maxX * 2, h: maxY * 2)) {
            def.prims = symbol.prims
            def.width = max(symbol.w, 50)
            def.depth = max(symbol.h, 50)
        }
        def.source = "gdtf"
        def.gdtfRID = listed?.rid ?? 0
        def.revision = listed?.revision ?? ""
        return def
    }
}
