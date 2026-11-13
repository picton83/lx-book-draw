import AppKit

/// Light or dark: "auto" follows the Mac's own setting, "light" and "dark" hold it.
enum Theme {
    static var mode: String {
        get { UserDefaults.standard.string(forKey: "theme") ?? "auto" }
        set {
            UserDefaults.standard.set(newValue, forKey: "theme")
            apply()
        }
    }

    static func apply() {
        switch mode {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil
        }
    }
}
