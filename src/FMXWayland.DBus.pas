{ FMXWayland: a small D-Bus client over Unix sockets, using only Delphi RTL. MIT license. }
unit FMXWayland.DBus;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections;

type
  EDBusError = class(Exception)
  public
    RemoteName: string;
    constructor CreateRemote(const Name, Message: string);
  end;
  EDBusUnavailable = class(EDBusError);
  EDBusTimeout = class(EDBusError);
  EDBusCancelled = class(EDBusError);

  TDBusValue = class
  public
    Signature, Text: string;
    Number: UInt64;
    Bytes: TBytes;
    Children: TObjectList<TDBusValue>;
    constructor Create(const ASignature: string);
    destructor Destroy; override;
    function Clone: TDBusValue;
    function Item(const Key: string): TDBusValue;
    procedure AddOption(const Key: string; Value: TDBusValue);
    class function Str(const Value: string; const Sig: string = 's'): TDBusValue; static;
    class function UInt(Value: Cardinal): TDBusValue; static;
    class function Bool(Value: Boolean): TDBusValue; static;
    class function ByteArray(const Value: TBytes): TDBusValue; static;
  end;

  TDBusMessage = class
  public
    Kind: Byte;
    Serial, ReplySerial: Cardinal;
    Path, Intf, Member, ErrorName, Signature: string;
    Body: TObjectList<TDBusValue>;
    constructor Create;
    destructor Destroy; override;
  end;

  TDBusConnection = class
  private
    FFd: Integer;
    FSerial: Cardinal;
    FInput: TBytes;
    FSignals: TObjectList<TDBusMessage>;
    FUniqueName: string;
    FPump: TFunc<Boolean>;
    procedure Pump;
    procedure SendBytes(const Data: TBytes);
    function ReadLine: string;
    function Receive(Timeout: Integer): TDBusMessage;
    function ExtractMessage: TDBusMessage;
  public
    constructor Create(const APump: TFunc<Boolean> = nil);
    destructor Destroy; override;
    function Call(const Destination, Path, Intf, Member: string; const Args: array of TDBusValue;
      Timeout: Integer = 5000): TDBusMessage;
    procedure AddMatch(const Rule: string);
    procedure StopPumping; // Cleanup may need to close a portal request after the application pump stopped.
    function WaitSignal(const Path, Intf, Member: string; Timeout: Integer): TDBusMessage;
    property UniqueName: string read FUniqueName;
  end;

function FindSessionBus: string;

implementation

uses
  System.IOUtils, System.Math, Posix.SysSocket, Posix.Unistd, Posix.Errno,
  FMXWayland.Posix;

const
  MaxMessage = 8 * 1024 * 1024;
  MsgDontWait = $40;
  MsgNoSignal = $4000;

type
  TUnixAddress = packed record
    Family: Word;
    Name: array[0..107] of AnsiChar;
  end;

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
  case Sig[1] of
    'y', 'g', 'v': Result := 1;
    'n', 'q': Result := 2;
    'b', 'i', 'u', 's', 'o', 'a': Result := 4;
    'x', 't', 'd', '(', '{': Result := 8;
  else
    raise EDBusError.Create('Unsupported D-Bus type: ' + Sig);
  end;
end;

constructor EDBusError.CreateRemote(const Name, Message: string);
begin
  inherited Create(Message);
  RemoteName := Name;
end;

function NextType(const Sig: string; var Index: Integer): string;
var
  Start: Integer;
  Terminator: Char;
begin
  if (Index < 1) or (Index > Length(Sig)) then
    raise EDBusError.Create('Incomplete D-Bus signature');
  Start := Index;
  case Sig[Index] of
    'a': begin Inc(Index); NextType(Sig, Index); end;
    '(', '{':
      begin
        if Sig[Index] = '(' then Terminator := ')' else Terminator := '}';
        Inc(Index);
        while (Index <= Length(Sig)) and (Sig[Index] <> Terminator) do NextType(Sig, Index);
        if Index > Length(Sig) then raise EDBusError.Create('Unclosed D-Bus container');
        Inc(Index);
      end;
    'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'v': Inc(Index);
  else
    raise EDBusError.Create('Invalid D-Bus signature');
  end;
  Result := Copy(Sig, Start, Index - Start);
