program CanvasCheck;

{ FMXWayland canvas check: one form that draws what FMX's canvases must agree on (gradients and opacity, dashes and
  caps, bitmap brushes, scaled and partial bitmaps, the PNG codec, text beyond the BMP, wrapping, alignment,
  trimming, styles, rotation, text as a path, a degenerate matrix), to compare the Skia raster canvas with FMX's
  cairo canvas (define NOSKIA). tests\canvas-check.ps1 builds and runs both and puts their frames side by side.

  Command line:
    --quit-after=N   closes the form after N seconds }

uses
  System.StartUpCopy,
  FMX.Forms,
  FMX.Types,
{$IFNDEF NOSKIA}
  FMX.Skia,
{$ENDIF}
  CanvasCheckMain in 'CanvasCheckMain.pas';

begin
{$IFNDEF NOSKIA}
  GlobalUseSkia := True;
{$ENDIF}
  Application.Initialize;
  Application.CreateForm(TCheckForm, CheckForm);
  Application.Run;
end.
