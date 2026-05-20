[Setup]
AppName=ssterm
AppVersion=1.0.0
DefaultDirName={autopf}\ssterm
DefaultGroupName=ssterm
OutputDir=dist
OutputBaseFilename=ssterm_Setup
Compression=lzma
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
SetupIconFile=assets\icon\icon.ico
UninstallDisplayIcon={app}\ssterm.exe

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\SSTerm"; Filename: "{app}\ssterm.exe"
Name: "{commondesktop}\SSTerm"; Filename: "{app}\ssterm.exe"

[Run]
Filename: "{app}\ssterm.exe"; Description: "Run ssterm"; Flags: nowait postinstall skipifsilent