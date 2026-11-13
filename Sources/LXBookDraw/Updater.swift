import AppKit

enum AppInfo {
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    /// Goes up by one with every build GitHub makes, so it orders versions reliably.
    static var build: Int {
        Int((Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "") ?? 0
    }
}

/// Updates the installed app from the newest GitHub release of picton83/lx-book-draw.
/// The repository must stay public for this to work without a login.
final class Updater {
    static let shared = Updater()
    private let latest = "https://api.github.com/repos/picton83/lx-book-draw/releases/latest"
    private var busy = false

    private func message(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    /// Release tags look like v0.3.0-BETA-b12; the number after "-b" is the build.
    static func buildNumber(fromTag tag: String) -> Int {
        guard let r = tag.range(of: "-b", options: .backwards) else { return 0 }
        return Int(tag[r.upperBound...]) ?? 0
    }

    func check(userInitiated: Bool) {
        if busy { return }
        guard let url = URL(string: latest) else { return }
        busy = true
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("LX Book Draw", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let task = URLSession.shared.dataTask(with: req) { data, _, error in
            DispatchQueue.main.async {
                self.busy = false
                self.handle(data, error, userInitiated)
            }
        }
        task.resume()
    }

    private func handle(_ data: Data?, _ error: Error?, _ userInitiated: Bool) {
        var json: [String: Any]? = nil
        if let data = data {
            json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        guard let release = json, let tag = release["tag_name"] as? String else {
            if userInitiated {
                message("Couldn't check for updates", error?.localizedDescription ?? "GitHub didn't return a release. Check the internet connection.")
            }
            return
        }
        let assets = (release["assets"] as? [[String: Any]]) ?? []
        let zip = assets.compactMap { $0["browser_download_url"] as? String }.first { $0.hasSuffix(".zip") }
        let newest = Updater.buildNumber(fromTag: tag)
        guard newest > AppInfo.build, let zipAddress = zip, let zipURL = URL(string: zipAddress) else {
            if userInitiated {
                message("You're up to date", "LX Book Draw \(AppInfo.version) (build \(AppInfo.build)) is the newest version.")
            }
            return
        }
        let alert = NSAlert()
        alert.messageText = "\((release["name"] as? String) ?? tag) is available"
        let notes = String(((release["body"] as? String) ?? "").prefix(700))
        alert.informativeText = "You have \(AppInfo.version) (build \(AppInfo.build)).\n\n" + notes
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { install(zipURL) }
    }

    private func install(_ zipURL: URL) {
        let appPath = Bundle.main.bundlePath
        let folder = (appPath as NSString).deletingLastPathComponent
        if appPath.contains("/AppTranslocation/") || !appPath.hasSuffix(".app") {
            message("Move LX Book Draw to Applications first",
                    "macOS is running this copy from a temporary place, so it can't be replaced. Quit, drag LX Book Draw into the Applications folder, open it from there, then check for updates again.")
            return
        }
        if !FileManager.default.isWritableFile(atPath: folder) {
            message("Can't update here", "LX Book Draw can't write to \(folder). Move the app to a folder you own, such as Applications.")
            return
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("lxbookdraw-update-" + UUID().uuidString, isDirectory: true)
        let zipFile = work.appendingPathComponent("update.zip")
        let task = URLSession.shared.downloadTask(with: zipURL) { temp, _, error in
            var failure: String? = error?.localizedDescription
            if let temp = temp {
                do {
                    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: temp, to: zipFile)
                } catch {
                    failure = error.localizedDescription
                }
            } else if failure == nil {
                failure = "Nothing was downloaded."
            }
            DispatchQueue.main.async {
                if let failure = failure {
                    self.message("The update couldn't be downloaded", failure)
                } else {
                    self.swap(zipFile, work, appPath)
                }
            }
        }
        task.resume()
    }

    private func swap(_ zipFile: URL, _ work: URL, _ appPath: String) {
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zipFile.path, unpacked.path]
        do {
            try unzip.run()
            unzip.waitUntilExit()
        } catch {
            message("The update couldn't be unpacked", error.localizedDescription)
            return
        }
        let found = (try? FileManager.default.contentsOfDirectory(atPath: unpacked.path))?.first { $0.hasSuffix(".app") }
        guard unzip.terminationStatus == 0, let appName = found else {
            message("The update couldn't be unpacked", "The download didn't contain the app.")
            return
        }
        let newApp = unpacked.appendingPathComponent(appName).path
        let oldApp = work.appendingPathComponent("previous.app").path

        // Waits for this copy to quit, swaps the app, and opens the new one. If the copy fails the
        // old app is put back.
        let script = """
        #!/bin/bash
        PID="$1"; NEW="$2"; DEST="$3"; OLD="$4"
        for i in $(seq 1 600); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
        if kill -0 "$PID" 2>/dev/null; then exit 0; fi
        mv "$DEST" "$OLD" || exit 1
        if /usr/bin/ditto "$NEW" "$DEST"; then
          /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        else
          rm -rf "$DEST"
          mv "$OLD" "$DEST"
        fi
        open "$DEST"
        """
        let scriptFile = work.appendingPathComponent("swap.sh")
        do {
            try script.write(to: scriptFile, atomically: true, encoding: .utf8)
        } catch {
            message("The update couldn't be installed", error.localizedDescription)
            return
        }
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/bash")
        launcher.arguments = ["-c", "nohup /bin/bash \"$0\" \"$1\" \"$2\" \"$3\" \"$4\" >/dev/null 2>&1 &",
                              scriptFile.path, String(ProcessInfo.processInfo.processIdentifier), newApp, appPath, oldApp]
        do {
            try launcher.run()
        } catch {
            message("The update couldn't be installed", error.localizedDescription)
            return
        }
        NSApp.terminate(nil)
    }
}
