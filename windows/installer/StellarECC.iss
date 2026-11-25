#ifndef AppVersion
  #define AppVersion "0.1.1"
#endif
#ifndef BuildDir
  #define BuildDir "build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{A2218824-27B4-4F54-A72B-F199E7D4F028}
AppName=Stellar ECC
AppVersion={#AppVersion}
AppPublisher=Stellar ECC
DefaultDirName={autopf}\Stellar ECC
DefaultGroupName=Stellar ECC
UninstallDisplayIcon={app}\stellar_ecc.exe
OutputDir=..\..\dist
OutputBaseFilename=StellarECCSetup-{#AppVersion}-x64
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Stellar ECC"; Filename: "{app}\stellar_ecc.exe"
Name: "{autodesktop}\Stellar ECC"; Filename: "{app}\stellar_ecc.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional icons:"

[Run]
Filename: "{app}\stellar_ecc.exe"; Description: "Launch Stellar ECC"; Flags: postinstall nowait skipifsilent
