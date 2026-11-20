unit uconfig;

{$mode objfpc}{$H+}

{ Einstellungen von WBCE Portable (Datei portable.ini im Programmordner)

    [ports]
    http=4443        Webserver (Apache)
    db=3311          Datenbank (MariaDB)
    [browser]
    open=site        was beim Start im Browser geoeffnet wird: site | admin | none

  Die Datei wird beim ersten Start mit den Standardwerten angelegt und gehoert zu den
  Nutzerdaten (nicht im ZIP). Die Ports werden beim Start in httpd.conf/my.ini
  eingesetzt und - falls WBCE schon eingerichtet ist - in htdocs\wbce\config.php
  (DB_PORT und der Port in WB_URL) nachgezogen. }

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, Dialogs, IniFiles, RegExpr,
  Sockets, Windows, uwbce;

const
  DEFAULT_HTTP_PORT = 4443;
  DEFAULT_DB_PORT = 3311;
  CONFIG_FILE = 'portable.ini';

type
  TOpenTarget = (otSite, otAdmin, otNone);

  TPortableConfig = record
    HttpPort: Integer;
    DbPort: Integer;
    OpenTarget: TOpenTarget;
  end;

var
  Cfg: TPortableConfig;   // aktuelle Einstellungen (LoadConfig beim Programmstart)

procedure LoadConfig(const ABase: string);
procedure SaveConfig(const ABase: string; const C: TPortableConfig);
function SiteUrl: string;
function AdminUrl: string;
function InstallUrl: string;
function PortInUse(APort: Integer): Boolean;
function ValidPort(APort: Integer): Boolean;
function ApplyPorts(const AText: string): string;
function SyncWbceConfig(const ABase: string; out AMsg: string): Boolean;
function ShowSettingsDialog(AOwner: TComponent; const ABase: string;
  AServerStopped: Boolean): Boolean;
procedure PreviewSettingsDialog(AOwner: TComponent; const ABase, AFile: string);

implementation

const
  OPEN_NAMES: array[TOpenTarget] of string = ('site', 'admin', 'none');

function ValidPort(APort: Integer): Boolean;
begin
  Result := (APort >= 1024) and (APort <= 65535);
end;

procedure LoadConfig(const ABase: string);
var
  ini: TIniFile;
  s: string;
  t: TOpenTarget;
begin
  Cfg.HttpPort := DEFAULT_HTTP_PORT;
  Cfg.DbPort := DEFAULT_DB_PORT;
  Cfg.OpenTarget := otSite;
  if not FileExists(ABase + CONFIG_FILE) then
  begin
    try
      SaveConfig(ABase, Cfg);
    except
      // schreibgeschuetzter Datentraeger: mit Standardwerten weiter
    end;
    Exit;
  end;
  ini := TIniFile.Create(ABase + CONFIG_FILE);
  try
    Cfg.HttpPort := ini.ReadInteger('ports', 'http', DEFAULT_HTTP_PORT);
    Cfg.DbPort := ini.ReadInteger('ports', 'db', DEFAULT_DB_PORT);
    s := LowerCase(Trim(ini.ReadString('browser', 'open', 'site')));
    for t := Low(TOpenTarget) to High(TOpenTarget) do
      if s = OPEN_NAMES[t] then Cfg.OpenTarget := t;
  finally
    ini.Free;
  end;
  if not ValidPort(Cfg.HttpPort) then Cfg.HttpPort := DEFAULT_HTTP_PORT;
  if not ValidPort(Cfg.DbPort) then Cfg.DbPort := DEFAULT_DB_PORT;
  if Cfg.HttpPort = Cfg.DbPort then
  begin
    Cfg.HttpPort := DEFAULT_HTTP_PORT;
    Cfg.DbPort := DEFAULT_DB_PORT;
  end;
end;

procedure SaveConfig(const ABase: string; const C: TPortableConfig);
var
  L: TStringList;
begin
  // von Hand geschrieben, damit die Kommentare erhalten bleiben (start.bat liest die Datei auch)
  L := TStringList.Create;
  try
    L.Add('; WBCE Portable - Einstellungen (am einfachsten im Programm unten "Einstellungen")');
    L.Add('; Ports 1024-65535; fuer mehrere Portables gleichzeitig jeder Kopie eigene Ports geben.');
    L.Add('[ports]');
    L.Add('http=' + IntToStr(C.HttpPort));
    L.Add('db=' + IntToStr(C.DbPort));
    L.Add('');
    L.Add('; Beim Start im Browser oeffnen: site (Website), admin (Administration), none (nichts)');
    L.Add('[browser]');
    L.Add('open=' + OPEN_NAMES[C.OpenTarget]);
    L.SaveToFile(ABase + CONFIG_FILE);
  finally
    L.Free;
  end;
