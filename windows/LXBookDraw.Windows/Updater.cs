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
        var exe = J.Objs(release, "assets").Select(a => J.S(a, "browser_download_url"))
            .FirstOrDefault(u => u.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) && u.Contains("Windows", StringComparison.OrdinalIgnoreCase));
        if (BuildNumber(tag) <= AppInfo.Build || string.IsNullOrEmpty(exe))
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
        if (answer == MessageBoxResult.Yes) await Install(owner, exe);
    }

    static async Task Install(Window owner, string address)
    {
        var current = Environment.ProcessPath ?? "";
        if (current.Length == 0 || !File.Exists(current))
        {
            MessageBox.Show(owner, "Couldn't find where LX Book Draw is running from.", "Update");
            return;
        }
        var fresh = Path.Combine(Path.GetTempPath(), "LX Book Draw (new).exe");
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, address);
            req.Headers.TryAddWithoutValidation("User-Agent", "LXBookDraw-Windows/" + AppInfo.Version);
            using var res = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead);
            res.EnsureSuccessStatusCode();
            await using (var file = File.Create(fresh)) await res.Content.CopyToAsync(file);
            // check the app's folder can be written to before quitting
            var probe = Path.Combine(Path.GetDirectoryName(current)!, ".lxbookdraw-update-test");
            File.WriteAllText(probe, "");
            File.Delete(probe);
        }
        catch (UnauthorizedAccessException)
        {
            MessageBox.Show(owner, "Windows won't let LX Book Draw replace itself in " + Path.GetDirectoryName(current) +
                ". Move LX Book Draw.exe to your Documents or Desktop folder and try again.", "Update");
            return;
        }
        catch (Exception e)
        {
            MessageBox.Show(owner, "The download didn't finish: " + e.Message, "Update");
            return;
        }
        // a small script waits for this copy to quit, puts the new one in its place and starts it
        var pid = Environment.ProcessId;
        var script = Path.Combine(Path.GetTempPath(), "lxbookdraw-update.cmd");
        var sb = new StringBuilder();
        sb.AppendLine("@echo off");
        sb.AppendLine(":wait");
        sb.AppendLine($"tasklist /fi \"PID eq {pid}\" | find \"{pid}\" >nul && (timeout /t 1 /nobreak >nul & goto wait)");
        sb.AppendLine($"move /y \"{fresh}\" \"{current}\" >nul");
        sb.AppendLine($"start \"\" \"{current}\"");
        sb.AppendLine("del \"%~f0\"");
        File.WriteAllText(script, sb.ToString(), Encoding.Default);
        Process.Start(new ProcessStartInfo("cmd.exe", "/c \"" + script + "\"") { CreateNoWindow = true, UseShellExecute = false, WindowStyle = ProcessWindowStyle.Hidden });
        Application.Current.Shutdown();
    }
}
