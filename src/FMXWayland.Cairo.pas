{ FMXWayland: Cairo raster canvas, Pango text and GdkPixbuf codecs.
  Written by Hemul GM. Copyright (c) 2026 Fasday and contributors. MIT license, see LICENSE. }

/// <summary>FMX's default Linux canvas (FMX.Canvas.Linux, TLinuxCanvas: used when GlobalUseSkia is False) served
/// through the FMUX canvas, text layout and bitmap codec functions, on the system's cairo, Pango and
/// gdk-pixbuf (loaded at run time, FMXWayland.CairoApi).</summary>
/// <remarks>The FMUX context handle is a TCairoContext: over a window frame (CreateCairoFrame, made by
/// FMXWayland.Fmux for each paint) or over an FMUX bitmap (FmuxCreateContext, for TBitmap canvases). What
/// TLinuxCanvas expects: solid colors arrive with the opacity already in their alpha, gradients and bitmap brushes
/// get it as the argument of FmuxCanvasFill/FmuxCanvasStroke; dash lengths are in units of the stroke width; FMX's
/// radial gradients run from the edge (offset 0) to the center (offset 1).</remarks>
unit FMXWayland.Cairo;

interface

uses
  System.Types;

type
  /// <summary>An FMUX bitmap: plain memory, premultiplied BGRA (as CAIRO_FORMAT_ARGB32), 4 bytes per pixel, no
  /// padding. Shared with the bitmap functions of FMXWayland.Fmux.</summary>
  TFmuxBitmap = record
    Width, Height: Integer;
    Data: Pointer;
    OwnsData: Boolean;
  end;
  PFmuxBitmap = ^TFmuxBitmap;

/// <summary>Assigns the canvas, text layout, bitmap codec and font functions of FMUX.Api.</summary>
procedure AssignCairoApi;
/// <summary>A cairo context over the pixels of a window frame (premultiplied BGRA, Stride bytes per row), scaled by
/// Scale (buffer pixels per logical pixel). Free it with DestroyCairoFrame.</summary>
function CreateCairoFrame(Bits: Pointer; Width, Height, Stride: Integer; Scale: Single): Pointer;
/// <summary>Frees a context of CreateCairoFrame or FmuxCreateContext.</summary>
procedure DestroyCairoFrame(Context: Pointer); cdecl;
/// <summary>True when Context is a context of this unit (FMX's cairo canvas), not a PWlFrame (Skia canvas).</summary>
function IsCairoContext(Context: Pointer): Boolean;
/// <summary>FmuxCanvasDrawBitmap for cairo contexts.</summary>
procedure CairoDrawBitmap(Context, Bitmap: Pointer; Src, Dst: System.Types.TRectF; Opacity: Single;
  HighSpeed: Boolean); cdecl;

implementation

uses
  System.SysUtils, System.UITypes, System.Math, System.Generics.Collections,
  FMUX.Api, FMXWayland.CairoApi, FMXWayland.Log;

type
  /// <summary>What FmuxSave/FmuxRestore keep besides cairo's own state.</summary>
  TCairoState = record
    AlphaInSource: Boolean;
    Degenerate: Boolean;
  end;

  TCairoContext = class
    Surface, Cr: Pointer;
    Scale: Double;
    /// <summary>The current source already carries FMX's opacity (solid colors: TLinuxCanvas multiplies it into the
    /// color); gradients and bitmaps get it at Fill/Stroke.</summary>
    AlphaInSource: Boolean;
    /// <summary>FMX set a matrix that cannot be inverted (a control scaled to 0): cairo would go into a permanent
    /// error state, so it keeps the previous matrix and nothing is drawn until the next valid one.</summary>
    Degenerate: Boolean;
    States: TList<TCairoState>;
    constructor Create(Bits: Pointer; Width, Height, Stride: Integer; AScale: Double);
    destructor Destroy; override;
    procedure CreateCr;
  end;

  /// <summary>A Pango layout and the UTF-16 -> UTF-8 index map of its text.</summary>
  TCairoText = class
    Layout: Pointer;
    Text: string;
    Utf8: UTF8String;
    /// <summary>Byte offset in Utf8 of each UTF-16 index of Text (the low surrogate of a pair has the offset of its
    /// character), plus the length at Length(Text).</summary>
    ByteOffsets: TArray<Integer>;
    destructor Destroy; override;
    procedure SetText(const Value: string);
    function ByteIndex(Index: Integer): Integer;
    function CharIndex(Index, Trailing: Integer): Integer;
  end;

var
  GFontNames: TArray<string>;

function C(Context: Pointer): TCairoContext; inline;
begin
  Result := TCairoContext(Context);
end;

constructor TCairoContext.Create(Bits: Pointer; Width, Height, Stride: Integer; AScale: Double);
var
  Status: Integer;
begin
  inherited Create;
  LoadGraphicsLibraries;
  Scale := AScale;
  States := TList<TCairoState>.Create;
  Surface := cairo_image_surface_create_for_data(Bits, CAIRO_FORMAT_ARGB32, Width, Height, Stride);
  Status := cairo_surface_status(Surface);
  if Status <> 0 then
    raise Exception.Create('FMXWayland: Cairo surface: ' + string(UTF8String(cairo_status_to_string(Status))));
  CreateCr;
end;

procedure TCairoContext.CreateCr;
var
  Status: Integer;
begin
  Cr := cairo_create(Surface);
  Status := cairo_status(Cr);
  if Status <> 0 then
    raise Exception.Create('FMXWayland: Cairo context: ' + string(UTF8String(cairo_status_to_string(Status))));
  cairo_scale(Cr, Scale, Scale);
end;

destructor TCairoContext.Destroy;
begin
  if Cr <> nil then
    cairo_destroy(Cr);
  if Surface <> nil then
  begin
    cairo_surface_flush(Surface);
    cairo_surface_destroy(Surface);
  end;
  States.Free;
  inherited;
end;

function CreateCairoFrame(Bits: Pointer; Width, Height, Stride: Integer; Scale: Single): Pointer;
begin
  Result := nil;
  if (Bits <> nil) and (Width > 0) and (Height > 0) then
    Result := TCairoContext.Create(Bits, Width, Height, Stride, Scale);
end;

