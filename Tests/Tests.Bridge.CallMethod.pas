unit Tests.Bridge.CallMethod;

{=============================================================================================================
   2026.11.14
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for the bridge command call_method (VCL bridge) and the registration API in Autopilot.Bridge.Commands:
       no name       - the list of the registered commands, sorted by name, with their descriptions
       a name + args - the handler runs on the main thread with args.args; its value comes back as result.result
       unknown name  - -32001, the message lists the registered names
       raising handler - -32603, the message carries the exception class and message
       slow handler  - -32004 after the caller's timeoutMs
       re-register   - replaces the handler; unregister removes the command
       a part of args - a handler that returns a value inside AArgs gets a copy sent, nothing is freed twice
       args in a new result - a new result that holds a pair, a name or a value of AArgs is sent as a copy; AArgs keeps its own
   - The registry is global: every test unregisters what it registered, in TearDown.
=============================================================================================================}

interface

uses
  System.JSON,
  DUnitX.TestFramework;

type
  [TestFixture]
  TCallMethodTests = class
  private
    FPipeName   : String;
    FPipeCounter: Integer;
    function Call(const AArgsJson: String; ATimeoutMs: Cardinal = 0): TJSONObject;
  public
    [SetupFixture] procedure SetupFixture;
    [Setup]        procedure Setup;
    [TearDown]     procedure TearDown;

    [Test] procedure Test_CallMethod_NoName_ListsCommandsSortedWithDescriptions;
    [Test] procedure Test_CallMethod_WithArgs_RunsOnMainThreadAndReturnsValue;
    [Test] procedure Test_CallMethod_NoArgs_HandlerGetsEmptyObject_NilResultIsNull;
    [Test] procedure Test_CallMethod_NameIsCaseInsensitive;
    [Test] procedure Test_CallMethod_UnknownName_Returns32001ListingNames;
    [Test] procedure Test_CallMethod_RaisingHandler_Returns32603WithClassAndMessage;
    [Test] procedure Test_CallMethod_SlowHandler_Returns32004AfterTimeoutMs;
    [Test] procedure Test_CallMethod_ReRegister_ReplacesHandler;
    [Test] procedure Test_CallMethod_Unregister_RemovesCommand;
    [Test] procedure Test_CallMethod_BadArgumentTypes_ReturnInvalidRequest;
    [Test] procedure Test_CallMethod_HandlerReturnsValueInsideArgs_SendsCopy;
    [Test] procedure Test_CallMethod_HandlerReturnsArgsOrAValueOfIt_SentValueIsAnotherObject;
    [Test] procedure Test_CallMethod_NewResultHoldsNodesOfArgs_SentAsCopy_ArgsKeepTheirs;
    [Test] procedure Test_CallMethod_NewResultHoldsAValueOfArgs_OverThePipe_AnswerIsRight;
  end;


implementation

uses
  Winapi.Windows,   // GetCurrentProcessId, GetCurrentThreadId
  System.SysUtils, System.Classes, System.Generics.Collections,   // Generics.Collections: inlines TJSONArray.GetValue
  Autopilot.Bridge.Core, Autopilot.Bridge.Vcl, Autopilot.Bridge.Commands,
  Bridge.TestClient, Bridge.Tests;


const
  CmdSum   = 'test.Sum';
  CmdAlpha = 'Alpha.First';
  CmdEcho  = 'test.Echo';
  CmdFail  = 'test.Fail';
  CmdSlow  = 'test.Slow';
  CmdSwap  = 'test.Swap';
  CmdNil   = 'test.Nil';
  CmdPart  = 'test.Part';
  CmdBuild = 'test.Build';
  AllNames: array[0..8] of String = (CmdSum, CmdAlpha, CmdEcho, CmdFail, CmdSlow, CmdSwap, CmdNil, CmdPart, CmdBuild);


{ Helpers --------------------------------------------------------------- }

function StrField(AObj: TJSONValue; const AName: String): String;
var
  V: TJSONValue;
begin
  Result := '';
  if not (AObj is TJSONObject) then EXIT;
  V := TJSONObject(AObj).GetValue(AName);
  if V is TJSONString
  then Result := TJSONString(V).Value;
end;


