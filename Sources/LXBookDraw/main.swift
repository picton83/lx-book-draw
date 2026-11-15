import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    func applicationWillFinishLaunching(_ notification: Notification) {
        Theme.apply()
        NSApp.mainMenu = AppDelegate.buildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        NoteStore.clearCompleted()
        // First launch: sign in to Lx Book and pick a show (once; File > Sign In does it later).
        // Otherwise: offer to open the last drawing again.
        if !UserDefaults.standard.bool(forKey: "askedLxSignIn") && !LxAccount.signedIn(LxSettings.server) {
            UserDefaults.standard.set(true, forKey: "askedLxSignIn")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                (NSDocumentController.shared as? DocController)?.signIn(nil)
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                Recents.askToReopen()
            }
        }
        // Look for a newer version on GitHub shortly after opening; silent unless there is one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            Updater.shared.check(userInitiated: false)
        }
    }

    /// No blank drawing at launch: the app asks whether to open the last one instead (Recents.askToReopen).
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    @objc func checkForUpdates(_ sender: Any?) {
        Updater.shared.check(userInitiated: true)
    }

    @objc func setTheme(_ sender: NSMenuItem) {
        if let mode = sender.representedObject as? String { Theme.mode = mode }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(setTheme(_:)) {
            item.state = (item.representedObject as? String) == Theme.mode ? .on : .off
        }
        return true
    }

    private static func fkey(_ code: Int) -> String {
        String(UnicodeScalar(UInt32(code)).map { Character($0) } ?? " ")
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        return i
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        for i in items { menu.addItem(i) }
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private static func recentItem() -> NSMenuItem {
        let menu = NSMenu(title: "Open Recent")
        menu.delegate = RecentMenu.shared
        let holder = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    static func buildMenu() -> NSMenu {
        let main = NSMenu()
        let sep = { NSMenuItem.separator() }

        main.addItem(submenu("LX Book Draw", [
            item("About LX Book Draw", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            item("Check for Updates…", #selector(AppDelegate.checkForUpdates(_:))),
            sep(),
            item("Hide LX Book Draw", #selector(NSApplication.hide(_:)), "h"),
            item("Quit LX Book Draw", #selector(NSApplication.terminate(_:)), "q")
        ]))

        main.addItem(submenu("File", [
            item("New", #selector(NSDocumentController.newDocument(_:)), "n"),
            item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
            recentItem(),
            item("Open Show from Lx Book…", #selector(DocController.openShow(_:)), "o", [.command, .shift]),
            item("Sign In to Lx Book…", #selector(DocController.signIn(_:))),
            item("Sign Out of Lx Book", #selector(DocController.signOut(_:))),
            sep(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Save…", #selector(NSDocument.save(_:)), "s"),
            item("Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]),
            item("Save to Dropbox…", #selector(MainWindowController.saveToDropbox(_:))),
            item("Keep a PDF Up to Date in a Folder…", #selector(MainWindowController.choosePublishFolder(_:))),
            sep(),
            item("Link to Lx Book…", #selector(MainWindowController.connectLxBook(_:)), "l", [.command, .shift]),
            item("Move This Drawing into the Lx Book Show…", #selector(MainWindowController.moveIntoShow(_:))),
            sep(),
            item("Add Fixture from GDTF Share…", #selector(MainWindowController.addFromGDTF(_:)), "g", [.command, .option]),
            item("Import GDTF File…", #selector(MainWindowController.importGDTFFile(_:))),
            sep(),
            item("Export PDF…", #selector(MainWindowController.exportPDF(_:)), "e"),
            item("Export Drawing File…", #selector(MainWindowController.exportDrawingFile(_:))),
            sep(),
            item("Import DXF…", #selector(MainWindowController.importDXF(_:))),
            item("Export DXF…", #selector(MainWindowController.exportDXF(_:)))
        ]))

        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            item("Change Log…", #selector(MainWindowController.showLog(_:))),
            sep(),
            item("Cut", #selector(MainWindowController.cutAction(_:)), "x"),
            item("Copy", #selector(MainWindowController.copyAction(_:)), "c"),
            item("Paste", #selector(MainWindowController.pasteAction(_:)), "v"),
            item("Duplicate", #selector(MainWindowController.duplicateAction(_:)), "d"),
            item("Delete", #selector(MainWindowController.deleteAction(_:))),
            item("Select All", #selector(MainWindowController.selectAllAction(_:)), "a")
        ]))

        var themes: [NSMenuItem] = []
        for (title, mode) in [("Match the Mac (Auto)", "auto"), ("Light", "light"), ("Dark", "dark")] {
            let i = item(title, #selector(AppDelegate.setTheme(_:)))
            i.representedObject = mode
            themes.append(i)
        }
        main.addItem(submenu("View", [
            item("Zoom In", #selector(MainWindowController.zoomInAction(_:)), "="),
            item("Zoom Out", #selector(MainWindowController.zoomOutAction(_:)), "-"),
            item("Fit to Objects", #selector(MainWindowController.zoomFitAction(_:)), "6"),
            sep(),
            submenu("Appearance", themes)
        ]))

        main.addItem(submenu("Modify", [
            item("Group", #selector(MainWindowController.groupAction(_:)), "g"),
            item("Ungroup", #selector(MainWindowController.ungroupAction(_:)), "g", [.command, .shift]),
            sep(),
            item("Move Label…", #selector(MainWindowController.labelAction(_:))),
            item("Fixture Label Config…", #selector(MainWindowController.labelConfig(_:)), "l", [.command, .option]),
            sep(),
            item("Send to Front", #selector(MainWindowController.bringToFront(_:)), "f"),
            item("Send to Back", #selector(MainWindowController.sendToBack(_:)), "b")
        ]))

        // Drafting aids on AutoCAD's function keys
        var drafting: [NSMenuItem] = [
            item("Object Snap", #selector(MainWindowController.toggleOsnap(_:)), fkey(NSF3FunctionKey), []),
            item("Grid", #selector(MainWindowController.toggleGrid(_:)), fkey(NSF7FunctionKey), []),
            item("Ortho", #selector(MainWindowController.toggleOrtho(_:)), fkey(NSF8FunctionKey), []),
            item("Grid Snap", #selector(MainWindowController.toggleGridSnap(_:)), fkey(NSF9FunctionKey), []),
            sep()
        ]
        for kind in SnapKind.allCases {
            let i = item("Snap to " + kind.label, #selector(MainWindowController.toggleSnapMode(_:)))
            i.representedObject = kind.rawValue
            drafting.append(i)
        }
        main.addItem(submenu("Drafting", drafting))
        main.addItem(submenu("Notes", [
            item("Write an Improvement Note…", #selector(MainWindowController.writeNote(_:)), "n", [.command, .shift]),
            item("Show Notes…", #selector(MainWindowController.showNotes(_:)))
        ]))


        let windowHolder = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            sep(),
            item("Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "\t", [.control]),
            item("Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "\t", [.control, .shift]),
            item("Merge All Windows", #selector(NSWindow.mergeAllWindows(_:)))
        ])
        main.addItem(windowHolder)
        NSApp.windowsMenu = windowHolder.submenu
        return main
    }
}

let app = NSApplication.shared
_ = DocController()   // must exist before the app starts so it becomes the shared document controller
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
