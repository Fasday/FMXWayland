program Hello;

{ FMXWayland sample: an FMX form with shapes, text, a button, an edit box, a combo box (popup), a check box, mouse
  coordinates, a timer animation, a second form, a modal form, the clipboard and file dialogs.

  Canvas: FMX's Skia raster canvas (libsk4d.so next to the program); with the define NOSKIA FMX's default Linux
  canvas, cairo and Pango (no libsk4d.so); with the define FASTCANVAS FastCanvas on Vulkan, presenting to the windows'
  wl_surfaces itself (HelloFastCanvas.pas; FastCanvas's src\Canvas and third_party\pasvulkan\src on the search path:
  tools\build.ps1 -SearchPath; no libsk4d.so).

  Command line:
    --quit-after=N    closes the main form after N seconds (tests: clean exit)
    --verbose         writes the events it gets to stdout
    --selftest        runs the self-test steps (tests\weston-headless.ps1)
    --dialog-dir=DIR  the folder the file dialogs of the buttons start in (default: HOME)
    --quit-in-folder-dialog=N  closes the main form when the folder dialog has been open N seconds (tests)
    --early-popup[=paint|create]
                      opens the combo box drop-down before the window's first configure (a timer of 1 ms), while it
                      paints its first frame, or in FormCreate before it is shown (tests: popups of unmapped parents)
    --own-titlebar    instead of the main form, a form that draws its own title bar through FMXWayland's
                      IFMXWaylandWindowFrame service (HelloTitleBar.pas; with --selftest its own steps;
                      --size=WxH its Width and Height, 720x460 by default; --size-after=WxH set again once the
                      frame is attached, before the show) }

uses
  System.StartUpCopy,
  FMX.Forms,
  FMX.Types,
{$IF Defined(FASTCANVAS)}
  HelloFastCanvas in 'HelloFastCanvas.pas',
{$ELSEIF not Defined(NOSKIA)}
  FMX.Skia,
{$ENDIF}
  HelloMain in 'HelloMain.pas' {HelloForm},
  HelloTitleBar in 'HelloTitleBar.pas';

var
  TitleBarForm: TTitleBarForm;
{$IFDEF FASTCANVAS}
  Reason: string;
{$ENDIF}

begin
{$IF Defined(FASTCANVAS)}
  // FastCanvas on Vulkan; FMX's own canvas when there is no Vulkan device it can use.
  if InstallHelloFastCanvas(Reason) then
  begin
    HelloCanvasInfo := HelloFastCanvasInfo;
    HelloSaveFrame :=
      function(AForm: TCommonCustomForm; AFileName: string): string
      begin
        Result := SaveHelloFastCanvasFrame(AForm, AFileName);
      end;
    HelloPresentation := 'Vulkan, VK_KHR_wayland_surface';
  end
  else
    HelloCanvasInfo :=
      function: string
      begin
        Result := 'FastCanvas not installed: ' + Reason;
      end;
{$ELSEIF not Defined(NOSKIA)}
  GlobalUseSkia := True;
{$ENDIF}
  Application.Initialize;
  if OwnTitleBarRequested then
    Application.CreateForm(TTitleBarForm, TitleBarForm)
  else
    Application.CreateForm(THelloForm, HelloForm);
  Application.Run;
end.
