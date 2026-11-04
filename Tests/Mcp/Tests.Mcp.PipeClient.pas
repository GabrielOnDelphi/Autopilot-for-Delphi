unit Tests.Mcp.PipeClient;

{=============================================================================================================
   2026.10.06
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for Autopilot.Mcp.PipeClient: PC-side proof using a synthetic TFakePipeBridge that runs on
     a background thread and speaks the wire protocol over a real named pipe (hello frame, request/response).
   - Covers the full round-trip through the overlapped deadline stream, and the S2 wedge scenario: a target
     that accepts + handshakes, then never answers, must raise ETargetNotResponding at ~(timeout + grace)
     instead of blocking the caller forever. Also the busy pipe of GitHub issue #2 (TBusyPipe).
   - TFakePipeBridge, TBusyPipe and TPrivateDiscovery are in the interface: Tests.Mcp.Tools drives the
     tools through them.
   - No live target app needed. Stdlib + Win32 only.
=============================================================================================================}

interface

uses
  Winapi.Windows,
  System.Classes, System.SyncObjs,
  DUnitX.TestFramework;

type
  [TestFixture]
  TPipeClientTests = class
  public
    [Test] procedure Test_RoundTrip_EchoesResponse;
    [Test] procedure Test_WedgedTarget_RaisesNotResponding;
    [Test] procedure Test_BusyPipe_RaisesNotResponding;
  end;


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


  // A named pipe whose only instance is already taken by another client, so every further connect fails
  // with ERROR_PIPE_BUSY (231): what the MCP server meets when the target's bridge worker is frozen while
  // an earlier connection is still open (GitHub issue #2).
  TBusyPipe = class
  strict private
    FPipeName: String;
    FServer  : THandle;   // the only instance
    FHolder  : THandle;   // the client that keeps it taken
  public
    constructor Create;
    destructor Destroy; override;
    property PipeName: String read FPipeName;
  end;


  // Moves the discovery folder of THIS test process (%TEMP%\Autopilot\active, read by
  // Autopilot.Mcp.PipeClient.ListTargets) into a private folder, by pointing the TMP variable of the
  // process at it, and announces one fake target there: this process's own pid, served by APipeName.
  // So the tools can be called with "pid" = GetCurrentProcessId. The live MCP servers and a bridge
  // test run elsewhere on this PC never see the fake target, and their targets never reach the test.
  // Destroy restores TMP and deletes the folder.
  TPrivateDiscovery = class
  strict private
    FOldTmp  : String;
    FRoot    : String;
    FTmpMoved: Boolean;
  public
    constructor Create(const APipeName: String);
    destructor Destroy; override;
  end;


implementation

uses
  System.SysUtils, System.IOUtils, System.JSON,
  Autopilot.Bridge.Core,
  Autopilot.Bridge.Log,
  Autopilot.Mcp.PipeClient;


var
  GPipeSeq: Integer = 0;   // makes each fixture's pipe name unique within the test run


function NewFakePipeName: String;
begin
  Result := '\\.\pipe\Autopilot.FakeTest.' + IntToStr(GetCurrentProcessId) +
            '.' + IntToStr(TInterlocked.Increment(GPipeSeq));
end;


