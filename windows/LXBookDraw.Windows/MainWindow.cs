using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;

namespace LXBookDrawWin;

/// LX Book Draw for Windows: the same drawing as the Mac app, kept in the Lx Book show, edited AutoCAD style.
public sealed class MainWindow : Window, ICanvasHost, ISyncHost
{
    static readonly Brush Dark = Hex("#1E2228"), DarkLine = Hex("#2E333B"), Accent = Hex("#E5484D"), Light = Hex("#F4F5F7"),
        Muted = Hex("#9AA3AD"), Ink = Hex("#1E2228"), Line = Hex("#DADDE2"), Panel = Hex("#FFFFFF"), DarkField = Hex("#2A2F37");

    readonly Account account = Account.Load();
    readonly LxClient lx;
    LxSync? sync;
    public DrawDoc? Doc { get; private set; }
    readonly DrawCanvas canvas;
    readonly Settings settings = Settings.Load();

    // side panel
    readonly TextBlock docName = new() { Foreground = Brushes.White, FontSize = 13, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(16, 12, 16, 2) };
    readonly TextBlock docWhere = new() { Foreground = Muted, FontSize = 11, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(16, 0, 16, 8) };
    readonly Button layerButton;
    readonly Popup layerPopup = new() { StaysOpen = false, Placement = PlacementMode.Right, AllowsTransparency = true };
    readonly ComboBox scenes = new();
    readonly ComboBox fixtureTypes = new();
    readonly ComboBox trussTypes = new();
    readonly StackPanel props = new() { Margin = new Thickness(12) };

    // top bar
    readonly TextBlock lxStatus = new() { Foreground = Muted, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 420, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(8, 0, 8, 0) };
    readonly Button signButton;
    readonly Button undoButton, redoButton;

