unit CanvasCheckMain;

{ The form of tests\CanvasCheck: draws in OnPaint what FMX's canvases must agree on, and logs ("canvascheck: ...")
  what can be measured: text positions with characters beyond the BMP, PtInPath, the PNG codec round trip. }

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Math, System.Math.Vectors, FMX.Types,
  FMX.Graphics, FMX.Forms, FMX.TextLayout;

type
  TCheckForm = class(TForm)
  private
    FTile: TBitmap;
    FLoaded: TBitmap;
    FQuit: TTimer;
    FPaints: Integer;
    procedure CheckPaint(Sender: TObject; Canvas: TCanvas; const ARect: TRectF);
    procedure QuitTimer(Sender: TObject);
    procedure Log(const AText: string);
    procedure MakeBitmaps;
    procedure MeasureText(const ACanvas: TCanvas);
    function NewLayout(const ACanvas: TCanvas; const AText: string; const ASize: Single): TTextLayout;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  CheckForm: TCheckForm;

implementation

constructor TCheckForm.Create(AOwner: TComponent);
var
  I, QuitAfter: Integer;
begin
  inherited CreateNew(AOwner);
  SetTextCodePage(Output, CP_UTF8);
  Caption := 'Canvas check';
  ClientWidth := 760;
  ClientHeight := 560;
  Fill.Kind := TBrushKind.Solid;
  Fill.Color := TAlphaColors.White;
  OnPaint := CheckPaint;
  QuitAfter := 0;
  for I := 1 to ParamCount do
    if ParamStr(I).StartsWith('--quit-after=') then
      QuitAfter := StrToIntDef(ParamStr(I).Substring(Length('--quit-after=')), 0);
  if QuitAfter > 0 then
  begin
    FQuit := TTimer.Create(Self);
    FQuit.Interval := QuitAfter * 1000;
    FQuit.OnTimer := QuitTimer;
    FQuit.Enabled := True;
  end;
  Log('canvas ' + TCanvasManager.DefaultCanvas.ClassName);
  MakeBitmaps;
end;

destructor TCheckForm.Destroy;
begin
  FTile.Free;
  FLoaded.Free;
  inherited;
end;

procedure TCheckForm.Log(const AText: string);
begin
  Writeln('canvascheck: ', AText);
  Flush(Output);
end;

procedure TCheckForm.QuitTimer(Sender: TObject);
begin
  FQuit.Enabled := False;
  Log('done');
  Close;
end;

procedure TCheckForm.MakeBitmaps;
const
  // Quadrants of the 16x16 tile: red, green / blue, yellow.
  CColors: array[0..3] of TAlphaColor = (TAlphaColors.Red, TAlphaColors.Lime, TAlphaColors.Blue,
    TAlphaColors.Yellow);
var
  D: TBitmapData;
  X, Y: Integer;
  S: TMemoryStream;
begin
  FTile := TBitmap.Create(16, 16);
  if FTile.Map(TMapAccess.Write, D) then
    try
      for Y := 0 to 15 do
        for X := 0 to 15 do
          D.SetPixel(X, Y, CColors[(Y div 8) * 2 + X div 8]);
    finally
      FTile.Unmap(D);
    end;
  // The codec: PNG out and back in.
  FLoaded := TBitmap.Create;
  S := TMemoryStream.Create;
  try
    FTile.SaveToStream(S);
    S.Position := 0;
    FLoaded.LoadFromStream(S);
    Log(Format('png %d bytes, loaded %dx%d', [S.Size, FLoaded.Width, FLoaded.Height]));
    if FLoaded.Map(TMapAccess.Read, D) then
      try
        Log(Format('png pixels %.8x %.8x %.8x %.8x', [D.GetPixel(2, 2), D.GetPixel(13, 2), D.GetPixel(2, 13),
          D.GetPixel(13, 13)]));
      finally
        FLoaded.Unmap(D);
      end;
  except
    on E: Exception do
      Log('png failed: ' + E.Message);
  end;
  S.Free;
end;

function TCheckForm.NewLayout(const ACanvas: TCanvas; const AText: string; const ASize: Single): TTextLayout;
begin
  Result := TTextLayoutManager.TextLayoutByCanvas(ACanvas.ClassType).Create(ACanvas);
  Result.BeginUpdate;
  Result.Text := AText;
  Result.Font.Size := ASize;
  Result.Color := TAlphaColors.Black;
  Result.WordWrap := False;
  Result.MaxSize := PointF(1000, 100);
  Result.EndUpdate;
