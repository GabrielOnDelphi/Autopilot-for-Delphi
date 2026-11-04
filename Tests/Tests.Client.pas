unit Tests.Client;

{=============================================================================================================
   2026.10.13
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for Autopilot.Client (TAutopilotApp), four fixtures:
     TClientTransportTests: a fake bridge on a plain thread - handshake, protocol check, error answers, the
       deadline, the retries, the dialog list after -32004, the stoppedReason of click, DismissDialog
     TClientBridgeTests: the real VCL bridge of this process - each command once, and rule 9 (check 4)
     TClientHandlerTests: event handlers that raise - what each command answers (check 5)
     TClientStartTests: Start and Attach, without a demo app
   - The real bridge runs every command on this main thread, so the client calls it from a worker thread
     (RunOnWorkerAndPump) while this thread pumps
   - Measured values go to the console, on lines that start with [measure]
   - ProveFail = TRUE makes one expected value of every test wrong, so every test must fail (Gabriel's rule
     of 2026-10-02: each new test is seen failing once)
=============================================================================================================}

interface

uses
  Vcl.Forms,
  DUnitX.TestFramework,
  Autopilot.Client;

type
  [TestFixture]
  TClientTransportTests = class
  private
    FCounter: Integer;
    function NewPipeName: String;
  public
    [Test] procedure Test_GetText_ReturnsTheAnswerText;
    [Test] procedure Test_EveryRequestCarriesTimeoutMs;
    [Test] procedure Test_ProtocolMismatch_RaisesWithBothVersions;
    [Test] procedure Test_ErrorAnswer_RaisesWithCodeAndData;
    [Test] procedure Test_SilentTarget_RaisesNotRespondingAfterTimeoutPlusGrace;
    [Test] procedure Test_BusyPipe_IsRetried;
    [Test] procedure Test_PipeBusyForTheWholeTimeout_RaisesNotResponding;
    [Test] procedure Test_MissingPipe_IsRetriedUntilItAppears;
    [Test] procedure Test_EndedTarget_FailsAtOnceWithExitCode;
    [Test] procedure Test_MainThreadBlocked_MessageNamesOpenDialogs;
    [Test] procedure Test_Click_ExceptionStoppedReason_RaisesHandlerError;
    [Test] procedure Test_Click_ReturnsClicksDispatched;
    [Test] procedure Test_DismissDialog_BlindClickConfirmedByList;
    [Test] procedure Test_DismissDialog_BlindClickDialogStays_ReturnsFalse;
    [Test] procedure Test_DismissDialog_DialogAppearsLate_IsDismissed;
    [Test] procedure Test_DismissDialog_ButtonNotFound_ReturnsFalseAtOnce;
  end;

  [TestFixture]
  TClientBridgeTests = class
  private
    FForm   : TForm;            // TClientForm 'ClientForm'
    FApp    : TAutopilotApp;
    FPipe   : String;
    FCounter: Integer;
  public
    [SetupFixture]    procedure SetupFixture;
    [Setup]           procedure Setup;
    [TearDown]        procedure TearDown;
    [TearDownFixture] procedure TearDownFixture;

    [Test] procedure Test_SetText_ThenGetText;
    [Test] procedure Test_Click_FiresOnClickAndReturnsTheCount;
    [Test] procedure Test_SetChecked_ChecksTheBox;
    [Test] procedure Test_SetProperty_ThenReadProperty;
    [Test] procedure Test_ExecuteAction_RunsOnExecute;
    [Test] procedure Test_SendKeys_TypesTextThenPressesKeys;
    [Test] procedure Test_Screenshot_SavesAPngFile;
    [Test] procedure Test_WaitForText_SeesTheTimerText;
    [Test] procedure Test_WaitForText_TimesOutWithFalse;
    [Test] procedure Test_Call_ReturnsTheResultObject;
    [Test] procedure Test_WrongPath_RaisesNotFound;
    [Test] procedure Test_DismissDialog_NoDialogOpen_ReturnsFalse;
    [Test] procedure Test_MainThreadCallToOwnBridge_RaisesAtOnce;
    [Test] procedure Test_BackToBackCommands_PayNoRetrySleep;
  end;

  [TestFixture]
  TClientHandlerTests = class
  private
    FForm        : TForm;           // TClientRaiseForm 'ClientRaiseForm'
    FApp         : TAutopilotApp;
    FPipe        : String;
    FCounter     : Integer;
    FSavedHandler: TExceptionEvent;
  public
    [SetupFixture]    procedure SetupFixture;
    [Setup]           procedure Setup;
    [TearDown]        procedure TearDown;
    [TearDownFixture] procedure TearDownFixture;

    [Test] procedure Test_Click_RaisingOnClick_GivesHandlerError;
    [Test] procedure Test_ExecuteAction_RaisingOnExecute_GivesInternalError;
    [Test] procedure Test_SetProperty_RaisingSetter_GivesInternalError;
    [Test] procedure Test_SetChecked_RaisingOnClick_GivesInternalError;
    [Test] procedure Test_SetText_RaisingOnChange_GoesToApplicationOnException;
    [Test] procedure Test_SendKeys_RaisingOnKeyDown_GoesToApplicationOnException;
  end;

  [TestFixture]
  TClientStartTests = class
  public
    [Test] procedure Test_Start_MissingFile_RaisesNotRunning;
    [Test] procedure Test_Start_ProcessThatEndsAtOnce_RaisesWithExitCode;
    [Test] procedure Test_Start_NoBridge_TimesOutAndEndsTheApp;
    [Test] procedure Test_Attach_PidWithoutDiscoveryFile_RaisesNotRunning;
    [Test] procedure Test_Attach_ZeroWithTwoTargets_RaisesNamingBoth;
    [Test] procedure Test_Attach_ByPid_ReachesThatBridge;
  end;


implementation

uses
  Winapi.Windows,
  System.SysUtils, System.Classes, System.JSON, System.IOUtils, System.SyncObjs, System.Actions, System.Diagnostics,
  Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ActnList,
  Autopilot.Bridge.Core, Autopilot.Bridge.Vcl,
  Bridge.Tests;

const
  ProveFail = FALSE;   // TRUE: every test expects one wrong value and must fail. Set it back to FALSE after the run.

type
  TAutopilotAppAccess = class(TAutopilotApp);   // reaches the protected constructor CreateForPipe

  EClientFixtureError = class(Exception);


{ Expected values ---------------------------------------------------------- }

function Want(const S: String): String; overload;
begin
  if ProveFail
  then Result := S + ' (wrong on purpose)'
  else Result := S;
end;


function Want(N: Integer): Integer; overload;
begin
  if ProveFail
  then Result := N + 1
  else Result := N;
end;


function Want(B: Boolean): Boolean; overload;
begin
  Result := B <> ProveFail;
end;


{ What a call raised ------------------------------------------------------- }

type
  { The class name of the exception ('' = nothing was raised), its message, the Code and Data of an EAutopilotError, and how long the call took }
  TRaised = record
    Cls      : String;
    Msg      : String;
    Code     : Integer;
    Data     : String;
    ElapsedMs: UInt64;
  end;


function Catch(const AProc: TProc): TRaised;
var
  T0: UInt64;
begin
  Result := Default(TRaised);
  T0 := GetTickCount64;
  try
    AProc();
  except
    on E: EAutopilotError do
    begin
      Result.Cls  := E.ClassName;
      Result.Msg  := E.Message;
      Result.Code := E.Code;
      Result.Data := E.Data;
    end;
    // The tests assert on the class, so every class is recorded
    on E: Exception do
    begin
      Result.Cls := E.ClassName;
      Result.Msg := E.Message;
    end;
  end;
  Result.ElapsedMs := GetTickCount64 - T0;
end;


// Catch on a worker thread, while this main thread pumps the bridge's queue
function CatchOnWorker(const AProc: TProc): TRaised;
var
  Proc: TProc;
  Got : TRaised;
begin
  Proc := AProc;
  Got  := Default(TRaised);
  RunOnWorkerAndPump(
    procedure
    begin
      Got := Catch(Proc);
    end, 30000);
  Result := Got;
end;


{ Catch on a worker thread, while this main thread waits on the bridge's queue itself (CheckSynchronize with a 1 ms wait).
  RunOnWorkerAndPump looks at the queue only every 10 ms, which would add up to 10 ms to every command: for a time measurement. }
function CatchOnWorkerFast(const AProc: TProc; ATimeoutMs: Cardinal): TRaised;
var
  Proc: TProc;
  Got : TRaised;
  Done: TEvent;
  Deadline: UInt64;
  Msg: TMsg;
begin
  Proc := AProc;
  Got  := Default(TRaised);
  Done := TEvent.Create(NIL, TRUE, FALSE, '');
  try
    TThread.CreateAnonymousThread(
      procedure
      begin
        Got := Catch(Proc);   // Catch never raises
        Done.SetEvent;
      end).Start;
    Deadline := GetTickCount64 + ATimeoutMs;
    while Done.WaitFor(0) <> wrSignaled do
    begin
      CheckSynchronize(1);
      while PeekMessage(Msg, 0, 0, 0, PM_REMOVE) do
      begin
        TranslateMessage(Msg);
        DispatchMessage(Msg);
      end;
      if GetTickCount64 > Deadline then
        raise EClientFixtureError.Create('CatchOnWorkerFast: the worker did not finish in time');
    end;
  finally
    FreeAndNil(Done);
  end;
  Result := Got;
