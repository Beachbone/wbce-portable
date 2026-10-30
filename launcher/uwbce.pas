unit uwbce;

{$mode objfpc}{$H+}

{ Oberflaechen-Bausteine im Look des WBCE-Backends (Theme "wbce_flat_theme"):
  flache, selbstgezeichnete Elemente - Kopfband, Schaltflaechen, Statuskarte,
  Schritteliste ("Weg zur fertigen Seite") und Hinweisbalken.
  Farben: Hintergrund #f3f3f3, Kopf #323741, Schaltflaechen #505b6d (hover #3c4150),
  Gruen #4db34e, Rot #cc0000, Link/Akzent #28609b. }

interface

uses
  Classes, SysUtils, Types, Controls, Graphics, Forms, StdCtrls, Windows, LCLType;

const
  // TColor ist BGR
  clWbBg       = TColor($F3F3F3);
  clWbCard     = TColor($FFFFFF);
  clWbLine     = TColor($DDDDDD);
  clWbInk      = TColor($444444);
  clWbMuted    = TColor($666666);
  clWbWaitInk  = TColor($767676);
  clWbHead     = TColor($413732);   // #323741
  clWbHeadInk  = TColor($F3F3F3);
  clWbHeadSub  = TColor($C3B5AD);   // #adb5c3
  clWbBtn      = TColor($6D5B50);   // #505b6d
  clWbBtnHover = TColor($50413C);   // #3c4150
  clWbBtnOff   = TColor($D4CDC9);   // #c9cdd4
  clWbBtnOffInk = TColor($80726B);  // #6b7280
  clWbGreen    = TColor($4EB34D);   // #4db34e
  clWbGreenInk = TColor($0F5D0F);
  clWbGreenBg  = TColor($D5FBD5);
  clWbRed      = TColor($0000CC);   // #cc0000
  clWbRedInk   = TColor($00008A);
  clWbRedBg    = TColor($E9E9FD);   // #fde9e9
  clWbBlue     = TColor($9B6028);   // #28609b
  clWbBlueInk  = TColor($72481D);
  clWbBlueBg   = TColor($F7EEE6);   // #e6eef7
  clWbOrange   = TColor($20A0F0);   // #f0a020
  WB_FONT = 'Segoe UI';

type
  TWbceButtonKind = (wbPrimary, wbSecondary);

  { Basisklasse: zeichnet ueber DrawTo, damit sich die Elemente auch in eine Bitmap rendern lassen }
  TWbceCustom = class(TCustomControl)
  protected
    procedure Paint; override;
  public
    procedure DrawTo(C: TCanvas; R: TRect); virtual; abstract;
  end;
  { Flache Schaltflaeche }
  TWbceButton = class(TWbceCustom)
  private
    FKind: TWbceButtonKind;
    FHover: Boolean;
    FDown: Boolean;
    procedure SetKind(AValue: TWbceButtonKind);
  protected
    procedure DrawTo(C: TCanvas; R: TRect); override;
    procedure MouseEnter; override;
    procedure MouseLeave; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure DoEnter; override;
    procedure DoExit; override;
    procedure EnabledChanged; override;
    procedure TextChanged; override;
  public
    constructor Create(AOwner: TComponent); override;
    property Kind: TWbceButtonKind read FKind write SetKind;
    property Caption;
    property OnClick;
  end;

  { Kopfband: dunkel, Programmsymbol, Titel, Untertitel, Versionstext rechts }
  TWbceHeader = class(TWbceCustom)
  private
    FTitle, FSubtitle, FRightText: string;
    FCompact: Boolean;
    procedure SetStr(Index: Integer; const AValue: string);
  protected
    procedure DrawTo(C: TCanvas; R: TRect); override;
  public
    constructor Create(AOwner: TComponent); override;
    property Title: string index 0 read FTitle write SetStr;
    property Subtitle: string index 1 read FSubtitle write SetStr;
    property RightText: string index 2 read FRightText write SetStr;
    property Compact: Boolean read FCompact write FCompact;
  end;

  { Statuskarte: Lampe + Status + Zusatzzeile }
  TWbceStatus = class(TWbceCustom)
  private
    FLamp: TColor;
    FTitle, FSub: string;
  protected
    procedure DrawTo(C: TCanvas; R: TRect); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetStatus(ALamp: TColor; const ATitle, ASub: string);
  end;

  TWbceStepState = (wsWait, wsActive, wsDone, wsError);

  { Liste "Auf dem Weg zur fertigen Seite" }
  TWbceSteps = class(TWbceCustom)
  private
    FLabels: array of string;
    FDetails: array of string;
    FStates: array of TWbceStepState;
  protected
    procedure DrawTo(C: TCanvas; R: TRect); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure AddStep(const ALabel: string);
    procedure SetStep(AIndex: Integer; AState: TWbceStepState; const ADetail: string = '');
    procedure ResetAll;
    function ActiveIndex: Integer;
    function NeededHeight: Integer;
  end;

  TWbceBannerKind = (bkInfo, bkOk, bkError);

  { Hinweisbalken (Info / Erfolg / Fehler) }
  TWbceBanner = class(TWbceCustom)
  private
    FKind: TWbceBannerKind;
    FText: string;
  protected
    procedure DrawTo(C: TCanvas; R: TRect); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Show(AKind: TWbceBannerKind; const AText: string);
    property Kind: TWbceBannerKind read FKind;
  end;

procedure WbceStyleForm(AForm: TForm);
procedure WbceDrawText(ACanvas: TCanvas; const R: TRect; const S: string;
  AAlign: TAlignment; ALayout: TTextLayout; AWrap: Boolean);
procedure WbceStyleLink(ALabel: TLabel);
procedure WbcePreviewForm(AForm: TForm; const AFile: string);

implementation

procedure WbceDrawText(ACanvas: TCanvas; const R: TRect; const S: string;
  AAlign: TAlignment; ALayout: TTextLayout; AWrap: Boolean);
var
  ts: TTextStyle;
begin
  ts := ACanvas.TextStyle;
  ts.Alignment := AAlign;
  ts.Layout := ALayout;
  ts.SingleLine := not AWrap;
  ts.Wordbreak := AWrap;
  ts.EndEllipsis := not AWrap;
  ts.Clipping := True;
  ts.Opaque := False;
  ACanvas.Brush.Style := bsClear;
  ACanvas.TextRect(R, R.Left, R.Top, S, ts);
end;

procedure WbceStyleForm(AForm: TForm);
begin
  AForm.Color := clWbBg;
  AForm.Font.Name := WB_FONT;
  AForm.Font.Size := 9;
  AForm.Font.Color := clWbInk;
end;

procedure WbceStyleLink(ALabel: TLabel);
begin
  ALabel.Font.Color := clWbBlue;
  ALabel.Font.Style := [fsUnderline];
  ALabel.Cursor := crHandPoint;
end;

{ WBCE-Marke (Siebeneck mit sieben Streben) als Vektorzeichnung: wird 4-fach gross gezeichnet und
  mit Halbton-Filter verkleinert - dadurch glatte Kanten in jeder Groesse und bei jeder Skalierung.
  Farben/Form nach dem WBCE-Favicon (#5599ff, Streben #0044aa). }
procedure DrawMark(ACanvas: TCanvas; X, Y, S: Integer; ABg: TColor);
const
  SS = 4;
  N = 7;
var
  bmp: Graphics.TBitmap;
  big, i: Integer;
  cx, cy, r, w, ang, dx, dy, ln: Double;
  pts: array[0..N - 1] of TPoint;
  q: array[0..3] of TPoint;
begin
  big := S * SS;
  bmp := Graphics.TBitmap.Create;
  try
    bmp.PixelFormat := pf24bit;
    bmp.SetSize(big, big);
    bmp.Canvas.Brush.Style := bsSolid;
    bmp.Canvas.Brush.Color := ABg;
    bmp.Canvas.Pen.Color := ABg;
    bmp.Canvas.FillRect(0, 0, big, big);
    cx := big / 2;
    cy := big * 0.515;
    r := big * 0.485;
    for i := 0 to N - 1 do
    begin
      ang := -Pi / 2 + i * 2 * Pi / N;
      pts[i] := Types.Point(Round(cx + r * Cos(ang)), Round(cy + r * Sin(ang)));
    end;
    bmp.Canvas.Brush.Color := TColor($FF9955);   // #5599ff
    bmp.Canvas.Pen.Color := TColor($FF9955);
    bmp.Canvas.Polygon(pts);
    bmp.Canvas.Brush.Color := TColor($AA4400);   // #0044aa
    bmp.Canvas.Pen.Color := TColor($AA4400);
    w := big * 0.075;
    for i := 0 to N - 1 do
    begin
      dx := pts[i].X - cx;
      dy := pts[i].Y - cy;
      ln := Sqrt(dx * dx + dy * dy);
      dx := dx / ln;
      dy := dy / ln;
      q[0] := Types.Point(Round(cx - dy * w / 2), Round(cy + dx * w / 2));
      q[1] := Types.Point(Round(cx + dy * w / 2), Round(cy - dx * w / 2));
      q[2] := Types.Point(Round(pts[i].X + dy * w / 2), Round(pts[i].Y - dx * w / 2));
      q[3] := Types.Point(Round(pts[i].X - dy * w / 2), Round(pts[i].Y + dx * w / 2));
      bmp.Canvas.Polygon(q);
    end;
    Windows.SetStretchBltMode(ACanvas.Handle, HALFTONE);
    Windows.SetBrushOrgEx(ACanvas.Handle, 0, 0, nil);
    Windows.StretchBlt(ACanvas.Handle, X, Y, S, S, bmp.Canvas.Handle, 0, 0, big, big, SRCCOPY);
  finally
    bmp.Free;
  end;
end;
procedure TWbceCustom.Paint;
begin
  DrawTo(Canvas, ClientRect);
end;

{ ---- TWbceButton ---------------------------------------------------------- }

constructor TWbceButton.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  TabStop := True;
  SetInitialBounds(0, 0, 160, 38);
  Cursor := crHandPoint;
end;

procedure TWbceButton.SetKind(AValue: TWbceButtonKind);
begin
  if FKind = AValue then Exit;
  FKind := AValue;
  Invalidate;
end;

procedure TWbceButton.DrawTo(C: TCanvas; R: TRect);
var
  bg, ink, line: TColor;
begin
  if FKind = wbPrimary then
  begin
    if not Enabled then begin bg := clWbBtnOff; ink := clWbBtnOffInk; end
    else if FHover or FDown then begin bg := clWbBtnHover; ink := clWbHeadInk; end
    else begin bg := clWbBtn; ink := clWbHeadInk; end;
    line := bg;
  end
  else
  begin
    if not Enabled then begin bg := clWbCard; ink := clWbBtnOffInk; line := clWbBtnOff; end
    else if FHover or FDown then begin bg := clWbBtn; ink := clWbHeadInk; line := clWbBtn; end
    else begin bg := clWbCard; ink := clWbBtn; line := clWbBtn; end;
  end;
  C.Brush.Style := bsSolid;
  C.Brush.Color := bg;
  C.Pen.Color := line;
  C.Rectangle(R);
  C.Font.Name := WB_FONT;
  C.Font.Size := 9;
  if FKind = wbPrimary then C.Font.Size := 10;
  C.Font.Color := ink;
  WbceDrawText(C, R, Caption, taCenter, tlCenter, False);
  if Focused and Enabled then
  begin
    C.Brush.Style := bsClear;
    C.Pen.Color := clWbBlue;
    C.Pen.Style := psDot;
    C.Rectangle(R.Left + 3, R.Top + 3, R.Right - 3, R.Bottom - 3);
    C.Pen.Style := psSolid;
  end;
end;

procedure TWbceButton.MouseEnter;
begin
  inherited MouseEnter;
  FHover := True;
  Invalidate;
end;

procedure TWbceButton.MouseLeave;
begin
  inherited MouseLeave;
  FHover := False;
  FDown := False;
  Invalidate;
end;

procedure TWbceButton.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button = mbLeft) and Enabled then
  begin
    FDown := True;
    if CanFocus then SetFocus;
    Invalidate;
  end;
end;

procedure TWbceButton.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  FDown := False;
  Invalidate;
  inherited MouseUp(Button, Shift, X, Y);
end;

procedure TWbceButton.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  if Enabled and ((Key = VK_SPACE) or (Key = VK_RETURN)) then
  begin
    Click;
    Key := 0;
  end;
end;

procedure TWbceButton.DoEnter;
begin
  inherited DoEnter;
  Invalidate;
end;

procedure TWbceButton.DoExit;
begin
  inherited DoExit;
  Invalidate;
end;

procedure TWbceButton.EnabledChanged;
begin
  inherited EnabledChanged;
  if not Enabled then
  begin
    FHover := False;
    FDown := False;
    Cursor := crDefault;
  end
  else
    Cursor := crHandPoint;
  Invalidate;
end;

procedure TWbceButton.TextChanged;
begin
  inherited TextChanged;
  Invalidate;
end;

{ ---- TWbceHeader ---------------------------------------------------------- }

constructor TWbceHeader.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  SetInitialBounds(0, 0, 400, 64);
end;

procedure TWbceHeader.SetStr(Index: Integer; const AValue: string);
begin
  case Index of
    0: FTitle := AValue;
    1: FSubtitle := AValue;
    2: FRightText := AValue;
  end;
  Invalidate;
end;

procedure TWbceHeader.DrawTo(C: TCanvas; R: TRect);
var
  T: TRect;
  isz, tx: Integer;
begin
  C.Brush.Style := bsSolid;
  C.Brush.Color := clWbHead;
  C.Pen.Style := psClear;
  C.Rectangle(R.Left, R.Top, R.Right + 1, R.Bottom + 1);
  C.Pen.Style := psSolid;
  C.Pen.Color := TColor($777777);
  C.MoveTo(R.Left, R.Bottom - 1);
  C.LineTo(R.Right, R.Bottom - 1);

  isz := R.Bottom - 16;   // 48 px im Hauptfenster, 36 px im Dialog
  DrawMark(C, 18, (R.Bottom - isz) div 2, isz, clWbHead);
  tx := 18 + isz + 14;

  C.Font.Name := WB_FONT;
  C.Font.Color := clWbHeadInk;
  if FCompact then
  begin
    C.Font.Size := 13;
    T := Types.Rect(tx, 0, R.Right - 18, R.Bottom);
    WbceDrawText(C, T, FTitle, taLeftJustify, tlCenter, False);
  end
  else
  begin
    C.Font.Size := 15;
    T := Types.Rect(tx, 10, R.Right - 130, 36);
    WbceDrawText(C, T, FTitle, taLeftJustify, tlCenter, False);
    C.Font.Size := 9;
    C.Font.Color := clWbHeadSub;
    T := Types.Rect(tx, 36, R.Right - 130, R.Bottom - 8);
    WbceDrawText(C, T, FSubtitle, taLeftJustify, tlTop, False);
    T := Types.Rect(R.Right - 130, 0, R.Right - 18, R.Bottom);
    WbceDrawText(C, T, FRightText, taRightJustify, tlCenter, False);
  end;
end;

{ ---- TWbceStatus ---------------------------------------------------------- }

constructor TWbceStatus.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  FLamp := clWbRed;
  SetInitialBounds(0, 0, 400, 66);
end;

procedure TWbceStatus.SetStatus(ALamp: TColor; const ATitle, ASub: string);
begin
  FLamp := ALamp;
  FTitle := ATitle;
  FSub := ASub;
  Invalidate;
end;

procedure TWbceStatus.DrawTo(C: TCanvas; R: TRect);
var
  T: TRect;
begin
  C.Brush.Style := bsSolid;
  C.Brush.Color := clWbCard;
  C.Pen.Color := clWbLine;
  C.Rectangle(R);
  C.Brush.Color := FLamp;
  C.Pen.Color := TColor($606060);
  C.Ellipse(14, (R.Bottom - 22) div 2, 36, (R.Bottom - 22) div 2 + 22);
  C.Font.Name := WB_FONT;
  C.Font.Style := [fsBold];
  C.Font.Size := 12;
  C.Font.Color := clWbInk;
  T := Types.Rect(50, 10, R.Right - 10, 34);
  WbceDrawText(C, T, FTitle, taLeftJustify, tlCenter, False);
  C.Font.Style := [];
  C.Font.Size := 9;
  C.Font.Color := clWbMuted;
  T := Types.Rect(50, 34, R.Right - 10, R.Bottom - 8);
  WbceDrawText(C, T, FSub, taLeftJustify, tlTop, False);
end;

{ ---- TWbceSteps ----------------------------------------------------------- }

constructor TWbceSteps.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  SetInitialBounds(0, 0, 400, 180);
end;

procedure TWbceSteps.AddStep(const ALabel: string);
var
  n: Integer;
begin
  n := Length(FLabels);
  SetLength(FLabels, n + 1);
  SetLength(FDetails, n + 1);
  SetLength(FStates, n + 1);
  FLabels[n] := ALabel;
  FDetails[n] := '';
  FStates[n] := wsWait;
end;

procedure TWbceSteps.SetStep(AIndex: Integer; AState: TWbceStepState; const ADetail: string);
begin
  if (AIndex < 0) or (AIndex > High(FLabels)) then Exit;
  FStates[AIndex] := AState;
  FDetails[AIndex] := ADetail;
  Invalidate;
  Application.ProcessMessages;
end;

procedure TWbceSteps.ResetAll;
var
  i: Integer;
begin
  for i := 0 to High(FLabels) do
  begin
    FStates[i] := wsWait;
    FDetails[i] := '';
  end;
  Invalidate;
end;

function TWbceSteps.ActiveIndex: Integer;
var
  i: Integer;
begin
  Result := -1;
  for i := 0 to High(FStates) do
    if FStates[i] = wsActive then Exit(i);
end;

function TWbceSteps.NeededHeight: Integer;
begin
  Result := 10 + 20 + Length(FLabels) * 30 + 8;
end;

procedure TWbceSteps.DrawTo(C: TCanvas; R: TRect);
var
  T, M: TRect;
  i, y: Integer;
  ink: TColor;
begin
  C.Brush.Style := bsSolid;
  C.Brush.Color := clWbCard;
  C.Pen.Color := clWbLine;
  C.Rectangle(R);
  C.Font.Name := WB_FONT;
  C.Font.Size := 8;
  C.Font.Style := [fsBold];
  C.Font.Color := clWbMuted;
  T := Types.Rect(14, 10, R.Right - 14, 28);
  WbceDrawText(C, T, 'AUF DEM WEG ZUR FERTIGEN SEITE', taLeftJustify, tlCenter, False);
  for i := 0 to High(FLabels) do
  begin
    y := 30 + i * 30;
    M := Types.Rect(14, y + 5, 34, y + 25);
    case FStates[i] of
      wsDone:
        begin
          C.Brush.Color := clWbGreen;
          C.Pen.Color := clWbGreen;
          C.Ellipse(M);
          C.Pen.Color := clWhite;
          C.Pen.Width := 2;
          C.MoveTo(M.Left + 5, M.Top + 10);
          C.LineTo(M.Left + 9, M.Top + 14);
          C.LineTo(M.Left + 15, M.Top + 6);
          C.Pen.Width := 1;
        end;
      wsActive:
        begin
          C.Brush.Color := clWbCard;
          C.Pen.Color := clWbBlue;
          C.Pen.Width := 2;
          C.Ellipse(M.Left + 1, M.Top + 1, M.Right - 1, M.Bottom - 1);
          C.Pen.Width := 1;
          C.Brush.Color := clWbBlue;
          C.Ellipse(M.Left + 6, M.Top + 6, M.Right - 6, M.Bottom - 6);
        end;
      wsError:
        begin
          C.Brush.Color := clWbRed;
          C.Pen.Color := clWbRed;
          C.Ellipse(M);
          C.Pen.Color := clWhite;
          C.Pen.Width := 2;
          C.MoveTo(M.Left + 10, M.Top + 5);
          C.LineTo(M.Left + 10, M.Top + 11);
          C.MoveTo(M.Left + 10, M.Top + 14);
          C.LineTo(M.Left + 10, M.Top + 15);
          C.Pen.Width := 1;
        end;
    else
      C.Brush.Color := clWbCard;
      C.Pen.Color := TColor($C3BAB5);
      C.Ellipse(M);
    end;
    C.Font.Size := 10;
    case FStates[i] of
      wsActive: begin C.Font.Style := [fsBold]; ink := clWbInk; end;
      wsError:  begin C.Font.Style := [fsBold]; ink := clWbRed; end;
      wsDone:   begin C.Font.Style := []; ink := clWbInk; end;
    else
      C.Font.Style := [];
      ink := clWbWaitInk;
    end;
    C.Font.Color := ink;
    T := Types.Rect(46, y, R.Right - 160, y + 30);
    WbceDrawText(C, T, FLabels[i], taLeftJustify, tlCenter, False);
    C.Font.Size := 9;
    C.Font.Style := [];
    C.Font.Color := clWbMuted;
    T := Types.Rect(R.Right - 200, y, R.Right - 14, y + 30);
    WbceDrawText(C, T, FDetails[i], taRightJustify, tlCenter, False);
  end;
end;

{ ---- TWbceBanner ---------------------------------------------------------- }

constructor TWbceBanner.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  SetInitialBounds(0, 0, 400, 56);
  Visible := False;
end;

procedure TWbceBanner.Show(AKind: TWbceBannerKind; const AText: string);
begin
  FKind := AKind;
  FText := AText;
  Visible := True;
  Invalidate;
end;

procedure TWbceBanner.DrawTo(C: TCanvas; R: TRect);
var
  T: TRect;
  bg, line, ink: TColor;
  g: string;
begin
  case FKind of
    bkOk:    begin bg := clWbGreenBg; line := clWbGreen; ink := clWbGreenInk; g := ''; end;
    bkError: begin bg := clWbRedBg;   line := clWbRed;   ink := clWbRedInk;   g := '!'; end;
  else
    bg := clWbBlueBg; line := clWbBlue; ink := clWbBlueInk; g := 'i';
  end;
  C.Brush.Style := bsSolid;
  C.Brush.Color := bg;
  C.Pen.Color := line;
  C.Rectangle(R);
  C.Font.Name := WB_FONT;
  C.Font.Color := ink;
  C.Font.Style := [fsBold];
  C.Font.Size := 11;
  T := Types.Rect(12, 8, 30, 28);
  if FKind = bkOk then
  begin
    // Haken zeichnen (kein Sonderzeichen noetig)
    C.Pen.Color := clWbGreenInk;
    C.Pen.Width := 2;
    C.MoveTo(13, 17);
    C.LineTo(17, 21);
    C.LineTo(25, 11);
    C.Pen.Width := 1;
  end
  else
    WbceDrawText(C, T, g, taCenter, tlTop, False);
  C.Font.Style := [];
  C.Font.Size := 9;
  T := Types.Rect(36, 7, R.Right - 10, R.Bottom - 5);
  WbceDrawText(C, T, FText, taLeftJustify, tlTop, True);
end;

{ Entwicklerhilfe: bildet ein Formular samt seiner Elemente in eine BMP-Datei ab
  (ohne sichtbares Fenster) - dient dem Pruefen der Oberflaeche. }
procedure WbcePreviewForm(AForm: TForm; const AFile: string);
var
  big, tmp: Graphics.TBitmap;
  i, j, y: Integer;
  c: TControl;
  R: TRect;
  S: string;
  al: TAlignment;
begin
  big := Graphics.TBitmap.Create;
  try
    big.SetSize(AForm.ClientWidth, AForm.ClientHeight);
    big.Canvas.Brush.Color := AForm.Color;
    big.Canvas.FillRect(0, 0, big.Width, big.Height);
    for i := 0 to AForm.ControlCount - 1 do
    begin
      c := AForm.Controls[i];
      if not c.Visible then Continue;
      R := Types.Rect(c.Left, c.Top, c.Left + c.Width, c.Top + c.Height);
      if c is TWbceCustom then
      begin
        tmp := Graphics.TBitmap.Create;
        try
          tmp.SetSize(c.Width, c.Height);
          TWbceCustom(c).DrawTo(tmp.Canvas, Types.Rect(0, 0, c.Width, c.Height));
          big.Canvas.Draw(c.Left, c.Top, tmp);
        finally
          tmp.Free;
        end;
      end
      else if c is TLabel then
      begin
        big.Canvas.Font.Assign(TLabel(c).Font);
        al := TLabel(c).Alignment;
        WbceDrawText(big.Canvas, R, TLabel(c).Caption, al, tlTop, TLabel(c).WordWrap);
      end
      else if (c is TEdit) or (c is TMemo) or (c is TListBox) then
      begin
        big.Canvas.Brush.Style := bsSolid;
        big.Canvas.Brush.Color := clWhite;
        big.Canvas.Pen.Color := TColor($AAAAAA);
        big.Canvas.Rectangle(R);
        big.Canvas.Font.Assign(TControl(c).Font);
        if c is TEdit then
        begin
          S := TEdit(c).Text;
          if TEdit(c).PasswordChar <> #0 then S := StringOfChar('*', Length(S));
          WbceDrawText(big.Canvas, Types.Rect(R.Left + 5, R.Top, R.Right - 3, R.Bottom), S, taLeftJustify, tlCenter, False);
        end
        else if c is TMemo then
        begin
          y := R.Top + 3;
          for j := 0 to TMemo(c).Lines.Count - 1 do
          begin
            if y + 14 > R.Bottom then Break;
            WbceDrawText(big.Canvas, Types.Rect(R.Left + 5, y, R.Right - 3, y + 15), TMemo(c).Lines[j], taLeftJustify, tlTop, False);
            Inc(y, 15);
          end;
        end
        else
        begin
          y := R.Top + 1;
          for j := 0 to TListBox(c).Items.Count - 1 do
          begin
            if j = TListBox(c).ItemIndex then
            begin
              big.Canvas.Brush.Style := bsSolid;
              big.Canvas.Brush.Color := TColor($D6A056);
              big.Canvas.FillRect(R.Left + 1, y, R.Right - 1, y + TListBox(c).ItemHeight);
              big.Canvas.Font.Color := clWhite;
            end
            else
              big.Canvas.Font.Color := TControl(c).Font.Color;
            WbceDrawText(big.Canvas, Types.Rect(R.Left + 6, y, R.Right - 3, y + TListBox(c).ItemHeight),
              TListBox(c).Items[j], taLeftJustify, tlCenter, False);
            Inc(y, TListBox(c).ItemHeight);
          end;
        end;
      end
      else if c is TCheckBox then
      begin
        big.Canvas.Brush.Style := bsSolid;
        big.Canvas.Brush.Color := clWhite;
        big.Canvas.Pen.Color := TColor($888888);
        big.Canvas.Rectangle(R.Left, R.Top + 3, R.Left + 14, R.Top + 17);
        if TCheckBox(c).Checked then
        begin
          big.Canvas.Pen.Color := clWbBlue;
          big.Canvas.MoveTo(R.Left + 3, R.Top + 10);
          big.Canvas.LineTo(R.Left + 6, R.Top + 14);
          big.Canvas.LineTo(R.Left + 12, R.Top + 6);
        end;
        big.Canvas.Font.Assign(TControl(c).Font);
        WbceDrawText(big.Canvas, Types.Rect(R.Left + 22, R.Top, R.Right, R.Bottom), TCheckBox(c).Caption, taLeftJustify, tlCenter, False);
      end;
    end;
    big.SaveToFile(AFile);
  finally
    big.Free;
  end;
end;

end.