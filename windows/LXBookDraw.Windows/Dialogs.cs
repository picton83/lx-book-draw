using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace LXBookDrawWin;

/// Small windows that ask for something.
public static class Ask
{
    static Window Frame(Window owner, string title, double width)
    {
        return new Window
        {
            Title = title, Width = width, SizeToContent = SizeToContent.Height, ResizeMode = ResizeMode.NoResize, Owner = owner,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, FontFamily = new FontFamily("Segoe UI"), ShowInTaskbar = false
        };
    }

    public static StackPanel Buttons(Window w, string ok, Action? onOk = null)
    {
        var okB = new Button { Content = ok, IsDefault = true, Padding = new Thickness(16, 4, 16, 4), Margin = new Thickness(6, 0, 0, 0) };
        var cancel = new Button { Content = "Cancel", IsCancel = true, Padding = new Thickness(14, 4, 14, 4) };
        okB.Click += (_, _) =>
        {
            onOk?.Invoke();
            w.DialogResult = true;
        };
        var p = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
        p.Children.Add(cancel);
        p.Children.Add(okB);
        return p;
    }

    public static string? Text(Window owner, string title, string prompt, string initial = "")
    {
        var w = Frame(owner, title, 400);
        var box = new TextBox { Text = initial, Padding = new Thickness(4) };
        var panel = new StackPanel { Margin = new Thickness(16) };
        panel.Children.Add(new TextBlock { Text = prompt, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 6) });
        panel.Children.Add(box);
        panel.Children.Add(Buttons(w, "OK"));
        w.Content = panel;
        w.Loaded += (_, _) => { box.Focus(); box.SelectAll(); };
        return w.ShowDialog() == true ? box.Text : null;
    }

    /// A list to pick from, with a box that filters it as you type. Returns the index picked, or -1.
    public static int Choose(Window owner, string title, string prompt, IList<string> items)
    {
        var w = Frame(owner, title, 440);
        var box = new TextBox { Padding = new Thickness(4) };
        var list = new ListBox { Height = 300, Margin = new Thickness(0, 6, 0, 0) };
        void Fill()
        {
            var f = box.Text.Trim().ToLowerInvariant();
            list.ItemsSource = items.Select((s, i) => (s, i)).Where(x => f.Length == 0 || x.s.ToLowerInvariant().Contains(f)).Select(x => new ListBoxItem { Content = x.s, Tag = x.i }).ToList();
            if (list.Items.Count > 0) list.SelectedIndex = 0;
        }
        box.TextChanged += (_, _) => Fill();
        Fill();
        var panel = new StackPanel { Margin = new Thickness(16) };
        panel.Children.Add(new TextBlock { Text = prompt, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 6) });
        panel.Children.Add(box);
        panel.Children.Add(list);
        panel.Children.Add(Buttons(w, "OK"));
        list.MouseDoubleClick += (_, _) => w.DialogResult = true;
        w.Content = panel;
        w.Loaded += (_, _) => box.Focus();
        box.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == System.Windows.Input.Key.Down && list.SelectedIndex < list.Items.Count - 1) { list.SelectedIndex++; e.Handled = true; }
            if (e.Key == System.Windows.Input.Key.Up && list.SelectedIndex > 0) { list.SelectedIndex--; e.Handled = true; }
        };
        return w.ShowDialog() == true && list.SelectedItem is ListBoxItem it ? (int)it.Tag : -1;
    }

    /// Fixture Label Config (or Motor Label Config): which lines show, their order and their size.
    public static List<JsonObject>? LabelConfig(Window owner, JsonObject d, bool hoist, out double? spacing)
    {
        spacing = null;
        var parts = M.EffectiveLabelParts(d, hoist);
        var w = Frame(owner, hoist ? "Motor Label Config" : "Fixture Label Config", 430);
        var rowsPanel = new StackPanel();
        var names = new Dictionary<string, string>
        {
            ["unit"] = hoist ? "Motor ID" : "Fixture ID", ["patch"] = "Patch (universe/address)", ["circuit"] = "Circuit (power)", ["position"] = "Position",
            ["type"] = "Fixture type", ["note"] = "Note", ["chain"] = "Chain", ["load"] = "Load"
        };
        void Build()
        {
            rowsPanel.Children.Clear();
            for (int i = 0; i < parts.Count; i++)
            {
                var part = parts[i];
                var idx = i;
                var row = new DockPanel { Margin = new Thickness(0, 3, 0, 3) };
                var on = new CheckBox { IsChecked = J.Has(part, "on"), VerticalAlignment = VerticalAlignment.Center, Width = 24 };
                on.Checked += (_, _) => part["on"] = true;
                on.Unchecked += (_, _) => part["on"] = false;
                var size = new TextBox { Text = M.Num(J.D(part, "size", 130)), Width = 60, Padding = new Thickness(2) };
                size.TextChanged += (_, _) => { if (M.ParseNum(size.Text) is double v && v > 0) part["size"] = v; };
                var up = new Button { Content = "▲", Width = 26, Margin = new Thickness(4, 0, 0, 0), IsEnabled = i > 0 };
                var down = new Button { Content = "▼", Width = 26, Margin = new Thickness(2, 0, 0, 0), IsEnabled = i < parts.Count - 1 };
                up.Click += (_, _) => { (parts[idx - 1], parts[idx]) = (parts[idx], parts[idx - 1]); Build(); };
                down.Click += (_, _) => { (parts[idx + 1], parts[idx]) = (parts[idx], parts[idx + 1]); Build(); };
                DockPanel.SetDock(on, Dock.Left);
                DockPanel.SetDock(down, Dock.Right);
                DockPanel.SetDock(up, Dock.Right);
                DockPanel.SetDock(size, Dock.Right);
                row.Children.Add(on);
                row.Children.Add(down);
                row.Children.Add(up);
                row.Children.Add(size);
                row.Children.Add(new TextBlock { Text = names.GetValueOrDefault(J.S(part, "field"), J.S(part, "field")), VerticalAlignment = VerticalAlignment.Center });
                rowsPanel.Children.Add(row);
            }
        }
        Build();
        var panel = new StackPanel { Margin = new Thickness(16) };
        panel.Children.Add(new TextBlock { Text = "Tick the lines to show, top line first. Sizes are text heights in millimetres on the drawing.", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8) });
        panel.Children.Add(rowsPanel);
        TextBox? room = null;
        if (!hoist)
        {
            room = new TextBox { Text = M.Num(J.D(d, "labelSpacing")), Width = 60, Padding = new Thickness(2), HorizontalAlignment = HorizontalAlignment.Left };
            panel.Children.Add(new TextBlock { Text = "Space kept between labels (mm), for the automatic layout:", Margin = new Thickness(0, 10, 0, 3) });
            panel.Children.Add(room);
        }
        panel.Children.Add(Buttons(w, "OK"));
        w.Content = panel;
        if (w.ShowDialog() != true) return null;
        if (room != null && M.ParseNum(room.Text) is double sp && sp >= 0) spacing = sp;
        return parts;
    }

    /// The title block: show, title, designer, venue, drawn by, version, date.
    public static JsonObject? TitleBlock(Window owner, JsonObject info)
    {
        var w = Frame(owner, "Title Block", 420);
        var fields = new[] { ("show", "Show"), ("drawingTitle", "Drawing title"), ("designer", "Lighting designer"), ("venue", "Venue"), ("drawnBy", "Drawn by"), ("version", "Version"), ("date", "Date") };
        var boxes = new Dictionary<string, TextBox>();
        var grid = new Grid { Margin = new Thickness(16) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(130) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        for (int i = 0; i < fields.Length; i++)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var label = new TextBlock { Text = fields[i].Item2, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 4, 0, 4) };
            var box = new TextBox { Text = J.S(info, fields[i].Item1), Padding = new Thickness(3), Margin = new Thickness(0, 3, 0, 3) };
            Grid.SetRow(label, i);
            Grid.SetRow(box, i);
            Grid.SetColumn(box, 1);
            grid.Children.Add(label);
            grid.Children.Add(box);
            boxes[fields[i].Item1] = box;
        }
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var b = Buttons(w, "OK");
        Grid.SetRow(b, fields.Length);
        Grid.SetColumnSpan(b, 2);
        grid.Children.Add(b);
        w.Content = grid;
        if (w.ShowDialog() != true) return null;
        var outp = (JsonObject)info.DeepClone();
        foreach (var (k, box) in boxes) outp[k] = box.Text;
        return outp;
    }

    /// A read-only list in its own window (the change log, the command history), with search and Export.
    public static void ShowList(Window owner, string title, IList<string> lines)
    {
        var w = new Window { Title = title, Width = 760, Height = 560, Owner = owner, WindowStartupLocation = WindowStartupLocation.CenterOwner, FontFamily = new FontFamily("Segoe UI") };
        var search = new TextBox { Padding = new Thickness(4), Margin = new Thickness(0, 0, 0, 6) };
        var list = new ListBox { FontFamily = new FontFamily("Consolas"), FontSize = 12 };
        void Fill()
        {
            var f = search.Text.Trim().ToLowerInvariant();
            list.ItemsSource = lines.Where(l => f.Length == 0 || l.ToLowerInvariant().Contains(f)).ToList();
            if (list.Items.Count > 0) list.ScrollIntoView(list.Items[^1]);
        }
        search.TextChanged += (_, _) => Fill();
        Fill();
        var export = new Button { Content = "Export…", Padding = new Thickness(12, 4, 12, 4), HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 6, 0, 0) };
        export.Click += (_, _) =>
        {
            var dlg = new Microsoft.Win32.SaveFileDialog { Filter = "Text (*.txt)|*.txt", FileName = title + ".txt" };
            if (dlg.ShowDialog(w) == true) File.WriteAllLines(dlg.FileName, lines);
        };
        var dock = new DockPanel { Margin = new Thickness(12) };
        DockPanel.SetDock(search, Dock.Top);
        DockPanel.SetDock(export, Dock.Bottom);
        dock.Children.Add(search);
        dock.Children.Add(export);
        dock.Children.Add(list);
        w.Content = dock;
        w.Show();
    }
}