function ErrorMessageOf(ARoot: TJSONObject): String;
begin
  Result := '';
  if ARoot <> NIL
  then Result := StrField(ARoot.GetValue('error'), 'message');
end;


function OkResultOf(ARoot: TJSONObject; const AWhat: String): TJSONObject;
begin
  Assert.IsNotNull(ARoot, AWhat + ': no answer');
  Result := GetOkResult(ARoot);
  Assert.IsNotNull(Result, AWhat + ': call_method failed: ' + ARoot.ToJSON);
end;


{ TCallMethodTests ---------------------------------------------------------- }

procedure TCallMethodTests.SetupFixture;
begin
  FPipeCounter := 0;
end;


procedure TCallMethodTests.Setup;
begin
  Inc(FPipeCounter);
  FPipeName := '\\.\pipe\AutopilotTestCallMethod.' + IntToStr(GetCurrentProcessId) + '.' + IntToStr(FPipeCounter);
  StartBridgeOnPipe(FPipeName);
end;


procedure TCallMethodTests.TearDown;
var
  Name: String;
begin
  StopBridge;
  for Name in AllNames do
    UnregisterAutopilotCommand(Name);
end;


{ Sends call_method with the arguments AArgsJson ('' = no arguments) and returns the whole answer (the caller frees it). }
function TCallMethodTests.Call(const AArgsJson: String; ATimeoutMs: Cardinal = 0): TJSONObject;
var
  Root: TJSONObject;
  PipeName, ArgsJson: String;
  Timeout: Cardinal;
begin
  PipeName := FPipeName;
  ArgsJson := AArgsJson;
  Timeout  := ATimeoutMs;
  Root := NIL;
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args: TJSONObject;
    begin
      if ArgsJson = ''
      then Args := NIL
      else Args := TJSONObject.ParseJSONValue(ArgsJson) as TJSONObject;   // Call owns Args from here
      Client := TBridgeTestClient.Create;
      try
        if not Client.ConnectAndHandshake(PipeName, 2000) then
          begin
            FreeAndNil(Args);
            Assert.Fail('connect to ' + PipeName + ' failed');
          end;
        Root := Client.Call(1, 'call_method', Args, Timeout);
      finally
        FreeAndNil(Client);
      end;
    end, 10000);
  Result := Root;
end;


procedure TCallMethodTests.Test_CallMethod_NoName_ListsCommandsSortedWithDescriptions;
var
  Root: TJSONObject;
  Cmds: TJSONArray;
begin
  RegisterAutopilotCommand(CmdSum,   'Adds a and b.',  function(AArgs: TJSONObject): TJSONValue begin Result := NIL; end);
  RegisterAutopilotCommand(CmdAlpha, 'The first one.', function(AArgs: TJSONObject): TJSONValue begin Result := NIL; end);

  Root := Call('');
  try
    Assert.IsTrue(OkResultOf(Root, 'list').GetValue('commands') is TJSONArray, 'result.commands must be an array: ' + Root.ToJSON);
    Cmds := TJSONArray(OkResultOf(Root, 'list').GetValue('commands'));
    Assert.AreEqual(2, Cmds.Count, 'two commands are registered: ' + Root.ToJSON);
    // CompareText order: 'Alpha.First' < 'test.Sum'
    Assert.AreEqual(CmdAlpha,         StrField(Cmds.Items[0], 'name'),        'first name (sorted): ' + Root.ToJSON);
    Assert.AreEqual('The first one.', StrField(Cmds.Items[0], 'description'), 'first description');
    Assert.AreEqual(CmdSum,           StrField(Cmds.Items[1], 'name'),        'second name (sorted): ' + Root.ToJSON);
    Assert.AreEqual('Adds a and b.',  StrField(Cmds.Items[1], 'description'), 'second description');
  finally
    FreeAndNil(Root);
  end;

  // name "" also lists
  Root := Call('{"name":""}');
  try
    Assert.AreEqual(2, (OkResultOf(Root, 'name ""').GetValue('commands') as TJSONArray).Count, 'name "" must list too: ' + Root.ToJSON);
  finally
    FreeAndNil(Root);
  end;
end;


procedure TCallMethodTests.Test_CallMethod_WithArgs_RunsOnMainThreadAndReturnsValue;
var
  Root: TJSONObject;
  R: TJSONValue;
  HandlerThread: Cardinal;
