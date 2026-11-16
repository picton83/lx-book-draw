# LX Book Draw for Windows

A separate Windows app (C#, .NET 8, WPF) in the same repository as the Mac app. GitHub builds it after the Mac app
and adds `LX-Book-Draw-Windows-<version>.exe` to the same release. The version is the repo's `VERSION` file and
the build number is the GitHub run number, as on the Mac.

- `PlotPdf.cs` and `Qr.cs` are a port of `lxdraw_pdf.py`, which mirrors the Mac app's PDF. Keep the three in step.
- `LxClient.cs` talks to Lx Book like the Mac app (`api/apps/login`, `api/draw/state`, `api/state`, `api/draw/symbols`).
  The Lx Book key is kept in `%APPDATA%\LX Book Draw\account.dat`, protected with Windows data protection. The password is never kept.
- `Updater.cs` downloads the newest release's Windows .exe and swaps it in.
