using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace LXBookDrawWin;

/// Updates the app from the newest GitHub release, like the Mac app: the number after "-b" in the release's tag is the build.
/// Installed in Program Files it runs the newer installer; a loose copy swaps in the newer .exe.
/// Every step shows in the update window, so it's clear what is happening and what went wrong.
public static class Updater
{
    const string Latest = "https://api.github.com/repos/picton83/lx-book-draw/releases/latest";
    public const string Releases = "https://github.com/picton83/lx-book-draw/releases";
    static readonly HttpClient http = new() { Timeout = TimeSpan.FromMinutes(15) };
    static bool running;

    public static int BuildNumber(string tag)
    {
        var m = Regex.Match(tag, @"-b(\d+)$");
        return m.Success ? int.Parse(m.Groups[1].Value) : 0;
    }

    /// True when the app runs from Program Files (put there by the installer).
    public static bool Installed
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

    /// After an update: a line saying what was installed (once), for the command line.
    public static string? JustUpdated()
    {
        if (Attempted != AppInfo.Build || AppInfo.Build == 0) return null;
        Attempted = 0;
        return $"Updated to LX Book Draw {AppInfo.Version} (build {AppInfo.Build}). What's new: Tools > Check for Updates shows the notes.";
    }

    /// `userInitiated`: from the menu, so the window shows from the start (checking, up to date, problems).
    /// At start-up it stays quiet unless there is a newer version.
    public static async Task Check(Window owner, bool userInitiated)
    {
        if (running) return;
        running = true;
        try
        {
            UpdateWindow? w = null;
            if (userInitiated)
            {
                w = new UpdateWindow(owner);
                w.Checking();
                w.Show();
            }
            JsonObject? release = null;
            string problem = "";
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, Latest);
                req.Headers.TryAddWithoutValidation("User-Agent", "LXBookDraw-Windows/" + AppInfo.Version);
                req.Headers.TryAddWithoutValidation("Accept", "application/vnd.github+json");
                using var res = await http.SendAsync(req);
                var text = await res.Content.ReadAsStringAsync();
                if (!res.IsSuccessStatusCode) problem = $"GitHub answered {(int)res.StatusCode}.";
                release = JsonNode.Parse(text) as JsonObject;
            }
            catch (Exception e)
            {
                problem = e.Message;
            }
            var tag = J.S(release, "tag_name");
            if (tag.Length == 0)
            {
                w?.Problem("Couldn't check for updates", (problem.Length > 0 ? problem : "GitHub didn't send the release.") + " Check the internet connection and try again.");
                return;
            }
            var installed = Installed;
            var asset = J.Objs(release, "assets").FirstOrDefault(a =>
            {
                var n = J.S(a, "name");
                return n.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) && n.Contains("Windows", StringComparison.OrdinalIgnoreCase) &&
                       n.Contains("Setup", StringComparison.OrdinalIgnoreCase) == installed;
            });
            var url = J.S(asset, "browser_download_url");
            var newest = BuildNumber(tag);
            var name = J.S(release, "name") is var nm && nm.Length > 0 ? nm : tag;
            var notes = J.S(release, "body");
            if (!userInitiated && newest > AppInfo.Build && Attempted == newest)
            {
                // the last try to install this build didn't take: say so once instead of asking on every start
                Attempted = -newest;
                w = new UpdateWindow(owner);
                w.Show();
                w.Problem("The last update didn't install",
                    $"Updating to build {newest} was started but this is still build {AppInfo.Build}. Try again with Install, or download it from the release page.",
                    () => _ = Install(owner, w!, url, newest, (long)J.D(asset, "size"), installed));
                return;
            }
            if (!userInitiated && Attempted == -newest) return;
            if (newest <= AppInfo.Build)
            {
                w?.UpToDate(notes);
                return;
            }
            if (url.Length == 0)
            {
                // the release is there but its Windows download isn't yet (GitHub is still building it)
                w?.Problem("Not ready yet", $"{name} is out, but its Windows download is still being built on GitHub. Try again in a few minutes.");
                return;
            }
            if (w == null)
            {
                w = new UpdateWindow(owner);
                w.Show();
            }
            var win = w;
            win.Offer(name, notes, installed, () => _ = Install(owner, win, url, newest, (long)J.D(asset, "size"), installed));
        }
        finally
        {
            running = false;
        }
    }

    static async Task Install(Window owner, UpdateWindow w, string url, int build, long size, bool installed)
    {
        var current = Environment.ProcessPath ?? "";
        var folder = Path.GetDirectoryName(current) ?? "";
        var target = installed ? Path.Combine(Path.GetTempPath(), "LX-Book-Draw-Setup.exe") : Path.Combine(folder, Path.GetFileNameWithoutExtension(current) + ".new");
        w.Steps(installed);

        // 1. download
        w.Step(0, "now", "");
        try
        {
            if (!installed)
            {
                // check the folder can be written to before downloading into it
                var probe = Path.Combine(folder, ".lxbookdraw-write-test");
                File.WriteAllText(probe, "");
                File.Delete(probe);
            }
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.TryAddWithoutValidation("User-Agent", "LXBookDraw-Windows/" + AppInfo.Version);
            using var res = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead);
            res.EnsureSuccessStatusCode();
            var total = res.Content.Headers.ContentLength ?? size;
            await using var input = await res.Content.ReadAsStreamAsync();
            await using (var file = File.Create(target))
            {
                var buffer = new byte[81920];
                long got = 0;
                var started = DateTime.Now;
                var shown = DateTime.MinValue;
                int read;
                while ((read = await input.ReadAsync(buffer)) > 0)
                {
                    await file.WriteAsync(buffer.AsMemory(0, read));
                    got += read;
                    if ((DateTime.Now - shown).TotalMilliseconds > 150)
                    {
                        shown = DateTime.Now;
                        var secs = Math.Max((DateTime.Now - started).TotalSeconds, 0.1);
                        w.Progress(got, total, got / secs);
                    }
                }
                w.Progress(got, total, 0);
            }
            w.Step(0, "done", $"{new FileInfo(target).Length / 1048576.0:0.0} MB downloaded");
        }
        catch (UnauthorizedAccessException)
        {
            TryDelete(target);
            w.Step(0, "failed", "");
            w.Problem("Can't update this copy", $"Windows won't let LX Book Draw replace itself in {folder}. Install it with the installer from the release page instead (it goes into Program Files and updates itself from then on).");
            return;
        }
        catch (Exception e)
        {
            TryDelete(target);
            w.Step(0, "failed", "");
            w.Problem("The download didn't finish", e.Message + " Check the internet connection and try again.");
            return;
        }

        // 2. check it
        w.Step(1, "now", "");
        var len = new FileInfo(target).Length;
        if ((size > 0 && len != size) || len < 1_000_000)
        {
            TryDelete(target);
            w.Step(1, "failed", "");
            w.Problem("The download is damaged", $"It is {len} bytes but should be {size}. Try again.");
            return;
        }
        w.Step(1, "done", "complete");

        if (!installed)
        {
            // 3. swap the files (Windows lets a running program's file be renamed)
            w.Step(2, "now", "");
            var old = current + ".old";
            try
            {
                if (File.Exists(old)) File.Delete(old);
                File.Move(current, old);
                try { File.Move(target, current); }
                catch
                {
                    File.Move(old, current);
                    throw;
                }
            }
            catch (Exception e)
            {
                TryDelete(target);
                w.Step(2, "failed", "");
                w.Problem("The new version couldn't be put in place", e.Message + " This version is still here and works.");
                return;
            }
            w.Step(2, "done", "");
        }

        // save, send anything waiting to Lx Book, close; then start the new version (or the installer)
        var save = installed ? 2 : 3;
        w.Step(save, "now", "");
        Attempted = build;
        await Task.Delay(400);
        owner.Closed += (_, _) =>
        {
            try
            {
                if (installed)
                    Process.Start(new ProcessStartInfo(target, "/SILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS") { UseShellExecute = true });
                else
                    Process.Start(new ProcessStartInfo(current) { UseShellExecute = true, WorkingDirectory = folder });
            }
            catch (Exception e)
            {
                // most often "No" on Windows' question about allowing the installer
                Attempted = 0;
                MessageBox.Show("The update wasn't installed: " + e.Message + "\n\nOpen LX Book Draw again and use Check for Updates to try again.", "LX Book Draw update");
            }
        };
        w.Finishing();
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
        TryDelete(Path.Combine(Path.GetTempPath(), "LX-Book-Draw-Setup.exe"));
    }

    static string AttemptFile => Path.Combine(Account.Folder, "update-attempt.txt");

    /// The build the last update tried to install, so a failed install isn't offered again and again.
    static int Attempted
    {
        get { try { return int.Parse(File.ReadAllText(AttemptFile).Trim()); } catch { return 0; } }
        set { try { File.WriteAllText(AttemptFile, value.ToString()); } catch { } }
    }
}

