UNIT Tests.Bridge.Worker;

{=====================================================
   2026.06.10
   Tests for the shared bridge worker (Autopilot.Bridge.Worker), extracted from
   NamedPipe.pas in Phase B of the Android transport work.

   These tests drive TBridgeWorker through a FAKE in-memory IBridgeTransport —
   no pipe, no socket. They pin the transport contract itself:
     - the worker completes the hello/helloAck handshake and serves a request
       through ANY transport that honours the interface;
     - the worker's destructor returns promptly when the worker is parked in
       AcceptConnection (the WakeAndStop contract).

   The pipe-specific behaviour (ACL, discovery file, CSI wake) stays covered by
   the existing Bridge.Tests over a real pipe.
=====================================================}

INTERFACE

USES
  DUnitX.TestFramework;

TYPE
  [TestFixture]
  TBridgeWorkerTests = CLASS
  PUBLIC
    [Test] PROCEDURE Test_WorkerServesHandshakeAndRequestThroughFakeTransport;
    [Test] PROCEDURE Test_WorkerShutsDownCleanlyFromBlockedAccept;
  END;


IMPLEMENTATION

USES
  System.SysUtils, System.Classes, System.SyncObjs, System.JSON,
  Autopilot.Bridge.Core, Autopilot.Bridge.Transport, Autopilot.Bridge.Worker;


TYPE
  TFakeTransport = CLASS;

  // A TStream view over the fake connection. Read consumes the scripted inbound
  // bytes; Write appends to the outbound capture. The read cursor lives on the
  // TRANSPORT (not the stream), because the worker creates a fresh stream per
  // handshake/request — exactly like THandleStream over one pipe handle.
  TFakeConnStream = CLASS(TStream)
  STRICT PRIVATE
    FOwner: TFakeTransport;
  PUBLIC
    CONSTRUCTOR Create(AOwner: TFakeTransport);
    FUNCTION Read (VAR   Buffer; Count: Longint): Longint; OVERRIDE;
    FUNCTION Write(CONST Buffer; Count: Longint): Longint; OVERRIDE;
    FUNCTION Seek (CONST Offset: Int64; Origin: TSeekOrigin): Int64; OVERRIDE;
  END;


  // In-memory IBridgeTransport. One scripted session: the first AcceptConnection
  // returns TRUE; every later call parks on an event until WakeAndStop — the same
  // blocking shape as a real listener.
  TFakeTransport = CLASS(TInterfacedObject, IBridgeTransport)
  STRICT PRIVATE
    FLock        : TCriticalSection;
    FInbound     : TBytes;      // scripted client->bridge bytes
    FInPos       : Integer;
    FOutbound    : TBytesStream; // captured bridge->client bytes
    FWake        : TEvent;
    FStopping    : Boolean;
    FAcceptCalls : Integer;     // worker thread only
    FBlockFirstAccept : Boolean;
    FWakeAndStopCalls : Integer;
  PUBLIC
    CONSTRUCTOR Create(ABlockFirstAccept: Boolean);
    DESTRUCTOR Destroy; OVERRIDE;

    /// Append one length-prefixed frame to the inbound script (call before the worker reads).
    PROCEDURE QueueInboundFrame(CONST AJson: String);
    /// Parse the captured outbound bytes into whole frames (thread-safe snapshot).
    FUNCTION  OutboundFrames: TArray<String>;
    FUNCTION  WakeAndStopCalls: Integer;

    // Stream plumbing, called from TFakeConnStream.
    FUNCTION  ReadInbound(VAR Buffer; Count: Longint): Longint;
    FUNCTION  WriteOutbound(CONST Buffer; Count: Longint): Longint;

    { IBridgeTransport }
    PROCEDURE StartListening;
    FUNCTION  AcceptConnection: Boolean;
    FUNCTION  ConnectionStream: TStream;
    PROCEDURE RecycleConnection;
    PROCEDURE WakeAndStop(AWorkerThread: TThread);
    FUNCTION  EndpointLabel: String;
  END;


{ TFakeConnStream -------------------------------------------------------- }

CONSTRUCTOR TFakeConnStream.Create(AOwner: TFakeTransport);
BEGIN
  inherited Create;
  FOwner := AOwner;
END;

FUNCTION TFakeConnStream.Read(VAR Buffer; Count: Longint): Longint;
BEGIN
  Result := FOwner.ReadInbound(Buffer, Count);
END;

FUNCTION TFakeConnStream.Write(CONST Buffer; Count: Longint): Longint;
BEGIN
  Result := FOwner.WriteOutbound(Buffer, Count);
END;

FUNCTION TFakeConnStream.Seek(CONST Offset: Int64; Origin: TSeekOrigin): Int64;
BEGIN
  Result := 0;   // non-seekable, like a pipe/socket
END;


{ TFakeTransport --------------------------------------------------------- }

CONSTRUCTOR TFakeTransport.Create(ABlockFirstAccept: Boolean);
BEGIN
  inherited Create;
  FLock     := TCriticalSection.Create;
  FOutbound := TBytesStream.Create;
  FWake     := TEvent.Create(NIL, TRUE, FALSE, '');
  FBlockFirstAccept := ABlockFirstAccept;
