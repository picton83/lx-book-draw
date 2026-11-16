import AppKit

// Signing in to Lx Book with a username and password, picking a show, and signing out (Lx Book 1.0.76).
//
// The password is sent once to api/apps/login and never kept. The key Lx Book answers with goes in the Keychain.
// The list of shows is asked for fresh (api/apps/shows, with the key) each time a show is picked; the last list is
// remembered (names and ids only) for when Lx Book can't be reached.

struct LxShow {
    var id: String
    var name: String
}

enum LxAccount {
    static var username: String {
        get { UserDefaults.standard.string(forKey: "lxbookUser") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "lxbookUser") }
    }

    static func savedShows(_ server: String) -> [LxShow] {
        let raw = UserDefaults.standard.array(forKey: "lxbookShows:" + server) as? [[String: String]] ?? []
        return raw.compactMap { r in
            guard let id = r["id"], !id.isEmpty else { return nil }
            return LxShow(id: id, name: r["name"] ?? id)
        }
    }

    private static func saveShows(_ server: String, _ shows: [LxShow]) {
        UserDefaults.standard.set(shows.map { ["id": $0.id, "name": $0.name] }, forKey: "lxbookShows:" + server)
    }

    static func signedIn(_ server: String) -> Bool {
        !server.isEmpty && LxSettings.key(for: server) != nil
    }

    static func tell(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Lx Book"
        alert.informativeText = text
        alert.runModal()
    }

    /// The sign-in sheet. Calls back with the server, the shows shared with the account, and the one open in the browser.
    static func signIn(_ done: @escaping (_ server: String, _ shows: [LxShow], _ open: String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Sign in to Lx Book"
        alert.informativeText = "Use the same username and password as on the Lx Book web page. The password is not kept on this Mac."
        let server = NSTextField(string: LxSettings.server)
        server.placeholderString = "Lx Book address, e.g. https://your-server/book"
        server.frame = NSRect(x: 0, y: 60, width: 340, height: 24)
        let user = NSTextField(string: username)
        user.placeholderString = "Username"
        user.frame = NSRect(x: 0, y: 30, width: 340, height: 24)
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        pass.placeholderString = "Password"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 86))
        box.addSubview(server)
        box.addSubview(user)
        box.addSubview(pass)
        alert.accessoryView = box
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = LxSettings.server.isEmpty ? server : (username.isEmpty ? user : pass)
        if alert.runModal() != .alertFirstButtonReturn { return }

        let address = LxSettings.tidy(server.stringValue)
        let name = user.stringValue.trimmingCharacters(in: .whitespaces)
        if address.isEmpty || name.isEmpty || pass.stringValue.isEmpty {
            tell("Enter the Lx Book address, your username and your password.")
            return
        }
        LxSettings.server = address
        username = name
        let body: [String: Any] = [
            "username": name, "password": pass.stringValue, "app": "LX Book Draw",
            "device": Host.current().localizedName ?? "Mac"
        ]
        LxBookSync.request(server: address, key: "", session: URLSession.shared, method: "POST", path: "api/apps/login", body: body) { result in
            switch result {
            case .failure(let e):
                tell(e.message)
            case .success(let j):
                guard let key = j["key"] as? String, !key.isEmpty else {
                    tell("Lx Book answered, but didn't give this Mac a key. Is Lx Book up to date?")
                    return
                }
                LxSettings.setKey(key, for: address)
                var shows: [LxShow] = []
                for s in j["shows"] as? [[String: Any]] ?? [] {
                    let id = LxBookSync.text(s["id"])
                    if !id.isEmpty { shows.append(LxShow(id: id, name: LxBookSync.text(s["name"]))) }
                }
                saveShows(address, shows)
                done(address, shows, LxBookSync.text(j["open"]))
            }
        }
    }

    /// Asks which show to work on. Returns nil for Cancel; "Sign In Again" signs in and asks again.
    static func pickShow(server: String, shows: [LxShow], open: String, title: String, then: @escaping (LxShow) -> Void) {
        if shows.isEmpty {
            tell("No shows are shared with this account in Lx Book.")
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Signed in to " + server + (username.isEmpty ? "" : " as " + username) + "."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26), pullsDown: false)
        for s in shows {
            popup.addItem(withTitle: s.id == open ? s.name + "  (open in the browser)" : s.name)
        }
        popup.selectItem(at: shows.firstIndex { $0.id == open } ?? 0)
        alert.accessoryView = popup
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Sign In Again…")
        let answer = alert.runModal()
        if answer == .alertThirdButtonReturn {
            signIn { srv, list, op in pickShow(server: srv, shows: list, open: op, title: title, then: then) }
            return
        }
        if answer != .alertFirstButtonReturn { return }
        let i = popup.indexOfSelectedItem
        if i >= 0 && i < shows.count { then(shows[i]) }
    }

    /// Asks Lx Book for the shows this account can open now (api/apps/shows), using the key: no signing in again.
    /// Calls back on the main thread with the list and the show open in the browser, or nil if Lx Book couldn't say
    /// (offline, or an Lx Book from before api/apps/shows).
    static func refreshShows(_ server: String, _ done: @escaping (_ shows: [LxShow]?, _ open: String, _ problem: LxError?) -> Void) {
        guard let key = LxSettings.key(for: server) else {
            done(nil, "", nil)
            return
        }
        LxBookSync.request(server: server, key: key, session: URLSession.shared, method: "GET", path: "api/apps/shows") { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let j):
                    var shows: [LxShow] = []
                    for s in j["shows"] as? [[String: Any]] ?? [] {
                        let id = LxBookSync.text(s["id"])
                        if !id.isEmpty { shows.append(LxShow(id: id, name: LxBookSync.text(s["name"]))) }
                    }
                    saveShows(server, shows)
                    done(shows, LxBookSync.text(j["open"]), nil)
                case .failure(let e):
                    done(nil, "", e)
                }
            }
        }
    }

    /// Signs in if needed, then asks for a show. The list comes fresh from Lx Book each time.
    static func chooseShow(title: String, then: @escaping (_ server: String, _ show: LxShow) -> Void) {
        let server = LxSettings.server
        if signedIn(server) {
            refreshShows(server) { list, open, problem in
                if let problem = problem, problem.login {
                    signIn { srv, list, op in pickShow(server: srv, shows: list, open: op, title: title) { then(srv, $0) } }
                    return
                }
                let shows = list ?? savedShows(server)
                if shows.isEmpty {
                    signIn { srv, list, op in pickShow(server: srv, shows: list, open: op, title: title) { then(srv, $0) } }
                    return
                }
                pickShow(server: server, shows: shows, open: open, title: title) { then(server, $0) }
            }
        } else {
            signIn { srv, list, op in pickShow(server: srv, shows: list, open: op, title: title) { then(srv, $0) } }
        }
    }

    /// File > Open Show from Lx Book.
    static func openShow() {
        chooseShow(title: "Open a show from Lx Book") { server, show in
            DocController.openWorkingCopy(LxLink(server: server, showID: show.id, showName: show.name))
        }
    }

    /// File > Sign Out. Anything waiting is sent first, then show windows close and the key is deleted.
    static func signOut() {
        let server = LxSettings.server
        guard signedIn(server), let key = LxSettings.key(for: server) else {
            tell("This Mac isn't signed in to Lx Book.")
            return
        }
        let docs = NSDocumentController.shared.documents.compactMap { $0 as? DrawDocument }.filter { $0.drawing.inShow == true }
        for d in docs { d.flushToLxBook() }
        DispatchQueue.main.asyncAfter(deadline: .now() + (docs.isEmpty ? 0 : 3)) {
            for d in docs { d.close() }
            LxBookSync.request(server: server, key: key, session: URLSession.shared, method: "POST", path: "api/apps/logout", body: [:]) { _ in }
            Keychain.delete(account: "lxbook:" + server)
            UserDefaults.standard.removeObject(forKey: "lxbookShows:" + server)
            tell("Signed out of Lx Book. If this Mac was offline, delete its key in Lx Book under Settings, Apps and keys.")
        }
    }

    /// Forgets a key Lx Book no longer accepts.
    static func dropKey(_ server: String) {
        Keychain.delete(account: "lxbook:" + server)
    }
}
