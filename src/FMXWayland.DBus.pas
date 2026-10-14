{ FMXWayland: a small D-Bus client over Unix sockets, using only the Delphi RTL.
  Written by Hemul GM. Copyright (c) 2026 Fasday and contributors. MIT license, see LICENSE. }

/// <summary>A small D-Bus client (no libdbus): a private connection to the session bus over its Unix socket, SASL
/// EXTERNAL authentication, method calls and signals with the marshalled values of the D-Bus wire format.</summary>
/// <remarks>Main thread only (a connection is not shared between threads). Outgoing messages are little endian;
/// incoming ones may be either. No Unix file descriptors are passed (NEGOTIATE_UNIX_FD is not asked for).</remarks>
unit FMXWayland.DBus;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections;

type
  /// <summary>A D-Bus failure; RemoteName is the error name of an error reply ('' for local failures).</summary>
  EDBusError = class(Exception)
  public
    RemoteName: string;
    constructor CreateRemote(const Name, Message: string);
  end;
  /// <summary>No session bus to connect to, or it refused us.</summary>
  EDBusUnavailable = class(EDBusError);
  /// <summary>No answer in time.</summary>
  EDBusTimeout = class(EDBusError);
  /// <summary>The pump asked to stop waiting.</summary>
  EDBusCancelled = class(EDBusError);

  /// <summary>Waits until AFd is readable or ATimeoutMs milliseconds have passed, processing the application's
  /// events meanwhile (painting, timers); returning False makes the waiting D-Bus call give up with
  /// EDBusCancelled.</summary>
  TDBusPump = reference to function(const AFd, ATimeoutMs: Integer): Boolean;

  /// <summary>A D-Bus value of a single complete type: numbers in Number (signed types as their two's complement
  /// bits), strings, object paths and signatures in Text, byte arrays in Bytes, the items of other containers in
  /// Children (a variant has one child).</summary>
  TDBusValue = class
  public
    Signature, Text: string;
    Number: UInt64;
    Bytes: TBytes;
    Children: TObjectList<TDBusValue>;
    constructor Create(const ASignature: string);
    destructor Destroy; override;
    function Clone: TDBusValue;
    /// <summary>The value of the entry Key of a dictionary (a{sv}: unwrapped from its variant), or nil.</summary>
    function Item(const Key: string): TDBusValue;
    /// <summary>Adds the entry Key: Value (wrapped into a variant) to an a{sv} dictionary; takes Value over.</summary>
    procedure AddOption(const Key: string; Value: TDBusValue);
    class function Str(const Value: string; const Sig: string = 's'): TDBusValue; static;
    class function UInt(Value: Cardinal): TDBusValue; static;
    class function Bool(Value: Boolean): TDBusValue; static;
    class function ByteArray(const Value: TBytes): TDBusValue; static;
  end;

  /// <summary>A message received: Kind 1 method call, 2 method return, 3 error, 4 signal.</summary>
  TDBusMessage = class
  public
    Kind: Byte;
    Serial, ReplySerial: Cardinal;
    Path, Intf, Member, ErrorName, Sender, Signature: string;
    Body: TObjectList<TDBusValue>;
    constructor Create;
    destructor Destroy; override;
  end;

  /// <summary>A private connection to the session bus.</summary>
  /// <remarks>Waiting (for the authentication, replies and signals) goes through the pump, which keeps the
  /// application's event loop running; without a pump it blocks in poll. Signals that arrive while a call waits for
  /// its reply are kept when Subscribe asked for them (so a reply and a signal can come in either order), others are
  /// dropped.</remarks>
  TDBusConnection = class
  private
    FFd: Integer;
    FSerial: Cardinal;
    FInput: TBytes;
    FSignals: TObjectList<TDBusMessage>;
    FWanted: TList<string>;
    FUniqueName: string;
    FPump: TDBusPump;
    procedure Connect(const Address: string);
    procedure WaitReadable(TimeoutMs: Integer);
    procedure SendBytes(const Data: TBytes);
    function ReadLine: string;
    function Receive(TimeoutMs: Integer): TDBusMessage;
    function ExtractMessage: TDBusMessage;
    procedure Keep(Msg: TDBusMessage);
  public
    /// <summary>Connects to the session bus (Address: a D-Bus address; '' = FindSessionBus), authenticates and says
    /// Hello. Raises EDBusUnavailable when no address works.</summary>
    constructor Create(const APump: TDBusPump = nil; const Address: string = '');
    destructor Destroy; override;
    /// <summary>Calls a method and waits up to TimeoutMs for its reply (raises EDBusError with RemoteName for an
    /// error reply, EDBusTimeout without a reply).</summary>
    function Call(const Destination, Path, Intf, Member: string; const Args: array of TDBusValue;
      TimeoutMs: Integer = 5000): TDBusMessage;
    /// <summary>Adds a match rule (org.freedesktop.DBus.AddMatch).</summary>
    procedure AddMatch(const Rule: string);
    /// <summary>Keeps the signals Intf.Member that arrive while other things are awaited, for WaitSignal.</summary>
    procedure Subscribe(const Intf, Member: string);
    /// <summary>Stops calling the pump (cleanup may need to close a portal request after the application's pump
    /// stopped).</summary>
    procedure StopPumping;
    /// <summary>Waits up to TimeoutMs for the signal Intf.Member on Path (0: only what has arrived); nil when none
    /// came.</summary>
    function WaitSignal(const Path, Intf, Member: string; TimeoutMs: Integer): TDBusMessage;
    property UniqueName: string read FUniqueName;
    property Fd: Integer read FFd;
  end;