END;

DESTRUCTOR TFakeTransport.Destroy;
BEGIN
  FreeAndNil(FWake);
  FreeAndNil(FOutbound);
  FreeAndNil(FLock);
  inherited;
END;

PROCEDURE TFakeTransport.QueueInboundFrame(CONST AJson: String);
VAR
  Tmp: TBytesStream;
  OldLen: Integer;
BEGIN
  Tmp := TBytesStream.Create;
  TRY
    TBridgeWire.WriteFrame(Tmp, AJson);
    FLock.Enter;
    TRY
      OldLen := Length(FInbound);
      SetLength(FInbound, OldLen + Tmp.Size);
      Move(Tmp.Bytes[0], FInbound[OldLen], Tmp.Size);
    FINALLY
      FLock.Leave;
    END;
  FINALLY
    FreeAndNil(Tmp);
  END;
END;

FUNCTION TFakeTransport.OutboundFrames: TArray<String>;
VAR
  Snapshot: TBytesStream;
  Frame: String;
BEGIN
  Result := NIL;
  Snapshot := TBytesStream.Create;
  TRY
    FLock.Enter;
    TRY
      if FOutbound.Size > 0 then
        Snapshot.WriteBuffer(FOutbound.Bytes[0], FOutbound.Size);
    FINALLY
      FLock.Leave;
    END;
    Snapshot.Position := 0;
    // Reuse the production framing to split the capture — whole frames only.
    WHILE (Snapshot.Position < Snapshot.Size) and TBridgeWire.TryReadFrame(Snapshot, Frame) DO
    BEGIN
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Frame;
    END;
  FINALLY
    FreeAndNil(Snapshot);
  END;
END;

FUNCTION TFakeTransport.WakeAndStopCalls: Integer;
BEGIN
  FLock.Enter;
  TRY
    Result := FWakeAndStopCalls;
  FINALLY
    FLock.Leave;
  END;
END;

FUNCTION TFakeTransport.ReadInbound(VAR Buffer; Count: Longint): Longint;
BEGIN
  FLock.Enter;
  TRY
    Result := Length(FInbound) - FInPos;
    if Result > Count then
      Result := Count;
    if Result > 0 then
    begin
      Move(FInbound[FInPos], Buffer, Result);
      Inc(FInPos, Result);
    end
    else
      Result := 0;   // script exhausted = clean EOF, like a closed pipe
  FINALLY
    FLock.Leave;
  END;
END;

FUNCTION TFakeTransport.WriteOutbound(CONST Buffer; Count: Longint): Longint;
BEGIN
  FLock.Enter;
  TRY
    FOutbound.WriteBuffer(Buffer, Count);
    Result := Count;
  FINALLY
    FLock.Leave;
  END;
END;

PROCEDURE TFakeTransport.StartListening;
BEGIN
  // Nothing to arm in memory.
END;

FUNCTION TFakeTransport.AcceptConnection: Boolean;
BEGIN
  if FStopping then EXIT(FALSE);
  Inc(FAcceptCalls);
  if (FAcceptCalls = 1) and not FBlockFirstAccept then EXIT(TRUE);
  // Park like a real listener until WakeAndStop. Bounded so a broken contract
  // fails the test instead of hanging the suite.
  FWake.WaitFor(10000);
  Result := FALSE;
END;

FUNCTION TFakeTransport.ConnectionStream: TStream;
BEGIN
  Result := TFakeConnStream.Create(Self);
END;

PROCEDURE TFakeTransport.RecycleConnection;
BEGIN
  // Nothing to close in memory.
END;

PROCEDURE TFakeTransport.WakeAndStop(AWorkerThread: TThread);
BEGIN
  FLock.Enter;
  TRY
    Inc(FWakeAndStopCalls);
  FINALLY
    FLock.Leave;
  END;
  FStopping := TRUE;
  FWake.SetEvent;
END;

FUNCTION TFakeTransport.EndpointLabel: String;
BEGIN
  Result := 'fake:in-memory';
END;


{ Helpers ----------------------------------------------------------------- }

// Pump TThread.Queue closures on this (main) thread until the fake transport has
// captured at least AFrameCount outbound frames. The worker's dispatcher call is
// queued to the main thread, so without CheckSynchronize the request would
// dead-wait exactly like a blocked GUI app.
PROCEDURE PumpUntilFrames(AFake: TFakeTransport; AFrameCount: Integer; ATimeoutMs: Cardinal);
VAR
  Deadline: UInt64;
BEGIN
  Deadline := TThread.GetTickCount64 + ATimeoutMs;
  WHILE Length(AFake.OutboundFrames) < AFrameCount DO
  BEGIN
    CheckSynchronize(10);
    if TThread.GetTickCount64 > Deadline then
      Assert.Fail('PumpUntilFrames: worker produced ' + IntToStr(Length(AFake.OutboundFrames)) +
                  ' of ' + IntToStr(AFrameCount) + ' frames within ' + IntToStr(ATimeoutMs) + ' ms');
  END;
