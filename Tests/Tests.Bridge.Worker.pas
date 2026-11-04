unit Tests.Bridge.Worker;

{=============================================================================================================
   2026.10.07
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for TBridgeWorker driven through a TFakeTransport (in-memory IBridgeTransport implementation — no pipe, no socket).
   - Pins the transport contract: hello/helloAck handshake, request dispatch, and clean WakeAndStop from a blocked AcceptConnection.
   - Pins that a client which left before its answer is recycled without any EWriteError raise (TRaiseCounter, Win32 only).
=============================================================================================================}

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TBridgeWorkerTests = class
  public
    [Test] procedure Test_WorkerServesHandshakeAndRequestThroughFakeTransport;
    [Test] procedure Test_WorkerShutsDownCleanlyFromBlockedAccept;
    [Test] procedure Test_WorkerRecyclesWithoutRaiseWhenClientLeftBeforeAnswer;
  end;


implementation

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.JSON,
  Autopilot.Bridge.Core, Autopilot.Bridge.Transport, Autopilot.Bridge.Worker,
  Tests.RaiseCounter;


type
  TFakeTransport = class;

  // A TStream view over the fake connection. Read consumes the scripted inbound
  // bytes; Write appends to the outbound capture. The read cursor lives on the
  // TRANSPORT (not the stream), because the worker creates a fresh stream per
  // handshake/request — exactly like THandleStream over one pipe handle.
  TFakeConnStream = class(TStream)
  strict private
    FOwner: TFakeTransport;
  public
    constructor Create(AOwner: TFakeTransport);
    function Read (var   Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek (const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;


  // In-memory IBridgeTransport. Scripted sessions: the first SessionCount AcceptConnection
  // calls return True; every later call parks on an event until WakeAndStop — the same
  // blocking shape as a real listener.
  TFakeTransport = class(TInterfacedObject, IBridgeTransport)
  strict private
    FLock        : TCriticalSection;
    FInbound     : TBytes;      // scripted client->bridge bytes
    FInPos       : Integer;
    FOutbound    : TBytesStream; // captured bridge->client bytes
    FWake        : TEvent;
    FStopping    : Boolean;
    FAcceptCalls : Integer;     // worker thread only
    FBlockFirstAccept : Boolean;
    FWakeAndStopCalls : Integer;
    FRecycleCalls     : Integer;
    FLeaveAt          : Integer; // inbound position at which the client "closes" its end
    FLeaveArmed       : Boolean;
  public
    SessionCount: Integer;      // how many AcceptConnection calls return True (default 1); set before the worker starts
    constructor Create(ABlockFirstAccept: Boolean);
    destructor Destroy; override;

    /// Append one length-prefixed frame to the inbound script (call before the worker reads).
    procedure QueueInboundFrame(const AJson: String);
    /// The client closes its end once the worker has read every frame queued so far: from then on every write
    /// returns 0 bytes, as THandleStream.Write does on a broken pipe. The next accepted connection is a new client.
    procedure ClientLeavesHere;
    /// Parse the captured outbound bytes into whole frames (thread-safe snapshot).
    function  OutboundFrames: TArray<String>;
    function  WakeAndStopCalls: Integer;
    function  RecycleCalls: Integer;

    // Stream plumbing, called from TFakeConnStream.
    function  ReadInbound(var Buffer; Count: Longint): Longint;
    function  WriteOutbound(const Buffer; Count: Longint): Longint;

    { IBridgeTransport }
    procedure StartListening;
    function  AcceptConnection: Boolean;
    function  ConnectionStream: TStream;
    procedure RecycleConnection;
    procedure WakeAndStop(AWorkerThread: TThread);
    function  EndpointLabel: String;
  end;


{ TFakeConnStream -------------------------------------------------------- }

constructor TFakeConnStream.Create(AOwner: TFakeTransport);
begin
  inherited Create;
  FOwner := AOwner;
end;

function TFakeConnStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := FOwner.ReadInbound(Buffer, Count);
end;

function TFakeConnStream.Write(const Buffer; Count: Longint): Longint;
begin
  Result := FOwner.WriteOutbound(Buffer, Count);
end;

function TFakeConnStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Result := 0;   // non-seekable, like a pipe/socket
end;


{ TFakeTransport --------------------------------------------------------- }

constructor TFakeTransport.Create(ABlockFirstAccept: Boolean);
begin
  inherited Create;
  FLock     := TCriticalSection.Create;
  FOutbound := TBytesStream.Create;
  FWake     := TEvent.Create(nil, True, False, '');
  FBlockFirstAccept := ABlockFirstAccept;
  SessionCount := 1;
end;

destructor TFakeTransport.Destroy;
begin
  FreeAndNil(FWake);
  FreeAndNil(FOutbound);
  FreeAndNil(FLock);
  inherited;
end;

procedure TFakeTransport.QueueInboundFrame(const AJson: String);
var
  Tmp: TBytesStream;
  OldLen: Integer;
begin
  Tmp := TBytesStream.Create;
  try
    TBridgeWire.WriteFrame(Tmp, AJson);
    FLock.Enter;
    try
      OldLen := Length(FInbound);
      SetLength(FInbound, OldLen + Tmp.Size);
      Move(Tmp.Bytes[0], FInbound[OldLen], Tmp.Size);
    finally
      FLock.Leave;
    end;
  finally
    FreeAndNil(Tmp);
  end;
end;

procedure TFakeTransport.ClientLeavesHere;
begin
  FLock.Enter;
  try
    FLeaveAt    := Length(FInbound);
    FLeaveArmed := True;
  finally
    FLock.Leave;
  end;
end;

function TFakeTransport.OutboundFrames: TArray<String>;
var
  Snapshot: TBytesStream;
  Frame: String;
begin
  Result := nil;
  Snapshot := TBytesStream.Create;
  try
    FLock.Enter;
    try
      if FOutbound.Size > 0 then
        Snapshot.WriteBuffer(FOutbound.Bytes[0], FOutbound.Size);
    finally
      FLock.Leave;
    end;
    Snapshot.Position := 0;
    // Reuse the production framing to split the capture — whole frames only.
    while (Snapshot.Position < Snapshot.Size) and TBridgeWire.TryReadFrame(Snapshot, Frame) do
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Frame;
    end;
  finally
    FreeAndNil(Snapshot);
  end;
end;

function TFakeTransport.WakeAndStopCalls: Integer;
begin
  FLock.Enter;
  try
    Result := FWakeAndStopCalls;
  finally
    FLock.Leave;
  end;
end;

function TFakeTransport.RecycleCalls: Integer;
begin
  FLock.Enter;
  try
    Result := FRecycleCalls;
  finally
    FLock.Leave;
  end;
end;

function TFakeTransport.ReadInbound(var Buffer; Count: Longint): Longint;
begin
  FLock.Enter;
  try
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
  finally
    FLock.Leave;
  end;
end;

function TFakeTransport.WriteOutbound(const Buffer; Count: Longint): Longint;
begin
  FLock.Enter;
  try
    if FLeaveArmed and (FInPos >= FLeaveAt) then
      Exit(0);   // the client is gone: nothing is written
    FOutbound.WriteBuffer(Buffer, Count);
    Result := Count;
  finally
    FLock.Leave;
  end;
end;

procedure TFakeTransport.StartListening;
begin
  // Nothing to arm in memory.
end;

function TFakeTransport.AcceptConnection: Boolean;
begin
  if FStopping then Exit(False);
  Inc(FAcceptCalls);
  if (FAcceptCalls <= SessionCount) and not FBlockFirstAccept then
  begin
    FLock.Enter;
    try
      if FLeaveArmed and (FInPos >= FLeaveAt) then
        FLeaveArmed := False;   // the client that left was the previous one; this is a new client
    finally
      FLock.Leave;
    end;
    Exit(True);
  end;
  // Park like a real listener until WakeAndStop. Bounded so a broken contract
  // fails the test instead of hanging the suite.
  FWake.WaitFor(10000);
  Result := False;
end;

function TFakeTransport.ConnectionStream: TStream;
begin
  Result := TFakeConnStream.Create(Self);
end;

procedure TFakeTransport.RecycleConnection;
begin
  // Nothing to close in memory; only counted.
  FLock.Enter;
  try
    Inc(FRecycleCalls);
  finally
    FLock.Leave;
  end;
end;

procedure TFakeTransport.WakeAndStop(AWorkerThread: TThread);
begin
  FLock.Enter;
  try
    Inc(FWakeAndStopCalls);
  finally
    FLock.Leave;
  end;
  FStopping := True;
  FWake.SetEvent;
end;

function TFakeTransport.EndpointLabel: String;
begin
  Result := 'fake:in-memory';
end;


{ Helpers ----------------------------------------------------------------- }

// Pump TThread.Queue closures on this (main) thread until the fake transport has
// captured at least AFrameCount outbound frames. The worker's dispatcher call is
// queued to the main thread, so without CheckSynchronize the request would
// dead-wait exactly like a blocked GUI app.
procedure PumpUntilFrames(AFake: TFakeTransport; AFrameCount: Integer; ATimeoutMs: Cardinal);
var
  Deadline: UInt64;
begin
  Deadline := TThread.GetTickCount64 + ATimeoutMs;
  while Length(AFake.OutboundFrames) < AFrameCount do
  begin
    CheckSynchronize(10);
    if TThread.GetTickCount64 > Deadline then
      Assert.Fail('PumpUntilFrames: worker produced ' + IntToStr(Length(AFake.OutboundFrames)) +
                  ' of ' + IntToStr(AFrameCount) + ' frames within ' + IntToStr(ATimeoutMs) + ' ms');
  end;
end;


{ TBridgeWorkerTests ------------------------------------------------------ }

procedure TBridgeWorkerTests.Test_WorkerServesHandshakeAndRequestThroughFakeTransport;
var
  Fake      : TFakeTransport;
  Transport : IBridgeTransport;
  Worker    : TBridgeWorker;
  DispatchedCmd: String;
  DispatchedArgX: Integer;
  Frames    : TArray<String>;
  Root      : TJSONValue;
  Hello     : TJSONObject;
begin
  Fake := TFakeTransport.Create(False);
  Transport := Fake;   // test holds one ref; the worker takes its own
  Fake.QueueInboundFrame('{"helloAck":{"protocolVersion":1}}');
  Fake.QueueInboundFrame('{"id":7,"cmd":"ping","args":{"x":41}}');

  DispatchedCmd  := '';
  DispatchedArgX := 0;
  Worker := TBridgeWorker.Create(Transport, 'FakeExe.exe',
    function(const Req: TBridgeRequest): TBridgeResponse
    begin
      DispatchedCmd := Req.Cmd;
      if Req.Args <> nil then
        DispatchedArgX := Req.Args.GetValue<Integer>('x', 0);
      Result := Default(TBridgeResponse);
      Result.Id := Req.Id;
      Result.Ok := True;
      Result.ResultJson := TJSONObject.Create;
      Result.ResultJson.AddPair('pong', TJSONBool.Create(True));
    end);
  try
    PumpUntilFrames(Fake, 2, 5000);
    Frames := Fake.OutboundFrames;
    Assert.AreEqual(2, Length(Frames), 'expected hello frame + response frame');

    // Frame 1: the hello the worker sends through ANY transport.
    Root := TJSONObject.ParseJSONValue(Frames[0]);
    try
      Assert.IsNotNull(Root, 'hello frame must be JSON');
      Hello := (Root AS TJSONObject).GetValue('hello') AS TJSONObject;
      Assert.IsNotNull(Hello, 'first frame must carry hello');
      Assert.AreEqual(ProtocolVersion, Hello.GetValue<Integer>('protocolVersion', -1));
      Assert.AreEqual('FakeExe.exe',   Hello.GetValue<String>('exe', ''));
    finally
      FreeAndNil(Root);
    end;

    // Frame 2: the dispatcher's response, serialized by the worker.
    Root := TJSONObject.ParseJSONValue(Frames[1]);
    try
      Assert.IsNotNull(Root, 'response frame must be JSON');
      Assert.AreEqual<Int64>(7, (Root AS TJSONObject).GetValue<Int64>('id', -1));
      Assert.IsTrue((Root AS TJSONObject).GetValue<Boolean>('ok', False), 'response must be ok');
      Assert.IsTrue((Root AS TJSONObject).GetValue<Boolean>('result.pong', False), 'result.pong must be true');
    finally
      FreeAndNil(Root);
    end;

    // The dispatcher really ran (on this thread, via TThread.Queue) and saw the cloned args.
    Assert.AreEqual('ping', DispatchedCmd);
    Assert.AreEqual(41, DispatchedArgX);
  finally
    FreeAndNil(Worker);    // drops the worker's transport ref
    Transport := nil;      // drops the test's ref — fake destroys here
  end;
end;


procedure TBridgeWorkerTests.Test_WorkerShutsDownCleanlyFromBlockedAccept;
var
  Fake      : TFakeTransport;
  Transport : IBridgeTransport;
  Worker    : TBridgeWorker;
  T0        : UInt64;
begin
  // No session at all: the very first AcceptConnection parks. Destroy must come
  // back promptly via the WakeAndStop contract, never serving anything.
  Fake := TFakeTransport.Create(True);
  Transport := Fake;
  Worker := TBridgeWorker.Create(Transport, 'FakeExe.exe',
    function(const Req: TBridgeRequest): TBridgeResponse
    begin
      Result := Default(TBridgeResponse);
      Assert.Fail('dispatcher must never run — no client ever connected');
    end);

  TThread.Sleep(50);   // let the worker reach (or pass) AcceptConnection
  T0 := TThread.GetTickCount64;
  FreeAndNil(Worker);
  Assert.IsTrue(TThread.GetTickCount64 - T0 < 3000, 'Destroy must not hang on a parked AcceptConnection');
  Assert.IsTrue(Fake.WakeAndStopCalls >= 1, 'Destroy must wake the transport via WakeAndStop');
  Assert.AreEqual(0, Length(Fake.OutboundFrames), 'no client connected, so nothing may be written');
  Transport := nil;
end;


// The client gives up before the answer is written (it timed out while the app sat at a breakpoint). The worker
// must find that out from the write's return value, never from a raise: even a caught EWriteError stops a debugger
// that halts on language exceptions, and with it the whole app. Then it must recycle and serve the next client.
procedure TBridgeWorkerTests.Test_WorkerRecyclesWithoutRaiseWhenClientLeftBeforeAnswer;
var
  Fake      : TFakeTransport;
  Transport : IBridgeTransport;
  Worker    : TBridgeWorker;
  Frames    : TArray<String>;
  Root      : TJSONValue;
  DispatchCount, ProbeCount, WriteErrorCount: Integer;
begin
  Fake := TFakeTransport.Create(False);
  Transport := Fake;
  Fake.SessionCount := 2;
  // Client 1: handshake, one request, then it leaves before the answer.
  Fake.QueueInboundFrame('{"helloAck":{"protocolVersion":1}}');
  Fake.QueueInboundFrame('{"id":1,"cmd":"ping"}');
  Fake.ClientLeavesHere;
  // Client 2: must be served normally.
  Fake.QueueInboundFrame('{"helloAck":{"protocolVersion":1}}');
  Fake.QueueInboundFrame('{"id":2,"cmd":"ping"}');

  DispatchCount := 0;
  Worker := NIL;
  TRaiseCounter.Install(EWriteError);
  try
    // The probe must see a raise that is caught, or a zero below would prove nothing.
    try
      raise EWriteError.Create('probe');
    except
      on EWriteError do ;   // the probe raise; only the counter matters
    end;
    ProbeCount := TRaiseCounter.Count;
    TRaiseCounter.Reset;

    Worker := TBridgeWorker.Create(Transport, 'FakeExe.exe',
      function(const Req: TBridgeRequest): TBridgeResponse
      begin
        Inc(DispatchCount);   // main thread (TThread.Queue, pumped below)
        Result := Default(TBridgeResponse);
        Result.Id := Req.Id;
        Result.Ok := True;
        Result.ResultJson := TJSONObject.Create;
      end);

    // hello 1 + hello 2 + the answer to id 2. The answer to id 1 has nowhere to go.
    PumpUntilFrames(Fake, 3, 5000);
    WriteErrorCount := TRaiseCounter.Count;
  finally
    TRaiseCounter.Uninstall;
    FreeAndNil(Worker);
  end;

  try
    Assert.AreEqual(1, ProbeCount, 'the raise counter must see a caught EWriteError');
    Assert.AreEqual(0, WriteErrorCount, 'a client that left must be detected without raising EWriteError');
    Assert.AreEqual(2, DispatchCount, 'both requests must reach the dispatcher');
    Assert.IsTrue(Fake.RecycleCalls >= 1, 'the dead connection must be recycled');

    Frames := Fake.OutboundFrames;
    Assert.AreEqual(3, Length(Frames), 'expected hello 1, hello 2 and the answer to id 2');
    Assert.Contains(Frames[0], '"hello"', 'frame 1 must be the first hello');
    Assert.Contains(Frames[1], '"hello"', 'frame 2 must be the hello to the second client');
    Root := TJSONObject.ParseJSONValue(Frames[2]);
    try
      Assert.IsNotNull(Root, 'answer frame must be JSON');
      Assert.AreEqual<Int64>(2, (Root AS TJSONObject).GetValue<Int64>('id', -1), 'the answer must be for id 2');
      Assert.IsTrue((Root AS TJSONObject).GetValue<Boolean>('ok', False), 'the answer to id 2 must be ok');
    finally
      FreeAndNil(Root);
    end;
  finally
    Transport := nil;
  end;
end;


initialization
  // This project's fixtures self-register explicitly — [TestFixture] attribute
  // auto-discovery is NOT active here (HANDOVER footgun).
  TDUnitX.RegisterTestFixture(TBridgeWorkerTests);

end.
