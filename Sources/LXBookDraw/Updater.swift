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

/// The update window: what is happening now, with the download's progress (as on Windows).
final class UpdatePanel: NSObject {
    static let shared = UpdatePanel()
    private var window: NSPanel?
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let bar = NSProgressIndicator()
    private let barText = NSTextField(labelWithString: "")
    private let steps = NSTextField(wrappingLabelWithString: "")
    private var stepNames: [String] = []
    private var stepStates: [String] = []

    func show() {
        if window == nil {
            let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 230), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Software Update"
            w.isReleasedWhenClosed = false
            title.font = .boldSystemFont(ofSize: 15)
            barText.font = .systemFont(ofSize: 11)
            barText.textColor = .secondaryLabelColor
            bar.style = .bar
            bar.minValue = 0
            bar.maxValue = 1
            let stack = NSStackView(views: [title, detail, steps, bar, barText])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
            for v in [title, detail, steps, bar, barText] { v.translatesAutoresizingMaskIntoConstraints = false }
            stack.translatesAutoresizingMaskIntoConstraints = false
            w.contentView = stack
            for v in [detail, steps, bar] { v.widthAnchor.constraint(equalToConstant: 420).isActive = true }
            window = w
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func set(_ heading: String, _ text: String) {
        title.stringValue = heading
        detail.stringValue = text
    }

    func begin(_ names: [String]) {
        stepNames = names
        stepStates = names.map { _ in "wait" }
        drawSteps()
        bar.isHidden = true
        barText.isHidden = true
    }

    func step(_ i: Int, _ state: String) {
        guard i >= 0 && i < stepStates.count else { return }
        stepStates[i] = state
        drawSteps()
        if state != "now" {
            bar.isHidden = true
            barText.isHidden = true
        }
    }

    private func drawSteps() {
        steps.stringValue = zip(stepNames, stepStates).map { name, state in
            (state == "done" ? "✓  " : state == "now" ? "▶  " : state == "failed" ? "✗  " : "○  ") + name
        }.joined(separator: "\n")
    }

    func progress(_ got: Int64, _ total: Int64, _ perSecond: Double) {
        bar.isHidden = false
        barText.isHidden = false
        bar.isIndeterminate = total <= 0
        if total > 0 { bar.doubleValue = Double(got) / Double(total) } else { bar.startAnimation(nil) }
        var text = String(format: "%.1f MB", Double(got) / 1048576)
        if total > 0 { text += String(format: " of %.1f MB (%.0f%%)", Double(total) / 1048576, 100 * Double(got) / Double(total)) }
        if perSecond > 0 {
            text += String(format: " · %.1f MB/s", perSecond / 1048576)
            if total > got { text += String(format: " · about %.0f s left", ceil(Double(total - got) / perSecond)) }
        }
        barText.stringValue = text
    }

    func close() {
        window?.orderOut(nil)
    }
}

/// Updates the installed app from the newest GitHub release of picton83/lx-book-draw.
/// The repository must stay public for this to work without a login.
final class Updater: NSObject, URLSessionDownloadDelegate {
    static let shared = Updater()
    private var downloadStarted = Date()
    private var lastShown = Date.distantPast
    private var downloadDone: ((URL?, Error?) -> Void)?
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
        if userInitiated {
            UpdatePanel.shared.begin([])
            UpdatePanel.shared.set("Checking for updates…", "You have LX Book Draw \(AppInfo.version) (build \(AppInfo.build)). Asking GitHub for the newest version.")
            UpdatePanel.shared.show()
        }
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
                UpdatePanel.shared.close()
                message("Couldn't check for updates", error?.localizedDescription ?? "GitHub didn't return a release. Check the internet connection.")
            }
            return
        }
        let assets = (release["assets"] as? [[String: Any]]) ?? []
        let zip = assets.compactMap { $0["browser_download_url"] as? String }.first { $0.hasSuffix(".zip") }
        let newest = Updater.buildNumber(fromTag: tag)
        guard newest > AppInfo.build, let zipAddress = zip, let zipURL = URL(string: zipAddress) else {
            if userInitiated {
                UpdatePanel.shared.close()
                if newest > AppInfo.build {
                    message("Not ready yet", "\((release["name"] as? String) ?? tag) is out, but its Mac download is still being built on GitHub. Try again in a few minutes.")
                } else {
                    message("You're up to date", "LX Book Draw \(AppInfo.version) (build \(AppInfo.build)) is the newest version.")
                }
            }
            return
        }
        UpdatePanel.shared.close()
        let alert = NSAlert()
        alert.messageText = "\((release["name"] as? String) ?? tag) is available"
        let notes = String(((release["body"] as? String) ?? "").prefix(700))
        alert.informativeText = "You have \(AppInfo.version) (build \(AppInfo.build)). The update downloads the new version, saves your work and relaunches.\n\n" + notes
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
        let names = ["Download the new version", "Check and unpack it", "Save your work and relaunch"]
        UpdatePanel.shared.begin(names)
        UpdatePanel.shared.set("Updating LX Book Draw", "Please wait. You can carry on looking at the drawing; it's saved before the relaunch.")
        UpdatePanel.shared.show()
        UpdatePanel.shared.step(0, "now")
        downloadStarted = Date()
        downloadDone = { temp, error in
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
                    UpdatePanel.shared.step(0, "failed")
                    UpdatePanel.shared.close()
                    self.message("The update couldn't be downloaded", failure + " Check the internet connection and try again.")
                } else {
                    UpdatePanel.shared.step(0, "done")
                    UpdatePanel.shared.step(1, "now")
                    self.swap(zipFile, work, appPath)
                }
            }
        }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session.downloadTask(with: zipURL).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = Date()
        if now.timeIntervalSince(lastShown) < 0.15 { return }
        lastShown = now
        let rate = Double(totalBytesWritten) / max(now.timeIntervalSince(downloadStarted), 0.1)
        DispatchQueue.main.async { UpdatePanel.shared.progress(totalBytesWritten, totalBytesExpectedToWrite, rate) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // the file at `location` is removed when this returns, so keep a copy first
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("lxbookdraw-download-" + UUID().uuidString + ".zip")
        do {
            try FileManager.default.moveItem(at: location, to: keep)
            downloadDone?(keep, nil)
        } catch {
            downloadDone?(nil, error)
        }
        downloadDone = nil
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            downloadDone?(nil, error)
            downloadDone = nil
        }
        session.finishTasksAndInvalidate()
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
            UpdatePanel.shared.close()
            message("The update couldn't be unpacked", error.localizedDescription)
            return
        }
        let found = (try? FileManager.default.contentsOfDirectory(atPath: unpacked.path))?.first { $0.hasSuffix(".app") }
        guard unzip.terminationStatus == 0, let appName = found else {
            UpdatePanel.shared.close()
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
            UpdatePanel.shared.close()
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
            UpdatePanel.shared.close()
            message("The update couldn't be installed", error.localizedDescription)
            return
        }
        UpdatePanel.shared.step(1, "done")
        UpdatePanel.shared.step(2, "now")
        UpdatePanel.shared.set("Relaunching…", "Saving your work and closing. The new version opens by itself in a moment.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
    }
}