/// <summary>The address of the session bus: DBUS_SESSION_BUS_ADDRESS, else the socket "bus" in XDG_RUNTIME_DIR or in
/// /run/user/&lt;uid&gt;, else the address an X11-autolaunched bus of this machine left in ~/.dbus/session-bus (read,
/// never executed). Raises EDBusUnavailable when there is none.</summary>
function FindSessionBus: string;

implementation

uses
  System.IOUtils, System.Math, Posix.SysSocket, Posix.Unistd, Posix.Errno,
  FMXWayland.Posix;

const
  /// <summary>The largest message accepted (the reference bus allows 128 MiB; portal replies are small).</summary>
  MaxMessage = 8 * 1024 * 1024;
  MaxPendingSignals = 64;
  MSG_DONTWAIT = $40;
  MSG_NOSIGNAL = $4000;
  SOCK_NONBLOCK = $800;
  SOCK_CLOEXEC = $80000;
  /// <summary>Message types.</summary>
  KindMethodCall = 1;
  KindReturn = 2;
  KindError = 3;
  KindSignal = 4;

type
  TUnixAddress = packed record
    Family: Word;
    Name: array[0..107] of AnsiChar;
  end;

  /// <summary>Marshals values (little endian); positions count from the start of the stream, which must start at
  /// an 8-byte boundary of the message.</summary>
  TWireWriter = class
    Stream: TMemoryStream;
    constructor Create;
    destructor Destroy; override;
    procedure Align(Boundary: Integer);
    procedure ByteValue(Value: Byte);
    procedure UIntValue(Value: UInt64; Count: Integer);
    procedure Raw(const Data: TBytes);
    procedure Sig(const Value: string);
    procedure Value(Item: TDBusValue);
    function Data: TBytes;
  end;

  /// <summary>Unmarshals values of a message (either endianness); positions count from the message start.</summary>
  TWireReader = class
    Data: TBytes;
    Position, Depth: Integer;
    Little: Boolean;
    constructor Create(const AData: TBytes; ALittle: Boolean);
    procedure Align(Boundary: Integer);
    procedure Require(Count: Integer);
    function UIntValue(Count: Integer): UInt64;
    function Sig: string;
    function Value(const Signature: string): TDBusValue;
  end;

function Alignment(const Sig: string): Integer;
begin
  if Sig = '' then
    raise EDBusError.Create('Empty D-Bus type');
  case Sig[1] of
    'y', 'g', 'v':
      Result := 1;
    'n', 'q':
      Result := 2;
    'b', 'i', 'u', 's', 'o', 'a':
      Result := 4;
    'x', 't', 'd', '(', '{':
      Result := 8;
  else
    raise EDBusError.Create('Unsupported D-Bus type: ' + Sig);
  end;
end;

constructor EDBusError.CreateRemote(const Name, Message: string);
begin
  inherited Create(Message);
  RemoteName := Name;
end;

/// The single complete type at Index of Sig; Index moves past it.
function NextType(const Sig: string; var Index: Integer): string;
var
  Start: Integer;
  Terminator: Char;
begin
  if (Index < 1) or (Index > Length(Sig)) then
    raise EDBusError.Create('Incomplete D-Bus signature');
  Start := Index;
  case Sig[Index] of
    'a':
      begin
        Inc(Index);
        NextType(Sig, Index);
      end;
    '(', '{':
      begin
        if Sig[Index] = '(' then
          Terminator := ')'
        else
          Terminator := '}';
        Inc(Index);
        while (Index <= Length(Sig)) and (Sig[Index] <> Terminator) do
          NextType(Sig, Index);
        if Index > Length(Sig) then
          raise EDBusError.Create('Unclosed D-Bus container');
        Inc(Index);
      end;
    'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'v':
      Inc(Index);
  else
    raise EDBusError.Create('Invalid D-Bus signature');
  end;
  Result := Copy(Sig, Start, Index - Start);
end;

/// Raises unless Sig is exactly one complete type (a variant's signature, a header field's).
procedure CheckSingleType(const Sig: string);
var
  Index: Integer;
begin
  Index := 1;
  NextType(Sig, Index);
  if Index <> Length(Sig) + 1 then
    raise EDBusError.Create('Not a single complete D-Bus type: ' + Sig);
end;

{$REGION 'TDBusValue, TDBusMessage'}

constructor TDBusValue.Create(const ASignature: string);
begin
  inherited Create;
  Signature := ASignature;
  Children := TObjectList<TDBusValue>.Create(True);
end;

destructor TDBusValue.Destroy;
begin
  Children.Free;
  inherited;
