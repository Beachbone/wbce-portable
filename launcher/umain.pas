unit umain;

{$mode objfpc}{$H+}

{ WBCE Portable Launcher
  Startet/stoppt Apache + MariaDB aus dem Ordner, in dem die EXE liegt.
  Alles laeuft unsichtbar im Hintergrund; das Fenster zeigt nur den Status.
  Kommandozeile:  /start      Server direkt beim Programmstart starten
                  /selftest   Start, 3 s warten, Stopp, beenden (Log: logs\launcher-selftest.txt)
                  /vccheck    VC++-Installer beschaffen + Signatur pruefen (ohne zu installieren) }

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls,
  Process, Sockets, LCLIntf, Windows, Registry, ShellApi;

const
  APP_VERSION = '0.1.1';
  HTTP_PORT = 4443;
  DB_PORT   = 3311;
  APP_URL   = 'http://localhost:4443/wbce';
  ADMIN_URL = 'http://localhost:4443/wbce/admin';
  // Apache Lounge VS18 braucht das VC++-Runtime 14.50 oder neuer (Visual Studio 2026)
  VC_MIN_MINOR = 50;
  VC_REG_KEY = 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64';
  VC_URL = 'https://aka.ms/vc14/vc_redist.x64.exe';

type
  TServerState = (ssStopped, ssStarting, ssRunning, ssStopping);

  { TfrmMain }

  TfrmMain = class(TForm)
  private
    FBase: string;        // Programmordner mit abschliessendem Backslash
    FBaseFwd: string;     // dito mit Slashes (fuer die Konfigdateien)
    FState: TServerState;
    FApachePid: DWORD;
    FDbPid: DWORD;
    FSilent: Boolean;     // Selbsttest: keine Dialoge, kein Browser
    FSelfTestLog: string;
    shpLamp: TShape;
    lblStatus: TLabel;
    lblHint: TLabel;
    btnStart: TButton;
    btnStop: TButton;
    btnSite: TButton;
    btnAdmin: TButton;
    memLog: TMemo;
    tmr: TTimer;
    function PortOpen(APort: Integer): Boolean;
    function ProcessAlive(APid: DWORD): Boolean;
    function RunWait(const Exe: string; const Args: array of string): Integer;
    function StartBg(const Exe: string; const Args: array of string): DWORD;
    function WaitForPort(APort, ATimeoutSec: Integer; APid: DWORD): Boolean;
    procedure Pause(AMs: Integer);
    procedure Log(const AMsg: string);
    procedure Fail(const AMsg: string);
    procedure SetState(AState: TServerState);
    procedure CheckFiles;
    function VcRuntimeOk(out AVersion: string): Boolean;
    function VcInstallerPath: string;
    procedure InstallVcRuntime;
    procedure EnsureVcRuntime;
    procedure WriteConfig(const ATemplate, ADest: string);
    procedure SavePids;
    procedure LoadPids;
    procedure KillPid(APid: DWORD);
    procedure DoStart;
    procedure DoStop;
    procedure StartClick(Sender: TObject);
    procedure StopClick(Sender: TObject);
    procedure SiteClick(Sender: TObject);
    procedure AdminClick(Sender: TObject);
    procedure TimerTick(Sender: TObject);
    procedure FormCloseQueryEvent(Sender: TObject; var CanClose: Boolean);
    procedure FormShowEvent(Sender: TObject);
  public
    constructor Create(TheOwner: TComponent); override;
  end;

var
  frmMain: TfrmMain;

implementation

const
  REQUIRED_FILES: array[0..8] of string = (
    'Apache24\bin\httpd.exe',
    'php\php8apache2_4.dll',
    'mariadb\bin\mysqld.exe',
    'mariadb\bin\mariadb-install-db.exe',
    'mariadb\bin\mariadb.exe',
    'mariadb\bin\mariadb-admin.exe',
    'conf-httpd.template',
    'conf-php.template',
    'conf-my.template');

{ TfrmMain }