end;

function SiteUrl: string;
begin
  Result := 'http://localhost:' + IntToStr(Cfg.HttpPort) + '/wbce';
end;

function AdminUrl: string;
begin
  Result := SiteUrl + '/admin';
end;

function InstallUrl: string;
begin
  Result := 'http://127.0.0.1:' + IntToStr(Cfg.HttpPort) + '/wbce/install/';
end;

function PortInUse(APort: Integer): Boolean;
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

{ Ports in eine erzeugte Konfiguration einsetzen: Platzhalter und - fuer aeltere Vorlagen
  ohne Platzhalter - die festen Zeilen von httpd.conf und my.ini }
function ApplyPorts(const AText: string): string;
begin
  Result := StringReplace(AText, '__HTTP_PORT__', IntToStr(Cfg.HttpPort), [rfReplaceAll]);
  Result := StringReplace(Result, '__DB_PORT__', IntToStr(Cfg.DbPort), [rfReplaceAll]);
  Result := ReplaceRegExpr('(?m)^(Listen\s+127\.0\.0\.1:)\d+', Result,
    '${1}' + IntToStr(Cfg.HttpPort), True);
  Result := ReplaceRegExpr('(?m)^(ServerName\s+localhost:)\d+', Result,
    '${1}' + IntToStr(Cfg.HttpPort), True);
  Result := ReplaceRegExpr('(?m)^(port\s*=\s*)\d+', Result, '${1}' + IntToStr(Cfg.DbPort), True);
end;

{ config.php von WBCE an die eingestellten Ports anpassen (nur wenn noetig).
  Result False = Datei konnte nicht angepasst werden (AMsg sagt warum). }
function SyncWbceConfig(const ABase: string; out AMsg: string): Boolean;
var
  fn, tmp, src, dst: string;
  L: TStringStream;
  re: TRegExpr;
begin
  Result := True;
  AMsg := '';
  fn := ABase + 'htdocs\wbce\config.php';
  if not FileExists(fn) then Exit;
  L := TStringStream.Create('');
  re := TRegExpr.Create;
  try
    L.LoadFromFile(fn);   // byteweise: Zeilenenden bleiben, wie sie sind
    src := L.DataString;
    if Length(src) < 40 then Exit;   // Platzhalter vor der Einrichtung
    dst := src;
    // DB_PORT als eigene Konstante (WBCE 1.6) ...
    dst := ReplaceRegExpr('(define\(\s*[''"]DB_PORT[''"]\s*,\s*[''"])\d+([''"])', dst,
      '${1}' + IntToStr(Cfg.DbPort) + '${2}', True);
    // ... oder als Teil von DB_HOST (127.0.0.1:3311)
    dst := ReplaceRegExpr('(define\(\s*[''"]DB_HOST[''"]\s*,\s*[''"](?:127\.0\.0\.1|localhost)):\d+([''"])',
      dst, '${1}:' + IntToStr(Cfg.DbPort) + '${2}', True);
    // WB_URL nur anfassen, wenn sie auf diesen Rechner zeigt
    re.Expression := '(define\(\s*[''"]WB_URL[''"]\s*,\s*[''"]https?://)([^''"/]+)';
    re.ModifierI := True;
    if re.Exec(dst) then
    begin
      if SameText(re.Match[2], 'localhost') or SameText(re.Match[2], '127.0.0.1') or
         ExecRegExpr('^(localhost|127\.0\.0\.1):\d+$', LowerCase(re.Match[2])) then
        dst := ReplaceRegExpr('(define\(\s*[''"]WB_URL[''"]\s*,\s*[''"]https?://(?:localhost|127\.0\.0\.1))(?::\d+)?',
          dst, '${1}:' + IntToStr(Cfg.HttpPort), True)
      else
        AMsg := 'WB_URL in config.php zeigt auf "' + re.Match[2] +
                '" und wurde nicht angepasst.';
    end;
    if dst = src then Exit;

    // erst vollstaendig schreiben, dann ersetzen (kein halber Zustand bei Abbruch)
    tmp := fn + '.port-tmp';
    try
      L.Size := 0;
      L.WriteString(dst);
      L.SaveToFile(tmp);
      if not Windows.MoveFileEx(PChar(tmp), PChar(fn), MOVEFILE_REPLACE_EXISTING) then
        RaiseLastOSError;
      if AMsg = '' then
        AMsg := 'config.php an die Ports angepasst (HTTP ' + IntToStr(Cfg.HttpPort) +
                ', DB ' + IntToStr(Cfg.DbPort) + ').';
    except
      on E: Exception do
      begin
        SysUtils.DeleteFile(tmp);
        AMsg := 'config.php konnte nicht angepasst werden: ' + E.Message;
        Result := False;
      end;
    end;
  finally
    re.Free;
    L.Free;
  end;