/// The update window: what is happening now, step by step, with the download's progress.
public sealed class UpdateWindow : Window
{
    readonly TextBlock title = new() { FontSize = 16, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap };
    readonly TextBlock detail = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0), Foreground = new SolidColorBrush(Color.FromRgb(0x44, 0x4A, 0x52)) };
    readonly ProgressBar bar = new() { Height = 10, Margin = new Thickness(0, 12, 0, 0), Visibility = Visibility.Collapsed };
    readonly TextBlock barText = new() { FontSize = 11, Margin = new Thickness(0, 4, 0, 0), Foreground = Brushes.Gray, Visibility = Visibility.Collapsed };
    readonly StackPanel steps = new() { Margin = new Thickness(0, 12, 0, 0) };
    readonly TextBox notes = new()
    {
        IsReadOnly = true, TextWrapping = TextWrapping.Wrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Height = 220,
        Margin = new Thickness(0, 12, 0, 0), FontSize = 12, Padding = new Thickness(6), Visibility = Visibility.Collapsed
    };
    readonly StackPanel buttons = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) };
    TextBlock[] stepLines = Array.Empty<TextBlock>();
    string[] stepNames = Array.Empty<string>();
    bool busy;

    public UpdateWindow(Window owner)
    {
        Owner = owner;
        Title = "Software Update";
        Width = 520;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        FontFamily = new FontFamily("Segoe UI");
        ShowInTaskbar = false;
        Icon = owner.Icon;
        var panel = new StackPanel { Margin = new Thickness(20) };
        panel.Children.Add(title);
        panel.Children.Add(detail);
        panel.Children.Add(notes);
        panel.Children.Add(steps);
        panel.Children.Add(bar);
        panel.Children.Add(barText);
        panel.Children.Add(buttons);
        Content = panel;
        Closing += (_, e) => { if (busy) e.Cancel = true; };
    }

    void Buttons(params (string Label, Action Act, bool Default)[] list)
    {
        buttons.Children.Clear();
        foreach (var (label, act, isDefault) in list)
        {
            var b = new Button { Content = label, Padding = new Thickness(14, 5, 14, 5), Margin = new Thickness(6, 0, 0, 0), IsDefault = isDefault };
            b.Click += (_, _) => act();
            buttons.Children.Add(b);
        }
    }

    public void Checking()
    {
        title.Text = "Checking for updates…";
        detail.Text = $"You have LX Book Draw {AppInfo.Version} (build {AppInfo.Build}). Asking GitHub for the newest version.";
        bar.IsIndeterminate = true;
        bar.Visibility = Visibility.Visible;
        Buttons(("Close", Close, false));
    }

    public void UpToDate(string releaseNotes)
    {
        bar.Visibility = Visibility.Collapsed;
        title.Text = "You're up to date";
        detail.Text = $"LX Book Draw {AppInfo.Version} (build {AppInfo.Build}) is the newest version. What's in it:";
        ShowNotes(releaseNotes);
        Buttons(("OK", Close, true));
    }

    void ShowNotes(string text)
    {
        notes.Text = text.Replace("**", "").Trim();
        notes.Visibility = notes.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    public void Offer(string name, string releaseNotes, bool installed, Action install)
    {
        bar.Visibility = Visibility.Collapsed;
        title.Text = name + " is available";
        detail.Text = $"You have {AppInfo.Version} (build {AppInfo.Build}). " +
                      (installed ? "The update downloads the new installer, saves your work, and installs the new version into Program Files. Windows will ask you to allow it."
                                 : "The update downloads the new version, saves your work, and restarts in it.");
        ShowNotes(releaseNotes);
        Buttons(("Later", Close, false), ("Install and Restart", install, true));
    }

    /// The list of steps, each shown as waiting, in progress, done or failed.
    public void Steps(bool installed)
    {
        busy = true;
        notes.Visibility = Visibility.Collapsed;
        title.Text = "Updating LX Book Draw";
        detail.Text = "Please wait. You can carry on looking at the drawing; it is saved before the restart.";
        stepNames = installed
            ? new[] { "Download the new installer", "Check the download", "Save your work and close", "Install into Program Files (Windows asks to allow it), then open" }
            : new[] { "Download the new version", "Check the download", "Put the new version in place", "Save your work and restart" };
        steps.Children.Clear();
        stepLines = stepNames.Select(n => new TextBlock { Text = "○  " + n, Margin = new Thickness(0, 3, 0, 3), Foreground = Brushes.Gray }).ToArray();
        foreach (var l in stepLines) steps.Children.Add(l);
        buttons.Children.Clear();
    }

    public void Step(int i, string state, string note)
    {
        if (i < 0 || i >= stepLines.Length) return;
        var (mark, brush, weight) = state switch
        {
            "now" => ("▶", (Brush)Brushes.Black, FontWeights.SemiBold),
            "done" => ("✓", new SolidColorBrush(Color.FromRgb(0x1B, 0x8A, 0x3A)), FontWeights.Normal),
            "failed" => ("✗", new SolidColorBrush(Color.FromRgb(0xC6, 0x28, 0x28)), FontWeights.SemiBold),
            _ => ("○", (Brush)Brushes.Gray, FontWeights.Normal)
        };
        stepLines[i].Text = $"{mark}  {stepNames[i]}" + (note.Length > 0 ? "  (" + note + ")" : "");
        stepLines[i].Foreground = brush;
        stepLines[i].FontWeight = weight;
        if (state != "now" || i != 0)
        {
            bar.Visibility = Visibility.Collapsed;
            barText.Visibility = Visibility.Collapsed;
        }
    }

    public void Progress(long got, long total, double perSecond)
    {
        bar.Visibility = Visibility.Visible;
        barText.Visibility = Visibility.Visible;
        bar.IsIndeterminate = total <= 0;
        if (total > 0)
        {
            bar.Maximum = total;
            bar.Value = Math.Min(got, total);
        }
        var text = $"{got / 1048576.0:0.0} MB" + (total > 0 ? $" of {total / 1048576.0:0.0} MB ({100.0 * got / total:0}%)" : "");
        if (perSecond > 0)
        {
            text += $" · {perSecond / 1048576.0:0.0} MB/s";
            if (total > got) text += $" · about {Math.Ceiling((total - got) / perSecond):0} s left";
        }
        barText.Text = text;
    }

    public void Problem(string heading, string text, Action? retry = null)
    {
        busy = false;
        bar.Visibility = Visibility.Collapsed;
        barText.Visibility = Visibility.Collapsed;
        title.Text = heading;
        detail.Text = text;
        var list = new System.Collections.Generic.List<(string, Action, bool)>
        {
            ("Open the Release Page", () => { try { Process.Start(new ProcessStartInfo(Updater.Releases) { UseShellExecute = true }); } catch { } }, false),
            ("Close", Close, retry == null)
        };
        if (retry != null) list.Add(("Install", retry, true));
        Buttons(list.ToArray());
    }

    public void Finishing()
    {
        detail.Text = "Closing LX Book Draw. The new version opens by itself in a moment.";
        busy = false;
    }
}