end;

procedure TCheckForm.MeasureText(const ACanvas: TCanvas);
var
  L: TTextLayout;
  R: TRegion;
  P: TPathData;
begin
  // 'a', U+1F600 (a surrogate pair: indexes 1 and 2), 'b': the end is 4, the pair one character.
  L := NewLayout(ACanvas, 'a'#$D83D#$DE00'b', 20);
  try
    Log(Format('text width>0 %s, position at the right end %d, at the left end %d',
      [BoolToStr(L.TextWidth > 0, True), L.PositionAtPoint(PointF(L.TextWidth - 1, L.TextHeight / 2)),
      L.PositionAtPoint(PointF(0.5, L.TextHeight / 2))]));
    R := L.RegionForRange(TTextRange.Create(1, 2));
    Log(Format('region of the pair: %d rect(s), width>0 %s', [Length(R),
      BoolToStr((Length(R) > 0) and (R[0].Width > 0), True)]));
    R := L.RegionForRange(TTextRange.Create(3, 1));
    Log(Format('region of b starts after the pair: %s', [BoolToStr((Length(R) > 0) and (R[0].Left > 15), True)]));
  finally
    L.Free;
  end;
  P := TPathData.Create;
  try
    P.AddEllipse(RectF(0, 0, 100, 50));
    Log(Format('PtInPath inside %s, outside %s', [BoolToStr(ACanvas.PtInPath(PointF(50, 25), P), True),
      BoolToStr(ACanvas.PtInPath(PointF(2, 2), P), True)]));
  finally
    P.Free;
  end;
end;

procedure TCheckForm.CheckPaint(Sender: TObject; Canvas: TCanvas; const ARect: TRectF);
const
  CDashes: array[0..4] of TStrokeDash = (TStrokeDash.Solid, TStrokeDash.Dash, TStrokeDash.Dot, TStrokeDash.DashDot,
    TStrokeDash.Custom);
var
  I, C: Integer;
  X0, Y: Single;
  Save: TCanvasSaveState;
  L: TTextLayout;
  Path: TPathData;
  M: TMatrix;

  procedure Stops(const AColors: array of TAlphaColor; const AOffsets: array of Single);
  var
    K: Integer;
  begin
    Canvas.Fill.Gradient.Points.Clear;
    for K := 0 to High(AColors) do
      with TGradientPoint(Canvas.Fill.Gradient.Points.Add) do
      begin
        IntColor := AColors[K];
        Offset := AOffsets[K];
      end;
  end;

begin
  Inc(FPaints);
  if FPaints = 1 then
    MeasureText(Canvas);

  // Row 1: gradients, opacity (the black bar shows through what is half transparent).
  Canvas.Fill.Kind := TBrushKind.Solid;
  Canvas.Fill.Color := TAlphaColors.Black;
  Canvas.FillRect(RectF(5, 45, 755, 65), 1);
  Canvas.Fill.Kind := TBrushKind.Gradient;
  Canvas.Fill.Gradient.Style := TGradientStyle.Linear;
  Canvas.Fill.Gradient.StartPosition.Point := PointF(0, 0);
  Canvas.Fill.Gradient.StopPosition.Point := PointF(1, 0);
  Stops([TAlphaColors.Red, TAlphaColors.Blue], [0, 1]);
  Canvas.FillRect(RectF(10, 10, 110, 100), 1);
  Canvas.FillRect(RectF(120, 10, 220, 100), 0.5);
  Canvas.Fill.Gradient.Style := TGradientStyle.Radial;
  Stops([TAlphaColors.Red, TAlphaColors.Yellow, TAlphaColors.Blue], [0, 0.5, 1]);
  Canvas.FillRect(RectF(230, 10, 370, 100), 1);
  Canvas.FillEllipse(RectF(380, 10, 470, 100), 1);
  Canvas.FillEllipse(RectF(480, 10, 570, 100), 0.5);
  Canvas.Fill.Kind := TBrushKind.Solid;
  Canvas.Fill.Color := TAlphaColors.Green;
  Canvas.FillRect(RectF(580, 10, 660, 100), 0.5);
  Canvas.Fill.Color := $8000A000;
  Canvas.FillRect(RectF(670, 10, 750, 100), 1);

  // Row 2: dashes and caps (thin red guides at the ends of the lines), Flat left, Round right.
  Canvas.Stroke.Kind := TBrushKind.Solid;
  for I := 0 to High(CDashes) do
    for C := 0 to 1 do
    begin
      X0 := 20 + C * 190;
      Y := 120 + I * 22;
      Canvas.Stroke.Color := TAlphaColors.Red;
      Canvas.Stroke.Thickness := 1;
      Canvas.Stroke.Dash := TStrokeDash.Solid;
      Canvas.Stroke.Cap := TStrokeCap.Flat;
      Canvas.DrawLine(PointF(X0 + 0.5, Y - 8), PointF(X0 + 0.5, Y + 8), 1);
      Canvas.DrawLine(PointF(X0 + 160.5, Y - 8), PointF(X0 + 160.5, Y + 8), 1);
      Canvas.Stroke.Color := TAlphaColors.Navy;
      Canvas.Stroke.Thickness := 5;
      if CDashes[I] = TStrokeDash.Custom then
        Canvas.Stroke.SetCustomDash([2, 1], 0)
      else
        Canvas.Stroke.Dash := CDashes[I];
      if C = 0 then
        Canvas.Stroke.Cap := TStrokeCap.Flat
      else
        Canvas.Stroke.Cap := TStrokeCap.Round;
      Canvas.DrawLine(PointF(X0, Y), PointF(X0 + 160, Y), 1);
    end;
  Canvas.Stroke.Cap := TStrokeCap.Flat;
  Canvas.Stroke.Dash := TStrokeDash.Dash;
  Canvas.Stroke.Thickness := 3;
  Canvas.Stroke.Join := TStrokeJoin.Round;
  Canvas.DrawRect(RectF(400, 115, 520, 225), 12, 12, AllCorners, 1);
  Canvas.Stroke.Dash := TStrokeDash.Solid;
  Canvas.Stroke.Kind := TBrushKind.Gradient;
  Canvas.Stroke.Gradient.Style := TGradientStyle.Linear;
  Canvas.Stroke.Gradient.Color := TAlphaColors.Orange;
  Canvas.Stroke.Gradient.Color1 := TAlphaColors.Purple;
  Canvas.Stroke.Thickness := 8;
  Canvas.DrawEllipse(RectF(540, 120, 640, 220), 1);
  Canvas.DrawEllipse(RectF(650, 120, 750, 220), 0.4);

  // Row 3: bitmap brushes Tile, TileOriginal, TileStretch; DrawBitmap nearest, smooth, a part (no bleeding of the
  // neighbors), the PNG round trip at half opacity.
  Canvas.Fill.Kind := TBrushKind.Bitmap;
  Canvas.Fill.Bitmap.Bitmap := FTile;
  Canvas.Fill.Bitmap.WrapMode := TWrapMode.Tile;
  Canvas.FillRect(RectF(10, 240, 110, 320), 1);
  Canvas.Fill.Bitmap.WrapMode := TWrapMode.TileOriginal;
  Canvas.FillRect(RectF(120, 240, 220, 320), 1);
  Canvas.Fill.Bitmap.WrapMode := TWrapMode.TileStretch;
  Canvas.FillRect(RectF(230, 240, 330, 320), 1);
  Canvas.DrawBitmap(FTile, RectF(0, 0, 16, 16), RectF(340, 240, 420, 320), 1, True);
  Canvas.DrawBitmap(FTile, RectF(0, 0, 16, 16), RectF(430, 240, 510, 320), 1, False);
  Canvas.DrawBitmap(FTile, RectF(0, 0, 8, 8), RectF(520, 240, 600, 320), 1, False);
  if not FLoaded.IsEmpty then
    Canvas.DrawBitmap(FLoaded, RectF(0, 0, FLoaded.Width, FLoaded.Height), RectF(610, 240, 690, 320), 0.5, True);

  // Row 4: text.
  Canvas.Fill.Kind := TBrushKind.Solid;
  Canvas.Fill.Color := TAlphaColors.Black;
  Canvas.Stroke.Kind := TBrushKind.Solid;
  Canvas.Stroke.Color := TAlphaColors.Silver;
  Canvas.Stroke.Thickness := 1;
  Canvas.Font.Size := 16;
  Canvas.FillText(RectF(10, 335, 370, 360), 'Unicode: Gr'#$00FC#$00DF'e '#$2713' '#$D834#$DD1E' '#$D83D#$DE00' '#$2192,
    False, 1, [], TTextAlign.Leading, TTextAlign.Center);
  Canvas.DrawRect(RectF(10.5, 365.5, 170.5, 470.5), 0, 0, [], 1);
  Canvas.FillText(RectF(10, 365, 170, 470), 'Word wrap: a long sentence that wraps inside a narrow box.', True, 1, [],
    TTextAlign.Leading, TTextAlign.Leading);
  Canvas.DrawRect(RectF(180.5, 365.5, 370.5, 390.5), 0, 0, [], 1);
  Canvas.FillText(RectF(180, 365, 370, 390), 'Centered', False, 1, [], TTextAlign.Center, TTextAlign.Center);
  Canvas.DrawRect(RectF(180.5, 395.5, 370.5, 420.5), 0, 0, [], 1);
  Canvas.FillText(RectF(180, 395, 370, 420), 'Right', False, 1, [], TTextAlign.Trailing, TTextAlign.Center);
  L := NewLayout(Canvas, 'Trimming: this text is far too long for its box', 16);
  try
    L.BeginUpdate;
    L.MaxSize := PointF(190, 25);
    L.Trimming := TTextTrimming.Character;
    L.TopLeft := PointF(180, 425);
    L.EndUpdate;
    Canvas.DrawRect(RectF(180.5, 425.5, 370.5, 450.5), 0, 0, [], 1);
    L.RenderLayout(Canvas);
  finally
    L.Free;
  end;
  Canvas.Font.Style := [TFontStyle.fsBold, TFontStyle.fsItalic, TFontStyle.fsUnderline, TFontStyle.fsStrikeOut];
  Canvas.FillText(RectF(180, 455, 370, 480), 'Bold italic lines', False, 1, [], TTextAlign.Leading,
    TTextAlign.Center);
  Canvas.Font.Style := [];
  Canvas.Fill.Color := TAlphaColors.Darkred;
  Canvas.FillText(RectF(10, 480, 370, 505), 'Half transparent text', False, 0.5, [], TTextAlign.Leading,
    TTextAlign.Center);

  // Rotated text, text as a path (gradient fill).
  Save := Canvas.SaveState;
  try
    M := Canvas.Matrix;
    Canvas.SetMatrix(TMatrix.CreateRotation(DegToRad(-20)) * TMatrix.CreateTranslation(400, 520) * M);
    Canvas.Fill.Color := TAlphaColors.Teal;
    Canvas.FillText(RectF(0, -30, 220, 0), 'Rotated text', False, 1, [], TTextAlign.Leading, TTextAlign.Center);
  finally
    Canvas.RestoreState(Save);
  end;
  L := NewLayout(Canvas, 'Path', 56);
  Path := TPathData.Create;
  try
    L.ConvertToPath(Path);
    Path.Translate(580, 360);
    Canvas.Fill.Kind := TBrushKind.Gradient;
    Canvas.Fill.Gradient.Style := TGradientStyle.Linear;
    Canvas.Fill.Gradient.StartPosition.Point := PointF(0, 0);
    Canvas.Fill.Gradient.StopPosition.Point := PointF(0, 1);
    Stops([TAlphaColors.Crimson, TAlphaColors.Navy], [0, 1]);
    Canvas.FillPath(Path, 1);
  finally
    Path.Free;
    L.Free;
  end;

  // A degenerate matrix (a control scaled to 0) must not stop the drawing that follows.
  Save := Canvas.SaveState;
  try
    Canvas.SetMatrix(TMatrix.CreateScaling(0, 0));
    Canvas.Fill.Kind := TBrushKind.Solid;
    Canvas.Fill.Color := TAlphaColors.Red;
    Canvas.FillRect(RectF(0, 0, 100, 100), 1);
    Canvas.FillText(RectF(0, 0, 100, 100), 'x', False, 1, [], TTextAlign.Leading, TTextAlign.Leading);
  finally
    Canvas.RestoreState(Save);
  end;
  Canvas.Fill.Kind := TBrushKind.Solid;
  Canvas.Fill.Color := TAlphaColors.Lime;
  Canvas.FillRect(RectF(700, 500, 750, 550), 1);
end;

end.