end;

{ ---------------------------------------------------------------- Dialog ---- }

type
  TSettingsForm = class(TForm)
  private
    FBase: string;
    FStopped: Boolean;
    edHttp, edDb: TEdit;
    rbSite, rbAdmin, rbNone: TRadioButton;
    lblHint: TLabel;
    btnFree: TWbceButton;
    btnOk: TWbceButton;
    btnCancel: TWbceButton;
    procedure FreeClick(Sender: TObject);
    procedure OkClick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
  public
    constructor CreateDlg(AOwner: TComponent; const ABase: string; AStopped: Boolean);
    function Data: TPortableConfig;
  end;

constructor TSettingsForm.CreateDlg(AOwner: TComponent; const ABase: string; AStopped: Boolean);
var
  y: Integer;
  hdr: TWbceHeader;
  info: TWbceBanner;

  function AddCaption(const S: string; AY: Integer): TLabel;
  begin
    Result := TLabel.Create(Self);
    Result.Parent := Self;
    Result.SetBounds(18, AY, 440, 16);
    Result.Caption := S;
    Result.Font.Style := [fsBold];
  end;

  function AddEdit(const S: string; AX, AY: Integer; AVal: Integer): TEdit;
  var
    L: TLabel;
  begin
    L := TLabel.Create(Self);
    L.Parent := Self;
    L.SetBounds(AX, AY + 4, 90, 18);
    L.Caption := S;
    Result := TEdit.Create(Self);
    Result.Parent := Self;
    Result.SetBounds(AX + 92, AY, 100, 26);
    Result.NumbersOnly := True;
    Result.MaxLength := 5;
    Result.Text := IntToStr(AVal);
    Result.Enabled := AStopped;
  end;

  function AddRadio(const S: string; AY: Integer; AChecked: Boolean): TRadioButton;
  begin
    Result := TRadioButton.Create(Self);
    Result.Parent := Self;
    Result.SetBounds(18, AY, 444, 22);
    Result.Caption := S;
    Result.Checked := AChecked;
  end;

begin
  inherited CreateNew(AOwner);
  FBase := ABase;
  FStopped := AStopped;
  Caption := 'Einstellungen';
  BorderStyle := bsDialog;
  Position := poOwnerFormCenter;
  ClientWidth := 480;
  WbceStyleForm(Self);

  hdr := TWbceHeader.Create(Self);
  hdr.Parent := Self;
  hdr.Compact := True;
  hdr.SetBounds(0, 0, 480, 52);
  hdr.Title := 'Einstellungen';

  info := TWbceBanner.Create(Self);
  info.Parent := Self;
  info.SetBounds(18, 66, 444, 52);
  if AStopped then
    info.Show(bkInfo, 'Mehrere Portables gleichzeitig? Dann bekommt jede Kopie eigene Ports. ' +
      'Die WBCE-Konfiguration wird beim Speichern automatisch angepasst.')
  else
    info.Show(bkInfo, 'Die Ports lassen sich nur bei gestopptem Server ändern. ' +
      'Die Browser-Einstellung gilt ab dem nächsten Start.');

  y := 132;
  AddCaption('Ports', y);
  Inc(y, 22);
  edHttp := AddEdit('Webserver', 18, y, Cfg.HttpPort);
  edDb := AddEdit('Datenbank', 250, y, Cfg.DbPort);
  Inc(y, 34);

  btnFree := TWbceButton.Create(Self);
  btnFree.Parent := Self;
  btnFree.Kind := wbSecondary;
  btnFree.SetBounds(18, y, 210, 28);
  btnFree.Caption := 'Freie Ports suchen';
  btnFree.OnClick := @FreeClick;
  btnFree.Enabled := AStopped;

  lblHint := TLabel.Create(Self);
  lblHint.Parent := Self;
  lblHint.AutoSize := False;
  lblHint.WordWrap := True;
  lblHint.SetBounds(238, y, 224, 34);
  lblHint.Font.Color := clWbMuted;
  lblHint.Caption := 'Standard: 4443 und 3311';
  Inc(y, 46);

  AddCaption('Beim Serverstart im Browser öffnen', y);
  Inc(y, 22);
  rbSite := AddRadio('Website (Frontend)', y, Cfg.OpenTarget = otSite);
  Inc(y, 24);
  rbAdmin := AddRadio('Administration (Backend)', y, Cfg.OpenTarget = otAdmin);
  Inc(y, 24);
  rbNone := AddRadio('Nichts öffnen', y, Cfg.OpenTarget = otNone);
  Inc(y, 36);

  ClientHeight := y + 54;

  btnOk := TWbceButton.Create(Self);
  btnOk.Parent := Self;
  btnOk.SetBounds(18, ClientHeight - 54, 218, 38);
  btnOk.Caption := 'Speichern';
  btnOk.OnClick := @OkClick;

  btnCancel := TWbceButton.Create(Self);
  btnCancel.Parent := Self;
  btnCancel.Kind := wbSecondary;
  btnCancel.SetBounds(244, ClientHeight - 54, 218, 38);
  btnCancel.Caption := 'Abbrechen';
  btnCancel.OnClick := @CancelClick;
