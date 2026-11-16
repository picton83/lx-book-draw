; The Windows installer for LX Book Draw (Inno Setup). GitHub builds it after the app (see .github/workflows/build.yml).
; Installs into Program Files with a Start menu entry, opens .lxdraw files, and can be uninstalled from Settings > Apps.
; The app's own updater runs a newer copy of this installer quietly.

#define AppVer GetEnv("APPVER")

[Setup]
AppId={{8C3F5D2E-6B7A-4E1F-9A2B-3C4D5E6F7A8B}
AppName=LX Book Draw
AppVersion={#AppVer}
AppVerName=LX Book Draw {#AppVer}
AppPublisher=Stuart Picton
DefaultDirName={autopf}\LX Book Draw
DefaultGroupName=LX Book Draw
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=LX-Book-Draw-Windows-Setup-{#AppVer}
SetupIconFile=LXBookDraw.Windows\AppIcon.ico
UninstallDisplayIcon={app}\LX Book Draw.exe
UninstallDisplayName=LX Book Draw
Compression=lzma2
SolidCompression=yes
CloseApplications=force
RestartApplications=no
WizardStyle=modern
ChangesAssociations=yes

[Tasks]
Name: desktopicon; Description: "Put a shortcut on the desktop"; Flags: unchecked

[Files]
Source: "..\out\LX Book Draw.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\LX Book Draw"; Filename: "{app}\LX Book Draw.exe"
Name: "{autodesktop}\LX Book Draw"; Filename: "{app}\LX Book Draw.exe"; Tasks: desktopicon

[Registry]
Root: HKA; Subkey: "Software\Classes\.lxdraw"; ValueType: string; ValueName: ""; ValueData: "LXBookDraw.Drawing"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\LXBookDraw.Drawing"; ValueType: string; ValueName: ""; ValueData: "LX Book Draw drawing"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\LXBookDraw.Drawing\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\LX Book Draw.exe,0"
Root: HKA; Subkey: "Software\Classes\LXBookDraw.Drawing\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\LX Book Draw.exe"" ""%1"""

[Run]
Filename: "{app}\LX Book Draw.exe"; Description: "Open LX Book Draw"; Flags: nowait postinstall runasoriginaluser