END;


{ TBridgeWorkerTests ------------------------------------------------------ }

PROCEDURE TBridgeWorkerTests.Test_WorkerServesHandshakeAndRequestThroughFakeTransport;
VAR
  Fake      : TFakeTransport;
  Transport : IBridgeTransport;
  Worker    : TBridgeWorker;
  DispatchedCmd: String;
  DispatchedArgX: Integer;
  Frames    : TArray<String>;
  Root      : TJSONValue;
  Hello     : TJSONObject;
BEGIN
  Fake := TFakeTransport.Create(FALSE);
  Transport := Fake;   // test holds one ref; the worker takes its own
  Fake.QueueInboundFrame('{"helloAck":{"protocolVersion":1}}');
  Fake.QueueInboundFrame('{"id":7,"cmd":"ping","args":{"x":41}}');

  DispatchedCmd  := '';
  DispatchedArgX := 0;
  Worker := TBridgeWorker.Create(Transport, 'FakeExe.exe',
    FUNCTION(CONST Req: TBridgeRequest): TBridgeResponse
    BEGIN
      DispatchedCmd := Req.Cmd;
      if Req.Args <> NIL then
        DispatchedArgX := Req.Args.GetValue<Integer>('x', 0);
      Result := Default(TBridgeResponse);
      Result.Id := Req.Id;
      Result.Ok := TRUE;
      Result.ResultJson := TJSONObject.Create;
      Result.ResultJson.AddPair('pong', TJSONBool.Create(TRUE));
    END);
  TRY
    PumpUntilFrames(Fake, 2, 5000);
    Frames := Fake.OutboundFrames;
    Assert.AreEqual(2, Length(Frames), 'expected hello frame + response frame');

    // Frame 1: the hello the worker sends through ANY transport.
    Root := TJSONObject.ParseJSONValue(Frames[0]);
    TRY
      Assert.IsNotNull(Root, 'hello frame must be JSON');
      Hello := (Root AS TJSONObject).GetValue('hello') AS TJSONObject;
      Assert.IsNotNull(Hello, 'first frame must carry hello');
      Assert.AreEqual(ProtocolVersion, Hello.GetValue<Integer>('protocolVersion', -1));
      Assert.AreEqual('FakeExe.exe',   Hello.GetValue<String>('exe', ''));
    FINALLY
      FreeAndNil(Root);
    END;

    // Frame 2: the dispatcher's response, serialized by the worker.
    Root := TJSONObject.ParseJSONValue(Frames[1]);
    TRY
      Assert.IsNotNull(Root, 'response frame must be JSON');
      Assert.AreEqual<Int64>(7, (Root AS TJSONObject).GetValue<Int64>('id', -1));
      Assert.IsTrue((Root AS TJSONObject).GetValue<Boolean>('ok', FALSE), 'response must be ok');
      Assert.IsTrue((Root AS TJSONObject).GetValue<Boolean>('result.pong', FALSE), 'result.pong must be true');
    FINALLY
      FreeAndNil(Root);
    END;

    // The dispatcher really ran (on this thread, via TThread.Queue) and saw the cloned args.
    Assert.AreEqual('ping', DispatchedCmd);
    Assert.AreEqual(41, DispatchedArgX);
  FINALLY
    FreeAndNil(Worker);    // drops the worker's transport ref
    Transport := NIL;      // drops the test's ref — fake destroys here
  END;
END;


PROCEDURE TBridgeWorkerTests.Test_WorkerShutsDownCleanlyFromBlockedAccept;
VAR
  Fake      : TFakeTransport;
  Transport : IBridgeTransport;
  Worker    : TBridgeWorker;
  T0        : UInt64;
BEGIN
  // No session at all: the very first AcceptConnection parks. Destroy must come
  // back promptly via the WakeAndStop contract, never serving anything.
  Fake := TFakeTransport.Create(TRUE);
  Transport := Fake;
  Worker := TBridgeWorker.Create(Transport, 'FakeExe.exe',
    FUNCTION(CONST Req: TBridgeRequest): TBridgeResponse
    BEGIN
      Result := Default(TBridgeResponse);
      Assert.Fail('dispatcher must never run — no client ever connected');
    END);

  TThread.Sleep(50);   // let the worker reach (or pass) AcceptConnection
  T0 := TThread.GetTickCount64;
  FreeAndNil(Worker);
  Assert.IsTrue(TThread.GetTickCount64 - T0 < 3000, 'Destroy must not hang on a parked AcceptConnection');
  Assert.IsTrue(Fake.WakeAndStopCalls >= 1, 'Destroy must wake the transport via WakeAndStop');
  Assert.AreEqual(0, Length(Fake.OutboundFrames), 'no client connected, so nothing may be written');
  Transport := NIL;
END;


INITIALIZATION
  // This project's fixtures self-register explicitly — [TestFixture] attribute
  // auto-discovery is NOT active here (HANDOVER footgun).
  TDUnitX.RegisterTestFixture(TBridgeWorkerTests);

END.