/// Improvement notes, as on the Mac: written where you are, kept on this PC, exported for Claude.
public static class NoteStore
{
    public static readonly string[] Kinds = { "Bug", "Idea", "Change", "Question" };

    public static string Dir
    {
        get
        {
            var d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LX Book Draw", "notes");
            Directory.CreateDirectory(d);
            return d;
        }
    }

    static string FilePath => Path.Combine(Dir, "notes.json");

    public static List<JsonObject> Load()
    {
        try
        {
            if (JsonNode.Parse(File.ReadAllText(FilePath)) is JsonArray a) return a.OfType<JsonObject>().ToList();
        }
        catch { }
        return new List<JsonObject>();
    }

    public static void Save(List<JsonObject> notes) =>
        File.WriteAllText(FilePath, new JsonArray(notes.Select(n => (JsonNode)n.DeepClone()).ToArray()).ToJsonString(new JsonSerializerOptions { WriteIndented = true }));

    public static void Add(string kind, string text, List<string> context, BitmapSource? shot)
    {
        var id = Guid.NewGuid().ToString().ToUpperInvariant();
        var note = new JsonObject
        {
            ["id"] = id, ["ts"] = DateTime.Now.ToString("yyyy-MM-dd HH:mm"), ["kind"] = Kinds.Contains(kind) ? kind : "Idea",
            ["text"] = text.Length > 5000 ? text[..5000] : text, ["context"] = new JsonArray(context.Take(12).Select(c => (JsonNode)c!).ToArray()),
            ["version"] = $"{AppInfo.Version} build {AppInfo.Build} (Windows)", ["done"] = false
        };
        if (shot != null)
        {
            var name = "note-" + id[..8] + ".png";
            try
            {
                var enc = new PngBitmapEncoder();
                enc.Frames.Add(BitmapFrame.Create(shot));
                using var f = File.Create(Path.Combine(Dir, name));
                enc.Save(f);
                note["shot"] = name;
            }
            catch { }
        }
        var all = Load();
        all.Insert(0, note);
        Save(all);
    }

