unit uphp;

{$mode objfpc}{$H+}

{ PHP-Verwaltung fuer WBCE Portable
  - mehrere PHP-Versionen nebeneinander (php, php-8.5.12-1, ...)
  - aktive Version steht in php-actDir.txt (fehlt die Datei: Ordner "php")
  - weitere Versionen werden von downloads.php.net geladen (releases.json),
    per SHA-256 geprueft, entpackt und mit den VC++-Runtime-DLLs aus Apache24\bin versehen }

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, Dialogs, Process, Windows, FileUtil, uwbce,
  fpjson, jsonparser;

type
  TLogProc = procedure(const AMsg: string) of object;

  TPhpOffer = record
    Branch: string;     // z. B. 8.5
    Version: string;    // z. B. 8.5.12-1
    ZipFile: string;    // z. B. php-8.5.12-1-Win32-vs17-x64.zip
    Sha256: string;
    Size: string;       // z. B. 34.76MB
  end;
  TPhpOffers = array of TPhpOffer;

const
  PHP_DOWNLOAD_BASE = 'https://downloads.php.net/~windows/releases/';
  // aelter als 8.2 ist (fuer WBCE 1.6.9 ohnehin) nicht mehr sinnvoll: EOL
  PHP_MIN_MAJOR = 8;
  PHP_MIN_MINOR = 2;

function PhpActiveDir(const ABase: string): string;
function PhpDirValid(const ABase, ADir: string): Boolean;
procedure PhpSetActive(const ABase, ADir: string);
function PhpVersionOf(const ABase, ADir: string): string;
function PhpFetchOffers(out AOffers: TPhpOffers; out AErr: string): Boolean;
function PhpFindOffer(const AOffers: TPhpOffers; const ABranch: string;
  out AOffer: TPhpOffer): Boolean;
function PhpInstall(const ABase: string; const AOffer: TPhpOffer; ALog: TLogProc;
  out AErr: string): string;
function ShowPhpDialog(AOwner: TComponent; const ABase: string;
  AServerRunning: Boolean; ALog: TLogProc): Boolean;
procedure PreviewPhpDialog(AOwner: TComponent; const ABase, AFile: string);

implementation

const
  ACTIVE_FILE = 'php-active.txt';
  VC_DLLS: array[0..2] of string = ('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll');

function SysExe(const AName: string): string;
begin
  Result := SysUtils.GetEnvironmentVariable('SystemRoot') + '\System32\' + AName;
end;

{ Startet einen Prozess unsichtbar, sammelt die Ausgabe, haelt die Oberflaeche am Leben. }
function RunCapture(const Exe: string; const Args: array of string;
  const WorkDir: string; out Output: string): Integer;
var
  P: TProcess;
  S: TStringStream;
  buf: array[0..4095] of Byte;
  n, i: Integer;
begin
  S := TStringStream.Create('');
  P := TProcess.Create(nil);
  try
    P.Executable := Exe;
    for i := 0 to High(Args) do P.Parameters.Add(Args[i]);
    if WorkDir <> '' then P.CurrentDirectory := WorkDir;
    P.Options := [poUsePipes, poNoConsole, poStderrToOutPut];
    P.ShowWindow := swoHide;
    P.Execute;
    while P.Running or (P.Output.NumBytesAvailable > 0) do
    begin
      if P.Output.NumBytesAvailable > 0 then
      begin
        n := P.Output.Read(buf, SizeOf(buf));
        if n > 0 then S.Write(buf, n);
      end
      else
      begin
        Application.ProcessMessages;
        Sleep(20);
      end;
    end;
    Result := P.ExitStatus;
    Output := S.DataString;
  finally
    P.Free;
    S.Free;
  end;
end;

function SafeDirName(const ADir: string): Boolean;
var
  i: Integer;
begin
  Result := (ADir <> '') and ((ADir = 'php') or (Copy(ADir, 1, 4) = 'php-'));
  if not Result then Exit;
  for i := 1 to Length(ADir) do
    if not (ADir[i] in ['a'..'z', 'A'..'Z', '0'..'9', '.', '-', '_']) then
      Exit(False);
