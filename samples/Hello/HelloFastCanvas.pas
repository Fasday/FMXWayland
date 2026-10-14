unit HelloFastCanvas;

{ Hello with FastCanvas (the define FASTCANVAS; tools\build.ps1 -Define FASTCANVAS -SearchPath
  <FastCanvas>\src\Canvas,<FastCanvas>\third_party\pasvulkan\src): FMX's canvas is FastCanvas on Vulkan. Its windows
  present to their wl_surfaces through VK_KHR_wayland_surface (FastCanvas finds them through FMXWayland's
  IFMXWaylandNativeWindow, declared there again: neither project depends on the other), its popups go through
  FMXWayland's frames; text by Pango, geometry its own: no Skia, no GTK, no X11. Only this unit names FastCanvas. }

interface

uses
  FMX.Forms;

/// <summary>Installs FastCanvas on Vulkan and its 3D context (before Application.Initialize). False, with the reason,
/// when there is no Vulkan device it can use: FMX's own canvas draws then.</summary>
function InstallHelloFastCanvas(out AReason: string): Boolean;
/// <summary>A line about FastCanvas for the log: the device, its Vulkan version, the surface extensions.</summary>
function HelloFastCanvasInfo: string;
/// <summary>The frame FastCanvas presented last in the form's window, as a top-down 32-bit BMP at AFileName (the
/// frame dump the tests look at: FMXWayland has no pixels of a window that a canvas presents itself); a line for the
/// log.</summary>
function SaveHelloFastCanvasFrame(const AForm: TCommonCustomForm; const AFileName: string): string;

implementation

uses
  System.SysUtils, System.Classes, System.Math, FastCanvas.Device, FastCanvas.DeviceVk, FastCanvas.Canvas,
  FastCanvas.Context3DVk;

function InstallHelloFastCanvas(out AReason: string): Boolean;
begin
  AReason := '';
  FastCanvasBackend := TFastCanvasBackend.Vulkan;
  try
    // EFastDevice with what each device lacks when there is none.
    TFastDevice.Ensure;
    InstallFastCanvas;
    if TFastContext3DVk.Valid then
      InstallFastContext3DVk;
    Result := True;
  except
    on E: Exception do
    begin
      AReason := E.Message;
      Result := False;
    end;
  end;
end;

function HelloFastCanvasInfo: string;
var
  V: TFastVulkan;
  Surfaces: string;
begin
  V := TFastDevice.Vulkan;
  if V = nil then
    Exit('no Vulkan device');
  Surfaces := '';
  if V.WaylandSurfaces then
    Surfaces := Surfaces + ' VK_KHR_wayland_surface';
  if V.XlibSurfaces then
    Surfaces := Surfaces + ' VK_KHR_xlib_surface';
  Result := Format('Vulkan device "%s", Vulkan %s, surfaces%s, 3D context %s', [V.DeviceName,
    FastVulkanVersionText(V.ApiVersion), Surfaces, BoolToStr(TFastContext3DVk.Valid, True)]);
end;

function SaveHelloFastCanvasFrame(const AForm: TCommonCustomForm; const AFileName: string): string;
var
  C: TFastWindowCapture;
  Header: packed record
    Magic: Word;
    FileSize: Cardinal;
    Reserved: Cardinal;
    Offset: Cardinal;
    Size: Cardinal;
    Width: Integer;
    Height: Integer;
    Planes: Word;
    BitCount: Word;
    Compression: Cardinal;
    ImageSize: Cardinal;
    XPels: Integer;
    YPels: Integer;
    ClrUsed: Cardinal;
    ClrImportant: Cardinal;
  end;
  Row: TBytes;
  Dump: TFileStream;
  X, Y, I: Integer;
begin
  if not FastCanvasCaptureWindow(AForm, C) then
    Exit('no frame presented');
  FillChar(Header, SizeOf(Header), 0);
  Header.Magic := $4D42;
  Header.Offset := SizeOf(Header);
  Header.FileSize := SizeOf(Header) + Cardinal(C.Width * C.Height * 4);
  Header.Size := 40;
  Header.Width := C.Width;
  Header.Height := -C.Height;
  Header.Planes := 1;
  Header.BitCount := 32;
  Header.ImageSize := C.Width * C.Height * 4;
  SetLength(Row, C.Width * 4);
  Dump := TFileStream.Create(AFileName, fmCreate);
  try
    Dump.WriteBuffer(Header, SizeOf(Header));
    for Y := 0 to C.Height - 1 do
    begin
      for X := 0 to C.Width - 1 do
      begin
        // The capture is R, G, B, A in 0..1; a BMP row is B, G, R, A.
        I := (Y * C.Width + X) * 4;
        Row[X * 4] := EnsureRange(Round(C.Pixels[I + 2] * 255), 0, 255);
        Row[X * 4 + 1] := EnsureRange(Round(C.Pixels[I + 1] * 255), 0, 255);
        Row[X * 4 + 2] := EnsureRange(Round(C.Pixels[I] * 255), 0, 255);
        Row[X * 4 + 3] := EnsureRange(Round(C.Pixels[I + 3] * 255), 0, 255);
      end;
      Dump.WriteBuffer(Row[0], Length(Row));
    end;
  finally
    Dump.Free;
  end;
  Result := Format('frame presented %dx%d saved', [C.Width, C.Height]);
end;

end.
