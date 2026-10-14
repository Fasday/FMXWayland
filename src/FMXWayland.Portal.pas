{ FMXWayland: XDG Desktop Portal FileChooser using the Pascal D-Bus client. MIT license. }
unit FMXWayland.Portal;

interface

uses
  System.SysUtils, FMXWayland.DialogTypes, FMXWayland.DBus;

type
  EPortalUnavailable = class(EDBusError);
  EPortalUnsupported = class(EPortalUnavailable);

function PortalFileDialog(const Request: TWaylandFileDialogRequest; out Files: TArray<string>;
  var FilterIndex: Integer; const Pump: TFunc<Boolean>): Boolean;
function PortalFileChooserVersion: Cardinal;

implementation

uses
  System.Math, System.IOUtils, System.Generics.Collections;

const
  PortalDestination = 'org.freedesktop.portal.Desktop';
  PortalPath = '/org/freedesktop/portal/desktop';
  FileChooserInterface = 'org.freedesktop.portal.FileChooser';
  RequestInterface = 'org.freedesktop.portal.Request';

function IsMissingService(const Name: string): Boolean;
begin
  Result := (Name = 'org.freedesktop.DBus.Error.ServiceUnknown') or
    (Name = 'org.freedesktop.DBus.Error.NameHasNoOwner') or
    (Name = 'org.freedesktop.DBus.Error.UnknownInterface') or
    (Name = 'org.freedesktop.DBus.Error.UnknownObject') or
    (Name = 'org.freedesktop.DBus.Error.UnknownMethod') or
    (Name = 'org.freedesktop.DBus.Error.UnknownProperty') or
    (Name = 'org.freedesktop.DBus.Error.Spawn.ServiceNotFound') or
    (Name = 'org.freedesktop.DBus.Error.Spawn.ExecFailed') or
    (Name = 'org.freedesktop.DBus.Error.Spawn.ChildExited') or
    (Name = 'org.freedesktop.portal.Error.NotFound') or
    (Name = 'org.freedesktop.portal.Error.NotSupported');
end;

function PortalCall(Bus: TDBusConnection; const Intf, Method: string;
  const Args: array of TDBusValue): TDBusMessage;
begin
  try
    Result := Bus.Call(PortalDestination, PortalPath, Intf, Method, Args);
  except
    on E: EDBusError do
    begin
      if IsMissingService(E.RemoteName) then raise EPortalUnavailable.Create(E.Message);
      raise;
    end;
  end;
end;

function GetVersion(Bus: TDBusConnection): Cardinal;
var
  Intf, Prop: TDBusValue;
  Reply: TDBusMessage;
begin
  Intf := TDBusValue.Str(FileChooserInterface);
  Prop := TDBusValue.Str('version');
  try
    try
      Reply := PortalCall(Bus, 'org.freedesktop.DBus.Properties', 'Get', [Intf, Prop]);
    except
      on E: EDBusTimeout do raise EPortalUnavailable.Create('FileChooser capability check timed out');
      on E: EDBusError do
      begin
        if (E.RemoteName = 'org.freedesktop.DBus.Error.NoReply') or
          (E.RemoteName = 'org.freedesktop.DBus.Error.TimedOut') or
          (E.RemoteName = 'org.freedesktop.DBus.Error.Timeout') then raise EPortalUnavailable.Create(E.Message);
        raise;
      end;
    end;
    try
      if (Reply.Body.Count <> 1) or (Reply.Body[0].Children.Count <> 1) then
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
  Bus := TDBusConnection.Create;
  try Result := GetVersion(Bus); finally Bus.Free; end;
end;

function SerializeFilter(const Filter: TWaylandFileFilter): TDBusValue;
var
  Patterns, Pattern: TDBusValue;
  Mask: string;
