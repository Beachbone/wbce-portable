unit usetup;

{$mode objfpc}{$H+}

{ Automatische Einrichtung von WBCE (statt des Installers im Browser)

  Ablauf (Server muss laufen):
    1. Pruefen: wbce-Datenbank leer, WBCE noch nicht eingerichtet
    2. Zufaelligen DB-Benutzer + Passwort anlegen (nur fuer die Datenbank "wbce")
    3. Das Original-Installerformular (install/save.php) per curl abschicken -
       die Zugangsdaten gehen ueber stdin, nie ueber die Kommandozeile
    4. Optional Demodaten einspielen (demo\demo.sql, falls im Bundle vorhanden)
  Bei einem Fehler wird alles zurueckgesetzt, sodass der normale Installer weiter geht. }

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, Dialogs, Process, Windows, uphp, uwbce;

type
  TSetupData = record
    Title: string;
    User: string;
    Mail: string;
    Pass: string;
    Demo: Boolean;
  end;

function WbceInstalled(const ABase: string): Boolean;
function DemoAvailable(const ABase: string): Boolean;
function ValidateSetup(const D: TSetupData): string;
function RandomString(ALen: Integer): string;
function RunSetup(const ABase: string; const D: TSetupData; ALog: TLogProc;
  out AErr: string): Boolean;
function ShowSetupDialog(AOwner: TComponent; const ABase: string;
  out D: TSetupData): Boolean;
procedure PreviewSetupDialog(AOwner: TComponent; const ABase, AFile: string);

implementation

const
  HTTP_PORT = 4443;
  DB_PORT = 3311;
  SITE_URL = 'http://localhost:4443/wbce';
  INSTALL_URL = 'http://127.0.0.1:4443/wbce/install/';
  DB_NAME = 'wbce';
  DEMO_SQL = 'demo\demo.sql';       // Platzhalter: kommt spaeter, wird dann automatisch angeboten
  PASS_CHARS = 'a-zA-Z0-9 _ - ! # * + @ $ & :';
  ALNUM = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  STUB_CONFIG = '<?php' + #10;

function RtlGenRandom(Buffer: Pointer; Len: ULONG): ByteBool; stdcall;
  external 'advapi32.dll' name 'SystemFunction036';

function GetUserDefaultUILanguage: Word; stdcall; external 'kernel32.dll' name 'GetUserDefaultUILanguage';

function WbceInstalled(const ABase: string): Boolean;
var
  fs: TFileStream;
begin
  Result := False;
  if not FileExists(ABase + 'htdocs\wbce\config.php') then Exit;
  try
    fs := TFileStream.Create(ABase + 'htdocs\wbce\config.php', fmOpenRead or fmShareDenyNone);
    try
      Result := fs.Size > 40;     // der Platzhalter im Archiv hat nur "<?php"
    finally
      fs.Free;
    end;
  except
    Result := True;
  end;
end;

function DemoAvailable(const ABase: string): Boolean;
begin
  Result := FileExists(ABase + DEMO_SQL);
end;

function RandomString(ALen: Integer): string;
var
  b: array of Byte;
  i: Integer;
begin
  SetLength(b, ALen);
  if not RtlGenRandom(@b[0], ALen) then
    raise Exception.Create('Zufallszahlen sind nicht verfügbar.');
  SetLength(Result, ALen);
  for i := 0 to ALen - 1 do
    Result[i + 1] := ALNUM[(b[i] mod Length(ALNUM)) + 1];
end;

function ValidPassChar(c: Char): Boolean;
begin
  Result := c in ['a'..'z', 'A'..'Z', '0'..'9', '_', '-', '!', '#', '*', '+', '@', '$', '&', ':'];
end;

function ValidateSetup(const D: TSetupData): string;
var
  i, at: Integer;
begin
  Result := '';
  if (Length(D.User) < 3) or (Length(D.User) > 30) then
    Exit('Der Benutzername muss 3 bis 30 Zeichen lang sein.');
  for i := 1 to Length(D.User) do
    if not (D.User[i] in ['a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.']) then
      Exit('Im Benutzernamen sind nur Buchstaben, Ziffern und _ - . erlaubt.');
  at := Pos('@', D.Mail);
  if (at < 2) or (Pos('.', Copy(D.Mail, at, 200)) < 3) or (Pos(' ', D.Mail) > 0) then
    Exit('Bitte eine gültige E-Mail-Adresse angeben.');
  if Length(D.Pass) < 12 then
    Exit('Das Passwort muss mindestens 12 Zeichen lang sein.');
  for i := 1 to Length(D.Pass) do
    if not ValidPassChar(D.Pass[i]) then
      Exit('Im Passwort sind nur diese Zeichen erlaubt: ' + PASS_CHARS);
