using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using WinPdf = global::Windows.Data.Pdf;
using WinStreams = global::Windows.Storage.Streams;

namespace LXBookDrawWin;

/// LX Book Draw for Windows, first version: sign in to Lx Book, pick a show, look at its plot pages, export the PDF.
/// The pages are drawn by PlotPdf (the same drawing code as the Mac app's PDF), then shown with Windows' own PDF renderer.
public sealed class MainWindow : Window
{
    static readonly Brush Dark = Hex("#1E2228"), DarkLine = Hex("#2E333B"), Accent = Hex("#E5484D"), Light = Hex("#F4F5F7"),
        ViewBack = Hex("#3A3F46"), Muted = Hex("#9AA3AD");

    readonly Account account = Account.Load();
    readonly LxClient lx;
    readonly ListBox pages = new();
    readonly ComboBox shows = new() { MinWidth = 220, Margin = new Thickness(4, 0, 4, 0), VerticalContentAlignment = VerticalAlignment.Center };
    readonly Button signButton, refreshButton, exportButton;
    readonly TextBlock status = new() { Foreground = Muted, Margin = new Thickness(12, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    readonly TextBlock who = new() { Foreground = Muted, FontSize = 11, Margin = new Thickness(16, 2, 16, 0), TextWrapping = TextWrapping.Wrap };
    readonly TextBlock sourceName = new() { Foreground = Brushes.White, FontSize = 13, FontWeight = FontWeights.SemiBold, Margin = new Thickness(16, 14, 16, 4), TextWrapping = TextWrapping.Wrap };
    readonly Border view = new() { Background = ViewBack, ClipToBounds = true };
    readonly Canvas surface = new();
    readonly Border paper = new() { Background = Brushes.White };
    readonly Image image = new() { Stretch = Stretch.Fill, SnapsToDevicePixels = true };
    readonly MatrixTransform placement = new();
    readonly TextBlock empty = new() { Foreground = Muted, FontSize = 15, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = 460 };
    readonly DispatcherTimer poll = new() { Interval = TimeSpan.FromSeconds(10) };

    byte[]? pdf;
    List<(double W, double H)> pageSizes = new();
    string fileName = "";            // set when a drawing file is open instead of an Lx Book show
    string lastRev = "";
    bool busy;
    bool settingShow;            // true while the show list is set from code, not by a click
    int renderTicket;
    Point? dragFrom;

    public MainWindow(string? openPath)
    {
        lx = new LxClient(account);
        Title = "LX Book Draw " + AppInfo.Version;
        Width = Math.Min(1400, SystemParameters.WorkArea.Width - 40);
        Height = Math.Min(900, SystemParameters.WorkArea.Height - 40);
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = Light;
        FontFamily = new FontFamily("Segoe UI");

        // ---- dark sidebar: name plate, what's open, the pages
        var plate = new StackPanel();
        plate.Children.Add(new TextBlock { Text = "LX BOOK DRAW", Foreground = Brushes.White, FontSize = 16, FontWeight = FontWeights.Bold, Margin = new Thickness(16, 16, 16, 0) });
        plate.Children.Add(new TextBlock { Text = AppInfo.Version + " · build " + AppInfo.Build + " · Windows", Foreground = Muted, FontSize = 11, Margin = new Thickness(16, 2, 16, 10) });
        plate.Children.Add(new Border { Height = 3, Background = Accent, Margin = new Thickness(16, 0, 16, 0), HorizontalAlignment = HorizontalAlignment.Left, Width = 40 });
        plate.Children.Add(sourceName);
        plate.Children.Add(who);
        plate.Children.Add(new TextBlock { Text = "PAGES", Foreground = Muted, FontSize = 11, FontWeight = FontWeights.SemiBold, Margin = new Thickness(16, 18, 16, 6) });
        pages.Background = Brushes.Transparent;
        pages.BorderThickness = new Thickness(0);
        pages.Foreground = Brushes.White;
        pages.FontSize = 13;
        pages.Padding = new Thickness(8, 0, 8, 0);
        pages.SelectionChanged += (_, _) => ShowPage();
        var side = new DockPanel { Background = Dark, Width = 230 };
        DockPanel.SetDock(plate, Dock.Top);
        side.Children.Add(plate);
        side.Children.Add(pages);

        // ---- light top bar
        signButton = Flat("Sign In…", async () => await SignInOrOut());
        refreshButton = Flat("Refresh", async () => await Reload(true));
        exportButton = Flat("Export PDF…", ExportPdf);
        var bar = new DockPanel { Background = Brushes.White, Height = 46, LastChildFill = true };
        var left = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
        left.Children.Add(signButton);
        left.Children.Add(new TextBlock { Text = "Show", Foreground = Muted, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 2, 0) });
        left.Children.Add(shows);
        left.Children.Add(refreshButton);
        left.Children.Add(Flat("Open File…", OpenFile));
        left.Children.Add(exportButton);
        var right = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
        right.Children.Add(Flat("−", () => ZoomBy(1 / 1.25)));
        right.Children.Add(Flat("Fit", Fit));
        right.Children.Add(Flat("+", () => ZoomBy(1.25)));
        right.Children.Add(Flat("Check for Updates", async () => await Updater.Check(this, true)));
        DockPanel.SetDock(left, Dock.Left);
        DockPanel.SetDock(right, Dock.Right);
        bar.Children.Add(left);
        bar.Children.Add(right);
        bar.Children.Add(new Border());
        var barLine = new Border { Height = 1, Background = Hex("#DADDE2") };

        // ---- the page, on a grey desk: wheel zooms where the pointer is, drag moves it
        paper.Child = image;
        paper.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 18, ShadowDepth = 2, Opacity = 0.45 };
        paper.RenderTransform = placement;
        paper.Visibility = Visibility.Collapsed;
        surface.Children.Add(paper);
        var desk = new Grid();
        desk.Children.Add(surface);
        empty.HorizontalAlignment = HorizontalAlignment.Center;
        empty.VerticalAlignment = VerticalAlignment.Center;
        desk.Children.Add(empty);
        view.Child = desk;
        view.MouseWheel += (_, e) => ZoomAt(e.GetPosition(view), e.Delta > 0 ? 1.15 : 1 / 1.15);
        view.MouseLeftButtonDown += (_, e) => { dragFrom = e.GetPosition(view); view.CaptureMouse(); view.Cursor = Cursors.SizeAll; };
        view.MouseLeftButtonUp += (_, _) => { dragFrom = null; view.ReleaseMouseCapture(); view.Cursor = null; };
        view.MouseMove += (_, e) =>
        {
            if (dragFrom == null) return;
            var p = e.GetPosition(view);
            var m = placement.Matrix;
            m.Translate(p.X - dragFrom.Value.X, p.Y - dragFrom.Value.Y);
            placement.Matrix = m;
            dragFrom = p;
        };
        view.SizeChanged += (_, e) => { if (e.PreviousSize.Width < 1) Fit(); };

        // ---- bottom status line
        var foot = new Border { Background = Dark, Height = 26, Child = status };

        var main = new DockPanel();
        DockPanel.SetDock(bar, Dock.Top);
        DockPanel.SetDock(barLine, Dock.Top);
        DockPanel.SetDock(foot, Dock.Bottom);
        main.Children.Add(bar);
        main.Children.Add(barLine);
        main.Children.Add(foot);
        main.Children.Add(view);
        var root = new DockPanel();
        DockPanel.SetDock(side, Dock.Left);
        root.Children.Add(side);
        root.Children.Add(main);
        Content = root;

        shows.SelectionChanged += async (_, _) =>
        {
            if (settingShow || shows.SelectedItem is not ShowRef s || (s.Id == account.ShowID && fileName.Length == 0 && (pdf != null || busy))) return;
            account.ShowID = s.Id;
            account.Save();
            fileName = "";
            pdf = null;
            await Reload(true);
        };
        KeyDown += (_, e) =>
        {
            if (e.Key == Key.F5) _ = Reload(true);
            else if (e.Key == Key.Home) Fit();
            else if (e.Key == Key.OemPlus || e.Key == Key.Add) ZoomBy(1.25);
            else if (e.Key == Key.OemMinus || e.Key == Key.Subtract) ZoomBy(1 / 1.25);
        };
        poll.Tick += async (_, _) => await Poll();
        Loaded += async (_, _) =>
        {
            Refresh();
            if (!string.IsNullOrEmpty(openPath) && File.Exists(openPath)) await OpenPath(openPath);
            else if (account.SignedIn) await Reload(false);
            poll.Start();
            await Updater.Check(this, false);
        };
    }