begin
  Result := TDBusValue.Create('(sa(us))');
  Result.Children.Add(TDBusValue.Str(Filter.Name));
  Patterns := TDBusValue.Create('a(us)');
  Result.Children.Add(Patterns);
  for Mask in Filter.Patterns do
  begin
    if Mask.Trim = '' then Continue;
    Pattern := TDBusValue.Create('(us)');
    Pattern.Children.Add(TDBusValue.UInt(0));
    if Mask.Trim = '*.*' then Pattern.Children.Add(TDBusValue.Str('*'))
    else Pattern.Children.Add(TDBusValue.Str(Mask.Trim));
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
    Result := (Value <> nil) and (Value.Children.Count = 2) and
      (Value.Children[0].Text = Expected.Children[0].Text) and
      (Value.Children[1].Children.Count = Expected.Children[1].Children.Count);
    if not Result then Exit;
    for I := 0 to Expected.Children[1].Children.Count - 1 do
      if (Value.Children[1].Children[I].Children.Count <> 2) or
        (Value.Children[1].Children[I].Children[0].Number <> 0) or
        (Value.Children[1].Children[I].Children[1].Text <> Expected.Children[1].Children[I].Children[1].Text) then
        Exit(False);
  finally
    Expected.Free;
  end;
end;

function DecodeFileUri(const Uri: string): string;
var
  Path, Authority: string;
  Input, Output: TBytes;
  I, N, Count, Slash: Integer;