end;

function PhpDirValid(const ABase, ADir: string): Boolean;
begin
  Result := SafeDirName(ADir) and FileExists(ABase + ADir + '\php8apache2_4.dll') and
            FileExists(ABase + ADir + '\php8ts.dll');
end;

function PhpActiveDir(const ABase: string): string;
var
  L: TStringList;
begin
  Result := 'php';
  if not FileExists(ABase + ACTIVE_FILE) then Exit;
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(ABase + ACTIVE_FILE);
      if (L.Count > 0) and PhpDirValid(ABase, Trim(L[0])) then
        Result := Trim(L[0]);
    except
      Result := 'php';
    end;
  finally
    L.Free;
  end;
end;

procedure PhpSetActive(const ABase, ADir: string);
var
  L: TStringList;
begin
  if not SafeDirName(ADir) then Exit;
  if ADir = 'php' then
  begin
    SysUtils.DeleteFile(ABase + ACTIVE_FILE);
    Exit;
  end;
  L := TStringList.Create;
  try
    L.Add(ADir);
    L.SaveToFile(ABase + ACTIVE_FILE);
  finally
    L.Free;
  end;
end;

function PhpVersionOf(const ABase, ADir: string): string;
var
  out_: string;
begin
  Result := '?';
  if not FileExists(ABase + ADir + '\php.exe') then Exit;
  try
    if (RunCapture(ABase + ADir + '\php.exe', ['-n', '-r', 'echo PHP_VERSION;'],
        ABase + ADir, out_) = 0) and (Trim(out_) <> '') then
      Result := Trim(out_);
  except
    Result := '?';
  end;
end;

function BranchOk(const ABranch: string): Boolean;
var
  p, maj, mi: Integer;
begin
  p := Pos('.', ABranch);
  if p = 0 then Exit(False);
  maj := StrToIntDef(Copy(ABranch, 1, p - 1), 0);
  mi := StrToIntDef(Copy(ABranch, p + 1, 10), -1);
  Result := (maj > PHP_MIN_MAJOR) or ((maj = PHP_MIN_MAJOR) and (mi >= PHP_MIN_MINOR));
end;

function BranchKey(const ABranch: string): Integer;
var
  p: Integer;
begin
  p := Pos('.', ABranch);
  Result := StrToIntDef(Copy(ABranch, 1, p - 1), 0) * 1000 + StrToIntDef(Copy(ABranch, p + 1, 10), 0);
end;

function PhpFetchOffers(out AOffers: TPhpOffers; out AErr: string): Boolean;
var
  S: string;
  J: TJSONData;
  O, B, Z: TJSONObject;
  D: TJSONData;
  i, k, n, a, b2: Integer;
  nm: string;
  tmp: TPhpOffer;
