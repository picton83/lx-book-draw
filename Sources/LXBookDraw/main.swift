import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = AppDelegate.buildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
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

    static func buildMenu() -> NSMenu {
        let main = NSMenu()
        let sep = { NSMenuItem.separator() }

        main.addItem(submenu("LX Book Draw", [
            item("About LX Book Draw", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            sep(),
            item("Hide LX Book Draw", #selector(NSApplication.hide(_:)), "h"),
            item("Quit LX Book Draw", #selector(NSApplication.terminate(_:)), "q")
        ]))

        main.addItem(submenu("File", [
            item("New", #selector(NSDocumentController.newDocument(_:)), "n"),
            item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
            sep(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Save…", #selector(NSDocument.save(_:)), "s"),
            item("Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]),
            sep(),
            item("Add Fixture from GDTF Share…", #selector(MainWindowController.addFromGDTF(_:)), "g", [.command, .shift]),
            item("Import GDTF File…", #selector(MainWindowController.importGDTFFile(_:))),
            sep(),
            item("Export PDF…", #selector(MainWindowController.exportPDF(_:)), "e")
        ]))

        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            sep(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Duplicate", #selector(MainWindowController.duplicateAction(_:)), "d"),
            item("Delete", #selector(MainWindowController.deleteAction(_:))),
            item("Select All", #selector(NSResponder.selectAll(_:)), "a")
        ]))

        main.addItem(submenu("View", [
            item("Zoom In", #selector(MainWindowController.zoomInAction(_:)), "="),
            item("Zoom Out", #selector(MainWindowController.zoomOutAction(_:)), "-"),
            item("Fit to Objects", #selector(MainWindowController.zoomFitAction(_:)), "6")
        ]))

        main.addItem(submenu("Modify", [
            item("Send to Front", #selector(MainWindowController.bringToFront(_:)), "f"),
            item("Send to Back", #selector(MainWindowController.sendToBack(_:)), "b")
        ]))

        let windowHolder = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)))
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