begin
  if not Uri.StartsWith('file://') then raise EDBusError.Create('FileChooser returned a non-file URI');
  Path := Copy(Uri, 8, MaxInt);
  if not Path.StartsWith('/') then
  begin
    Slash := Path.IndexOf('/');
    if Slash < 0 then raise EDBusError.Create('Invalid file URI');
    Authority := Copy(Path, 1, Slash);
    if not SameText(Authority, 'localhost') then raise EDBusError.Create('Remote file URI is not a local path');
    Path := Copy(Path, Slash + 1, MaxInt);
  end;
  Input := TEncoding.UTF8.GetBytes(Path);
  SetLength(Output, Length(Input));
  I := 0; Count := 0;
  while I < Length(Input) do
  begin
    if Input[I] = Ord('%') then
    begin
      if I + 2 >= Length(Input) then raise EDBusError.Create('Invalid file URI escape');
      N := StrToIntDef('$' + Char(Input[I + 1]) + Char(Input[I + 2]), -1);
      if N <= 0 then raise EDBusError.Create('Invalid file URI escape');
      Output[Count] := N;
      Inc(I, 3);
    end
    else
    begin
      if Input[I] in [0, 10, 13, Ord('?'), Ord('#')] then raise EDBusError.Create('Invalid file URI');
      Output[Count] := Input[I];
      Inc(I);
    end;
    Inc(Count);
  end;
  Result := TEncoding.UTF8.GetString(Output, 0, Count);
  if Result.Contains(#10) or Result.Contains(#13) then
    raise EDBusError.Create('FMX file lists cannot represent filenames containing line breaks');
end;

function PathBytes(const Path: string): TBytes;
begin
  Result := TEncoding.UTF8.GetBytes(Path + #0);
end;

function PortalFileDialog(const Request: TWaylandFileDialogRequest; out Files: TArray<string>;
  var FilterIndex: Integer; const Pump: TFunc<Boolean>): Boolean;
var
  Bus: TDBusConnection;
  Options, Filters, Parent, Title, Value, Uris, CurrentFilter: TDBusValue;
  Reply, Response: TDBusMessage;
  Id: TGUID;
  Token, Handle, Method, Folder, Name: string;
  I, SelectedIndex: Integer;
  Version: Cardinal;
  Pending: Boolean;
begin
  Files := nil;
  try
    Bus := TDBusConnection.Create(Pump);
  except
    on E: EDBusUnavailable do raise EPortalUnavailable.Create(E.Message);
    on E: EDBusTimeout do raise EPortalUnavailable.Create(E.Message);
  end;
  Handle := '';
  Pending := False;
  try
    Version := GetVersion(Bus);
    if Version < 1 then raise EPortalUnsupported.Create('This portal has no supported FileChooser version');
    if (Request.Kind = TWaylandFileDialogKind.SelectFolder) and (Version < 3) then
      raise EPortalUnsupported.Create('Folder selection requires XDG FileChooser version 3');
    // Subscribe before OpenFile/SaveFile: a fast provider may send Response before the method reply.
    Bus.AddMatch('type=''signal'',sender=''org.freedesktop.portal.Desktop'',interface=''' +
      RequestInterface + ''',member=''Response''');
    CreateGUID(Id);
    Token := 'fmx_' + GUIDToString(Id).Replace('{', '').Replace('}', '').Replace('-', '');
    Options := TDBusValue.Create('a{sv}');
    Parent := TDBusValue.Str(''); // Wayland compositors without xdg-foreign cannot export a parent identifier.
    Title := TDBusValue.Str(Request.Title);
    try
      Options.AddOption('handle_token', TDBusValue.Str(Token));
      Options.AddOption('modal', TDBusValue.Bool(True));
      if Request.Kind <> TWaylandFileDialogKind.SaveFile then
      begin
        Options.AddOption('multiple', TDBusValue.Bool(Request.Multiple));
        if Request.Kind = TWaylandFileDialogKind.SelectFolder then Options.AddOption('directory', TDBusValue.Bool(True));
      end;
      Folder := Request.InitialFolder;
      if (Folder = '') and Request.InitialFile.StartsWith('/') then Folder := TPath.GetDirectoryName(Request.InitialFile);
      if Folder <> '' then Options.AddOption('current_folder', TDBusValue.ByteArray(PathBytes(Folder)));
      if Request.Kind = TWaylandFileDialogKind.SaveFile then
      begin
        Name := TPath.GetFileName(Request.InitialFile);
        if Name <> '' then Options.AddOption('current_name', TDBusValue.Str(Name));
        if (Request.InitialFile <> '') and FileExists(Request.InitialFile) then
          Options.AddOption('current_file', TDBusValue.ByteArray(PathBytes(Request.InitialFile)));
      end;
      if Length(Request.Filters) > 0 then
      begin
        Filters := TDBusValue.Create('a(sa(us))');
        for I := 0 to High(Request.Filters) do Filters.Children.Add(SerializeFilter(Request.Filters[I]));
        SelectedIndex := EnsureRange(Request.FilterIndex - 1, 0, High(Request.Filters));
        Options.AddOption('current_filter', Filters.Children[SelectedIndex].Clone);
        Options.AddOption('filters', Filters);
      end;
      if Request.Kind = TWaylandFileDialogKind.SaveFile then Method := 'SaveFile' else Method := 'OpenFile';
      Reply := PortalCall(Bus, FileChooserInterface, Method, [Parent, Title, Options]);
      try
        if (Reply.Body.Count <> 1) or (Reply.Body[0].Signature <> 'o') then raise EDBusError.Create('Invalid portal handle');
        Handle := Reply.Body[0].Text;
        Pending := True;
      finally
        Reply.Free;
      end;
    finally
      Parent.Free; Title.Free; Options.Free;
    end;
    Response := nil;
    while Response = nil do Response := Bus.WaitSignal(Handle, RequestInterface, 'Response', 100);
    try
      Pending := False;
      if (Response.Body.Count <> 2) or (Response.Body[0].Signature <> 'u') or
        (Response.Body[1].Signature <> 'a{sv}') then raise EDBusError.Create('Invalid portal response');
      if Response.Body[0].Number = 1 then Exit(False);
      if Response.Body[0].Number <> 0 then raise EDBusError.Create('FileChooser failed');
      Value := Response.Body[1];
      Uris := Value.Item('uris');
      if (Uris = nil) or (Uris.Signature <> 'as') or (Uris.Children.Count = 0) then
        raise EDBusError.Create('FileChooser returned no files');
      if (not Request.Multiple or (Request.Kind = TWaylandFileDialogKind.SaveFile)) and (Uris.Children.Count <> 1) then
        raise EDBusError.Create('FileChooser returned multiple files for a single-selection dialog');
      SetLength(Files, Uris.Children.Count);
      for I := 0 to High(Files) do Files[I] := DecodeFileUri(Uris.Children[I].Text);
      CurrentFilter := Value.Item('current_filter');
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
    // A private connection owns the request. Closing it cancels an unfinished dialog even during app shutdown.
    if Pending and (Handle <> '') then
    begin
      Bus.StopPumping;
      try
        Reply := Bus.Call(PortalDestination, Handle, RequestInterface, 'Close', [], 1000);
        Reply.Free;
      except
        // A failed Close must not replace the original error; disconnect also removes the request.
      end;
    end;
    Bus.Free;
  end;
end;

end.