    // command line
    readonly StackPanel logLines = new();
    readonly List<(string Text, string Kind)> log = new();
    readonly TextBlock prompt = new() { FontFamily = new FontFamily("Consolas"), FontSize = 13, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 6, 0) };
    readonly TextBox commandBox = new() { FontFamily = new FontFamily("Consolas"), FontSize = 13, BorderThickness = new Thickness(0), VerticalContentAlignment = VerticalAlignment.Center, Background = Brushes.Transparent };
    readonly TextBlock coords = new() { FontFamily = new FontFamily("Consolas"), FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Width = 150, Margin = new Thickness(10, 0, 0, 0) };
    readonly Dictionary<string, ToggleButton> toggles = new();
    readonly StackPanel tabs = new() { Orientation = Orientation.Horizontal };
    readonly Grid startPanel = new();

    string activeLayer = "";
    string currentFixtureType = "generic";
    string currentTrussType = "lopro-2.5";
    readonly DispatcherTimer sideRefresh = new() { Interval = TimeSpan.FromMilliseconds(200) };
    bool building;
    bool closing;

    public string ActiveLayer
    {
        get
        {
            if (Doc == null) return "";
            if (M.Layer(Doc.D, activeLayer) == null) activeLayer = J.S(J.Objs(Doc.D, "layers").FirstOrDefault(), "id");
            return activeLayer;
        }
    }

    public string CurrentFixtureType => currentFixtureType;
    public string CurrentTrussType => currentTrussType;
    public string ShowName => sync?.ShowName ?? J.S(J.G(Doc?.D, "lxBook"), "showName");
    Window ISyncHost.Owner => this;

    public MainWindow(string? openPath)
    {
        lx = new LxClient(account);
        canvas = new DrawCanvas(this) { Osnap = settings.Osnap, Ortho = settings.Ortho, ShowGrid = settings.Grid };
        prompt.Foreground = Ink;
        coords.Foreground = Muted;
        startPanel.Background = Hex("#5A6068");
        Title = "LX Book Draw";
        Width = Math.Min(1600, SystemParameters.WorkArea.Width - 20);
        Height = Math.Min(1000, SystemParameters.WorkArea.Height - 20);
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = Light;
        FontFamily = new FontFamily("Segoe UI");
        UseLayoutRounding = true;

        // ---- dark side panel
        var side = new StackPanel();
        side.Children.Add(new TextBlock { Text = "LX BOOK DRAW", Foreground = Brushes.White, FontSize = 16, FontWeight = FontWeights.Bold, Margin = new Thickness(16, 16, 16, 0) });
        side.Children.Add(new TextBlock { Text = AppInfo.Version + " · build " + AppInfo.Build + " · Windows", Foreground = Muted, FontSize = 11, Margin = new Thickness(16, 2, 16, 10) });
        side.Children.Add(new Border { Height = 3, Background = Accent, Margin = new Thickness(16, 0, 16, 0), HorizontalAlignment = HorizontalAlignment.Left, Width = 40 });
        side.Children.Add(docName);
        side.Children.Add(docWhere);
        layerButton = SideButton("Layer", () => OpenLayers());
        side.Children.Add(SideLabel("LAYER"));
        side.Children.Add(layerButton);
        side.Children.Add(SideLabel("SCENE"));
        StyleCombo(scenes);
        scenes.SelectionChanged += (_, _) => SceneChosen();
        side.Children.Add(scenes);
        side.Children.Add(SideLabel("FIXTURE"));
        StyleCombo(fixtureTypes);
        fixtureTypes.SelectionChanged += (_, _) =>
        {
            if (!building && fixtureTypes.SelectedItem is ComboBoxItem it) currentFixtureType = (string)it.Tag;
        };
        side.Children.Add(fixtureTypes);
        side.Children.Add(SideButton("Place Fixtures (FX)", () => RunCommand("fx")));
        side.Children.Add(SideLabel("TRUSS"));
        StyleCombo(trussTypes);
        foreach (var id in PlotPdf.TrussOrder) trussTypes.Items.Add(new ComboBoxItem { Content = PlotPdf.Truss[id].Name, Tag = id });
        trussTypes.SelectedIndex = 0;
        trussTypes.SelectionChanged += (_, _) => { if (trussTypes.SelectedItem is ComboBoxItem it) currentTrussType = (string)it.Tag; };
        side.Children.Add(trussTypes);
        side.Children.Add(SideButton("Draw Truss (TR)", () => RunCommand("tr")));
        side.Children.Add(SideLabel("QUICK"));
        var quick = new WrapPanel { Margin = new Thickness(12, 0, 12, 12) };
        foreach (var (label, cmd) in new[] { ("Line", "l"), ("Rect", "rec"), ("Circle", "c"), ("Text", "t"), ("Move", "m"), ("Copy", "co"), ("Rotate", "ro"), ("Erase", "e"), ("Label", "lb"), ("Measure", "di") })
            quick.Children.Add(Chip(label, () => RunCommand(cmd)));
        side.Children.Add(quick);
        var sideScroll = new ScrollViewer { Content = side, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Background = Dark, Width = 236 };

        // ---- light top bar with the ribbon's drop-down menus
        var bar = new DockPanel { Background = Brushes.White, Height = 44 };
        var left = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 0, 0) };
        left.Children.Add(MenuButton("File", FileMenu));
        left.Children.Add(MenuButton("Draw", () => Menu(("Line  L", "l"), ("Polyline  PL", "pl"), ("Rectangle  REC", "rec"), ("Circle  C", "c"), ("Text  T", "t"))));
        left.Children.Add(MenuButton("Lighting", LightingMenu));
        left.Children.Add(MenuButton("Modify", () => Menu(("Move  M", "m"), ("Copy  CO", "co"), ("Rotate  RO", "ro"), ("Scale  SC", "sc"), ("Erase  E", "e"), ("-", ""), ("Group  G", "g"), ("Ungroup  UG", "ug"), ("-", ""), ("Select All  Ctrl+A", "@selectall"))));
        left.Children.Add(MenuButton("Sheets", SheetsMenu));
        left.Children.Add(MenuButton("Tools", () => Menu(("Measure Distance  DI", "di"), ("-", ""), ("Write a Note…  NOTE", "note"), ("Improvement Notes…  NOTES", "notes"), ("Change Log  LOG", "log"), ("Command Line Window", "cmdlog"), ("-", ""), ("Check for Updates", "update"))));
        left.Children.Add(MenuButton("View", () => Menu(("Zoom Extents  ZE", "ze"), ("Zoom Window  Z W", "@zoomwindow"), ("-", ""), ("Grid  F7", "grid"), ("Object Snap  F3", "os"), ("Ortho  F8", "ortho"))));
        undoButton = TopButton("↶ Undo", () => { Doc?.Undo(); FocusCommand(); });
        redoButton = TopButton("↷ Redo", () => { Doc?.Redo(); FocusCommand(); });
        left.Children.Add(new Border { Width = 1, Background = Line, Margin = new Thickness(8, 10, 8, 10) });
        left.Children.Add(undoButton);
        left.Children.Add(redoButton);
        var right = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
        right.Children.Add(lxStatus);
        signButton = TopButton("Sign In…", async () => await SignInOrOut());
        right.Children.Add(TopButton("✎ Note", () => WriteNote()));
        right.Children.Add(signButton);
        DockPanel.SetDock(left, Dock.Left);
        DockPanel.SetDock(right, Dock.Right);
        bar.Children.Add(left);
        bar.Children.Add(right);
        bar.Children.Add(new Border());

        // ---- the bottom: tabs, command history, command line, status line
        var tabBar = new Border { Background = Light, BorderBrush = Line, BorderThickness = new Thickness(0, 1, 0, 1), Height = 30, Child = new ScrollViewer { Content = tabs, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled } };
        var logBox = new Border { Background = Brushes.White, Height = 78, Padding = new Thickness(8, 4, 8, 2), Child = logLines };
        var cmdRow = new DockPanel { Background = Brushes.White, Height = 30 };
        DockPanel.SetDock(prompt, Dock.Left);
        cmdRow.Children.Add(prompt);
        cmdRow.Children.Add(commandBox);
        var cmdBorder = new Border { BorderBrush = Line, BorderThickness = new Thickness(0, 1, 0, 0), Child = cmdRow };
        var statusRow = new DockPanel { Background = Dark, Height = 28 };
        var statusLeft = new StackPanel { Orientation = Orientation.Horizontal };
        statusLeft.Children.Add(coords);
        foreach (var t in new[] { "GRID", "SNAP", "ORTHO", "OSNAP" })
        {
            var b = new ToggleButton { Content = t, Margin = new Thickness(2, 3, 2, 3), Padding = new Thickness(8, 0, 8, 0), FontSize = 11, Foreground = Brushes.White, Background = DarkField, BorderBrush = DarkLine, Cursor = Cursors.Hand };
            var name = t;
            b.Click += (_, _) => Toggle(name);
            toggles[t] = b;
            statusLeft.Children.Add(b);
        }
        var logButton = new Button { Content = "Log", Margin = new Thickness(6, 3, 6, 3), Padding = new Thickness(10, 0, 10, 0), FontSize = 11, Foreground = Brushes.White, Background = DarkField, BorderBrush = DarkLine };
        logButton.Click += (_, _) => AppCommand("cmdlog");
        DockPanel.SetDock(statusLeft, Dock.Left);
        DockPanel.SetDock(logButton, Dock.Right);
        statusRow.Children.Add(statusLeft);
        statusRow.Children.Add(logButton);
        statusRow.Children.Add(new Border());

        var bottom = new StackPanel();
        bottom.Children.Add(tabBar);
        bottom.Children.Add(logBox);
        bottom.Children.Add(cmdBorder);
        bottom.Children.Add(statusRow);

        // ---- start panel (nothing open)
        var start = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        start.Children.Add(new TextBlock { Text = "Open a show's drawing from Lx Book, or a drawing file.", Foreground = Brushes.White, FontSize = 15, Margin = new Thickness(0, 0, 0, 14), HorizontalAlignment = HorizontalAlignment.Center });
        foreach (var (label, act) in new (string, Func<Task>)[]
                 {
                     ("Open Show from Lx Book…", OpenShowFromLx), ("Open Drawing File…", OpenFile), ("New Drawing", () => { NewDrawing(); return Task.CompletedTask; })
                 })
        {
            var b = new Button { Content = label, Width = 260, Padding = new Thickness(10, 7, 10, 7), Margin = new Thickness(0, 4, 0, 4), FontSize = 13 };
            b.Click += async (_, _) => await act();
            start.Children.Add(b);
        }
        startPanel.Children.Add(start);

        var centre = new Grid();
        centre.Children.Add(canvas);
        centre.Children.Add(startPanel);
        var middle = new DockPanel();
        DockPanel.SetDock(bottom, Dock.Bottom);
        middle.Children.Add(bottom);
        middle.Children.Add(centre);

        var propScroll = new ScrollViewer { Content = props, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Width = 270, Background = Panel };
        var propBorder = new Border { BorderBrush = Line, BorderThickness = new Thickness(1, 0, 0, 0), Child = propScroll };

        var body = new DockPanel();
        DockPanel.SetDock(sideScroll, Dock.Left);
        DockPanel.SetDock(propBorder, Dock.Right);
        body.Children.Add(sideScroll);
        body.Children.Add(propBorder);
        body.Children.Add(middle);

        var root = new DockPanel();
        var barLine = new Border { Height = 1, Background = Line };
        DockPanel.SetDock(bar, Dock.Top);
        DockPanel.SetDock(barLine, Dock.Top);
        root.Children.Add(bar);
        root.Children.Add(barLine);
        root.Children.Add(body);
        Content = root;

        commandBox.KeyDown += CommandKey;
        commandBox.PreviewKeyDown += (_, e) => { if (e.Key == Key.Space) CommandKey(commandBox, e); };
        PreviewKeyDown += WindowKey;
        sideRefresh.Tick += (_, _) =>
        {
            sideRefresh.Stop();
            RefreshSide();
        };
        Closing += async (_, e) =>
        {
            if (closing) return;
            e.Cancel = true;
            closing = true;
            // anything not yet sent to Lx Book goes now (waiting a few seconds at most)
            if (sync != null)
            {
                try { await Task.WhenAny(sync.Flush(), Task.Delay(5000)); } catch { }
                sync.Stop();
            }
            try { Doc?.SaveNow(); } catch { }
            settings.Osnap = canvas.Osnap;
            settings.Ortho = canvas.Ortho;
            settings.Grid = canvas.ShowGrid;
            settings.Save();
            Close();
        };
        SourceInitialized += (_, _) =>
        {
            // Windows sends sideways two-finger scrolling as its own message, which WPF doesn't pass on
            if (System.Windows.Interop.HwndSource.FromHwnd(new System.Windows.Interop.WindowInteropHelper(this).Handle) is System.Windows.Interop.HwndSource src)
                src.AddHook((IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled) =>
                {
                    const int WM_MOUSEHWHEEL = 0x020E;
                    if (msg == WM_MOUSEHWHEEL && canvas.IsMouseOver && Doc != null)
                    {
                        canvas.HorizontalWheel((short)((wParam.ToInt64() >> 16) & 0xFFFF));
                        handled = true;
                    }
                    return IntPtr.Zero;
                });
        };
        Loaded += async (_, _) =>
        {
            Log("LX Book Draw for Windows " + AppInfo.Version + ". Type a command (HELP for the list), or use the menus.");
            if (!string.IsNullOrEmpty(openPath) && File.Exists(openPath)) OpenPath(openPath);
            else ReopenLast();
            RefreshAll();
            FocusCommand();
            await Updater.Check(this, false);
        };
    }

    // ---------------------------------------------------------------- small builders

    static SolidColorBrush Hex(string h) => (SolidColorBrush)new BrushConverter().ConvertFromString(h)!;

    static TextBlock SideLabel(string t) => new() { Text = t, Foreground = Muted, FontSize = 11, FontWeight = FontWeights.SemiBold, Margin = new Thickness(16, 14, 16, 4) };

    static void StyleCombo(ComboBox c)
    {
        c.Margin = new Thickness(14, 0, 14, 4);
        c.Padding = new Thickness(6, 4, 6, 4);
        c.FontSize = 12;
    }

    Button SideButton(string text, Action act)
    {
        var b = new Button
        {
            Content = text, Margin = new Thickness(14, 2, 14, 4), Padding = new Thickness(8, 5, 8, 5), HorizontalContentAlignment = HorizontalAlignment.Left,
            Foreground = Brushes.White, Background = DarkField, BorderBrush = DarkLine, Cursor = Cursors.Hand, FontSize = 12
        };
        b.Click += (_, _) => act();
        return b;
    }

    Button Chip(string text, Action act)
    {
        var b = new Button { Content = text, Margin = new Thickness(2), Padding = new Thickness(8, 3, 8, 3), Foreground = Brushes.White, Background = DarkField, BorderBrush = DarkLine, FontSize = 11, Cursor = Cursors.Hand };
        b.Click += (_, _) => act();
        return b;
    }

    Button TopButton(string text, Action act)
    {
        var b = new Button { Content = text, Margin = new Thickness(2, 0, 2, 0), Padding = new Thickness(10, 5, 10, 5), Background = Brushes.White, BorderBrush = Hex("#D0D4DA"), Foreground = Ink, Cursor = Cursors.Hand };
        b.Click += (_, _) => act();
        return b;
    }

    Button TopButton(string text, Func<Task> act)
    {
        var b = TopButton(text, () => { });
        b.Click += async (_, _) => await act();
        return b;
    }

    Button? lastMenuButton;

    Button MenuButton(string text, Action open)
    {
        var b = new Button { Content = text + " ▾", Margin = new Thickness(1, 0, 1, 0), Padding = new Thickness(10, 5, 10, 5), Background = Brushes.Transparent, BorderThickness = new Thickness(0), Foreground = Ink, Cursor = Cursors.Hand, FontWeight = FontWeights.SemiBold };
        b.Click += (_, _) =>
        {
            lastMenuButton = b;
            open();
        };
        return b;
    }

    /// A drop-down of commands: each item runs its command as if typed ("@..." are actions of this window).
    void Menu(params (string Label, string Cmd)[] items)
    {
        var menu = new ContextMenu { PlacementTarget = lastMenuButton, Placement = PlacementMode.Bottom };
        foreach (var (label, cmd) in items)
        {
            if (label == "-")
            {
                menu.Items.Add(new Separator());
                continue;
            }
            var mi = new MenuItem { Header = label.Replace("_", "__") };
            var c = cmd;
            mi.Click += (_, _) => RunCommand(c);
            menu.Items.Add(mi);
        }
        menu.IsOpen = true;
    }

    void FileMenu()
    {
        var inShow = Doc?.InShow == true;
        Menu(("Open Show from Lx Book…", "@openshow"), ("Open Drawing File…  Ctrl+O", "@open"), ("New Drawing", "@new"), ("-", ""),
             ("Save  Ctrl+S", "save"), (inShow ? "Export Drawing File…" : "Save As…", "@saveas"),
             ("Move This Drawing into the Lx Book Show…", "@moveinto"), ("-", ""), ("Export PDF…  Ctrl+P", "pdf"), ("Title Block…", "@title"), ("-", ""),
             (account.SignedIn ? "Sign Out of Lx Book" : "Sign In to Lx Book…", "@sign"), ("Check for Updates", "update"), ("Exit", "@exit"));
    }

    void LightingMenu() => Menu(("Place Fixtures  FX", "fx"), ("Draw Truss  TR", "tr"), ("Insert Location Label  LOC", "loc"), ("-", ""),
                                ("Move Label  LB", "lb"), ("Move Labels Mode  ML", "ml"), ("Fixture Label Config  LC", "lc"), ("Motor Label Config  MLC", "mlc"),
                                ("Automatic Labels On/Off", "autolabel"), ("Show Labels On/Off", "@labels"), ("Label Background On/Off", "@labelback"), ("-", ""),
                                ("Next Fixture Number…", "@nextunit"));

    void SheetsMenu() => Menu(("New Sheet", "@newsheet"), ("New Sheet per Scene", "@sheetperscene"), ("-", ""), ("Layout: One Viewport", "@grid11"),
                              ("Layout: Two Side by Side", "@grid21"), ("Layout: Two Top and Bottom", "@grid12"), ("Layout: Four", "@grid22"), ("-", ""),
                              ("Make a Viewport  MV", "mv"), ("Rename Sheet…", "@renamesheet"), ("Delete Sheet", "@deletesheet"), ("Back to the Model", "@model"));

    // ---------------------------------------------------------------- log, prompt and command line

    public void Log(string text, string kind = "note")
    {
        foreach (var line in text.Split('\n'))
        {
            log.Add((line, kind));
            if (log.Count > 3000) log.RemoveAt(0);
        }
        logLines.Children.Clear();
        foreach (var (t, k) in log.Skip(Math.Max(0, log.Count - 4)))
            logLines.Children.Add(new TextBlock
            {
                Text = t, FontFamily = new FontFamily("Consolas"), FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis,
                Foreground = k switch { "cmd" => Ink, "lx" => Hex("#1F5FD0"), "problem" => Hex("#C62828"), "measure" => Hex("#1B8A3A"), _ => Hex("#555B63") },
                FontWeight = k == "cmd" ? FontWeights.SemiBold : FontWeights.Normal
            });
    }

    public void SetPrompt(string text) => prompt.Text = text;
    public void SetCoords(double x, double y) => coords.Text = $"{x:0}, {y:0}";

    void FocusCommand()
    {
        if (!ReferenceEquals(Keyboard.FocusedElement, commandBox)) commandBox.Focus();
    }

    /// Runs a command from a menu or button exactly as if it had been typed.
    public void RunCommand(string name)
    {
        if (name.Length == 0) return;
        if (name.StartsWith('@'))
        {
            _ = Action(name[1..]);
            FocusCommand();
            return;
        }
        if (Doc == null && !IsAppOnly(name))
        {
            Log("Open a drawing first (File menu).", "problem");
            return;
        }
        Log("Command: " + name.ToUpperInvariant(), "cmd");
        if (Doc != null && canvas.Command != Cmd.None) canvas.Escape();
        var done = Doc != null && canvas.Run(name);
        if (!done && !AppCommand(name)) Log($"Unknown command \"{name}\".", "problem");
        FocusCommand();
    }

    static bool IsAppOnly(string n) => n is "update" or "updates" or "note" or "notes" or "cmdlog" or "help";

    void CommandKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter || (e.Key == Key.Space && !canvas.WantsFreeText))
        {
            var text = commandBox.Text;
            commandBox.Clear();
            e.Handled = true;
            if (Doc == null)
            {
                var t = text.Trim().ToLowerInvariant();
                if (t.Length > 0 && !AppCommand(t)) Log("Open a drawing first (File menu).", "problem");
                return;
            }
            if (text.Trim().Length > 0)
            {
                if (canvas.Command == Cmd.None) Log("Command: " + text.Trim().ToUpperInvariant(), "cmd");
                else Log(prompt.Text + " " + text.Trim());
            }
            canvas.Enter(text);
        }
        else if (e.Key == Key.Up && commandBox.Text.Length == 0)
        {
            var last = log.LastOrDefault(l => l.Kind == "cmd" && l.Text.StartsWith("Command: "));
            if (last.Text != null) commandBox.Text = last.Text["Command: ".Length..].ToLowerInvariant();
            commandBox.CaretIndex = commandBox.Text.Length;
            e.Handled = true;
        }
    }

    void WindowKey(object sender, KeyEventArgs e)
    {
        var focused = Keyboard.FocusedElement;
        var inField = (focused is TextBox tb && !ReferenceEquals(tb, commandBox)) || focused is ComboBox || focused is PasswordBox;
        if (e.Key == Key.Escape)
        {
            if (inField) FocusCommand();
            commandBox.Clear();
            canvas.Escape();
            e.Handled = true;
            return;
        }
        if (inField) return;
        var ctrl = Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
        if (ctrl)
        {
            switch (e.Key)
            {
                case Key.Z: Doc?.Undo(); e.Handled = true; return;
                case Key.Y: Doc?.Redo(); e.Handled = true; return;
                case Key.S: _ = Save(); e.Handled = true; return;
                case Key.O: _ = OpenFile(); e.Handled = true; return;
                case Key.P: AppCommand("pdf"); e.Handled = true; return;
                case Key.C: CopySelection(); e.Handled = true; return;
                case Key.V: Paste(); e.Handled = true; return;
                case Key.A: _ = Action("selectall"); e.Handled = true; return;
            }
            return;
        }
        switch (e.Key)
        {
            case Key.F3: Toggle("OSNAP"); e.Handled = true; return;
            case Key.F7: Toggle("GRID"); e.Handled = true; return;
            case Key.F8: Toggle("ORTHO"); e.Handled = true; return;
            case Key.F9: Toggle("SNAP"); e.Handled = true; return;
            case Key.Delete:
                if (commandBox.Text.Length == 0)
                {
                    canvas.EraseSelection();
                    e.Handled = true;
                    return;
                }
                break;
        }
        FocusCommand();
    }

    void Toggle(string name)
    {
        switch (name)
        {
            case "GRID": canvas.ShowGrid = !canvas.ShowGrid; break;
            case "ORTHO": canvas.Ortho = !canvas.Ortho; Log("Ortho " + (canvas.Ortho ? "on" : "off")); break;
            case "OSNAP": canvas.Osnap = !canvas.Osnap; Log("Object snap " + (canvas.Osnap ? "on" : "off")); break;
            case "SNAP":
                if (Doc != null)
                {
                    var on = !J.Has(Doc.D, "snapGrid");
                    Doc.Edit("Snap", d => d["snapGrid"] = on);
                    Log("Snap to grid " + (on ? "on" : "off"));
                }
                break;
        }
        RefreshToggles();
        canvas.InvalidateVisual();
        FocusCommand();
    }

    void RefreshToggles()
    {
        toggles["GRID"].IsChecked = canvas.ShowGrid;
        toggles["ORTHO"].IsChecked = canvas.Ortho;
        toggles["OSNAP"].IsChecked = canvas.Osnap;
        toggles["SNAP"].IsChecked = Doc != null && J.Has(Doc.D, "snapGrid");
        foreach (var t in toggles.Values) t.Background = t.IsChecked == true ? Hex("#3B6FD8") : DarkField;
    }

    /// Commands that belong to the app rather than the drawing area.
    public bool AppCommand(string name)
    {
        switch (name.ToLowerInvariant())
        {
            case "pdf": case "plot": case "export": _ = ExportPdf(); return true;
            case "update": case "updates": _ = Updater.Check(this, true); return true;
            case "save": case "qsave": _ = Save(); return true;
            case "note": WriteNote(); return true;
            case "notes": NoteStore.ShowList(this); return true;
            case "help": case "?": Log(DrawCanvas.HelpText); return true;
            case "lc": case "labelconfig": case "fixturelabels": LabelConfig(false); return true;
            case "mlc": case "motorlabels": case "motorlabelconfig": LabelConfig(true); return true;
            case "loc": case "location": case "il": case "insertlocation": InsertLocation(); return true;
            case "cmdlog": case "commandlog": Ask.ShowList(this, "Command Line", log.Select(l => l.Text).ToList()); return true;
            case "log": case "history": case "changelog":
                if (Doc != null) Ask.ShowList(this, "Change Log", J.Objs(Doc.D, "history").Select(h => J.S(h, "ts") + "  " + J.S(h, "what")).ToList());
                return true;
            case "autolabel": case "autolabels":
                if (Doc == null) return true;
                var on = J.IsFalse(Doc.D, "autoLabels");
                Doc.Edit("Automatic Labels", d => { if (on) d.Remove("autoLabels"); else d["autoLabels"] = false; });
                Log("Automatic label placement " + (on ? "on" : "off"));
                return true;
            case "lxbook": case "lx": case "sync": _ = OpenShowFromLx(); return true;
            case "title": _ = Action("title"); return true;
            case "mv": case "mview":
                Log("Click a sheet tab first (or Sheets > New Sheet), then MV.");
                return true;
        }
        return false;
    }

    /// Actions of this window, from the menus (the "@" commands).
    async Task Action(string a)
    {
        switch (a)
        {
            case "openshow": await OpenShowFromLx(); break;
            case "open": await OpenFile(); break;
            case "new": NewDrawing(); break;
            case "saveas": SaveAs(); break;
            case "moveinto": await MoveIntoShow(); break;
            case "sign": await SignInOrOut(); break;
            case "exit": Close(); break;
            case "selectall":
                if (Doc != null && canvas.SheetID == null)
                    canvas.SetSelection(M.Objects(Doc.D).Where(o => M.IsVisible(Doc.D, o) && !M.IsLocked(Doc.D, o)).Select(M.Id).ToHashSet());
                break;
            case "zoomwindow": if (Doc != null) canvas.Start(Cmd.ZoomWindow); break;
            case "title":
                if (Doc != null && Ask.TitleBlock(this, J.G(Doc.D, "info") as JsonObject ?? M.NewInfo()) is JsonObject info) Doc.Edit("Title Block", d => d["info"] = info);
                break;
            case "labels":
                if (Doc != null) { var on = J.IsFalse(Doc.D, "showLabels"); Doc.Edit("Show Labels", d => d["showLabels"] = on); }
                break;
            case "labelback":
                if (Doc != null) { var on = J.IsFalse(Doc.D, "labelBackground"); Doc.Edit("Label Background", d => { if (on) d.Remove("labelBackground"); else d["labelBackground"] = false; }); }
                break;
            case "nextunit":
                if (Doc != null && Ask.Text(this, "Next Fixture Number", "The number the next fixture placed gets:", M.Num(J.D(Doc.D, "nextUnit", 1))) is string s && int.TryParse(s.Trim(), out var n) && n > 0)
                    Doc.Edit("Next Fixture Number", d => d["nextUnit"] = n);
                break;
            case "newsheet":
                if (Doc != null)
                {
                    var sheet = Sheets.NewSheet(Doc.D, "Sheet " + (J.A(Doc.D, "sheets").Count + 1));
                    Doc.Edit("New Sheet", d => (d["sheets"] as JsonArray ?? (JsonArray)(d["sheets"] = new JsonArray())).Add(sheet));
                    canvas.ShowSheet(J.S(sheet, "id"));
                }
                break;
            case "sheetperscene":
                if (Doc != null)
                {
                    var list = J.Objs(Doc.D, "scenes").ToList();
                    if (list.Count == 0) { Log("There are no scenes yet. Save one from the Scene list first."); break; }
                    var made = list.Select(sc => Sheets.NewSheet(Doc.D, J.S(sc, "name"), J.A(sc, "visibleLayers").Select(x => J.Txt(x)).ToList())).ToList();
                    Doc.Edit("Sheets from Scenes", d => { var arr = d["sheets"] as JsonArray ?? (JsonArray)(d["sheets"] = new JsonArray()); foreach (var m in made) arr.Add(m); });
                    canvas.ShowSheet(J.S(made[0], "id"));
                }
                break;
            case "grid11": case "grid21": case "grid12": case "grid22":
                if (canvas.SheetID == null || Doc == null) { Log("Click a sheet tab first."); break; }
                int cols = a[4] - '0', rws = a[5] - '0';
                var dd = Doc.D;
                canvas.EditSheet("Viewport Layout", sh => Sheets.SetGrid(sh, cols, rws, dd));
                break;
            case "renamesheet":
                if (canvas.Sheet() is JsonObject cur && Ask.Text(this, "Rename Sheet", "Sheet name:", J.S(cur, "name")) is string nm && nm.Trim().Length > 0)
                    canvas.EditSheet("Rename Sheet", sh => sh["name"] = nm.Trim());
                else if (canvas.SheetID == null) Log("Click a sheet tab first.");
                break;
            case "deletesheet":
                if (canvas.Sheet() is JsonObject del && Doc != null && MessageBox.Show(this, $"Delete the sheet \"{J.S(del, "name")}\"?", "Delete Sheet", MessageBoxButton.OKCancel) == MessageBoxResult.OK)
                {
                    var id = J.S(del, "id");
                    canvas.ShowSheet(null);
                    Doc.Edit("Delete Sheet", d =>
                    {
                        if (d["sheets"] is JsonArray arr) for (int i = arr.Count - 1; i >= 0; i--) if (J.S(arr[i], "id") == id) arr.RemoveAt(i);
                        if (J.A(d, "sheets").Count == 0) d.Remove("sheets");
                    });
                }
                break;
            case "model": canvas.ShowSheet(null); break;
        }
        RefreshAll();
    }

    // ---------------------------------------------------------------- opening, saving

    void ReopenLast()
    {
        var last = settings.Last;
        if (last.StartsWith("show:") && account.SignedIn)
        {
            var parts = last[5..].Split('|', 2);
            if (parts.Length == 2) OpenShow(parts[0], parts[1]);
        }
        else if (last.StartsWith("file:") && File.Exists(last[5..])) OpenPath(last[5..]);
    }

    async Task<bool> CloseDoc()
    {
        if (sync != null)
        {
            await sync.Flush();
            sync.Stop();
            sync = null;
        }
        if (Doc != null)
        {
            if (Doc.FilePath != null) Doc.SaveNow();
            else if (M.Objects(Doc.D).Any())
            {
                var answer = MessageBox.Show(this, "This drawing has never been saved. Save it first?", "LX Book Draw", MessageBoxButton.YesNoCancel);
                if (answer == MessageBoxResult.Cancel) return false;
                if (answer == MessageBoxResult.Yes) SaveAs();
            }
            Doc.Changed -= DocChanged;
        }
        Doc = null;
        canvas.SetSelection(new HashSet<string>());
        canvas.ShowSheet(null);
        canvas.DrawingChanged();
        RefreshAll();
        return true;
    }

    void Attach(DrawDoc doc)
    {
        Doc = doc;
        doc.Changed += DocChanged;
        var layers = J.Objs(doc.D, "layers").ToList();
        activeLayer = J.S(layers.FirstOrDefault(l => !J.IsTrue(l, "locked")) ?? layers.First(), "id");
        canvas.DrawingChanged();
        Dispatcher.BeginInvoke(() => canvas.ZoomFit(), DispatcherPriority.Loaded);
        var link = J.G(doc.D, "lxBook");
        if (link != null && account.SignedIn && J.S(link, "showID").Length > 0)
        {
            if (J.S(link, "server").TrimEnd('/') != account.Server.TrimEnd('/'))
                Log("This drawing is linked to a different Lx Book address (" + J.S(link, "server") + "). Sign in there to sync it.", "problem");
            else
            {
                sync = new LxSync(lx, this, account.Server, J.S(link, "showID"), J.S(link, "showName"));
                sync.Start();
            }
        }
        else if (link != null && !account.SignedIn) Log("This drawing is linked to Lx Book. Sign in (top right) to keep it in step.", "lx");
        RefreshAll();
    }

    void DocChanged(bool live)
    {
        canvas.DrawingChanged();
        if (!live) sync?.DrawingChanged();
        undoButton.IsEnabled = Doc?.UndoName.Length > 0;
        redoButton.IsEnabled = Doc?.RedoName.Length > 0;
        undoButton.ToolTip = Doc?.UndoName.Length > 0 ? "Undo " + Doc.UndoName : null;
        redoButton.ToolTip = Doc?.RedoName.Length > 0 ? "Redo " + Doc.RedoName : null;
        if (!live)
        {
            sideRefresh.Stop();
            sideRefresh.Start();
        }
    }

    async void NewDrawing()
    {
        if (!await CloseDoc()) return;
        Attach(new DrawDoc(M.Blank(), null));
        Log("New drawing. It's kept once you give it a file (File > Save As) or move it into an Lx Book show.");
    }

    async Task OpenFile()
    {
        var dlg = new OpenFileDialog { Filter = "LX Book Draw drawing (*.lxdraw)|*.lxdraw|All files|*.*", Title = "Open a drawing file" };
        if (dlg.ShowDialog(this) != true) return;
        if (!await CloseDoc()) return;
        OpenPath(dlg.FileName);
    }

    void OpenPath(string path)
    {
        try
        {
            var doc = DrawDoc.Open(path);
            // a show's working copy opened as a file is kept as a plain file
            doc.D.Remove("inShow");
            Attach(doc);
            settings.Last = "file:" + path;
            settings.AddRecent(path);
            settings.Save();
            Log("Opened " + Path.GetFileName(path) + ".");
        }
        catch (Exception e)
        {
            MessageBox.Show(this, "Couldn't open " + Path.GetFileName(path) + ": " + e.Message, "Open");
        }
    }

    async Task OpenShowFromLx()
    {
        if (!account.SignedIn)
        {
            await SignInOrOut();
            if (!account.SignedIn) return;
        }
        if (account.Shows.Count == 0)
        {
            Log("Lx Book didn't list any shows for this account.", "problem");
            return;
        }
        var i = Ask.Choose(this, "Open Show from Lx Book", "Pick the show. (To see a newly made show, sign out and in again.)", account.Shows.Select(s => s.Name).ToList());
        if (i < 0) return;
        var show = account.Shows[i];
        if (!await CloseDoc()) return;
        OpenShow(show.Id, show.Name);
    }

    void OpenShow(string id, string name)
    {
        var path = LxSync.WorkingCopy(id);
        JsonObject d;
        try { d = File.Exists(path) && JsonNode.Parse(File.ReadAllText(path)) is JsonObject j ? j : M.Blank(); }
        catch { d = M.Blank(); }
        d["lxBook"] = new JsonObject { ["server"] = account.Server, ["showID"] = id, ["showName"] = name };
        d["inShow"] = true;
        var doc = new DrawDoc(d, path);
        doc.SaveNow();
        Attach(doc);
        account.ShowID = id;
        account.Save();
        settings.Last = "show:" + id + "|" + name;
        settings.Save();
        Log($"Opened \"{name}\" from Lx Book. Changes are saved to the show as you work.", "lx");
    }

    async Task MoveIntoShow()
    {
        if (Doc == null) return;
        if (Doc.InShow)
        {
            Log("This drawing already lives in its Lx Book show.");
            return;
        }
        if (!account.SignedIn)
        {
            await SignInOrOut();
            if (!account.SignedIn) return;
        }
        var i = Ask.Choose(this, "Move This Drawing into the Lx Book Show", "Pick the show this drawing belongs to. If it already has a drawing you'll be asked first; nothing is overwritten unasked.", account.Shows.Select(s => s.Name).ToList());
        if (i < 0) return;
        var show = account.Shows[i];
        var d = (JsonObject)Doc.D.DeepClone();
        if (Doc.FilePath != null) Doc.SaveNow();
        if (sync != null)
        {
            sync.Stop();
            sync = null;
        }
        Doc.Changed -= DocChanged;
        Doc = null;
        d["lxBook"] = new JsonObject { ["server"] = account.Server, ["showID"] = show.Id, ["showName"] = show.Name };
        d["inShow"] = true;
        File.WriteAllText(LxSync.WorkingCopy(show.Id), d.ToJsonString());
        LxSync.ResetSidecar(show.Id, true);
        OpenShow(show.Id, show.Name);
    }

    async Task Save()
    {
        if (Doc == null) return;
        if (Doc.FilePath == null)
        {
            SaveAs();
            return;
        }
        Doc.SaveNow();
        if (sync != null) await sync.Flush();
        Log(Doc.InShow ? "Saved; changes are sent to Lx Book." : "Saved " + Path.GetFileName(Doc.FilePath) + ".");
    }

    void SaveAs()
    {
        if (Doc == null) return;
        var dlg = new SaveFileDialog { Filter = "LX Book Draw drawing (*.lxdraw)|*.lxdraw", FileName = (ShowName.Length > 0 ? ShowName : "Plot") + ".lxdraw" };
        if (dlg.ShowDialog(this) != true) return;
        if (Doc.InShow)
        {
            var copy = (JsonObject)Doc.D.DeepClone();
            copy.Remove("inShow");
            File.WriteAllText(dlg.FileName, copy.ToJsonString());
            Log("Exported a copy of the drawing to " + Path.GetFileName(dlg.FileName) + ". The drawing itself stays in the show.");
            return;
        }
        Doc.FilePath = dlg.FileName;
        Doc.SaveNow();
        settings.Last = "file:" + dlg.FileName;
        settings.AddRecent(dlg.FileName);
        settings.Save();
        RefreshAll();
    }

    async Task ExportPdf()
    {
        if (Doc == null) return;
        var dlg = new SaveFileDialog { Filter = "PDF (*.pdf)|*.pdf", FileName = (ShowName.Length > 0 ? ShowName : "Plot") + " plot.pdf", Title = "Export PDF" };
        if (dlg.ShowDialog(this) != true) return;
        try
        {
            var d = (JsonObject)Doc.D.DeepClone();
            var name = ShowName;
            // File > Export PDF prints every sheet, including any left out of Lx Book's copy
            foreach (var sh in J.Objs(d, "sheets")) sh.Remove("lxBook");
            var bytes = await Task.Run(() => PlotPdf.Render(d, null, name, DateTime.Now.ToString("d MMM yyyy HH:mm")));
            File.WriteAllBytes(dlg.FileName, bytes);
            Log("Saved " + Path.GetFileName(dlg.FileName) + ".");
        }
        catch (Exception e)
        {
            Log("The PDF couldn't be saved: " + e.Message, "problem");
        }
    }

    async Task SignInOrOut()
    {
        if (account.SignedIn)
        {
            if (MessageBox.Show(this, "Sign out of Lx Book on this PC? A show's drawing stays on this PC and is sent when you sign in again.", "Sign Out", MessageBoxButton.OKCancel) != MessageBoxResult.OK) return;
            if (sync != null)
            {
                await sync.Flush();
                sync.Stop();
                sync = null;
            }
            await lx.SignOut();
            Log("Signed out of Lx Book.", "lx");
            RefreshAll();
            return;
        }
        var dlg = new SignInWindow(account.Server, account.User) { Owner = this };
        dlg.Submit = async (server, user, password) => await lx.SignIn(server, user, password);
        if (dlg.ShowDialog() != true) return;
        Log("Signed in to Lx Book as " + account.User + ".", "lx");
        if (Doc != null && sync == null && J.G(Doc.D, "lxBook") is JsonNode link && J.S(link, "showID").Length > 0)
        {
            sync = new LxSync(lx, this, account.Server, J.S(link, "showID"), J.S(link, "showName"));
            sync.Start();
        }
        RefreshAll();
    }

    // ---------------------------------------------------------------- ICanvasHost / ISyncHost

    public void SelectionChanged()
    {
        sideRefresh.Stop();
        RefreshProps();
    }

    public void MakeLayerCurrent(string name)
    {
        if (Doc == null) return;
        var l = J.Objs(Doc.D, "layers").FirstOrDefault(x => J.S(x, "name").Equals(name, StringComparison.OrdinalIgnoreCase));
        if (l == null)
        {
            Log($"No layer called \"{name}\". Layers: " + string.Join(", ", J.Objs(Doc.D, "layers").Select(x => J.S(x, "name"))));
            return;
        }
        activeLayer = J.S(l, "id");
        Log("Current layer: " + J.S(l, "name"));
        RefreshSide();
    }

    public void SyncStatusChanged() => RefreshLxStatus();

    void RefreshLxStatus()
    {
        lxStatus.Text = sync?.Status ?? (account.SignedIn ? "Lx Book: signed in as " + account.User : "Lx Book: not signed in");
        lxStatus.ToolTip = lxStatus.Text;
        signButton.Content = account.SignedIn ? "Sign Out" : "Sign In…";
        docWhere.Text = Doc == null ? "" : Doc.InShow ? "In Lx Book · " + (sync?.Status.Replace("Lx Book: ", "") ?? "not signed in") : Doc.FilePath ?? "Not saved yet";
    }

    // ---------------------------------------------------------------- refreshing the panels

    void RefreshAll()
    {
        startPanel.Visibility = Doc == null ? Visibility.Visible : Visibility.Collapsed;
        var name = Doc == null ? "Nothing open" : Doc.InShow ? ShowName : Doc.FilePath != null ? Path.GetFileNameWithoutExtension(Doc.FilePath) : "Untitled";
        Title = Doc == null ? "LX Book Draw" : "LX Book Draw — " + name;
        docName.Text = name;
        RefreshLxStatus();
        RefreshToggles();
        RefreshSide();
        canvas.RefreshPrompt();
    }

    void RefreshSide()
    {
        building = true;
        try
        {
            RefreshTabs();
            if (Doc == null)
            {
                layerButton.Content = "Layer";
                scenes.Items.Clear();
                fixtureTypes.Items.Clear();
                return;
            }
            var d = Doc.D;
            var cur = M.Layer(d, ActiveLayer);
            layerButton.Content = "◧  " + J.S(cur, "name") + "   ▾";
            scenes.Items.Clear();
            var active = J.S(d, "activeScene");
            scenes.Items.Add(new ComboBoxItem { Content = "(no scene)", Tag = "" });
            foreach (var s in J.Objs(d, "scenes")) scenes.Items.Add(new ComboBoxItem { Content = J.S(s, "name"), Tag = J.S(s, "id") });
            foreach (var act in new[] { "Save View as New Scene…", "Update Scene from View", "Rename Scene…", "Delete Scene" })
                scenes.Items.Add(new ComboBoxItem { Content = act, Tag = "@" + act, FontStyle = FontStyles.Italic, Foreground = Muted });
            scenes.SelectedIndex = Math.Max(0, scenes.Items.OfType<ComboBoxItem>().ToList().FindIndex(i => (string)i.Tag == active));
            fixtureTypes.Items.Clear();
            foreach (var t in M.AllFixtureTypes(d))
            {
                var label = (J.S(t, "manufacturer") + " " + J.S(t, "name")).Trim() + (J.S(t, "mode").Length > 0 ? " · " + J.S(t, "mode") : "");
                fixtureTypes.Items.Add(new ComboBoxItem { Content = label, Tag = J.S(t, "id") });
            }
            var sel = fixtureTypes.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == currentFixtureType);
            if (sel == null && fixtureTypes.Items.Count > 0)
            {
                sel = (ComboBoxItem)fixtureTypes.Items[0];
                currentFixtureType = (string)sel.Tag;
            }
            fixtureTypes.SelectedItem = sel;
        }
        finally
        {
            building = false;
        }
        RefreshProps();
        RefreshLxStatus();
    }

    void SceneChosen()
    {
        if (building || Doc == null || scenes.SelectedItem is not ComboBoxItem it) return;
        var tag = (string)it.Tag;
        var d = Doc.D;
        var active = J.S(d, "activeScene");
        if (tag.StartsWith('@'))
        {
            switch (tag[1..])
            {
                case "Save View as New Scene…":
                    if (Ask.Text(this, "New Scene", "Name for a scene showing the layers that are showing now:", "Scene " + (J.A(d, "scenes").Count + 1)) is string name && name.Trim().Length > 0)
                    {
                        var id = M.NewId();
                        var shown = J.Objs(d, "layers").Where(l => !J.IsFalse(l, "visible")).Select(l => (JsonNode)J.S(l, "id")!).ToArray();
                        Doc.Edit("New Scene", x =>
                        {
                            (x["scenes"] as JsonArray ?? (JsonArray)(x["scenes"] = new JsonArray())).Add(new JsonObject { ["id"] = id, ["name"] = name.Trim(), ["visibleLayers"] = new JsonArray(shown) });
                            x["activeScene"] = id;
                        });
                    }
                    break;
                case "Update Scene from View":
                    if (active.Length == 0) { Log("Pick a scene first, then Update."); break; }
                    var now = J.Objs(d, "layers").Where(l => !J.IsFalse(l, "visible")).Select(l => (JsonNode)J.S(l, "id")!).ToArray();
                    Doc.Edit("Update Scene", x => { if (J.Objs(x, "scenes").FirstOrDefault(s => J.S(s, "id") == active) is JsonObject s) s["visibleLayers"] = new JsonArray(now); });
                    break;
                case "Rename Scene…":
                    if (J.Objs(d, "scenes").FirstOrDefault(s => J.S(s, "id") == active) is JsonObject cur && Ask.Text(this, "Rename Scene", "Scene name:", J.S(cur, "name")) is string nm && nm.Trim().Length > 0)
                        Doc.Edit("Rename Scene", x => { if (J.Objs(x, "scenes").FirstOrDefault(s => J.S(s, "id") == active) is JsonObject s) s["name"] = nm.Trim(); });
                    else if (active.Length == 0) Log("Pick a scene first, then Rename.");
                    break;
                case "Delete Scene":
                    if (active.Length == 0) { Log("Pick a scene first, then Delete."); break; }
                    Doc.Edit("Delete Scene", x =>
                    {
                        if (x["scenes"] is JsonArray arr) for (int i = arr.Count - 1; i >= 0; i--) if (J.S(arr[i], "id") == active) arr.RemoveAt(i);
                        x.Remove("activeScene");
                    });
                    break;
            }
            RefreshSide();
            return;
        }
        if (tag.Length == 0)
        {
            if (active.Length > 0) Doc.Edit("No Scene", x => x.Remove("activeScene"));
            return;
        }
        if (tag != active)
        {
            canvas.SetSelection(new HashSet<string>());
            Doc.Edit("Show Scene", x => M.ApplyScene(x, tag));
        }
        FocusCommand();
    }

    /// The layers drop-down: Show, Lock, colour, whether things use the layer's colour, and which layer is current.
    void OpenLayers()
    {
        if (Doc == null) return;
        var panel = new StackPanel { Background = Brushes.White, Width = 420 };
        void Build()
        {
            panel.Children.Clear();
            if (Doc == null) return;
            var head = new Grid { Margin = new Thickness(6, 8, 10, 4) };
            Columns(head);
            foreach (var (t, col) in new[] { ("Layer (click to make current)", 0), ("Show", 1), ("Lock", 2), ("Colour", 3), ("Use", 4) })
            {
                var tb = new TextBlock { Text = t, FontSize = 11, Foreground = Muted };
                Grid.SetColumn(tb, col);
                head.Children.Add(tb);
            }
            panel.Children.Add(head);
            foreach (var l in J.Objs(Doc.D, "layers").ToList())
            {
                var id = J.S(l, "id");
                var row = new Grid { Margin = new Thickness(6, 1, 10, 1) };
                Columns(row);
                var current = id == ActiveLayer;
                var nameB = new Button
                {
                    Content = (current ? "● " : "    ") + J.S(l, "name"), HorizontalContentAlignment = HorizontalAlignment.Left, Background = current ? Hex("#E8F0FE") : Brushes.Transparent,
                    BorderThickness = new Thickness(0), Padding = new Thickness(4, 3, 4, 3), FontWeight = current ? FontWeights.SemiBold : FontWeights.Normal
                };
                nameB.Click += (_, _) =>
                {
                    if (J.IsTrue(M.Layer(Doc.D, id), "locked")) { Log("That layer is locked. Unlock it to draw on it."); return; }
                    activeLayer = id;
                    Build();
                    RefreshSide();
                };
                nameB.MouseRightButtonUp += (_, _) => LayerMenu(id, Build);
                var show = new CheckBox { IsChecked = !J.IsFalse(l, "visible"), VerticalAlignment = VerticalAlignment.Center };
                show.Click += (_, _) => { var v = show.IsChecked == true; Doc.Edit(v ? "Show Layer" : "Hide Layer", d => { if (M.Layer(d, id) is JsonObject x) x["visible"] = v; }); };
                var lockB = new CheckBox { IsChecked = J.IsTrue(l, "locked"), VerticalAlignment = VerticalAlignment.Center };
                lockB.Click += (_, _) =>
                {
                    var v = lockB.IsChecked == true;
                    if (v && id == ActiveLayer) { lockB.IsChecked = false; Log("The current layer can't be locked. Make another layer current first."); return; }
                    Doc.Edit(v ? "Lock Layer" : "Unlock Layer", d => { if (M.Layer(d, id) is JsonObject x) x["locked"] = v; });
                };
                var colour = new Button { Width = 34, Height = 18, BorderBrush = Line, Background = J.G(l, "color") is JsonObject c ? ScreenSurface.BrushOf(PlotPdf.ToRgb(c, PlotPdf.Black)) : Brushes.White, Cursor = Cursors.Hand };
                colour.Click += (_, _) =>
                {
                    var menu = new ContextMenu();
                    foreach (var (n, c) in M.Presets.Take(8))
                    {
                        var mi = new MenuItem { Header = n, Icon = new Border { Width = 14, Height = 10, Background = ScreenSurface.BrushOf(c) } };
                        mi.Click += (_, _) => { Doc.Edit("Layer Colour", d => { if (M.Layer(d, id) is JsonObject x) x["color"] = M.Rgba(c); }); Build(); };
                        menu.Items.Add(mi);
                    }
                    var none = new MenuItem { Header = "No colour" };
                    none.Click += (_, _) => { Doc.Edit("Layer Colour", d => { if (M.Layer(d, id) is JsonObject x) { x.Remove("color"); x.Remove("colorBy"); } }); Build(); };
                    menu.Items.Add(none);
                    menu.PlacementTarget = colour;
                    menu.IsOpen = true;
                };
                var use = new CheckBox { IsChecked = J.S(l, "colorBy") == "layer", VerticalAlignment = VerticalAlignment.Center, ToolTip = "Draw things on this layer in the layer's colour" };
                use.Click += (_, _) =>
                {
                    var v = use.IsChecked == true;
                    Doc.Edit("Layer Colour Use", d =>
                    {
                        if (M.Layer(d, id) is not JsonObject x) return;
                        if (v)
                        {
                            x["colorBy"] = "layer";
                            if (x["color"] == null) x["color"] = M.Rgba(M.Presets[1].Color);
                        }
                        else x.Remove("colorBy");
                    });
                    Build();
                };
                foreach (var (el, col) in new (UIElement, int)[] { (nameB, 0), (show, 1), (lockB, 2), (colour, 3), (use, 4) })
                {
                    Grid.SetColumn(el, col);
                    row.Children.Add(el);
                }
                panel.Children.Add(row);
            }
            var add = new Button { Content = "New Layer…", Margin = new Thickness(10, 6, 10, 6), Padding = new Thickness(8, 3, 8, 3), HorizontalAlignment = HorizontalAlignment.Left };
            add.Click += (_, _) =>
            {
                layerPopup.IsOpen = false;
                if (Ask.Text(this, "New Layer", "Layer name:", "Layer " + (J.A(Doc.D, "layers").Count + 1)) is string n && n.Trim().Length > 0)
                {
                    var nl = M.NewLayer(n.Trim());
                    Doc.Edit("New Layer", d => ((JsonArray)d["layers"]!).Add(nl));
                    activeLayer = J.S(nl, "id");
                    RefreshSide();
                }
            };
            panel.Children.Add(add);
            panel.Children.Add(new TextBlock { Text = "Right-click a layer's name to rename or delete it.", FontSize = 11, Foreground = Muted, Margin = new Thickness(10, 0, 10, 8) });
        }
        Build();
        layerPopup.Child = new Border { BorderBrush = Line, BorderThickness = new Thickness(1), Child = new ScrollViewer { Content = panel, MaxHeight = 520, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } };
        layerPopup.PlacementTarget = layerButton;
        layerPopup.IsOpen = true;
    }

    static void Columns(Grid g)
    {
        foreach (var w in new[] { 200.0, 44, 44, 60, 40 }) g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(w) });
    }

    void LayerMenu(string id, Action rebuild)
    {
        if (Doc == null) return;
        var menu = new ContextMenu();
        var rename = new MenuItem { Header = "Rename…" };
        rename.Click += (_, _) =>
        {
            layerPopup.IsOpen = false;
            if (Ask.Text(this, "Rename Layer", "Layer name:", J.S(M.Layer(Doc.D, id), "name")) is string n && n.Trim().Length > 0)
                Doc.Edit("Rename Layer", d => { if (M.Layer(d, id) is JsonObject x) x["name"] = n.Trim(); });
            RefreshSide();
        };
        var delete = new MenuItem { Header = "Delete (moves its objects to the current layer)" };
        delete.Click += (_, _) =>
        {
            if (id == ActiveLayer || J.A(Doc.D, "layers").Count < 2) { Log("Make another layer current before deleting this one."); return; }
            var to = ActiveLayer;
            Doc.Edit("Delete Layer", d =>
            {
                foreach (var o in M.Objects(d)) if (J.S(o, "layer") == id) o["layer"] = to;
                var arr = (JsonArray)d["layers"]!;
                for (int i = arr.Count - 1; i >= 0; i--) if (J.S(arr[i], "id") == id) arr.RemoveAt(i);
                foreach (var s in J.Objs(d, "scenes"))
                    if (s["visibleLayers"] is JsonArray vl) for (int i = vl.Count - 1; i >= 0; i--) if (J.Txt(vl[i]) == id) vl.RemoveAt(i);
            });
            rebuild();
        };
        menu.Items.Add(rename);
        menu.Items.Add(delete);
        menu.IsOpen = true;
    }

    void RefreshTabs()
    {
        tabs.Children.Clear();
        if (Doc == null) return;
        void Tab(string label, string? id)
        {
            var on = canvas.SheetID == id;
            var b = new Button
            {
                Content = label, Padding = new Thickness(12, 2, 12, 2), Margin = new Thickness(2, 3, 0, 0), BorderThickness = new Thickness(1, 1, 1, 0),
                Background = on ? Brushes.White : Light, BorderBrush = on ? Line : Brushes.Transparent, FontWeight = on ? FontWeights.SemiBold : FontWeights.Normal, Cursor = Cursors.Hand
            };
            b.Click += (_, _) =>
            {
                canvas.ShowSheet(id);
                RefreshTabs();
                RefreshProps();
                FocusCommand();
            };
            tabs.Children.Add(b);
        }
        Tab("Model", null);
        foreach (var s in J.Objs(Doc.D, "sheets")) Tab(J.S(s, "name") + (J.IsFalse(s, "lxBook") ? "  (not in Lx Book)" : ""), J.S(s, "id"));
        var add = new Button { Content = "+", Padding = new Thickness(10, 0, 10, 0), Margin = new Thickness(4, 3, 0, 0), Background = Brushes.Transparent, BorderThickness = new Thickness(0), ToolTip = "New sheet", Cursor = Cursors.Hand };
        add.Click += (_, _) => RunCommand("@newsheet");
        tabs.Children.Add(add);
    }

    // ---------------------------------------------------------------- the properties panel

    TextBlock Heading(string t) => new() { Text = t, FontWeight = FontWeights.SemiBold, FontSize = 13, Margin = new Thickness(0, 10, 0, 6), Foreground = Ink };

    /// A labelled field. `commit` gets the new text when Enter is pressed or the field is left.
    void Field(string label, string value, Action<string> commit, bool varies = false)
    {
        var row = new DockPanel { Margin = new Thickness(0, 2, 0, 2) };
        var lab = new TextBlock { Text = label, Width = 92, VerticalAlignment = VerticalAlignment.Center, Foreground = Hex("#555B63"), FontSize = 12 };
        var box = new TextBox { Text = varies ? "" : value, Padding = new Thickness(3, 2, 3, 2), FontSize = 12 };
        if (varies) box.ToolTip = "The selected objects differ; typing here sets them all";
        var original = box.Text;
        void Done()
        {
            if (box.Text == original) return;
            original = box.Text;
            commit(box.Text);
        }
        box.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter)
            {
                Done();
                FocusCommand();
                e.Handled = true;
            }
        };
        box.LostKeyboardFocus += (_, _) => Done();
        DockPanel.SetDock(lab, Dock.Left);
        row.Children.Add(lab);
        row.Children.Add(box);
        props.Children.Add(row);
    }

    void Choice(string label, IList<(string Label, string Value)> items, string current, Action<string> commit)
    {
        var row = new DockPanel { Margin = new Thickness(0, 2, 0, 2) };
        var lab = new TextBlock { Text = label, Width = 92, VerticalAlignment = VerticalAlignment.Center, Foreground = Hex("#555B63"), FontSize = 12 };
        var box = new ComboBox { FontSize = 12 };
        foreach (var (l, v) in items) box.Items.Add(new ComboBoxItem { Content = l, Tag = v });
        box.SelectedItem = box.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == current);
        box.SelectionChanged += (_, _) =>
        {
            if (box.SelectedItem is ComboBoxItem it && (string)it.Tag != current) commit((string)it.Tag);
            FocusCommand();
        };
        DockPanel.SetDock(lab, Dock.Left);
        row.Children.Add(lab);
        row.Children.Add(box);
        props.Children.Add(row);
    }

    void Check(string label, bool value, Action<bool> commit)
    {
        var c = new CheckBox { Content = label, IsChecked = value, Margin = new Thickness(0, 4, 0, 2), FontSize = 12 };
        c.Click += (_, _) =>
        {
            commit(c.IsChecked == true);
            FocusCommand();
        };
        props.Children.Add(c);
    }

    void PropButton(string label, Action act)
    {
        var b = new Button { Content = label, Margin = new Thickness(0, 3, 0, 3), Padding = new Thickness(8, 3, 8, 3), HorizontalAlignment = HorizontalAlignment.Left };
        b.Click += (_, _) =>
        {
            act();
            FocusCommand();
        };
        props.Children.Add(b);
    }

    void Hint(string t) => props.Children.Add(new TextBlock { Text = t, TextWrapping = TextWrapping.Wrap, Foreground = Muted, FontSize = 11, Margin = new Thickness(0, 4, 0, 4) });

    /// One value shared by every selected object, or null when they differ.
    static string? Common(IEnumerable<JsonObject> objs, Func<JsonObject, string> get)
    {
        var vals = objs.Select(get).Distinct().ToList();
        return vals.Count == 1 ? vals[0] : null;
    }

    void SetOn(string name, IEnumerable<string> ids, Action<JsonObject> change)
    {
        var set = ids.ToHashSet();
        Doc?.Edit(name, d => { foreach (var o in M.Objects(d).Where(o => set.Contains(M.Id(o)))) change(o); });
    }

    void RefreshProps()
    {
        props.Children.Clear();
        if (Doc == null) return;
        var d = Doc.D;
        if (canvas.SheetID != null)
        {
            SheetProps(d);
            return;
        }
        var sel = M.Objects(d).Where(o => canvas.Selection.Contains(M.Id(o))).ToList();
        if (sel.Count == 0)
        {
            DrawingProps(d);
            return;
        }
        var ids = sel.Select(M.Id).ToList();
        var kinds = sel.Select(M.Kind).Distinct().ToList();
        props.Children.Add(Heading(sel.Count == 1 ? KindName(sel[0], d) : $"{sel.Count} objects" + (kinds.Count == 1 ? " (" + KindName(sel[0], d) + ")" : "")));
        var layers = J.Objs(d, "layers").Select(l => (J.S(l, "name"), J.S(l, "id"))).ToList();
        Choice("Layer", layers, Common(sel, o => J.S(o, "layer")) ?? "", v => SetOn("Change Layer", ids, o => o["layer"] = v));

        if (kinds.All(k => k == "fixture"))
        {
            if (sel.Count == 1) Field(M.Category(d, sel[0]) == "hoist" ? "Motor ID" : "Fixture ID", J.S(sel[0], "unit"), v => SetOn("Fixture ID", ids, o => o["unit"] = v.Trim()));
            var uni = Common(sel, o => J.S(o, "universe"));
            var adr = Common(sel, o => J.S(o, "address"));
            var pos = Common(sel, o => J.S(o, "position"));
            var note = Common(sel, o => J.S(o, "note"));
            Field("Universe", uni ?? "", v => SetOn("Patch", ids, o => o["universe"] = v.Trim()), uni == null);
            Field("Address", adr ?? "", v => SetOn("Patch", ids, o => o["address"] = v.Trim()), adr == null);
            Field("Position", pos ?? "", v => SetOn("Position", ids, o => o["position"] = v), pos == null);
            Field("Note", note ?? "", v => SetOn("Note", ids, o => o["note"] = v), note == null);
            if (sel.Any(o => J.S(o, "circuit").Length > 0)) Hint("Circuit: " + (Common(sel, o => J.S(o, "circuit")) ?? "various") + " (from Lx Book's power patch)");
            var types = M.AllFixtureTypes(d).Select(t => ((J.S(t, "manufacturer") + " " + J.S(t, "name")).Trim() + (J.S(t, "mode").Length > 0 ? " · " + J.S(t, "mode") : ""), J.S(t, "id"))).ToList();
            Choice("Type", types, Common(sel, o => J.S(o, "typeID")) ?? "", v =>
            {
                var t = M.FixtureType(d, v);
                SetOn("Change Type", ids, o => { o["typeID"] = v; o["w"] = J.D(t, "width", 400); o["h"] = J.D(t, "depth", 400); });
            });
            var rot = Common(sel, o => M.Num(J.D(o, "rot")));
            Field("Rotation", rot ?? "", v => { if (M.ParseNum(v) is double r) SetOn("Rotate", ids, o => o["rot"] = r); }, rot == null);
            var linked = sel.Count(o => J.S(o, "lxID").Length > 0 || J.S(o, "lxMotor").Length > 0);
            Hint(linked == sel.Count ? "Linked to Lx Book: patch, position and notes are kept the same in both. The ID is the link." :
                 linked == 0 ? "Not linked to Lx Book. A fixture links itself when its ID matches a fixture in the show." : $"{linked} of {sel.Count} are linked to Lx Book.");
            var typeIDs = sel.Select(o => J.S(o, "typeID")).Distinct().ToList();
            props.Children.Add(Heading("Symbol (every fixture of this type)"));
            var style = typeIDs.Count == 1 ? J.G(J.G(d, "typeStyles"), typeIDs[0]) : null;
            var tints = new List<(string, string)> { ("None", "") };
            tints.AddRange(M.Tints.Select(t => (t.Name, t.Name)));
            var curTint = J.G(style, "color") is JsonObject c
                ? M.Tints.FirstOrDefault(t => Math.Abs(t.Color.R - J.D(c, "r")) < 0.01 && Math.Abs(t.Color.G - J.D(c, "g")) < 0.01 && Math.Abs(t.Color.B - J.D(c, "b")) < 0.01).Name ?? ""
                : "";
            Choice("Colour", tints, curTint, v => TypeStyle(typeIDs, s => { if (v.Length == 0) s.Remove("color"); else s["color"] = M.Rgba(M.Tints.First(t => t.Name == v).Color); }));
            Field("Easy ID", J.S(style, "easyID"), v => TypeStyle(typeIDs, s => { if (v.Trim().Length == 0) s.Remove("easyID"); else s["easyID"] = v.Trim(); }));
            props.Children.Add(Heading("Label"));
            PropButton("Move Label… (LB)", () => RunCommand("lb"));
            PropButton("Reset Label", () => SetOn("Reset Label", ids, o => { o.Remove("labelDX"); o.Remove("labelDY"); o.Remove("labelArrow"); o.Remove("labelLevel"); }));
            Check("Leader arrow when moved", sel.All(o => J.IsTrue(o, "labelArrow")), v => SetOn("Label Arrow", ids, o => { if (v) o["labelArrow"] = true; else o.Remove("labelArrow"); }));
            Check("Label kept level", sel.All(o => J.IsTrue(o, "labelLevel")), v => SetOn("Level Label", ids, o => { if (v) o["labelLevel"] = true; else o.Remove("labelLevel"); }));
        }
        else if (kinds.All(k => k == "truss"))
        {
            var types = PlotPdf.TrussOrder.Select(id => (PlotPdf.Truss[id].Name, id)).ToList();
            Choice("Truss", types, Common(sel, o => J.S(o, "typeID")) ?? "", v => SetOn("Truss Type", ids, o => o["typeID"] = v));
            var pos = Common(sel, o => J.S(o, "position"));
            Field("Position", pos ?? "", v => SetOn("Position Name", ids, o => o["position"] = v), pos == null);
            Hint("Fixtures hung on this truss take its position name when placed.");
            var rot = Common(sel, o => M.Num(J.D(o, "rot")));
            Field("Rotation", rot ?? "", v => { if (M.ParseNum(v) is double r) SetOn("Rotate", ids, o => o["rot"] = r); }, rot == null);
            ColourChoice(sel, ids, "fill", "Fill");
        }
        else if (kinds.All(k => k == "text"))
        {
            if (sel.Count == 1) Field("Text", J.S(sel[0], "text"), v => SetOn("Edit Text", ids, o => o["text"] = v));
            var h = Common(sel, o => M.Num(J.D(o, "textSize")));
            Field("Height", h ?? "", v => { if (M.ParseNum(v) is double x && x > 0) SetOn("Text Height", ids, o => o["textSize"] = x); }, h == null);
            Field("Rotation", Common(sel, o => M.Num(J.D(o, "rot"))) ?? "", v => { if (M.ParseNum(v) is double r) SetOn("Rotate", ids, o => o["rot"] = r); });
            if (sel.Any(o => J.IsTrue(o, "tag"))) Hint("A location label: its tape colours come from the location in Lx Book.");
            else ColourChoice(sel, ids, "stroke", "Colour");
        }
        else
        {
            ColourChoice(sel, ids, "stroke", "Colour");
            if (kinds.All(k => k is "rect" or "ellipse" or "polyline")) ColourChoice(sel, ids, "fill", "Fill");
            var weights = new[] { 0.13, 0.18, 0.25, 0.35, 0.5, 0.7, 1.0 }.Select(w => (M.Num(w) + " mm", M.Num(w))).ToList();
            Choice("Line weight", weights, Common(sel, o => M.Num(J.D(o, "lineWeight", 0.25))) ?? "", v => SetOn("Line Weight", ids, o => o["lineWeight"] = M.ParseNum(v) ?? 0.25));
            if (sel.Count == 1 && M.Kind(sel[0]) is "rect" or "ellipse")
            {
                Field("Width", M.Num(J.D(sel[0], "w")), v => { if (M.ParseNum(v) is double w && w > 0) SetOn("Resize", ids, o => o["w"] = w); });
                Field("Height", M.Num(J.D(sel[0], "h")), v => { if (M.ParseNum(v) is double hh && hh > 0) SetOn("Resize", ids, o => o["h"] = hh); });
            }
        }
        if (sel.Count == 1)
        {
            var (x0, y0) = M.UsesPoints(sel[0]) && M.Pts(sel[0]).Count > 0 ? M.Pts(sel[0])[0] : M.Pos(sel[0]);
            var moving = ids.Concat(M.AttachedFixtures(d, ids)).ToList();
            Field("X", M.Num(Math.Round(x0, 1)), v => { if (M.ParseNum(v) is double nx) SetOn("Move", moving, o => M.Translate(o, nx - x0, 0)); });
            Field("Y", M.Num(Math.Round(y0, 1)), v => { if (M.ParseNum(v) is double ny) SetOn("Move", moving, o => M.Translate(o, 0, ny - y0)); });
        }
        PropButton("Erase (E)", () => canvas.EraseSelection());
    }

    void TypeStyle(List<string> typeIDs, Action<JsonObject> change)
    {
        Doc?.Edit("Symbol Style", d =>
        {
            if (d["typeStyles"] is not JsonObject styles) d["typeStyles"] = styles = new JsonObject();
            foreach (var id in typeIDs)
            {
                if (styles[id] is not JsonObject s) styles[id] = s = new JsonObject();
                change(s);
                if (s.Count == 0) styles.Remove(id);
            }
            if (styles.Count == 0) d.Remove("typeStyles");
        });
    }

    void ColourChoice(List<JsonObject> sel, List<string> ids, string key, string label)
    {
        var items = new List<(string, string)>();
        if (key == "fill") items.Add(("None", ""));
        items.AddRange(M.Presets.Select(p => (p.Name, p.Name)));
        string Name(JsonObject o) => J.G(o, key) is JsonObject c
            ? M.Presets.FirstOrDefault(p => Math.Abs(p.Color.R - J.D(c, "r")) < 0.02 && Math.Abs(p.Color.G - J.D(c, "g")) < 0.02 && Math.Abs(p.Color.B - J.D(c, "b")) < 0.02).Name ?? ""
            : "";
        Choice(label, items, Common(sel, Name) ?? "", v => SetOn(label, ids, o => { if (v.Length == 0) o.Remove(key); else o[key] = M.Rgba(M.Presets.First(p => p.Name == v).Color); }));
    }

    static string KindName(JsonObject o, JsonObject d) => M.Kind(o) switch
    {
        "fixture" => J.S(M.FixtureType(d, J.S(o, "typeID")), "name"),
        "truss" => M.TrussType(J.S(o, "typeID")).Name,
        "text" => J.IsTrue(o, "tag") ? "Location label" : "Text",
        "rect" => "Rectangle",
        "ellipse" => "Circle",
        "polyline" => "Polyline",
        _ => "Line"
    };

    void DrawingProps(JsonObject d)
    {
        props.Children.Add(Heading("Drawing"));
        var counts = M.Objects(d).GroupBy(M.Kind).ToDictionary(g => g.Key, g => g.Count());
        Hint($"{counts.GetValueOrDefault("fixture")} fixtures, {counts.GetValueOrDefault("truss")} truss sections, {M.Objects(d).Count()} objects in all.");
        PropButton("Title Block…", () => RunCommand("@title"));
        Field("Label size", M.Num(J.D(d, "labelSize", 130)), v => { if (M.ParseNum(v) is double s && s > 0) Doc!.Edit("Label Size", x => x["labelSize"] = s); });
        Check("Show labels", !J.IsFalse(d, "showLabels"), v => Doc!.Edit("Show Labels", x => x["showLabels"] = v));
        Check("Labels move out of each other's way", !J.IsFalse(d, "autoLabels"), v => Doc!.Edit("Automatic Labels", x => { if (v) x.Remove("autoLabels"); else x["autoLabels"] = false; }));
        Check("White behind label text", !J.IsFalse(d, "labelBackground"), v => Doc!.Edit("Label Background", x => { if (v) x.Remove("labelBackground"); else x["labelBackground"] = false; }));
        PropButton("Fixture Label Config… (LC)", () => LabelConfig(false));
        PropButton("Motor Label Config… (MLC)", () => LabelConfig(true));
        Field("Grid size", M.Num(J.D(d, "gridSize", 100)), v => { if (M.ParseNum(v) is double g && g > 0) Doc!.Edit("Grid Size", x => x["gridSize"] = g); });
        Field("Next fixture", M.Num(J.D(d, "nextUnit", 1)), v => { if (int.TryParse(v.Trim(), out var n) && n > 0) Doc!.Edit("Next Fixture Number", x => x["nextUnit"] = n); });
        Field("Viewer link", J.S(d, "viewerLink"), v => Doc!.Edit("Viewer Link", x => { if (v.Trim().Length == 0) x.Remove("viewerLink"); else x["viewerLink"] = v.Trim(); }));
        Hint("The viewer link is printed on every page as a QR code. Lx Book fills it in once it gives one.");
        if (Doc!.InShow) Hint("This drawing lives in its Lx Book show. A copy is kept on this PC so work carries on with no signal.");
    }

    void SheetProps(JsonObject d)
    {
        var sh = canvas.Sheet();
        if (sh == null) return;
        var item = canvas.SelectedSheetItem();
        if (item != null && item["scale"] != null)
        {
            var vid = J.S(item, "id");
            void EditVp(string name, Action<JsonObject> change) =>
                canvas.EditSheet(name, s => { if (J.Objs(s, "viewports").FirstOrDefault(v => J.S(v, "id") == vid) is JsonObject v) change(v); });
            props.Children.Add(Heading("Viewport"));
            var scales = Sheets.Scales.Select(s => ("1:" + M.Num(s), M.Num(s))).ToList();
            var cur = M.Num(J.D(item, "scale", 50));
            if (!scales.Any(s => s.Item2 == cur)) scales.Add(("1:" + cur, cur));
            Choice("Scale", scales, cur, v => EditVp("Viewport Scale", x => x["scale"] = M.ParseNum(v) ?? 50));
            var showing = new List<(string, string)> { ("(the layers ticked below)", "") };
            showing.AddRange(J.Objs(d, "scenes").Select(s => ("Scene: " + J.S(s, "name"), J.S(s, "id"))));
            Choice("Shows", showing, "", v =>
            {
                var scene = J.Objs(d, "scenes").FirstOrDefault(s => J.S(s, "id") == v);
                if (scene != null) EditVp("Viewport Layers", x => x["layers"] = J.A(scene, "visibleLayers").DeepClone());
            });
            var vl = item["layers"] is JsonArray la ? la.Select(n => J.Txt(n)).ToHashSet() : J.Objs(d, "layers").Where(l => !J.IsFalse(l, "visible")).Select(l => J.S(l, "id")).ToHashSet();
            foreach (var l in J.Objs(d, "layers"))
            {
                var lid = J.S(l, "id");
                Check(J.S(l, "name"), vl.Contains(lid), v => EditVp("Viewport Layers", x =>
                {
                    var set = x["layers"] is JsonArray a ? a.Select(n => J.Txt(n)).ToList() : vl.ToList();
                    set.Remove(lid);
                    if (v) set.Add(lid);
                    x["layers"] = new JsonArray(set.Select(s => (JsonNode)s!).ToArray());
                }));
            }
            Field("Centre X", M.Num(Math.Round(J.D(item, "cx"))), v => { if (M.ParseNum(v) is double n) EditVp("Viewport Centre", x => x["cx"] = n); });
            Field("Centre Y", M.Num(Math.Round(J.D(item, "cy"))), v => { if (M.ParseNum(v) is double n) EditVp("Viewport Centre", x => x["cy"] = n); });
            Field("Width (mm)", M.Num(Math.Round(J.D(item, "w"), 1)), v => { if (M.ParseNum(v) is double n && n > 5) EditVp("Viewport Size", x => x["w"] = n); });
            Field("Height (mm)", M.Num(Math.Round(J.D(item, "h"), 1)), v => { if (M.ParseNum(v) is double n && n > 5) EditVp("Viewport Size", x => x["h"] = n); });
            PropButton("Fit the Drawing (FIT)", () => EditVp("Fit Viewport", x => Sheets.Fit(x, d)));
            Check("Frame drawn", !J.IsFalse(item, "frame"), v => EditVp("Viewport Frame", x => { if (v) x.Remove("frame"); else x["frame"] = false; }));
            Check("Locked (can't be dragged)", J.IsTrue(item, "locked"), v => EditVp("Lock Viewport", x => { if (v) x["locked"] = true; else x.Remove("locked"); }));
            PropButton("Erase Viewport", () => canvas.EraseSelection());
            return;
        }
        if (item != null)
        {
            var tid = J.S(item, "id");
            void EditT(string name, Action<JsonObject> change) =>
                canvas.EditSheet(name, s => { if (J.Objs(s, "objects").FirstOrDefault(v => J.S(v, "id") == tid) is JsonObject v) change(v); });
            props.Children.Add(Heading("Text on the sheet"));
            Field("Text", J.S(item, "text"), v => EditT("Edit Text", x => x["text"] = v));
            Field("Height (mm)", M.Num(J.D(item, "textSize", 4)), v => { if (M.ParseNum(v) is double h && h > 0) EditT("Text Height", x => x["textSize"] = h); });
            PropButton("Erase", () => canvas.EraseSelection());
            return;
        }
        props.Children.Add(Heading("Sheet"));
        Field("Name", J.S(sh, "name"), v =>
        {
            if (v.Trim().Length > 0) canvas.EditSheet("Rename Sheet", s => s["name"] = v.Trim());
        });
        var sizes = new List<(string, string)> { ("A4 landscape", "297x210"), ("A3 landscape", "420x297"), ("A2 landscape", "594x420"), ("A1 landscape", "841x594"), ("A0 landscape", "1189x841"), ("A3 portrait", "297x420"), ("Tabloid 11x17", "432x279"), ("Letter", "279x216") };
        var curSize = M.Num(J.D(sh, "w", 420)) + "x" + M.Num(J.D(sh, "h", 297));
        if (!sizes.Any(s => s.Item2 == curSize)) sizes.Add((curSize + " mm", curSize));
        Choice("Paper", sizes, curSize, v =>
        {
            var p = v.Split('x');
            canvas.EditSheet("Paper Size", s => { s["w"] = M.ParseNum(p[0]) ?? 420; s["h"] = M.ParseNum(p[1]) ?? 297; });
            canvas.ZoomFit();
        });
        Check("Key and title block down the right", !J.IsFalse(sh, "panel"), v => canvas.EditSheet("Key Panel", s => { if (v) s.Remove("panel"); else s["panel"] = false; }));
        Check("Include in the PDF that goes to Lx Book", !J.IsFalse(sh, "lxBook"), v => canvas.EditSheet("Lx Book PDF", s => { if (v) s.Remove("lxBook"); else s["lxBook"] = false; }));
        props.Children.Add(Heading("Viewports"));
        Hint("Click a viewport to select it; drag to move it. MV (or Sheets > Make a Viewport) draws a new one. A layout replaces them with one, two or four.");
        PropButton("Layout: One", () => RunCommand("@grid11"));
        PropButton("Layout: Two Side by Side", () => RunCommand("@grid21"));
        PropButton("Layout: Two Top and Bottom", () => RunCommand("@grid12"));
        PropButton("Layout: Four", () => RunCommand("@grid22"));
    }

    // ---------------------------------------------------------------- other commands

    void LabelConfig(bool hoist)
    {
        if (Doc == null) return;
        var parts = Ask.LabelConfig(this, Doc.D, hoist, out var spacing);
        if (parts == null) return;
        Doc.Edit(hoist ? "Motor Label Config" : "Fixture Label Config", d =>
        {
            d[hoist ? "hoistLabelParts" : "labelParts"] = new JsonArray(parts.Select(p => (JsonNode)p.DeepClone()).ToArray());
            if (spacing is double s)
            {
                if (s > 0) d["labelSpacing"] = s;
                else d.Remove("labelSpacing");
            }
        });
    }

    void InsertLocation()
    {
        if (Doc == null) return;
        var locations = J.Objs(Doc.D, "locations").ToList();
        if (locations.Count == 0)
        {
            Log("No Lx Book locations yet. Open the show from Lx Book (or sign in) and they come across.");
            return;
        }
        var names = locations.Select(l => J.S(l, "short").Length == 0 ? J.S(l, "name") : J.S(l, "name") + "  (" + J.S(l, "short") + ")").ToList();
        var i = Ask.Choose(this, "Insert Location Label", "Type to search the show's locations in Lx Book:", names);
        if (i < 0) return;
        canvas.PlaceLocation(locations[i]);
        RefreshTabs();
    }

    const string ClipMark = "LXBookDraw-objects:";

    void CopySelection()
    {
        if (Doc == null || canvas.Selection.Count == 0) return;
        var objs = M.Objects(Doc.D).Where(o => canvas.Selection.Contains(M.Id(o))).Select(o => (JsonNode)o.DeepClone()).ToArray();
        try { Clipboard.SetText(ClipMark + new JsonArray(objs).ToJsonString()); } catch { }
        Log($"Copied {objs.Length} objects.");
    }

    void Paste()
    {
        if (Doc == null || canvas.SheetID != null) return;
        string text;
        try { text = Clipboard.ContainsText() ? Clipboard.GetText() : ""; } catch { return; }
        if (!text.StartsWith(ClipMark)) return;
        JsonArray? arr;
        try { arr = JsonNode.Parse(text[ClipMark.Length..]) as JsonArray; } catch { return; }
        if (arr == null) return;
        var objs = arr.OfType<JsonObject>().ToList();
        var e = M.Extents(Doc.D, objs);
        double dx = 500, dy = -500;
        if (e != null && canvas.IsMouseOver)
        {
            var w = canvas.ToWorld(Mouse.GetPosition(canvas));
            dx = w.X - (e.Value.X0 + e.Value.X1) / 2;
            dy = w.Y - (e.Value.Y0 + e.Value.Y1) / 2;
        }
        canvas.InsertCopies(objs, dx, dy, "Paste", true);
    }

    void WriteNote()
    {
        BitmapSource? shot = null;
        try
        {
            if (Content is FrameworkElement root && root.ActualWidth > 0)
            {
                var dpi = VisualTreeHelper.GetDpi(this);
                var rtb = new RenderTargetBitmap((int)(root.ActualWidth * dpi.DpiScaleX), (int)(root.ActualHeight * dpi.DpiScaleY), dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
                rtb.Render(root);
                rtb.Freeze();
                shot = rtb;
            }
        }
        catch { }
        var context = new List<string> { $"LX Book Draw for Windows {AppInfo.Version} build {AppInfo.Build}" };
        if (Doc != null)
        {
            context.Add("Drawing: " + docName.Text + (Doc.InShow ? " (in Lx Book)" : ""));
            context.Add("Tab: " + (canvas.Sheet() is JsonObject sh ? "sheet " + J.S(sh, "name") : "Model"));
            context.Add("Command line: " + prompt.Text);
            if (canvas.Selection.Count > 0)
                context.Add("Selected: " + string.Join(", ", M.Objects(Doc.D).Where(o => canvas.Selection.Contains(M.Id(o))).GroupBy(M.Kind).Select(g => g.Count() + " " + g.Key)));
        }
        context.Add(lxStatus.Text);
        NoteStore.Write(this, context, shot);
        FocusCommand();
    }
}

