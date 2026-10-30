unit umain;

{$mode objfpc}{$H+}

{ WBCE Portable Launcher
  Startet/stoppt Apache + MariaDB aus dem Ordner, in dem die EXE liegt.
  Alles laeuft unsichtbar im Hintergrund; das Fenster zeigt nur den Status.
  Kommandozeile:  /start      Server direkt beim Programmstart starten
                  /selftest   Start, 3 s warten, Stopp, beenden (Log: logs\launcher-selftest.txt)
                  /phpswitch:8.5  neueste PHP-Version des Zweigs laden und aktivieren, beenden
                  /phpuse:php-8.3.36  vorhandenes PHP-Verzeichnis aktivieren, beenden
                  /autosetup  Start, WBCE automatisch einrichten, Stopp (nur zum Testen; Zugangsdaten
                              aus den Umgebungsvariablen WBCE_SETUP_USER, _MAIL, _PASS, _DEMO) }

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls,
  Process, Sockets, LCLIntf, Windows, uphp, usetup, uwbce;

const
  APP_VERSION = '0.5.0';
  HTTP_PORT = 4443;
  DB_PORT   = 3311;
  APP_URL   = 'http://localhost:4443/wbce';
  ADMIN_URL = 'http://localhost:4443/wbce/admin';

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
    FPhpDir: string;      // aktives PHP-Verzeichnis (php oder php-8.x.y), ohne Backslash
    lblPhp: TLabel;
    lblSetup: TLabel;
    header: TWbceHeader;
    status: TWbceStatus;
    steps: TWbceSteps;
    banner: TWbceBanner;
    lblLog: TLabel;
    btnStart: TWbceButton;
    btnStop: TWbceButton;
    btnSite: TWbceButton;
    btnAdmin: TWbceButton;
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
    procedure Relayout;
    procedure ShowBanner(AKind: TWbceBannerKind; const AText: string);
    procedure HideBanner;
    procedure UpdateSetupLabel;
    procedure PreviewMode(const AMode, AFile: string);
    function DoSetup(const D: TSetupData; out AErr: string): Boolean;
    procedure OfferSetup(AFromStart: Boolean);
    procedure SetupClick(Sender: TObject);
    procedure RefreshPhpLabel;
    procedure PhpClick(Sender: TObject);
    procedure PhpCli(const AArg: string);
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
  REQUIRED_FILES: array[0..10] of string = (
    'Apache24\bin\httpd.exe',
    'Apache24\bin\vcruntime140.dll',
    'Apache24\bin\vcruntime140_1.dll',
    'Apache24\bin\msvcp140.dll',
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
    if SameText(ParamStr(i), '/selftest') or (Pos('/phpswitch:', LowerCase(ParamStr(i))) = 1) or
       (Pos('/phpuse:', LowerCase(ParamStr(i))) = 1) or SameText(ParamStr(i), '/autosetup') then
    begin
      FSilent := True;
      FSelfTestLog := FBase + 'logs\launcher-selftest.txt';
    end;

  Caption := 'WBCE Portable ' + APP_VERSION;
  BorderStyle := bsSingle;
  BorderIcons := [biSystemMenu, biMinimize];
  Position := poScreenCenter;
  ClientWidth := 520;
  ClientHeight := 660;
  WbceStyleForm(Self);
  OnCloseQuery := @FormCloseQueryEvent;
  OnShow := @FormShowEvent;

  header := TWbceHeader.Create(Self);
  header.Parent := Self;
  header.SetBounds(0, 0, 520, 64);
  header.Title := 'WBCE Portable';
  header.Subtitle := 'Apache · PHP · MariaDB aus einem Ordner';
  header.RightText := 'Version ' + APP_VERSION;

  status := TWbceStatus.Create(Self);
  status.Parent := Self;
  status.SetBounds(18, 80, 484, 66);

  btnStart := TWbceButton.Create(Self);
  btnStart.Parent := Self;
  btnStart.SetBounds(18, 158, 237, 40);
  btnStart.Caption := 'Server starten';
  btnStart.OnClick := @StartClick;

  btnStop := TWbceButton.Create(Self);
  btnStop.Parent := Self;
  btnStop.SetBounds(265, 158, 237, 40);
  btnStop.Caption := 'Server stoppen';
  btnStop.OnClick := @StopClick;

  btnSite := TWbceButton.Create(Self);
  btnSite.Parent := Self;
  btnSite.Kind := wbSecondary;
  btnSite.SetBounds(18, 206, 237, 32);
  btnSite.Caption := 'Website öffnen';
  btnSite.OnClick := @SiteClick;

  btnAdmin := TWbceButton.Create(Self);
  btnAdmin.Parent := Self;
  btnAdmin.Kind := wbSecondary;
  btnAdmin.SetBounds(265, 206, 237, 32);
  btnAdmin.Caption := 'Administration öffnen';
  btnAdmin.OnClick := @AdminClick;

  banner := TWbceBanner.Create(Self);
  banner.Parent := Self;
  banner.SetBounds(18, 250, 484, 56);

  steps := TWbceSteps.Create(Self);
  steps.Parent := Self;
  steps.AddStep('Dateien prüfen');
  steps.AddStep('Datenbank starten (MariaDB)');
  steps.AddStep('Webserver starten (Apache)');
  steps.AddStep('WBCE einrichten');
  steps.AddStep('Seite öffnen');
  steps.SetBounds(18, 250, 484, steps.NeededHeight);

  lblLog := TLabel.Create(Self);
  lblLog.Parent := Self;
  lblLog.AutoSize := False;
  lblLog.SetBounds(18, 450, 484, 16);
  lblLog.Caption := 'PROTOKOLL';
  lblLog.Font.Size := 8;
  lblLog.Font.Style := [fsBold];
  lblLog.Font.Color := clWbMuted;

  memLog := TMemo.Create(Self);
  memLog.Parent := Self;
  memLog.SetBounds(18, 468, 484, 130);
  memLog.ReadOnly := True;
  memLog.ScrollBars := ssAutoVertical;
  memLog.Font.Name := 'Consolas';
  memLog.Font.Size := 9;
  memLog.Color := clWbCard;
  memLog.BorderStyle := bsSingle;

  lblSetup := TLabel.Create(Self);
  lblSetup.Parent := Self;
  lblSetup.AutoSize := False;
  lblSetup.SetBounds(18, 628, 260, 18);
  lblSetup.Caption := 'WBCE automatisch einrichten ...';
  lblSetup.Hint := 'Administrator-Zugang anlegen und WBCE ohne Browser-Installer einrichten';
  lblSetup.ShowHint := True;
  lblSetup.Visible := False;
  lblSetup.OnClick := @SetupClick;
  WbceStyleLink(lblSetup);

  lblPhp := TLabel.Create(Self);
  lblPhp.Parent := Self;
  lblPhp.AutoSize := False;
  lblPhp.SetBounds(302, 628, 200, 18);
  lblPhp.Alignment := taRightJustify;
  lblPhp.Hint := 'PHP-Version anzeigen oder wechseln';
  lblPhp.ShowHint := True;
  lblPhp.OnClick := @PhpClick;
  WbceStyleLink(lblPhp);

  tmr := TTimer.Create(Self);
  tmr.Interval := 2000;
  tmr.OnTimer := @TimerTick;
  tmr.Enabled := True;

  Relayout;  SetState(ssStopped);
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
      status.SetStatus(clWbRed, 'Server gestoppt', 'Zum Starten auf „Server starten“ klicken.');
    ssStarting:
      status.SetStatus(clWbOrange, 'Server startet ...', 'Datenbank und Webserver werden gestartet.');
    ssRunning:
      status.SetStatus(clWbGreen, 'Server läuft',
        APP_URL + '   ·   Vor dem Abziehen des Sticks stoppen!');
    ssStopping:
      status.SetStatus(clWbOrange, 'Server wird gestoppt ...', 'MariaDB wird sauber heruntergefahren.');
  end;
  btnStart.Enabled := AState = ssStopped;
  btnStop.Enabled := AState = ssRunning;
  btnSite.Enabled := AState = ssRunning;
  btnAdmin.Enabled := AState = ssRunning;
  lblPhp.Enabled := AState in [ssStopped, ssRunning];
  UpdateSetupLabel;
  Application.ProcessMessages;
end;

{ Elemente von oben nach unten anordnen; der Hinweisbalken schiebt die Liste nach unten }
procedure TfrmMain.Relayout;
var
  y: Integer;
begin
  y := 250;
  if banner.Visible then
  begin
    banner.Top := y;
    y := y + banner.Height + 12;
  end;
  steps.Top := y;
  y := y + steps.Height + 12;
  lblLog.Top := y;
  y := y + 18;
  memLog.Top := y;
  memLog.Height := ClientHeight - 38 - y;
  lblSetup.Top := ClientHeight - 28;
  lblPhp.Top := ClientHeight - 28;
end;

procedure TfrmMain.ShowBanner(AKind: TWbceBannerKind; const AText: string);
begin
  banner.Show(AKind, AText);
  Relayout;
end;

procedure TfrmMain.HideBanner;
begin
  banner.Visible := False;
  Relayout;
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
  FPhpDir := PhpActiveDir(FBase);
  if not PhpDirValid(FBase, FPhpDir) then
    Fail('PHP fehlt: ' + FPhpDir + '\php8apache2_4.dll' + LineEnding +
         'Das Programm muss im entpackten WBCE-Portable-Ordner liegen.');
  for i := Low(REQUIRED_FILES) to High(REQUIRED_FILES) do
    if not FileExists(FBase + REQUIRED_FILES[i]) then
      Fail('Datei fehlt: ' + REQUIRED_FILES[i] + LineEnding +
           'Das Programm muss im entpackten WBCE-Portable-Ordner liegen.');
end;

procedure TfrmMain.WriteConfig(const ATemplate, ADest: string);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.LoadFromFile(FBase + ATemplate);
    L.Text := StringReplace(L.Text, '__PHP__', FBaseFwd + FPhpDir, [rfReplaceAll]);
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

{ Entwicklerhilfe: Fenster in einem Beispielzustand als BMP abbilden (Umgebungsvariable
  WBCE_PREVIEW_MODE: bereit, startet, richtet, fertig, fehler) }
procedure TfrmMain.PreviewMode(const AMode, AFile: string);
begin
  if AMode = 'startet' then
  begin
    SetState(ssStarting);
    steps.SetStep(0, wsDone, 'PHP: php');
    steps.SetStep(1, wsDone, 'Port ' + IntToStr(DB_PORT));
    steps.SetStep(2, wsActive, 'Port ' + IntToStr(HTTP_PORT));
    Log('Prüfe Dateien ...');
    Log('Starte MariaDB (Port ' + IntToStr(DB_PORT) + ') ...');
    Log('Starte Apache (Port ' + IntToStr(HTTP_PORT) + ') ...');
  end
  else if (AMode = 'richtet') or (AMode = 'fertig') or (AMode = 'fehler') then
  begin
    FState := ssRunning;
    SetState(ssRunning);
    steps.SetStep(0, wsDone, 'PHP: php');
    steps.SetStep(1, wsDone, 'Port ' + IntToStr(DB_PORT));
    steps.SetStep(2, wsDone, 'Port ' + IntToStr(HTTP_PORT));
    Log('Server läuft: ' + APP_URL);
    if AMode = 'richtet' then
    begin
      steps.SetStep(3, wsActive, 'Admin-Zugang wird angelegt');
      status.SetStatus(clWbOrange, 'WBCE wird eingerichtet ...', 'Bitte einen Moment warten.');
    end
    else if AMode = 'fertig' then
    begin
      steps.SetStep(3, wsDone, 'Admin „admin“ angelegt');
      steps.SetStep(4, wsDone, 'Anmeldeseite geöffnet');
      ShowBanner(bkOk, 'WBCE ist eingerichtet. Anmeldung in der Administration mit dem Benutzer „admin“ und dem gewählten Passwort.');
      Log('WBCE ist eingerichtet. Anmeldung: ' + ADMIN_URL);
    end
    else
    begin
      steps.SetStep(3, wsError, 'fehlgeschlagen');
      ShowBanner(bkError, 'Die Einrichtung ist fehlgeschlagen: e20: Konfigurationsdatei nicht beschreibbar. Alles wurde zurückgesetzt; der Installer im Browser kann benutzt werden.');
      Log('FEHLER bei der Einrichtung: e20 ...');
    end;
  end;
  UpdateSetupLabel;
  WbcePreviewForm(Self, AFile);
  FState := ssStopped;   // Close soll nicht nachfragen
end;

procedure TfrmMain.UpdateSetupLabel;
begin
  lblSetup.Visible := (FState = ssRunning) and not WbceInstalled(FBase);
end;

function TfrmMain.DoSetup(const D: TSetupData; out AErr: string): Boolean;
begin
  Result := False;
  AErr := '';
  if FState <> ssRunning then
  begin
    AErr := 'Der Server läuft nicht.';
    Exit;
  end;
  Log('Richte WBCE ein ...');
  HideBanner;
  steps.SetStep(3, wsActive, 'Admin-Zugang wird angelegt');
  status.SetStatus(clWbOrange, 'WBCE wird eingerichtet ...', 'Bitte einen Moment warten.');
  Enabled := False;
  Screen.Cursor := crHourGlass;
  try
    Result := RunSetup(FBase, D, @Log, AErr);
  finally
    Screen.Cursor := crDefault;
    Enabled := True;
  end;
  status.SetStatus(clWbGreen, 'Server läuft',
    APP_URL + '   ·   Vor dem Abziehen des Sticks stoppen!');
  if Result then
  begin
    steps.SetStep(3, wsDone, 'Admin „' + D.User + '“ angelegt');
    ShowBanner(bkOk, 'WBCE ist eingerichtet. Anmeldung in der Administration mit dem Benutzer „' +
      D.User + '“ und dem gewählten Passwort.');
    Log('WBCE ist eingerichtet. Anmeldung: ' + ADMIN_URL + '  (Benutzer: ' + D.User + ')');
  end
  else
  begin
    steps.SetStep(3, wsError, 'fehlgeschlagen');
    ShowBanner(bkError, 'Die Einrichtung ist fehlgeschlagen: ' + AErr + ' Alles wurde ' +
      'zurückgesetzt; der Installer im Browser kann benutzt werden.');
    Log('FEHLER bei der Einrichtung: ' + AErr);
  end;
  UpdateSetupLabel;
end;

{ Dialog zur automatischen Einrichtung; bei Abbruch/Fehler geht es mit dem Installer im Browser weiter }
procedure TfrmMain.OfferSetup(AFromStart: Boolean);
var
  D: TSetupData;
  err: string;
begin
  if ShowSetupDialog(Self, FBase, D) then
  begin
    if DoSetup(D, err) then
    begin
      OpenURL(ADMIN_URL);
      steps.SetStep(4, wsDone, 'Anmeldeseite geöffnet');
    end
    else if AFromStart then
      OpenURL(APP_URL);
  end
  else if AFromStart then
    OpenURL(APP_URL);
end;
procedure TfrmMain.SetupClick(Sender: TObject);
begin
  if (FState = ssRunning) and not WbceInstalled(FBase) then OfferSetup(False);
end;

procedure TfrmMain.RefreshPhpLabel;
begin
  FPhpDir := PhpActiveDir(FBase);
  if PhpDirValid(FBase, FPhpDir) then
    lblPhp.Caption := 'PHP ' + PhpVersionOf(FBase, FPhpDir)
  else
    lblPhp.Caption := 'PHP fehlt';
end;

procedure TfrmMain.PhpClick(Sender: TObject);
begin
  if not (FState in [ssStopped, ssRunning]) then Exit;
  if ShowPhpDialog(Self, FBase, FState = ssRunning, @Log) then
    RefreshPhpLabel;
end;

{ Kommandozeile: /phpswitch:8.5 oder /phpuse:php-8.3.36 (ohne Oberflaeche, zum Testen) }
procedure TfrmMain.PhpCli(const AArg: string);
var
  offers: TPhpOffers;
  offer: TPhpOffer;
  err, pname: string;
begin
  try
    if Pos('/phpuse:', LowerCase(AArg)) = 1 then
    begin
      pname := Copy(AArg, 9, 200);
      if not PhpDirValid(FBase, pname) then Fail('Kein gültiges PHP-Verzeichnis: ' + pname);
    end
    else
    begin
      if not PhpFetchOffers(offers, err) then Fail(err);
      if not PhpFindOffer(offers, Copy(AArg, 12, 20), offer) then
        Fail('Zweig nicht verfügbar: ' + Copy(AArg, 12, 20));
      pname := PhpInstall(FBase, offer, @Log, err);
      if pname = '' then Fail(err);
    end;
    PhpSetActive(FBase, pname);
    RefreshPhpLabel;
    Log('PHP aktiv: ' + pname + ' (' + lblPhp.Caption + ')');
  except
    on E: Exception do Log('FEHLER: ' + E.Message);
  end;
end;

procedure TfrmMain.DoStart;
var
  rc: Integer;
begin
  if FState <> ssStopped then Exit;
  SetState(ssStarting);
  HideBanner;
  steps.ResetAll;
  try
    steps.SetStep(0, wsActive);
    Log('Prüfe Dateien ...');
    CheckFiles;
    steps.SetStep(0, wsDone, 'PHP: ' + FPhpDir);
    ForceDirectories(FBase + 'data');
    ForceDirectories(FBase + 'logs');
    ForceDirectories(FBase + 'tmp');

    if PortOpen(HTTP_PORT) then
      Fail('Port ' + IntToStr(HTTP_PORT) + ' ist bereits belegt (anderer Webserver?).');
    if PortOpen(DB_PORT) then
      Fail('Port ' + IntToStr(DB_PORT) + ' ist bereits belegt (andere MariaDB/MySQL?).');

    Log('Schreibe Konfiguration (Pfad: ' + FBase + ', PHP: ' + FPhpDir + ')');
    WriteConfig('conf-httpd.template', 'Apache24\conf\httpd.conf');
    WriteConfig('conf-php.template', FPhpDir + '\php.ini');
    WriteConfig('conf-my.template', 'my.ini');

    // PHP-Verzeichnis in den DLL-Suchpfad (curl/intl brauchen DLLs neben php.exe)
    Windows.SetEnvironmentVariableA('PATH',
      PAnsiChar(AnsiString(FBase + FPhpDir + ';' + SysUtils.GetEnvironmentVariable('PATH'))));

    if not DirectoryExists(FBase + 'data\mysql') then
    begin
      steps.SetStep(1, wsActive, 'Erstinitialisierung ...');
      Log('Initialisiere Datenbank (nur beim ersten Start, ca. 10-20 s) ...');
      rc := RunWait(FBase + 'mariadb\bin\mariadb-install-db.exe',
        ['--datadir=' + FBase + 'data']);
      if (rc <> 0) or not DirectoryExists(FBase + 'data\mysql') then
        Fail('Datenbank-Initialisierung fehlgeschlagen (Code ' + IntToStr(rc) + ').' +
             LineEnding + 'Ordner "data" leeren und erneut versuchen.');
    end;

    steps.SetStep(1, wsActive, 'Port ' + IntToStr(DB_PORT));
    Log('Starte MariaDB (Port ' + IntToStr(DB_PORT) + ') ...');
    FDbPid := StartBg(FBase + 'mariadb\bin\mysqld.exe',
      ['--defaults-file=' + FBase + 'my.ini']);
    if not WaitForPort(DB_PORT, 60, FDbPid) then
      Fail('MariaDB ist nicht gestartet. Siehe data\*.err');
    steps.SetStep(1, wsDone, 'Port ' + IntToStr(DB_PORT));

    RunWait(FBase + 'mariadb\bin\mariadb.exe',
      ['--protocol=tcp', '--port=' + IntToStr(DB_PORT), '-u', 'root', '-e',
       'CREATE DATABASE IF NOT EXISTS wbce CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;']);

    steps.SetStep(2, wsActive, 'Port ' + IntToStr(HTTP_PORT));
    Log('Starte Apache (Port ' + IntToStr(HTTP_PORT) + ') ...');
    FApachePid := StartBg(FBase + 'Apache24\bin\httpd.exe', []);
    if not WaitForPort(HTTP_PORT, 30, FApachePid) then
      Fail('Apache ist nicht gestartet. Siehe logs\apache-error.log');
    steps.SetStep(2, wsDone, 'Port ' + IntToStr(HTTP_PORT));

    SavePids;
    SetState(ssRunning);
    Log('Server läuft: ' + APP_URL);
    if not FileExists(FBase + 'htdocs\wbce\config.php') then
      Log('Erster Start: WBCE-Installer, DB-Host 127.0.0.1:3311, DB wbce, ' +
          'Benutzer root, Passwort leer, System Windows.');
    if WbceInstalled(FBase) then
      steps.SetStep(3, wsDone, 'bereits eingerichtet')
    else
      steps.SetStep(3, wsWait, 'noch nicht eingerichtet');
    if not FSilent then
    begin
      if WbceInstalled(FBase) then
      begin
        OpenURL(APP_URL);
        steps.SetStep(4, wsDone, 'Browser geöffnet');
      end
      else OfferSetup(True);
    end;
  except
    on E: Exception do
    begin
      Log('FEHLER: ' + E.Message);
      if steps.ActiveIndex >= 0 then steps.SetStep(steps.ActiveIndex, wsError, 'fehlgeschlagen');
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
  steps.ResetAll;
  HideBanner;
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
  D: TSetupData;
  err: string;
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
  RefreshPhpLabel;

  for i := 1 to ParamCount do
    if Pos('/preview', LowerCase(ParamStr(i))) = 1 then
    begin
      if Pos('/previewsetup:', LowerCase(ParamStr(i))) = 1 then
        PreviewSetupDialog(Self, FBase, Copy(ParamStr(i), 15, 500))
      else if Pos('/previewphp:', LowerCase(ParamStr(i))) = 1 then
        PreviewPhpDialog(Self, FBase, Copy(ParamStr(i), 13, 500))
      else
        PreviewMode(SysUtils.GetEnvironmentVariable('WBCE_PREVIEW_MODE'), Copy(ParamStr(i), 10, 500));
      Close;
      Break;
    end
    else if (Pos('/phpswitch:', LowerCase(ParamStr(i))) = 1) or (Pos('/phpuse:', LowerCase(ParamStr(i))) = 1) then
    begin
      PhpCli(ParamStr(i));
      Close;
      Break;
    end
    else if SameText(ParamStr(i), '/autosetup') then
    begin
      Application.ProcessMessages;
      DoStart;
      if FState = ssRunning then
      begin
        D.Title := 'WBCE Portable';
        D.User := SysUtils.GetEnvironmentVariable('WBCE_SETUP_USER');
        D.Mail := SysUtils.GetEnvironmentVariable('WBCE_SETUP_MAIL');
        D.Pass := SysUtils.GetEnvironmentVariable('WBCE_SETUP_PASS');
        D.Demo := SysUtils.GetEnvironmentVariable('WBCE_SETUP_DEMO') = '1';
        DoSetup(D, err);
        Pause(1500);
        DoStop;
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