    public static string Markdown(List<JsonObject> notes)
    {
        var sb = new StringBuilder();
        sb.Append("# LX Book Draw improvement notes\n\n");
        sb.Append($"Please work through these improvement notes for LX Book Draw for Windows (currently version {AppInfo.Version} build {AppInfo.Build}). ");
        sb.Append("They were written in the app; each one says what was on screen at the time.\n\n");
        sb.Append($"Exported {DateTime.Now:yyyy-MM-dd} · {notes.Count} note{(notes.Count == 1 ? "" : "s")}.\n\n");
        for (int i = 0; i < notes.Count; i++)
        {
            var n = notes[i];
            var lines = J.S(n, "text").Split('\n');
            sb.Append($"{i + 1}. **{J.S(n, "kind")}**: {lines[0]}\n");
            foreach (var extra in lines.Skip(1)) sb.Append($"   {extra}\n");
            var ctx = J.A(n, "context").Select(c => J.Txt(c)).ToList();
            if (ctx.Count > 0)
            {
                sb.Append("   Where in the app:\n");
                foreach (var c in ctx) sb.Append($"   - {c}\n");
            }
            if (J.S(n, "shot").Length > 0) sb.Append($"   Screenshot: {J.S(n, "shot")}\n");
            sb.Append($"   _({J.S(n, "ts")} · v{J.S(n, "version")})_\n\n");
        }
        return sb.ToString();
    }

