program Hello;

{ FMXWayland sample: an FMX form with shapes, text, a button, an edit box, a combo box (popup), a check box, mouse
  coordinates, a timer animation, a second form, a modal form and the clipboard.

  Command line:
    --quit-after=N   closes the main form after N seconds (tests: clean exit)
    --verbose        writes the events it gets to stdout }

uses
  System.StartUpCopy,
  FMX.Forms,
  FMX.Types,
  FMX.Skia,
  HelloMain in 'HelloMain.pas' {HelloForm};

begin
  // FMXWayland draws with FMX's Skia raster canvas (FMX's cairo canvas needs libfmux).
  GlobalUseSkia := True;
  Application.Initialize;
  Application.CreateForm(THelloForm, HelloForm);
  Application.Run;
end.
