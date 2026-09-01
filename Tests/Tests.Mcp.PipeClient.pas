unit Tests.Mcp.PipeClient;

{=============================================================================================================
   2026.09.01
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for Autopilot.Mcp.PipeClient: PC-side proof using a synthetic TFakePipeBridge that runs on
     a background thread and speaks the wire protocol over a real named pipe (hello frame, request/response).
   - Covers the full round-trip through the overlapped deadline stream, and the S2 wedge scenario: a target
     that accepts + handshakes, then never answers, must raise ETargetNotResponding at ~(timeout + grace)
     instead of blocking the caller forever.
   - No live target app needed. Stdlib + Win32 only.
=============================================================================================================}

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TPipeClientTests = class
  public
    [Test] procedure Test_RoundTrip_EchoesResponse;
    [Test] procedure Test_WedgedTarget_RaisesNotResponding;
  end;


implementation

uses
  Winapi.Windows,
  System.SysUtils, System.Classes, System.JSON, System.SyncObjs,
  Autopilot.Bridge.Core,
  Autopilot.Mcp.PipeClient;


{ # Synthetic bridge-side pipe server }

var
  GPipeSeq: Integer = 0;   // makes each fixture's pipe name unique within the test run

type
  // A one-shot named-pipe server that imitates the target-app bridge for exactly
  // one connection: create pipe → accept → write hello → read helloAck + request →
  // then either write the canned response or WEDGE (hold the connection open and
  // answer nothing — the frozen-on-a-breakpoint target of review item S2).
  // Runs on its own thread so the test thread can drive CallTarget synchronously.
  TFakePipeBridge = class(TThread)
  strict private
    FPipeName  : String;
    FPipe      : THandle;
    FResponse  : String;     // canned response JSON; '' = wedge mode
    FReady     : TEvent;     // signalled once the pipe exists (PipeName is connectable)
    FRelease   : TEvent;     // signalled by Destroy to let a wedged Execute finish
    FSawRequest: String;     // the request frame the client sent (for assertions)
  protected
    procedure Execute; override;
  public
    constructor Create(const AResponseJson: String);
    destructor Destroy; override;
    procedure WaitUntilReady;
    property PipeName: String read FPipeName;
    property SawRequest: String read FSawRequest;
  end;


constructor TFakePipeBridge.Create(const AResponseJson: String);
begin
  FResponse := AResponseJson;
  FPipeName := '\\.\pipe\Autopilot.FakeTest.' + IntToStr(GetCurrentProcessId) +
               '.' + IntToStr(TInterlocked.Increment(GPipeSeq));
  FReady   := TEvent.Create(nil, True, False, '');   // manual-reset
  FRelease := TEvent.Create(nil, True, False, '');
  FPipe := INVALID_HANDLE_VALUE;
  inherited Create(False);   // start immediately
end;


destructor TFakePipeBridge.Destroy;
begin
  FRelease.SetEvent;               // let a wedged Execute proceed to its cleanup
  if Handle <> 0 then
    // Safety net for assert-failure paths: unblocks a ConnectNamedPipe/ReadFile the
    // test never satisfied (same wake the real bridge transport uses). ERROR_NOT_FOUND
    // when nothing is pending — harmless.
    CancelSynchronousIo(Handle);
  inherited;                       // joins the thread
  if FPipe <> INVALID_HANDLE_VALUE then CloseHandle(FPipe);
  FreeAndNil(FReady);
  FreeAndNil(FRelease);
end;


procedure TFakePipeBridge.WaitUntilReady;
begin
  if FReady.WaitFor(5000) <> wrSignaled then
    raise Exception.Create('FakePipeBridge never became ready');
end;


procedure TFakePipeBridge.Execute;
var
  Stream  : THandleStream;
  Hello   : TJSONObject;
  AckFrame: String;
begin
  FPipe := CreateNamedPipeW(PWideChar(FPipeName),
             PIPE_ACCESS_DUPLEX or FILE_FLAG_FIRST_PIPE_INSTANCE,
             PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT,
             1, 65536, 65536, 0, nil);
  if FPipe = INVALID_HANDLE_VALUE then Exit;   // FReady stays unsignalled -> WaitUntilReady raises

  FReady.SetEvent;   // pipe exists — the test may connect now

  if not ConnectNamedPipe(FPipe, nil) then
    if GetLastError <> ERROR_PIPE_CONNECTED then Exit;   // client won the connect race = success
  try
    Stream := THandleStream.Create(FPipe);
    try
      // 1. Bridge speaks first: hello frame.
      Hello := BuildHelloJson('Autopilot.FakePipeBridge.exe', GetCurrentProcessId);
      try
        TBridgeWire.WriteFrame(Stream, Hello.ToJSON);
      finally
        FreeAndNil(Hello);
      end;

      // 2. Client replies helloAck, then sends its request.
      if not TBridgeWire.TryReadFrame(Stream, AckFrame) then Exit;     // helloAck
      if not TBridgeWire.TryReadFrame(Stream, FSawRequest) then Exit;  // the command

      // 3. Answer — or wedge like a breakpoint-frozen target.
      if FResponse = '' then
        FRelease.WaitFor(30000)
      else
      begin
        TBridgeWire.WriteFrame(Stream, FResponse);
        // Park until the client has read the buffered response — DisconnectNamedPipe
        // DISCARDS un-read data, so disconnecting straight after the write is a race.
        FlushFileBuffers(FPipe);
      end;
    finally
      FreeAndNil(Stream);
    end;
  finally
    DisconnectNamedPipe(FPipe);
  end;
end;


{ # Tests }

procedure TPipeClientTests.Test_RoundTrip_EchoesResponse;
var
  Fake: TFakePipeBridge;
  Req : TJSONObject;
  Resp: TJSONObject;
begin
  Fake := TFakePipeBridge.Create('{"id":1,"ok":true,"result":{"pong":true}}');
  try
    Fake.WaitUntilReady;

    Req := TJSONObject.Create;
    Req.AddPair('id', TJSONNumber.Create(1));
    Req.AddPair('cmd', 'ping');
    try
      Resp := CallTarget(Fake.PipeName, Req, 3000);
      try
        Assert.IsNotNull(Resp, 'No response object');
        Assert.AreEqual(Int64(1), (Resp.GetValue('id') AS TJSONNumber).AsInt64, 'id mismatch');
        Assert.IsTrue((Resp.GetValue('ok') AS TJSONBool).AsBoolean, 'ok should be true');
      finally
        FreeAndNil(Resp);
      end;
    finally
      FreeAndNil(Req);
    end;

    // The client must have sent our exact command through the deadline stream.
    Assert.IsTrue(Fake.SawRequest.Contains('"cmd":"ping"'), 'fake bridge did not see the request: ' + Fake.SawRequest);
  finally
    FreeAndNil(Fake);
  end;
end;


procedure TPipeClientTests.Test_WedgedTarget_RaisesNotResponding;
var
  Fake       : TFakePipeBridge;
  Req        : TJSONObject;
  Resp       : TJSONObject;
  T0, Elapsed: UInt64;
  RaisedRight: Boolean;
begin
  // Review item S2: the target ACCEPTS the connection and completes the handshake,
  // then never answers the command (whole app frozen on an IDE breakpoint). CallTarget
  // must raise ETargetNotResponding at ~(timeout + IoDeadlineGraceMs) — not hang.
  Fake := TFakePipeBridge.Create('');   // '' = wedge mode
  try
    Fake.WaitUntilReady;

    Req := TJSONObject.Create;
    Req.AddPair('id', TJSONNumber.Create(1));
    Req.AddPair('cmd', 'get_text');
    RaisedRight := False;
    T0 := GetTickCount64;
    try
      try
        Resp := CallTarget(Fake.PipeName, Req, 500);
        FreeAndNil(Resp);   // must not be reached
      except
        on E: ETargetNotResponding do
          RaisedRight := True;
        // Any OTHER exception escapes on purpose — the test then errors with the real message.
      end;
    finally
      FreeAndNil(Req);
    end;
    Elapsed := GetTickCount64 - T0;

    Assert.IsTrue(RaisedRight, 'expected ETargetNotResponding from the wedged target');
    Assert.IsTrue(Elapsed >= 2000, 'deadline fired too early (' + IntToStr(Elapsed) + ' ms) — grace not applied?');
    Assert.IsTrue(Elapsed < 10000, 'deadline fired too late (' + IntToStr(Elapsed) + ' ms) — I/O deadline not working?');
  finally
    FreeAndNil(Fake);
  end;
end;


initialization
  TDUnitX.RegisterTestFixture(TPipeClientTests);

end.
