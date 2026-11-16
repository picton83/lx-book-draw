using System;
using System.Linq;
using System.Reflection;
using System.Windows;

namespace LXBookDrawWin;

public static class AppInfo
{
    public static string Version =>
        Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "0.0.0";

    public static int Build =>
        int.TryParse(Assembly.GetExecutingAssembly().GetCustomAttributes<AssemblyMetadataAttribute>().FirstOrDefault(a => a.Key == "Build")?.Value, out var b) ? b : 0;
}

public static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
        app.DispatcherUnhandledException += (_, e) =>
        {
            MessageBox.Show(e.Exception.Message, "LX Book Draw", MessageBoxButton.OK, MessageBoxImage.Warning);
            e.Handled = true;
        };
        var window = new MainWindow(args.FirstOrDefault());
        app.Run(window);
    }
}