procedure DestroyCairoFrame(Context: Pointer); cdecl;
begin
  TCairoContext(Context).Free;
end;

function IsCairoContext(Context: Pointer): Boolean;
begin
  // An object starts with its class (VMT) pointer; a PWlFrame starts with the address of its pixels.
  Result := (Context <> nil) and (PPointer(Context)^ = Pointer(TCairoContext));
end;

function CreateContext(Bitmap: Pointer): Pointer; cdecl;
var
  B: PFmuxBitmap;
begin
  B := Bitmap;
  Result := nil;
  if B <> nil then
    Result := CreateCairoFrame(B.Data, B.Width, B.Height, B.Width * 4, 1);
end;

procedure Save(Context: Pointer); cdecl;
var
  S: TCairoState;
begin
  if (C(Context).States.Count = 0) and (cairo_status(C(Context).Cr) <> 0) then
  begin
    // A bitmap's context lives as long as its canvas: start its next scene with a usable cairo context.
    WlLogOnce('cairo-status', 'cairo: ' + string(UTF8String(cairo_status_to_string(cairo_status(C(Context).Cr)))));
    cairo_destroy(C(Context).Cr);
    C(Context).CreateCr;
    C(Context).Degenerate := False;
  end;
  cairo_save(C(Context).Cr);
  S.AlphaInSource := C(Context).AlphaInSource;
  S.Degenerate := C(Context).Degenerate;
  C(Context).States.Add(S);
end;

procedure Restore(Context: Pointer); cdecl;
var
  Last: Integer;
begin
  Last := C(Context).States.Count - 1;
  if Last < 0 then
    Exit;
  C(Context).AlphaInSource := C(Context).States[Last].AlphaInSource;
  C(Context).Degenerate := C(Context).States[Last].Degenerate;
  C(Context).States.Delete(Last);
  cairo_restore(C(Context).Cr);
end;

procedure SetMatrix(Context: Pointer; M11, M12, M21, M22, M31, M32: Single); cdecl;
var
  M: TCairoMatrix;
  S, Det: Double;
begin
  S := C(Context).Scale;
  M.XX := M11 * S;
  M.YX := M12 * S;
  M.XY := M21 * S;
  M.YY := M22 * S;
  M.X0 := M31 * S;
  M.Y0 := M32 * S;
  Det := M.XX * M.YY - M.YX * M.XY;
  C(Context).Degenerate := IsNan(Det) or IsInfinite(Det) or (Abs(Det) < 1E-12) or IsNan(M.X0) or IsNan(M.Y0) or
    IsInfinite(M.X0) or IsInfinite(M.Y0);
  if not C(Context).Degenerate then
    cairo_set_matrix(C(Context).Cr, @M);
end;

procedure SetQuality(Context: Pointer; Quality: Integer); cdecl;
begin
  case Quality of
    FmuxCanvasQualityHighPerformance:
      cairo_set_antialias(C(Context).Cr, CAIRO_ANTIALIAS_FAST);
    FmuxCanvasQualityHighQuality:
      cairo_set_antialias(C(Context).Cr, CAIRO_ANTIALIAS_BEST);
  else
    cairo_set_antialias(C(Context).Cr, CAIRO_ANTIALIAS_DEFAULT);
  end;
end;

procedure SetColor(Context: Pointer; Color: TAlphaColor); cdecl;
begin
  cairo_set_source_rgba(C(Context).Cr, ((Color shr 16) and 255) / 255, ((Color shr 8) and 255) / 255,
    (Color and 255) / 255, (Color shr 24) / 255);
  // TLinuxCanvas.ApplyFill/ApplyStroke already multiplied solid-color alpha by opacity.
  C(Context).AlphaInSource := True;
end;

/// Clips to nothing (what a clip rectangle under a degenerate matrix amounts to).
procedure ClipEmpty(Context: Pointer);
begin
  cairo_new_path(C(Context).Cr);
  cairo_rectangle(C(Context).Cr, 0, 0, 0, 0);
  cairo_clip(C(Context).Cr);
end;

procedure SetClipRects(Context: Pointer; const Rects: PRectF; const Count: Integer); cdecl;
var
  I: Integer;
  R: PRectF;
  Matrix, Identity: TCairoMatrix;
  X1, Y1, X2, Y2, EpsilonX, EpsilonY: Double;
  Left, Top, Right, Bottom: Integer;
begin
  if (Rects = nil) or (Count <= 0) then
    Exit;
  if C(Context).Degenerate then
  begin
    ClipEmpty(Context);
    Exit;
  end;
  // Update rectangles are pixel regions, not antialiased vector geometry. Fractional clips leave
  // old color behind when SOURCE clears them and multiply coverage again when controls are drawn.
  cairo_get_matrix(C(Context).Cr, @Matrix);
  FillChar(Identity, SizeOf(Identity), 0);
  Identity.XX := 1;
  Identity.YY := 1;
  cairo_set_matrix(C(Context).Cr, @Identity);
  try
    cairo_new_path(C(Context).Cr);
    R := Rects;
    for I := 0 to Count - 1 do
    begin
      if not R.IsEmpty then
      begin
        X1 := R.Left * Matrix.XX + R.Top * Matrix.XY + Matrix.X0;
        X2 := R.Right * Matrix.XX + R.Bottom * Matrix.XY + Matrix.X0;
        Y1 := R.Left * Matrix.YX + R.Top * Matrix.YY + Matrix.Y0;
        Y2 := R.Right * Matrix.YX + R.Bottom * Matrix.YY + Matrix.Y0;
        // FMX stores logical bounds as Single; tolerate its rounding of integer device boundaries.
        EpsilonX := Max(1E-6, Max(Abs(X1), Abs(X2)) * 1E-7);
        EpsilonY := Max(1E-6, Max(Abs(Y1), Abs(Y2)) * 1E-7);
        Left := Floor(Min(X1, X2) + EpsilonX);
        Top := Floor(Min(Y1, Y2) + EpsilonY);
        Right := Ceil(Max(X1, X2) - EpsilonX);
        Bottom := Ceil(Max(Y1, Y2) - EpsilonY);
        cairo_rectangle(C(Context).Cr, Left, Top, Right - Left, Bottom - Top);
      end;
      Inc(R);
    end;
    cairo_clip(C(Context).Cr);
  finally
    cairo_set_matrix(C(Context).Cr, @Matrix);
  end;
