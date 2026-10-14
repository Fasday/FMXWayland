program DialogCheck;

{ FMXWayland dialog check: FMXWayland's D-Bus client against a real session bus, and the dialog backend with a test
  backend that answers without showing anything (what TOpenDialog, TSaveDialog, SelectDirectory, TDialogService and
  the FMUX dialog functions hand it, what comes back). tests\dialog-check.ps1 builds and runs it on a private headless
  Weston with a private bus. FMX's default canvas (no Skia). }

uses
  System.StartUpCopy,
  FMX.Forms,
  FMX.Types,
  DialogCheckMain in 'DialogCheckMain.pas';

begin
  Application.Initialize;
  Application.CreateForm(TDialogCheckForm, DialogCheckForm);
  Application.Run;
end.