begin
  HandlerThread := 0;
  RegisterAutopilotCommand(CmdSum, 'Adds a and b.',
    function(AArgs: TJSONObject): TJSONValue
    begin
      HandlerThread := GetCurrentThreadId;
      Result := TJSONObject.Create(TJSONPair.Create('sum', TJSONNumber.Create(AArgs.GetValue<Integer>('a') + AArgs.GetValue<Integer>('b'))));
    end);

  Root := Call('{"name":"' + CmdSum + '","args":{"a":2,"b":40}}');
  try
    Assert.AreEqual(CmdSum, StrField(OkResultOf(Root, 'sum'), 'name'), 'result.name: ' + Root.ToJSON);
    R := OkResultOf(Root, 'sum').GetValue('result');
    Assert.IsTrue(R is TJSONObject, 'result.result must be the object the handler returned: ' + Root.ToJSON);
    Assert.AreEqual('42', TJSONObject(R).GetValue('sum').Value, '2 + 40: ' + Root.ToJSON);
    Assert.IsTrue(HandlerThread = MainThreadID, 'the handler must run on the main thread (ran on ' + IntToStr(HandlerThread) + ')');
  finally
    FreeAndNil(Root);
  end;
end;


procedure TCallMethodTests.Test_CallMethod_NoArgs_HandlerGetsEmptyObject_NilResultIsNull;
var
  Root: TJSONObject;
  ArgsSeen: String;
begin
  ArgsSeen := '(handler did not run)';
  RegisterAutopilotCommand(CmdNil, 'Returns nothing.',
    function(AArgs: TJSONObject): TJSONValue
    begin
      if AArgs = NIL
      then ArgsSeen := 'NIL'
      else ArgsSeen := AArgs.ToJSON;
      Result := NIL;
    end);

  Root := Call('{"name":"' + CmdNil + '"}');
  try
    Assert.AreEqual('{}', ArgsSeen, 'without args the handler must get an empty object, never NIL');
    Assert.IsTrue(OkResultOf(Root, 'nil').GetValue('result') is TJSONNull, 'a NIL result must be sent as null: ' + Root.ToJSON);
  finally
    FreeAndNil(Root);
  end;

  // A handler that returns its own AArgs gets a copy sent, and nothing is freed twice.
  RegisterAutopilotCommand(CmdEcho, 'Returns its args.',
    function(AArgs: TJSONObject): TJSONValue
    begin
      Result := AArgs;
    end);
  Root := Call('{"name":"' + CmdEcho + '","args":{"x":"y"}}');
  try
    Assert.AreEqual('{"x":"y"}', OkResultOf(Root, 'echo').GetValue('result').ToJSON, 'the echo must be the args: ' + Root.ToJSON);
  finally
    FreeAndNil(Root);
  end;
end;


procedure TCallMethodTests.Test_CallMethod_NameIsCaseInsensitive;
var
  Root: TJSONObject;
begin
  RegisterAutopilotCommand(CmdSum, 'Returns 7.', function(AArgs: TJSONObject): TJSONValue begin Result := TJSONNumber.Create(7); end);
  Root := Call('{"name":"' + UpperCase(CmdSum) + '"}');
  try
    Assert.AreEqual('7', OkResultOf(Root, 'upper case').GetValue('result').Value, 'the name in upper case must find the command: ' + Root.ToJSON);
    Assert.AreEqual(CmdSum, StrField(OkResultOf(Root, 'upper case'), 'name'), 'result.name keeps the registered spelling');
  finally
    FreeAndNil(Root);
  end;
end;


procedure TCallMethodTests.Test_CallMethod_UnknownName_Returns32001ListingNames;
var
  Root: TJSONObject;
  Msg: String;