constructor TfrmMain.Create(TheOwner: TComponent);
var
  i: Integer;
begin
  inherited CreateNew(TheOwner);   // Formular wird komplett im Code gebaut (keine .lfm)

  FBase := ExtractFilePath(ParamStr(0));
  FBaseFwd := StringReplace(FBase, '\', '/', [rfReplaceAll]);
  FState := ssStopped;
  FSilent := False;
  for i := 1 to ParamCount do
    if SameText(ParamStr(i), '/selftest') or SameText(ParamStr(i), '/vccheck') then
    begin
      FSilent := True;
      FSelfTestLog := FBase + 'logs\launcher-selftest.txt';
    end;

  Caption := 'WBCE Portable ' + APP_VERSION;
  BorderStyle := bsSingle;
  BorderIcons := [biSystemMenu, biMinimize];
  Position := poScreenCenter;
  ClientWidth := 460;
  ClientHeight := 330;
  OnCloseQuery := @FormCloseQueryEvent;
  OnShow := @FormShowEvent;

  shpLamp := TShape.Create(Self);
  shpLamp.Parent := Self;
  shpLamp.Shape := stCircle;
  shpLamp.SetBounds(16, 16, 28, 28);
  shpLamp.Pen.Color := clGray;

  lblStatus := TLabel.Create(Self);
  lblStatus.Parent := Self;
  lblStatus.SetBounds(56, 14, 390, 32);
  lblStatus.Font.Size := 14;
  lblStatus.Font.Style := [fsBold];
  lblStatus.Layout := tlCenter;

  btnStart := TButton.Create(Self);
  btnStart.Parent := Self;
  btnStart.SetBounds(16, 60, 205, 40);
  btnStart.Caption := 'Server starten';
  btnStart.OnClick := @StartClick;

  btnStop := TButton.Create(Self);
  btnStop.Parent := Self;
  btnStop.SetBounds(239, 60, 205, 40);
  btnStop.Caption := 'Server stoppen';
  btnStop.OnClick := @StopClick;

  btnSite := TButton.Create(Self);
  btnSite.Parent := Self;
  btnSite.SetBounds(16, 108, 205, 30);
  btnSite.Caption := 'Website öffnen';
  btnSite.OnClick := @SiteClick;

  btnAdmin := TButton.Create(Self);
  btnAdmin.Parent := Self;
  btnAdmin.SetBounds(239, 108, 205, 30);
  btnAdmin.Caption := 'Administration öffnen';
  btnAdmin.OnClick := @AdminClick;

  lblHint := TLabel.Create(Self);
  lblHint.Parent := Self;
  lblHint.SetBounds(16, 148, 428, 16);
  lblHint.Font.Color := clGray;
  lblHint.Caption := 'Vor dem Abziehen des Sticks den Server stoppen!';

  memLog := TMemo.Create(Self);
  memLog.Parent := Self;
  memLog.SetBounds(16, 172, 428, 142);
  memLog.ReadOnly := True;
  memLog.ScrollBars := ssAutoVertical;
  memLog.Font.Size := 9;

  tmr := TTimer.Create(Self);
  tmr.Interval := 2000;
  tmr.OnTimer := @TimerTick;
  tmr.Enabled := True;

  SetState(ssStopped);
end;

procedure TfrmMain.Pause(AMs: Integer);
var
  t: QWord;
begin
  t := GetTickCount64 + AMs;
  while GetTickCount64 < t do
  begin
    Application.ProcessMessages;
    Sleep(25);
  end;
end;

procedure TfrmMain.Log(const AMsg: string);
var
  L: TStringList;
begin
  memLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + AMsg);
  if FSelfTestLog <> '' then
  begin
    L := TStringList.Create;
    try
      if FileExists(FSelfTestLog) then L.LoadFromFile(FSelfTestLog);
      L.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + AMsg);
      L.SaveToFile(FSelfTestLog);
    finally
      L.Free;
    end;
  end;
end;

