{ FMXWayland: the xdg-desktop-portal FileChooser over the Pascal D-Bus client.
  Written by Hemul GM. Copyright (c) 2026 Fasday and contributors. MIT license, see LICENSE. }

/// <summary>File dialogs through the FileChooser of xdg-desktop-portal (org.freedesktop.portal.FileChooser):
/// OpenFile and SaveFile on a private session bus connection (FMXWayland.DBus).</summary>
/// <remarks>The request's handle path is computed from the connection's unique name and a handle_token before the
/// call, and the Response signal is subscribed to before it (a fast portal may answer before the method returns).
/// While the dialog is open the application's loop keeps running through the pump; every two seconds without an
/// answer the request object is checked (Introspect): a request closed by someone else, or a portal that went away,
/// ends the wait as a cancel.</remarks>
unit FMXWayland.Portal;

interface

uses
  System.SysUtils, FMXWayland.DialogTypes, FMXWayland.DBus;

type
  /// <summary>No portal, or none with a usable FileChooser, or it failed before showing a dialog: the caller falls
  /// back to another dialog.</summary>
  EPortalUnavailable = class(EDBusError);
  /// <summary>The FileChooser cannot do what was asked (folder selection before version 3).</summary>
  EPortalUnsupported = class(EPortalUnavailable);

/// <summary>Shows the portal's file dialog; True with the chosen Files, False when the user cancelled it (or the
/// portal ended it otherwise). ParentWindow: the window the dialog belongs to as the portal names windows
/// ('wayland:&lt;xdg-foreign handle&gt;'), or ''. Pump keeps the application's events going while the dialog is
/// open. Raises EPortalUnavailable when there is no usable portal (nothing was shown), EDBusCancelled when the pump
/// cancelled (the request is closed), EDBusError when the portal failed after it accepted the request.</summary>
function PortalFileDialog(const Request: TWaylandFileDialogRequest; const ParentWindow: string;
  out Files: TArray<string>; var FilterIndex: Integer; const Pump: TDBusPump): Boolean;
/// <summary>The version of the portal's FileChooser interface; raises EPortalUnavailable without one.</summary>
function PortalFileChooserVersion: Cardinal;

implementation

uses
  System.Math, System.IOUtils, FMXWayland.Log;

const
  PortalDestination = 'org.freedesktop.portal.Desktop';
  PortalPath = '/org/freedesktop/portal/desktop';
  FileChooserInterface = 'org.freedesktop.portal.FileChooser';
  RequestInterface = 'org.freedesktop.portal.Request';
  /// <summary>Milliseconds for the portal's method replies: the first call may start (D-Bus activate) it.</summary>
  CallTimeoutMs = 5000;
  /// <summary>Milliseconds without an answer after which the request object is checked.</summary>
  CheckIntervalMs = 2000;
  /// <summary>Response codes of org.freedesktop.portal.Request.Response.</summary>
  ResponseSuccess = 0;
  ResponseCancelled = 1;

function GetVersion(Bus: TDBusConnection): Cardinal;
var
  Intf, Prop: TDBusValue;
  Reply: TDBusMessage;
begin
  Intf := TDBusValue.Str(FileChooserInterface);
  Prop := TDBusValue.Str('version');
  try
    Reply := Bus.Call(PortalDestination, PortalPath, 'org.freedesktop.DBus.Properties', 'Get', [Intf, Prop],
      CallTimeoutMs);
    try
      if (Reply.Body.Count <> 1) or (Reply.Body[0].Children.Count <> 1) or
        (Reply.Body[0].Children[0].Signature <> 'u') then
        raise EDBusError.Create('Invalid FileChooser version response');
      Result := Reply.Body[0].Children[0].Number;
    finally
      Reply.Free;
    end;
  finally
    Intf.Free;
    Prop.Free;
  end;
end;

function PortalFileChooserVersion: Cardinal;
var
  Bus: TDBusConnection;
begin
  try
    Bus := TDBusConnection.Create;
    try
      Result := GetVersion(Bus);
    finally
      Bus.Free;
    end;
  except
    on E: EDBusError do
      raise EPortalUnavailable.CreateRemote(E.RemoteName, E.Message);
  end;
end;

function SerializeFilter(const Filter: TWaylandFileFilter): TDBusValue;
var
  Patterns, Pattern: TDBusValue;
  Mask: string;