    static SolidColorBrush Hex(string h) => (SolidColorBrush)new BrushConverter().ConvertFromString(h)!;

    static Button Flat(string text, Action act)
    {
        var b = new Button
        {
            Content = text, Margin = new Thickness(3, 0, 3, 0), Padding = new Thickness(12, 5, 12, 5), Background = Brushes.White,
            BorderBrush = Hex("#D0D4DA"), Foreground = Hex("#1E2228"), Cursor = Cursors.Hand, MinWidth = 34
        };
        b.Click += (_, _) => act();
        return b;
    }

    static Button Flat(string text, Func<Task> act)
    {
        var b = Flat(text, () => { });
        b.Click += async (_, _) => await act();
        return b;
    }

    /// Brings the buttons, show list and side panel into line with what is open.
    void Refresh()
    {
        signButton.Content = account.SignedIn ? "Sign Out" : "Sign In…";
        shows.IsEnabled = account.SignedIn && account.Shows.Count > 0;
        refreshButton.IsEnabled = account.SignedIn || fileName.Length > 0;
        exportButton.IsEnabled = pdf != null;
        var want = account.Shows.FirstOrDefault(s => s.Id == account.ShowID);
        settingShow = true;
        if (!ReferenceEquals(shows.ItemsSource, account.Shows)) shows.ItemsSource = account.Shows;
        if (fileName.Length == 0 && !ReferenceEquals(shows.SelectedItem, want)) shows.SelectedItem = want;
        settingShow = false;
        sourceName.Text = fileName.Length > 0 ? Path.GetFileNameWithoutExtension(fileName) : account.SignedIn ? (account.ShowName.Length > 0 ? account.ShowName : "No show picked") : "Not signed in";
        who.Text = fileName.Length > 0 ? "Drawing file on this PC" : account.SignedIn ? "Lx Book · " + account.User : "Sign in to Lx Book to see your shows.";
        if (pdf == null)
        {
            paper.Visibility = Visibility.Collapsed;
            empty.Visibility = Visibility.Visible;
            if (busy) empty.Text = "Loading…";
            else if (!account.SignedIn && fileName.Length == 0) empty.Text = "Sign in to Lx Book (top left) to see a show's plot.\n\nOr use Open File… for a drawing file (.lxdraw).";
            else if (account.ShowID.Length == 0) empty.Text = "Pick a show at the top.";
        }
        else
        {
            empty.Visibility = Visibility.Collapsed;
            paper.Visibility = Visibility.Visible;
        }
    }

