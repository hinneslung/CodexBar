#ifndef PayloadDirectory
  #error Build this script through package_windows_installer.ps1.
#endif
#ifdef TestIdentity
  #define ProductId "CodexBar.Windows.Installer.QA"
  #define ProductName "CodexBar Installer QA"
  #define StartupTaskName "CodexBar Installer QA Autostart"
#else
  #define ProductId "CodexBar.Windows"
  #define ProductName "CodexBar"
  #define StartupTaskName "CodexBar Autostart"
#endif

[Setup]
AppId={#ProductId}
AppName={#ProductName}
AppVersion={#DisplayVersion}
VersionInfoVersion={#NumericVersion}
DefaultDirName={localappdata}\Programs\{#ProductName}
DefaultGroupName={#ProductName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
#if AssetArchitecture == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64os and not arm64
ArchitecturesInstallIn64BitMode=x64os
#endif
OutputDir={#OutputDirectory}
OutputBaseFilename={#AssetName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
DisableWelcomePage=no
CloseApplications=yes
RestartApplications=no
UninstallDisplayIcon={app}\CodexBar.exe
UninstallDisplayName={#ProductName}
SetupLogging=yes

[Files]
Source: "{#PayloadDirectory}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#ProductName}"; Filename: "{app}\CodexBar.exe"; WorkingDir: "{app}"

[Run]
Filename: "{app}\CodexBar.exe"; Description: "Launch CodexBar"; Flags: nowait postinstall skipifsilent

[Code]
procedure OpenWSLHelp(Sender: TObject);
var
  ErrorCode: Integer;
begin
  ShellExec('open', 'https://learn.microsoft.com/windows/wsl/install', '', '', SW_SHOWNORMAL,
    ewNoWait, ErrorCode);
end;

procedure InitializeWizard;
var
  Page: TWizardPage;
  Description: TNewStaticText;
  Help: TNewButton;
begin
  Page := CreateCustomPage(wpWelcome, 'Provider usage requires WSL', 'Install CodexBar now; finish WSL setup when ready.');
  Description := TNewStaticText.Create(Page);
  Description.Parent := Page.Surface;
  Description.SetBounds(0, 0, Page.SurfaceWidth, ScaleY(120));
  Description.AutoSize := False;
  Description.WordWrap := True;
  if FileExists(ExpandConstant('{sys}\wsl.exe')) then
    Description.Caption := 'WSL was detected on this PC. CodexBar needs a configured WSL distribution to retrieve provider usage. You can choose the distribution in CodexBar Settings.'
  else
    Description.Caption := 'WSL was not found on this PC. CodexBar needs Windows Subsystem for Linux and a configured distribution to retrieve provider usage. You can install CodexBar now and set up WSL later.';
  Help := TNewButton.Create(Page);
  Help.Parent := Page.Surface;
  Help.SetBounds(0, ScaleY(130), ScaleX(210), ScaleY(28));
  Help.Caption := 'Open Microsoft WSL setup guide';
  Help.OnClick := @OpenWSLHelp;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpFinished then
    WizardForm.FinishedLabel.Caption := 'CodexBar is installed. Open it from the Start menu, then use its notification-area icon. To launch it when you sign in, turn on Run at startup in CodexBar Settings.';
end;

procedure RemoveOwnedStartupTask;
var
  Service, Folder, Task, Actions, Action: Variant;
  Target: String;
begin
  try
    Service := CreateOleObject('Schedule.Service');
    Service.Connect;
    Folder := Service.GetFolder('\');
    try
      Task := Folder.GetTask('{#StartupTaskName}');
    except
      Exit;
    end;
    Actions := Task.Definition.Actions;
    if Actions.Count <> 1 then Exit;
    Action := Actions.Item(1);
    { Only executable actions expose Path; any other action fails closed below. }
    Target := Action.Path;
    if CompareText(Target, ExpandConstant('{app}\CodexBar.exe')) <> 0 then Exit;
    Folder.DeleteTask('{#StartupTaskName}', 0);
  except
    Log('Could not remove the installed copy''s startup task. Other startup registrations were preserved.');
  end;
end;

function InitializeUninstall: Boolean;
var
  Locator, Services, Processes: Variant;
  Target: String;
begin
  Result := False;
  try
    Target := ExpandConstant('{app}\CodexBar.exe');
    StringChangeEx(Target, '\', '\\', True);
    StringChangeEx(Target, '''', '\''', True);
    Locator := CreateOleObject('WbemScripting.SWbemLocator');
    Services := Locator.ConnectServer('', 'root\CIMV2');
    Processes := Services.ExecQuery('SELECT ExecutablePath FROM Win32_Process WHERE ExecutablePath = ''' + Target + '''');
    if Processes.Count > 0 then begin
      if not UninstallSilent then
        MsgBox('CodexBar is running. Right-click its notification-area icon, choose Quit CodexBar, then run uninstall again.', mbInformation, MB_OK);
      Log('Uninstall stopped because the installed copy is running.');
      Exit;
    end;
    Result := True;
  except
    if not UninstallSilent then
      MsgBox('Windows could not check whether CodexBar is running. Close CodexBar and try uninstalling again.', mbError, MB_OK);
    Log('Uninstall stopped because the running-app check could not complete.');
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then RemoveOwnedStartupTask;
end;