begin
  // (sa(us)): the name and its (kind, pattern) pairs; kind 0 is a glob pattern, 1 a MIME type.
  Result := TDBusValue.Create('(sa(us))');
  Result.Children.Add(TDBusValue.Str(Filter.Name));
  Patterns := TDBusValue.Create('a(us)');
  Result.Children.Add(Patterns);
  for Mask in Filter.Patterns do
  begin
    if Mask.Trim = '' then
      Continue;
    Pattern := TDBusValue.Create('(us)');
    Pattern.Children.Add(TDBusValue.UInt(0));
    if Mask.Trim = '*.*' then
      Pattern.Children.Add(TDBusValue.Str('*'))
    else
      Pattern.Children.Add(TDBusValue.Str(Mask.Trim));
    Patterns.Children.Add(Pattern);
  end;
end;

function FilterMatches(Value: TDBusValue; const Filter: TWaylandFileFilter): Boolean;
var
  Expected: TDBusValue;
  I: Integer;
begin
  Expected := SerializeFilter(Filter);
  try
    Result := (Value <> nil) and (Value.Signature = '(sa(us))') and (Value.Children.Count = 2) and
      (Value.Children[0].Text = Expected.Children[0].Text) and
      (Value.Children[1].Children.Count = Expected.Children[1].Children.Count);
    if not Result then
      Exit;
    for I := 0 to Expected.Children[1].Children.Count - 1 do
      if (Value.Children[1].Children[I].Children.Count <> 2) or
        (Value.Children[1].Children[I].Children[0].Number <> 0) or
        (Value.Children[1].Children[I].Children[1].Text <> Expected.Children[1].Children[I].Children[1].Text) then
        Exit(False);
  finally
    Expected.Free;
  end;
end;

/// The local path of a file:// URI (percent escapes decoded as UTF-8).
function DecodeFileUri(const Uri: string): string;
var
  Path, Authority: string;
  Input, Output: TBytes;
  I, N, Count, Slash: Integer;
