#define MyAppName "MutsuRelay"
#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif
#define MyAppPublisher "MutsuRelay"
#define MyAppURL ""
#define MyBuildDir "..\..\build\windows\x64\runner\Release"

[Setup]
AppId={{98E2FCB0-9904-4727-A97C-DE5B7C71DF8F}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={userpf}\{#MyAppName}
DefaultGroupName={#MyAppName}
UninstallDisplayIcon={app}\mutsurelay_flutter.exe
Compression=lzma2
SolidCompression=yes
OutputDir=..\..\dist
OutputBaseFilename=MutsuRelay-{#MyAppVersion}-setup
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
AllowNoIcons=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: checkedonce

[Files]
Source: "{#MyBuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\mutsurelay_flutter.exe"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\mutsurelay_flutter.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\mutsurelay_flutter.exe"; Description: "Launch MutsuRelay"; Flags: postinstall nowait skipifsilent shellexec