begin
  RegisterAutopilotCommand(CmdSum,   'Sum.',   function(AArgs: TJSONObject): TJSONValue begin Result := NIL; end);
  RegisterAutopilotCommand(CmdAlpha, 'Alpha.', function(AArgs: TJSONObject): TJSONValue begin Result := NIL; end);
  Root := Call('{"name":"NoSuchCommandXyz"}');
  try
    Assert.IsNotNull(Root, 'no answer');
    Assert.AreEqual(ErrNotFound, GetErrorCode(Root), 'an unknown name must answer -32001: ' + Root.ToJSON);
    Msg := ErrorMessageOf(Root);
    Assert.IsTrue(Msg.Contains('NoSuchCommandXyz'), 'the message must name the command asked for: ' + Msg);
    Assert.IsTrue(Msg.Contains(CmdSum),   'the message must list ' + CmdSum + ': ' + Msg);
    Assert.IsTrue(Msg.Contains(CmdAlpha), 'the message must list ' + CmdAlpha + ': ' + Msg);
  finally
    FreeAndNil(Root);
  end;
end;


procedure TCallMethodTests.Test_CallMethod_RaisingHandler_Returns32603WithClassAndMessage;
var
  Root: TJSONObject;
  Msg: String;
begin
  RegisterAutopilotCommand(CmdFail, 'Always raises.',
    function(AArgs: TJSONObject): TJSONValue
    begin
      raise EConvertError.Create('spectrum file is broken');
    end);
  Root := Call('{"name":"' + CmdFail + '"}');
  try
    Assert.IsNotNull(Root, 'no answer');
    Assert.AreEqual(ErrInternalError, GetErrorCode(Root), 'a raising handler must answer -32603: ' + Root.ToJSON);
    Msg := ErrorMessageOf(Root);
    Assert.IsTrue(Msg.Contains('EConvertError'),           'the message must carry the exception class: ' + Msg);
    Assert.IsTrue(Msg.Contains('spectrum file is broken'), 'the message must carry the exception message: ' + Msg);
    Assert.IsTrue(Msg.Contains(CmdFail),                   'the message must name the command: ' + Msg);
  finally
    FreeAndNil(Root);
  end;

  // The bridge still answers after the raise.
  RegisterAutopilotCommand(CmdSum, 'Returns 1.', function(AArgs: TJSONObject): TJSONValue begin Result := TJSONNumber.Create(1); end);
  Root := Call('{"name":"' + CmdSum + '"}');
  try
    Assert.AreEqual('1', OkResultOf(Root, 'after the raise').GetValue('result').Value, 'the next call must work: ' + Root.ToJSON);
  finally
    FreeAndNil(Root);
  end;
end;


procedure TCallMethodTests.Test_CallMethod_SlowHandler_Returns32004AfterTimeoutMs;
var
  Root: TJSONObject;
  HandlerDone: Boolean;
begin
  HandlerDone := FALSE;
  RegisterAutopilotCommand(CmdSlow, 'Sleeps 1500 ms.',
    function(AArgs: TJSONObject): TJSONValue
    begin
      Sleep(1500);
      HandlerDone := TRUE;
      Result := TJSONString.Create('late');
    end);
  Root := Call('{"name":"' + CmdSlow + '"}', 300);
  try
    Assert.IsNotNull(Root, 'no answer');
    Assert.AreEqual(ErrMainThreadBlocked, GetErrorCode(Root), 'a handler slower than timeoutMs must answer -32004: ' + Root.ToJSON);
    Assert.IsTrue(ErrorMessageOf(Root).Contains('300'), 'the message must name the 300 ms timeout: ' + Root.ToJSON);
    // RunOnWorkerAndPump pumped the handler on this thread, so it ended before the call returned; TearDown stops the bridge after it.
    Assert.IsTrue(HandlerDone, 'the late handler must still run to its end');
  finally
    FreeAndNil(Root);
  end;
end;


procedure TCallMethodTests.Test_CallMethod_ReRegister_ReplacesHandler;
var
  Root: TJSONObject;
  Cmds: TJSONArray;
begin
  RegisterAutopilotCommand(CmdSwap, 'Old.', function(AArgs: TJSONObject): TJSONValue begin Result := TJSONString.Create('old'); end);
  RegisterAutopilotCommand(CmdSwap, 'New.', function(AArgs: TJSONObject): TJSONValue begin Result := TJSONString.Create('new'); end);

  Root := Call('{"name":"' + CmdSwap + '"}');
  try
    Assert.AreEqual('new', OkResultOf(Root, 'swap').GetValue('result').Value, 'the second registration must replace the first: ' + Root.ToJSON);
  finally
    FreeAndNil(Root);
  end;

  Root := Call('');
  try
    Cmds := OkResultOf(Root, 'list').GetValue('commands') as TJSONArray;
    Assert.AreEqual(1, Cmds.Count, 'a re-registered name must be listed once: ' + Root.ToJSON);
    Assert.AreEqual('New.', StrField(Cmds.Items[0], 'description'), 'the description must be replaced too');
  finally
    FreeAndNil(Root);
  end;