    void Say(string text) => status.Text = text;

    async Task SignInOrOut()
    {
        if (account.SignedIn)
        {
            if (MessageBox.Show(this, "Sign out of Lx Book on this PC?", "Sign Out", MessageBoxButton.OKCancel) != MessageBoxResult.OK) return;
            await lx.SignOut();
            if (fileName.Length == 0) { pdf = null; pages.ItemsSource = null; }
            Say("Signed out.");
            Refresh();
            return;
        }
        var dlg = new SignInWindow(account.Server, account.User) { Owner = this };
        dlg.Submit = async (server, user, password) =>
        {
            await lx.SignIn(server, user, password);
        };
        if (dlg.ShowDialog() != true) return;
        fileName = "";
        pdf = null;
        Refresh();
        Say("Signed in to Lx Book as " + account.User + ".");
        await Reload(true);
    }

    async Task Reload(bool force)
    {
        if (busy) return;
        if (fileName.Length > 0)
        {
            await OpenPath(fileName);
            return;
        }
        if (!account.SignedIn || account.ShowID.Length == 0)
        {
            Refresh();
            return;
        }
        busy = true;
        Refresh();
        Say("Reading " + account.ShowName + " from Lx Book…");
        try
        {
            var health = await lx.Health();
            var (drawing, state, link) = await lx.LoadShow();
            lastRev = J.Txt(J.G(health, "drawRev")) + "/" + J.Txt(J.G(health, "rev"));
            if (drawing == null)
            {
                pdf = null;
                pages.ItemsSource = null;
                busy = false;
                Refresh();
                empty.Text = "\"" + account.ShowName + "\" has no drawing in Lx Book yet.\n\nOpen the plot in LX Book Draw on the Mac and use Move This Drawing into the Lx Book Show.";
                Say("No drawing in this show.");
                return;
            }
            var name = account.ShowName;
            var bytes = await Task.Run(() => PlotPdf.Render(drawing, state, name, Stamp(), link.Length > 0 ? link : null));
            await Present(bytes, PlotPdf.PageNames(drawing), force);
            Say("Lx Book · " + name + " · updated " + DateTime.Now.ToString("HH:mm") + " · changes in Lx Book show here within about 10 seconds");
        }
        catch (LxException e)
        {
            if (e.Login)
            {
                account.Key = "";
                account.Save();
            }
            if (e.NoShow) account.ShowID = "";
            Say(e.Message);
            if (pdf == null) empty.Text = e.Message;
        }
        catch (Exception e)
        {
            Say("Couldn't draw the plot: " + e.Message);
            if (pdf == null) empty.Text = "Couldn't draw the plot: " + e.Message;
        }
        finally
        {
            busy = false;
            Refresh();
        }
    }