begin
  if not Uri.StartsWith('file://') then
    raise EDBusError.Create('FileChooser returned a non-file URI: ' + Uri);
  Path := Copy(Uri, 8, MaxInt);
  if not Path.StartsWith('/') then
  begin
    Slash := Path.IndexOf('/');
    if Slash < 0 then
      raise EDBusError.Create('Invalid file URI: ' + Uri);
    Authority := Copy(Path, 1, Slash);
    if not SameText(Authority, 'localhost') then
      raise EDBusError.Create('Remote file URI is not a local path: ' + Uri);
    Path := Copy(Path, Slash + 1, MaxInt);
  end;
  Input := TEncoding.UTF8.GetBytes(Path);
  SetLength(Output, Length(Input));
  I := 0;
  Count := 0;
  while I < Length(Input) do
  begin
    if Input[I] = Ord('%') then
    begin
      if I + 2 >= Length(Input) then
        raise EDBusError.Create('Invalid file URI escape: ' + Uri);
      N := StrToIntDef('$' + Char(Input[I + 1]) + Char(Input[I + 2]), -1);
      if (N <= 0) or (N > 255) then
        raise EDBusError.Create('Invalid file URI escape: ' + Uri);
      Output[Count] := N;
      Inc(I, 3);
    end
    else
    begin
      if Input[I] in [0, 10, 13, Ord('?'), Ord('#')] then
        raise EDBusError.Create('Invalid file URI: ' + Uri);
      Output[Count] := Input[I];
      Inc(I);
    end;
    Inc(Count);
  end;
  Result := TEncoding.UTF8.GetString(Output, 0, Count);
  if Result.Contains(#10) or Result.Contains(#13) then
    raise EDBusError.Create('FMX file lists cannot represent filenames containing line breaks');
end;

/// A path as the portal's byte strings (ay, NUL-terminated).
function PathBytes(const Path: string): TBytes;
begin
  Result := TEncoding.UTF8.GetBytes(Path + #0);
end;

/// The object path of the request a call with HandleToken makes: /org/freedesktop/portal/desktop/request/SENDER/TOKEN
/// with SENDER the caller's unique name without its ':' and with '_' for '.'.
function RequestPath(const UniqueName, HandleToken: string): string;
begin
  Result := PortalPath + '/request/' + UniqueName.Substring(1).Replace('.', '_') + '/' + HandleToken;
end;

function ResponseMatch(const Path: string): string;
begin
  Result := Format('type=''signal'',sender=''%s'',path=''%s'',interface=''%s'',member=''Response''',
    [PortalDestination, Path, RequestInterface]);
end;

/// The options of OpenFile/SaveFile (a{sv}).
function MakeOptions(const Request: TWaylandFileDialogRequest; const Token: string): TDBusValue;
var
  Filters: TDBusValue;
  Folder, Name: string;
  I: Integer;
begin
  Result := TDBusValue.Create('a{sv}');
  try
    Result.AddOption('handle_token', TDBusValue.Str(Token));
    Result.AddOption('modal', TDBusValue.Bool(True));
    if Request.Kind <> TWaylandFileDialogKind.SaveFile then
    begin
      Result.AddOption('multiple', TDBusValue.Bool(Request.Multiple));
      // FileChooser version 3.
      if Request.Kind = TWaylandFileDialogKind.SelectFolder then
        Result.AddOption('directory', TDBusValue.Bool(True));
    end;
    // current_folder: SaveFile, and OpenFile since version 3 (older ones ignore it).
    Folder := Request.InitialFolder;
    if (Folder = '') and Request.InitialFile.StartsWith('/') then
    begin
      if (Request.Kind = TWaylandFileDialogKind.SelectFolder) and DirectoryExists(Request.InitialFile) then
        Folder := Request.InitialFile
      else
        Folder := TPath.GetDirectoryName(Request.InitialFile);
    end;
    if Folder <> '' then
      Result.AddOption('current_folder', TDBusValue.ByteArray(PathBytes(Folder)));
    if Request.Kind = TWaylandFileDialogKind.SaveFile then
    begin
      Name := TPath.GetFileName(Request.InitialFile);
      if Name <> '' then
        Result.AddOption('current_name', TDBusValue.Str(Name));
      if Request.InitialFile.StartsWith('/') and FileExists(Request.InitialFile) then
        Result.AddOption('current_file', TDBusValue.ByteArray(PathBytes(Request.InitialFile)));
    end;
    if Length(Request.Filters) > 0 then
    begin
      Filters := TDBusValue.Create('a(sa(us))');
      Result.AddOption('filters', Filters);
      for I := 0 to High(Request.Filters) do
        Filters.Children.Add(SerializeFilter(Request.Filters[I]));
      Result.AddOption('current_filter',
        Filters.Children[EnsureRange(Request.FilterIndex - 1, 0, High(Request.Filters))].Clone);
    end;
  except
    Result.Free;
    raise;
  end;
end;

/// Asks the portal to close the request (it ends the dialog; no Response follows), without the pump: also during
/// the application's shutdown. Failures are ignored (closing the connection removes the request too).
procedure CloseRequest(Bus: TDBusConnection; const Handle: string);
begin
  Bus.StopPumping;
  try
    Bus.Call(PortalDestination, Handle, RequestInterface, 'Close', [], 1000).Free;
  except
    on E: EDBusError do
      WlLog(TWlLogLevel.Debug, 'portal: Close of %s: %s', [Handle, E.Message]);
  end;
end;

/// False when the request object is gone (closed by someone else, or the portal went away) or answers no more.
function RequestAlive(Bus: TDBusConnection; const Handle: string): Boolean;
var
  Reply: TDBusMessage;
begin
  try
    Reply := Bus.Call(PortalDestination, Handle, 'org.freedesktop.DBus.Introspectable', 'Introspect', [],
      CallTimeoutMs);
  except
    on E: EDBusTimeout do
      // A busy portal is not a gone one.
      Exit(True);
    on E: EDBusCancelled do
      raise;
    on E: EDBusError do
      Exit(False);
  end;
  try
    Result := (Reply.Body.Count = 1) and Reply.Body[0].Text.Contains(RequestInterface);
  finally
    Reply.Free;
  end;
end;

function PortalFileDialog(const Request: TWaylandFileDialogRequest; const ParentWindow: string;
  out Files: TArray<string>; var FilterIndex: Integer; const Pump: TDBusPump): Boolean;
var
  Bus: TDBusConnection;
  Options, Parent, Title, Results, Uris, CurrentFilter: TDBusValue;
  Reply, Response: TDBusMessage;
  Id: TGUID;
  Token, Handle, Returned, Method: string;
  I: Integer;
  Version, Code: Cardinal;
  Pending: Boolean;
begin
  Files := nil;
  Result := False;
  Bus := nil;
  Handle := '';
  Pending := False;
  try
    // Up to the accepted request nothing is shown: any failure means "no usable portal".
    try
      Bus := TDBusConnection.Create(Pump);
      Version := GetVersion(Bus);
      if Version < 1 then
        raise EPortalUnsupported.Create('the portal has no usable FileChooser version');
      if (Request.Kind = TWaylandFileDialogKind.SelectFolder) and (Version < 3) then
        raise EPortalUnsupported.CreateFmt('folder selection needs FileChooser version 3 (the portal has %d)',
          [Version]);
      CreateGUID(Id);
      Token := 'fmx_' + GUIDToString(Id).Replace('{', '').Replace('}', '').Replace('-', '');
      // Subscribed before the call: the Response may come before the method's reply.
      Handle := RequestPath(Bus.UniqueName, Token);
      Bus.Subscribe(RequestInterface, 'Response');
      Bus.AddMatch(ResponseMatch(Handle));
      if Request.Kind = TWaylandFileDialogKind.SaveFile then
        Method := 'SaveFile'
      else
        Method := 'OpenFile';
      Parent := TDBusValue.Str(ParentWindow);
      Title := TDBusValue.Str(Request.Title);
      Options := MakeOptions(Request, Token);
      try
        try
          Reply := Bus.Call(PortalDestination, PortalPath, FileChooserInterface, Method, [Parent, Title, Options],
            CallTimeoutMs);
        except
          on E: EDBusTimeout do
          begin
            // The portal may still show the dialog: the request it would make is known.
            CloseRequest(Bus, Handle);
            raise;
          end;
        end;
      finally
        Parent.Free;
        Title.Free;
        Options.Free;
      end;
      try
        if (Reply.Body.Count <> 1) or (Reply.Body[0].Signature <> 'o') then
          raise EDBusError.Create('Invalid portal handle');
        Returned := Reply.Body[0].Text;
      finally
        Reply.Free;
      end;
      Pending := True;
      if Returned <> Handle then
      begin
        // Portals before handle_token (0.9) chose the path themselves.
        Handle := Returned;
        Bus.AddMatch(ResponseMatch(Handle));
      end;
      WlLog(TWlLogLevel.Debug, 'portal: %s request %s (FileChooser %d, parent "%s")',
        [Method, Handle, Version, ParentWindow]);
    except
      on E: EDBusCancelled do
        raise;
      on E: EPortalUnavailable do
        raise;
      on E: EDBusError do
        raise EPortalUnavailable.CreateRemote(E.RemoteName, E.Message);
      on E: Exception do
        raise EPortalUnavailable.Create(E.ClassName + ': ' + E.Message);
    end;
    repeat
      Response := Bus.WaitSignal(Handle, RequestInterface, 'Response', CheckIntervalMs);
      if (Response = nil) and not RequestAlive(Bus, Handle) then
      begin
        // A Response sent before the request went away arrived before the answer to Introspect.
        Response := Bus.WaitSignal(Handle, RequestInterface, 'Response', 0);
        if Response = nil then
        begin
          Pending := False;
          WlLog(TWlLogLevel.Warning, 'portal: the request %s was closed without a response', [Handle]);
          Exit(False);
        end;
      end;
    until Response <> nil;
    Pending := False;
    try
      if (Response.Body.Count <> 2) or (Response.Body[0].Signature <> 'u') or
        (Response.Body[1].Signature <> 'a{sv}') then
        raise EDBusError.Create('Invalid portal response');
      Code := Response.Body[0].Number;
      WlLog(TWlLogLevel.Debug, 'portal: response %d to %s', [Code, Handle]);
      if Code = ResponseCancelled then
        Exit(False);
      if Code <> ResponseSuccess then
      begin
        // 2: "ended in some other way" (also a backend that failed); GTK treats it as a cancel too.
        WlLog(TWlLogLevel.Warning, 'portal: the file dialog ended with response %d', [Code]);
        Exit(False);
      end;
      Results := Response.Body[1];
      Uris := Results.Item('uris');
      if (Uris = nil) or (Uris.Signature <> 'as') or (Uris.Children.Count = 0) then
        raise EDBusError.Create('FileChooser returned no files');
      if (not Request.Multiple or (Request.Kind = TWaylandFileDialogKind.SaveFile)) and
        (Uris.Children.Count <> 1) then
        raise EDBusError.Create('FileChooser returned multiple files for a single-selection dialog');
      SetLength(Files, Uris.Children.Count);
      for I := 0 to High(Files) do
      begin
        Files[I] := DecodeFileUri(Uris.Children[I].Text);
        if (Request.Kind = TWaylandFileDialogKind.SelectFolder) and (Length(Files[I]) > 1) then
          Files[I] := ExcludeTrailingPathDelimiter(Files[I]);
      end;
      CurrentFilter := Results.Item('current_filter');
      for I := 0 to High(Request.Filters) do
        if FilterMatches(CurrentFilter, Request.Filters[I]) then
        begin
          FilterIndex := I + 1;
          Break;
        end;
      Result := True;
    finally
      Response.Free;
    end;
  finally
    // The private connection owns the request: an unfinished dialog is closed (cancel, errors, shutdown).
    if Pending then
      CloseRequest(Bus, Handle);
    Bus.Free;
    if not Result then
      Files := nil;
  end;
end;

end.