end;

function TDBusValue.Clone: TDBusValue;
var
  Child: TDBusValue;
begin
  Result := TDBusValue.Create(Signature);
  Result.Text := Text;
  Result.Number := Number;
  Result.Bytes := Copy(Bytes);
  for Child in Children do
    Result.Children.Add(Child.Clone);
end;

class function TDBusValue.Str(const Value: string; const Sig: string): TDBusValue;
begin
  Result := TDBusValue.Create(Sig);
  Result.Text := Value;
end;

class function TDBusValue.UInt(Value: Cardinal): TDBusValue;
begin
  Result := TDBusValue.Create('u');
  Result.Number := Value;
end;

class function TDBusValue.Bool(Value: Boolean): TDBusValue;
begin
  Result := TDBusValue.Create('b');
  Result.Number := Ord(Value);
end;

class function TDBusValue.ByteArray(const Value: TBytes): TDBusValue;
begin
  Result := TDBusValue.Create('ay');
  Result.Bytes := Copy(Value);
end;

procedure TDBusValue.AddOption(const Key: string; Value: TDBusValue);
var
  Entry, Variant: TDBusValue;
begin
  Entry := TDBusValue.Create('{sv}');
  Entry.Children.Add(Str(Key));
  Variant := TDBusValue.Create('v');
  Variant.Children.Add(Value);
  Entry.Children.Add(Variant);
  Children.Add(Entry);
end;

function TDBusValue.Item(const Key: string): TDBusValue;
var
  Entry: TDBusValue;
begin
  Result := nil;
  for Entry in Children do
    if (Entry.Children.Count = 2) and (Entry.Children[0].Text = Key) then
    begin
      Result := Entry.Children[1];
      while (Result.Signature = 'v') and (Result.Children.Count = 1) do
        Result := Result.Children[0];
      Exit;
    end;
end;

constructor TDBusMessage.Create;
begin
  inherited;
  Body := TObjectList<TDBusValue>.Create(True);
end;

destructor TDBusMessage.Destroy;
begin
  Body.Free;
  inherited;
end;

{$ENDREGION}

{$REGION 'TWireWriter'}

constructor TWireWriter.Create;
begin
  inherited;
  Stream := TMemoryStream.Create;
end;

destructor TWireWriter.Destroy;
begin
  Stream.Free;
  inherited;
end;

procedure TWireWriter.ByteValue(Value: Byte);
begin
  Stream.WriteBuffer(Value, 1);
end;

procedure TWireWriter.Align(Boundary: Integer);
begin
  while Stream.Position mod Boundary <> 0 do
    ByteValue(0);
end;

procedure TWireWriter.UIntValue(Value: UInt64; Count: Integer);
var
  I: Integer;
begin
  for I := 0 to Count - 1 do
    ByteValue(Byte(Value shr (8 * I)));
end;

procedure TWireWriter.Raw(const Data: TBytes);
begin
  if Length(Data) > 0 then
    Stream.WriteBuffer(Data[0], Length(Data));
end;

procedure TWireWriter.Sig(const Value: string);
var
  Bytes: TBytes;
begin
  Bytes := TEncoding.ASCII.GetBytes(Value);
  if Length(Bytes) > 255 then
    raise EDBusError.Create('D-Bus signature is too long');
  ByteValue(Length(Bytes));
  Raw(Bytes);
  ByteValue(0);
end;

procedure TWireWriter.Value(Item: TDBusValue);
var
  Bytes: TBytes;
  Child: TDBusValue;
  SizeAt, StartAt, EndAt: Int64;
