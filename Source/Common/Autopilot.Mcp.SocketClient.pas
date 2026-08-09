UNIT Autopilot.Mcp.SocketClient;

(*=====================================================
   2026.06.04
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────────────┐
   │  WINDOWS  (PC-side, adb socket client) │   reaches an Android target over `adb forward`
   └──────────────────────────────────────┘

   The MCP-server-side socket twin of Autopilot.Mcp.PipeClient.

   Where PipeClient opens a Win32 named pipe with CreateFileW, this opens a
   loopback TCP socket with connect(127.0.0.1:<port>). Everything past the
   connect is IDENTICAL to the pipe client — the bridge speaks the same
   hello / helloAck handshake and the same length-prefixed TBridgeWire frames
   regardless of transport, because TBridgeWire takes a TStream and ReadFully
   loops on short reads (TCP produces short reads exactly as a byte-mode pipe
   does). So we wrap the socket in a tiny TStream adapter and reuse TBridgeWire
   verbatim.

   The <port> is a HOST loopback port that `adb forward` tunnels over USB to the
   device-side listener (an AF_UNIX abstract socket 'Autopilot.<pid>', or a
   device TCP port). Setting up that forward is Autopilot.Mcp.AdbForward's job;
   this unit only connects to the already-forwarded host port.

   PHASE A SCOPE: this is the PC side and is testable TODAY against any loopback
   listener that speaks the protocol (see Tests.Mcp.SocketClient — a synthetic
   echo listener). The DEVICE side (the bridge's Autopilot.Bridge.Socket body)
   is Phase B and needs the shared worker + a physical device. See
   " Plans\05_AndroidTransport.md".

   No VCL, no FMX, no LightSaber, no Indy. Stdlib + Winsock only.
=====================================================*)

INTERFACE

USES
  Winapi.Windows, Winapi.WinSock2,
  System.SysUtils, System.Classes, System.SyncObjs, System.JSON,
  Autopilot.Bridge.Core;

TYPE
  /// Blocking-socket view as a TStream, so TBridgeWire can frame over it.
  /// Does NOT own the socket — the caller closes it (mirrors THandleStream's
  /// "we still own the handle" contract used by the pipe client).
  TSocketStream = CLASS(TStream)
  STRICT PRIVATE
    FSocket: TSocket;
  PUBLIC
    CONSTRUCTOR Create(ASocket: TSocket);
    FUNCTION Read (VAR Buffer; Count: Longint): Longint; OVERRIDE;
    FUNCTION Write(CONST Buffer; Count: Longint): Longint; OVERRIDE;
    FUNCTION Seek(CONST Offset: Int64; Origin: TSeekOrigin): Int64; OVERRIDE;
  END;


/// Run one round-trip over a loopback TCP socket: connect, read bridge hello,
/// write helloAck, send one command frame, read one response, close.
/// Returns the parsed response object (caller frees) or raises on transport failure.
/// Mirrors Autopilot.Mcp.PipeClient.CallTarget exactly, port for socket.
FUNCTION CallTargetSocket(APort: Word; ARequestJson: TJSONObject; ATimeoutMs: Cardinal = 5000): TJSONObject;


IMPLEMENTATION


{ # Winsock lifecycle }

// Winsock needs WSAStartup once per process before any socket call. We do it
// EXACTLY ONCE, lock-free, and never call WSACleanup — the OS reclaims Winsock
// at process exit, and a never-cleaned single startup removes every teardown
// race (startup/cleanup churn, decrement-on-failure imbalance) that a ref-count
// would introduce. This also drops the INITIALIZATION/FINALISATION block the
// critical-section version needed.
//
// Race-free one-shot via TInterlocked.CompareExchange on a 3-state cell:
//   0 = untouched   1 = a thread is running WSAStartup   2 = ready
// Exactly one thread wins the 0->1 transition and runs WSAStartup; everyone
// else WAITS for state 2 (they do NOT race ahead to socket() before startup
// finished — that was the hazard in a naive Increment-only counter). On failure
// the winner resets the cell to 0 so the next caller retries, and raises.
//
// Why this is safe for our callers AND for future ones: the MCP stdio loop is
// single-threaded today, so contention never actually happens — but unlike the
// counter version, this stays correct if a future parallel dispatcher (or the
// Phase-B worker) ever calls in concurrently. Defensive by construction, not by
// assumption about the caller.

CONST
  WSA_UNTOUCHED = 0;
  WSA_STARTING  = 1;
  WSA_READY     = 2;

VAR
  GWsaState: Integer = WSA_UNTOUCHED;

PROCEDURE EnsureWinsock;
VAR
  Data : TWSAData;
  Rc   : Integer;
BEGIN
  // Fast path: already ready (a plain read is fine — once 2, it never changes).
  if GWsaState = WSA_READY then EXIT;

  if TInterlocked.CompareExchange(GWsaState, WSA_STARTING, WSA_UNTOUCHED) = WSA_UNTOUCHED then
  begin
    // We won the race — we own the one-time startup.
    Rc := WSAStartup($0202, Data);
    if Rc <> 0 then
    begin
      // Let the next caller try again, then surface the failure.
      TInterlocked.Exchange(GWsaState, WSA_UNTOUCHED);
      raise Exception.CreateFmt('WSAStartup failed (code %d)', [Rc]);
    end;
    TInterlocked.Exchange(GWsaState, WSA_READY);
    EXIT;
  end;

  // We lost the race (or another thread is mid-startup). Wait for READY. This
  // spins for the microseconds WSAStartup takes; Yield keeps it cheap. If the
  // winner failed and reset to UNTOUCHED, take over the startup ourselves.
  while GWsaState <> WSA_READY do
  begin
    if GWsaState = WSA_UNTOUCHED then
    begin
      EnsureWinsock;   // winner failed and reset — retry from the top
      EXIT;
    end;
    TThread.Yield;
  end;
END;


{ # TSocketStream }

CONSTRUCTOR TSocketStream.Create(ASocket: TSocket);
BEGIN
  inherited Create;
  FSocket := ASocket;
END;

FUNCTION TSocketStream.Read(VAR Buffer; Count: Longint): Longint;
VAR
  N: Integer;
BEGIN
  if Count <= 0 then EXIT(0);
  N := recv(FSocket, Buffer, Count, 0);
  if N = SOCKET_ERROR then
    raise Exception.CreateFmt('socket recv failed (code %d)', [WSAGetLastError]);
  // N = 0 means the peer closed — surface as 0 so TBridgeWire.ReadFully sees EOF.
  Result := N;
END;

FUNCTION TSocketStream.Write(CONST Buffer; Count: Longint): Longint;
VAR
  Sent, N: Integer;
  P: PByte;
BEGIN
  // send() may write fewer bytes than asked — loop until the whole buffer goes
  // out, the same way TBridgeWire expects a full-frame write.
  Sent := 0;
  P := @Buffer;
  while Sent < Count do
  begin
    N := send(FSocket, P^, Count - Sent, 0);
    if N = SOCKET_ERROR then
      raise Exception.CreateFmt('socket send failed (code %d)', [WSAGetLastError]);
    if N = 0 then
      raise Exception.Create('socket send returned 0 (peer closed)');
    Inc(Sent, N);
    Inc(P, N);
  end;
  Result := Sent;
END;

FUNCTION TSocketStream.Seek(CONST Offset: Int64; Origin: TSeekOrigin): Int64;
BEGIN
  // A socket is not seekable. TBridgeWire never seeks; satisfy the abstract method.
  raise Exception.Create('TSocketStream is not seekable');
END;


{ # Connect with timeout }

// Open a non-blocking connect to 127.0.0.1:APort, wait up to ATimeoutMs for it
// to complete via select(), then switch the socket back to blocking for the
// frame I/O (TBridgeWire does blocking reads/writes). Mirrors the pipe client's
// OpenPipeWithTimeout retry intent: a target whose listener isn't up yet should
// not fail instantly — the forward survives app restarts and the socket comes
// back, so we retry connection-refused until the deadline.
FUNCTION ConnectLoopbackWithTimeout(APort: Word; ATimeoutMs: Cardinal): TSocket;
VAR
  Addr     : TSockAddrIn;
  NonBlock : u_long;
  Deadline : UInt64;
  Rc       : Integer;
  WriteSet : TFDSet;
  ErrSet   : TFDSet;
  TV       : TTimeVal;
  SockErr  : Integer;
  ErrLen   : Integer;
  RemainMs : Int64;
BEGIN
  Deadline := GetTickCount64 + ATimeoutMs;

  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family      := AF_INET;
  Addr.sin_port        := htons(APort);
  Addr.sin_addr.S_addr := htonl(INADDR_LOOPBACK);   // 127.0.0.1

  REPEAT
    Result := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if Result = INVALID_SOCKET then
      raise Exception.CreateFmt('socket() failed (code %d)', [WSAGetLastError]);

    NonBlock := 1;
    ioctlsocket(Result, Integer(FIONBIO), NonBlock);

    Rc := connect(Result, TSockAddr(Addr), SizeOf(Addr));
    if Rc = 0 then
    begin
      // Immediate connect (loopback can do this). Back to blocking and done.
      NonBlock := 0;
      ioctlsocket(Result, Integer(FIONBIO), NonBlock);
      EXIT;
    end;

    if WSAGetLastError = WSAEWOULDBLOCK then
    begin
      RemainMs := Int64(Deadline) - Int64(GetTickCount64);
      if RemainMs < 0 then RemainMs := 0;
      FD_ZERO(WriteSet); _FD_SET(Result, WriteSet);
      FD_ZERO(ErrSet);   _FD_SET(Result, ErrSet);
      TV.tv_sec  := RemainMs DIV 1000;
      TV.tv_usec := (RemainMs MOD 1000) * 1000;
      Rc := select(0, NIL, @WriteSet, @ErrSet, @TV);
      if (Rc > 0) and FD_ISSET(Result, WriteSet) then
      begin
        // Writable: check SO_ERROR to confirm the connect actually succeeded.
        // If getsockopt itself fails, treat it as a failed attempt (don't trust
        // the pre-zeroed SockErr, which would otherwise read as "connected").
        SockErr := 0; ErrLen := SizeOf(SockErr);
        if (getsockopt(Result, SOL_SOCKET, SO_ERROR, PAnsiChar(@SockErr), ErrLen) = 0) and (SockErr = 0) then
        begin
          NonBlock := 0;
          ioctlsocket(Result, Integer(FIONBIO), NonBlock);
          EXIT;
        end;
      end;
    end;

    // Failed this attempt (refused, or select timed out short). Close and retry
    // until the overall deadline — the listener may still be coming up.
    closesocket(Result);
    Result := INVALID_SOCKET;
    if GetTickCount64 >= Deadline then BREAK;
    Sleep(25);
  UNTIL GetTickCount64 >= Deadline;

  if Result = INVALID_SOCKET then
    raise Exception.CreateFmt('CallTargetSocket: could not connect to 127.0.0.1:%d within %d ms', [APort, ATimeoutMs]);
END;


{ # Handshake reply }

// Identical wire shape to PipeClient.WriteHelloAck — the bridge expects the
// same {"helloAck":{"protocolVersion":N}} regardless of transport.
PROCEDURE WriteHelloAck(AStream: TStream);
VAR
  Ack   : TJSONObject;
  Inner : TJSONObject;
BEGIN
  Inner := TJSONObject.Create;
  Ack   := TJSONObject.Create;
  TRY
    Inner.AddPair('protocolVersion', TJSONNumber.Create(ProtocolVersion));
    Ack.AddPair('helloAck', Inner);
    Inner := NIL;
    TBridgeWire.WriteFrame(AStream, Ack.ToJSON);
  FINALLY
    Inner.Free;
    Ack.Free;
  END;
END;


{ # Round-trip }

FUNCTION CallTargetSocket(APort: Word; ARequestJson: TJSONObject; ATimeoutMs: Cardinal): TJSONObject;
VAR
  Sock    : TSocket;
  Stream  : TSocketStream;
  HelloRaw: String;
  Frame   : String;
  Parsed  : TJSONValue;
BEGIN
  EnsureWinsock;   // one-time, lock-free; raises if Winsock can't start
  Sock := ConnectLoopbackWithTimeout(APort, ATimeoutMs);
  TRY
    Stream := TSocketStream.Create(Sock);
    TRY
      // Bridge writes hello first. We don't verify contents — the bridge owns the wire format.
      if not TBridgeWire.TryReadFrame(Stream, HelloRaw) then
        raise Exception.Create('CallTargetSocket: bridge did not send hello');

      WriteHelloAck(Stream);

      TBridgeWire.WriteFrame(Stream, ARequestJson.ToJSON);
      if not TBridgeWire.TryReadFrame(Stream, Frame) then
        raise Exception.Create('CallTargetSocket: no response from bridge');

      Parsed := TJSONObject.ParseJSONValue(Frame);
      if Parsed IS TJSONObject then
        Result := TJSONObject(Parsed)
      else
      begin
        Parsed.Free;
        raise Exception.Create('CallTargetSocket: response is not a JSON object');
      end;
    FINALLY
      Stream.Free;
    END;
  FINALLY
    closesocket(Sock);
  END;
END;


END.
