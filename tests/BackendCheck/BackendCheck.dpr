program BackendCheck;

// Cross-process clipboard, coordinate round-trips and early FMUX initialization probe.
uses
  System.StartUpCopy,
  FMX.Clipboard.Linux,
  FMX.Forms,
  FMUX.Api,
  System.SysUtils,
  System.Classes,
  System.Types,
  System.IOUtils,
  Posix.Dlfcn,
  Posix.Unistd,
  FMXWayland.Posix,
  FMXWayland.Xlib;

type
  TXCreateEvent = record
    Header: TXAnyEvent;
    Window: TXID;
    X, Y, Width, Height, Border, OverrideRedirect: Integer;
  end;
  PXCreateEvent = ^TXCreateEvent;

var
  Text: string;
  Deadline: UInt64;
  Started: UInt64;
  Info: TFmuxCreateStruct;
  Wnd, Display: Pointer;
  P, Origin: TPointF;
  I, X, Y: Integer;
  Child: TXID;
  Frame, InnerFrame: TXID;
  Xlib: NativeUInt;
  Reparent: function(D: Pointer; Window, Parent: TXID; X, Y: Integer): Integer; cdecl;
  Event: TXEvent;
  ExpectedOffset: TPointF;
  Popup: Pointer;
  Found: Boolean;
  SizeBefore, SizeAfter: TPointF;
  Width, Height, Border, Depth: Cardinal;
  DisplayInfo: TFmuxDisplayInfo;
  Victim, Replacement: Pointer;
  CallbackCount, Mode: Integer;
  GetImage: function(D: Pointer; Drawable: TXID; X, Y: Integer; W, H: Cardinal;
    Planes: NativeUInt; Format: Integer): PXImage; cdecl;
  GetPixel: function(Image: PXImage; X, Y: Integer): NativeUInt; cdecl;
  Image: PXImage;
  PipeFds: array[0..1] of Integer;
  ByteValue: Byte;

procedure ReplaceVictim;
var
  Next: TFmuxCreateStruct;
begin
  Inc(CallbackCount);
  FmuxDestroyWindow(Victim);
  Victim := nil;
  Next := Default(TFmuxCreateStruct);
  Next.X := 10;
  Next.Y := 10;
  Next.Width := 128;
  Next.Height := 96;
  Replacement := FmuxCreateWindow(Next);
  if Mode = 0 then
  begin
    P := FmuxGetMousePos(); // publish the new XID before the observer connection selects events on it
    XSelectInput(Display, TXID(FmuxGetWindowNativeHandle(Replacement)), 1 shl 17);
    XGetGeometry(Display, TXID(FmuxGetWindowNativeHandle(Replacement)), @Child, @X, @Y,
      @Width, @Height, @Border, @Depth);
    FmuxShowWindow(Replacement, True);
  end;
end;

procedure DestroyInPaint(Data, Ctx: Pointer; Rects: PRectFArray; Count: Integer); cdecl;
begin
  FmuxCanvasClear(Ctx, $FFFF0000);
  ReplaceVictim;
end;

procedure DestroyInBounds(Data: Pointer; Bounds: TRectF); cdecl;
begin
  ReplaceVictim;
end;

procedure DestroyInState(Data: Pointer; State: TFmuxWindowState); cdecl;
begin
  ReplaceVictim;
end;