end;

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
  for Child in Children do Result.Children.Add(Child.Clone);
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
      while (Result.Signature = 'v') and (Result.Children.Count = 1) do Result := Result.Children[0];
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
  while Stream.Position mod Boundary <> 0 do ByteValue(0);
end;

procedure TWireWriter.UIntValue(Value: UInt64; Count: Integer);
var
  I: Integer;
begin
  for I := 0 to Count - 1 do ByteValue(Byte(Value shr (8 * I)));
end;

procedure TWireWriter.Raw(const Data: TBytes);
begin
  if Length(Data) > 0 then Stream.WriteBuffer(Data[0], Length(Data));
end;

procedure TWireWriter.Sig(const Value: string);
var
  Bytes: TBytes;
begin
  Bytes := TEncoding.ASCII.GetBytes(Value);
  if Length(Bytes) > 255 then raise EDBusError.Create('D-Bus signature is too long');
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
    'y': UIntValue(Item.Number, 1);
    'n', 'q': UIntValue(Item.Number, 2);
    'b', 'i', 'u': UIntValue(Item.Number, 4);
    'x', 't', 'd': UIntValue(Item.Number, 8);
    's', 'o':
      begin
        if Item.Text.Contains(#0) then raise EDBusError.Create('NUL in D-Bus string');
        Bytes := TEncoding.UTF8.GetBytes(Item.Text);
        UIntValue(Length(Bytes), 4);
        Raw(Bytes);
        ByteValue(0);
      end;
    'g': Sig(Item.Text);
    'v':
      begin
        if Item.Children.Count <> 1 then raise EDBusError.Create('Invalid D-Bus variant');
        Sig(Item.Children[0].Signature);
        Value(Item.Children[0]);
      end;
    'a':
      begin
        SizeAt := Stream.Position;
        UIntValue(0, 4);
        Align(Alignment(Copy(Item.Signature, 2, MaxInt)));
        StartAt := Stream.Position;
        if Item.Signature = 'ay' then Raw(Item.Bytes)
        else for Child in Item.Children do Value(Child);
        EndAt := Stream.Position;
        Stream.Position := SizeAt;
        UIntValue(EndAt - StartAt, 4);
        Stream.Position := EndAt;
      end;
    '(', '{': for Child in Item.Children do Value(Child);
  end;
end;

function TWireWriter.Data: TBytes;
begin
  SetLength(Result, Stream.Size);
  if Stream.Size > 0 then Move(Stream.Memory^, Result[0], Stream.Size);
end;

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
    if Little then Shift := I * 8 else Shift := (Count - 1 - I) * 8;
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
  if UIntValue(1) <> 0 then raise EDBusError.Create('Unterminated D-Bus signature');
end;

function TWireReader.Value(const Signature: string): TDBusValue;
var
  Count, StopAt, Index: Integer;
  ChildSig: string;
begin
  Inc(Depth);
  if Depth > 32 then raise EDBusError.Create('D-Bus container nesting limit');
  Align(Alignment(Signature));
  Result := TDBusValue.Create(Signature);
  try
    try
      case Signature[1] of
        'y': Result.Number := UIntValue(1);
        'n', 'q': Result.Number := UIntValue(2);
        'b', 'i', 'u': Result.Number := UIntValue(4);
        'x', 't', 'd': Result.Number := UIntValue(8);
        's', 'o':
          begin
            Count := UIntValue(4);
            Require(Count + 1);
            Result.Text := TEncoding.UTF8.GetString(Data, Position, Count);
            Inc(Position, Count);
            if UIntValue(1) <> 0 then raise EDBusError.Create('Unterminated D-Bus string');
          end;
        'g': Result.Text := Sig;
        'v': Result.Children.Add(Value(Sig));
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
              while Position < StopAt do Result.Children.Add(Value(ChildSig));
            if Position <> StopAt then raise EDBusError.Create('Invalid D-Bus array size');
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
      end;
    except
      Result.Free;
      raise;
    end;
  finally
    Dec(Depth);
  end;
end;

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
      if I + 2 >= Length(B) then raise EDBusError.Create('Invalid D-Bus address escape');
      N := StrToIntDef('$' + Char(B[I + 1]) + Char(B[I + 2]), -1);
      if N < 0 then raise EDBusError.Create('Invalid D-Bus address escape');
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

function FindSessionBus: string;
var
  Candidate, Directory, FileName, Line: string;
begin
  Result := GetEnvironmentVariable('DBUS_SESSION_BUS_ADDRESS');
  if Result <> '' then Exit;
  Candidate := '/run/user/' + UIntToStr(getuid) + '/bus';
  if FileExists(Candidate) then Exit('unix:path=' + Candidate);
  // WSL without systemd commonly has an X11-autolaunched bus. Read its address, never execute the cache file.
  Directory := TPath.Combine(GetEnvironmentVariable('HOME'), '.dbus/session-bus');
  if DirectoryExists(Directory) then
    for FileName in TDirectory.GetFiles(Directory) do
      if TFile.GetSize(FileName) < 65536 then
        for Line in TFile.ReadAllLines(FileName, TEncoding.UTF8) do
          if Line.StartsWith('DBUS_SESSION_BUS_ADDRESS=') then
          begin
            Result := Copy(Line, Length('DBUS_SESSION_BUS_ADDRESS=') + 1, MaxInt).Trim;
            if (Length(Result) >= 2) and (Result[1] = #39) and (Result[Length(Result)] = #39) then
              Result := Copy(Result, 2, Length(Result) - 2);
            if Result.StartsWith('unix:') then Exit;
          end;
  raise EDBusUnavailable.Create('FMXWayland: no session bus; set DBUS_SESSION_BUS_ADDRESS');
end;

procedure TDBusConnection.Pump;
begin
  if Assigned(FPump) and not FPump() then raise EDBusCancelled.Create('D-Bus request cancelled');
end;

procedure TDBusConnection.StopPumping;
begin
  FPump := nil;
end;

constructor TDBusConnection.Create(const APump: TFunc<Boolean>);
var
  Address, Entry, Part, Value, Uid, Auth: string;
  Name: UTF8String;
  Addr: TUnixAddress;
  AddrLen, I: Integer;
  Abstract: Boolean;
  Reply: TDBusMessage;
begin
  inherited Create;
  FFd := -1;
  FPump := APump;
  FSignals := TObjectList<TDBusMessage>.Create(True);
  Address := FindSessionBus;
  Value := '';
  Abstract := False;
  for Entry in Address.Split([';']) do
    if Entry.StartsWith('unix:') then
    begin
      for Part in Copy(Entry, 6, MaxInt).Split([',']) do
        if Part.StartsWith('path=') then Value := Copy(Part, 6, MaxInt)
        else if Part.StartsWith('abstract=') then
        begin
          Value := Copy(Part, 10, MaxInt);
          Abstract := True;
        end;
      if Value <> '' then Break;
    end;
  if Value = '' then raise EDBusUnavailable.Create('FMXWayland: session bus needs a Unix socket');
  Name := DecodeAddress(Value);
  if (Length(Name) = 0) or (Length(Name) > 106) then raise EDBusError.Create('Invalid D-Bus socket path');
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
  FFd := socket(AF_UNIX, SOCK_STREAM or O_CLOEXEC, 0);
  if (FFd < 0) or (connect(FFd, PSockAddr(@Addr)^, AddrLen) <> 0) then
    raise EDBusUnavailable.Create('FMXWayland: cannot connect to the session bus: ' + SysErrorMessage(errno));
  Uid := UIntToStr(getuid);
  Auth := '';
  for I := 1 to Length(Uid) do Auth := Auth + IntToHex(Ord(Uid[I]), 2);
  SendBytes(TEncoding.ASCII.GetBytes(#0 + 'AUTH EXTERNAL ' + Auth + #13#10));
  if not ReadLine.StartsWith('OK ') then raise EDBusError.Create('Session bus rejected EXTERNAL authentication');
  SendBytes(TEncoding.ASCII.GetBytes('BEGIN'#13#10));
  Reply := Call('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'Hello', []);
  try
    if Reply.Body.Count <> 1 then raise EDBusError.Create('Invalid D-Bus Hello response');
    FUniqueName := Reply.Body[0].Text;
  finally
    Reply.Free;
  end;
end;

destructor TDBusConnection.Destroy;
begin
  CloseFd(FFd);
  FSignals.Free;
  inherited;
end;

procedure TDBusConnection.SendBytes(const Data: TBytes);
var
  Offset, N: NativeInt;
  Fd: TPollFd;
  Deadline: Int64;
begin
  Offset := 0;
  Deadline := MonotonicMs + 5000;
  while Offset < Length(Data) do
  begin
    N := send(FFd, Data[Offset], Length(Data) - Offset, MsgDontWait or MsgNoSignal);
    if N > 0 then Inc(Offset, N)
    else if (N < 0) and (errno in [EAGAIN, EINTR]) then
    begin
      Pump;
      if MonotonicMs >= Deadline then raise EDBusTimeout.Create('D-Bus send timeout');
      Fd.fd := FFd; Fd.events := POLLOUT; Fd.revents := 0;
      poll(@Fd, 1, 20);
    end
    else raise EDBusError.Create('D-Bus socket write failed');
  end;
end;

function TDBusConnection.ReadLine: string;
var
  B: Byte;
  N: NativeInt;
  Fd: TPollFd;
  Deadline: Int64;
begin
  Result := '';
  Deadline := MonotonicMs + 5000;
  repeat
    N := recv(FFd, B, 1, MsgDontWait);
    if N = 1 then
    begin
      if B = 10 then Exit(Result.TrimRight);
      Result := Result + Char(B);
      if Length(Result) > 4096 then raise EDBusError.Create('Oversized D-Bus authentication response');
    end
    else if (N < 0) and (errno in [EAGAIN, EINTR]) then
    begin
      Pump;
      if MonotonicMs >= Deadline then raise EDBusTimeout.Create('D-Bus authentication timeout');
      Fd.fd := FFd; Fd.events := POLLIN; Fd.revents := 0;
      poll(@Fd, 1, 20);
    end
    else raise EDBusError.Create('D-Bus authentication socket closed');
  until False;
end;

function TDBusConnection.ExtractMessage: TDBusMessage;
var
  Reader: TWireReader;
  BodySize, HeaderSize, BodyAt, Total, StopAt, Index, Code: Integer;
  Frame: TBytes;
  Item: TDBusValue;
  ChildSig: string;
begin
  Result := nil;
  if Length(FInput) < 16 then Exit;
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
    BodyAt := (16 + HeaderSize + 7) and not 7;
    Total := BodyAt + BodySize;
    if Total > MaxMessage then raise EDBusError.Create('Oversized D-Bus message');
    if Length(FInput) < Total then Exit;
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
        if Reader.Position >= StopAt then Break;
        Code := Reader.UIntValue(1);
        ChildSig := Reader.Sig;
        Item := Reader.Value(ChildSig);
        try
          case Code of
            1: Result.Path := Item.Text;
            2: Result.Intf := Item.Text;
            3: Result.Member := Item.Text;
            4: Result.ErrorName := Item.Text;
            5: Result.ReplySerial := Item.Number;
            8: Result.Signature := Item.Text;
          end;
        finally
          Item.Free;
        end;
      end;
      if Reader.Position <> StopAt then raise EDBusError.Create('Invalid D-Bus header size');
      Reader.Position := BodyAt;
      Index := 1;
      while Index <= Length(Result.Signature) do
      begin
        ChildSig := NextType(Result.Signature, Index);
        Result.Body.Add(Reader.Value(ChildSig));
      end;
      if Reader.Position <> Total then raise EDBusError.Create('Invalid D-Bus body size');
    except
      FreeAndNil(Result);
      raise;
    end;
  finally
    Reader.Free;
  end;
end;

function TDBusConnection.Receive(Timeout: Integer): TDBusMessage;
var
  Buffer: array[0..8191] of Byte;
  N: NativeInt;
  OldSize: Integer;
  Fd: TPollFd;
  Deadline: Int64;
begin
  Deadline := MonotonicMs + Timeout;
  repeat
    Result := ExtractMessage;
    if Result <> nil then Exit;
    N := recv(FFd, Buffer[0], SizeOf(Buffer), MsgDontWait);
    if N > 0 then
    begin
      OldSize := Length(FInput);
      if OldSize + N > MaxMessage then raise EDBusError.Create('D-Bus input limit');
      SetLength(FInput, OldSize + N);
      Move(Buffer[0], FInput[OldSize], N);
    end
    else if (N < 0) and (errno in [EAGAIN, EINTR]) then
    begin
      if MonotonicMs >= Deadline then Exit(nil);
      Pump;
      Fd.fd := FFd; Fd.events := POLLIN; Fd.revents := 0;
      poll(@Fd, 1, Min(20, Max(0, Integer(Deadline - MonotonicMs))));
    end
    else raise EDBusError.Create('Session bus connection closed');
  until False;
end;

function TDBusConnection.Call(const Destination, Path, Intf, Member: string; const Args: array of TDBusValue;
  Timeout: Integer): TDBusMessage;
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
    if BodySig <> '' then Field(8, TDBusValue.Str(BodySig, 'g'));
    HeaderBytes := Header.Data;
    Inc(FSerial);
    Serial := FSerial;
    Message.ByteValue(Ord('l'));
    Message.ByteValue(1);
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
  Deadline := MonotonicMs + Timeout;
  repeat
    Reply := Receive(Min(50, Max(0, Integer(Deadline - MonotonicMs))));
    if Reply <> nil then
    begin
      if (Reply.Kind in [2, 3]) and (Reply.ReplySerial = Serial) then
      begin
        if Reply.Kind = 2 then Exit(Reply);
        try
          ErrorText := Reply.ErrorName;
          if Reply.Body.Count > 0 then ErrorText := ErrorText + ': ' + Reply.Body[0].Text;
          raise EDBusError.CreateRemote(Reply.ErrorName, ErrorText);
        finally Reply.Free; end;
      end;
      if Reply.Kind = 4 then
      begin
        if FSignals.Count >= 64 then
        begin
          Reply.Free;
          raise EDBusError.Create('D-Bus pending signal limit');
        end;
        FSignals.Add(Reply);
      end
      else Reply.Free;
    end;
    if MonotonicMs >= Deadline then raise EDBusTimeout.Create('D-Bus method timeout: ' + Member);
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

function TDBusConnection.WaitSignal(const Path, Intf, Member: string; Timeout: Integer): TDBusMessage;
var
  I: Integer;
  Reply: TDBusMessage;
  Deadline: Int64;
begin
  Deadline := MonotonicMs + Timeout;
  repeat
    for I := 0 to FSignals.Count - 1 do
      if (FSignals[I].Path = Path) and (FSignals[I].Intf = Intf) and (FSignals[I].Member = Member) then
        Exit(FSignals.Extract(FSignals[I]));
    Reply := Receive(Min(50, Max(0, Integer(Deadline - MonotonicMs))));
    if Reply <> nil then
    begin
      if (Reply.Kind = 4) and (Reply.Path = Path) and (Reply.Intf = Intf) and (Reply.Member = Member) then Exit(Reply);
      Reply.Free;
    end;
    if MonotonicMs >= Deadline then Exit(nil);
  until False;
end;

end.