begin
  Align(Alignment(Item.Signature));
  case Item.Signature[1] of
    'y':
      UIntValue(Item.Number, 1);
    'n', 'q':
      UIntValue(Item.Number, 2);
    'b', 'i', 'u':
      UIntValue(Item.Number, 4);
    'x', 't', 'd':
      UIntValue(Item.Number, 8);
    's', 'o':
      begin
        // The bus disconnects clients that send invalid UTF-8 or NUL; TEncoding.UTF8 replaces lone surrogates.
        if Item.Text.Contains(#0) then
          raise EDBusError.Create('NUL in D-Bus string');
        Bytes := TEncoding.UTF8.GetBytes(Item.Text);
        UIntValue(Length(Bytes), 4);
        Raw(Bytes);
        ByteValue(0);
      end;
    'g':
      Sig(Item.Text);
    'v':
      begin
        if Item.Children.Count <> 1 then
          raise EDBusError.Create('Invalid D-Bus variant');
        Sig(Item.Children[0].Signature);
        Value(Item.Children[0]);
      end;
    'a':
      begin
        // The length counts the elements only, not the padding to the first one.
        SizeAt := Stream.Position;
        UIntValue(0, 4);
        Align(Alignment(Copy(Item.Signature, 2, MaxInt)));
        StartAt := Stream.Position;
        if Item.Signature = 'ay' then
          Raw(Item.Bytes)
        else
          for Child in Item.Children do
            Value(Child);
        EndAt := Stream.Position;
        Stream.Position := SizeAt;
        UIntValue(EndAt - StartAt, 4);
        Stream.Position := EndAt;
      end;
    '(', '{':
      for Child in Item.Children do
        Value(Child);
  else
    raise EDBusError.Create('Unsupported D-Bus type: ' + Item.Signature);
  end;
end;

function TWireWriter.Data: TBytes;
begin
  SetLength(Result, Stream.Size);
  if Stream.Size > 0 then
    Move(Stream.Memory^, Result[0], Stream.Size);
end;

{$ENDREGION}

{$REGION 'TWireReader'}

constructor TWireReader.Create(const AData: TBytes; ALittle: Boolean);
begin
  inherited Create;
  Data := AData;
  Little := ALittle;
end;

procedure TWireReader.Require(Count: Integer);
begin
  if (Count < 0) or (Position < 0) or (Count > Length(Data) - Position) then
    raise EDBusError.Create('Truncated D-Bus message');
end;

procedure TWireReader.Align(Boundary: Integer);
begin
  Position := (Position + Boundary - 1) and not (Boundary - 1);
  Require(0);
end;

function TWireReader.UIntValue(Count: Integer): UInt64;
var
  I, Shift: Integer;
begin
  Require(Count);
  Result := 0;
  for I := 0 to Count - 1 do
  begin
    if Little then
      Shift := I * 8
    else
      Shift := (Count - 1 - I) * 8;
    Result := Result or (UInt64(Data[Position + I]) shl Shift);
  end;
  Inc(Position, Count);
end;

function TWireReader.Sig: string;
var
  Count: Integer;
begin
  Count := UIntValue(1);
  Require(Count + 1);
  Result := TEncoding.ASCII.GetString(Data, Position, Count);
  Inc(Position, Count);
  if UIntValue(1) <> 0 then
    raise EDBusError.Create('Unterminated D-Bus signature');
end;

function TWireReader.Value(const Signature: string): TDBusValue;
var
  Count, StopAt, Index: Integer;
  ChildSig: string;
begin
  Inc(Depth);
  try
    // The specification allows 32 levels of arrays plus 32 of structures.
    if Depth > 64 then
      raise EDBusError.Create('D-Bus container nesting limit');
    Align(Alignment(Signature));
    Result := TDBusValue.Create(Signature);
    try
      case Signature[1] of
        'y':
          Result.Number := UIntValue(1);
        'n', 'q':
          Result.Number := UIntValue(2);
        'b', 'i', 'u':
          Result.Number := UIntValue(4);
        'x', 't', 'd':
          Result.Number := UIntValue(8);
        's', 'o':
          begin
            Count := UIntValue(4);
            Require(Count + 1);
            Result.Text := TEncoding.UTF8.GetString(Data, Position, Count);
            Inc(Position, Count);
            if UIntValue(1) <> 0 then
              raise EDBusError.Create('Unterminated D-Bus string');
          end;
        'g':
          Result.Text := Sig;
        'v':
          begin
            ChildSig := Sig;
            CheckSingleType(ChildSig);
            Result.Children.Add(Value(ChildSig));
          end;
        'a':
          begin
            Count := UIntValue(4);
            ChildSig := Copy(Signature, 2, MaxInt);
            Align(Alignment(ChildSig));
            Require(Count);
            StopAt := Position + Count;
            if ChildSig = 'y' then
            begin
              Result.Bytes := Copy(Data, Position, Count);
              Position := StopAt;
            end
            else
              while Position < StopAt do
                Result.Children.Add(Value(ChildSig));
            if Position <> StopAt then
              raise EDBusError.Create('Invalid D-Bus array size');
          end;
        '(', '{':
          begin
            Index := 2;
            while Index < Length(Signature) do
            begin
              ChildSig := NextType(Signature, Index);
              Result.Children.Add(Value(ChildSig));
            end;
          end;
      else
        raise EDBusError.Create('Unsupported D-Bus type: ' + Signature);
      end;
    except
      Result.Free;
      raise;
    end;
  finally
    Dec(Depth);
  end;
end;

{$ENDREGION}

{$REGION 'Session bus address'}

/// The bytes of a D-Bus address value with its %XX escapes decoded.
function DecodeAddress(const Value: string): UTF8String;
var
  I, N, Count: Integer;
  B: TBytes;
begin
  B := TEncoding.UTF8.GetBytes(Value);
  SetLength(Result, Length(B));
  Count := 0;
  I := 0;
  while I < Length(B) do
  begin
    if B[I] = Ord('%') then
    begin
      if I + 2 >= Length(B) then
        raise EDBusError.Create('Invalid D-Bus address escape');
      N := StrToIntDef('$' + Char(B[I + 1]) + Char(B[I + 2]), -1);
      if (N < 0) or (N > 255) then
        raise EDBusError.Create('Invalid D-Bus address escape');
      Inc(Count);
      Result[Count] := AnsiChar(N);
      Inc(I, 3);
    end
    else
    begin
      Inc(Count);
      Result[Count] := AnsiChar(B[I]);
      Inc(I);
    end;
  end;
  SetLength(Result, Count);
end;

/// A path as a D-Bus address value: bytes other than [-0-9A-Za-z_/.\*] become %XX.
function EscapeAddress(const Path: string): string;
var
  B: Byte;
begin
  Result := '';
  for B in TEncoding.UTF8.GetBytes(Path) do
    if AnsiChar(B) in ['-', '0'..'9', 'A'..'Z', 'a'..'z', '_', '/', '.', '\', '*'] then
      Result := Result + Char(B)
    else
      Result := Result + '%' + IntToHex(B, 2);
end;

/// The machine id of D-Bus (X11 autolaunch keys its files with it), or ''.
function MachineId: string;
const
  CFiles: array[0..1] of string = ('/etc/machine-id', '/var/lib/dbus/machine-id');
var
  FileName: string;
begin
  Result := '';
  for FileName in CFiles do
    try
      if FileExists(FileName) then
        Result := TFile.ReadAllText(FileName).Trim;
      if Result <> '' then
        Exit;
    except
      on Exception do
        Result := '';
    end;
end;

function FindSessionBus: string;
var
  Candidate, Directory, FileName, Line, Id: string;
begin
  Result := GetEnvironmentVariable('DBUS_SESSION_BUS_ADDRESS');
  if Result <> '' then
    Exit;
  // Where libdbus and GDBus look next (the "user bus" of systemd).
  Directory := GetEnvironmentVariable('XDG_RUNTIME_DIR');
  if (Directory <> '') and FileExists(Directory + '/bus') then
    Exit('unix:path=' + EscapeAddress(Directory + '/bus'));
  Candidate := '/run/user/' + UIntToStr(getuid) + '/bus';
  if FileExists(Candidate) then
    Exit('unix:path=' + Candidate);
  // WSL without systemd commonly has an X11-autolaunched bus: its address is in a file named after the machine id
  // and the display. Read it, never execute the file.
  Id := MachineId;
  Directory := TPath.Combine(GetEnvironmentVariable('HOME'), '.dbus/session-bus');
  if (Id <> '') and DirectoryExists(Directory) then
    for FileName in TDirectory.GetFiles(Directory, Id + '-*') do
      try
        if TFile.GetSize(FileName) < 65536 then
          for Line in TFile.ReadAllLines(FileName, TEncoding.UTF8) do
            if Line.StartsWith('DBUS_SESSION_BUS_ADDRESS=') then
            begin
              Result := Copy(Line, Length('DBUS_SESSION_BUS_ADDRESS=') + 1, MaxInt).Trim;
              if (Length(Result) >= 2) and (Result[1] = #39) and (Result[Length(Result)] = #39) then
                Result := Copy(Result, 2, Length(Result) - 2);
              if Result.StartsWith('unix:') then
                Exit;
            end;
      except
        // An unreadable file is no address.
        on Exception do
          Result := '';
      end;
  raise EDBusUnavailable.Create('no session bus (DBUS_SESSION_BUS_ADDRESS is not set)');
end;

/// The Unix socket of an address entry: 'unix:path=...', 'unix:abstract=...' or 'unix:runtime=yes' (keys such as
/// guid= are ignored); False for other transports and for listen-only entries (unix:dir=, unix:tmpdir=).
function UnixSocketOf(const Entry: string; out Name: UTF8String; out Abstract: Boolean): Boolean;
var
  Part, Key, Value, Runtime: string;
  P: Integer;
begin
  Result := False;
  Name := '';
  Abstract := False;
  if not Entry.StartsWith('unix:') then
    Exit;
  for Part in Copy(Entry, 6, MaxInt).Split([',']) do
  begin
    P := Part.IndexOf('=');
    if P <= 0 then
      Continue;
    Key := Part.Substring(0, P);
    Value := Part.Substring(P + 1);
    if Key = 'path' then
    begin
      Name := DecodeAddress(Value);
      Result := True;
    end
    else if Key = 'abstract' then
    begin
      Name := DecodeAddress(Value);
      Abstract := True;
      Result := True;
    end
    else if (Key = 'runtime') and (DecodeAddress(Value) = 'yes') then
    begin
      Runtime := GetEnvironmentVariable('XDG_RUNTIME_DIR');
      if Runtime <> '' then
      begin
        Name := UTF8String(Runtime + '/bus');
        Result := True;
      end;
    end;
  end;
end;

/// A connected, non-blocking stream socket to a Unix socket, or -1 with the reason in Error.
function ConnectUnix(const Name: UTF8String; Abstract: Boolean; var Error: string): Integer;
var
  Addr: TUnixAddress;
  AddrLen: Integer;
begin
  Result := -1;
  // sun_path: 108 bytes, with the NUL of a path or the leading NUL of an abstract name.
  if (Length(Name) = 0) or (Length(Name) > 107) then
  begin
    Error := 'invalid socket name';
    Exit;
  end;
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.Family := AF_UNIX;
  if Abstract then
  begin
    Move(Name[1], Addr.Name[1], Length(Name));
    AddrLen := 2 + 1 + Length(Name);
  end
  else
  begin
    Move(Name[1], Addr.Name[0], Length(Name));
    AddrLen := 2 + Length(Name) + 1;
  end;
  // Non-blocking: a bus with a full listen queue fails at once (EAGAIN) instead of blocking the program.
  Result := socket(AF_UNIX, SOCK_STREAM or SOCK_NONBLOCK or SOCK_CLOEXEC, 0);
  if Result < 0 then
  begin
    Error := SysErrorMessage(errno);
    Exit;
  end;
  if connect(Result, PSockAddr(@Addr)^, AddrLen) <> 0 then
  begin
    Error := string(Name) + ': ' + SysErrorMessage(errno);
    CloseFd(Result);
  end;
end;

{$ENDREGION}

{$REGION 'TDBusConnection'}

constructor TDBusConnection.Create(const APump: TDBusPump; const Address: string);
var
  Uid, Auth, Line: string;
  I: Integer;
  Reply: TDBusMessage;
begin
  inherited Create;
  FFd := -1;
  FPump := APump;
  FSignals := TObjectList<TDBusMessage>.Create(True);
  FWanted := TList<string>.Create;
  if Address <> '' then
    Connect(Address)
  else
    Connect(FindSessionBus);
  // SASL EXTERNAL: the bus checks our credentials against the uid we name (hex of its decimal digits).
  Uid := UIntToStr(getuid);
  Auth := '';
  for I := 1 to Length(Uid) do
    Auth := Auth + IntToHex(Ord(Uid[I]), 2);
  try
    SendBytes(TEncoding.ASCII.GetBytes(#0 + 'AUTH EXTERNAL ' + Auth + #13#10));
    Line := ReadLine;
  except
    on E: EDBusCancelled do
      raise;
    on E: EDBusError do
      raise EDBusUnavailable.Create('session bus authentication: ' + E.Message);
  end;
  if not Line.StartsWith('OK ') then
    raise EDBusUnavailable.Create('the session bus refused the EXTERNAL authentication: ' + Line);
  SendBytes(TEncoding.ASCII.GetBytes('BEGIN'#13#10));
  Reply := Call('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'Hello', []);
  try
    if (Reply.Body.Count <> 1) or (Reply.Body[0].Signature <> 's') then
      raise EDBusError.Create('Invalid D-Bus Hello response');
    FUniqueName := Reply.Body[0].Text;
  finally
    Reply.Free;
  end;
end;

destructor TDBusConnection.Destroy;
begin
  CloseFd(FFd);
  FWanted.Free;
  FSignals.Free;
  inherited;
end;

procedure TDBusConnection.Connect(const Address: string);
var
  Entry, Error: string;
  Name: UTF8String;
  Abstract: Boolean;
begin
  // The entries of an address are alternatives, tried in order.
  Error := 'no Unix socket in the address';
  for Entry in Address.Split([';']) do
    if UnixSocketOf(Entry.Trim, Name, Abstract) then
    begin
      FFd := ConnectUnix(Name, Abstract, Error);
      if FFd >= 0 then
        Exit;
    end;
  raise EDBusUnavailable.Create('cannot connect to the session bus "' + Address + '": ' + Error);
end;

procedure TDBusConnection.StopPumping;
begin
  FPump := nil;
end;

procedure TDBusConnection.Subscribe(const Intf, Member: string);
begin
  if not FWanted.Contains(Intf + '.' + Member) then
    FWanted.Add(Intf + '.' + Member);
end;

procedure TDBusConnection.WaitReadable(TimeoutMs: Integer);
var
  Fd: TPollFd;
begin
  if Assigned(FPump) then
  begin
    if not FPump(FFd, TimeoutMs) then
      raise EDBusCancelled.Create('D-Bus request cancelled');
  end
  else
  begin
    Fd.fd := FFd;
    Fd.events := POLLIN;
    Fd.revents := 0;
    poll(@Fd, 1, TimeoutMs);
  end;
end;

procedure TDBusConnection.SendBytes(const Data: TBytes);
var
  Offset, N: NativeInt;
  Fd: TPollFd;
  Deadline, Left: Int64;
begin
  // The bus reads what it is sent: a full socket buffer is rare and short, so this waits without the pump.
  Offset := 0;
  Deadline := MonotonicMs + 5000;
  while Offset < Length(Data) do
  begin
    N := send(FFd, Data[Offset], Length(Data) - Offset, MSG_DONTWAIT or MSG_NOSIGNAL);
    if N > 0 then
      Inc(Offset, N)
    else if (N < 0) and (errno = EINTR) then
      Continue
    else if (N < 0) and (errno = EAGAIN) then
    begin
      Left := Deadline - MonotonicMs;
      if Left <= 0 then
        raise EDBusTimeout.Create('D-Bus send timeout');
      Fd.fd := FFd;
      Fd.events := POLLOUT;
      Fd.revents := 0;
      poll(@Fd, 1, Integer(Left));
    end
    else
      raise EDBusError.Create('D-Bus socket write failed: ' + SysErrorMessage(errno));
  end;
end;

function TDBusConnection.ReadLine: string;
var
  B: Byte;
  N: NativeInt;
  Deadline, Left: Int64;
begin
  Result := '';
  Deadline := MonotonicMs + 5000;
  repeat
    N := recv(FFd, B, 1, MSG_DONTWAIT);
    if N = 1 then
    begin
      if B = 10 then
        Exit(Result.TrimRight);
      Result := Result + Char(B);
      if Length(Result) > 4096 then
        raise EDBusError.Create('Oversized D-Bus authentication response');
    end
    else if (N < 0) and (errno = EINTR) then
      Continue
    else if (N < 0) and (errno = EAGAIN) then
    begin
      Left := Deadline - MonotonicMs;
      if Left <= 0 then
        raise EDBusTimeout.Create('D-Bus authentication timeout');
      WaitReadable(Integer(Left));
    end
    else
      raise EDBusError.Create('D-Bus authentication socket closed');
  until False;
end;

function TDBusConnection.ExtractMessage: TDBusMessage;
const
  // The types of the header fields 1..9 (PATH, INTERFACE, MEMBER, ERROR_NAME, REPLY_SERIAL, DESTINATION, SENDER,
  // SIGNATURE, UNIX_FDS).
  CFieldTypes: array[1..9] of string = ('o', 's', 's', 's', 'u', 's', 's', 'g', 'u');
var
  Reader: TWireReader;
  BodySize, HeaderSize, BodyAt, Total, StopAt, Index, Code: Integer;
  Frame: TBytes;
  Item: TDBusValue;
  ChildSig: string;
begin
  Result := nil;
  if Length(FInput) < 16 then
    Exit;
  if not (FInput[0] in [Ord('l'), Ord('B')]) or (FInput[3] <> 1) then
    raise EDBusError.Create('Invalid D-Bus message header');
  Reader := TWireReader.Create(FInput, FInput[0] = Ord('l'));
  try
    Reader.Position := 4;
    BodySize := Reader.UIntValue(4);
    Reader.Position := 12;
    HeaderSize := Reader.UIntValue(4);
    if (BodySize < 0) or (HeaderSize < 0) or (BodySize > MaxMessage) or (HeaderSize > MaxMessage) then
      raise EDBusError.Create('Oversized D-Bus message');
    // The header fields array ends where its length says; the body starts at the next 8-byte boundary.
    BodyAt := (16 + HeaderSize + 7) and not 7;
    Total := BodyAt + BodySize;
    if Total > MaxMessage then
      raise EDBusError.Create('Oversized D-Bus message');
    if Length(FInput) < Total then
      Exit;
    Frame := Copy(FInput, 0, Total);
    FInput := Copy(FInput, Total, MaxInt);
    Reader.Data := Frame;
    Result := TDBusMessage.Create;
    try
      Result.Kind := Frame[1];
      Reader.Position := 8;
      Result.Serial := Reader.UIntValue(4);
      Reader.Position := 16;
      StopAt := 16 + HeaderSize;
      while Reader.Position < StopAt do
      begin
        Reader.Align(8);
        if Reader.Position >= StopAt then
          Break;
        Code := Reader.UIntValue(1);
        ChildSig := Reader.Sig;
        CheckSingleType(ChildSig);
        if (Code >= Low(CFieldTypes)) and (Code <= High(CFieldTypes)) and (ChildSig <> CFieldTypes[Code]) then
          raise EDBusError.Create('Invalid D-Bus header field type');
        Item := Reader.Value(ChildSig);
        try
          case Code of
            1:
              Result.Path := Item.Text;
            2:
              Result.Intf := Item.Text;
            3:
              Result.Member := Item.Text;
            4:
              Result.ErrorName := Item.Text;
            5:
              Result.ReplySerial := Item.Number;
            7:
              Result.Sender := Item.Text;
            8:
              Result.Signature := Item.Text;
          end;
        finally
          Item.Free;
        end;
      end;
      if Reader.Position <> StopAt then
        raise EDBusError.Create('Invalid D-Bus header size');
      Reader.Position := BodyAt;
      Index := 1;
      while Index <= Length(Result.Signature) do
      begin
        ChildSig := NextType(Result.Signature, Index);
        Result.Body.Add(Reader.Value(ChildSig));
      end;
      if Reader.Position <> Total then
        raise EDBusError.Create('Invalid D-Bus body size');
    except
      FreeAndNil(Result);
      raise;
    end;
  finally
    Reader.Free;
  end;
end;

function TDBusConnection.Receive(TimeoutMs: Integer): TDBusMessage;
var
  Buffer: array[0..8191] of Byte;
  N: NativeInt;
  OldSize: Integer;
  Deadline, Left: Int64;
begin
  Deadline := MonotonicMs + Max(0, TimeoutMs);
  repeat
    Result := ExtractMessage;
    if Result <> nil then
      Exit;
    N := recv(FFd, Buffer[0], SizeOf(Buffer), MSG_DONTWAIT);
    if N > 0 then
    begin
      OldSize := Length(FInput);
      if OldSize + N > MaxMessage then
        raise EDBusError.Create('D-Bus input limit');
      SetLength(FInput, OldSize + N);
      Move(Buffer[0], FInput[OldSize], N);
    end
    else if (N < 0) and (errno = EINTR) then
      Continue
    else if (N < 0) and (errno = EAGAIN) then
    begin
      Left := Deadline - MonotonicMs;
      if Left <= 0 then
        Exit(nil);
      WaitReadable(Integer(Left));
    end
    else
      raise EDBusError.Create('Session bus connection closed');
  until False;
end;

procedure TDBusConnection.Keep(Msg: TDBusMessage);
begin
  if (Msg.Kind = KindSignal) and FWanted.Contains(Msg.Intf + '.' + Msg.Member) then
  begin
    if FSignals.Count >= MaxPendingSignals then
      FSignals.Delete(0);
    FSignals.Add(Msg);
  end
  else
    // Replies to calls that timed out, unwanted signals, method calls to us (we serve none).
    Msg.Free;
end;

function TDBusConnection.Call(const Destination, Path, Intf, Member: string; const Args: array of TDBusValue;
  TimeoutMs: Integer): TDBusMessage;
var
  Header, Body, Message: TWireWriter;
  Arg: TDBusValue;
  BodySig, ErrorText: string;
  BodyBytes, HeaderBytes: TBytes;
  Serial: Cardinal;
  Reply: TDBusMessage;
  Deadline: Int64;

  procedure Field(Code: Byte; Value: TDBusValue);
  begin
    try
      Header.Align(8);
      Header.ByteValue(Code);
      Header.Sig(Value.Signature);
      Header.Value(Value);
    finally
      Value.Free;
    end;
  end;

begin
  Header := TWireWriter.Create;
  Body := TWireWriter.Create;
  Message := TWireWriter.Create;
  try
    BodySig := '';
    for Arg in Args do
    begin
      BodySig := BodySig + Arg.Signature;
      Body.Value(Arg);
    end;
    BodyBytes := Body.Data;
    Field(1, TDBusValue.Str(Path, 'o'));
    Field(2, TDBusValue.Str(Intf));
    Field(3, TDBusValue.Str(Member));
    Field(6, TDBusValue.Str(Destination));
    if BodySig <> '' then
      Field(8, TDBusValue.Str(BodySig, 'g'));
    // The header fields array is 8-aligned at offset 16; its length excludes the padding before the body.
    HeaderBytes := Header.Data;
    Inc(FSerial);
    if FSerial = 0 then
      Inc(FSerial);
    Serial := FSerial;
    Message.ByteValue(Ord('l'));
    Message.ByteValue(KindMethodCall);
    Message.ByteValue(0);
    Message.ByteValue(1);
    Message.UIntValue(Length(BodyBytes), 4);
    Message.UIntValue(Serial, 4);
    Message.UIntValue(Length(HeaderBytes), 4);
    Message.Raw(HeaderBytes);
    Message.Align(8);
    Message.Raw(BodyBytes);
    SendBytes(Message.Data);
  finally
    Header.Free;
    Body.Free;
    Message.Free;
  end;
  Deadline := MonotonicMs + TimeoutMs;
  repeat
    Reply := Receive(Integer(Max(0, Deadline - MonotonicMs)));
    if Reply = nil then
      raise EDBusTimeout.Create('D-Bus method timeout: ' + Member);
    if (Reply.Kind in [KindReturn, KindError]) and (Reply.ReplySerial = Serial) then
    begin
      if Reply.Kind = KindReturn then
        Exit(Reply);
      try
        ErrorText := Reply.ErrorName;
        if (Reply.Body.Count > 0) and (Reply.Body[0].Signature = 's') then
          ErrorText := ErrorText + ': ' + Reply.Body[0].Text;
        raise EDBusError.CreateRemote(Reply.ErrorName, ErrorText);
      finally
        Reply.Free;
      end;
    end;
    Keep(Reply);
  until False;
end;

procedure TDBusConnection.AddMatch(const Rule: string);
var
  Arg: TDBusValue;
  Reply: TDBusMessage;
begin
  Arg := TDBusValue.Str(Rule);
  try
    Reply := Call('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'AddMatch', [Arg]);
    Reply.Free;
  finally
    Arg.Free;
  end;
end;

function TDBusConnection.WaitSignal(const Path, Intf, Member: string; TimeoutMs: Integer): TDBusMessage;
var
  I: Integer;
  Msg: TDBusMessage;
  Deadline: Int64;
begin
  for I := 0 to FSignals.Count - 1 do
    if (FSignals[I].Path = Path) and (FSignals[I].Intf = Intf) and (FSignals[I].Member = Member) then
      Exit(FSignals.Extract(FSignals[I]));
  Deadline := MonotonicMs + TimeoutMs;
  repeat
    Msg := Receive(Integer(Max(0, Deadline - MonotonicMs)));
    if Msg = nil then
      Exit(nil);
    if (Msg.Kind = KindSignal) and (Msg.Path = Path) and (Msg.Intf = Intf) and (Msg.Member = Member) then
      Exit(Msg);
    Keep(Msg);
  until False;
end;

{$ENDREGION}

end.