    public static void Write(Window owner, List<string> context, BitmapSource? shot)
    {
        var w = new Window
        {
            Title = "Write an Improvement Note", Width = 520, SizeToContent = SizeToContent.Height, ResizeMode = ResizeMode.NoResize, Owner = owner,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, FontFamily = new FontFamily("Segoe UI")
        };
        var kind = new ComboBox { ItemsSource = Kinds, SelectedIndex = 0, Width = 140, HorizontalAlignment = HorizontalAlignment.Left };
        var text = new TextBox { Height = 160, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new Thickness(0, 8, 0, 0), Padding = new Thickness(4) };
        var include = new CheckBox { Content = "Save where I am in the app with the note", IsChecked = true, Margin = new Thickness(0, 8, 0, 0) };
        var withShot = new CheckBox { Content = "Include a screenshot of the window", IsChecked = shot != null, IsEnabled = shot != null, Margin = new Thickness(0, 4, 0, 0) };
        var where = new TextBlock { Text = string.Join("\n", context), Foreground = Brushes.Gray, FontSize = 11, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(18, 2, 0, 0) };
        var panel = new StackPanel { Margin = new Thickness(16) };
        panel.Children.Add(kind);
        panel.Children.Add(text);
        panel.Children.Add(include);
        panel.Children.Add(where);
        panel.Children.Add(withShot);
        panel.Children.Add(Ask.Buttons(w, "Save Note"));
        w.Content = panel;
        w.Loaded += (_, _) => text.Focus();
        if (w.ShowDialog() != true || text.Text.Trim().Length == 0) return;
        Add((string)kind.SelectedItem, text.Text.Trim(), include.IsChecked == true ? context : new List<string>(), withShot.IsChecked == true ? shot : null);
    }