begin
  Result := False;
  AErr := '';
  SetLength(AOffers, 0);
  try
    if RunCapture(SysExe('curl.exe'), ['-sSL', '--fail', '--max-time', '30',
         PHP_DOWNLOAD_BASE + 'releases.json'], '', S) <> 0 then
    begin
      AErr := 'Die Versionsliste von php.net konnte nicht geladen werden (keine Internetverbindung?).';
      Exit;
    end;
    J := GetJSON(S);
    try
      if not (J is TJSONObject) then
      begin
        AErr := 'Die Versionsliste von php.net hat ein unerwartetes Format.';
        Exit;
      end;
      O := TJSONObject(J);
      for i := 0 to O.Count - 1 do
      begin
        if not (O.Items[i] is TJSONObject) then Continue;
        if not BranchOk(O.Names[i]) then Continue;
        B := TJSONObject(O.Items[i]);
        for k := 0 to B.Count - 1 do
        begin
          nm := B.Names[k];
          // thread-safe x64 ("ts-vsNN-x64"; "nts-..." beginnt anders)
          if (Pos('ts-vs', nm) = 1) and (Pos('-x64', nm) = Length(nm) - 3) and
             (B.Items[k] is TJSONObject) then
          begin
            D := TJSONObject(B.Items[k]).Find('zip');
            if not (D is TJSONObject) then Continue;
            Z := TJSONObject(D);
            n := Length(AOffers);
            SetLength(AOffers, n + 1);
            AOffers[n].Branch := O.Names[i];
            AOffers[n].Version := B.Get('version', '');
            AOffers[n].ZipFile := Z.Get('path', '');
            AOffers[n].Sha256 := LowerCase(Z.Get('sha256', ''));
            AOffers[n].Size := Z.Get('size', '');
            Break;
          end;
        end;
      end;
    finally
      J.Free;
    end;
    // neueste Version zuerst
    for a := 0 to High(AOffers) - 1 do
      for b2 := a + 1 to High(AOffers) do
        if BranchKey(AOffers[b2].Branch) > BranchKey(AOffers[a].Branch) then
        begin
          tmp := AOffers[a];
          AOffers[a] := AOffers[b2];
          AOffers[b2] := tmp;
        end;
    Result := Length(AOffers) > 0;
    if not Result then AErr := 'Die Versionsliste enthält keine passenden PHP-Versionen.';
  except
    on E: Exception do
    begin
      AErr := 'Die Versionsliste konnte nicht gelesen werden: ' + E.Message;
      Result := False;
    end;
  end;
end;

function PhpFindOffer(const AOffers: TPhpOffers; const ABranch: string;
  out AOffer: TPhpOffer): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(AOffers) do
    if AOffers[i].Branch = ABranch then
    begin
      AOffer := AOffers[i];
      Exit(True);
    end;
end;

function IsHex64(const S: string): Boolean;
var
  i: Integer;
begin
  Result := Length(S) = 64;
  if not Result then Exit;
  for i := 1 to 64 do
    if not (S[i] in ['0'..'9', 'a'..'f']) then Exit(False);
end;

function FileSha256(const AFile: string): string;
var
  outp: string;
  L: TStringList;
  i: Integer;
  s: string;
begin
  Result := '';
  // certutil gehoert zu Windows; die Ausgabe ist je nach Sprache anders beschriftet,
  // der Hashwert steht aber in einer eigenen Zeile
  if RunCapture(SysExe('certutil.exe'), ['-hashfile', AFile, 'SHA256'], '', outp) <> 0 then Exit;
  L := TStringList.Create;
  try
    L.Text := outp;
    for i := 0 to L.Count - 1 do
    begin
      s := LowerCase(StringReplace(Trim(L[i]), ' ', '', [rfReplaceAll]));
      if IsHex64(s) then Exit(s);
    end;
  finally
    L.Free;
  end;
end;

function CopyFileOver(const ASrc, ADst: string): Boolean;
begin
  Result := Windows.CopyFileW(PWideChar(UnicodeString(ASrc)), PWideChar(UnicodeString(ADst)), False);
end;

function PhpInstall(const ABase: string; const AOffer: TPhpOffer; ALog: TLogProc;
  out AErr: string): string;
var
  pname, dest, part, zip, outp, h: string;
  i: Integer;
  sz: Int64;

  procedure Say(const M: string);
  begin
    if Assigned(ALog) then ALog(M);
  end;