procedure TfrmMain.Fail(const AMsg: string);
begin
  raise Exception.Create(AMsg);
end;

procedure TfrmMain.SetState(AState: TServerState);
begin
  FState := AState;
  case AState of
    ssStopped:
      begin
        shpLamp.Brush.Color := $0000C0;   // rot (BGR)
        lblStatus.Caption := 'Server gestoppt';
      end;
    ssStarting:
      begin
        shpLamp.Brush.Color := $00A5FF;   // orange
        lblStatus.Caption := 'Server startet ...';
      end;
    ssRunning:
      begin
        shpLamp.Brush.Color := $50B000;   // gruen
        lblStatus.Caption := 'Server läuft';
      end;
    ssStopping:
      begin
        shpLamp.Brush.Color := $00A5FF;
        lblStatus.Caption := 'Server wird gestoppt ...';
      end;
  end;
  btnStart.Enabled := AState = ssStopped;
  btnStop.Enabled := AState = ssRunning;
  btnSite.Enabled := AState = ssRunning;
  btnAdmin.Enabled := AState = ssRunning;
  Application.ProcessMessages;
end;

function TfrmMain.PortOpen(APort: Integer): Boolean;
var
  s: Sockets.TSocket;
  addr: Sockets.TInetSockAddr;
begin
  Result := False;
  s := Sockets.fpSocket(Sockets.AF_INET, Sockets.SOCK_STREAM, 0);
  if s < 0 then Exit;
  try
    FillChar(addr, SizeOf(addr), 0);
    addr.sin_family := Sockets.AF_INET;
    addr.sin_port := Sockets.htons(APort);
    addr.sin_addr := Sockets.StrToNetAddr('127.0.0.1');
    Result := Sockets.fpConnect(s, @addr, SizeOf(addr)) = 0;
  finally
    Sockets.CloseSocket(s);
  end;
end;

function TfrmMain.ProcessAlive(APid: DWORD): Boolean;
var
  h: THandle;
  code: DWORD;
begin
  Result := False;
  if APid = 0 then Exit;
  h := Windows.OpenProcess(PROCESS_QUERY_INFORMATION, False, APid);
  if h = 0 then Exit;
  try
    Result := Windows.GetExitCodeProcess(h, code) and (code = STILL_ACTIVE);
  finally
    Windows.CloseHandle(h);
  end;
end;

function TfrmMain.RunWait(const Exe: string; const Args: array of string): Integer;
var
  P: TProcess;
  i: Integer;
begin
  P := TProcess.Create(nil);
  try
    P.Executable := Exe;
    for i := 0 to High(Args) do P.Parameters.Add(Args[i]);
    P.CurrentDirectory := FBase;
    P.Options := [poNoConsole];
    P.ShowWindow := swoHide;
    P.Execute;
    while P.Running do Pause(50);
    Result := P.ExitStatus;
  finally
    P.Free;
  end;
end;

function TfrmMain.StartBg(const Exe: string; const Args: array of string): DWORD;
var
  P: TProcess;
  i: Integer;
begin
  P := TProcess.Create(nil);
  try
    P.Executable := Exe;
    for i := 0 to High(Args) do P.Parameters.Add(Args[i]);
    P.CurrentDirectory := FBase;
    P.Options := [poNoConsole];
    P.ShowWindow := swoHide;
    P.Execute;
    Result := P.ProcessID;
  finally
    P.Free;   // beendet den Prozess nicht
  end;
end;

function TfrmMain.WaitForPort(APort, ATimeoutSec: Integer; APid: DWORD): Boolean;
var
  t: QWord;
begin
  Result := False;
  t := GetTickCount64 + QWord(ATimeoutSec) * 1000;
  while GetTickCount64 < t do
  begin
    if PortOpen(APort) then Exit(True);
    if not ProcessAlive(APid) then Exit(False);
    Pause(300);
  end;
end;

procedure TfrmMain.CheckFiles;
var
  i: Integer;