end;

procedure IntersectClip(Context: Pointer; const R: TRectF); cdecl;
begin
  if C(Context).Degenerate then
  begin
    ClipEmpty(Context);
    Exit;
  end;
  cairo_new_path(C(Context).Cr);
  cairo_rectangle(C(Context).Cr, R.Left, R.Top, R.Width, R.Height);
  cairo_clip(C(Context).Cr);
end;

procedure ExcludeClip(Context: Pointer; const R: TRectF); cdecl;
var
  X1, Y1, X2, Y2: Double;
begin
  if C(Context).Degenerate then
    Exit;
  cairo_clip_extents(C(Context).Cr, @X1, @Y1, @X2, @Y2);
  cairo_new_path(C(Context).Cr);
  cairo_rectangle(C(Context).Cr, X1, Y1, X2 - X1, Y2 - Y1);
  cairo_rectangle(C(Context).Cr, R.Left, R.Top, R.Width, R.Height);
  cairo_set_fill_rule(C(Context).Cr, CAIRO_FILL_RULE_EVEN_ODD); // even-odd subtraction
  cairo_clip(C(Context).Cr);
  cairo_set_fill_rule(C(Context).Cr, CAIRO_FILL_RULE_WINDING);
end;

procedure Clear(Context: Pointer; Color: TAlphaColor); cdecl;
begin
  Save(Context);
  try
    cairo_set_operator(C(Context).Cr, CAIRO_OPERATOR_SOURCE); // including transparent pixels
    SetColor(Context, Color);
    cairo_paint(C(Context).Cr);
  finally
    Restore(Context);
  end;
end;

procedure ClearRect(Context: Pointer; R: TRectF; Color: TAlphaColor); cdecl;
var
  Matrix: TCairoMatrix;
begin
  if C(Context).Degenerate then
    Exit;
  Save(Context);
  try
    cairo_get_matrix(C(Context).Cr, @Matrix);
    if (Abs(Matrix.XY) < 1E-10) and (Abs(Matrix.YX) < 1E-10) then
      SetClipRects(Context, @R, 1)
    else
      IntersectClip(Context, R);
    Clear(Context, Color);
  finally
    Restore(Context);
  end;
end;

procedure AddStop(Pattern: Pointer; Offset: Double; Color: Cardinal);
begin
  cairo_pattern_add_color_stop_rgba(Pattern, Offset, ((Color shr 16) and 255) / 255, ((Color shr 8) and 255) / 255,
    (Color and 255) / 255, (Color shr 24) / 255);
end;

procedure SetStops(Pattern: Pointer; Stops: PFmuxGradient; Count: Integer);
var
  I: Integer;
begin
  for I := 0 to Count - 1 do
  begin
    AddStop(Pattern, Stops.Offset, Stops.Color);
    Inc(Stops);
  end;
  cairo_pattern_set_extend(Pattern, CAIRO_EXTEND_PAD);
end;

procedure SetGradient(Context: Pointer; P1, P2: TPointF; Stops: PFmuxGradient; Count: Integer); cdecl;
var
  Pattern: Pointer;
begin
  Pattern := cairo_pattern_create_linear(P1.X, P1.Y, P2.X, P2.Y);
  try
    SetStops(Pattern, Stops, Count);
    cairo_set_source(C(Context).Cr, Pattern);
    C(Context).AlphaInSource := False;
  finally
    cairo_pattern_destroy(Pattern);
  end;
end;

procedure SetRadialGradient(Context: Pointer; Center, P1, P2: TPointF; Stops: PFmuxGradient; Count: Integer); cdecl;
var
  Pattern: Pointer;
  M: TCairoMatrix;
  I: Integer;
  Stop: PFmuxGradient;
begin
  // The ellipse inscribed in P1-P2 around Center; cairo's offset 0 is the center, FMX's is the edge.
  Pattern := cairo_pattern_create_radial(0, 0, 0, 0, 0, 1);
  try
    for I := Count - 1 downto 0 do
    begin
      Stop := Stops;
      Inc(Stop, I);
      AddStop(Pattern, 1 - Stop.Offset, Stop.Color);
    end;
    cairo_pattern_set_extend(Pattern, CAIRO_EXTEND_PAD);
    FillChar(M, SizeOf(M), 0);
    M.XX := 1 / Max(0.0001, Abs(P2.X - P1.X) / 2);
    M.YY := 1 / Max(0.0001, Abs(P2.Y - P1.Y) / 2);
    M.X0 := -Center.X * M.XX;
    M.Y0 := -Center.Y * M.YY;
    cairo_pattern_set_matrix(Pattern, @M);
    cairo_set_source(C(Context).Cr, Pattern);
    C(Context).AlphaInSource := False;
  finally
    cairo_pattern_destroy(Pattern);
  end;
end;

function BitmapSurface(Bitmap: Pointer): Pointer;
var
  B: PFmuxBitmap;
begin
  B := Bitmap;
  Result := cairo_image_surface_create_for_data(B.Data, CAIRO_FORMAT_ARGB32, B.Width, B.Height, B.Width * 4);
end;

/// A bitmap that can be drawn: memory and a size.
function BitmapUsable(Bitmap: Pointer): Boolean;
begin
  Result := (Bitmap <> nil) and (PFmuxBitmap(Bitmap).Data <> nil) and (PFmuxBitmap(Bitmap).Width > 0) and
    (PFmuxBitmap(Bitmap).Height > 0);
end;

procedure SetBitmap(Context, Bitmap: Pointer; R: TRectF; Mode: Integer); cdecl;
const
  // TWrapMode
  Tile = 0;
  TileOriginal = 1;
  TileStretch = 2;
var
  Surface, Pattern: Pointer;
  M: TCairoMatrix;
  B: PFmuxBitmap;