    /// Every 10 seconds: has the show or its drawing changed in Lx Book? If so, draw it again.
    async Task Poll()
    {
        if (busy || fileName.Length > 0 || !account.SignedIn || account.ShowID.Length == 0 || pdf == null) return;
        try
        {
            var health = await lx.Health();
            var rev = J.Txt(J.G(health, "drawRev")) + "/" + J.Txt(J.G(health, "rev"));
            if (rev != lastRev) await Reload(false);
        }
        catch (LxException) { }
    }

    static string Stamp() => DateTime.Now.ToString("d MMM yyyy HH:mm");

    async Task OpenFile()
    {
        var dlg = new OpenFileDialog { Filter = "LX Book Draw drawing (*.lxdraw)|*.lxdraw|All files|*.*", Title = "Open a drawing file" };
        if (dlg.ShowDialog(this) != true) return;
        await OpenPath(dlg.FileName);
    }

    async Task OpenPath(string path)
    {
        busy = true;
        try
        {
            if (JsonNode.Parse(await File.ReadAllTextAsync(path)) is not JsonObject drawing) throw new InvalidDataException("That isn't a drawing file.");
            var same = fileName == path;
            fileName = path;
            var bytes = await Task.Run(() => PlotPdf.Render(drawing, null, "", Stamp()));
            await Present(bytes, PlotPdf.PageNames(drawing), !same);
            Say(Path.GetFileName(path) + " · read " + DateTime.Now.ToString("HH:mm") + " · not linked to Lx Book here");
        }
        catch (Exception e)
        {
            MessageBox.Show(this, "Couldn't open " + Path.GetFileName(path) + ": " + e.Message, "Open File");
        }
        finally
        {
            busy = false;
            Refresh();
        }
    }

    async Task Present(byte[] bytes, List<string> names, bool refit)
    {
        var keep = Math.Max(pages.SelectedIndex, 0);
        pdf = bytes;
        pageSizes = await PageSizes(bytes);
        var labels = names.Count == pageSizes.Count ? names : Enumerable.Range(1, pageSizes.Count).Select(i => "Page " + i).ToList();
        pages.ItemsSource = labels;
        var wasPage = (int)(paper.Tag ?? -1);
        pages.SelectedIndex = Math.Min(keep, labels.Count - 1);
        if (refit || wasPage < 0) fitNext = true;
        ShowPage();
    }

    bool fitNext = true;

    static async Task<WinPdf.PdfDocument> Load(byte[] bytes)
    {
        var stream = new WinStreams.InMemoryRandomAccessStream();
        var writer = new WinStreams.DataWriter(stream);
        writer.WriteBytes(bytes);
        await writer.StoreAsync();
        await writer.FlushAsync();
        writer.DetachStream();
        writer.Dispose();
        stream.Seek(0);
        return await WinPdf.PdfDocument.LoadFromStreamAsync(stream);
    }

    static async Task<List<(double, double)>> PageSizes(byte[] bytes)
    {
        var doc = await Load(bytes);
        var outp = new List<(double, double)>();
        for (uint i = 0; i < doc.PageCount; i++)
        {
            using var page = doc.GetPage(i);
            outp.Add((page.Size.Width, page.Size.Height));
        }
        return outp;
    }