end;


function Describe(const R: TRaised): String;
begin
  if R.Cls = '' then EXIT('answered ok, nothing raised');
  Result := R.Cls + ' code ' + IntToStr(R.Code) + ': ' + R.Msg;
  if R.Data <> '' then
    Result := Result + ' | data ' + R.Data;
end;


{ One measured value on the console. A plain routine on purpose: inside a test method, WriteLn means the one-string
  WriteLn of the DUnitX class helper for TObject (DUnitX.TestFramework.pas, TTestFixtureHelper) }
procedure Measure(const AText: String);
begin
  WriteLn('[measure] ' + AText);
end;


function PathArgs(const APath: String): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('path', APath);
end;


{ Processes and discovery files -------------------------------------------- }

function CmdExe: String;
begin
  Result := GetEnvironmentVariable('ComSpec');
  if Result = '' then
    Result := 'C:\Windows\System32\cmd.exe';
end;


{ Starts cmd.exe with AArgs; ASuspended: it does not run until resumed, so it stays alive. The caller closes both handles. }
function StartCmd(const AArgs: String; ASuspended: Boolean): TProcessInformation;
var
  SI: TStartupInfo;
  Exe, CmdLine: String;
  Flags: DWORD;
begin
  SI := Default(TStartupInfo);
  SI.cb := SizeOf(SI);
  Exe := CmdExe;
  CmdLine := '"' + Exe + '" ' + AArgs;
  UniqueString(CmdLine);
  if ASuspended
  then Flags := CREATE_SUSPENDED
  else Flags := 0;
  Result := Default(TProcessInformation);
  if not CreateProcess(PChar(Exe), PChar(CmdLine), NIL, NIL, FALSE, Flags, NIL, NIL, SI, Result) then
    RaiseLastOSError;
end;


function DiscoveryFolder: String;
begin
  Result := TPath.Combine(TPath.GetTempPath, 'Autopilot\active');
end;


function WaitForFile(const AFile: String; ATimeoutMs: Cardinal): Boolean;
var
  Deadline: UInt64;
begin
  Deadline := GetTickCount64 + ATimeoutMs;
  repeat
    if FileExists(AFile) then EXIT(TRUE);
    Sleep(20);
  until GetTickCount64 >= Deadline;
  Result := FileExists(AFile);
end;


// The number after '(pid ' in AMessage; 0 when there is none
function PidInMessage(const AMessage: String): Cardinal;
var
  P: Integer;
  Digits: String;
begin
  Result := 0;
  P := Pos('(pid ', AMessage);
  if P = 0 then EXIT;
  P := P + Length('(pid ');
  Digits := '';
  while (P <= Length(AMessage)) and CharInSet(AMessage[P], ['0'..'9']) do
  begin
    Digits := Digits + AMessage[P];
    Inc(P);
  end;
  if not TryStrToUInt(Digits, Result) then
    Result := 0;
end;


// timeoutMs of a request frame; -1 when it has none
function TimeoutOf(const AFrame: String): Integer;
var
  Root: TJSONValue;
  N: Int64;
begin
  Result := -1;
  Root := TJSONObject.ParseJSONValue(AFrame);
  try
    if (Root is TJSONObject) and TryJsonInt64(TJSONObject(Root).GetValue('timeoutMs'), N) then
      Result := Integer(N);
  finally
    FreeAndNil(Root);
  end;
end;


{ The fake bridge ---------------------------------------------------------- }

type
  { One connection of the fake bridge }
  TFakeSession = record
    HelloVersion: Integer;   // protocolVersion of its hello
    Answer      : String;    // the answer without its id: '"ok":true,"result":{...}'; '' = never answer
  end;

  { A fake bridge on a plain thread (no VCL). It serves the sessions in order, and the last one again for every further connection. }
  TFakeBridge = class(TThread)
  private
    FPipeName    : String;
    FSessions    : TArray<TFakeSession>;
    FStartDelayMs: Cardinal;    // the pipe does not exist before this: the client sees ERROR_FILE_NOT_FOUND
    FHoldFirstMs : Cardinal;    // the first connection (a blocker) is held this long: the client sees ERROR_PIPE_BUSY
    FPipe        : THandle;
    FReady       : TEvent;      // set once the pipe exists
    FRequests    : TStringList; // every request frame received; read it only after Shutdown
    function  ConnectClient: Boolean;
    procedure Serve(const ASession: TFakeSession);
  protected
    procedure Execute; override;
  public
    constructor Create(const APipeName: String; const ASessions: array of TFakeSession; AStartDelayMs, AHoldFirstMs: Cardinal);
    destructor Destroy; override;
    function  WaitReady: Boolean;
    procedure Shutdown;
    property PipeName: String read FPipeName;
    property Requests: TStringList read FRequests;
  end;


function Session(const AAnswer: String; AHelloVersion: Integer = 1): TFakeSession;
begin
  Result.HelloVersion := AHelloVersion;
  Result.Answer       := AAnswer;
end;


constructor TFakeBridge.Create(const APipeName: String; const ASessions: array of TFakeSession; AStartDelayMs, AHoldFirstMs: Cardinal);
var
  i: Integer;
begin
  FPipeName     := APipeName;
  FStartDelayMs := AStartDelayMs;
  FHoldFirstMs  := AHoldFirstMs;
  FPipe         := INVALID_HANDLE_VALUE;
  SetLength(FSessions, Length(ASessions));
  for i := 0 to High(ASessions) do
    FSessions[i] := ASessions[i];
  FReady    := TEvent.Create(NIL, TRUE, FALSE, '');
  FRequests := TStringList.Create;
  inherited Create(FALSE);   // runs once the constructor has finished
end;


destructor TFakeBridge.Destroy;
begin
  inherited;   // Terminate + WaitFor when the test did not call Shutdown
  FreeAndNil(FRequests);
  FreeAndNil(FReady);
end;


function TFakeBridge.WaitReady: Boolean;
begin
  Result := FReady.WaitFor(3000) = wrSignaled;
end;


function TFakeBridge.ConnectClient: Boolean;
begin
  Result := ConnectNamedPipe(FPipe, NIL) or (GetLastError = ERROR_PIPE_CONNECTED);
end;


procedure TFakeBridge.Execute;
var
  i: Integer;
begin
  if FStartDelayMs > 0 then
    Sleep(FStartDelayMs);
  if Terminated then EXIT;
  FPipe := CreateNamedPipe(PChar(FPipeName), PIPE_ACCESS_DUPLEX, PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT,
                           1, 65536, 65536, 0, NIL);
  if FPipe = INVALID_HANDLE_VALUE then EXIT;   // WaitReady then answers FALSE
  try
    FReady.SetEvent;
    if FHoldFirstMs > 0 then
    begin
      if not ConnectClient then EXIT;
      Sleep(FHoldFirstMs);
      DisconnectNamedPipe(FPipe);
    end;
    i := 0;
    while not Terminated do
    begin
      if not ConnectClient or Terminated then Break;
      if i < Length(FSessions)
      then Serve(FSessions[i])
      else Serve(FSessions[High(FSessions)]);
      DisconnectNamedPipe(FPipe);
      Inc(i);
    end;
  finally
    CloseHandle(FPipe);
  end;
end;


procedure TFakeBridge.Serve(const ASession: TFakeSession);
var
  Stream: THandleStream;
  Frame, Id: String;
  Root: TJSONValue;
begin
  Stream := THandleStream.Create(FPipe);
  try
    if not TBridgeWire.TryWriteFrame(Stream, '{"hello":{"protocolVersion":' + IntToStr(ASession.HelloVersion) +
                                             ',"bridgeVersion":"fake","pid":4,"exe":"fake.exe"}}') then EXIT;
    if not TBridgeWire.TryReadFrame(Stream, Frame) then EXIT;   // no helloAck: the client refused the hello
    if not TBridgeWire.TryReadFrame(Stream, Frame) then EXIT;
    FRequests.Add(Frame);
    if ASession.Answer <> '' then
    begin
      Id := '0';
      Root := TJSONObject.ParseJSONValue(Frame);
      try
        if (Root is TJSONObject) and (TJSONObject(Root).GetValue('id') <> NIL) then
          Id := TJSONObject(Root).GetValue('id').ToJSON;
      finally
        FreeAndNil(Root);
      end;
      if not TBridgeWire.TryWriteFrame(Stream, '{"id":' + Id + ',' + ASession.Answer + '}') then EXIT;
    end;
    // Wait until the client closes: DisconnectNamedPipe throws away an answer the client has not read yet
    TBridgeWire.TryReadFrame(Stream, Frame);
  finally
    FreeAndNil(Stream);
  end;
end;


procedure TFakeBridge.Shutdown;
var
  Tries: Integer;
  H: THandle;
begin
  Terminate;
  Tries := 0;
  while not Finished and (Tries < 300) do
  begin
    // Wake a blocking ConnectNamedPipe or ReadFile: cancel it, and connect a dummy client for a ConnectNamedPipe that started after the cancel
    CancelSynchronousIo(Handle);
    H := CreateFile(PChar(FPipeName), GENERIC_READ or GENERIC_WRITE, 0, NIL, OPEN_EXISTING, 0, 0);
    if H <> INVALID_HANDLE_VALUE then
      CloseHandle(H);
    Sleep(10);
    Inc(Tries);
  end;
  WaitFor;
end;


// Takes the only instance of the fake's pipe, as another client would
function OpenBlocker(const APipeName: String): THandle;
var
  Deadline: UInt64;
