unit Autopilot.Bridge.Socket;

(*============================================================================================================
   2026.06
   www.GabrielMoraru.com
------------------------------------------------------------------------------------------------------------
   - POSIX/Android-only IBridgeTransport implementation using an AF_UNIX abstract-namespace socket
   - Whole body sits behind an IFDEF POSIX gate; on Windows this unit compiles to an empty no-op
   - Shutdown wake via self-pipe trick; non-blocking listener so a RST between select and accept returns EAGAIN
   NOTE: this header uses parenthesis-star comment form — a brace comment would be terminated by any
   compiler directive brace inside it, which destroyed two earlier builds of this unit (HANDOVER footgun 1).
============================================================================================================*)

interface

{$IFDEF POSIX}

uses
  System.Classes, System.SysUtils,
  Posix.Unistd,
  Autopilot.Bridge.Transport;

type
  /// POSIX AF_UNIX abstract-socket transport. All methods except WakeAndStop
  /// run on the bridge worker thread; WakeAndStop runs on the owner thread.
  /// The destructor runs after the worker is joined (worker releases the
  /// transport after `inherited`/WaitFor), so it cannot race the worker.
  TSocketTransport = class(TInterfacedObject, IBridgeTransport)
  strict private
    FEndpoint : String;            // abstract-socket name, e.g. 'Autopilot.12345' (no NUL, no 'localabstract:' prefix)
    FListenFd : Integer;           // -1 until StartListening succeeds; persists across sessions
    FConnFd   : Integer;           // accepted client fd; -1 between sessions
    FWakePipe : TPipeDescriptors;  // self-pipe; ReadDes is select()ed alongside the listener
    FStopping : Boolean;           // set by WakeAndStop before the wake byte
  public
    /// AEndpoint: the abstract name to bind. Callers use 'Autopilot.<pid>' -
    /// per-process and unguessable enough for a debug feature.
    constructor Create(const AEndpoint: String);
    destructor Destroy; override;

    { IBridgeTransport }
    procedure StartListening;
    function  AcceptConnection: Boolean;
    function  ConnectionStream: TStream;
    procedure RecycleConnection;
    procedure WakeAndStop(AWorkerThread: TThread);
    function  EndpointLabel: String;
  end;

{$ENDIF POSIX}

implementation

{$IFDEF POSIX}

uses
  Posix.SysSocket, Posix.SysUn, Posix.SysSelect, Posix.Errno, Posix.Fcntl,
  Autopilot.Bridge.Log;


constructor TSocketTransport.Create(const AEndpoint: String);
begin
  inherited Create;
  FEndpoint := AEndpoint;
  FListenFd := -1;
  FConnFd   := -1;
  FWakePipe.ReadDes  := -1;
  FWakePipe.WriteDes := -1;
end;


destructor TSocketTransport.Destroy;
begin
  // Backstop + normal teardown. Runs after the worker thread exited, so no
  // close-vs-accept race is possible here. The abstract name vanishes from the
  // kernel namespace when the listen fd closes.
  if FConnFd >= 0 then
  begin
    __close(FConnFd);
    FConnFd := -1;
  end;
  if FListenFd >= 0 then
  begin
    __close(FListenFd);
    FListenFd := -1;
  end;
  if FWakePipe.ReadDes >= 0 then
  begin
    __close(FWakePipe.ReadDes);
    FWakePipe.ReadDes := -1;
  end;
  if FWakePipe.WriteDes >= 0 then
  begin
    __close(FWakePipe.WriteDes);
    FWakePipe.WriteDes := -1;
  end;
  inherited;
end;


procedure TSocketTransport.StartListening;
var
  Addr     : sockaddr_un;
  NameBytes: TBytes;
  AddrLen  : socklen_t;
  Err      : Integer;
  Flags    : Integer;