    /// Draws the chosen page as a picture sharp enough to zoom into.
    async void ShowPage()
    {
        var index = pages.SelectedIndex;
        if (pdf == null || index < 0 || index >= pageSizes.Count) return;
        var ticket = ++renderTicket;
        var bytes = pdf;
        var (w, h) = pageSizes[index];
        paper.Width = w;
        paper.Height = h;
        if (fitNext || (int)(paper.Tag ?? -1) != index) Fit();
        fitNext = false;
        paper.Tag = index;
        try
        {
            var doc = await Load(bytes);
            using var page = doc.GetPage((uint)index);
            var output = new WinStreams.InMemoryRandomAccessStream();
            var width = (uint)Math.Min(7000, w * 4);
            await page.RenderToStreamAsync(output, new WinPdf.PdfPageRenderOptions { DestinationWidth = width, DestinationHeight = (uint)(width * h / w) });
            var reader = new WinStreams.DataReader(output.GetInputStreamAt(0));
            var size = (uint)output.Size;
            await reader.LoadAsync(size);
            var png = new byte[size];
            reader.ReadBytes(png);
            if (ticket != renderTicket) return;
            var bmp = new BitmapImage();
            bmp.BeginInit();
            bmp.CacheOption = BitmapCacheOption.OnLoad;
            bmp.StreamSource = new MemoryStream(png);
            bmp.EndInit();
            bmp.Freeze();
            image.Source = bmp;
            RenderOptions.SetBitmapScalingMode(image, BitmapScalingMode.HighQuality);
        }
        catch (Exception e)
        {
            Say("Couldn't show the page: " + e.Message);
        }
    }

    void Fit()
    {
        if (paper.Width is double.NaN || view.ActualWidth < 1) return;
        var s = Math.Min((view.ActualWidth - 40) / paper.Width, (view.ActualHeight - 40) / paper.Height);
        if (s <= 0) return;
        var m = Matrix.Identity;
        m.Scale(s, s);
        m.Translate((view.ActualWidth - paper.Width * s) / 2, (view.ActualHeight - paper.Height * s) / 2);
        placement.Matrix = m;
    }

    void ZoomBy(double k) => ZoomAt(new Point(view.ActualWidth / 2, view.ActualHeight / 2), k);

    void ZoomAt(Point at, double k)
    {
        var m = placement.Matrix;
        var next = m.M11 * k;
        if (next < 0.05 || next > 40) return;
        m.ScaleAt(k, k, at.X, at.Y);
        placement.Matrix = m;
    }

    void ExportPdf()
    {
        if (pdf == null) return;
        var name = fileName.Length > 0 ? Path.GetFileNameWithoutExtension(fileName) : account.ShowName;
        var safe = string.Concat((name.Length > 0 ? name : "Plot").Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '_' : c));
        var dlg = new SaveFileDialog { Filter = "PDF (*.pdf)|*.pdf", FileName = safe + " plot.pdf", Title = "Export PDF" };
        if (dlg.ShowDialog(this) != true) return;
        try
        {
            File.WriteAllBytes(dlg.FileName, pdf);
            Say("Saved " + Path.GetFileName(dlg.FileName) + ".");
        }
        catch (Exception e)
        {
            MessageBox.Show(this, "Couldn't save the PDF: " + e.Message, "Export PDF");
        }
    }
}

/// Lx Book sign-in: address, username and password. The password goes to Lx Book once and is not kept.
public sealed class SignInWindow : Window
{
    public Func<string, string, string, Task>? Submit;
    readonly TextBox server = new() { Padding = new Thickness(4) };
    readonly TextBox user = new() { Padding = new Thickness(4) };
    readonly PasswordBox password = new() { Padding = new Thickness(4) };
    readonly TextBlock error = new() { Foreground = Brushes.Firebrick, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) };
    readonly Button go = new() { Content = "Sign In", IsDefault = true, Padding = new Thickness(18, 5, 18, 5), Margin = new Thickness(6, 0, 0, 0) };

    public SignInWindow(string serverText, string userText)
    {
        Title = "Sign In to Lx Book";
        Width = 420;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        FontFamily = new FontFamily("Segoe UI");
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
