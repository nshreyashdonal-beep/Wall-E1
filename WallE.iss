; ---------------------------------------------------------------------------
; Wall-E installer script (Inno Setup)
;
; HOW TO USE:
;   1. Install Inno Setup (free): https://jrsoftware.org/isdl.php
;   2. Build Wall-E.exe first (run build.ps1 on Windows) so it sits next to
;      this script alongside modules\, UI\, assets\, README.md.
;   3. Open this file in Inno Setup and click Compile, or from a command
;      prompt:
;        "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" WallE.iss
;   4. The compiled installer lands in .\Output\Wall-E-Setup.exe - that is
;      the single file you distribute.
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
#define MyAppPublisher "Shreyash Donal"
#define MyAppURL ""
#define MyAppExeName "Wall-E.exe"

[Setup]
; Unique per-app GUID - do not reuse across unrelated apps, and do not
; regenerate this once you've shipped a version, or Windows will treat
; upgrades as a fresh install instead of an update.
AppId={{732CEF5C-EBBD-43C8-924E-9DAA97DD601B}}
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
; Switch to PrivilegesRequired=admin if you want a machine-wide install.
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
; Uncomment if you add a LICENSE.txt file next to this script:
; LicenseFile=LICENSE.txt

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