begin
  // The socket listener is created ONCE and survives client sessions (the pipe
  // recreates its instance per session; accept() needs no such recycling).
  if FListenFd >= 0 then exit;

  // The self-pipe is created once and survives even a failed listener attempt,
  // so a WakeAndStop arriving while the worker is in its retry-sleep still has
  // a live write end on the next pass.
  if FWakePipe.ReadDes < 0 then
    if pipe(FWakePipe) <> 0 then
    begin
      Err := errno;
      FWakePipe.ReadDes  := -1;
      FWakePipe.WriteDes := -1;
      raise EOSError.Create('Bridge socket: pipe() failed: ' + IntToStr(Err) + ' (' + SysErrorMessage(Err) + ')');
    end;

  NameBytes := TEncoding.UTF8.GetBytes(FEndpoint);
  // Abstract form: sun_path[0] = NUL, the name in sun_path[1..]. Max name length
  // is therefore UNIX_PATH_MAX-1 bytes. 'Autopilot.<pid>' is tiny; this guards a
  // caller-supplied endpoint.
  if Length(NameBytes) > UNIX_PATH_MAX - 1 then
    raise EArgumentException.Create('Bridge socket: abstract name longer than ' +
                                    IntToStr(UNIX_PATH_MAX - 1) + ' bytes: ' + FEndpoint);
  if Length(NameBytes) = 0 then
    raise EArgumentException.Create('Bridge socket: empty abstract name');

  FListenFd := socket(AF_UNIX, SOCK_STREAM, 0);
  if FListenFd < 0 then
  begin
    Err := errno;
    FListenFd := -1;
    raise EOSError.Create('Bridge socket: socket() failed: ' + IntToStr(Err) + ' (' + SysErrorMessage(Err) + ')');
  end;

  // Non-blocking listener: select() reporting the listener readable does not
  // guarantee accept() won't block - a client that RSTs in between leaves a blocking
  // accept() waiting for the NEXT client, and the self-pipe wake only interrupts
  // select(), not accept() (so shutdown would hang). With O_NONBLOCK that case is
  // EAGAIN and AcceptConnection re-selects. SOCK_NONBLOCK is not defined for the
  // Android RTL target, so set the flag via fcntl. The accepted fd does not inherit
  // O_NONBLOCK on Linux/bionic, so served connections stay blocking for TBridgeWire.
  // A fcntl failure only degrades to the pre-existing blocking behaviour - log and
  // carry on rather than abort the listener.
  Flags := fcntl(FListenFd, F_GETFL);
  if Flags = -1 then
    BridgeLogWarn('bridge', 'fcntl(F_GETFL) failed: ' + IntToStr(errno) + '; listener stays blocking')
  else if fcntl(FListenFd, F_SETFL, Flags or O_NONBLOCK) = -1 then
    BridgeLogWarn('bridge', 'fcntl(F_SETFL,O_NONBLOCK) failed: ' + IntToStr(errno) + '; listener stays blocking');

  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sun_family := AF_UNIX;
  // sun_path[0] stays 0 - that is what makes the name abstract (kernel
  // namespace, auto-cleaned). The addrlen passed to bind must be the REAL
  // occupied length, not SizeOf(sockaddr_un), or the kernel treats the
  // trailing zeros as part of the name and `adb forward localabstract:<name>`
  // never matches.
  Move(NameBytes[0], Addr.sun_path[1], Length(NameBytes));
  AddrLen := socklen_t(SizeOf(sa_family_t) + 1 + Length(NameBytes));

  if bind(FListenFd, Psockaddr(@Addr)^, AddrLen) <> 0 then
  begin
    Err := errno;
    __close(FListenFd);
    FListenFd := -1;
    // EADDRINUSE = another instance of this exe already owns the name - the
    // same loud rejection FILE_FLAG_FIRST_PIPE_INSTANCE gives on Windows.
    raise EOSError.Create('Bridge socket: bind(@' + FEndpoint + ') failed: ' + IntToStr(Err) + ' (' + SysErrorMessage(Err) + ')');
  end;

  if listen(FListenFd, 1) <> 0 then
  begin
    Err := errno;
    __close(FListenFd);
    FListenFd := -1;
    raise EOSError.Create('Bridge socket: listen() failed: ' + IntToStr(Err) + ' (' + SysErrorMessage(Err) + ')');
  end;

  BridgeLogInfo('bridge', 'abstract socket listening @' + FEndpoint);
end;


function TSocketTransport.AcceptConnection: Boolean;
var
  ReadSet : fd_set;
  MaxFd   : Integer;
  Rc      : Integer;
  Err     : Integer;
  Peer    : sockaddr;
  PeerLen : socklen_t;
  WakeByte: Byte;