end;

{ Prozess unsichtbar starten, Eingabe ueber stdin, Ausgabe einsammeln }
function RunIO(const Exe: string; const Args: array of string; const WorkDir, Input: string;
  out Output: string): Integer;
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
    if Input <> '' then P.Input.Write(Input[1], Length(Input));
    P.CloseInput;
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

function SqlRoot(const ABase, ASql: string; out AOut: string): Boolean;
begin
  Result := (RunIO(ABase + 'mariadb\bin\mariadb.exe',
    ['--protocol=tcp', '--port=' + IntToStr(DB_PORT), '-u', 'root', '-N', '-B'],
    ABase, ASql, AOut) = 0) and (Pos('ERROR', AOut) = 0);
end;

{ Letzte nicht leere Zeile (die mariadb-Warnung zum Passwortlosen Login steht davor) }
function LastLine(const S: string): string;
var
  L: TStringList;
  i: Integer;
begin
  Result := '';
  L := TStringList.Create;
  try
    L.Text := S;
    for i := L.Count - 1 downto 0 do
      if Trim(L[i]) <> '' then Exit(Trim(L[i]));
  finally
    L.Free;
  end;
end;

function CurlCfgEscape(const S: string): string;
begin
  Result := StringReplace(S, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
end;

function SysExe(const AName: string): string;
begin
  Result := SysUtils.GetEnvironmentVariable('SystemRoot') + '\System32\' + AName;
end;

function CleanTitle(const S: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do
    if not (S[i] in ['\', '"', '''', '<', '>', '&', #0..#31]) then Result := Result + S[i];
  Result := Trim(Result);
  if Result = '' then Result := 'WBCE Portable';
end;

function TimeZoneHours: Integer;
var
  tzi: TIME_ZONE_INFORMATION;
begin
  FillChar(tzi, SizeOf(tzi), 0);
  GetTimeZoneInformation(tzi);
  Result := -(tzi.Bias div 60);
end;

function LanguageCode(const ABase: string): string;
begin
  // Windows-Oberflaechensprache Deutsch -> DE, sonst EN (wenn vorhanden)
  if ((GetUserDefaultUILanguage and $3FF) = $07) and
     FileExists(ABase + 'htdocs\wbce\languages\DE.php') then Result := 'DE'
  else if FileExists(ABase + 'htdocs\wbce\languages\EN.php') then Result := 'EN'
  else Result := 'DE';
end;

function ExtractInstallerErrors(const APage: string): string;
var
  p, q: Integer;
  s: string;
begin
  Result := '';
  s := APage;
  repeat
    p := Pos('<b>Error: </b>', s);
    if p = 0 then Break;
    Delete(s, 1, p + Length('<b>Error: </b>') - 1);
    q := Pos('<br', s);
    if q = 0 then q := Length(s) + 1;
    if Result <> '' then Result := Result + LineEnding;
    Result := Result + Trim(Copy(s, 1, q - 1));
    Delete(s, 1, q);
  until False;
end;

function RunSetup(const ABase: string; const D: TSetupData; ALog: TLogProc;
  out AErr: string): Boolean;
var
  dbUser, dbPass, outp, jar, cfg, page, errs: string;
  userCreated, dbTouched: Boolean;
  rc: Integer;
  sl: TStringList;

  procedure Say(const M: string);
  begin
    if Assigned(ALog) then ALog(M);
  end;

  procedure Cleanup;
  var
    o: string;
  begin
    // Datenbank und Benutzer zuruecksetzen, config.php-Platzhalter wiederherstellen
    if dbTouched then
      SqlRoot(ABase, 'DROP DATABASE IF EXISTS `' + DB_NAME + '`; CREATE DATABASE `' + DB_NAME +
        '` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;', o);
    if userCreated then
      SqlRoot(ABase, 'DROP USER IF EXISTS ''' + dbUser + '''@''127.0.0.1'';', o);
    if WbceInstalled(ABase) then
    begin
      sl := TStringList.Create;
      try
        sl.Text := STUB_CONFIG;
        sl.SaveToFile(ABase + 'htdocs\wbce\config.php');
      finally
        sl.Free;
      end;
    end;
  end;

begin
  Result := False;
  AErr := '';
  userCreated := False;
  dbTouched := False;
  dbUser := '';

  AErr := ValidateSetup(D);
  if AErr <> '' then Exit;
  if WbceInstalled(ABase) then
  begin
    AErr := 'WBCE ist bereits eingerichtet (htdocs\wbce\config.php vorhanden).';
    Exit;
  end;
  if not FileExists(ABase + 'htdocs\wbce\install\save.php') then
  begin
    AErr := 'Der WBCE-Installer fehlt (htdocs\wbce\install\save.php).';
    Exit;
  end;

  try
    // 1) Datenbank pruefen
    if not SqlRoot(ABase, 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=''' +
         DB_NAME + ''';', outp) then
    begin
      AErr := 'Die Datenbank ist nicht erreichbar: ' + Trim(outp);
      Exit;
    end;
    if StrToIntDef(LastLine(outp), -1) <> 0 then
    begin
      AErr := 'Die Datenbank "' + DB_NAME + '" enthält schon Tabellen. ' +
              'Bitte den normalen WBCE-Installer im Browser verwenden.';
      Exit;
    end;

    // 2) zufaelliger DB-Zugang nur fuer diese Datenbank
    dbUser := 'wbce_' + LowerCase(RandomString(8));
    dbPass := RandomString(24);
    Say('Lege Datenbank-Benutzer ' + dbUser + ' an (zufälliges Passwort) ...');
    if not SqlRoot(ABase,
         'CREATE DATABASE IF NOT EXISTS `' + DB_NAME + '` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; ' +
         'CREATE USER ''' + dbUser + '''@''127.0.0.1'' IDENTIFIED BY ''' + dbPass + '''; ' +
         'GRANT ALL PRIVILEGES ON `' + DB_NAME + '`.* TO ''' + dbUser + '''@''127.0.0.1''; ' +
         'FLUSH PRIVILEGES;', outp) then
    begin
      AErr := 'Der Datenbank-Benutzer konnte nicht angelegt werden: ' + Trim(outp);
      Exit;
    end;
    userCreated := True;
    dbTouched := True;

    // 3) Installer-Formular abschicken (Session holen, dann POST)
    ForceDirectories(ABase + 'tmp');
    jar := StringReplace(ABase + 'tmp\setup-cookies.txt', '\', '/', [rfReplaceAll]);
    SysUtils.DeleteFile(ABase + 'tmp\setup-cookies.txt');
    Say('Starte die WBCE-Installation ...');
    rc := RunIO(SysExe('curl.exe'), ['-s', '-L', '-c', jar, '-b', jar, '-o', 'NUL',
            INSTALL_URL + 'index.php'], ABase, '', outp);
    if rc <> 0 then
    begin
      AErr := 'Der Installer ist nicht erreichbar (läuft der Server?).';
      Cleanup;
      Exit;
    end;

    cfg := 'url = "' + INSTALL_URL + 'save.php"' + LineEnding +
           'silent' + LineEnding +
           'output = "NUL"' + LineEnding +
           'write-out = "%{http_code} %{redirect_url}"' + LineEnding +
           'cookie = "' + jar + '"' + LineEnding +
           'cookie-jar = "' + jar + '"' + LineEnding;
      cfg := cfg +
      'data-urlencode = "website_title=' + CurlCfgEscape(CleanTitle(D.Title)) + '"' + LineEnding +
      'data-urlencode = "wb_url=' + SITE_URL + '"' + LineEnding +
      'data-urlencode = "default_timezone=' + IntToStr(TimeZoneHours) + '"' + LineEnding +
      'data-urlencode = "default_language=' + LanguageCode(ABase) + '"' + LineEnding +
      'data-urlencode = "operating_system=windows"' + LineEnding +
      'data-urlencode = "database_host=127.0.0.1:' + IntToStr(DB_PORT) + '"' + LineEnding +
      'data-urlencode = "database_username=' + dbUser + '"' + LineEnding +
      'data-urlencode = "database_password=' + dbPass + '"' + LineEnding +
      'data-urlencode = "database_name=' + DB_NAME + '"' + LineEnding +
      'data-urlencode = "table_prefix=wb_"' + LineEnding +
      'data-urlencode = "admin_username=' + CurlCfgEscape(D.User) + '"' + LineEnding +
      'data-urlencode = "admin_email=' + CurlCfgEscape(D.Mail) + '"' + LineEnding +
      'data-urlencode = "admin_password=' + CurlCfgEscape(D.Pass) + '"' + LineEnding +
      'data-urlencode = "admin_repassword=' + CurlCfgEscape(D.Pass) + '"' + LineEnding +
      'data-urlencode = "remember=true"' + LineEnding +
      'data-urlencode = "install=Install"' + LineEnding;
    RunIO(SysExe('curl.exe'), ['-K', '-'], ABase, cfg, outp);
    cfg := '';

    if Pos('/admin/', outp) = 0 then
    begin
      // Fehlermeldungen des Installers aus der Session holen
      RunIO(SysExe('curl.exe'), ['-s', '-c', jar, '-b', jar,
        INSTALL_URL + 'index.php?sessions_checked=true'], ABase, '', page);
      errs := ExtractInstallerErrors(page);
      if errs = '' then errs := 'Der Installer hat die Eingaben nicht angenommen (Antwort: ' + Trim(outp) + ').';
      AErr := errs;
      SysUtils.DeleteFile(ABase + 'tmp\setup-cookies.txt');
      Cleanup;
      Exit;
    end;
    SysUtils.DeleteFile(ABase + 'tmp\setup-cookies.txt');
    Say('WBCE ist installiert.');

    // 4) Demodaten (Platzhalter fuer spaeter)
    if D.Demo and DemoAvailable(ABase) then
    begin
      Say('Spiele Demodaten ein ...');
      if not SqlRoot(ABase, 'USE `' + DB_NAME + '`; SOURCE ' +
           StringReplace(ABase + DEMO_SQL, '\', '/', [rfReplaceAll]) + ';', outp) then
        Say('Hinweis: Die Demodaten konnten nicht eingespielt werden: ' + Trim(outp));
    end;

    Say('Datenbank-Benutzer ' + dbUser + ' (Passwort steht in htdocs\wbce\config.php).');
    Result := True;
  except
    on E: Exception do
    begin
      AErr := E.Message;
      Cleanup;
      Result := False;
    end;
  end;
end;

{ ---- Dialog --------------------------------------------------------------- }

type
  TSetupForm = class(TForm)
  private
    FBase: string;
    edTitle, edUser, edMail, edPass, edPass2: TEdit;
    chkDemo: TCheckBox;
    lblRules: TLabel;
    btnGen: TWbceButton;
    btnOk: TWbceButton;
    btnCancel: TWbceButton;
    procedure GenClick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
    procedure OkClick(Sender: TObject);
  public
    constructor CreateDlg(AOwner: TComponent; const ABase: string);
    function Data: TSetupData;
  end;

constructor TSetupForm.CreateDlg(AOwner: TComponent; const ABase: string);
var
  y: Integer;
  hdr: TWbceHeader;
  info: TWbceBanner;

  function AddRow(const ACaption: string; out AEdit: TEdit): TEdit;
  var
    L: TLabel;
  begin
    L := TLabel.Create(Self);
    L.Parent := Self;
    L.SetBounds(18, y, 440, 16);
    L.Caption := ACaption;
    L.Font.Style := [fsBold];
    AEdit := TEdit.Create(Self);
    AEdit.Parent := Self;
    AEdit.SetBounds(18, y + 18, 444, 26);
    Result := AEdit;
    Inc(y, 54);
  end;

begin
  inherited CreateNew(AOwner);
  FBase := ABase;
  Caption := 'WBCE automatisch einrichten';
  BorderStyle := bsDialog;
  Position := poOwnerFormCenter;
  ClientWidth := 480;
  ClientHeight := 620;
  WbceStyleForm(Self);

  hdr := TWbceHeader.Create(Self);
  hdr.Parent := Self;
  hdr.Compact := True;
  hdr.SetBounds(0, 0, 480, 52);
  hdr.Title := 'Administrator-Zugang anlegen';

  info := TWbceBanner.Create(Self);
  info.Parent := Self;
  info.SetBounds(18, 66, 444, 52);
  info.Show(bkInfo, 'Die Datenbank bekommt automatisch einen eigenen Benutzer mit zufälligem ' +
    'Passwort. Gespeichert wird er nur in der Datei config.php.');

  y := 132;
  AddRow('Name der Website', edTitle);
  AddRow('Admin-Benutzername', edUser);
  AddRow('E-Mail-Adresse', edMail);
  AddRow('Passwort', edPass);
  edPass.Width := 300;
  btnGen := TWbceButton.Create(Self);
  btnGen.Parent := Self;
  btnGen.Kind := wbSecondary;
  btnGen.SetBounds(326, edPass.Top - 1, 136, 28);
  btnGen.Caption := 'Zufallspasswort';
  btnGen.OnClick := @GenClick;
  AddRow('Passwort wiederholen', edPass2);
  edPass.PasswordChar := '*';
  edPass2.PasswordChar := '*';
  edTitle.Text := 'WBCE Portable';
  edUser.Text := 'admin';

  lblRules := TLabel.Create(Self);
  lblRules.Parent := Self;
  lblRules.SetBounds(18, y - 4, 444, 34);
  lblRules.AutoSize := False;
  lblRules.WordWrap := True;
  lblRules.Font.Color := clWbMuted;
  lblRules.Caption := 'Passwort: mindestens 12 Zeichen; erlaubt sind Buchstaben, Ziffern und ' +
                      '_ - ! # * + @ $ &  :';
  Inc(y, 38);

  chkDemo := TCheckBox.Create(Self);
  chkDemo.Parent := Self;
  chkDemo.SetBounds(18, y, 444, 22);
  chkDemo.Caption := 'Demodaten einrichten';
  chkDemo.Checked := True;
  chkDemo.Visible := DemoAvailable(ABase);
  if chkDemo.Visible then Inc(y, 30);

  ClientHeight := y + 66;

  btnOk := TWbceButton.Create(Self);
  btnOk.Parent := Self;
  btnOk.SetBounds(18, ClientHeight - 54, 218, 38);
  btnOk.Caption := 'Einrichten';
  btnOk.OnClick := @OkClick;

  btnCancel := TWbceButton.Create(Self);
  btnCancel.Parent := Self;
  btnCancel.Kind := wbSecondary;
  btnCancel.SetBounds(244, ClientHeight - 54, 218, 38);
  btnCancel.Caption := 'Installer im Browser benutzen';
  btnCancel.OnClick := @CancelClick;
end;

procedure TSetupForm.CancelClick(Sender: TObject);
begin
  ModalResult := mrCancel;
end;
procedure TSetupForm.GenClick(Sender: TObject);
var
  p: string;
begin
  p := RandomString(16);
  edPass.Text := p;
  edPass2.Text := p;
  edPass.PasswordChar := #0;
  edPass2.PasswordChar := #0;
  lblRules.Caption := 'Das erzeugte Passwort steht jetzt lesbar im Feld - bitte notieren. ' +
                      'Es wird nirgends sonst gespeichert.';
end;

function TSetupForm.Data: TSetupData;
begin
  Result.Title := Trim(edTitle.Text);
  Result.User := Trim(edUser.Text);
  Result.Mail := Trim(edMail.Text);
  Result.Pass := edPass.Text;
  Result.Demo := chkDemo.Visible and chkDemo.Checked;
end;

procedure TSetupForm.OkClick(Sender: TObject);
var
  err: string;
begin
  if edPass.Text <> edPass2.Text then
  begin
    MessageDlg('WBCE einrichten', 'Die beiden Passwörter sind nicht gleich.', mtError, [mbOK], 0);
    Exit;
  end;
  err := ValidateSetup(Data);
  if err <> '' then
  begin
    MessageDlg('WBCE einrichten', err, mtError, [mbOK], 0);
    Exit;
  end;
  ModalResult := mrOK;
end;

function ShowSetupDialog(AOwner: TComponent; const ABase: string;
  out D: TSetupData): Boolean;
var
  F: TSetupForm;
begin
  FillChar(D, SizeOf(D), 0);
  F := TSetupForm.CreateDlg(AOwner, ABase);
  try
    Result := F.ShowModal = mrOK;
    if Result then D := F.Data;
  finally
    F.Free;
  end;
end;

procedure PreviewSetupDialog(AOwner: TComponent; const ABase, AFile: string);
var
  F: TSetupForm;
begin
  F := TSetupForm.CreateDlg(AOwner, ABase);
  try
    F.edMail.Text := 'beispiel@example.com';
    F.GenClick(nil);
    WbcePreviewForm(F, AFile);
  finally
    F.Free;
  end;
end;

end.