begin
  B := Bitmap;
  if not BitmapUsable(B) then
    Exit;
  Surface := BitmapSurface(Bitmap);
  Pattern := cairo_pattern_create_for_surface(Surface);
  try
    // Tile repeats the bitmap at its size from the rectangle's corner, TileOriginal draws it there once,
    // TileStretch stretches it over the rectangle.
    FillChar(M, SizeOf(M), 0);
    M.XX := 1;
    M.YY := 1;
    if (Mode = TileStretch) and (R.Width > 0) and (R.Height > 0) then
    begin
      M.XX := B.Width / R.Width;
      M.YY := B.Height / R.Height;
    end;
    M.X0 := -R.Left * M.XX;
    M.Y0 := -R.Top * M.YY;
    cairo_pattern_set_matrix(Pattern, @M);
    case Mode of
      Tile:
        cairo_pattern_set_extend(Pattern, CAIRO_EXTEND_REPEAT);
      TileOriginal:
        cairo_pattern_set_extend(Pattern, CAIRO_EXTEND_NONE);
    else
      cairo_pattern_set_extend(Pattern, CAIRO_EXTEND_PAD);
    end;
    cairo_set_source(C(Context).Cr, Pattern);
    C(Context).AlphaInSource := False;
  finally
    cairo_pattern_destroy(Pattern);
    cairo_surface_destroy(Surface);
  end;
end;

procedure RectPath(Context: Pointer; R: TRectF); cdecl;
begin
  cairo_new_path(C(Context).Cr);
  cairo_rectangle(C(Context).Cr, R.Left, R.Top, R.Width, R.Height);
end;

procedure EllipsePath(Context: Pointer; R: TRectF); cdecl;
begin
  cairo_new_path(C(Context).Cr);
  if (R.Width <= 0) or (R.Height <= 0) then
    Exit;
  cairo_save(C(Context).Cr);
  cairo_translate(C(Context).Cr, R.CenterPoint.X, R.CenterPoint.Y);
  cairo_scale(C(Context).Cr, R.Width / 2, R.Height / 2);
  cairo_arc(C(Context).Cr, 0, 0, 1, 0, 2 * Pi);
  cairo_restore(C(Context).Cr);
end;

procedure LinePath(Context: Pointer; P1, P2: TPointF); cdecl;
begin
  cairo_new_path(C(Context).Cr);
  cairo_move_to(C(Context).Cr, P1.X, P1.Y);
  cairo_line_to(C(Context).Cr, P2.X, P2.Y);
end;

procedure AppendPath(Cr: Pointer; Pts: PFmuxPathPoint; Count: Integer);
var
  I: Integer;
  P, Control1, Control2: PFmuxPathPoint;
begin
  // FMUX's path array has a declared bound of 0; walk the Count points directly
  // so this also works with range checking enabled.
  P := Pts;
  I := 0;
  while I < Count do
  begin
    case P.Kind of
      TFmuxPathPointKind.MoveTo:
        cairo_move_to(Cr, P.Point.X, P.Point.Y);
      TFmuxPathPointKind.LineTo:
        cairo_line_to(Cr, P.Point.X, P.Point.Y);
      TFmuxPathPointKind.CurveTo:
        if Count - I >= 3 then
        begin
          Control1 := P;
          Inc(P);
          Control2 := P;
          Inc(P);
          cairo_curve_to(Cr, Control1.Point.X, Control1.Point.Y, Control2.Point.X, Control2.Point.Y,
            P.Point.X, P.Point.Y);
          Inc(I, 2);
        end;
      TFmuxPathPointKind.Close:
        cairo_close_path(Cr);
    end;
    Inc(P);
    Inc(I);
  end;
end;

procedure Path(Context: Pointer; Pts: PFmuxPathPoint; Count: Integer); cdecl;
begin
  cairo_new_path(C(Context).Cr);
  AppendPath(C(Context).Cr, Pts, Count);
end;

procedure DrawPath(Context: Pointer; Opacity: Single; Stroke: Boolean);
begin
  if C(Context).Degenerate or ((Opacity <= 0) and not C(Context).AlphaInSource) then
  begin
    cairo_new_path(C(Context).Cr);
    Exit;
  end;
  if C(Context).AlphaInSource or (Opacity >= 1) then
  begin
    if Stroke then
      cairo_stroke(C(Context).Cr)
    else
      cairo_fill(C(Context).Cr);
    Exit;
  end;
  cairo_save(C(Context).Cr);
  if Stroke then
  begin
    cairo_push_group(C(Context).Cr);
    cairo_stroke(C(Context).Cr);
    cairo_pop_group_to_source(C(Context).Cr);
  end
  else
    // The path as a clip and the source painted through it: the fill with an opacity, without a group.
    cairo_clip(C(Context).Cr);
  cairo_paint_with_alpha(C(Context).Cr, Opacity);
  cairo_restore(C(Context).Cr);
end;

procedure Fill(Context: Pointer; Opacity: Single); cdecl;
begin
  DrawPath(Context, Opacity, False);
end;

procedure Stroke(Context: Pointer; Opacity: Single); cdecl;
begin
  DrawPath(Context, Opacity, True);
end;

procedure SetStrokeWidth(Context: Pointer; Width: Single); cdecl;
begin
  cairo_set_line_width(C(Context).Cr, Max(0, Width));
end;

procedure SetStrokeCap(Context: Pointer; Cap: Integer); cdecl;
begin
  // TStrokeCap: Flat, Round. FMX's other canvases (Direct2D, Skia) draw Flat with square caps: lines and dashes
  // reach half the width beyond their ends.
  if Cap = 1 then
    cairo_set_line_cap(C(Context).Cr, CAIRO_LINE_CAP_ROUND)
  else
    cairo_set_line_cap(C(Context).Cr, CAIRO_LINE_CAP_SQUARE);
end;

procedure SetStrokeJoin(Context: Pointer; Join: Integer); cdecl;
begin
  cairo_set_line_join(C(Context).Cr, EnsureRange(Join, 0, 2));
end;

procedure SetStrokeDash(Context: Pointer; Offset: Single; DashArray: Pointer; Length: Integer); cdecl;

  function Value(const AIndex: Integer): Single;
  begin
    Result := PSingle(PByte(DashArray) + AIndex * SizeOf(Single))^;
  end;

  function Matches(const APreset: array of Single): Boolean;
  var
    K: Integer;
  begin
    Result := High(APreset) + 1 = Length;
    if Result then
      for K := 0 to High(APreset) do
        if Value(K) <> APreset[K] then
          Exit(False);
  end;

var
  Dashes: TArray<Double>;
  I: Integer;
  Width, Cap: Double;
