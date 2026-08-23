; ---------------------------------------------------------------------------
; Wall-E installer script (Inno Setup)
;
; HOW TO USE:
;   1. Install Inno Setup (free): https://jrsoftware.org/isdl.php
;   2. Build Wall-E.exe first (see build.ps1 or your ps2exe command) so it
;      sits next to this script alongside modules\, UI\, assets\.
;   3. Open this file in Inno Setup, or compile from the command line:
;        "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" WallE.iss
;   4. The compiled installer lands in the .\Output folder as
;      Wall-E-Setup.exe - that's the single file you distribute/sell.
;
; This script assumes the following layout next to WallE.iss:
;   Wall-E.exe
;   modules\...
;   UI\...
;   assets\icon.ico
;   README.md
; ---------------------------------------------------------------------------

#define MyAppName "Wall-E"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Your Name"
#define MyAppURL "https://example.com"
#define MyAppExeName "Wall-E.exe"

[Setup]
AppId={{B6F1E0B0-6C2A-4B7E-9C7E-3C5F2A9F7E10}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
; Per-user install by default so it doesn't require admin rights.
; Switch to "admin" + PrivilegesRequired if you want a machine-wide install.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=Output
OutputBaseFilename=Wall-E-Setup
SetupIconFile=assets\icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"
Name: "startmenuicon"; Description: "Create a &Start Menu shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "Wall-E.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "modules\*"; DestDir: "{app}\modules"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "UI\*"; DestDir: "{app}\UI"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "assets\*"; DestDir: "{app}\assets"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "README.md"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\assets\icon.ico"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\assets\icon.ico"; Tasks: desktopicon
Name: "{userstartmenu}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\assets\icon.ico"; Tasks: startmenuicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName} now"; Flags: nowait postinstall skipifsilent

; modules\Cache holds runtime config/log - make sure it exists and is
; writable for a per-user install (default DefaultDirName above).
[Dirs]
Name: "{app}\modules\Cache"

[UninstallDelete]
Type: filesandordirs; Name: "{app}\modules\Cache"
