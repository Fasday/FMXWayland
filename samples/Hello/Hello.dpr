program Hello;

{ FMXWayland sample: an FMX form with shapes, text, a button, an edit box, a combo box (popup), a check box, mouse
  coordinates, a timer animation, a second form, a modal form and the clipboard.

  Canvas: FMX's Skia raster canvas (libsk4d.so next to the program); with the define NOSKIA FMX's default Linux
  canvas, cairo and Pango (no libsk4d.so).

  Command line:
    --quit-after=N   closes the main form after N seconds (tests: clean exit)
    --verbose        writes the events it gets to stdout
    --selftest       runs the self-test steps (tests\weston-headless.ps1)
    --early-popup[=paint|create]
                     opens the combo box drop-down before the window's first configure (a timer of 1 ms), while it
                     paints its first frame, or in FormCreate before it is shown (tests: popups of unmapped parents)
    --own-titlebar   instead of the main form, a form that draws its own title bar through FMXWayland's
                     IFMXWaylandWindowFrame service (HelloTitleBar.pas; with --selftest its own steps;
                     --size=WxH its Width and Height, 720x460 by default; --size-after=WxH set again once the
                     frame is attached, before the show) }

uses
  System.StartUpCopy,
  FMX.Forms,
  FMX.Types,
{$IFNDEF NOSKIA}
  FMX.Skia,
{$ENDIF}
  HelloMain in 'HelloMain.pas' {HelloForm},
  HelloTitleBar in 'HelloTitleBar.pas';

var
  TitleBarForm: TTitleBarForm;

begin
{$IFNDEF NOSKIA}
  GlobalUseSkia := True;
{$ENDIF}
  Application.Initialize;
  if OwnTitleBarRequested then
    Application.CreateForm(TTitleBarForm, TitleBarForm)
  else
    Application.CreateForm(THelloForm, HelloForm);
  Application.Run;
end.