begin
  for i := Low(REQUIRED_FILES) to High(REQUIRED_FILES) do
    if not FileExists(FBase + REQUIRED_FILES[i]) then
      Fail('Datei fehlt: ' + REQUIRED_FILES[i] + LineEnding +
           'Das Programm muss im entpackten WBCE-Portable-Ordner liegen.');
end;

{ Ist das Microsoft Visual C++ Runtime (x64) in ausreichender Version installiert? }
function TfrmMain.VcRuntimeOk(out AVersion: string): Boolean;
var
  R: TRegistry;
  major, minor: Integer;
begin
  Result := False;
  AVersion := '';
  R := TRegistry.Create(KEY_READ or KEY_WOW64_64KEY);
  try
    try
      R.RootKey := HKEY_LOCAL_MACHINE;
      if R.OpenKeyReadOnly(VC_REG_KEY) and R.ValueExists('Installed') and
         (R.ReadInteger('Installed') = 1) then
      begin
        major := R.ReadInteger('Major');
        minor := R.ReadInteger('Minor');
        AVersion := Format('%d.%d', [major, minor]);
        Result := (major > 14) or ((major = 14) and (minor >= VC_MIN_MINOR));
      end;
    except
      Result := False;   // Schluessel fehlt/nicht lesbar = nicht installiert
    end;
  finally
    R.Free;
  end;
end;

{ Pfad des Installers: mitgelieferte Kopie (offline) oder Download von Microsoft.
  Vor der Verwendung wird die digitale Signatur geprueft (Microsoft Corporation). }
function TfrmMain.VcInstallerPath: string;
var
  rc: Integer;
  sz: Int64;