end;

function TSettingsForm.Data: TPortableConfig;
begin
  Result.HttpPort := StrToIntDef(Trim(edHttp.Text), 0);
  Result.DbPort := StrToIntDef(Trim(edDb.Text), 0);
  if rbAdmin.Checked then Result.OpenTarget := otAdmin
  else if rbNone.Checked then Result.OpenTarget := otNone
  else Result.OpenTarget := otSite;
end;

{ naechstes freies Paar oberhalb der Standardports (4444/3312, 4445/3313, ...) }
procedure TSettingsForm.FreeClick(Sender: TObject);
var
  i: Integer;
begin
  Screen.Cursor := crHourGlass;
  try
    for i := 0 to 50 do
      if not PortInUse(DEFAULT_HTTP_PORT + i) and not PortInUse(DEFAULT_DB_PORT + i) then
      begin
        edHttp.Text := IntToStr(DEFAULT_HTTP_PORT + i);
        edDb.Text := IntToStr(DEFAULT_DB_PORT + i);
        lblHint.Caption := 'Diese Ports sind gerade frei.';
        Exit;
      end;
    lblHint.Caption := 'Kein freies Paar gefunden - bitte von Hand eintragen.';
  finally
    Screen.Cursor := crDefault;
  end;
end;

procedure TSettingsForm.OkClick(Sender: TObject);
var
  D: TPortableConfig;
  busy: string;
begin
  D := Data;
  if FStopped then
  begin
    if not ValidPort(D.HttpPort) or not ValidPort(D.DbPort) then
    begin
      MessageDlg('Einstellungen', 'Ports müssen zwischen 1024 und 65535 liegen.', mtError, [mbOK], 0);
      Exit;
    end;
    if D.HttpPort = D.DbPort then
    begin
      MessageDlg('Einstellungen', 'Webserver und Datenbank brauchen verschiedene Ports.', mtError, [mbOK], 0);
      Exit;
    end;
    busy := '';
    if (D.HttpPort <> Cfg.HttpPort) and PortInUse(D.HttpPort) then
      busy := busy + ' ' + IntToStr(D.HttpPort);
    if (D.DbPort <> Cfg.DbPort) and PortInUse(D.DbPort) then
      busy := busy + ' ' + IntToStr(D.DbPort);
    if (busy <> '') and (MessageDlg('Einstellungen', 'Port' + busy + ' wird gerade von einem ' +
        'anderen Programm benutzt. Trotzdem speichern?', mtWarning, [mbYes, mbNo], 0) <> mrYes) then
      Exit;
  end;
  ModalResult := mrOK;
end;

procedure TSettingsForm.CancelClick(Sender: TObject);
begin
  ModalResult := mrCancel;
end;

{ Result True = gespeichert; neue Werte stehen in Cfg }
function ShowSettingsDialog(AOwner: TComponent; const ABase: string;
  AServerStopped: Boolean): Boolean;
var
  F: TSettingsForm;
  D: TPortableConfig;
begin
  F := TSettingsForm.CreateDlg(AOwner, ABase, AServerStopped);
  try
    Result := F.ShowModal = mrOK;
    if Result then
    begin
      D := F.Data;
      if not AServerStopped then
      begin
        D.HttpPort := Cfg.HttpPort;
        D.DbPort := Cfg.DbPort;
      end;
      try
        SaveConfig(ABase, D);
      except
        on E: Exception do
        begin
          MessageDlg('Einstellungen', 'portable.ini konnte nicht gespeichert werden: ' +
            E.Message, mtError, [mbOK], 0);
          Exit(False);
        end;
      end;
      Cfg := D;
    end;
  finally
    F.Free;
  end;
end;

procedure PreviewSettingsDialog(AOwner: TComponent; const ABase, AFile: string);
var
  F: TSettingsForm;
begin
  F := TSettingsForm.CreateDlg(AOwner, ABase, True);
  try
    WbcePreviewForm(F, AFile);
  finally
    F.Free;
  end;
end;

end.