begin
  Width := cairo_get_line_width(C(Context).Cr);
  if (DashArray = nil) or (Length <= 0) or (Width <= 0) then
  begin
    cairo_set_dash(C(Context).Cr, nil, 0, 0);
    Exit;
  end;
  // The lengths are in stroke widths. Each dash gets the caps, half a width at each end; the preset styles
  // (TStrokeDash.Dash, Dot, DashDot, DashDotDot) mean what is seen, so their dashes are shortened by the caps and
  // their gaps lengthened; custom arrays are taken as they are (FMX's Direct2D and Skia canvases do the same).
  Cap := 0;
  if (Offset = 0) and (Matches([3, 1]) or Matches([1, 1]) or Matches([3, 1, 1, 1]) or
    Matches([3, 1, 1, 1, 1, 1])) then
    Cap := Width;
  SetLength(Dashes, Length);
  for I := 0 to Length - 1 do
    if Odd(I) then
      Dashes[I] := Max(0, Value(I) * Width + Cap)
    else
      // Not zero: cairo leaves out some dashes of length 0 (their caps make dots); all zero would be an error.
      Dashes[I] := Max(Width / 100, Value(I) * Width - Cap);
  cairo_set_dash(C(Context).Cr, @Dashes[0], Length, Offset * Width);
end;

procedure CairoDrawBitmap(Context, Bitmap: Pointer; Src, Dst: TRectF; Opacity: Single; HighSpeed: Boolean); cdecl;
var
  B: PFmuxBitmap;
  Surface, Sub, Pattern: Pointer;
  SX, SY, SR, SB: Integer;
begin
  if (Context = nil) or not BitmapUsable(Bitmap) or (Src.Width <= 0) or (Src.Height <= 0) or (Dst.Width <= 0) or
    (Dst.Height <= 0) or C(Context).Degenerate or (Opacity <= 0) then
    Exit;
  B := Bitmap;
  // The source rectangle as a surface of its own, extended with its edge pixels: filtering must not blend in the
  // pixels around it (FMX's styles draw parts of one bitmap), nor transparency at the edges of the destination.
  SX := EnsureRange(Floor(Src.Left), 0, B.Width - 1);
  SY := EnsureRange(Floor(Src.Top), 0, B.Height - 1);
  SR := EnsureRange(Ceil(Src.Right), SX + 1, B.Width);
  SB := EnsureRange(Ceil(Src.Bottom), SY + 1, B.Height);
  Surface := BitmapSurface(Bitmap);
  Sub := cairo_surface_create_for_rectangle(Surface, SX, SY, SR - SX, SB - SY);
  cairo_save(C(Context).Cr);
  try
    IntersectClip(Context, Dst);
    cairo_translate(C(Context).Cr, Dst.Left, Dst.Top);
    cairo_scale(C(Context).Cr, Dst.Width / Src.Width, Dst.Height / Src.Height);
    cairo_set_source_surface(C(Context).Cr, Sub, SX - Src.Left, SY - Src.Top);
    Pattern := cairo_get_source(C(Context).Cr);
    cairo_pattern_set_extend(Pattern, CAIRO_EXTEND_PAD);
    if HighSpeed then
      cairo_pattern_set_filter(Pattern, CAIRO_FILTER_NEAREST)
    else
      cairo_pattern_set_filter(Pattern, CAIRO_FILTER_GOOD);
    if Opacity >= 1 then
      cairo_paint(C(Context).Cr)
    else
      cairo_paint_with_alpha(C(Context).Cr, Opacity);
  finally
    cairo_restore(C(Context).Cr);
    cairo_surface_destroy(Sub);
    cairo_surface_destroy(Surface);
  end;
end;

function PtInPath(Pt: TPointF; Pts: PFmuxPathPoint; Count: Integer): Boolean; cdecl;
var
  Surface, Cr: Pointer;
begin
  LoadGraphicsLibraries;
  Surface := cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
  Cr := cairo_create(Surface);
  try
    AppendPath(Cr, Pts, Count);
    Result := cairo_in_fill(Cr, Pt.X, Pt.Y) <> 0;
  finally
    cairo_destroy(Cr);
    cairo_surface_destroy(Surface);
  end;
end;

destructor TCairoText.Destroy;
begin
  if Layout <> nil then
    g_object_unref(Layout);
  inherited;
end;

procedure TCairoText.SetText(const Value: string);
var
  I, N, Len: Integer;
  Code: Cardinal;
  P: PByte;
begin
  // UTF-16 -> UTF-8 here (not by the RTL) so that the offsets match the bytes exactly: a lone surrogate (invalid in
  // UTF-8, Pango would reject the text) and NUL (Pango ends the text there) become U+FFFD.
  Text := Value;
  Len := System.Length(Value);
  SetLength(ByteOffsets, Len + 1);
  SetLength(Utf8, Len * 3);
  P := PByte(PAnsiChar(Utf8));
  N := 0;
  I := 1;
  while I <= Len do
  begin
    ByteOffsets[I - 1] := N;
    Code := Ord(Value[I]);
    if (Code >= $D800) and (Code <= $DBFF) and (I < Len) and (Ord(Value[I + 1]) >= $DC00) and
      (Ord(Value[I + 1]) <= $DFFF) then
    begin
      Code := $10000 + ((Code - $D800) shl 10) + (Cardinal(Ord(Value[I + 1])) - $DC00);
      ByteOffsets[I] := N;
      Inc(I);
    end
    else if ((Code >= $D800) and (Code <= $DFFF)) or (Code = 0) then
      Code := $FFFD;
    if Code < $80 then
    begin
      P[N] := Byte(Code);
      Inc(N);
    end
    else if Code < $800 then
    begin
      P[N] := Byte($C0 or (Code shr 6));
      P[N + 1] := Byte($80 or (Code and $3F));
      Inc(N, 2);
    end
    else if Code < $10000 then
    begin
      P[N] := Byte($E0 or (Code shr 12));
      P[N + 1] := Byte($80 or ((Code shr 6) and $3F));
      P[N + 2] := Byte($80 or (Code and $3F));
      Inc(N, 3);
    end
    else
    begin
      P[N] := Byte($F0 or (Code shr 18));
      P[N + 1] := Byte($80 or ((Code shr 12) and $3F));
      P[N + 2] := Byte($80 or ((Code shr 6) and $3F));
      P[N + 3] := Byte($80 or (Code and $3F));
      Inc(N, 4);
    end;
    Inc(I);
  end;
  ByteOffsets[Len] := N;
  SetLength(Utf8, N);