begin
  Result := FBase + 'vcredist\vc_redist.x64.exe';
  if not FileExists(Result) then
  begin
    Result := FBase + 'tmp\vc_redist.x64.exe';
    Log('Lade Visual C++ Runtime von Microsoft (ca. 18 MB) ...');
    SysUtils.DeleteFile(Result);
    RunWait('curl.exe', ['-L', '--fail', '--silent', '--max-time', '300', '-o', Result, VC_URL]);
    sz := 0;
    if FileExists(Result) then
      with TFileStream.Create(Result, fmOpenRead or fmShareDenyNone) do
      try
        sz := Size;
      finally
        Free;
      end;
    if sz < 1000000 then
      Fail('Der Download des Visual C++ Runtime ist fehlgeschlagen (keine Internetverbindung?).' +
           LineEnding + 'Bitte manuell installieren: ' + VC_URL);
  end;

  Log('Prüfe digitale Signatur des Installers ...');
  rc := RunWait('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
    '$s = Get-AuthenticodeSignature -LiteralPath ''' + Result + '''; ' +
    'if ($s.Status -eq ''Valid'' -and $s.SignerCertificate.Subject -like ''*O=Microsoft Corporation*'') ' +
    '{ exit 0 } else { exit 1 }']);
  if rc <> 0 then
    Fail('Die digitale Signatur des Installers ist ungültig - er wird nicht ausgeführt.' +
         LineEnding + 'Bitte manuell von Microsoft installieren: ' + VC_URL);
end;

{ Startet den Installer mit Administratorrechten (UAC-Abfrage) und wartet. }
procedure TfrmMain.InstallVcRuntime;
var
  exe: string;
  wExe, wVerb, wParams: UnicodeString;
  sei: TShellExecuteInfoW;
  code: DWORD;
begin
  exe := VcInstallerPath;
  Log('Starte Installation (Administratorrechte nötig) ...');
  wExe := UnicodeString(exe);
  wVerb := 'runas';
  wParams := '/install /passive /norestart';
  FillChar(sei, SizeOf(sei), 0);
  sei.cbSize := SizeOf(sei);
  sei.fMask := SEE_MASK_NOCLOSEPROCESS;
  sei.Wnd := Handle;
  sei.lpVerb := PWideChar(wVerb);
  sei.lpFile := PWideChar(wExe);
  sei.lpParameters := PWideChar(wParams);
  sei.nShow := SW_SHOWNORMAL;
  if not ShellExecuteExW(@sei) then
    Fail('Die Installation wurde abgebrochen oder es fehlen Administratorrechte.' +
         LineEnding + 'Bitte als Administrator installieren: ' + VC_URL);
  try
    while Windows.WaitForSingleObject(sei.hProcess, 100) = WAIT_TIMEOUT do
      Application.ProcessMessages;
    code := 0;
    Windows.GetExitCodeProcess(sei.hProcess, code);
  finally
    Windows.CloseHandle(sei.hProcess);
  end;
  Log('Installer beendet (Code ' + IntToStr(code) + ').');
  // 0 = ok, 1638 = neuere Version schon da, 3010 = ok, Neustart empfohlen
  if (code <> 0) and (code <> 1638) and (code <> 3010) then
    Fail('Die Installation des Visual C++ Runtime ist fehlgeschlagen (Code ' +
         IntToStr(code) + ').');
end;

{ Stellt sicher, dass das Runtime vorhanden ist; fragt ggf. nach und installiert. }
procedure TfrmMain.EnsureVcRuntime;
var
  ver: string;
begin
  if VcRuntimeOk(ver) then Exit;

  if ver = '' then
    Log('Visual C++ Runtime (x64) ist nicht installiert.')
  else
    Log('Visual C++ Runtime ' + ver + ' ist zu alt (benötigt: 14.' + IntToStr(VC_MIN_MINOR) + ').');

  if FSilent then
    Fail('Visual C++ Runtime (x64) 14.' + IntToStr(VC_MIN_MINOR) + ' oder neuer fehlt.');

  if MessageDlg('WBCE Portable',
       'Für den Webserver wird das "Microsoft Visual C++ Runtime (x64)" benötigt, ' +
       'das auf diesem PC fehlt oder zu alt ist.' + LineEnding + LineEnding +
       'Jetzt installieren?' + LineEnding +
       '(Einmalig pro PC, dauert ca. 1 Minute. Windows fragt nach Administratorrechten.)',
       mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Fail('Ohne das Visual C++ Runtime kann der Server nicht starten.' + LineEnding +
         'Manuell installieren: ' + VC_URL);

  InstallVcRuntime;

  if not VcRuntimeOk(ver) then
    Fail('Das Visual C++ Runtime wird noch nicht erkannt.' + LineEnding +
         'Bitte Windows neu starten und WBCE Portable erneut öffnen.');
  Log('Visual C++ Runtime ' + ver + ' ist jetzt installiert.');
end;

procedure TfrmMain.WriteConfig(const ATemplate, ADest: string);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.LoadFromFile(FBase + ATemplate);
    L.Text := StringReplace(L.Text, '__BASE__', FBaseFwd, [rfReplaceAll]);
    L.SaveToFile(FBase + ADest);
  finally
    L.Free;
  end;
end;

procedure TfrmMain.SavePids;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Add(IntToStr(FApachePid));
    L.Add(IntToStr(FDbPid));
    L.SaveToFile(FBase + 'tmp\launcher.pid');
  finally
    L.Free;
  end;
end;

procedure TfrmMain.LoadPids;
var
  L: TStringList;
begin
  FApachePid := 0;
  FDbPid := 0;
  if not FileExists(FBase + 'tmp\launcher.pid') then Exit;
  L := TStringList.Create;
  try
    L.LoadFromFile(FBase + 'tmp\launcher.pid');
    if L.Count >= 2 then
    begin
      FApachePid := StrToIntDef(L[0], 0);
      FDbPid := StrToIntDef(L[1], 0);
    end;
  finally
    L.Free;
  end;
end;

procedure TfrmMain.KillPid(APid: DWORD);
begin
  if (APid <> 0) and ProcessAlive(APid) then
    RunWait('taskkill.exe', ['/F', '/T', '/PID', IntToStr(APid)]);
end;

procedure TfrmMain.DoStart;
var
  rc: Integer;
begin
  if FState <> ssStopped then Exit;
  SetState(ssStarting);
  try
    Log('Prüfe Dateien ...');
    CheckFiles;
    EnsureVcRuntime;
    ForceDirectories(FBase + 'data');
    ForceDirectories(FBase + 'logs');
    ForceDirectories(FBase + 'tmp');

    if PortOpen(HTTP_PORT) then
      Fail('Port ' + IntToStr(HTTP_PORT) + ' ist bereits belegt (anderer Webserver?).');
    if PortOpen(DB_PORT) then
      Fail('Port ' + IntToStr(DB_PORT) + ' ist bereits belegt (andere MariaDB/MySQL?).');

    Log('Schreibe Konfiguration (Pfad: ' + FBase + ')');
    WriteConfig('conf-httpd.template', 'Apache24\conf\httpd.conf');
    WriteConfig('conf-php.template', 'php\php.ini');
    WriteConfig('conf-my.template', 'my.ini');

    // PHP-Verzeichnis in den DLL-Suchpfad (curl/intl brauchen DLLs neben php.exe)
    Windows.SetEnvironmentVariableA('PATH',
      PAnsiChar(AnsiString(FBase + 'php;' + SysUtils.GetEnvironmentVariable('PATH'))));

    if not DirectoryExists(FBase + 'data\mysql') then
    begin
      Log('Initialisiere Datenbank (nur beim ersten Start, ca. 10-20 s) ...');
      rc := RunWait(FBase + 'mariadb\bin\mariadb-install-db.exe',
        ['--datadir=' + FBase + 'data']);
      if (rc <> 0) or not DirectoryExists(FBase + 'data\mysql') then
        Fail('Datenbank-Initialisierung fehlgeschlagen (Code ' + IntToStr(rc) + ').' +
             LineEnding + 'Ordner "data" leeren und erneut versuchen.');
    end;

    Log('Starte MariaDB (Port ' + IntToStr(DB_PORT) + ') ...');
    FDbPid := StartBg(FBase + 'mariadb\bin\mysqld.exe',
      ['--defaults-file=' + FBase + 'my.ini']);
    if not WaitForPort(DB_PORT, 60, FDbPid) then
      Fail('MariaDB ist nicht gestartet. Siehe data\*.err');

    RunWait(FBase + 'mariadb\bin\mariadb.exe',
      ['--protocol=tcp', '--port=' + IntToStr(DB_PORT), '-u', 'root', '-e',
       'CREATE DATABASE IF NOT EXISTS wbce CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;']);

    Log('Starte Apache (Port ' + IntToStr(HTTP_PORT) + ') ...');
    FApachePid := StartBg(FBase + 'Apache24\bin\httpd.exe', []);
    if not WaitForPort(HTTP_PORT, 30, FApachePid) then
      Fail('Apache ist nicht gestartet. Siehe logs\apache-error.log');

    SavePids;
    SetState(ssRunning);
    Log('Server läuft: ' + APP_URL);
    if not FileExists(FBase + 'htdocs\wbce\config.php') then
      Log('Erster Start: WBCE-Installer, DB-Host 127.0.0.1:3311, DB wbce, ' +
          'Benutzer root, Passwort leer, System Windows.');
    if not FSilent then OpenURL(APP_URL);
  except
    on E: Exception do
    begin
      Log('FEHLER: ' + E.Message);
      KillPid(FApachePid);
      if FDbPid <> 0 then
        RunWait(FBase + 'mariadb\bin\mariadb-admin.exe',
          ['--protocol=tcp', '--port=' + IntToStr(DB_PORT), '-u', 'root', 'shutdown']);
      KillPid(FDbPid);
      FApachePid := 0;
      FDbPid := 0;
      SetState(ssStopped);
      if not FSilent then MessageDlg('WBCE Portable', E.Message, mtError, [mbOK], 0);
    end;
  end;
end;

procedure TfrmMain.DoStop;
var
  t: QWord;
begin
  if FState in [ssStopped, ssStopping] then Exit;
  SetState(ssStopping);
  Log('Stoppe Apache ...');
  KillPid(FApachePid);

  Log('Fahre MariaDB sauber herunter ...');
  RunWait(FBase + 'mariadb\bin\mariadb-admin.exe',
    ['--protocol=tcp', '--port=' + IntToStr(DB_PORT), '-u', 'root', 'shutdown']);
  t := GetTickCount64 + 30000;
  while ProcessAlive(FDbPid) and (GetTickCount64 < t) do Pause(200);
  if ProcessAlive(FDbPid) then
  begin
    Log('MariaDB reagiert nicht - beende Prozess.');
    KillPid(FDbPid);
  end;

  FApachePid := 0;
  FDbPid := 0;
  SysUtils.DeleteFile(FBase + 'tmp\launcher.pid');
  SetState(ssStopped);
  Log('Gestoppt. Der Stick kann jetzt entfernt werden.');
end;

procedure TfrmMain.StartClick(Sender: TObject);
begin
  DoStart;
end;

procedure TfrmMain.StopClick(Sender: TObject);
begin
  DoStop;
end;

procedure TfrmMain.SiteClick(Sender: TObject);
begin
  OpenURL(APP_URL);
end;

procedure TfrmMain.AdminClick(Sender: TObject);
begin
  OpenURL(ADMIN_URL);
end;

procedure TfrmMain.TimerTick(Sender: TObject);
begin
  if (FState = ssRunning) and
     (not ProcessAlive(FApachePid) or not ProcessAlive(FDbPid)) then
  begin
    Log('Ein Serverprozess wurde unerwartet beendet - stoppe den Rest.');
    DoStop;
  end;
end;

procedure TfrmMain.FormCloseQueryEvent(Sender: TObject; var CanClose: Boolean);
begin
  CanClose := True;
  if FState = ssStopped then Exit;
  if FSilent or
     (MessageDlg('WBCE Portable', 'Der Server läuft noch.' + LineEnding +
        'Jetzt sauber stoppen und das Programm beenden?',
        mtConfirmation, [mbYes, mbNo], 0) = mrYes) then
  begin
    if FState in [ssRunning, ssStarting] then DoStop;
    CanClose := FState = ssStopped;
  end
  else
    CanClose := False;
end;

procedure TfrmMain.FormShowEvent(Sender: TObject);
var
  i: Integer;
  ver: string;
begin
  // Prozesse einer frueheren Sitzung uebernehmen (z. B. Launcher wurde beendet)
  LoadPids;
  if ProcessAlive(FApachePid) and ProcessAlive(FDbPid) then
  begin
    SetState(ssRunning);
    Log('Laufender Server aus früherer Sitzung übernommen.');
  end
  else
  begin
    FApachePid := 0;
    FDbPid := 0;
    SysUtils.DeleteFile(FBase + 'tmp\launcher.pid');
    Log('Bereit. Ordner: ' + FBase);
  end;

  if VcRuntimeOk(ver) then
    Log('Visual C++ Runtime ' + ver + ': OK')
  else
    Log('Visual C++ Runtime fehlt - wird beim Serverstart installiert.');

  for i := 1 to ParamCount do
    if SameText(ParamStr(i), '/vccheck') then
    begin
      // Test: Installer beschaffen und Signatur pruefen, aber NICHT installieren
      try
        Log('vccheck: Installer = ' + VcInstallerPath);
        Log('vccheck: OK');
      except
        on E: Exception do Log('vccheck: FEHLER: ' + E.Message);
      end;
      Close;
      Break;
    end
    else if SameText(ParamStr(i), '/start') or SameText(ParamStr(i), '/selftest') then
    begin
      Application.ProcessMessages;
      DoStart;
      if FSilent then
      begin
        if FState = ssRunning then
        begin
          Pause(3000);
          DoStop;
        end;
        Close;
      end;
      Break;
    end;
end;

end.
