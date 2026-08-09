UNIT Autopilot.Bridge.Socket;

(*=====================================================
   2026.06.20 - listener socket set non-blocking so accept() can never block after
                select() reported the listener readable. A client that RSTs in the
                window between select() and accept() now surfaces as EAGAIN and we
                re-arm select(), instead of accept() blocking until the NEXT client
                where the self-pipe shutdown wake could not reach it. See
                AcceptConnection + StartListening.
   2026.06.11
   GabrielMoraru.com / SciVance Tech

   ANDROID / POSIX only - the whole body sits behind an IFDEF POSIX gate,
   so on Windows this unit compiles to an empty no-op.

   POSIX socket transport for the Autopilot bridge - the device-side half of
   " Plans\05_AndroidTransport.md". The FMX app LISTENS on an AF_UNIX
   ABSTRACT-namespace socket; the PC-side MCP server reaches it over USB via

       adb forward tcp:<hostPort> localabstract:<EndpointLabel>

   and connects to 127.0.0.1:<hostPort> with the same hello/helloAck +
   length-prefix framing as the Windows pipe (verified: localabstract: is a
   documented adb-forward REMOTE form; Chrome remote debugging uses it).

   Why an abstract socket instead of loopback TCP (decision 2026-06-03):
     - no INTERNET manifest permission (the AF_INET "paranoid network" gid
       check does not apply to AF_UNIX);
     - no TCP port collisions, and the kernel removes the name when the
       socket closes - no stale discovery file, ever (better than %TEMP%);
     - byte-stream semantics identical to the pipe, so TBridgeWire and the
       whole dispatcher are unchanged.

   Connection stream: a plain THandleStream over the accepted fd -
   THandleStream.Read/Write -> FileRead/FileWrite -> __read/__write
   (System.SysUtils:9985/9996), which are valid on socket fds. The worker
   frees the stream; this transport owns the fd.

   Shutdown wake: the self-pipe trick. AcceptConnection parks in select() on
   {listen fd, wake-pipe read end}; WakeAndStop writes one byte. WakeAndStop
   deliberately closes NOTHING - closing a fd raced against an in-flight
   accept()/select() is exactly the class of bug the Windows wake fought; all
   fds close in the destructor, which runs only after the worker thread has
   been joined (see TBridgeWorker.Destroy).

   NOTE for maintainers: this header deliberately uses the parenthesis-star
   comment form and never spells out a compiler directive or ANY comment
   terminator inside itself. History: the 2026-06-11 Android build failed
   twice on this header alone - first because the old brace-comment header
   mentioned the IFDEF-POSIX directive literally (a brace comment ends at the
   directive's closing brace - HANDOVER footgun #1), then because the fixed
   header described the new comment form with the literal star-parenthesis
   pair, which terminated the comment just the same. The unit was never
   compiled before Phase B (referenced by no Windows project), so these
   landmines sat undetected since the stub was written. Error signature when
   a header self-destructs: E2029 INTERFACE expected, E2052 unterminated
   string, E2038 illegal character - straight quotes from prose suddenly in
   code context; it is NOT a file-encoding problem.

   Security note (accepted for a debug-gated feature): abstract sockets have
   no access control - any local app may connect. Mitigations: the
   per-process unguessable name, the protocolVersion handshake gate, and the
   AUTOPILOT compile guard keeping the bridge out of release builds.
=====================================================*)

INTERFACE

{$IFDEF POSIX}

USES
  System.Classes, System.SysUtils,
  Posix.Unistd,
  Autopilot.Bridge.Transport;

TYPE
  /// POSIX AF_UNIX abstract-socket transport. All methods except WakeAndStop
  /// run on the bridge worker thread; WakeAndStop runs on the owner thread.
  /// The destructor runs after the worker is joined (worker releases the
  /// transport after `inherited`/WaitFor), so it cannot race the worker.
  TSocketTransport = CLASS(TInterfacedObject, IBridgeTransport)
  STRICT PRIVATE
    FEndpoint : String;            // abstract-socket name, e.g. 'Autopilot.12345' (no NUL, no 'localabstract:' prefix)
    FListenFd : Integer;           // -1 until StartListening succeeds; persists across sessions
    FConnFd   : Integer;           // accepted client fd; -1 between sessions
    FWakePipe : TPipeDescriptors;  // self-pipe; ReadDes is select()ed alongside the listener
    FStopping : Boolean;           // set by WakeAndStop before the wake byte
  PUBLIC
    /// AEndpoint: the abstract name to bind. Callers use 'Autopilot.<pid>' -
    /// per-process and unguessable enough for a debug feature.
    CONSTRUCTOR Create(CONST AEndpoint: String);
    DESTRUCTOR Destroy; OVERRIDE;

    { IBridgeTransport }
    PROCEDURE StartListening;
    FUNCTION  AcceptConnection: Boolean;
    FUNCTION  ConnectionStream: TStream;
    PROCEDURE RecycleConnection;
    PROCEDURE WakeAndStop(AWorkerThread: TThread);
    FUNCTION  EndpointLabel: String;
  END;

{$ENDIF POSIX}

IMPLEMENTATION

{$IFDEF POSIX}

USES
  Posix.SysSocket, Posix.SysUn, Posix.SysSelect, Posix.Errno, Posix.Fcntl,
  Autopilot.Bridge.Log;


CONSTRUCTOR TSocketTransport.Create(CONST AEndpoint: String);
BEGIN
  inherited Create;
  FEndpoint := AEndpoint;
  FListenFd := -1;
  FConnFd   := -1;
  FWakePipe.ReadDes  := -1;
  FWakePipe.WriteDes := -1;
END;


DESTRUCTOR TSocketTransport.Destroy;
BEGIN
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
END;


PROCEDURE TSocketTransport.StartListening;
VAR
  Addr     : sockaddr_un;
  NameBytes: TBytes;
  AddrLen  : socklen_t;
  Err      : Integer;
  Flags    : Integer;
BEGIN
  // The socket listener is created ONCE and survives client sessions (the pipe
  // recreates its instance per session; accept() needs no such recycling).
  if FListenFd >= 0 then EXIT;

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

  // Non-blocking listener: select() reporting the listener readable does NOT
  // guarantee accept() won't block - a client that RSTs in between leaves a blocking
  // accept() waiting for the NEXT client, and the self-pipe wake only interrupts
  // select(), not accept() (so shutdown would hang). With O_NONBLOCK that case is
  // EAGAIN and AcceptConnection re-selects. SOCK_NONBLOCK is not defined for the
  // Android RTL target, so set the flag via fcntl. The accepted fd does NOT inherit
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
  // sun_path[0] stays 0 - that is what makes the name ABSTRACT (kernel
  // namespace, auto-cleaned). The addrlen passed to bind must be the REAL
  // occupied length, NOT SizeOf(sockaddr_un), or the kernel treats the
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
END;


FUNCTION TSocketTransport.AcceptConnection: Boolean;
VAR
  ReadSet : fd_set;
  MaxFd   : Integer;
  Rc      : Integer;
  Err     : Integer;
  Peer    : sockaddr;
  PeerLen : socklen_t;
  WakeByte: Byte;
BEGIN
  if FStopping then EXIT(FALSE);

  // Outer loop so a non-blocking accept() that comes up empty re-arms select()
  // rather than failing the call. Because the listen fd is non-blocking (see
  // StartListening), a client that RSTs between select() readiness and accept()
  // surfaces as EAGAIN here; we loop back to select() instead of blocking - which a
  // blocking accept() would do until the next client, beyond the self-pipe wake's
  // reach. The accepted fd stays blocking (not inherited on Linux/bionic).
  WHILE TRUE DO
  BEGIN
    if FStopping then EXIT(FALSE);

    // Park in select() on {listener, self-pipe}. The self-pipe readying is the
    // clean shutdown signal - no phantom connection to filter, unlike the
    // Windows self-connect wake. (No Posix.Poll binding exists in the D13 RTL;
    // select() over 2 fds is equivalent here.)
    REPEAT
      __FD_ZERO(ReadSet);
      __FD_SET(FListenFd, ReadSet);
      __FD_SET(FWakePipe.ReadDes, ReadSet);
      MaxFd := FListenFd;
      if FWakePipe.ReadDes > MaxFd then
        MaxFd := FWakePipe.ReadDes;
      Rc := select(MaxFd + 1, @ReadSet, NIL, NIL, NIL);
    UNTIL (Rc >= 0) or (errno <> EINTR);

    if Rc < 0 then
    begin
      Err := errno;
      BridgeLogWarn('bridge', 'select() failed: ' + IntToStr(Err) + ' (' + SysErrorMessage(Err) + ')');
      EXIT(FALSE);   // worker retries off Terminated
    end;

    if __FD_ISSET(FWakePipe.ReadDes, ReadSet) then
    begin
      // Drain the wake byte so a (theoretical) spurious wake doesn't hot-loop
      // the next select; WakeAndStop always sets FStopping before writing.
      __read(FWakePipe.ReadDes, @WakeByte, 1);
      EXIT(FALSE);
    end;

    PeerLen := SizeOf(Peer);
    REPEAT
      FConnFd := accept(FListenFd, Peer, PeerLen);
    UNTIL (FConnFd >= 0) or (errno <> EINTR);

    if FConnFd >= 0 then Break;   // a real client is connected

    // accept() failed with no client. EAGAIN/EWOULDBLOCK = the pending connection
    // vanished between select() and accept() (or a spurious readiness) - re-arm
    // select() rather than treat it as a hard failure. Any other errno is transient:
    // return FALSE and let the worker loop back through StartListening.
    Err := errno;
    FConnFd := -1;
    if (Err = EAGAIN) or (Err = EWOULDBLOCK) then Continue;
    BridgeLogWarn('bridge', 'accept() failed: ' + IntToStr(Err) + ' (' + SysErrorMessage(Err) + ')');
    EXIT(FALSE);
  END;

  // Quirk-contract #3 backstop: a real client can land between Terminate and
  // WakeAndStop; the worker re-checks Terminated after we return TRUE.
  if FStopping then
  begin
    __close(FConnFd);
    FConnFd := -1;
    EXIT(FALSE);
  end;

  Result := TRUE;
END;


FUNCTION TSocketTransport.ConnectionStream: TStream;
BEGIN
  // THandleStream does NOT close the fd; the transport still owns it. On POSIX
  // its Read/Write map to __read/__write, which work on socket fds.
  Result := THandleStream.Create(THandle(FConnFd));
END;


PROCEDURE TSocketTransport.RecycleConnection;
BEGIN
  if FConnFd >= 0 then
  begin
    __close(FConnFd);
    FConnFd := -1;
  end;
  // The listener stays alive - the next AcceptConnection just select()s again.
END;


PROCEDURE TSocketTransport.WakeAndStop(AWorkerThread: TThread);
VAR
  WakeByte: Byte;
BEGIN
  // AWorkerThread is unused here - it exists for the pipe transport's
  // CancelSynchronousIo. The self-pipe needs no thread targeting.
  FStopping := TRUE;   // FIRST, so the woken AcceptConnection sees it
  WakeByte := 0;
  if FWakePipe.WriteDes >= 0 then
    __write(FWakePipe.WriteDes, @WakeByte, 1);
  // Close NOTHING here: the worker may sit anywhere between select() and
  // accept(); fds close in Destroy, after the thread join.
END;


FUNCTION TSocketTransport.EndpointLabel: String;
BEGIN
  Result := FEndpoint;
END;

{$ENDIF POSIX}

END.
