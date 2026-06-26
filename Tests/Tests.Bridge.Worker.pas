unit Tests.Bridge.Worker;

{=============================================================================================================
   2026.06
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for TBridgeWorker driven through a TFakeTransport (in-memory IBridgeTransport implementation — no pipe, no socket).
   - Pins the transport contract: hello/helloAck handshake, request dispatch, and clean WakeAndStop from a blocked AcceptConnection.
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
  end;


implementation

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.JSON,
  Autopilot.Bridge.Core, Autopilot.Bridge.Transport, Autopilot.Bridge.Worker;


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


  // In-memory IBridgeTransport. One scripted session: the first AcceptConnection
  // returns True; every later call parks on an event until WakeAndStop — the same
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
  public
    constructor Create(ABlockFirstAccept: Boolean);
    destructor Destroy; override;

    /// Append one length-prefixed frame to the inbound script (call before the worker reads).
    procedure QueueInboundFrame(const AJson: String);
    /// Parse the captured outbound bytes into whole frames (thread-safe snapshot).
    function  OutboundFrames: TArray<String>;
    function  WakeAndStopCalls: Integer;

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
  if (FAcceptCalls = 1) and not FBlockFirstAccept then Exit(True);
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
  // Nothing to close in memory.
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


initialization
  // This project's fixtures self-register explicitly — [TestFixture] attribute
  // auto-discovery is NOT active here (HANDOVER footgun).
  TDUnitX.RegisterTestFixture(TBridgeWorkerTests);

end.