begin
  Deadline := GetTickCount64 + 2000;
  repeat
    Result := CreateFile(PChar(APipeName), GENERIC_READ or GENERIC_WRITE, 0, NIL, OPEN_EXISTING, 0, 0);
    if Result <> INVALID_HANDLE_VALUE then EXIT;
    Sleep(10);
  until GetTickCount64 >= Deadline;
end;


{ TClientTransportTests ---------------------------------------------------- }

function TClientTransportTests.NewPipeName: String;
begin
  Inc(FCounter);
  Result := '\\.\pipe\AutopilotTestFake.' + IntToStr(GetCurrentProcessId) + '.' + IntToStr(FCounter);
end;


procedure TClientTransportTests.Test_GetText_ReturnsTheAnswerText;
var
  Fake: TFakeBridge;
  App : TAutopilotApp;
  Text: String;
begin
  Fake := TFakeBridge.Create(NewPipeName, [Session('"ok":true,"result":{"text":"from the fake"}')], 0, 0);
  try
    Assert.IsTrue(Fake.WaitReady, 'the fake bridge did not start');
    App := TAutopilotAppAccess.CreateForPipe(Fake.PipeName, 0);
    try
      Text := App.GetText('Fake.lblText');
    finally
      FreeAndNil(App);
    end;
  finally
    Fake.Shutdown;
    FreeAndNil(Fake);
  end;
  Assert.AreEqual(Want('from the fake'), Text);
end;


procedure TClientTransportTests.Test_EveryRequestCarriesTimeoutMs;
var
  Fake: TFakeBridge;
  App : TAutopilotApp;
  Count, First, Second: Integer;
begin
  First  := -1;
  Second := -1;
  Fake := TFakeBridge.Create(NewPipeName, [Session('"ok":true,"result":{"text":"t"}'),
                                           Session('"ok":true,"result":{"dispatchedVia":"click","clicksDispatched":3}')], 0, 0);
  try
    Assert.IsTrue(Fake.WaitReady, 'the fake bridge did not start');
    App := TAutopilotAppAccess.CreateForPipe(Fake.PipeName, 0);
    try
      App.GetText('Fake.lblText');
      App.Click('Fake.btnGo', 3);
    finally
      FreeAndNil(App);
    end;
    Fake.Shutdown;
    Count := Fake.Requests.Count;
    if Count > 0 then First  := TimeoutOf(Fake.Requests[0]);
    if Count > 1 then Second := TimeoutOf(Fake.Requests[1]);
  finally
    Fake.Shutdown;
    FreeAndNil(Fake);
  end;
  Assert.AreEqual(2, Count, 'requests the fake received');
  Assert.AreEqual(Want(2000), First, 'timeoutMs of get_text (the bridge default of a read command)');
  Assert.AreEqual(5200, Second, 'timeoutMs of a click with count 3 (5000 + 2 x 100)');
end;


procedure TClientTransportTests.Test_ProtocolMismatch_RaisesWithBothVersions;
var
  Fake: TFakeBridge;
  App : TAutopilotApp;
  R   : TRaised;
begin
  Fake := TFakeBridge.Create(NewPipeName, [Session('"ok":true,"result":{"text":"t"}', 2)], 0, 0);
  try
    Assert.IsTrue(Fake.WaitReady, 'the fake bridge did not start');
    App := TAutopilotAppAccess.CreateForPipe(Fake.PipeName, 0);
    try
      R := Catch(procedure begin App.GetText('Fake.lblText'); end);
    finally
      FreeAndNil(App);
    end;
  finally
    Fake.Shutdown;
    FreeAndNil(Fake);
  end;
  Assert.AreEqual(Want('EAutopilotError'), R.Cls, R.Msg);
  Assert.AreEqual(ErrProtocolMismatch, R.Code, 'Code');
  Assert.Contains(R.Msg, 'protocol 2', 'the number the bridge speaks');
  Assert.Contains(R.Msg, 'protocol 1', 'the number the client speaks');
end;


procedure TClientTransportTests.Test_ErrorAnswer_RaisesWithCodeAndData;
var
  Fake: TFakeBridge;
  App : TAutopilotApp;
  R   : TRaised;
begin
  Fake := TFakeBridge.Create(NewPipeName,
    [Session('"ok":false,"error":{"code":-32001,"message":"no component matches Fake.nope","data":{"hint":"h"}}')], 0, 0);
  try
    Assert.IsTrue(Fake.WaitReady, 'the fake bridge did not start');
    App := TAutopilotAppAccess.CreateForPipe(Fake.PipeName, 0);
    try
      R := Catch(procedure begin App.GetText('Fake.nope'); end);
    finally
      FreeAndNil(App);
    end;
  finally
    Fake.Shutdown;
    FreeAndNil(Fake);
  end;
  Assert.AreEqual('EAutopilotError', R.Cls, R.Msg);
  Assert.AreEqual(Want(-32001), R.Code, 'Code');
  Assert.AreEqual('{"hint":"h"}', R.Data, 'Data');
  Assert.Contains(R.Msg, 'no component matches Fake.nope', 'the bridge''s message');
end;


procedure TClientTransportTests.Test_SilentTarget_RaisesNotRespondingAfterTimeoutPlusGrace;
var
  Fake: TFakeBridge;
  App : TAutopilotApp;
  R   : TRaised;
begin
  Fake := TFakeBridge.Create(NewPipeName, [Session('')], 0, 0);   // reads the request, never answers
  try
    Assert.IsTrue(Fake.WaitReady, 'the fake bridge did not start');
    App := TAutopilotAppAccess.CreateForPipe(Fake.PipeName, 0);
    try
      R := Catch(
        procedure
        var Res: TJSONObject;
        begin
          Res := App.Call('get_text', PathArgs('Fake.lblText'), 300);
          FreeAndNil(Res);
        end);
    finally
      FreeAndNil(App);
    end;
  finally
    Fake.Shutdown;
    FreeAndNil(Fake);
  end;
  Measure('a target that never answers (timeoutMs 300, grace ' + IntToStr(IoDeadlineGraceMs) + ' ms): ' + R.Cls + ' after ' + UIntToStr(R.ElapsedMs) + ' ms');
  Assert.AreEqual(Want('ETargetNotResponding'), R.Cls, R.Msg);
  Assert.IsTrue(R.ElapsedMs >= 2250, 'raised after ' + UIntToStr(R.ElapsedMs) + ' ms: before the deadline of 300 + 2000 ms');
  Assert.IsTrue(R.ElapsedMs < 3300,  'raised after ' + UIntToStr(R.ElapsedMs) + ' ms: long after the deadline of 300 + 2000 ms');
end;


procedure TClientTransportTests.Test_BusyPipe_IsRetried;
var
  Fake   : TFakeBridge;
  App    : TAutopilotApp;
  Blocker: THandle;
  Text   : String;
  T0, Elapsed: UInt64;
begin
  Fake := TFakeBridge.Create(NewPipeName, [Session('"ok":true,"result":{"text":"after the busy time"}')], 0, 400);
  try
    Assert.IsTrue(Fake.WaitReady, 'the fake bridge did not start');
    Blocker := OpenBlocker(Fake.PipeName);   // takes the only pipe instance; the fake holds it 400 ms, then drops it
    try
      Assert.IsTrue(Blocker <> INVALID_HANDLE_VALUE, 'the blocker could not connect');
      App := TAutopilotAppAccess.CreateForPipe(Fake.PipeName, 0);
      try
        T0 := GetTickCount64;
        Text := App.GetText('Fake.lblText');
        Elapsed := GetTickCount64 - T0;
      finally
        FreeAndNil(App);
      end;
    finally
      if Blocker <> INVALID_HANDLE_VALUE then
        CloseHandle(Blocker);
    end;
  finally
    Fake.Shutdown;
    FreeAndNil(Fake);
  end;
  Measure('a pipe held busy for 400 ms: GetText answered after ' + UIntToStr(Elapsed) + ' ms');
  Assert.AreEqual(Want('after the busy time'), Text);
  Assert.IsTrue(Elapsed >= 300, 'answered after ' + UIntToStr(Elapsed) + ' ms: the pipe was never busy');
end;