end;

function TCairoText.ByteIndex(Index: Integer): Integer;
begin
  Result := ByteOffsets[EnsureRange(Index, 0, System.Length(Text))];
end;

function TCairoText.CharIndex(Index, Trailing: Integer): Integer;
var
  Lo, Hi, Mid: Integer;
begin
  // The first UTF-16 index at or after byte Index (binary search: the offsets ascend).
  Lo := 0;
  Hi := System.Length(Text);
  while Lo < Hi do
  begin
    Mid := (Lo + Hi) div 2;
    if ByteOffsets[Mid] < Index then
      Lo := Mid + 1
    else
      Hi := Mid;
  end;
  Result := Lo;
  // Pango's trailing counts characters: a surrogate pair is one.
  while (Trailing > 0) and (Result < System.Length(Text)) do
  begin
    Inc(Result);
    if (Result < System.Length(Text)) and (ByteOffsets[Result] = ByteOffsets[Result - 1]) then
      Inc(Result);
    Dec(Trailing);
  end;
end;

function CreateText(Text: PChar; var Font: TFmuxFont; Width, Height: Single; Align, Trimming: Integer;
  WordWrap: Boolean): Pointer; cdecl;
const
  // TFontWeight (Thin .. UltraBlack) -> PangoWeight.
  Weights: array[0..10] of Integer = (100, 200, 300, 350, 400, 500, 600, 700, 800, 900, 1000);
  // FMX: center/leading/trailing; Pango: left/center/right.
  Alignments: array[0..2] of Integer = (PANGO_ALIGN_CENTER, PANGO_ALIGN_LEFT, PANGO_ALIGN_RIGHT);
var
  T: TCairoText;
  Surface, Cr, Desc, Attrs, Options: Pointer;
  Family: UTF8String;
begin
  LoadGraphicsLibraries;
  T := TCairoText.Create;
  Surface := cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
  Cr := cairo_create(Surface);
  try
    try
      T.SetText(string(Text));
      T.Layout := pango_cairo_create_layout(Cr);
      // Grayscale antialiasing: subpixel (fontconfig's rgba) leaves colored fringes on transparent bitmaps, and a
      // Wayland client does not know the subpixel order of where its pixels end up.
      Options := cairo_font_options_create;
      try
        cairo_font_options_set_antialias(Options, CAIRO_ANTIALIAS_GRAY);
        pango_cairo_context_set_font_options(pango_layout_get_context(T.Layout), Options);
      finally
        cairo_font_options_destroy(Options);
      end;
      pango_layout_context_changed(T.Layout);
      Desc := pango_font_description_new;
      try
        Family := UTF8String(string(Font.Family));
        pango_font_description_set_family(Desc, PAnsiChar(Family));
        pango_font_description_set_absolute_size(Desc, Max(1, Font.Size) * PANGO_SCALE);
        pango_font_description_set_weight(Desc, Weights[EnsureRange(Font.Weight, 0, 10)]);
        case Font.Slant of
          1:
            pango_font_description_set_style(Desc, PANGO_STYLE_ITALIC);
          2:
            pango_font_description_set_style(Desc, PANGO_STYLE_OBLIQUE);
        end;
        pango_layout_set_font_description(T.Layout, Desc);
      finally
        pango_font_description_free(Desc);
      end;
      pango_layout_set_text(T.Layout, PAnsiChar(T.Utf8), System.Length(T.Utf8));
      if WordWrap or (Trimming <> 0) then
      begin
        pango_layout_set_width(T.Layout, Round(Min(Max(0, Width) * PANGO_SCALE, MaxInt)));
        pango_layout_set_wrap(T.Layout, PANGO_WRAP_WORD_CHAR); // word-char fallback for long words
        pango_layout_set_alignment(T.Layout, Alignments[EnsureRange(Align, 0, 2)]);
      end
      else
        pango_layout_set_width(T.Layout, -1); // FMX computes the alignment offset itself
      if Trimming <> 0 then
      begin
        pango_layout_set_ellipsize(T.Layout, PANGO_ELLIPSIZE_END);
        if WordWrap then
          pango_layout_set_height(T.Layout, Round(Min(Max(1, Height) * PANGO_SCALE, MaxInt)))
        else
          pango_layout_set_height(T.Layout, -1); // at most one line
      end;
      Attrs := pango_attr_list_new;
      try
        if Font.Underline then
          pango_attr_list_insert(Attrs, pango_attr_underline_new(PANGO_UNDERLINE_SINGLE));
        if Font.Strikeout then
          pango_attr_list_insert(Attrs, pango_attr_strikethrough_new(1));
        pango_layout_set_attributes(T.Layout, Attrs);
      finally
        pango_attr_list_unref(Attrs);
      end;
      Result := T;
    except
      T.Free;
      raise;
    end;
  finally
    cairo_destroy(Cr);
    cairo_surface_destroy(Surface);
  end;
end;

procedure DestroyText(Layout: Pointer); cdecl;
begin
  TCairoText(Layout).Free;
end;

procedure DrawText(Context, Layout: Pointer; X, Y: Single); cdecl;
begin
  if (Layout = nil) or C(Context).Degenerate then
    Exit;
  cairo_move_to(C(Context).Cr, X, Y);
  pango_cairo_show_layout(C(Context).Cr, TCairoText(Layout).Layout);
  cairo_new_path(C(Context).Cr);
end;

procedure GetTextRect(Layout: Pointer; var R: TRectF); cdecl;
var
  Logical: TPangoRectangle;
begin
  R := TRectF.Empty;
  if Layout = nil then
    Exit;
  pango_layout_get_extents(TCairoText(Layout).Layout, nil, @Logical);
  R := RectF(Logical.X / PANGO_SCALE, Logical.Y / PANGO_SCALE, (Logical.X + Logical.Width) / PANGO_SCALE,
    (Logical.Y + Logical.Height) / PANGO_SCALE);
end;

function PositionAtPoint(Layout: Pointer; Point: PPointF): Integer; cdecl;
var
  Index, Trailing: Integer;
