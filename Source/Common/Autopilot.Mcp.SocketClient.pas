unit Autopilot.Mcp.SocketClient;

{=============================================================================================================
   2026.07.07
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - TCP loopback socket client for the MCP-server side of the bridge — reaches an Android target via `adb forward`.
   - TSocketStream wraps a Winsock socket as a TStream so TBridgeWire can frame over it without modification.
   - Same hello/helloAck handshake and length-prefixed frame wire format as the named-pipe client.
   - Every recv/send after connect runs under an I/O deadline (SO_RCVTIMEO/SO_SNDTIMEO): a target that accepts
     the connection but stops servicing the wire (frozen app, dead adb forward) raises ETargetNotResponding
     instead of blocking the single-threaded MCP server forever.
   - No VCL, no FMX, no LightSaber, no Indy. Stdlib + Winsock only.
=============================================================================================================}

interface

uses
  Winapi.Windows, Winapi.WinSock2,
  System.SysUtils, System.Classes, System.SyncObjs, System.JSON,
  Autopilot.Bridge.Core;

type
  /// Blocking-socket view as a TStream, so TBridgeWire can frame over it.
  /// Does NOT own the socket — the caller closes it (mirrors THandleStream's
  /// "we still own the handle" contract used by the pipe client).
  TSocketStream = class(TStream)
  strict private
    FSocket: TSocket;
  public
    constructor Create(ASocket: TSocket);
    function Read (var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;


/// Run one round-trip over a loopback TCP socket: connect, read bridge hello,
/// write helloAck, send one command frame, read one response, close.
/// Returns the parsed response object (caller frees) or raises on transport failure.
/// ATimeoutMs budgets the connect phase; every recv/send after connect runs under a deadline of
/// ATimeoutMs + IoDeadlineGraceMs and raises ETargetNotResponding when it expires (frozen target).
/// Mirrors Autopilot.Mcp.PipeClient.CallTarget exactly, port for socket.
function CallTargetSocket(APort: Word; ARequestJson: TJSONObject; ATimeoutMs: Cardinal = 5000): TJSONObject;


implementation


{ # Winsock lifecycle }

// Winsock needs WSAStartup once per process before any socket call. We do it
// EXACTLY ONCE, lock-free, and never call WSACleanup — the OS reclaims Winsock
// at process exit, and a never-cleaned single startup removes every teardown
// race (startup/cleanup churn, decrement-on-failure imbalance) that a ref-count
// would introduce. This also drops the initialization/FINALISATION block the
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

const
  WSA_UNTOUCHED = 0;
  WSA_STARTING  = 1;
  WSA_READY     = 2;

var
  GWsaState: Integer = WSA_UNTOUCHED;

procedure EnsureWinsock;
var
  Data : TWSAData;
  Rc   : Integer;
begin
  // Fast path: already ready (a plain read is fine — once 2, it never changes).
  if GWsaState = WSA_READY then Exit;

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
    Exit;
  end;

  // We lost the race (or another thread is mid-startup). Wait for READY. This
  // spins for the microseconds WSAStartup takes; Yield keeps it cheap. If the
  // winner failed and reset to UNTOUCHED, take over the startup ourselves.
  while GWsaState <> WSA_READY do
  begin
    if GWsaState = WSA_UNTOUCHED then
    begin
      EnsureWinsock;   // winner failed and reset — retry from the top
      Exit;
    end;
    TThread.Yield;
  end;
end;


{ # TSocketStream }

constructor TSocketStream.Create(ASocket: TSocket);
begin
  inherited Create;
  FSocket := ASocket;
end;

function TSocketStream.Read(var Buffer; Count: Longint): Longint;
var
  N, Err: Integer;
begin
  if Count <= 0 then Exit(0);
  N := recv(FSocket, Buffer, Count, 0);
  if N = SOCKET_ERROR then
  begin
    Err := WSAGetLastError;
    // WSAETIMEDOUT here = the SO_RCVTIMEO deadline set by CallTargetSocket expired:
    // the target accepted the connection but sent nothing back within the deadline.
    if Err = WSAETIMEDOUT then
      raise ETargetNotResponding.Create(
        'target accepted the socket connection but sent no reply within the I/O deadline — frozen, hung, or screen-off-frozen (Android)?');
    raise Exception.CreateFmt('socket recv failed (code %d)', [Err]);
  end;
  // N = 0 means the peer closed — surface as 0 so TBridgeWire.ReadFully sees EOF.
  Result := N;
end;

function TSocketStream.Write(const Buffer; Count: Longint): Longint;
var
  Sent, N, Err: Integer;
  P: PByte;
begin
  // send() may write fewer bytes than asked — loop until the whole buffer goes
  // out, the same way TBridgeWire expects a full-frame write.
  Sent := 0;
  P := @Buffer;
  while Sent < Count do
  begin
    N := send(FSocket, P^, Count - Sent, 0);
    if N = SOCKET_ERROR then
    begin
      Err := WSAGetLastError;
      // SO_SNDTIMEO deadline: the peer stopped draining its receive buffer.
      if Err = WSAETIMEDOUT then
        raise ETargetNotResponding.Create(
          'target accepted the socket connection but stopped accepting data within the I/O deadline — frozen or hung?');
      raise Exception.CreateFmt('socket send failed (code %d)', [Err]);
    end;
    if N = 0 then
      raise Exception.Create('socket send returned 0 (peer closed)');
    Inc(Sent, N);
    Inc(P, N);
  end;
  Result := Sent;
end;

function TSocketStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  // A socket is not seekable. TBridgeWire never seeks; satisfy the abstract method.
  raise Exception.Create('TSocketStream is not seekable');
end;


{ # Connect with timeout }

// Open a non-blocking connect to 127.0.0.1:APort, wait up to ATimeoutMs for it
// to complete via select(), then switch the socket back to blocking for the
// frame I/O (TBridgeWire does blocking reads/writes). Mirrors the pipe client's
// OpenPipeWithTimeout retry intent: a target whose listener isn't up yet should
// not fail instantly — the forward survives app restarts and the socket comes
// back, so we retry connection-refused until the deadline.
function ConnectLoopbackWithTimeout(APort: Word; ATimeoutMs: Cardinal): TSocket;
var
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
begin
  Deadline := GetTickCount64 + ATimeoutMs;

  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family      := AF_INET;
  Addr.sin_port        := htons(APort);
  Addr.sin_addr.S_addr := htonl(INADDR_LOOPBACK);   // 127.0.0.1

  repeat
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
      Exit;
    end;

    if WSAGetLastError = WSAEWOULDBLOCK then
    begin
      RemainMs := Int64(Deadline) - Int64(GetTickCount64);
      if RemainMs < 0 then RemainMs := 0;
      FD_ZERO(WriteSet); _FD_SET(Result, WriteSet);
      FD_ZERO(ErrSet);   _FD_SET(Result, ErrSet);
      TV.tv_sec  := RemainMs DIV 1000;
      TV.tv_usec := (RemainMs MOD 1000) * 1000;
      Rc := select(0, nil, @WriteSet, @ErrSet, @TV);
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
          Exit;
        end;
      end;
    end;

    // Failed this attempt (refused, or select timed out short). Close and retry
    // until the overall deadline — the listener may still be coming up.
    closesocket(Result);
    Result := INVALID_SOCKET;
    if GetTickCount64 >= Deadline then Break;
    Sleep(25);
  until GetTickCount64 >= Deadline;

  if Result = INVALID_SOCKET then
    raise Exception.CreateFmt('CallTargetSocket: could not connect to 127.0.0.1:%d within %d ms', [APort, ATimeoutMs]);
end;


{ # Handshake reply }

// Identical wire shape to PipeClient.WriteHelloAck — the bridge expects the
// same {"helloAck":{"protocolVersion":N}} regardless of transport.
procedure WriteHelloAck(AStream: TStream);
var
  Ack   : TJSONObject;
  Inner : TJSONObject;
begin
  Inner := TJSONObject.Create;
  Ack   := TJSONObject.Create;
  try
    Inner.AddPair('protocolVersion', TJSONNumber.Create(ProtocolVersion));
    Ack.AddPair('helloAck', Inner);
    Inner := nil;
    TBridgeWire.WriteFrame(AStream, Ack.ToJSON);
  finally
    Inner.Free;
    Ack.Free;
  end;
end;


{ # Round-trip }

function CallTargetSocket(APort: Word; ARequestJson: TJSONObject; ATimeoutMs: Cardinal): TJSONObject;
var
  Sock       : TSocket;
  Stream     : TSocketStream;
  HelloRaw   : String;
  Frame      : String;
  Parsed     : TJSONValue;
  IoTimeoutMs: DWORD;
begin
  EnsureWinsock;   // one-time, lock-free; raises if Winsock can't start
  Sock := ConnectLoopbackWithTimeout(APort, ATimeoutMs);
  try
    // I/O deadline: on Windows SO_RCVTIMEO/SO_SNDTIMEO take a DWORD of milliseconds.
    // A recv/send past the deadline fails with WSAETIMEDOUT, which TSocketStream turns
    // into ETargetNotResponding. The socket is in an indeterminate state after such a
    // timeout (per WinSock docs) — fine here: it is closed on the way out of this call.
    IoTimeoutMs := ATimeoutMs + IoDeadlineGraceMs;
    if (setsockopt(Sock, SOL_SOCKET, SO_RCVTIMEO, PAnsiChar(@IoTimeoutMs), SizeOf(IoTimeoutMs)) = SOCKET_ERROR) or
       (setsockopt(Sock, SOL_SOCKET, SO_SNDTIMEO, PAnsiChar(@IoTimeoutMs), SizeOf(IoTimeoutMs)) = SOCKET_ERROR) then
      raise Exception.CreateFmt('setsockopt(SO_RCVTIMEO/SO_SNDTIMEO) failed (code %d)', [WSAGetLastError]);
    Stream := TSocketStream.Create(Sock);
    try
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
    finally
      Stream.Free;
    end;
  finally
    closesocket(Sock);
  end;
end;


end.