    public static void ShowList(Window owner)
    {
        var w = new Window { Title = "Improvement Notes", Width = 680, Height = 520, Owner = owner, WindowStartupLocation = WindowStartupLocation.CenterOwner, FontFamily = new FontFamily("Segoe UI") };
        var list = new ListBox { SelectionMode = SelectionMode.Extended };
        var status = new TextBlock { Foreground = Brushes.Gray, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) };
        List<JsonObject> notes = new();
        void Reload()
        {
            notes = Load();
            list.ItemsSource = notes.Select(n => new ListBoxItem
            {
                Content = new TextBlock
                {
                    Text = (J.IsTrue(n, "done") ? "✓ Done · " : "") + J.S(n, "ts") + " · " + J.S(n, "kind") + (J.S(n, "shot").Length > 0 ? " · 📷" : "") + "\n" + J.S(n, "text").Replace("\n", " "),
                    TextWrapping = TextWrapping.Wrap, MaxWidth = 600, Foreground = J.IsTrue(n, "done") ? Brushes.Gray : Brushes.Black
                },
                Tag = J.S(n, "id")
            }).ToList();
        }
        Reload();
        HashSet<string> Picked() => list.SelectedItems.OfType<ListBoxItem>().Select(i => (string)i.Tag).ToHashSet();
        Button B(string t, Action a)
        {
            var b = new Button { Content = t, Padding = new Thickness(10, 4, 10, 4), Margin = new Thickness(0, 0, 6, 0) };
            b.Click += (_, _) => a();
            return b;
        }
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
        bar.Children.Add(B("Write a Note…", () => { Write(w, new List<string> { "Notes window" }, null); Reload(); }));
        bar.Children.Add(B("Copy for Claude", () =>
        {
            var open = notes.Where(n => !J.IsTrue(n, "done")).ToList();
            if (open.Count == 0) { status.Text = "There are no open notes to copy."; return; }
            Clipboard.SetText(Markdown(open));
            status.Text = $"Copied {open.Count} notes. Paste them into your chat with Claude." + (open.Any(n => J.S(n, "shot").Length > 0) ? " Some have screenshots: use Export and attach the pictures too." : "");
        }));
        bar.Children.Add(B("Export…", () =>
        {
            var open = notes.Where(n => !J.IsTrue(n, "done")).ToList();
            var dlg = new Microsoft.Win32.OpenFolderDialog { Title = "Choose where to put the notes (they go in a new folder named with the date and time)" };
            if (dlg.ShowDialog(w) != true) return;
            var stamp = DateTime.Now.ToString("yyyy-MM-dd HHmm");
            var folder = Path.Combine(dlg.FolderName, "LX Book Draw notes " + stamp);
            Directory.CreateDirectory(folder);
            File.WriteAllText(Path.Combine(folder, $"LX Book Draw improvement notes {stamp}.md"), Markdown(open));
            foreach (var n in open.Where(n => J.S(n, "shot").Length > 0))
                try { File.Copy(Path.Combine(Dir, J.S(n, "shot")), Path.Combine(folder, J.S(n, "shot")), true); } catch { }
            status.Text = $"Exported {open.Count} notes and their screenshots to \"{Path.GetFileName(folder)}\". Attach its files to your chat with Claude.";
            try { Process.Start(new ProcessStartInfo("explorer.exe", "\"" + folder + "\"") { UseShellExecute = true }); } catch { }
        }));
        bar.Children.Add(B("Done / Not Done", () =>
        {
            var ids = Picked();
            var all = Load();
            foreach (var n in all.Where(n => ids.Contains(J.S(n, "id")))) n["done"] = !J.IsTrue(n, "done");
            Save(all);
            Reload();
        }));
        bar.Children.Add(B("Delete", () =>
        {
            var ids = Picked();
            if (ids.Count == 0) return;
            var all = Load();
            foreach (var n in all.Where(n => ids.Contains(J.S(n, "id")) && J.S(n, "shot").Length > 0)) try { File.Delete(Path.Combine(Dir, J.S(n, "shot"))); } catch { }
            Save(all.Where(n => !ids.Contains(J.S(n, "id"))).ToList());
            Reload();
        }));
        bar.Children.Add(B("Screenshot", () =>
        {
            var n = notes.FirstOrDefault(x => Picked().Contains(J.S(x, "id")));
            if (n == null || J.S(n, "shot").Length == 0) { status.Text = "That note has no screenshot."; return; }
            try { Process.Start(new ProcessStartInfo(Path.Combine(Dir, J.S(n, "shot"))) { UseShellExecute = true }); } catch { }
        }));
        var dock = new DockPanel { Margin = new Thickness(12) };
        DockPanel.SetDock(status, Dock.Bottom);
        DockPanel.SetDock(bar, Dock.Bottom);
        dock.Children.Add(status);
        dock.Children.Add(bar);
        dock.Children.Add(list);
        w.Content = dock;
        w.Show();
    }
}
