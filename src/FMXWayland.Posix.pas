{ FMXWayland: native Wayland platform for Delphi FireMonkey on Linux.
  Copyright (c) 2026 Fasday. MIT license, see LICENSE. }

/// <summary>The few C library functions FMXWayland needs that Delphi's Posix units do not declare (poll, eventfd,
/// pipe2, memfd_create), plus small helpers: monotonic milliseconds, anonymous shared-memory files, blocking-safe
/// reads and writes.</summary>
unit FMXWayland.Posix;

interface

uses
  Posix.Base;

type
  /// <summary>struct pollfd.</summary>
  TPollFd = record
    fd: Integer;
    events: Int16;
    revents: Int16;
  end;
  PPollFd = ^TPollFd;

const
  POLLIN = $001;
  POLLOUT = $004;
  POLLERR = $008;
  POLLHUP = $010;
  POLLNVAL = $020;
  O_CLOEXEC = $80000;
  EFD_CLOEXEC = O_CLOEXEC;
  EFD_NONBLOCK = $800;

/// <summary>poll(2).</summary>
function poll(AFds: PPollFd; ANfds: NativeUInt; ATimeout: Integer): Integer; cdecl; external libc name 'poll';
/// <summary>eventfd(2).</summary>
function eventfd(AInitVal: Cardinal; AFlags: Integer): Integer; cdecl; external libc name 'eventfd';
/// <summary>pipe2(2).</summary>
function pipe2(AFds: PInteger; AFlags: Integer): Integer; cdecl; external libc name 'pipe2';

/// <summary>Milliseconds of CLOCK_MONOTONIC.</summary>
function MonotonicMs: Int64;
/// <summary>An anonymous file of ASize bytes for shared memory (memfd_create, or an unlinked file in
/// XDG_RUNTIME_DIR on old systems); -1 on failure.</summary>
function CreateAnonymousFile(const ASize: NativeInt): Integer;
/// <summary>Closes a file descriptor (ignores -1).</summary>
procedure CloseFd(var AFd: Integer);
/// <summary>Writes all of ABuffer (retries on EINTR/partial writes, waits with poll on EAGAIN); False on error.
/// </summary>
function WriteAll(const AFd: Integer; ABuffer: Pointer; ASize: NativeInt): Boolean;
/// <summary>Ignores SIGPIPE (a clipboard reader that goes away must not kill the program).</summary>
procedure IgnoreSigPipe;

implementation

uses
  System.SysUtils, Posix.Time, Posix.Unistd, Posix.Errno, Posix.Stdlib, Posix.Dlfcn, Posix.Signal;

function MonotonicMs: Int64;
var
  T: timespec;
begin
  clock_gettime(CLOCK_MONOTONIC, @T);
  Result := Int64(T.tv_sec) * 1000 + T.tv_nsec div 1000000;
end;

type
  TMemfdCreate = function(AName: PAnsiChar; AFlags: Cardinal): Integer; cdecl;

var
  GMemfdCreate: TMemfdCreate = nil;
  GMemfdChecked: Boolean = False;

function CreateAnonymousFile(const ASize: NativeInt): Integer;
const
  MFD_CLOEXEC = 1;
var
  Dir: string;
  Template: TBytes;
  Lib: NativeUInt;
begin
  if not GMemfdChecked then
  begin
    GMemfdChecked := True;
    Lib := dlopen('libc.so.6', RTLD_LAZY);
    if Lib <> 0 then
      @GMemfdCreate := dlsym(Lib, 'memfd_create');
  end;
  Result := -1;
  if Assigned(GMemfdCreate) then
    Result := GMemfdCreate('fmxwayland-shm', MFD_CLOEXEC);
  if Result < 0 then
  begin
    Dir := GetEnvironmentVariable('XDG_RUNTIME_DIR');
    if Dir = '' then
      Dir := '/tmp';
    Template := TEncoding.UTF8.GetBytes(Dir + '/fmxwayland-shm-XXXXXX');
    SetLength(Template, Length(Template) + 1);
    Template[High(Template)] := 0;
    Result := mkstemp(@Template[0]);
    if Result >= 0 then
      unlink(@Template[0]);
  end;
  if Result < 0 then
    Exit;
  if ftruncate(Result, ASize) <> 0 then
  begin
    __close(Result);
    Result := -1;
  end;
end;

procedure CloseFd(var AFd: Integer);
begin
  if AFd >= 0 then
    __close(AFd);
  AFd := -1;
end;

function WriteAll(const AFd: Integer; ABuffer: Pointer; ASize: NativeInt): Boolean;
var
  P: PByte;
  N: NativeInt;
  Fd: TPollFd;
begin
  P := ABuffer;
  while ASize > 0 do
  begin
    N := __write(AFd, P, ASize);
    if N < 0 then
    begin
      if errno = EINTR then
        Continue;
      if errno = EAGAIN then
      begin
        Fd.fd := AFd;
        Fd.events := POLLOUT;
        Fd.revents := 0;
        if poll(@Fd, 1, 2000) <= 0 then
          Exit(False);
        Continue;
      end;
      Exit(False);
    end;
    Inc(P, N);
    Dec(ASize, N);
  end;
  Result := True;
end;

procedure IgnoreSigPipe;
begin
  signal(SIGPIPE, TSignalHandler(SIG_IGN));
end;

end.