/// Settings kept between runs (not secrets).
public sealed class Settings
{
    public bool Osnap { get; set; } = true;
    public bool Ortho { get; set; }
    public bool Grid { get; set; } = true;
    public string Last { get; set; } = "";
    public List<string> Recent { get; set; } = new();

    static string FilePath => Path.Combine(Account.Folder, "settings.json");

    public static Settings Load()
    {
        try { return System.Text.Json.JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new Settings(); }
        catch { return new Settings(); }
    }

    public void Save()
    {
        try { File.WriteAllText(FilePath, System.Text.Json.JsonSerializer.Serialize(this)); } catch { }
    }

    public void AddRecent(string path)
    {
        Recent.Remove(path);
        Recent.Insert(0, path);
        if (Recent.Count > 12) Recent.RemoveRange(12, Recent.Count - 12);
    }
}

/// Lx Book sign-in: address, username and password. The password goes to Lx Book once and is not kept.
public sealed class SignInWindow : Window
{
    public Func<string, string, string, Task>? Submit;
    readonly TextBox server = new() { Padding = new Thickness(4) };
    readonly TextBox user = new() { Padding = new Thickness(4) };
    readonly PasswordBox password = new() { Padding = new Thickness(4) };
    readonly TextBlock error = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) };
    readonly Button go = new() { Content = "Sign In", IsDefault = true, Padding = new Thickness(18, 5, 18, 5), Margin = new Thickness(6, 0, 0, 0) };

    public SignInWindow(string serverText, string userText)
    {
        Title = "Sign In to Lx Book";
        Width = 420;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        FontFamily = new FontFamily("Segoe UI");
        error.Foreground = Brushes.Firebrick;
        server.Text = serverText;
        user.Text = userText;
        var panel = new StackPanel { Margin = new Thickness(18) };
        void Row(string label, Control box)
        {
            panel.Children.Add(new TextBlock { Text = label, Margin = new Thickness(0, 8, 0, 3) });
            panel.Children.Add(box);
        }
        Row("Lx Book address", server);
        Row("Username", user);
        Row("Password", password);
        panel.Children.Add(error);
        var cancel = new Button { Content = "Cancel", IsCancel = true, Padding = new Thickness(14, 5, 14, 5) };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
        buttons.Children.Add(cancel);
        buttons.Children.Add(go);
        panel.Children.Add(buttons);
        Content = panel;
        go.Click += async (_, _) =>
        {
            if (Submit == null) return;
            if (!server.Text.Trim().StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            {
                error.Text = "The address must start with https://";
                return;
            }
            go.IsEnabled = false;
            error.Text = "Signing in…";
            try
            {
                await Submit(server.Text, user.Text.Trim(), password.Password);
                DialogResult = true;
            }
            catch (Exception e)
            {
                error.Text = e.Message;
                go.IsEnabled = true;
            }
        };
        Loaded += (_, _) => (user.Text.Length > 0 ? (Control)password : user).Focus();
    }
}