begin
  if (SizeOf(TXEvent) <> 192) or (SizeOf(TXKeyEvent) <> 96) or (SizeOf(TXImage) <> 136) then
    raise Exception.Create('Xlib LP64 ABI mismatch');
  if ParamStr(1) = 'write' then
  begin
    Text := TFile.ReadAllText(ParamStr(2), TEncoding.UTF8);
    FmuxClipboardSetText(PChar(Text));
    Writeln('ready');
    Flush(Output);
    Deadline := TThread.GetTickCount64 + 10000;
    while TThread.GetTickCount64 < Deadline do
    begin
      FmuxHandleMessage();
      TThread.Sleep(1);
    end;
  end
  else if ParamStr(1) = 'read' then
  begin
    Text := string(FmuxClipboardGetText());
    TFile.WriteAllText(ParamStr(2), Text, TEncoding.UTF8);
  end
  else if ParamStr(1) = 'signal' then
  begin
    SizeAfter := FmuxGetScreenSize();
    if pipe2(@PipeFds[0], O_CLOEXEC) <> 0 then raise Exception.Create('pipe2 failed');
    __close(PipeFds[0]);
    try
      ByteValue := 1;
      if WriteAll(PipeFds[1], @ByteValue, 1) then raise Exception.Create('Closed pipe unexpectedly accepted data');
    finally
      __close(PipeFds[1]);
    end;
    Writeln('Closed peer produces an I/O failure, not process termination: PASS');
  end
  else if ParamStr(1) = 'lifetime' then
  begin
    Xlib := dlopen('libX11.so.6', RTLD_NOW);
    GetImage := dlsym(Xlib, 'XGetImage');
    GetPixel := dlsym(Xlib, 'XGetPixel');
    Display := XOpenDisplay(nil);
    try
      for Mode := 0 to 2 do
        for I := 1 to 25 do
        begin
          Info := Default(TFmuxCreateStruct);
          Info.Width := 64;
          Info.Height := 48;
          case Mode of
            0: Info.PaintCallback := DestroyInPaint;
            1: Info.BoundsChanged := DestroyInBounds;
            2: Info.StateChanged := DestroyInState;
          end;
          CallbackCount := 0;
          Victim := FmuxCreateWindow(Info);
          Replacement := nil;
          try
            case Mode of
              0: begin FmuxShowWindow(Victim, True); FmuxProcessUpdates(Victim) end;
              1: FmuxSetWindowRect(Victim, RectF(20, 20, 160, 120));
              2: FmuxSetWindowState(Victim, TFmuxWindowState(2));
            end;
            if (CallbackCount <> 1) or (Victim <> nil) or (Replacement = nil) then
              raise Exception.Create('Destroy/recreate callback was not completed');
            FmuxGetClientSize(Replacement, P);
            if P <> PointF(128, 96) then raise Exception.Create('Destroyed window modified its replacement');
            if Mode = 0 then
            begin
              Found := False;
              Deadline := TThread.GetTickCount64 + 2000;
              repeat
                FmuxHandleMessage();
                while XPending(Display) > 0 do
                begin
                  XNextEvent(Display, @Event);
                  if (Event.Any.Kind = 19) and
                    (Event.Any.Window = TXID(FmuxGetWindowNativeHandle(Replacement))) then Found := True;
                end;
                if Found then Break;
                TThread.Sleep(1);
              until TThread.GetTickCount64 >= Deadline;
              if not Found then raise Exception.Create('Replacement window did not map');
              P := FmuxGetMousePos(); // same-connection round-trip: the replacement has been mapped
              Image := GetImage(Display, TXID(FmuxGetWindowNativeHandle(Replacement)), 0, 0, 1, 1, High(NativeUInt), 2);
              if Image = nil then raise Exception.Create('Cannot read replacement drawable');
              try
                if GetPixel(Image, 0, 0) and $FFFFFF <> 0 then
                  raise Exception.Create('Old paint callback uploaded pixels into the replacement window');
              finally
                XDestroyImage(Image);
              end;
            end;
          finally
            if Victim <> nil then FmuxDestroyWindow(Victim);
            if Replacement <> nil then FmuxDestroyWindow(Replacement);
          end;
          FmuxHandleMessage();
        end;
      Info := Default(TFmuxCreateStruct);
      Info.Width := 160;
      Info.Height := 100;
      Victim := FmuxCreateWindow(Info);
      FmuxSetMainWindow(Victim);
      Info.Popup := True;
      Popup := FmuxCreateWindow(Info);
      try
        FmuxShowWindow(Popup, True);
        P := FmuxGetMousePos();
        FmuxDestroyWindow(Victim);
        Victim := nil;
        P := FmuxGetMousePos();
        if XGrabPointer(Display, XRootWindow(Display, XDefaultScreen(Display)), 0, 1 shl 6,
          1, 1, 0, 0, 0) <> 0 then raise Exception.Create('Destroyed owner left an orphaned popup grab');
        XUngrabPointer(Display, 0);
      finally
        if Victim <> nil then FmuxDestroyWindow(Victim);
        FmuxDestroyWindow(Popup);
      end;
      Writeln('Window destruction/recreation in callbacks and owner/popup grab cleanup: PASS');
    finally
      XCloseDisplay(Display);
      dlclose(Xlib);
    end;
  end
  else if ParamStr(1) = 'screen-watch' then
  begin
    SizeBefore := FmuxGetScreenSize();
    Writeln('ready');
    Flush(Output);
    Deadline := TThread.GetTickCount64 + 5000;
    repeat
      FmuxHandleMessage();
      SizeAfter := FmuxGetScreenSize();
      if SizeAfter <> SizeBefore then Break;
      TThread.Sleep(5);
    until TThread.GetTickCount64 >= Deadline;
    if SizeAfter = SizeBefore then raise Exception.Create('Screen size did not update after root resize');
    Display := XOpenDisplay(nil);
    try
      XGetGeometry(Display, XRootWindow(Display, XDefaultScreen(Display)), @Child, @X, @Y,
        @Width, @Height, @Border, @Depth);
      FmuxGetDisplayInfo(@DisplayInfo, 0);
      if (SizeAfter <> PointF(Width, Height)) or (DisplayInfo.WorkareaRect.Width <> Integer(Width)) or
        (DisplayInfo.WorkareaRect.Height <> Integer(Height)) then
        raise Exception.Create('Screen/work area disagree with live root geometry');
      Writeln('screen changed ', Width, 'x', Height);
    finally
      XCloseDisplay(Display);
    end;
  end
  else if ParamStr(1) = 'coordinates' then
  begin
    if IsWayland() then raise Exception.Create('Coordinate probe requires FMXWAYLAND_BACKEND=x11');
    Info := Default(TFmuxCreateStruct);
    Info.X := 80;
    Info.Y := 90;
    Info.Width := 120;
    Info.Height := 100;
    Wnd := FmuxCreateWindow(Info);
    Display := XOpenDisplay(nil);
    Frame := 0;
    InnerFrame := 0;
    Xlib := dlopen('libX11.so.6', RTLD_NOW);
    Reparent := dlsym(Xlib, 'XReparentWindow');
    ExpectedOffset := PointF(0, 0);
    try
      // Also simulate a WM moving its frames without sending ConfigureNotify to the client (WSLg).
      for I := 0 to 7 do
      begin
        if I = 1 then
          FmuxSetWindowRect(Wnd, RectF(200, 150, 320, 250));
        if I = 2 then
        begin
          Frame := XCreateSimpleWindow(Display, XRootWindow(Display, XDefaultScreen(Display)),
            300, 200, 240, 200, 0, 0, 0);
          InnerFrame := XCreateSimpleWindow(Display, Frame, 20, 30, 200, 150, 0, 0, 0);
          Reparent(Display, TXID(FmuxGetWindowNativeHandle(Wnd)), InnerFrame, 7, 9);
        end;
        if I = 3 then XMoveResizeWindow(Display, Frame, 500, 350, 240, 200);
        if I = 4 then XMoveResizeWindow(Display, InnerFrame, 40, 60, 180, 120);
        if I = 5 then
        begin
          // XWayland's compositor can send a screen position different from the virtual X window tree.
          XTranslateCoordinates(Display, TXID(FmuxGetWindowNativeHandle(Wnd)),
            XRootWindow(Display, XDefaultScreen(Display)), 0, 0, @X, @Y, @Child);
          ExpectedOffset := PointF(900 - X, 600 - Y);
          Event := Default(TXEvent);
          Event.Configure.Header.Kind := 22;
          Event.Configure.Header.Display := Display;
          Event.Configure.Header.Window := TXID(FmuxGetWindowNativeHandle(Wnd));
          Event.Configure.Window := Event.Configure.Header.Window;
          Event.Configure.X := 900;
          Event.Configure.Y := 600;
          Event.Configure.Width := 120;
          Event.Configure.Height := 100;
          XSendEvent(Display, Event.Configure.Window, 0, 1 shl 17, @Event);
        end;
        if I = 6 then
        begin
          // A newer native move supersedes an earlier synthetic position; never retain a stale delta.
          ExpectedOffset := PointF(0, 0);
          XMoveResizeWindow(Display, Frame, 700, 400, 240, 200);
        end;
        if I = 7 then
        begin
          // Pointer coordinates after that move must agree with the current root position.
          XTranslateCoordinates(Display, TXID(FmuxGetWindowNativeHandle(Wnd)),
            XRootWindow(Display, XDefaultScreen(Display)), 0, 0, @X, @Y, @Child);
          Event := Default(TXEvent);
          Event.Key.Header.Kind := 6;
          Event.Key.Header.Display := Display;
          Event.Key.Header.Window := TXID(FmuxGetWindowNativeHandle(Wnd));
          Event.Key.Root := XRootWindow(Display, XDefaultScreen(Display));
          Event.Key.X := 10;
          Event.Key.Y := 20;
          Event.Key.RootX := X + 10;
          Event.Key.RootY := Y + 20;
          Event.Key.SameScreen := 1;
          XSendEvent(Display, Event.Key.Header.Window, 0, 1 shl 6, @Event);
        end;
        XFlush(Display);
        // Let asynchronous configure events settle. A WM can adjust the requested position; compare with
        // the server's actual client origin rather than assuming that it accepted those coordinates.
        Deadline := TThread.GetTickCount64 + 100;
        repeat
          FmuxHandleMessage();
          TThread.Sleep(1);
        until TThread.GetTickCount64 >= Deadline;
        XTranslateCoordinates(Display, TXID(FmuxGetWindowNativeHandle(Wnd)),
          XRootWindow(Display, XDefaultScreen(Display)), 0, 0, @X, @Y, @Child);
        Origin := PointF(X, Y) + ExpectedOffset;
        FmuxHandleMessage(); // consume the ConfigureNotify produced before the reference connection's reply
        P := FmuxClientToScreen(Wnd, PointF(12.5, 24.25));
        if P <> Origin + PointF(12.5, 24.25) then
          raise Exception.CreateFmt('ClientToScreen origin mismatch: phase %d, server %d,%d, cached %.0f,%.0f',
            [I, X, Y, P.X - 12.5, P.Y - 24.25]);
        if FmuxScreenToClient(Wnd, P) <> PointF(12.5, 24.25) then
          raise Exception.Create('ScreenToClient round-trip mismatch');
      end;
      Started := TThread.GetTickCount64;
      for I := 1 to 10000 do
      begin
        P := FmuxClientToScreen(Wnd, PointF(12.5, 24.25));
        P := FmuxScreenToClient(Wnd, P);
      end;
      Writeln('10000 coordinate round-trips: ', TThread.GetTickCount64 - Started, ' ms');
      // Observe CreateNotify, not just the eventual window attributes. Weston caches override_redirect at
      // creation; setting it afterwards can give a popup a managed toplevel role and random placement.
      XSelectInput(Display, XRootWindow(Display, XDefaultScreen(Display)), 1 shl 19);
      XGetGeometry(Display, XRootWindow(Display, XDefaultScreen(Display)), @Child, @X, @Y,
        @Width, @Height, @Border, @Depth); // barrier: install the observer before creating the window
      Info.Popup := True;
      Popup := FmuxCreateWindow(Info);
      try
        Found := False;
        Deadline := TThread.GetTickCount64 + 2000;
        repeat
          FmuxHandleMessage();
          while XPending(Display) > 0 do
          begin
            XNextEvent(Display, @Event);
            if (Event.Any.Kind = 16) and
              (PXCreateEvent(@Event).Window = TXID(FmuxGetWindowNativeHandle(Popup))) then
            begin
              Found := True;
              if PXCreateEvent(@Event).OverrideRedirect <> 1 then
                raise Exception.Create('Popup was created as a managed toplevel');
            end;
          end;
          if Found then Break;
          TThread.Sleep(1);
        until TThread.GetTickCount64 >= Deadline;
        if not Found then raise Exception.Create('Popup CreateNotify was not observed');
        Writeln('Popup CreateNotify override_redirect: PASS');
      finally
        FmuxDestroyWindow(Popup);
      end;
    finally
      if Frame <> 0 then
        Reparent(Display, TXID(FmuxGetWindowNativeHandle(Wnd)),
          XRootWindow(Display, XDefaultScreen(Display)), 80, 90);
      XCloseDisplay(Display);
      dlclose(Xlib);
      FmuxDestroyWindow(Wnd);
    end;
  end
  else
    raise Exception.Create('Usage: BackendCheck read|write filename | coordinates | lifetime | signal | screen-watch');
end.
