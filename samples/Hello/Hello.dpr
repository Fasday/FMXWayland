program Hello;

{ FMXWayland sample: an FMX form with shapes, text, a button, an edit box, a combo box (popup), a check box, mouse
  coordinates, a timer animation, a second form, a modal form and the clipboard.

  Canvas: FMX's Skia raster canvas (libsk4d.so next to the program); with the define NOSKIA FMX's default Linux
  canvas, cairo and Pango (no libsk4d.so).

  Command line:
    --quit-after=N   closes the main form after N seconds (tests: clean exit)
    --verbose        writes the events it gets to stdout
    --selftest       runs the self-test steps (tests\weston-headless.ps1) }

uses
  System.StartUpCopy,
  FMX.Forms,
  FMX.Types,
{$IFNDEF NOSKIA}
  FMX.Skia,
{$ENDIF}
  HelloMain in 'HelloMain.pas' {HelloForm};

begin
{$IFNDEF NOSKIA}
  GlobalUseSkia := True;
{$ENDIF}
  Application.Initialize;
  Application.CreateForm(THelloForm, HelloForm);
  Application.Run;
end.
