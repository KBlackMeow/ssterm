[Setup]
AppName=SSTerm
AppVersion=1.1.0
DefaultDirName={autopf}\ssterm
DefaultGroupName=SSTerm
OutputDir=dist
OutputBaseFilename=SSTerm_Setup
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
Filename: "{app}\ssterm.exe"; Description: "Run SSTerm"; Flags: nowait postinstall skipifsilent