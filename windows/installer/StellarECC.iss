#ifndef AppVersion
  #define AppVersion "0.1.1"
#endif
#ifndef BuildDir
  #define BuildDir "build\windows\x64\runner\Release"
#endif
#ifndef VCRedistPath
  #define VCRedistPath "vc_redist.x64.exe"
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
CloseApplications=yes
RestartApplications=no

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#VCRedistPath}"; DestDir: "{tmp}"; DestName: "vc_redist.x64.exe"; Flags: deleteafterinstall

[Icons]
Name: "{group}\Stellar ECC"; Filename: "{app}\stellar_ecc.exe"
Name: "{autodesktop}\Stellar ECC"; Filename: "{app}\stellar_ecc.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional icons:"

[Run]
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "Installing Microsoft Visual C++ runtime..."; Flags: runhidden waituntilterminated
Filename: "{app}\stellar_ecc.exe"; Description: "Launch Stellar ECC"; Flags: postinstall nowait skipifsilent

[Code]
var
  DeleteStellarUserData: Boolean;

function InitializeUninstall(): Boolean;
var
  StellarDataDir: String;
begin
  StellarDataDir := ExpandConstant('{userappdata}\I-WORKS\Stellar ECC');
  DeleteStellarUserData := False;
  if DirExists(StellarDataDir) then
    DeleteStellarUserData := MsgBox(
      'Do you also want to permanently erase Stellar ECC local data, including encrypted messages, attachments, and device keys? This cannot be undone.',
      mbConfirmation,
      MB_YESNO or MB_DEFBUTTON2) = IDYES;
  Result := True;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  StellarDataDir: String;
begin
  if (CurUninstallStep = usPostUninstall) and DeleteStellarUserData then
  begin
    StellarDataDir := ExpandConstant('{userappdata}\I-WORKS\Stellar ECC');
    if DirExists(StellarDataDir) then
      DelTree(StellarDataDir, True, True, True);
  end;
end;