begin
  Result := 0;
  if (Layout = nil) or (Point = nil) then
    Exit;
  pango_layout_xy_to_index(TCairoText(Layout).Layout, Round(Point.X * PANGO_SCALE), Round(Point.Y * PANGO_SCALE),
    @Index, @Trailing);
  Result := TCairoText(Layout).CharIndex(Index, Trailing);
end;

function MeasureRange(Layout: Pointer; Pos, Count: Integer; Region: PRectF): Integer; cdecl;
var
  I: Integer;
  R: TPangoRectangle;
  T: TCairoText;
begin
  Result := 0;
  if (Layout = nil) or (Region = nil) or (Pos < 0) then
    Exit;
  T := TCairoText(Layout);
  Count := Max(0, Min(Count, System.Length(T.Text) - Pos));
  for I := 0 to Count - 1 do
  begin
    pango_layout_index_to_pos(T.Layout, T.ByteIndex(Pos + I), @R);
    Region^ := RectF(Min(R.X, R.X + R.Width) / PANGO_SCALE, R.Y / PANGO_SCALE,
      Max(R.X, R.X + R.Width) / PANGO_SCALE, (R.Y + R.Height) / PANGO_SCALE);
    Inc(Region);
  end;
  Result := Count;
end;

function TextToPath(Layout: Pointer; Pts: PFmuxPathPoint; Count: Integer): Integer; cdecl;
var
  Surface, Cr: Pointer;
  PathData: PCairoPath;
  Item, Point: PCairoPathData;
  I, J, N: Integer;
  Kind: TFmuxPathPointKind;
begin
  Result := 0;
  if Layout = nil then
    Exit;
  Surface := cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
  Cr := cairo_create(Surface);
  PathData := nil;
  try
    pango_cairo_layout_path(Cr, TCairoText(Layout).Layout);
    PathData := cairo_copy_path(Cr);
    I := 0;
    while I < PathData.Count do
    begin
      Item := PCairoPathData(PByte(PathData.Data) + I * SizeOf(TCairoPathData));
      case Item.Kind of
        CAIRO_PATH_MOVE_TO:
          Kind := TFmuxPathPointKind.MoveTo;
        CAIRO_PATH_LINE_TO:
          Kind := TFmuxPathPointKind.LineTo;
        CAIRO_PATH_CURVE_TO:
          Kind := TFmuxPathPointKind.CurveTo;
      else
        Kind := TFmuxPathPointKind.Close;
      end;
      N := Max(1, Item.Length - 1);
      for J := 0 to N - 1 do
      begin
        if (Pts <> nil) and (Result < Count) then
        begin
          Pts.Kind := Kind;
          Pts.Point := PointF(0, 0);
          if Item.Kind <> CAIRO_PATH_CLOSE_PATH then
          begin
            Point := PCairoPathData(PByte(Item) + (J + 1) * SizeOf(TCairoPathData));
            Pts.Point := PointF(Point.X, Point.Y);
          end;
          Inc(Pts);
        end;
        Inc(Result);
      end;
      Inc(I, Item.Length);
    end;
  finally
    if PathData <> nil then
      cairo_path_destroy(PathData);
    cairo_destroy(Cr);
    cairo_surface_destroy(Surface);
  end;
end;

function BitmapLoad(ReadFunc: TFmuxReadFunc; Param: Pointer; var W, H: Integer; var Bits: Pointer): Pointer; cdecl;
var
  Loader, Pixbuf, Err: Pointer;
  Buffer: array[0..65535] of Byte;
  N, Remaining, X, Y, Stride, Channels: Integer;
  B: PFmuxBitmap;
  Src: PByte;
  Dst: PCardinal;
  A, R, G, Blue: Cardinal;
  Closed: Boolean;
begin
  LoadGraphicsLibraries;
  Result := nil;
  Bits := nil;
  W := 0;
  H := 0;
  Loader := gdk_pixbuf_loader_new;
  B := nil;
  Err := nil;
  Closed := False;
  try
    // FMUX callbacks return zero on success; a nil buffer queries the stream size.
    Remaining := ReadFunc(Param, nil, 0);
    while Remaining > 0 do
    begin
      N := Min(Remaining, SizeOf(Buffer));
      if ReadFunc(Param, @Buffer[0], N) <> 0 then
        Exit;
      if gdk_pixbuf_loader_write(Loader, @Buffer[0], N, @Err) = 0 then
        Exit;
      Dec(Remaining, N);
    end;
    Closed := True;
    if gdk_pixbuf_loader_close(Loader, @Err) = 0 then
      Exit;
    Pixbuf := gdk_pixbuf_loader_get_pixbuf(Loader);
    if Pixbuf = nil then
      Exit;
    W := gdk_pixbuf_get_width(Pixbuf);
    H := gdk_pixbuf_get_height(Pixbuf);
    B := FmuxBitmapCreate(W, H, nil);
    Stride := gdk_pixbuf_get_rowstride(Pixbuf);
    Channels := gdk_pixbuf_get_n_channels(Pixbuf);
    for Y := 0 to H - 1 do
    begin
      Src := gdk_pixbuf_get_pixels(Pixbuf) + NativeInt(Y) * Stride;
      Dst := PCardinal(PByte(B.Data) + NativeInt(Y) * W * 4);
      for X := 0 to W - 1 do
      begin
        A := 255;
        if Channels = 4 then
          A := PByte(Src + 3)^;
        R := (Src^ * A + 127) div 255;
        G := (PByte(Src + 1)^ * A + 127) div 255;
        Blue := (PByte(Src + 2)^ * A + 127) div 255;
        Dst^ := (A shl 24) or (R shl 16) or (G shl 8) or Blue;
        Inc(Src, Channels);
        Inc(Dst);
      end;
    end;
    Bits := B.Data;
    Result := B;
  finally
    if not Closed then
      gdk_pixbuf_loader_close(Loader, nil);
    if (Result = nil) and (B <> nil) then
      FmuxBitmapDestroy(B);
    if Err <> nil then
      g_error_free(Err);
    g_object_unref(Loader);
  end;
end;

function BitmapSave(WriteFunc: TFmuxReadFunc; Param: Pointer; W, H: Integer; Bits: Pointer;
  Extension: PChar): Boolean; cdecl;
