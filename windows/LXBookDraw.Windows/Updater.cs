using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows;

namespace LXBookDrawWin;

/// Updates the app from the newest GitHub release, like the Mac app: the number after "-b" in the release's tag is the build.
public static class Updater
{
    const string Latest = "https://api.github.com/repos/picton83/lx-book-draw/releases/latest";
    static readonly HttpClient http = new() { Timeout = TimeSpan.FromMinutes(10) };

    public static int BuildNumber(string tag)
    {
        var m = Regex.Match(tag, @"-b(\d+)$");
        return m.Success ? int.Parse(m.Groups[1].Value) : 0;
    }

    public static async Task Check(Window owner, bool userInitiated)
    {
        JsonObject? release = null;
        string problem = "";
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, Latest);
            req.Headers.TryAddWithoutValidation("User-Agent", "LXBookDraw-Windows/" + AppInfo.Version);
            req.Headers.TryAddWithoutValidation("Accept", "application/vnd.github+json");
            var res = await http.SendAsync(req);
            release = JsonNode.Parse(await res.Content.ReadAsStringAsync()) as JsonObject;
        }
        catch (Exception e)
        {
            problem = e.Message;
        }
        var tag = J.S(release, "tag_name");
        if (tag.Length == 0)
        {
            if (userInitiated)
                MessageBox.Show(owner, problem.Length > 0 ? problem : "GitHub didn't return a release. Check the internet connection.", "Couldn't check for updates");
            return;
        }
        // the Windows app is the release's .exe; the Mac app is its .zip
        // installed in Program Files: run the newer installer; a loose copy: swap in the newer .exe
        var installed = Installed;
        var asset = J.Objs(release, "assets").FirstOrDefault(a =>
        {
            var n = J.S(a, "name");
            return n.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) && n.Contains("Windows", StringComparison.OrdinalIgnoreCase) &&
                   n.Contains("Setup", StringComparison.OrdinalIgnoreCase) == installed;
        });
        var exe = J.S(asset, "browser_download_url");
        var newest = BuildNumber(tag);
        if (!userInitiated && newest > AppInfo.Build && Attempted == newest)
        {
            // the last try to install this build didn't take: say so once instead of asking again on every start
            Attempted = -newest;
            MessageBox.Show(owner, $"Updating to build {newest} didn't work last time (this is still build {AppInfo.Build}). Use Check for Updates to try again, or download it from the GitHub release page.", "Update");
            return;
        }
        if (!userInitiated && Attempted == -newest) return;
        if (newest <= AppInfo.Build || exe.Length == 0)
        {
            if (userInitiated)
                MessageBox.Show(owner, $"LX Book Draw {AppInfo.Version} (build {AppInfo.Build}) is the newest version.", "You're up to date");
            return;
        }
        var notes = J.S(release, "body");
        if (notes.Length > 700) notes = notes.Substring(0, 700) + "…";
        var name = J.S(release, "name") is var n && n.Length > 0 ? n : tag;
        var answer = MessageBox.Show(owner, $"You have {AppInfo.Version} (build {AppInfo.Build}).\n\n{notes}\n\nInstall it and restart now?",
            name + " is available", MessageBoxButton.YesNo, MessageBoxImage.Information);
        if (answer != MessageBoxResult.Yes) return;
        if (installed) await RunInstaller(owner, exe, newest, (long)J.D(asset, "size"));
        else await Install(owner, exe, newest, (long)J.D(asset, "size"));
    }

    /// Downloads the new app next to this one, swaps the files (Windows lets a running program's file be renamed),
    /// starts the new one and quits. The old file is deleted the next time the app starts.
    static async Task Install(Window owner, string address, int build, long size)
    {
        var current = Environment.ProcessPath ?? "";
        if (current.Length == 0 || !File.Exists(current))
        {
            MessageBox.Show(owner, "Couldn't find where LX Book Draw is running from.", "Update");
            return;
        }
        var folder = Path.GetDirectoryName(current)!;
        var fresh = Path.Combine(folder, Path.GetFileNameWithoutExtension(current) + ".new");
        var old = current + ".old";
        try
        {
            using (var req = new HttpRequestMessage(HttpMethod.Get, address))
            {
                req.Headers.TryAddWithoutValidation("User-Agent", "LXBookDraw-Windows/" + AppInfo.Version);
                using var res = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead);
                res.EnsureSuccessStatusCode();
                await using var file = File.Create(fresh);
                await res.Content.CopyToAsync(file);
            }
            var got = new FileInfo(fresh).Length;
            if (size > 0 && got != size) throw new IOException($"the download was incomplete ({got} of {size} bytes)");
            if (File.Exists(old)) File.Delete(old);
            File.Move(current, old);
            try
            {
                File.Move(fresh, current);
            }
            catch
            {
                File.Move(old, current);   // put this version back
                throw;
            }
        }
        catch (UnauthorizedAccessException)
        {
            TryDelete(fresh);
            MessageBox.Show(owner, "Windows won't let LX Book Draw replace itself in " + folder +
                ". Move the LX Book Draw .exe to your Documents or Desktop folder and try again.", "Update");
            return;
        }
        catch (Exception e)
        {
            TryDelete(fresh);
            MessageBox.Show(owner, "The update didn't install: " + e.Message + "\n\nYou can download it from the GitHub release page instead.", "Update");
            return;
        }
        Attempted = build;
        // close normally (anything waiting goes to Lx Book and the drawing is saved), then start the new version
        owner.Closed += (_, _) =>
        {
            try { Process.Start(new ProcessStartInfo(current) { UseShellExecute = true, WorkingDirectory = folder }); } catch { }
        };
        owner.Close();
    }

    /// True when the app runs from Program Files (put there by the installer).
    static bool Installed
    {
        get
        {
            var current = Environment.ProcessPath ?? "";
            foreach (var f in new[] { Environment.SpecialFolder.ProgramFiles, Environment.SpecialFolder.ProgramFilesX86 })
            {
                var pf = Environment.GetFolderPath(f);
                if (pf.Length > 0 && current.StartsWith(pf + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        }
    }

    /// Downloads the newer installer, closes the app normally, then runs the installer quietly (Windows asks to allow it).
    /// The installer puts the new version in Program Files and opens it.
    static async Task RunInstaller(Window owner, string address, int build, long size)
    {
        var setup = Path.Combine(Path.GetTempPath(), "LX-Book-Draw-Setup.exe");
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, address);
            req.Headers.TryAddWithoutValidation("User-Agent", "LXBookDraw-Windows/" + AppInfo.Version);
            using var res = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead);
            res.EnsureSuccessStatusCode();
            await using (var file = File.Create(setup)) await res.Content.CopyToAsync(file);
            var got = new FileInfo(setup).Length;
            if (size > 0 && got != size) throw new IOException($"the download was incomplete ({got} of {size} bytes)");
        }
        catch (Exception e)
        {
            TryDelete(setup);
            MessageBox.Show(owner, "The update didn't download: " + e.Message, "Update");
            return;
        }
        Attempted = build;
        owner.Closed += (_, _) =>
        {
            try
            {
                Process.Start(new ProcessStartInfo(setup, "/SILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS") { UseShellExecute = true });
            }
            catch (Exception e)
            {
                // most likely "No" on Windows' question about allowing the installer
                MessageBox.Show("The update wasn't installed: " + e.Message, "Update");
            }
        };
        owner.Close();
    }

    static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }

    /// Called at start: removes the file an update left behind.
    public static void CleanUp()
    {
        var current = Environment.ProcessPath ?? "";
        if (current.Length > 0) TryDelete(current + ".old");
    }

    static string AttemptFile => Path.Combine(Account.Folder, "update-attempt.txt");

    /// The build the last update tried to install, so a failed swap isn't offered again and again.
    static int Attempted
    {
        get { try { return int.Parse(File.ReadAllText(AttemptFile).Trim()); } catch { return 0; } }
        set { try { File.WriteAllText(AttemptFile, value.ToString()); } catch { } }
    }
}