end;


procedure TCallMethodTests.Test_CallMethod_Unregister_RemovesCommand;
var
  Root: TJSONObject;
begin
  RegisterAutopilotCommand(CmdSum, 'Sum.', function(AArgs: TJSONObject): TJSONValue begin Result := NIL; end);
  UnregisterAutopilotCommand(LowerCase(CmdSum));   // case-insensitive
  UnregisterAutopilotCommand('NeverRegistered');     // ignored

  Root := Call('{"name":"' + CmdSum + '"}');
  try
    Assert.AreEqual(ErrNotFound, GetErrorCode(Root), 'an unregistered command must answer -32001: ' + Root.ToJSON);
  finally
    FreeAndNil(Root);
  end;

  Root := Call('');
  try
    Assert.AreEqual(0, (OkResultOf(Root, 'list').GetValue('commands') as TJSONArray).Count, 'the list must be empty: ' + Root.ToJSON);
  finally
    FreeAndNil(Root);
  end;
end;


procedure TCallMethodTests.Test_CallMethod_BadArgumentTypes_ReturnInvalidRequest;
var
  Root: TJSONObject;
begin
  RegisterAutopilotCommand(CmdSum, 'Sum.', function(AArgs: TJSONObject): TJSONValue begin Result := NIL; end);

  Root := Call('{"name":5}');
  try
    Assert.AreEqual(ErrInvalidRequest, GetErrorCode(Root), 'a name that is not a string must answer -32600: ' + Root.ToJSON);
    Assert.IsTrue(ErrorMessageOf(Root).Contains('name'), 'the message must name the argument: ' + Root.ToJSON);
  finally
    FreeAndNil(Root);
  end;

  Root := Call('{"name":"' + CmdSum + '","args":[1,2]}');
  try
    Assert.AreEqual(ErrInvalidRequest, GetErrorCode(Root), 'args that is not an object must answer -32600: ' + Root.ToJSON);
    Assert.IsTrue(ErrorMessageOf(Root).Contains('args'), 'the message must name the argument: ' + Root.ToJSON);
  finally
    FreeAndNil(Root);
  end;
end;


{ TJSONObject.GetValue returns the pair's own value, still owned by AArgs.
  The bridge must send a copy of it; freeing the value itself would free it twice (a double free under FastMM FullDebugMode). }
procedure TCallMethodTests.Test_CallMethod_HandlerReturnsValueInsideArgs_SendsCopy;
var
  Root: TJSONObject;
begin
  RegisterAutopilotCommand(CmdPart, 'Returns a part of its args, picked by args.pick.',
    function(AArgs: TJSONObject): TJSONValue
    var
      Pick: String;
    begin
      Pick := AArgs.GetValue<string>('pick');
      if Pick = 'text'
      then Result := AArgs.GetValue('text')
      else
        if Pick = 'item'
        then Result := (AArgs.GetValue('list') as TJSONArray).Items[1]
        else Result := (AArgs.GetValue('obj') as TJSONObject).GetValue('inner');
    end);

  // A value of AArgs itself (the echo command a user writes first)
  Root := Call('{"name":"' + CmdPart + '","args":{"pick":"text","text":"hello"}}');
  try
    Assert.AreEqual('"hello"', OkResultOf(Root, 'text').GetValue('result').ToJSON, 'result.result must be the value of args.text: ' + Root.ToJSON);
  finally
    FreeAndNil(Root);
  end;

  // An item of an array inside AArgs
  Root := Call('{"name":"' + CmdPart + '","args":{"pick":"item","list":[1,"two",3]}}');
  try
    Assert.AreEqual('"two"', OkResultOf(Root, 'item').GetValue('result').ToJSON, 'result.result must be args.list[1]: ' + Root.ToJSON);
  finally
    FreeAndNil(Root);
  end;

  // An object two levels down
  Root := Call('{"name":"' + CmdPart + '","args":{"pick":"deep","obj":{"inner":{"k":"v"}}}}');
  try
    Assert.AreEqual('{"k":"v"}', OkResultOf(Root, 'deep').GetValue('result').ToJSON, 'result.result must be args.obj.inner: ' + Root.ToJSON);
  finally
    FreeAndNil(Root);
  end;