begin
  Result := '';
  AErr := '';
  pname := 'php-' + AOffer.Version;
  if not SafeDirName(pname) then
  begin
    AErr := 'Ungültiger Versionsname: ' + AOffer.Version;
    Exit;
  end;
  dest := ABase + pname;
  part := dest + '.part';
  zip := ABase + 'tmp\' + AOffer.ZipFile;
  if PhpDirValid(ABase, pname) then Exit(pname);   // schon da

  try
    ForceDirectories(ABase + 'tmp');
    if DirectoryExists(part) then DeleteDirectory(part, False);
    SysUtils.DeleteFile(zip);

    Say('Lade PHP ' + AOffer.Version + ' (' + AOffer.Size + ') von downloads.php.net ...');
    if RunCapture(SysExe('curl.exe'), ['-sSL', '--fail', '--max-time', '1200', '-o', zip,
         PHP_DOWNLOAD_BASE + AOffer.ZipFile], ABase, outp) <> 0 then
    begin
      AErr := 'Der Download ist fehlgeschlagen (keine Internetverbindung?).';
      Exit;
    end;
    sz := 0;
    if FileExists(zip) then
      with TFileStream.Create(zip, fmOpenRead or fmShareDenyNone) do
      try
        sz := Size;
      finally
        Free;
      end;
    if sz < 1000000 then
    begin
      AErr := 'Die heruntergeladene Datei ist zu klein - Download unvollständig.';
      Exit;
    end;

    Say('Prüfe SHA-256 ...');
    h := FileSha256(zip);
    if (h = '') or (AOffer.Sha256 = '') or (h <> AOffer.Sha256) then
    begin
      SysUtils.DeleteFile(zip);
      AErr := 'Die SHA-256-Prüfsumme stimmt nicht mit php.net überein - Datei wird verworfen.';
      Exit;
    end;

    Say('Entpacke nach ' + pname + ' ...');
    ForceDirectories(part);
    if RunCapture(SysExe('tar.exe'), ['-xf', zip, '-C', part], ABase, outp) <> 0 then
    begin
      AErr := 'Das Entpacken ist fehlgeschlagen: ' + Trim(outp);
      DeleteDirectory(part, False);
      Exit;
    end;
    if not (FileExists(part + '\php8apache2_4.dll') and FileExists(part + '\php8ts.dll') and
            FileExists(part + '\php.exe')) then
    begin
      AErr := 'Das Archiv enthält kein passendes PHP (php8apache2_4.dll fehlt).';
      DeleteDirectory(part, False);
      Exit;
    end;

    // VC++-Runtime-DLLs wie beim mitgelieferten PHP (php.exe sucht zuerst im eigenen Ordner)
    for i := 0 to High(VC_DLLS) do
      if FileExists(ABase + 'Apache24\bin\' + VC_DLLS[i]) then
        CopyFileOver(ABase + 'Apache24\bin\' + VC_DLLS[i], part + '\' + VC_DLLS[i]);

    if not RenameFile(part, dest) then
    begin
      AErr := 'Der Ordner konnte nicht umbenannt werden.';
      DeleteDirectory(part, False);
      Exit;
    end;
    SysUtils.DeleteFile(zip);
    Result := pname;
  except
    on E: Exception do
    begin
      AErr := E.Message;
      Result := '';
    end;
  end;
end;

{ ---- Dialog --------------------------------------------------------------- }

type
  TPhpForm = class(TForm)
  private
    FBase: string;
    FRunning: Boolean;
    FLog: TLogProc;
    FOffers: TPhpOffers;
    FOnlineErr: string;
    FKind: TStringList;     // je Eintrag "I:<ordner>" oder "O:<index>"
    FBusy: Boolean;
    FChanged: Boolean;
    lblInfo: TLabel;
    lst: TListBox;
    lblHint: TLabel;
    btnApply: TWbceButton;
    btnClose: TWbceButton;
    procedure FillList;
    procedure UpdateButtons;
    procedure ListClick(Sender: TObject);
    procedure ApplyClick(Sender: TObject);
    procedure CloseClick(Sender: TObject);
    procedure CloseQueryEvent(Sender: TObject; var CanClose: Boolean);
  public
    constructor CreateDlg(AOwner: TComponent; const ABase: string;
      ARunning: Boolean; ALog: TLogProc);
    destructor Destroy; override;
    procedure LoadOffers;
    property Changed: Boolean read FChanged;
  end;

constructor TPhpForm.CreateDlg(AOwner: TComponent; const ABase: string;
  ARunning: Boolean; ALog: TLogProc);
var
  hdr: TWbceHeader;
begin
  inherited CreateNew(AOwner);
  FBase := ABase;
  FRunning := ARunning;
  FLog := ALog;
  FKind := TStringList.Create;

  Caption := 'PHP-Version';
  BorderStyle := bsDialog;
  Position := poOwnerFormCenter;
  ClientWidth := 480;
  ClientHeight := 400;
  OnCloseQuery := @CloseQueryEvent;
  WbceStyleForm(Self);

  hdr := TWbceHeader.Create(Self);
  hdr.Parent := Self;
  hdr.Compact := True;
  hdr.SetBounds(0, 0, 480, 52);
  hdr.Title := 'PHP-Version wechseln';

  lblInfo := TLabel.Create(Self);
  lblInfo.Parent := Self;
  lblInfo.SetBounds(18, 64, 444, 20);
  lblInfo.AutoSize := False;
  lblInfo.WordWrap := True;
  lblInfo.Font.Color := clWbMuted;
  lblInfo.Caption := 'Installierte und bei php.net verfügbare Versionen (thread safe, x64).';

  lst := TListBox.Create(Self);
  lst.Parent := Self;
  lst.SetBounds(18, 90, 444, 170);
  lst.ItemHeight := 24;
  lst.OnClick := @ListClick;

  lblHint := TLabel.Create(Self);
  lblHint.Parent := Self;
  lblHint.SetBounds(18, 270, 444, 54);
  lblHint.AutoSize := False;
  lblHint.WordWrap := True;
  lblHint.Font.Color := clWbMuted;

  btnApply := TWbceButton.Create(Self);
  btnApply.Parent := Self;
  btnApply.SetBounds(18, 340, 300, 38);
  btnApply.OnClick := @ApplyClick;

  btnClose := TWbceButton.Create(Self);
  btnClose.Parent := Self;
  btnClose.Kind := wbSecondary;
  btnClose.SetBounds(326, 340, 136, 38);
  btnClose.Caption := 'Schließen';
  btnClose.OnClick := @CloseClick;
end;

procedure TPhpForm.CloseClick(Sender: TObject);
begin
  if not FBusy then ModalResult := mrCancel;
end;
destructor TPhpForm.Destroy;
begin
  FKind.Free;
  inherited Destroy;
end;

procedure TPhpForm.LoadOffers;
begin
  lblHint.Caption := 'Lade Versionsliste von php.net ...';
  Application.ProcessMessages;
  Screen.Cursor := crHourGlass;
  try
    PhpFetchOffers(FOffers, FOnlineErr);
  finally
    Screen.Cursor := crDefault;
  end;
  FillList;
end;

procedure TPhpForm.FillList;
var
  sr: TSearchRec;
  dirs: TStringList;
  i, j: Integer;
  actDir, ver, baseVer, line: string;
  vers: TStringList;
  known: Boolean;
begin
  lst.Items.Clear;
  FKind.Clear;
  actDir := PhpActiveDir(FBase);
  dirs := TStringList.Create;
  vers := TStringList.Create;
  try
    if SysUtils.FindFirst(FBase + 'php*', faDirectory, sr) = 0 then
    try
      repeat
        if ((sr.Attr and faDirectory) <> 0) and PhpDirValid(FBase, sr.Name) then
          dirs.Add(sr.Name);
      until SysUtils.FindNext(sr) <> 0;
    finally
      SysUtils.FindClose(sr);
    end;
    dirs.Sort;

    for i := 0 to dirs.Count - 1 do
    begin
      ver := PhpVersionOf(FBase, dirs[i]);
      vers.Add(ver);
      line := 'PHP ' + ver + '   (installiert';
      if dirs[i] = actDir then line := line + ', aktiv';
      line := line + ')';
      lst.Items.Add(line);
      FKind.Add('I:' + dirs[i]);
    end;

    for i := 0 to High(FOffers) do
    begin
      baseVer := FOffers[i].Version;
      j := Pos('-', baseVer);
      if j > 0 then baseVer := Copy(baseVer, 1, j - 1);
      known := vers.IndexOf(baseVer) >= 0;
      if known then Continue;
      lst.Items.Add('PHP ' + FOffers[i].Version + '   (Download, ' +
        StringReplace(StringReplace(FOffers[i].Size, '.', ',', []), 'MB', ' MB', []) + ')');
      FKind.Add('O:' + IntToStr(i));
    end;
  finally
    dirs.Free;
    vers.Free;
  end;

  // aktive Version vorwaehlen
  for i := 0 to FKind.Count - 1 do
    if FKind[i] = 'I:' + actDir then lst.ItemIndex := i;

  if FOnlineErr <> '' then
    lblHint.Caption := FOnlineErr + ' Es werden nur die installierten Versionen angezeigt.'
  else if FRunning then
    lblHint.Caption := 'Der Server läuft - zum Wechseln zuerst den Server stoppen.'
  else
    lblHint.Caption := 'Die gewählte Version wird beim nächsten Serverstart verwendet. ' +
                       'Die Daten bleiben unverändert.';
  UpdateButtons;
end;

procedure TPhpForm.UpdateButtons;
var
  k, actDir: string;
begin
  actDir := PhpActiveDir(FBase);
  btnApply.Enabled := False;
  btnApply.Caption := 'Aktivieren';
  if (lst.ItemIndex < 0) or FBusy then Exit;
  k := FKind[lst.ItemIndex];
  if Copy(k, 1, 2) = 'O:' then
    btnApply.Caption := 'Herunterladen und aktivieren'
  else
    btnApply.Caption := 'Aktivieren';
  btnApply.Enabled := (not FRunning) and (k <> 'I:' + actDir);
end;

procedure TPhpForm.ListClick(Sender: TObject);
begin
  UpdateButtons;
end;

procedure TPhpForm.ApplyClick(Sender: TObject);
var
  k, pname, err: string;
begin
  if lst.ItemIndex < 0 then Exit;
  k := FKind[lst.ItemIndex];
  FBusy := True;
  lst.Enabled := False;
  btnApply.Enabled := False;
  btnClose.Enabled := False;
  Screen.Cursor := crHourGlass;
  try
    if Copy(k, 1, 2) = 'O:' then
    begin
      lblHint.Caption := 'Lade und installiere PHP - bitte warten (ca. 35 MB) ...';
      Application.ProcessMessages;
      pname := PhpInstall(FBase, FOffers[StrToInt(Copy(k, 3, 10))], FLog, err);
      if pname = '' then
      begin
        MessageDlg('PHP-Version', err, mtError, [mbOK], 0);
        Exit;
      end;
    end
    else
      pname := Copy(k, 3, 200);
    PhpSetActive(FBase, pname);
    if Assigned(FLog) then FLog('PHP-Version gewechselt: ' + pname);
    FChanged := True;
  finally
    Screen.Cursor := crDefault;
    FBusy := False;
    lst.Enabled := True;
    btnClose.Enabled := True;
    if FChanged then ModalResult := mrOK else FillList;
  end;
end;

procedure TPhpForm.CloseQueryEvent(Sender: TObject; var CanClose: Boolean);
begin
  CanClose := not FBusy;
end;

function ShowPhpDialog(AOwner: TComponent; const ABase: string;
  AServerRunning: Boolean; ALog: TLogProc): Boolean;
var
  F: TPhpForm;
begin
  F := TPhpForm.CreateDlg(AOwner, ABase, AServerRunning, ALog);
  try
    F.LoadOffers;
    F.ShowModal;
    Result := F.Changed;
  finally
    F.Free;
  end;
end;

procedure PreviewPhpDialog(AOwner: TComponent; const ABase, AFile: string);
var
  F: TPhpForm;
begin
  F := TPhpForm.CreateDlg(AOwner, ABase, False, nil);
  try
    F.LoadOffers;
    WbcePreviewForm(F, AFile);
  finally
    F.Free;
  end;
end;

end.