import AppKit

/// The drawings opened lately, kept by the app itself so the list survives updates. Shows kept in Lx Book are listed
/// by show name; they open from their working copy and sync again.
enum Recents {
    private static let key = "recentDrawings"

    static var list: [(path: String, name: String)] {
        seedIfEmpty()
        let raw = UserDefaults.standard.array(forKey: key) as? [[String: String]] ?? []
        return raw.compactMap { r in
            guard let p = r["path"], FileManager.default.fileExists(atPath: p) else { return nil }
            return (p, r["name"] ?? (p as NSString).lastPathComponent)
        }
    }

    /// The first time (or after the list was lost): start it from the system's recent list and the last show opened.
    private static func seedIfEmpty() {
        if UserDefaults.standard.array(forKey: key) != nil { return }
        var raw: [[String: String]] = []
        if let last = UserDefaults.standard.string(forKey: "lastShowID"), !last.isEmpty {
            let url = ShowStore.workingCopy(last)
            if FileManager.default.fileExists(atPath: url.path) {
                raw.append(["path": url.path, "name": showName(url) ?? "Lx Book show"])
            }
        }
        for url in NSDocumentController.shared.recentDocumentURLs where !raw.contains(where: { $0["path"] == url.path }) {
            raw.append(["path": url.path, "name": showName(url) ?? url.lastPathComponent])
        }
        UserDefaults.standard.set(Array(raw.prefix(12)), forKey: key)
    }

    /// For a show's working copy: the show's name, read from the file.
    private static func showName(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), let d = try? JSONDecoder().decode(Drawing.self, from: data),
              d.inShow == true, let link = d.lxBook else { return nil }
        return link.showName + " (Lx Book)"
    }

    /// AppKit puts in an Open Recent menu of its own; ours is the one that survives updates, so its copy goes.
    static func removeSystemMenu() {
        guard let file = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "File" })?.submenu else { return }
        for item in file.items where item.title == "Open Recent" && !(item.submenu?.delegate is RecentMenu) {
            file.removeItem(item)
        }
    }

    static func add(_ url: URL, name: String) {
        var raw = (UserDefaults.standard.array(forKey: key) as? [[String: String]] ?? []).filter { $0["path"] != url.path }
        raw.insert(["path": url.path, "name": name], at: 0)
        UserDefaults.standard.set(Array(raw.prefix(12)), forKey: key)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func open(_ path: String) {
        NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: path), display: true) { _, _, error in
            if let error = error { NSAlert(error: error).runModal() }
        }
    }

    /// At launch: offer to open the last drawing again.
    static func askToReopen() {
        if !NSDocumentController.shared.documents.isEmpty { return }
        guard let last = list.first else {
            NSDocumentController.shared.newDocument(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Open \(last.name) again?"
        alert.informativeText = "It was the last drawing you had open."
        alert.addButton(withTitle: "Open It")
        alert.addButton(withTitle: "New Drawing")
        alert.addButton(withTitle: "Neither")
        switch alert.runModal() {
        case .alertFirstButtonReturn: open(last.path)
        case .alertSecondButtonReturn: NSDocumentController.shared.newDocument(nil)
        default: break
        }
    }
}

/// File > Open Recent, filled from the list above each time it opens.
final class RecentMenu: NSObject, NSMenuDelegate {
    static let shared = RecentMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let items = Recents.list
        for r in items {
            let item = NSMenuItem(title: r.name, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = r.path
            item.toolTip = r.path
            menu.addItem(item)
        }
        if items.isEmpty {
            let none = NSMenuItem(title: "No Recent Drawings", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(NSMenuItem.separator())
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearAll(_:)), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !items.isEmpty
        menu.addItem(clear)
    }

    @objc func pick(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? String { Recents.open(p) }
    }

    @objc func clearAll(_ sender: Any?) {
        Recents.clear()
        NSDocumentController.shared.clearRecentDocuments(nil)
    }
}