end;


{ Runs HandleCallMethod directly on the main thread with the request ARequestJson.
  Returns TRUE when the value the answer would send is the very object the handler returned (AHandlerResult): a pointer compare, so the check needs no memory manager to catch the double free.
  ASentJson: the sent value as JSON text, read only when it is a different object. }
function SendsTheHandlersOwnObject(const ARequestJson: String; const AHandlerResult: TFunc<TJSONValue>; OUT ASentJson: String): Boolean;
var
  Root: TJSONObject;
  Req: TBridgeRequest;
  Resp: TBridgeResponse;
  Sent: TJSONValue;
begin
  ASentJson := '';
  Root := TJSONObject.ParseJSONValue(ARequestJson) as TJSONObject;
  Assert.IsNotNull(Root, 'test request does not parse: ' + ARequestJson);
  Resp := Default(TBridgeResponse);
  try
    Req := Default(TBridgeRequest);
    Req.Cmd  := 'call_method';
    Req.Args := Root;
    Resp := HandleCallMethod(Req);
    Assert.IsTrue(Resp.Ok, 'call_method failed: ' + Resp.ErrorMessage);
    Assert.IsNotNull(Resp.ResultJson, 'call_method answered no result');
    Sent := Resp.ResultJson.GetValue('result');
    Result := (Sent <> NIL) and (Sent = AHandlerResult());
    if Result
    then Resp.ResultJson := NIL   // shared with AArgs (or already freed with it): freeing it here would free it twice; the test fails and leaks it
    else
      if Sent <> NIL
      then ASentJson := Sent.ToJSON;
  finally
    FreeAndNil(Resp.ResultJson);
    FreeAndNil(Root);
  end;
end;


{ The same rule as Test_CallMethod_HandlerReturnsValueInsideArgs_SendsCopy, checked without the pipe: the sent value must be another object than the one the handler returned. }
procedure TCallMethodTests.Test_CallMethod_HandlerReturnsArgsOrAValueOfIt_SentValueIsAnotherObject;
var
  Returned: TJSONValue;
  SentJson: String;
begin
  Returned := NIL;
  RegisterAutopilotCommand(CmdPart, 'Returns args.text.',
    function(AArgs: TJSONObject): TJSONValue
    begin
      Result   := AArgs.GetValue('text');
      Returned := Result;
    end);
  RegisterAutopilotCommand(CmdEcho, 'Returns its args.',
    function(AArgs: TJSONObject): TJSONValue
    begin
      Result   := AArgs;
      Returned := Result;
    end);

  // A value inside the args the request carried
  Assert.IsFalse(SendsTheHandlersOwnObject('{"name":"' + CmdPart + '","args":{"text":"hello"}}', function: TJSONValue begin Result := Returned; end, SentJson),
                 'the answer sends args.text itself, which the request still owns and frees');
  Assert.AreEqual('"hello"', SentJson, 'the sent copy of args.text');

  // No args given: the handler gets the empty object the bridge made, which the bridge frees right after the call
  Returned := NIL;
  Assert.IsFalse(SendsTheHandlersOwnObject('{"name":"' + CmdEcho + '"}', function: TJSONValue begin Result := Returned; end, SentJson),
                 'the answer sends the empty AArgs object itself, which the bridge frees after the handler returns');
  Assert.AreEqual('{}', SentJson, 'the sent copy of the empty AArgs');
end;


{ Adds ANode and every node under it (pairs, pair names, pair values, array items) to AList. Pointer collection only. }
procedure CollectNodes(ANode: TJSONAncestor; var AList: TArray<TJSONAncestor>);
var
  i: Integer;
  Pair: TJSONPair;