begin
  if FStopping then exit(FALSE);

  // Outer loop so a non-blocking accept() that comes up empty re-arms select()
  // rather than failing the call. Because the listen fd is non-blocking (see
  // StartListening), a client that RSTs between select() readiness and accept()
  // surfaces as EAGAIN here; we loop back to select() instead of blocking - which a
  // blocking accept() would do until the next client, beyond the self-pipe wake's
  // reach. The accepted fd stays blocking (not inherited on Linux/bionic).
  while TRUE do
  begin
    if FStopping then exit(FALSE);

    // Park in select() on {listener, self-pipe}. The self-pipe readying is the
    // clean shutdown signal - no phantom connection to filter, unlike the
    // Windows self-connect wake. (No Posix.Poll binding exists in the D13 RTL;
    // select() over 2 fds is equivalent here.)
    repeat
      __FD_ZERO(ReadSet);
      __FD_SET(FListenFd, ReadSet);
      __FD_SET(FWakePipe.ReadDes, ReadSet);
      MaxFd := FListenFd;
      if FWakePipe.ReadDes > MaxFd then
        MaxFd := FWakePipe.ReadDes;
      Rc := select(MaxFd + 1, @ReadSet, NIL, NIL, NIL);
    until (Rc >= 0) or (errno <> EINTR);

    if Rc < 0 then
    begin
      Err := errno;
      BridgeLogWarn('bridge', 'select() failed: ' + IntToStr(Err) + ' (' + SysErrorMessage(Err) + ')');
      exit(FALSE);   // worker retries off Terminated
    end;

    if __FD_ISSET(FWakePipe.ReadDes, ReadSet) then
    begin
      // Drain the wake byte so a (theoretical) spurious wake doesn't hot-loop
      // the next select; WakeAndStop always sets FStopping before writing.
      __read(FWakePipe.ReadDes, @WakeByte, 1);
      exit(FALSE);
    end;

    PeerLen := SizeOf(Peer);
    repeat
      FConnFd := accept(FListenFd, Peer, PeerLen);
    until (FConnFd >= 0) or (errno <> EINTR);

    if FConnFd >= 0 then Break;   // a real client is connected

    // accept() failed with no client. EAGAIN/EWOULDBLOCK = the pending connection
    // vanished between select() and accept() (or a spurious readiness) - re-arm
    // select() rather than treat it as a hard failure. Any other errno is transient:
    // return FALSE and let the worker loop back through StartListening.
    Err := errno;
    FConnFd := -1;
    if (Err = EAGAIN) or (Err = EWOULDBLOCK) then Continue;
    BridgeLogWarn('bridge', 'accept() failed: ' + IntToStr(Err) + ' (' + SysErrorMessage(Err) + ')');
    exit(FALSE);
  end;

  // Quirk-contract #3 backstop: a real client can land between Terminate and
  // WakeAndStop; the worker re-checks Terminated after we return TRUE.
  if FStopping then
  begin
    __close(FConnFd);
    FConnFd := -1;
    exit(FALSE);
  end;

  Result := TRUE;
end;


function TSocketTransport.ConnectionStream: TStream;
begin
  // THandleStream does not close the fd; the transport still owns it. On POSIX
  // its Read/Write map to __read/__write, which work on socket fds.
  Result := THandleStream.Create(THandle(FConnFd));
end;


procedure TSocketTransport.RecycleConnection;
begin
  if FConnFd >= 0 then
  begin
    __close(FConnFd);
    FConnFd := -1;
  end;
  // The listener stays alive - the next AcceptConnection just select()s again.
end;


procedure TSocketTransport.WakeAndStop(AWorkerThread: TThread);
var
  WakeByte: Byte;
begin
  // AWorkerThread is unused here - it exists for the pipe transport's
  // CancelSynchronousIo. The self-pipe needs no thread targeting.
  FStopping := TRUE;   // FIRST, so the woken AcceptConnection sees it
  WakeByte := 0;
  if FWakePipe.WriteDes >= 0 then
    __write(FWakePipe.WriteDes, @WakeByte, 1);
  // Close NOTHING here: the worker may sit anywhere between select() and
  // accept(); fds close in Destroy, after the thread join.
end;


function TSocketTransport.EndpointLabel: String;
begin
  Result := FEndpoint;
end;

{$ENDIF POSIX}

end.