{ The busy wait (WaitNamedPipe) must end at the command's own timeout }
procedure TClientTransportTests.Test_PipeBusyForTheWholeTimeout_RaisesNotResponding;
var
  Fake   : TFakeBridge;
  App    : TAutopilotApp;
  Blocker: THandle;
  R      : TRaised;
begin
  Fake := TFakeBridge.Create(NewPipeName, [Session('"ok":true,"result":{"text":"t"}')], 0, 1500);
  try
    Assert.IsTrue(Fake.WaitReady, 'the fake bridge did not start');
    Blocker := OpenBlocker(Fake.PipeName);   // takes the only pipe instance for 1500 ms
    try
      Assert.IsTrue(Blocker <> INVALID_HANDLE_VALUE, 'the blocker could not connect');
      App := TAutopilotAppAccess.CreateForPipe(Fake.PipeName, 0);
      try
        R := Catch(
          procedure
          var Res: TJSONObject;
          begin
            Res := App.Call('get_text', PathArgs('Fake.lblText'), 300);
            FreeAndNil(Res);
          end);
      finally
        FreeAndNil(App);
      end;
    finally
      if Blocker <> INVALID_HANDLE_VALUE then
        CloseHandle(Blocker);
    end;
  finally
    Fake.Shutdown;
    FreeAndNil(Fake);
  end;
  Measure('a pipe busy for longer than the timeout (timeoutMs 300): ' + R.Cls + ' after ' + UIntToStr(R.ElapsedMs) + ' ms');
  Assert.AreEqual(Want('ETargetNotResponding'), R.Cls, R.Msg);
  Assert.Contains(R.Msg, 'stayed busy', 'the message says why');
  Assert.IsTrue(R.ElapsedMs >= 250, 'raised after ' + UIntToStr(R.ElapsedMs) + ' ms, before the timeout of 300 ms');
  Assert.IsTrue(R.ElapsedMs < 1000, 'raised after ' + UIntToStr(R.ElapsedMs) + ' ms, long after the timeout of 300 ms');
end;


procedure TClientTransportTests.Test_MissingPipe_IsRetriedUntilItAppears;
var
  Fake: TFakeBridge;
  App : TAutopilotApp;
  Text: String;
  T0, Elapsed: UInt64;
begin
  Fake := TFakeBridge.Create(NewPipeName, [Session('"ok":true,"result":{"text":"after the pipe appeared"}')], 400, 0);
  try
    App := TAutopilotAppAccess.CreateForPipe(Fake.PipeName, 0);
    try
      T0 := GetTickCount64;
      Text := App.GetText('Fake.lblText');
      Elapsed := GetTickCount64 - T0;
    finally
      FreeAndNil(App);
    end;
  finally
    Fake.Shutdown;
    FreeAndNil(Fake);
  end;
  Measure('a pipe that appears after 400 ms: GetText answered after ' + UIntToStr(Elapsed) + ' ms');
  Assert.AreEqual(Want('after the pipe appeared'), Text);
  // The fake's 400 ms run from its own start, a little before the client's first try
  Assert.IsTrue(Elapsed >= 300, 'answered after ' + UIntToStr(Elapsed) + ' ms: the pipe existed already');
end;


procedure TClientTransportTests.Test_EndedTarget_FailsAtOnceWithExitCode;
var
  PI : TProcessInformation;
  App: TAutopilotApp;
  R  : TRaised;
begin
  PI := StartCmd('/c exit 3', FALSE);
  try
    WaitForSingleObject(PI.hProcess, 10000);
    App := TAutopilotAppAccess.CreateForPipe(NewPipeName, PI.dwProcessId);   // nobody creates this pipe
    try
      R := Catch(
        procedure
        var Res: TJSONObject;
        begin
          Res := App.Call('get_text', PathArgs('Fake.lblText'), 3000);
          FreeAndNil(Res);
        end);
    finally
      FreeAndNil(App);
    end;
  finally
    CloseHandle(PI.hThread);
    CloseHandle(PI.hProcess);
  end;
  Measure('a target that has ended (timeoutMs 3000): ' + R.Cls + ' after ' + UIntToStr(R.ElapsedMs) + ' ms');
  Assert.AreEqual(Want('ETargetNotRunning'), R.Cls, R.Msg);
  Assert.Contains(R.Msg, 'exit code 3', 'the exit code of the ended process');
  Assert.IsTrue(R.ElapsedMs < 1000, 'raised after ' + UIntToStr(R.ElapsedMs) + ' ms: it waited for the timeout');
end;


procedure TClientTransportTests.Test_MainThreadBlocked_MessageNamesOpenDialogs;
var
  Fake  : TFakeBridge;
  App   : TAutopilotApp;
  R     : TRaised;
  Count : Integer;
  Second: String;
begin
  Second := '';
  Fake := TFakeBridge.Create(NewPipeName,
    [Session('"ok":false,"error":{"code":-32004,"message":"main thread did not respond within 5000 ms"}'),
     Session('"ok":true,"result":{"dialogs":[{"hwnd":4242,"class":"#32770","caption":"Fixture box","text":"boom in OnClick","buttons":[]}],"supported":true,"platform":"windows"}')],
    0, 0);
  try
    Assert.IsTrue(Fake.WaitReady, 'the fake bridge did not start');
    App := TAutopilotAppAccess.CreateForPipe(Fake.PipeName, 0);
    try
      R := Catch(procedure begin App.Click('Fake.btnGo'); end);
    finally
      FreeAndNil(App);
    end;
    Fake.Shutdown;
    Count := Fake.Requests.Count;
    if Count > 1 then Second := Fake.Requests[1];
  finally
    Fake.Shutdown;
    FreeAndNil(Fake);
  end;
  Assert.AreEqual(Want(ErrMainThreadBlocked), R.Code, R.Msg);
  Assert.Contains(R.Msg, 'Fixture box', 'the caption of the open dialog');
  Assert.Contains(R.Msg, 'boom in OnClick', 'the text of the open dialog');
  Assert.AreEqual(2, Count, 'the click, then the dialog list');
  Assert.Contains(Second, '"cmd":"dismiss_dialog"', 'the second request lists the dialogs');
  Assert.IsFalse(Pos('"button"', Second) > 0, 'the dialog list must not click a button: ' + Second);
end;


procedure TClientTransportTests.Test_Click_ExceptionStoppedReason_RaisesHandlerError;
var
  Fake: TFakeBridge;
  App : TAutopilotApp;
  R   : TRaised;
begin
  Fake := TFakeBridge.Create(NewPipeName,
    [Session('"ok":true,"result":{"dispatchedVia":"click","clicksDispatched":0,"stoppedReason":"exception:EAccessViolation"}')], 0, 0);
  try
    Assert.IsTrue(Fake.WaitReady, 'the fake bridge did not start');
    App := TAutopilotAppAccess.CreateForPipe(Fake.PipeName, 0);
    try
      R := Catch(procedure begin App.Click('Fake.btnGo'); end);
    finally
      FreeAndNil(App);
    end;
  finally
    Fake.Shutdown;
    FreeAndNil(Fake);
  end;
  Assert.AreEqual(Want('EAutopilotHandlerError'), R.Cls, R.Msg);
  Assert.Contains(R.Msg, 'EAccessViolation', 'the class the handler raised');
  Assert.Contains(R.Data, 'stoppedReason', 'Data holds the click answer');
end;


procedure TClientTransportTests.Test_Click_ReturnsClicksDispatched;
var
  Fake: TFakeBridge;
  App : TAutopilotApp;
  N   : Integer;
begin
  Fake :=TFakeBridge.Create(NewPipeName,
    [Session('"ok":true,"result":{"dispatchedVia":"click","clicksDispatched":2,"stoppedReason":"disabled"}')], 0, 0);
  try
    Assert.IsTrue(Fake.WaitReady, 'the fake bridge did not start');
    App := TAutopilotAppAccess.CreateForPipe(Fake.PipeName, 0);
    try
      N := App.Click('Fake.btnGo', 3);
    finally
      FreeAndNil(App);
    end;
  finally
    Fake.Shutdown;
    FreeAndNil(Fake);
  end;
  Assert.AreEqual(Want(2), N, 'clicksDispatched: the control became disabled after 2 of 3 clicks');
end;


procedure TClientTransportTests.Test_DismissDialog_BlindClickConfirmedByList;
var
  Fake : TFakeBridge;
  App  : TAutopilotApp;
  Gone : Boolean;
  Count: Integer;
  First: String;
begin
  First := '';
  Fake := TFakeBridge.Create(NewPipeName,
    [Session('"ok":true,"result":{"dialogs":[{"hwnd":777,"caption":"Confirm","text":"Sure?","buttons":[]}],"supported":true,"platform":"windows",' +
             '"clicked":true,"clickedId":1,"clickedCaption":"OK","dialogHwnd":777,"via":"WM_COMMAND"}'),
     Session('"ok":true,"result":{"dialogs":[],"supported":true,"platform":"windows"}')], 0, 0);
  try
    Assert.IsTrue(Fake.WaitReady, 'the fake bridge did not start');
    App := TAutopilotAppAccess.CreateForPipe(Fake.PipeName, 0);
    try
      Gone := App.DismissDialog('ok');
    finally
      FreeAndNil(App);
    end;
    Fake.Shutdown;
    Count := Fake.Requests.Count;
    if Count > 0 then First := Fake.Requests[0];
  finally
    Fake.Shutdown;
    FreeAndNil(Fake);
  end;
  Assert.AreEqual(Want(TRUE), Gone, 'the list after the blind click no longer holds the dialog');
  Assert.Contains(First, '"button":"ok"', 'the first request clicks the button');
  Assert.IsTrue(Count >= 2, 'a blind (WM_COMMAND) click must be confirmed by a dialog list; requests: ' + IntToStr(Count));
end;


procedure TClientTransportTests.Test_DismissDialog_BlindClickDialogStays_ReturnsFalse;
var
  Fake: TFakeBridge;
  App : TAutopilotApp;
  Gone: Boolean;
  T0, Elapsed: UInt64;
begin
  Fake :=TFakeBridge.Create(NewPipeName,
    [Session('"ok":true,"result":{"dialogs":[{"hwnd":777,"caption":"Confirm","text":"Sure?","buttons":[]}],"supported":true,"platform":"windows",' +
             '"clicked":true,"clickedId":1,"clickedCaption":"OK","dialogHwnd":777,"via":"WM_COMMAND"}'),
     Session('"ok":true,"result":{"dialogs":[{"hwnd":777,"caption":"Confirm","text":"Sure?","buttons":[]}],"supported":true,"platform":"windows"}')], 0, 0);
  try
    Assert.IsTrue(Fake.WaitReady, 'the fake bridge did not start');
    App := TAutopilotAppAccess.CreateForPipe(Fake.PipeName, 0);
    try
      T0 := GetTickCount64;
      Gone := App.DismissDialog('ok');
      Elapsed := GetTickCount64 - T0;
    finally
      FreeAndNil(App);
    end;
  finally
    Fake.Shutdown;
    FreeAndNil(Fake);
  end;
  Assert.AreEqual(Want(FALSE), Gone, 'the dialog is still in the list after the blind click');
  Assert.IsTrue(Elapsed >= 900, 'gave up after ' + UIntToStr(Elapsed) + ' ms: it must watch the list for about 1000 ms');
end;


const
  NoDialogAnswer = '"ok":true,"result":{"dialogs":[],"supported":true,"platform":"windows","clicked":false,"reason":"no_dialog"}';


{ ClickAsync returns before the click runs, so the dialog the click opens may not exist yet when DismissDialog is called }
procedure TClientTransportTests.Test_DismissDialog_DialogAppearsLate_IsDismissed;
var
  Fake : TFakeBridge;
  App  : TAutopilotApp;
  Gone : Boolean;
  Count, WithButton, i: Integer;
  T0, Elapsed: UInt64;
begin
  WithButton := 0;
  Fake := TFakeBridge.Create(NewPipeName,
    [Session(NoDialogAnswer), Session(NoDialogAnswer), Session(NoDialogAnswer), Session(NoDialogAnswer),
     Session('"ok":true,"result":{"dialogs":[{"hwnd":778,"caption":"Native Dialog","text":"Save?","buttons":[]}],"supported":true,"platform":"windows",' +
             '"clicked":true,"clickedId":2,"clickedCaption":"Cancel","dialogHwnd":778,"via":"BM_CLICK"}')], 0, 0);
  try
    Assert.IsTrue(Fake.WaitReady, 'the fake bridge did not start');
    App := TAutopilotAppAccess.CreateForPipe(Fake.PipeName, 0);
    try
      T0 := GetTickCount64;
      Gone := App.DismissDialog('cancel');
      Elapsed := GetTickCount64 - T0;
    finally
      FreeAndNil(App);
    end;
    Fake.Shutdown;
    Count := Fake.Requests.Count;
    for i := 0 to Count - 1 do
      if Pos('"button":"cancel"', Fake.Requests[i]) > 0 then
        Inc(WithButton);
  finally
    Fake.Shutdown;
    FreeAndNil(Fake);
  end;
  Measure('DismissDialog, a dialog that appears after 4 no_dialog answers: ' + BoolToStr(Gone, TRUE) + ' after ' + UIntToStr(Elapsed) + ' ms');
  Assert.AreEqual(Want(TRUE), Gone, 'the dialog appeared about 200 ms after DismissDialog was called');
  Assert.AreEqual(5, Count, 'four answers "no_dialog", then the click');
  Assert.AreEqual(5, WithButton, 'every try clicks the button');
end;


{ A dialog that is open but has no such button: the click cannot land, so DismissDialog must not wait for its deadline }
procedure TClientTransportTests.Test_DismissDialog_ButtonNotFound_ReturnsFalseAtOnce;
var
  Fake : TFakeBridge;
  App  : TAutopilotApp;
  Gone : Boolean;
  Count: Integer;
  T0, Elapsed: UInt64;
begin
  Fake := TFakeBridge.Create(NewPipeName,
    [Session('"ok":true,"result":{"dialogs":[{"hwnd":779,"caption":"Native Dialog","text":"Save?","buttons":[]}],"supported":true,' +
             '"platform":"windows","clicked":false,"reason":"button_not_found"}')], 0, 0);
  try
    Assert.IsTrue(Fake.WaitReady, 'the fake bridge did not start');
    App := TAutopilotAppAccess.CreateForPipe(Fake.PipeName, 0);
    try
      T0 := GetTickCount64;
      Gone := App.DismissDialog('retry');
      Elapsed := GetTickCount64 - T0;
    finally
      FreeAndNil(App);
    end;
    Fake.Shutdown;
    Count := Fake.Requests.Count;
  finally
    Fake.Shutdown;
    FreeAndNil(Fake);
  end;
  Assert.AreEqual(Want(FALSE), Gone, 'the dialog has no Retry button');
  Assert.AreEqual(1, Count, 'one request: the button cannot appear later');
  Assert.IsTrue(Elapsed < 500, 'returned after ' + UIntToStr(Elapsed) + ' ms: it waited for the deadline');
end;


{ The fixture forms -------------------------------------------------------- }

type
  { A form that is shown but never activated and never raised: off-screen, WS_EX_NOACTIVATE, no SetZOrder.
    send_keys needs a showing control (CanFocus), and the form must not take the focus from the user's window. }
  TClientQuietForm = class(TForm)
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure SetZOrder(TopMost: Boolean); override;
  public
    procedure ShowQuietly;
  end;

  TClientForm = class(TClientQuietForm)
  public
    EdtName   : TEdit;
    EdtKeys   : TEdit;
    BtnCount  : TButton;
    BtnDelayed: TButton;
    CbxFlag   : TCheckBox;
    LblStatus : TLabel;
    LblDelayed: TLabel;
    TmrDelayed: TTimer;
    ActList   : TActionList;
    ActRun    : TAction;
    ClickCount: Integer;
    ActionRuns: Integer;
    constructor Create(AOwner: TComponent); override;
    procedure Reset;
    procedure BtnCountClick(Sender: TObject);
    procedure BtnDelayedClick(Sender: TObject);
    procedure TmrDelayedTimer(Sender: TObject);
    procedure ActRunExecute(Sender: TObject);
  end;

  TClientRaiseForm = class(TClientQuietForm)
  private
    FBoomText: String;
    procedure SetBoomText(const AValue: String);
  public
    BtnBoom      : TButton;      // OnClick raises
    CbxBoom      : TCheckBox;    // OnClick raises
    EdtBoomChange: TEdit;        // OnChange raises
    EdtBoomKey   : TEdit;        // OnKeyDown raises
    ActList      : TActionList;
    ActBoom      : TAction;      // OnExecute raises
    AppException : String;       // what Application.OnException received
    constructor Create(AOwner: TComponent); override;
    procedure Reset;
    procedure Boom(Sender: TObject);
    procedure BoomKey(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure RecordAppException(Sender: TObject; E: Exception);
  published
    property BoomText: String read FBoomText write SetBoomText;   // the setter raises
  end;


procedure TClientQuietForm.CreateParams(var Params: TCreateParams);
begin
  inherited;
  Params.ExStyle := Params.ExStyle or WS_EX_NOACTIVATE or WS_EX_TOOLWINDOW;
end;


procedure TClientQuietForm.SetZOrder(TopMost: Boolean);
begin
  // Never raise the window: TCustomForm.Show ends in BringToFront
end;


procedure TClientQuietForm.ShowQuietly;
begin
  Position := poDesigned;
  SetBounds(-20000, -20000, 320, 240);
  Visible := TRUE;
end;


constructor TClientForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Name    := 'ClientForm';
  Caption := 'Client';

  EdtName := TEdit.Create(Self);
  EdtName.Name   := 'edtName';
  EdtName.Parent := Self;

  EdtKeys := TEdit.Create(Self);
  EdtKeys.Name   := 'edtKeys';
  EdtKeys.Parent := Self;
  EdtKeys.Top    := 30;

  BtnCount := TButton.Create(Self);
  BtnCount.Name    := 'btnCount';
  BtnCount.Parent  := Self;
  BtnCount.Top     := 60;
  BtnCount.OnClick := BtnCountClick;

  BtnDelayed := TButton.Create(Self);
  BtnDelayed.Name    := 'btnDelayed';
  BtnDelayed.Parent  := Self;
  BtnDelayed.Top     := 90;
  BtnDelayed.OnClick := BtnDelayedClick;

  CbxFlag := TCheckBox.Create(Self);
  CbxFlag.Name   := 'cbxFlag';
  CbxFlag.Parent := Self;
  CbxFlag.Top    := 120;

  LblStatus := TLabel.Create(Self);
  LblStatus.Name   := 'lblStatus';
  LblStatus.Parent := Self;
  LblStatus.Top    := 150;

  LblDelayed := TLabel.Create(Self);
  LblDelayed.Name   := 'lblDelayed';
  LblDelayed.Parent := Self;
  LblDelayed.Top    := 170;

  TmrDelayed := TTimer.Create(Self);
  TmrDelayed.Name     := 'tmrDelayed';
  TmrDelayed.Enabled  := FALSE;
  TmrDelayed.Interval := 150;
  TmrDelayed.OnTimer  := TmrDelayedTimer;

  ActList := TActionList.Create(Self);
  ActList.Name := 'alClient';

  ActRun := TAction.Create(Self);
  ActRun.Name       := 'actRun';
  ActRun.OnExecute  := ActRunExecute;
  ActRun.ActionList := ActList;
end;


procedure TClientForm.Reset;
begin
  EdtName.Text       := '';
  EdtKeys.Text       := '';
  BtnCount.Tag       := 0;
  CbxFlag.Checked    := FALSE;
  LblStatus.Caption  := 'ready';
  LblDelayed.Caption := 'waiting';
  TmrDelayed.Enabled := FALSE;
  ClickCount := 0;
  ActionRuns := 0;
end;


procedure TClientForm.BtnCountClick(Sender: TObject);
begin
  Inc(ClickCount);
end;


procedure TClientForm.BtnDelayedClick(Sender: TObject);
begin
  TmrDelayed.Enabled := TRUE;
end;


procedure TClientForm.TmrDelayedTimer(Sender: TObject);
begin
  TmrDelayed.Enabled := FALSE;
  LblDelayed.Caption := 'done';
end;


procedure TClientForm.ActRunExecute(Sender: TObject);
begin
  Inc(ActionRuns);
end;


constructor TClientRaiseForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Name    := 'ClientRaiseForm';
  Caption := 'Client raise';

  BtnBoom := TButton.Create(Self);
  BtnBoom.Name    := 'btnBoom';
  BtnBoom.Parent  := Self;
  BtnBoom.OnClick := Boom;

  CbxBoom := TCheckBox.Create(Self);
  CbxBoom.Name    := 'cbxBoom';
  CbxBoom.Parent  := Self;
  CbxBoom.Top     := 30;
  CbxBoom.OnClick := Boom;

  // The handler goes on last: setting Name sets the Text of a TEdit created in code, which would fire OnChange
  EdtBoomChange := TEdit.Create(Self);
  EdtBoomChange.Name     := 'edtBoomChange';
  EdtBoomChange.Parent   := Self;
  EdtBoomChange.Top      := 60;
  EdtBoomChange.Text     := '';
  EdtBoomChange.OnChange := Boom;

  EdtBoomKey := TEdit.Create(Self);
  EdtBoomKey.Name      := 'edtBoomKey';
  EdtBoomKey.Parent    := Self;
  EdtBoomKey.Top       := 90;
  EdtBoomKey.Text      := '';
  EdtBoomKey.OnKeyDown := BoomKey;

  ActList := TActionList.Create(Self);
  ActList.Name := 'alBoom';

  ActBoom := TAction.Create(Self);
  ActBoom.Name       := 'actBoom';
  ActBoom.OnExecute  := Boom;
  ActBoom.ActionList := ActList;
end;


procedure TClientRaiseForm.Reset;
begin
  AppException := '';
  // The raising handlers are off while the state is reset
  CbxBoom.OnClick := NIL;
  CbxBoom.Checked := FALSE;
  CbxBoom.OnClick := Boom;
  EdtBoomChange.OnChange := NIL;
  EdtBoomChange.Text     := '';
  EdtBoomChange.OnChange := Boom;
  EdtBoomKey.Text := '';
end;


procedure TClientRaiseForm.SetBoomText(const AValue: String);
begin
  raise EClientFixtureError.Create('boom from the BoomText setter (value "' + AValue + '")');
end;


procedure TClientRaiseForm.Boom(Sender: TObject);
begin
  raise EClientFixtureError.Create('boom from ' + TComponent(Sender).Name);
end;


procedure TClientRaiseForm.BoomKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  raise EClientFixtureError.Create('boom from ' + TComponent(Sender).Name + ' OnKeyDown');
end;


procedure TClientRaiseForm.RecordAppException(Sender: TObject; E: Exception);
begin
  AppException := E.ClassName + ': ' + E.Message;
end;


{ TClientBridgeTests ------------------------------------------------------- }

procedure TClientBridgeTests.SetupFixture;
begin
  FCounter := 0;
  FForm := TClientForm.Create(NIL);
  TClientForm(FForm).ShowQuietly;
end;


procedure TClientBridgeTests.Setup;
begin
  TClientForm(FForm).Reset;
  Inc(FCounter);
  FPipe := '\\.\pipe\AutopilotTestClient.' + IntToStr(GetCurrentProcessId) + '.' + IntToStr(FCounter);
  StartBridgeOnPipe(FPipe);
  FApp := TAutopilotAppAccess.CreateForPipe(FPipe, GetCurrentProcessId);
end;


procedure TClientBridgeTests.TearDown;
begin
  FreeAndNil(FApp);
  StopBridge;
end;


procedure TClientBridgeTests.TearDownFixture;
begin
  FreeAndNil(FForm);
end;


procedure TClientBridgeTests.Test_SetText_ThenGetText;
var
  App: TAutopilotApp;
  Got: String;
begin
  App := FApp;
  Got := '';
  RunOnWorkerAndPump(
    procedure
    begin
      App.SetText('ClientForm.edtName', 'Gabriel');
      Got := App.GetText('ClientForm.edtName');
    end, 15000);
  Assert.AreEqual(Want('Gabriel'), Got, 'GetText');
  Assert.AreEqual('Gabriel', TClientForm(FForm).EdtName.Text, 'the edit on the form');
end;


procedure TClientBridgeTests.Test_Click_FiresOnClickAndReturnsTheCount;
var
  App: TAutopilotApp;
  N  : Integer;
begin
  App := FApp;
  N   := -1;
  RunOnWorkerAndPump(
    procedure
    begin
      N := App.Click('ClientForm.btnCount', 3);
    end, 15000);
  Assert.AreEqual(Want(3), N, 'clicksDispatched');
  Assert.AreEqual(3, TClientForm(FForm).ClickCount, 'OnClick runs');
end;


procedure TClientBridgeTests.Test_SetChecked_ChecksTheBox;
var
  App: TAutopilotApp;
begin
  App := FApp;
  RunOnWorkerAndPump(
    procedure
    begin
      App.SetChecked('ClientForm.cbxFlag', TRUE);
    end, 15000);
  Assert.AreEqual(Want(TRUE), TClientForm(FForm).CbxFlag.Checked, 'Checked');
end;


procedure TClientBridgeTests.Test_SetProperty_ThenReadProperty;
var
  App: TAutopilotApp;
  Got: String;
begin
  App := FApp;
  Got := '';
  RunOnWorkerAndPump(
    procedure
    begin
      App.SetProperty('ClientForm.btnCount', 'Tag', '42');
      Got := App.ReadProperty('ClientForm.btnCount', 'Tag');
    end, 15000);
  Assert.AreEqual(Want('42'), Got, 'ReadProperty');
  Assert.AreEqual(42, TClientForm(FForm).BtnCount.Tag, 'Tag on the form');
end;


procedure TClientBridgeTests.Test_ExecuteAction_RunsOnExecute;
var
  App: TAutopilotApp;
  Ran: Boolean;
begin
  App := FApp;
  Ran := FALSE;
  RunOnWorkerAndPump(
    procedure
    begin
      Ran := App.ExecuteAction('ClientForm.actRun');
    end, 15000);
  Assert.AreEqual(Want(1), TClientForm(FForm).ActionRuns, 'OnExecute runs');
  Assert.IsTrue(Ran, 'executed');
end;


procedure TClientBridgeTests.Test_SendKeys_TypesTextThenPressesKeys;
var
  App: TAutopilotApp;
begin
  App := FApp;
  RunOnWorkerAndPump(
    procedure
    begin
      App.SendKeys('ClientForm.edtKeys', 'Backspace', 'abc');
    end, 15000);
  Assert.AreEqual(Want('ab'), TClientForm(FForm).EdtKeys.Text, 'abc typed, then Backspace');
end;


procedure TClientBridgeTests.Test_Screenshot_SavesAPngFile;
var
  App: TAutopilotApp;
  FileName, Signature: String;
  Bytes: TBytes;
  i: Integer;
begin
  App := FApp;
  FileName := TPath.Combine(TPath.GetTempPath, 'Autopilot_ClientTest_' + IntToStr(GetCurrentProcessId) + '.png');
  if FileExists(FileName) then
    System.SysUtils.DeleteFile(FileName);
  RunOnWorkerAndPump(
    procedure
    begin
      App.Screenshot('ClientForm', FileName);
    end, 30000);
  Signature := '';
  if FileExists(FileName) then
  begin
    Bytes := TFile.ReadAllBytes(FileName);
    for i := 0 to 7 do
      if i < Length(Bytes) then
        Signature := Signature + IntToHex(Bytes[i], 2);
    System.SysUtils.DeleteFile(FileName);
  end;
  Assert.AreEqual(Want('89504E470D0A1A0A'), Signature, 'the first 8 bytes of the file: the PNG signature');
end;


procedure TClientBridgeTests.Test_WaitForText_SeesTheTimerText;
var
  App : TAutopilotApp;
  Seen: Boolean;
begin
  App  := FApp;
  Seen := FALSE;
  RunOnWorkerAndPump(
    procedure
    begin
      App.Click('ClientForm.btnDelayed');   // a 150 ms timer writes 'done'
      Seen := App.WaitForText('ClientForm.lblDelayed', 'done', 3000);
    end, 15000);
  Assert.AreEqual(Want(TRUE), Seen, 'WaitForText');
  Assert.AreEqual('done', TClientForm(FForm).LblDelayed.Caption, 'the label on the form');
end;


procedure TClientBridgeTests.Test_WaitForText_TimesOutWithFalse;
var
  App : TAutopilotApp;
  Seen: Boolean;
  T0, Elapsed: UInt64;
begin
  App     := FApp;
  Seen    := TRUE;
  Elapsed := 0;
  RunOnWorkerAndPump(
    procedure
    begin
      T0 := GetTickCount64;
      Seen := App.WaitForText('ClientForm.lblStatus', 'a text that never comes', 400);
      Elapsed := GetTickCount64 - T0;
    end, 15000);
  Assert.AreEqual(Want(FALSE), Seen, 'WaitForText');
  Assert.IsTrue(Elapsed >= 400, 'gave up after ' + UIntToStr(Elapsed) + ' ms, before its timeout of 400 ms');
  Assert.IsTrue(Elapsed < 3000, 'gave up after ' + UIntToStr(Elapsed) + ' ms, long after its timeout of 400 ms');
end;


procedure TClientBridgeTests.Test_Call_ReturnsTheResultObject;
var
  App : TAutopilotApp;
  Text: String;
begin
  App  := FApp;
  Text := '';
  RunOnWorkerAndPump(
    procedure
    var
      Res: TJSONObject;
      V  : TJSONValue;
    begin
      Res := App.Call('get_text', PathArgs('ClientForm.lblStatus'));
      try
        V := Res.GetValue('text');
        if V is TJSONString then
          Text := TJSONString(V).Value;
      finally
        FreeAndNil(Res);
      end;
    end, 15000);
  Assert.AreEqual(Want('ready'), Text, 'result.text');
end;


procedure TClientBridgeTests.Test_WrongPath_RaisesNotFound;
var
  App: TAutopilotApp;
  R  : TRaised;
begin
  App := FApp;
  R := CatchOnWorker(procedure begin App.GetText('ClientForm.nope'); end);
  Assert.AreEqual('EAutopilotError', R.Cls, R.Msg);
  Assert.AreEqual(Want(ErrNotFound), R.Code, R.Msg);
end;


procedure TClientBridgeTests.Test_DismissDialog_NoDialogOpen_ReturnsFalse;
var
  App : TAutopilotApp;
  Gone: Boolean;
  Elapsed: UInt64;
begin
  App     := FApp;
  Gone    := TRUE;
  Elapsed := 0;
  RunOnWorkerAndPump(
    procedure
    var T0: UInt64;
    begin
      T0 := GetTickCount64;
      Gone := App.DismissDialog('ok', 400);
      Elapsed := GetTickCount64 - T0;
    end, 15000);
  Measure('DismissDialog with no dialog open (TimeoutMs 400): FALSE after ' + UIntToStr(Elapsed) + ' ms');
  Assert.AreEqual(Want(FALSE), Gone, 'no native dialog is open in this process');
  Assert.IsTrue(Elapsed >= 380, 'gave up after ' + UIntToStr(Elapsed) + ' ms: it must wait TimeoutMs (400 ms) for a dialog to appear');
  Assert.IsTrue(Elapsed < 2000, 'gave up after ' + UIntToStr(Elapsed) + ' ms: long after TimeoutMs (400 ms)');
end;


procedure TClientBridgeTests.Test_MainThreadCallToOwnBridge_RaisesAtOnce;
var
  App : TAutopilotApp;
  Warm: String;
  R   : TRaised;
begin
  App  := FApp;
  Warm := '';
  RunOnWorkerAndPump(
    procedure
    begin
      Warm := App.GetText('ClientForm.lblStatus');   // the same call from a worker thread: the pipe is up and answers
    end, 15000);
  R := Catch(procedure begin App.GetText('ClientForm.lblStatus'); end);   // from this main thread
  Measure('check 4 (rule 9): a call from the main thread to the bridge of its own process: ' + R.Cls + ' after ' + UIntToStr(R.ElapsedMs) + ' ms');
  Assert.AreEqual('ready', Warm, 'the call from a worker thread');
  Assert.AreEqual(Want('EInvalidOpException'), R.Cls, R.Msg);
  Assert.IsTrue(R.ElapsedMs < 100, 'raised after ' + UIntToStr(R.ElapsedMs) + ' ms, not at once');
end;


{ Check 1 of the build phase, in the suite: a command sent right after the previous one finds the bridge's single pipe
  instance still busy (ERROR_PIPE_BUSY) for a fraction of a millisecond. The client must not pay a whole sleep for it:
  a Sleep(25) lasts about 33 ms with the default timer tick (measured 2026-10-13, Record 4 check 1). }
procedure TClientBridgeTests.Test_BackToBackCommands_PayNoRetrySleep;
const
  Calls = 20;
var
  App   : TAutopilotApp;
  R     : TRaised;
  Last  : String;
  MeanUs, MaxUs: Int64;
begin
  App    := FApp;
  Last   := '';
  MeanUs := 0;
  MaxUs  := 0;
  R := CatchOnWorkerFast(
    procedure
    var
      i: Integer;
      Total, One: TStopwatch;
      Us: Int64;
    begin
      App.GetText('ClientForm.lblStatus');   // warm-up
      Total := TStopwatch.StartNew;
      for i := 1 to Calls do
      begin
        One := TStopwatch.StartNew;
        Last := App.GetText('ClientForm.lblStatus');
        Us := One.ElapsedTicks * 1000000 div TStopwatch.Frequency;
        if Us > MaxUs then
          MaxUs := Us;
      end;
      MeanUs := Total.ElapsedTicks * 1000000 div TStopwatch.Frequency div Calls;
    end, 30000);
  Measure('check 1 in the suite: ' + IntToStr(Calls) + ' back-to-back GetText calls to the bridge of this process: mean ' +
          IntToStr(MeanUs) + ' us, longest ' + IntToStr(MaxUs) + ' us');
  Assert.AreEqual('', R.Cls, Describe(R));
  Assert.AreEqual('ready', Last, 'GetText');
  Assert.AreEqual(Want(TRUE), MeanUs < 15000, 'mean ' + IntToStr(MeanUs) + ' us per command: the client slept after a busy pipe');
end;


{ TClientHandlerTests ------------------------------------------------------ }

procedure TClientHandlerTests.SetupFixture;
begin
  FCounter := 0;
  FForm := TClientRaiseForm.Create(NIL);
  TClientRaiseForm(FForm).ShowQuietly;
end;


procedure TClientHandlerTests.Setup;
begin
  TClientRaiseForm(FForm).Reset;
  // No error box: with no handler the VCL would show one, and it would block this main thread
  FSavedHandler := Application.OnException;
  Application.OnException := TClientRaiseForm(FForm).RecordAppException;
  Inc(FCounter);
  FPipe := '\\.\pipe\AutopilotTestClientRaise.' + IntToStr(GetCurrentProcessId) + '.' + IntToStr(FCounter);
  StartBridgeOnPipe(FPipe);
  FApp := TAutopilotAppAccess.CreateForPipe(FPipe, GetCurrentProcessId);
end;


procedure TClientHandlerTests.TearDown;
begin
  FreeAndNil(FApp);
  StopBridge;
  Application.OnException := FSavedHandler;
end;


procedure TClientHandlerTests.TearDownFixture;
begin
  FreeAndNil(FForm);
end;


procedure TClientHandlerTests.Test_Click_RaisingOnClick_GivesHandlerError;
var
  App: TAutopilotApp;
  R  : TRaised;
  F  : TClientRaiseForm;
begin
  App := FApp;
  F   := TClientRaiseForm(FForm);
  R := CatchOnWorker(procedure begin App.Click('ClientRaiseForm.btnBoom'); end);
  Measure('check 5: click, OnClick raises -> ' + Describe(R) + ' | Application.OnException: "' + F.AppException + '"');
  Assert.AreEqual(Want('EAutopilotHandlerError'), R.Cls, Describe(R));
  Assert.Contains(R.Msg, 'EClientFixtureError', 'the class the handler raised');
  Assert.AreEqual('', F.AppException, 'click keeps the exception away from Application.OnException');
end;


procedure TClientHandlerTests.Test_ExecuteAction_RaisingOnExecute_GivesInternalError;
var
  App: TAutopilotApp;
  R  : TRaised;
  F  : TClientRaiseForm;
begin
  App := FApp;
  F   := TClientRaiseForm(FForm);
  R := CatchOnWorker(procedure begin App.ExecuteAction('ClientRaiseForm.actBoom'); end);
  Measure('check 5: execute_action, OnExecute raises -> ' + Describe(R) + ' | Application.OnException: "' + F.AppException + '"');
  Assert.AreEqual('EAutopilotError', R.Cls, Describe(R));
  Assert.AreEqual(Want(ErrInternalError), R.Code, Describe(R));
  Assert.Contains(R.Msg, 'boom from actBoom', 'the handler''s message');
end;


procedure TClientHandlerTests.Test_SetProperty_RaisingSetter_GivesInternalError;
var
  App: TAutopilotApp;
  R  : TRaised;
  F  : TClientRaiseForm;
begin
  App := FApp;
  F   := TClientRaiseForm(FForm);
  R := CatchOnWorker(procedure begin App.SetProperty('ClientRaiseForm', 'BoomText', 'x'); end);
  Measure('check 5: set_property, the property setter raises -> ' + Describe(R) + ' | Application.OnException: "' + F.AppException + '"');
  Assert.AreEqual('EAutopilotError', R.Cls, Describe(R));
  Assert.AreEqual(Want(ErrInternalError), R.Code, Describe(R));
  Assert.Contains(R.Msg, 'boom from the BoomText setter', 'the setter''s message');
end;


procedure TClientHandlerTests.Test_SetChecked_RaisingOnClick_GivesInternalError;
var
  App: TAutopilotApp;
  R  : TRaised;
  F  : TClientRaiseForm;
begin
  App := FApp;
  F   := TClientRaiseForm(FForm);
  R := CatchOnWorker(procedure begin App.SetChecked('ClientRaiseForm.cbxBoom', TRUE); end);
  Measure('check 5: set_checked, OnClick raises -> ' + Describe(R) + ' | Application.OnException: "' + F.AppException + '"');
  Assert.AreEqual('EAutopilotError', R.Cls, Describe(R));
  Assert.AreEqual(Want(ErrInternalError), R.Code, Describe(R));
  Assert.Contains(R.Msg, 'boom from cbxBoom', 'the handler''s message');
end;


procedure TClientHandlerTests.Test_SetText_RaisingOnChange_GoesToApplicationOnException;
var
  App: TAutopilotApp;
  R  : TRaised;
  F  : TClientRaiseForm;
begin
  App := FApp;
  F   := TClientRaiseForm(FForm);
  R := CatchOnWorker(procedure begin App.SetText('ClientRaiseForm.edtBoomChange', 'changed'); end);
  Measure('check 5: set_text, OnChange raises -> ' + Describe(R) + ' | Application.OnException: "' + F.AppException + '"');
  Assert.AreEqual(Want(''), R.Cls, 'the client raised: ' + Describe(R));
  Assert.Contains(F.AppException, 'boom from edtBoomChange', 'the exception went to Application.OnException');
end;


procedure TClientHandlerTests.Test_SendKeys_RaisingOnKeyDown_GoesToApplicationOnException;
var
  App: TAutopilotApp;
  R  : TRaised;
  F  : TClientRaiseForm;
begin
  App := FApp;
  F   := TClientRaiseForm(FForm);
  R := CatchOnWorker(procedure begin App.SendKeys('ClientRaiseForm.edtBoomKey', 'A'); end);
  Measure('check 5: send_keys, OnKeyDown raises -> ' + Describe(R) + ' | Application.OnException: "' + F.AppException + '"');
  Assert.AreEqual(Want(''), R.Cls, 'the client raised: ' + Describe(R));
  Assert.Contains(F.AppException, 'boom from edtBoomKey', 'the exception went to Application.OnException');
end;


{ TClientStartTests -------------------------------------------------------- }

procedure TClientStartTests.Test_Start_MissingFile_RaisesNotRunning;
var
  R: TRaised;
begin
  R := Catch(
    procedure
    var App: TAutopilotApp;
    begin
      App := TAutopilotApp.Start('C:\Autopilot test\no such folder\NoSuchApp.exe');
      FreeAndNil(App);
    end);
  Assert.AreEqual(Want('ETargetNotRunning'), R.Cls, R.Msg);
  Assert.Contains(R.Msg, 'NoSuchApp.exe', 'the message names the file');
end;


procedure TClientStartTests.Test_Start_ProcessThatEndsAtOnce_RaisesWithExitCode;
var
  R: TRaised;
begin
  R := Catch(
    procedure
    var App: TAutopilotApp;
    begin
      App := TAutopilotApp.Start(CmdExe, '/c exit 7', 10000);
      FreeAndNil(App);
    end);
  Measure('Start of a process that ends at once (StartTimeoutMs 10000): ' + R.Cls + ' after ' + UIntToStr(R.ElapsedMs) + ' ms');
  Assert.AreEqual(Want('ETargetNotRunning'), R.Cls, R.Msg);
  Assert.Contains(R.Msg, 'exit code 7', 'the exit code');
  Assert.IsTrue(R.ElapsedMs < 3000, 'raised after ' + UIntToStr(R.ElapsedMs) + ' ms: it waited for StartTimeoutMs');
end;


procedure TClientStartTests.Test_Start_NoBridge_TimesOutAndEndsTheApp;
var
  R    : TRaised;
  Pid  : Cardinal;
  H    : THandle;
  Ended: Boolean;
begin
  // A process that runs for about 9 s and never writes a discovery file
  R := Catch(
    procedure
    var App: TAutopilotApp;
    begin
      App := TAutopilotApp.Start(CmdExe, '/c ping -n 10 127.0.0.1 >nul', 600);
      FreeAndNil(App);
    end);
  Pid   := PidInMessage(R.Msg);
  Ended := TRUE;
  if Pid <> 0 then
  begin
    H := OpenProcess(SYNCHRONIZE, FALSE, Pid);
    if H <> 0 then
    try
      Ended := WaitForSingleObject(H, 2000) = WAIT_OBJECT_0;
    finally
      CloseHandle(H);
    end;
  end;
  Measure('Start of a process without a bridge (StartTimeoutMs 600): ' + R.Cls + ' after ' + UIntToStr(R.ElapsedMs) + ' ms');
  Assert.AreEqual(Want('ETargetNotRunning'), R.Cls, R.Msg);
  Assert.Contains(R.Msg, 'AUTOPILOT', 'the message names the likely causes');
  Assert.IsTrue(Pid <> 0, 'the message names the pid: ' + R.Msg);
  Assert.IsTrue(Ended, 'the app must be gone once Start gave up');
  Assert.IsTrue(R.ElapsedMs >= 600, 'raised after ' + UIntToStr(R.ElapsedMs) + ' ms, before StartTimeoutMs');
  Assert.IsTrue(R.ElapsedMs < 4000, 'raised after ' + UIntToStr(R.ElapsedMs) + ' ms, long after StartTimeoutMs');
end;


procedure TClientStartTests.Test_Attach_PidWithoutDiscoveryFile_RaisesNotRunning;
var
  R: TRaised;
begin
  // Pid 4 is the Windows "System" process: it never runs an Autopilot bridge
  R := Catch(
    procedure
    var App: TAutopilotApp;
    begin
      App := TAutopilotApp.Attach(4);
      FreeAndNil(App);
    end);
  Assert.AreEqual(Want('ETargetNotRunning'), R.Cls, R.Msg);
  Assert.Contains(R.Msg, 'pid 4', 'the message names the pid');
end;


procedure TClientStartTests.Test_Attach_ZeroWithTwoTargets_RaisesNamingBoth;
var
  Job     : THandle;
  Limits  : TJobObjectExtendedLimitInformation;
  PI      : TProcessInformation;
  OwnFile, FakeFile: String;
  R       : TRaised;
  OtherPid: Cardinal;
begin
  { Target 1: the bridge of this process. Target 2: a discovery file for a suspended cmd.exe, which sits in a job that ends it with this process. }
  Job := CreateJobObject(NIL, NIL);
  Limits := Default(TJobObjectExtendedLimitInformation);
  Limits.BasicLimitInformation.LimitFlags := JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  SetInformationJobObject(Job, JobObjectExtendedLimitInformation, @Limits, SizeOf(Limits));
  PI := StartCmd('/c exit 0', TRUE);
  OtherPid := PI.dwProcessId;
  try
    AssignProcessToJobObject(Job, PI.hProcess);
    ForceDirectories(DiscoveryFolder);
    FakeFile := TPath.Combine(DiscoveryFolder, UIntToStr(OtherPid) + '.pipe');
    TFile.WriteAllText(FakeFile, '\\.\pipe\AutopilotTestNobody.' + UIntToStr(OtherPid));
    OwnFile := TPath.Combine(DiscoveryFolder, IntToStr(GetCurrentProcessId) + '.pipe');
    StartBridgeOnPipe('\\.\pipe\AutopilotTestAttach.' + IntToStr(GetCurrentProcessId) + '.2');
    try
      Assert.IsTrue(WaitForFile(OwnFile, 3000), 'the bridge of this process wrote no discovery file');
      R := Catch(
        procedure
        var App: TAutopilotApp;
        begin
          App := TAutopilotApp.Attach(0);
          FreeAndNil(App);
        end);
    finally
      StopBridge;
    end;
  finally
    System.SysUtils.DeleteFile(FakeFile);
    TerminateProcess(PI.hProcess, 0);
    CloseHandle(PI.hThread);
    CloseHandle(PI.hProcess);
    CloseHandle(Job);
  end;
  Assert.AreEqual(Want('ETargetNotRunning'), R.Cls, R.Msg);
  Assert.Contains(R.Msg, IntToStr(GetCurrentProcessId), 'the message names this process');
  Assert.Contains(R.Msg, UIntToStr(OtherPid), 'the message names the other target');
end;


procedure TClientStartTests.Test_Attach_ByPid_ReachesThatBridge;
var
  OwnFile: String;
  App    : TAutopilotApp;
  R      : TRaised;
  AppPid : Cardinal;
begin
  OwnFile :=TPath.Combine(DiscoveryFolder, IntToStr(GetCurrentProcessId) + '.pipe');
  StartBridgeOnPipe('\\.\pipe\AutopilotTestAttach.' + IntToStr(GetCurrentProcessId) + '.1');
  try
    Assert.IsTrue(WaitForFile(OwnFile, 3000), 'the bridge of this process wrote no discovery file');
    App := TAutopilotApp.Attach(GetCurrentProcessId);
    try
      AppPid := App.Pid;
      R := CatchOnWorker(procedure begin App.GetText('NoSuchForm.nope'); end);
    finally
      FreeAndNil(App);
    end;
  finally
    StopBridge;
  end;
  Assert.AreEqual(Want(Integer(GetCurrentProcessId)), Integer(AppPid), 'Pid');
  Assert.AreEqual(ErrNotFound, R.Code, 'the bridge of this process answered: ' + Describe(R));
end;


INITIALIZATION
  TDUnitX.RegisterTestFixture(TClientTransportTests);
  TDUnitX.RegisterTestFixture(TClientBridgeTests);
  TDUnitX.RegisterTestFixture(TClientHandlerTests);
  TDUnitX.RegisterTestFixture(TClientStartTests);

end.