begin
  if ANode = NIL then EXIT;
  AList := AList + [ANode];
  if ANode is TJSONObject then
    for i := 0 to TJSONObject(ANode).Count - 1 do
      begin
        Pair := TJSONObject(ANode).Pairs[i];
        AList := AList + [TJSONAncestor(Pair)];
        CollectNodes(Pair.JsonString, AList);
        CollectNodes(Pair.JsonValue, AList);
      end
  else
    if ANode is TJSONArray then
      for i := 0 to TJSONArray(ANode).Count - 1 do
        CollectNodes(TJSONArray(ANode).Items[i], AList);
end;


function SharesANode(const A, B: TArray<TJSONAncestor>): Boolean;
var
  X, Y: TJSONAncestor;
begin
  for X in A do
    for Y in B do
      if X = Y then EXIT(TRUE);
  Result := FALSE;
end;


{ A handler that puts a pair, a pair name or a value of AArgs INTO a new result makes both AArgs and the result own that node, and both free it.
  The bridge must send a copy and leave the node to AArgs alone.
  Calls HandleCallMethod directly and compares pointers, so no memory manager has to catch the double free.
  Every case runs even when an earlier one fails: the message lists each failed case. }
procedure TCallMethodTests.Test_CallMethod_NewResultHoldsNodesOfArgs_SentAsCopy_ArgsKeepTheirs;
const
  ArgsJson = '{"text":"hello","list":[1,"two",3],"obj":{"inner":{"k":"v"}}}';
  CaseNames: array[1..8] of String = ('a pair value', 'an array item', 'a value two levels down', 'a whole array', 'a whole pair',
                                      'a pair name', 'one value used twice', 'the empty AArgs the bridge made');
  Expected : array[1..8] of String = ('{"x":"hello"}', '["two"]', '{"a":{"b":{"k":"v"}}}', '{"list":[1,"two",3]}', '{"text":"hello"}',
                                      '{"text":"new"}', '{"a":"hello","b":"hello"}', '{"args":{}}');
var
  CaseNo, i: Integer;
  ArgsSeen: TJSONObject;
  Returned, Sent: TJSONValue;
  Root: TJSONObject;
  Req: TBridgeRequest;
  Resp: TBridgeResponse;
  ArgsNodes, SentNodes: TArray<TJSONAncestor>;
  Node: TJSONAncestor;
  Shared: Boolean;
  Failures: String;