{ # Synthetic bridge-side pipe server }

constructor TFakePipeBridge.Create(const AResponseJson: String);
begin
  FResponse := AResponseJson;
  FPipeName := NewFakePipeName;
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


{ # Busy pipe }

constructor TBusyPipe.Create;
begin
  inherited Create;
  FServer := INVALID_HANDLE_VALUE;   // set before anything can raise: Destroy runs on a failed Create
  FHolder := INVALID_HANDLE_VALUE;
  FPipeName := NewFakePipeName;
  FServer := CreateNamedPipeW(PWideChar(FPipeName),
               PIPE_ACCESS_DUPLEX or FILE_FLAG_FIRST_PIPE_INSTANCE,
               PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT,
               1, 65536, 65536, 0, nil);
  if FServer = INVALID_HANDLE_VALUE then RaiseLastOSError;
  // A client may connect before the server calls ConnectNamedPipe; this one takes the only instance.
  FHolder := CreateFileW(PWideChar(FPipeName), GENERIC_READ or GENERIC_WRITE, 0, nil, OPEN_EXISTING, 0, 0);
  if FHolder = INVALID_HANDLE_VALUE then RaiseLastOSError;
end;


destructor TBusyPipe.Destroy;
begin
  if FHolder <> INVALID_HANDLE_VALUE then CloseHandle(FHolder);
  if FServer <> INVALID_HANDLE_VALUE then CloseHandle(FServer);
  inherited;
end;


{ # Private discovery folder }

constructor TPrivateDiscovery.Create(const APipeName: String);
var
  ActiveFolder: String;
begin
  inherited Create;
  // Autopilot.Bridge.Log fixes its file path on its first line. Write one now, so the log stays in the real %TEMP%.
  BridgeLogInfo('tests', 'private discovery folder for ' + APipeName);

  FOldTmp := System.SysUtils.GetEnvironmentVariable('TMP');
  FRoot   := TPath.Combine(TPath.GetTempPath, 'AutopilotTestsMcp-' + IntToStr(GetCurrentProcessId) +
                                              '-' + IntToStr(TInterlocked.Increment(GPipeSeq)));
  ForceDirectories(FRoot);
  if not Winapi.Windows.SetEnvironmentVariable('TMP', PChar(FRoot)) then RaiseLastOSError;
  FTmpMoved := TRUE;
  if not SameText(ExcludeTrailingPathDelimiter(TPath.GetTempPath), FRoot)
  then raise Exception.Create('TPrivateDiscovery: GetTempPath did not follow TMP, it returns ' + TPath.GetTempPath);

  ActiveFolder := DiscoveryFolderPath;
  ForceDirectories(ActiveFolder);
  TFile.WriteAllText(TPath.Combine(ActiveFolder, IntToStr(GetCurrentProcessId) + '.pipe'), APipeName, TEncoding.ASCII);
end;


destructor TPrivateDiscovery.Destroy;
begin
  if FTmpMoved then
    if FOldTmp = ''
    then Winapi.Windows.SetEnvironmentVariable('TMP', nil)   // TMP was not set before: remove it again
    else Winapi.Windows.SetEnvironmentVariable('TMP', PChar(FOldTmp));
  if (FRoot <> '') and TDirectory.Exists(FRoot) then
    TDirectory.Delete(FRoot, TRUE);
  inherited;
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


procedure TPipeClientTests.Test_BusyPipe_RaisesNotResponding;
var
  Busy       : TBusyPipe;
  Req        : TJSONObject;
  Resp       : TJSONObject;
  T0, Elapsed: UInt64;
  RaisedClass: String;
  RaisedMsg  : String;
begin
  // GitHub issue #2: the target's only pipe instance stays taken, so every connect fails with
  // ERROR_PIPE_BUSY. After the retry window CallTarget must raise ETargetNotResponding (which
  // Autopilot.Mcp.ToolBase turns into -32098), not a plain "could not open pipe ... (code 231)".
  Busy := TBusyPipe.Create;
  try
    Req := TJSONObject.Create;
    Req.AddPair('id', TJSONNumber.Create(1));
    Req.AddPair('cmd', 'get_text');
    RaisedClass := '';
    RaisedMsg   := '';
    T0 := GetTickCount64;
    try
      try
        Resp := CallTarget(Busy.PipeName, Req, 300);
        FreeAndNil(Resp);   // must not be reached
      except
        on E: Exception do   // recorded, then judged by the asserts below
        begin
          RaisedClass := E.ClassName;
          RaisedMsg   := E.Message;
        end;
      end;
    finally
      FreeAndNil(Req);
    end;
    Elapsed := GetTickCount64 - T0;

    Assert.AreEqual('ETargetNotResponding', RaisedClass, 'wrong exception for a busy pipe: ' + RaisedMsg);
    Assert.IsTrue(RaisedMsg.Contains(Busy.PipeName), 'message does not name the pipe: ' + RaisedMsg);
    Assert.IsTrue(RaisedMsg.Contains('busy'), 'message does not say the pipe is busy: ' + RaisedMsg);
    Assert.IsTrue(Elapsed >= 250, 'gave up before the retry window ended (' + IntToStr(Elapsed) + ' ms)');
  finally
    FreeAndNil(Busy);
  end;
end;


initialization
  TDUnitX.RegisterTestFixture(TPipeClientTests);

end.