var
  Pixbuf, Buffer, Err: Pointer;
  Size, Offset: NativeUInt;
  X, Y, Stride, Chunk: Integer;
  Src: PCardinal;
  Dst: PByte;
  Color, A: Cardinal;
  FormatName: UTF8String;
begin
  LoadGraphicsLibraries;
  Result := False;
  if (Bits = nil) or (W <= 0) or (H <= 0) then
    Exit;
  FormatName := UTF8String(LowerCase(string(Extension)).TrimLeft(['.']));
  if FormatName = 'jpg' then
    FormatName := 'jpeg';
  Pixbuf := gdk_pixbuf_new(GDK_COLORSPACE_RGB, 1, 8, W, H);
  if Pixbuf = nil then
    Exit;
  Buffer := nil;
  Err := nil;
  try
    Stride := gdk_pixbuf_get_rowstride(Pixbuf);
    for Y := 0 to H - 1 do
    begin
      Src := PCardinal(PByte(Bits) + NativeInt(Y) * W * 4);
      Dst := gdk_pixbuf_get_pixels(Pixbuf) + NativeInt(Y) * Stride;
      for X := 0 to W - 1 do
      begin
        Color := Src^;
        A := Color shr 24;
        if A = 0 then
        begin
          Dst^ := 0;
          PByte(Dst + 1)^ := 0;
          PByte(Dst + 2)^ := 0;
        end
        else
        begin
          Dst^ := Min(255, (((Color shr 16) and 255) * 255 + A div 2) div A);
          PByte(Dst + 1)^ := Min(255, (((Color shr 8) and 255) * 255 + A div 2) div A);
          PByte(Dst + 2)^ := Min(255, ((Color and 255) * 255 + A div 2) div A);
        end;
        PByte(Dst + 3)^ := A;
        Inc(Src);
        Inc(Dst, 4);
      end;
    end;
    if gdk_pixbuf_save_to_bufferv(Pixbuf, @Buffer, @Size, PAnsiChar(FormatName), nil, nil, @Err) = 0 then
      Exit;
    Offset := 0;
    while Offset < Size do
    begin
      Chunk := Min(NativeUInt(65536), Size - Offset);
      if WriteFunc(Param, PByte(Buffer) + Offset, Chunk) <> 0 then
        Exit;
      Inc(Offset, Chunk);
    end;
    Result := True;
  finally
    if Err <> nil then
      g_error_free(Err);
    if Buffer <> nil then
      g_free(Buffer);
    g_object_unref(Pixbuf);
  end;
end;

function GetFontCount: Integer; cdecl;
var
  Families: Pointer;
  Family: PPointer;
  I, Count: Integer;
begin
  LoadGraphicsLibraries;
  pango_font_map_list_families(pango_cairo_font_map_get_default, @Families, @Count);
  try
    SetLength(GFontNames, Count);
    Family := Families;
    for I := 0 to Count - 1 do
    begin
      GFontNames[I] := string(UTF8String(pango_font_family_get_name(Family^)));
      Inc(Family);
    end;
    Result := Count;
  finally
    g_free(Families);
  end;
end;

function GetFontName(Index: Integer): PChar; cdecl;
begin
  Result := nil;
  if (Index >= 0) and (Index < Length(GFontNames)) then
    Result := PChar(GFontNames[Index]);
end;

procedure AssignCairoApi;
begin
  FMUX.Api.FmuxCreateContext := CreateContext;
  FMUX.Api.FmuxDestroyContext := DestroyCairoFrame;
  FMUX.Api.FmuxSave := Save;
  FMUX.Api.FmuxRestore := Restore;
  FMUX.Api.FmuxSetClipRects := SetClipRects;
  FMUX.Api.FmuxIntersectClipRect := IntersectClip;
  FMUX.Api.FmuxExcludeClipRect := ExcludeClip;
  FMUX.Api.FmuxCanvasSetMatrix := SetMatrix;
  FMUX.Api.FmuxCanvasSetQuality := SetQuality;
  FMUX.Api.FmuxCanvasClear := Clear;
  FMUX.Api.FmuxCanvasClearRect := ClearRect;
  FMUX.Api.FmuxCanvasSetFillColor := SetColor;
  FMUX.Api.FmuxCanvasSetFillGradient := SetGradient;
  FMUX.Api.FmuxCanvasSetFillRadialGradient := SetRadialGradient;
  FMUX.Api.FmuxCanvasSetFillBitmap := SetBitmap;
  FMUX.Api.FmuxCanvasRect := RectPath;
  FMUX.Api.FmuxCanvasEllipse := EllipsePath;
  FMUX.Api.FmuxCanvasLine := LinePath;
  FMUX.Api.FmuxCanvasPath := Path;
  FMUX.Api.FmuxCanvasFill := Fill;
  FMUX.Api.FmuxCanvasStroke := Stroke;
  FMUX.Api.FmuxCanvasPtInPath := PtInPath;
  FMUX.Api.FmuxCanvasSetStrokeWidth := SetStrokeWidth;
  FMUX.Api.FmuxCanvasSetStrokeCap := SetStrokeCap;
  FMUX.Api.FmuxCanvasSetStrokeJoin := SetStrokeJoin;
  FMUX.Api.FmuxCanvasSetStrokeDash := SetStrokeDash;
  FMUX.Api.FmuxCreateTextLayout := CreateText;
  FMUX.Api.FmuxDestroyTextLayout := DestroyText;
  FMUX.Api.FmuxDrawTextLayout := DrawText;
  FMUX.Api.FmuxGetTextLayoutRect := GetTextRect;
  FMUX.Api.FmuxLayoutPositionAtPoint := PositionAtPoint;
  FMUX.Api.FmuxLayoutMeasureRange := MeasureRange;
  FMUX.Api.FmuxLayoutToPath := TextToPath;
  FMUX.Api.FmuxBitmapLoad := BitmapLoad;
  FMUX.Api.FmuxBitmapSave := BitmapSave;
  FMUX.Api.FmuxGetFontCount := GetFontCount; // partial: the system's font families
  FMUX.Api.FmuxGetFontName := GetFontName; // partial: names of FmuxGetFontCount (custom fonts: not yet)
end;

end.