begin
  CaseNo   := 0;
  ArgsSeen := NIL;
  Returned := NIL;
  RegisterAutopilotCommand(CmdBuild, 'Builds a new result from parts of its args; the test picks the case.',
    function(AArgs: TJSONObject): TJSONValue
    var
      R, Inner: TJSONObject;
      A: TJSONArray;
      V: TJSONValue;
    begin
      ArgsSeen := AArgs;
      case CaseNo of
        1: begin R := TJSONObject.Create; R.AddPair('x', AArgs.GetValue('text')); Result := R; end;
        2: begin A := TJSONArray.Create; A.AddElement((AArgs.GetValue('list') as TJSONArray).Items[1]); Result := A; end;
        3: begin
             R := TJSONObject.Create;
             Inner := TJSONObject.Create;
             R.AddPair('a', Inner);
             Inner.AddPair('b', (AArgs.GetValue('obj') as TJSONObject).GetValue('inner'));
             Result := R;
           end;
        4: begin R := TJSONObject.Create; R.AddPair('list', AArgs.GetValue('list')); Result := R; end;
        5: begin R := TJSONObject.Create; R.AddPair(AArgs.Pairs[0]); Result := R; end;
        6: begin R := TJSONObject.Create; R.AddPair(TJSONPair.Create(AArgs.Pairs[0].JsonString, TJSONString.Create('new'))); Result := R; end;
        7: begin V := AArgs.GetValue('text'); R := TJSONObject.Create; R.AddPair('a', V); R.AddPair('b', V); Result := R; end;
        8: begin R := TJSONObject.Create; R.AddPair('args', AArgs); Result := R; end;
      else
        Result := TJSONObject.Create(TJSONPair.Create('n', TJSONNumber.Create(1)));   // all new: nothing of AArgs
      end;
      Returned := Result;
    end);

  Failures := '';
  for i := 1 to 8 do
    begin
      CaseNo := i;
      if i = 8
      then Root := TJSONObject.ParseJSONValue('{"name":"' + CmdBuild + '"}') as TJSONObject
      else Root := TJSONObject.ParseJSONValue('{"name":"' + CmdBuild + '","args":' + ArgsJson + '}') as TJSONObject;
      Resp := Default(TBridgeResponse);
      try
        Req := Default(TBridgeRequest);
        Req.Cmd  := 'call_method';
        Req.Args := Root;
        Resp := HandleCallMethod(Req);
        if not Resp.Ok or (Resp.ResultJson = NIL) then
          begin
            Failures := Failures + sLineBreak + CaseNames[i] + ': call_method failed: ' + Resp.ErrorMessage;
            Continue;
          end;
        Sent := Resp.ResultJson.GetValue('result');

        ArgsNodes := NIL;
        if i = 8
        then Shared := (Sent is TJSONObject) and (TJSONObject(Sent).GetValue('args') = ArgsSeen)   // pointer compare only: the bridge freed ArgsSeen after the call
        else
          begin
            SentNodes := NIL;
            CollectNodes(Root.GetValue('args'), ArgsNodes);
            CollectNodes(Sent, SentNodes);
            Shared := SharesANode(SentNodes, ArgsNodes);
          end;
        if Shared then
          begin
            Failures := Failures + sLineBreak + CaseNames[i] + ': the answer holds a node of AArgs itself, which AArgs frees too';
            Resp.ResultJson := NIL;   // freeing it would free the shared nodes twice: the failed case leaks it instead
            Continue;
          end;

        if Sent.ToJSON <> Expected[i]
        then Failures := Failures + sLineBreak + CaseNames[i] + ': sent ' + Sent.ToJSON + ', expected ' + Expected[i];
        for Node in ArgsNodes do
          if not Node.Owned then
            begin
              Failures := Failures + sLineBreak + CaseNames[i] + ': a node of AArgs is no longer owned, so AArgs would never free it';
              Break;
            end;
      finally
        FreeAndNil(Resp.ResultJson);
        FreeAndNil(Root);
      end;
    end;

  { # A new result with nothing of AArgs is sent as it is, not copied }
  CaseNo := 9;
  Root := TJSONObject.ParseJSONValue('{"name":"' + CmdBuild + '","args":' + ArgsJson + '}') as TJSONObject;
  Resp := Default(TBridgeResponse);
  try
    Req := Default(TBridgeRequest);
    Req.Cmd  := 'call_method';
    Req.Args := Root;
    Resp := HandleCallMethod(Req);
    if not Resp.Ok or (Resp.ResultJson = NIL)
    then Failures := Failures + sLineBreak + 'all new: call_method failed: ' + Resp.ErrorMessage
    else
      if Resp.ResultJson.GetValue('result') <> Returned
      then Failures := Failures + sLineBreak + 'all new: the result was copied although it holds nothing of AArgs';
  finally
    FreeAndNil(Resp.ResultJson);
    FreeAndNil(Root);
  end;

  Assert.IsTrue(Failures = '', 'failed cases:' + Failures);
end;


{ The same rule through the pipe: the answer text is right, and the bridge still answers a second call (no double free on the way). }
procedure TCallMethodTests.Test_CallMethod_NewResultHoldsAValueOfArgs_OverThePipe_AnswerIsRight;
var
  Root: TJSONObject;
  Pass: Integer;
begin
  RegisterAutopilotCommand(CmdBuild, 'Returns args.text as echo and the whole args as all.',
    function(AArgs: TJSONObject): TJSONValue
    var
      R: TJSONObject;
    begin
      R := TJSONObject.Create;
      R.AddPair('echo', AArgs.GetValue('text'));
      R.AddPair('all', AArgs);
      Result := R;
    end);

  for Pass := 1 to 2 do
    begin
      Root := Call('{"name":"' + CmdBuild + '","args":{"text":"hello"}}');
      try
        Assert.AreEqual('{"echo":"hello","all":{"text":"hello"}}', OkResultOf(Root, 'round ' + IntToStr(Pass)).GetValue('result').ToJSON,
                        'round ' + IntToStr(Pass) + ': ' + Root.ToJSON);
      finally
        FreeAndNil(Root);
      end;
    end;
end;


initialization
  TDUnitX.RegisterTestFixture(TCallMethodTests);

end.
