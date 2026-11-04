unit Tests.Mcp.JsonRpc;

{=============================================================================================================
   2026.11.01
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for the MCP JSON-RPC dispatcher: initialize negotiation, ping, error codes (-32601/-32700), id-type preservation (numeric/string/null), notification handling.
   - tools/call protocol errors (-32602): an unknown tool, a missing or non-string name, arguments that are not an object.
   - A bad argument value (missing, wrong type, out of range) is an isError result, never a JSON-RPC error
     (https://modelcontextprotocol.io/specification/2025-11-25/server/tools section "Error Handling").
   - Tests.exe links the fourteen production tool units, so tools/list returns them. Tool behaviour is tested in Tests.Mcp.Tools.
=============================================================================================================}

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TJsonRpcTests = class
  public
    [Setup] procedure Setup;

    [Test] procedure Test_Initialize_EchoesSupportedVersion;
    [Test] procedure Test_Initialize_FallsBackForBogusVersion;
    [Test] procedure Test_Initialize_ReturnsServerInfo;
    [Test] procedure Test_Initialize_ReturnsShortInstructions;
    [Test] procedure Test_Ping_ReturnsEmptyObject;
    [Test] procedure Test_UnknownMethod_Returns32601;
    [Test] procedure Test_MalformedJson_Returns32700;
    [Test] procedure Test_NotificationsInitialized_ReturnsEmptyString;
    [Test] procedure Test_NoIdWithUnknownMethod_ReturnsEmptyString;
    [Test] procedure Test_NumericIdPreserved;
    [Test] procedure Test_StringIdPreserved;
    [Test] procedure Test_NullIdPreserved;
    [Test] procedure Test_BatchArrayRejectedAsInvalidRequest;
    [Test] procedure Test_ToolsList_ReturnsTools_Array;
    [Test] procedure Test_ToolsCall_UnknownTool_Returns32602;
    [Test] procedure Test_ServerDiscover_Returns32601;
    [Test] procedure Test_NumericMethod_Returns32600;
    [Test] procedure Test_ToolsCall_MissingName_Returns32602;
    [Test] procedure Test_ToolsCall_NumericName_Returns32602;
    [Test] procedure Test_ToolsCall_ArgumentsNotAnObject_Returns32602;
    [Test] procedure Test_ToolsCall_NullOrMissingArguments_RunsTheTool;
    [Test] procedure Test_ToolsCall_MissingRequiredParam_IsErrorNamingIt;
    [Test] procedure Test_ToolsCall_BadArgumentValue_IsErrorResultNamingIt;
  end;


implementation

uses
  System.SysUtils, System.JSON, System.Generics.Collections,
  Autopilot.Mcp.JsonRpc;


/// Parse the dispatcher's response and return the root JSON object. Caller frees.
function Parse(const AResponse: String): TJSONObject;
var
  V: TJSONValue;
begin
  V := TJSONObject.ParseJSONValue(AResponse);
  Assert.IsTrue(V IS TJSONObject, 'Response is not a JSON object: ' + AResponse);
  Result := TJSONObject(V);
end;


/// Pull a nested JSONObject by path 'a.b.c'. Returns nil if any segment missing.
function Drill(ARoot: TJSONObject; const APath: String): TJSONObject;
var
  Parts: TArray<String>;
  Cur  : TJSONValue;
  Next : TJSONValue;
  i    : Integer;
begin
  Result := nil;
  Parts := APath.Split(['.']);
  Cur := ARoot;
  for i := 0 to High(Parts) do
  begin
    if not (Cur IS TJSONObject) then Exit;
    Next := TJSONObject(Cur).GetValue(Parts[i]);
    if Next = nil then Exit;
    Cur := Next;
  end;
  if Cur IS TJSONObject then
    Result := TJSONObject(Cur);
end;


/// error.code of a parsed answer; 0 when the answer has no error object.
function ErrorCode(ARoot: TJSONObject): Integer;
var
  ErrObj: TJSONObject;
begin
  ErrObj := Drill(ARoot, 'error');
  if ErrObj = NIL then EXIT(0);
  Result := (ErrObj.GetValue('code') AS TJSONNumber).AsInt;
end;


/// Dispatch ALine and check that the answer is the JSON-RPC error ACode with no result. Returns error.message.
function ExpectError(const ALine: String; ACode: Integer): String;
var
  Resp: String;
  Root: TJSONObject;
begin
  Resp := DispatchLine(ALine);
  Root := Parse(Resp);
  try
    Assert.AreEqual(ACode, ErrorCode(Root), 'error.code: ' + Resp);
    Assert.IsNull(Root.GetValue('result'), 'an error answer must carry no result: ' + Resp);
    Result := Drill(Root, 'error').GetValue('message').Value;
  finally
    FreeAndNil(Root);
  end;
end;


/// Dispatch ALine and check that the answer is a result with isError: true and no JSON-RPC error object.
/// Returns the text of the first content block.
function ExpectIsErrorResult(const ALine: String): String;
var
  Resp : String;
  Root : TJSONObject;
  Res  : TJSONObject;
  IsErr: TJSONValue;
begin
  Resp := DispatchLine(ALine);
  Root := Parse(Resp);
  try
    Assert.IsNull(Root.GetValue('error'), 'the answer must be a result, not a JSON-RPC error: ' + Resp);
    Res := Drill(Root, 'result');
    Assert.IsNotNull(Res, 'result missing: ' + Resp);
    IsErr := Res.GetValue('isError');
    Assert.IsTrue((IsErr IS TJSONBool) and TJSONBool(IsErr).AsBoolean, 'isError must be true: ' + Resp);
    Result := ((Res.GetValue('content') AS TJSONArray).Items[0] AS TJSONObject).GetValue('text').Value;
  finally
    FreeAndNil(Root);
  end;
end;


procedure TJsonRpcTests.Setup;
begin
  // Each test gets a clean tool cache. The registry is whatever production code
  // wired up (the fourteen tool units Tests.dpr links).
  ResetToolCache;
end;


procedure TJsonRpcTests.Test_Initialize_EchoesSupportedVersion;
var
  Resp: String;
  Root: TJSONObject;
  Result_: TJSONObject;
begin
  Resp := DispatchLine('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}');
  Root := Parse(Resp);
  try
    Result_ := Root.GetValue('result') AS TJSONObject;
    Assert.IsNotNull(Result_, 'result missing');
    Assert.AreEqual('2024-11-05', Result_.GetValue('protocolVersion').Value);
  finally
    Root.Free;
  end;
end;


procedure TJsonRpcTests.Test_Initialize_FallsBackForBogusVersion;
var
  Resp: String;
  Root, Result_: TJSONObject;
  Ver: String;
begin
  Resp := DispatchLine('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"never-shipped"}}');
  Root := Parse(Resp);
  try
    Result_ := Root.GetValue('result') AS TJSONObject;
    Ver := Result_.GetValue('protocolVersion').Value;
    // We don't pin the literal version string — it's a const in MCPServer.Types.
    // Just confirm it's a real YYYY-MM-DD-ish value and not the bogus one.
    Assert.AreNotEqual('never-shipped', Ver);
    Assert.IsTrue(Ver.StartsWith('20'), 'Expected a date-like version, got: ' + Ver);
  finally
    Root.Free;
  end;
end;


procedure TJsonRpcTests.Test_Initialize_ReturnsServerInfo;
var
  Resp: String;
  Root, Info: TJSONObject;
begin
  Resp := DispatchLine('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}');
  Root := Parse(Resp);
  try
    Info := Drill(Root, 'result.serverInfo');
    Assert.IsNotNull(Info, 'result.serverInfo missing');
    Assert.AreEqual('Autopilot.Mcp', Info.GetValue('name').Value);
    Assert.IsNotNull(Info.GetValue('version'), 'serverInfo.version missing');
  finally
    Root.Free;
  end;
end;


/// The initialize result must carry the optional MCP "instructions" string. Claude Code loads it into
/// every session, also one that never drives a Delphi app, so it only names -32099 target_not_running.
/// The bridge-wiring recipe itself rides that error (checked in Tests.Mcp.Tools), where it costs
/// nothing until an AI actually needs it.
procedure TJsonRpcTests.Test_Initialize_ReturnsShortInstructions;
var
  Resp, Instr: String;
  Root, Result_: TJSONObject;
begin
  Resp := DispatchLine('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}');
  Root := Parse(Resp);
  try
    Result_ := Root.GetValue('result') AS TJSONObject;
    Assert.IsNotNull(Result_, 'result missing');
    Assert.IsNotNull(Result_.GetValue('instructions'), 'result.instructions missing');

    Instr := Result_.GetValue('instructions').Value;
    Assert.IsTrue(Instr.Contains('-32099'),                'instructions do not name the target_not_running code');
    Assert.IsTrue(Instr.Contains('target_not_running'),    'instructions do not name target_not_running');
    Assert.IsTrue(Instr.Contains('call attach'),           'instructions do not say where the setup steps are');
    Assert.IsFalse(Instr.Contains('StartBridge'),          'the bridge-wiring recipe is back in the instructions: it belongs to the -32099 error');
    Assert.IsTrue(Instr.Length < 1000,                     'instructions grew to ' + IntToStr(Instr.Length) + ' characters');
  finally
    Root.Free;
  end;
end;


procedure TJsonRpcTests.Test_Ping_ReturnsEmptyObject;
var
  Resp: String;
  Root, Result_: TJSONObject;
begin
  Resp := DispatchLine('{"jsonrpc":"2.0","id":99,"method":"ping"}');
  Root := Parse(Resp);
  try
    Result_ := Root.GetValue('result') AS TJSONObject;
    Assert.IsNotNull(Result_);
    Assert.AreEqual(0, Result_.Count, 'result should be {} (zero keys)');
  finally
    Root.Free;
  end;
end;


procedure TJsonRpcTests.Test_UnknownMethod_Returns32601;
var
  Resp: String;
  Root, ErrObj: TJSONObject;
begin
  Resp := DispatchLine('{"jsonrpc":"2.0","id":7,"method":"nope"}');
  Root := Parse(Resp);
  try
    ErrObj := Root.GetValue('error') AS TJSONObject;
    Assert.IsNotNull(ErrObj, 'error missing');
    Assert.AreEqual(-32601, (ErrObj.GetValue('code') AS TJSONNumber).AsInt);
  finally
    Root.Free;
  end;
end;


procedure TJsonRpcTests.Test_MalformedJson_Returns32700;
var
  Resp: String;
  Root, ErrObj: TJSONObject;
begin
  Resp := DispatchLine('{"jsonrpc":"2.0",-broken-');
  Root := Parse(Resp);
  try
    ErrObj := Root.GetValue('error') AS TJSONObject;
    Assert.AreEqual(-32700, (ErrObj.GetValue('code') AS TJSONNumber).AsInt);
    Assert.IsTrue(Root.GetValue('id') IS TJSONNull, 'id should be null on parse error');
  finally
    Root.Free;
  end;
end;


procedure TJsonRpcTests.Test_NotificationsInitialized_ReturnsEmptyString;
var
  Resp: String;
begin
  Resp := DispatchLine('{"jsonrpc":"2.0","method":"notifications/initialized"}');
  Assert.AreEqual('', Resp, 'Notifications must produce no response');
end;


procedure TJsonRpcTests.Test_NoIdWithUnknownMethod_ReturnsEmptyString;
var
  Resp: String;
begin
  // A request without "id" is a notification per JSON-RPC 2.0, even for
  // unknown methods. We must not respond.
  Resp := DispatchLine('{"jsonrpc":"2.0","method":"unknown_no_id"}');
  Assert.AreEqual('', Resp);
end;


procedure TJsonRpcTests.Test_NumericIdPreserved;
var
  Resp: String;
  Root: TJSONObject;
begin
  Resp := DispatchLine('{"jsonrpc":"2.0","id":42,"method":"ping"}');
  Root := Parse(Resp);
  try
    Assert.IsTrue(Root.GetValue('id') IS TJSONNumber, 'id should be a TJSONNumber');
    Assert.AreEqual(Int64(42), (Root.GetValue('id') AS TJSONNumber).AsInt64);
  finally
    Root.Free;
  end;
end;


procedure TJsonRpcTests.Test_StringIdPreserved;
var
  Resp: String;
  Root: TJSONObject;
begin
  Resp := DispatchLine('{"jsonrpc":"2.0","id":"hello","method":"ping"}');
  Root := Parse(Resp);
  try
    Assert.IsTrue(Root.GetValue('id') IS TJSONString, 'id should be a TJSONString');
    Assert.AreEqual('hello', Root.GetValue('id').Value);
  finally
    Root.Free;
  end;
end;


procedure TJsonRpcTests.Test_NullIdPreserved;
var
  Resp: String;
  Root: TJSONObject;
begin
  // A literal "id":null is NOT a notification — it's a request whose id
  // happens to be null. We respond, echoing id=null.
  Resp := DispatchLine('{"jsonrpc":"2.0","id":null,"method":"ping"}');
  Root := Parse(Resp);
  try
    Assert.IsTrue(Root.GetValue('id') IS TJSONNull, 'id should be a TJSONNull');
  finally
    Root.Free;
  end;
end;


procedure TJsonRpcTests.Test_BatchArrayRejectedAsInvalidRequest;
var
  Resp: String;
  Root, ErrObj: TJSONObject;
begin
  Resp := DispatchLine('[{"jsonrpc":"2.0","id":1,"method":"ping"}]');
  Root := Parse(Resp);
  try
    ErrObj := Root.GetValue('error') AS TJSONObject;
    Assert.AreEqual(-32600, (ErrObj.GetValue('code') AS TJSONNumber).AsInt);
  finally
    Root.Free;
  end;
end;


procedure TJsonRpcTests.Test_ToolsList_ReturnsTools_Array;
var
  Resp: String;
  Root, Result_: TJSONObject;
  Tools: TJSONArray;
begin
  Resp := DispatchLine('{"jsonrpc":"2.0","id":5,"method":"tools/list"}');
  Root := Parse(Resp);
  try
    Result_ := Root.GetValue('result') AS TJSONObject;
    Tools := Result_.GetValue('tools') AS TJSONArray;
    Assert.IsNotNull(Tools, 'result.tools missing');
    Assert.AreEqual(14, Tools.Count, 'Tests.dpr links all fourteen tool units');
  finally
    Root.Free;
  end;
end;


/// MCP 2025-11-25 (server/tools, "Error Handling") lists an unknown tool as a protocol error, example code -32602.
procedure TJsonRpcTests.Test_ToolsCall_UnknownTool_Returns32602;
var
  Msg: String;
begin
  Msg := ExpectError('{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"does_not_exist","arguments":{}}}', -32602);
  Assert.IsTrue(Msg.Contains('does_not_exist'), 'message does not name the tool: ' + Msg);
end;


/// Claude Code 2.1.309 sends server/discover first and falls back to initialize only on -32601. An answer to
/// server/discover would move it to a protocol version this server does not speak.
procedure TJsonRpcTests.Test_ServerDiscover_Returns32601;
begin
  ExpectError('{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{}}', -32601);
end;


/// A method that is not a JSON string is an invalid request. On Delphi 11 and 12 a TJSONNumber is a TJSONString,
/// so this guards the check against those versions; on Delphi 13 it passes with or without the guard.
procedure TJsonRpcTests.Test_NumericMethod_Returns32600;
begin
  ExpectError('{"jsonrpc":"2.0","id":1,"method":42}', -32600);
end;


procedure TJsonRpcTests.Test_ToolsCall_MissingName_Returns32602;
begin
  ExpectError('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"arguments":{}}}', -32602);
  ExpectError('{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"","arguments":{}}}', -32602);
  ExpectError('{"jsonrpc":"2.0","id":4,"method":"tools/call"}', -32602);
end;


/// A name that is a JSON number is no name. Same Delphi 11/12 guard as Test_NumericMethod_Returns32600.
procedure TJsonRpcTests.Test_ToolsCall_NumericName_Returns32602;
begin
  ExpectError('{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":42,"arguments":{}}}', -32602);
end;


/// "arguments" that is not an object used to run the tool with every parameter at its default.
procedure TJsonRpcTests.Test_ToolsCall_ArgumentsNotAnObject_Returns32602;
begin
  ExpectError('{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"attach","arguments":[1]}}', -32602);
  ExpectError('{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"attach","arguments":"x"}}', -32602);
end;


/// A missing "arguments" and a JSON null both mean "no arguments": the tool runs. attach needs no target.
procedure TJsonRpcTests.Test_ToolsCall_NullOrMissingArguments_RunsTheTool;
const
  Lines: array[0..1] of String = (
    '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"attach","arguments":null}}',
    '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"attach"}}');
var
  Line, Resp: String;
  Root: TJSONObject;
begin
  for Line in Lines do
  begin
    Resp := DispatchLine(Line);
    Root := Parse(Resp);
    try
      Assert.IsNull(Root.GetValue('error'), 'attach must run: ' + Resp);
      Assert.IsNotNull(Drill(Root, 'result'), 'result missing: ' + Resp);
    finally
      FreeAndNil(Root);
    end;
  end;
end;


/// set_checked without "checked" used to uncheck the box. Now the call is refused before the tool runs, as an
/// isError result (a tool execution error, MCP 2025-11-25 server/tools) that names the parameter. The pid is one
/// no target owns, so a tool that ran anyway answers -32099 instead.
procedure TJsonRpcTests.Test_ToolsCall_MissingRequiredParam_IsErrorNamingIt;
var
  Resp, Text: String;
  Root: TJSONObject;
  IsErr: TJSONValue;
begin
  Resp := DispatchLine('{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"set_checked",'
                     + '"arguments":{"path":"frmMain.chkBox","pid":2147483000}}}');
  Root := Parse(Resp);
  try
    IsErr := Drill(Root, 'result').GetValue('isError');
    Assert.IsTrue((IsErr IS TJSONBool) and TJSONBool(IsErr).AsBoolean, 'isError must be true: ' + Resp);
    Text := ((Drill(Root, 'result').GetValue('content') AS TJSONArray).Items[0] AS TJSONObject).GetValue('text').Value;
    Assert.IsTrue(Text.Contains('"checked"'), 'the error does not name checked: ' + Text);
    Assert.IsTrue(Text.Contains('Missing required parameter'), 'the error is not the missing-parameter one: ' + Text);
  finally
    FreeAndNil(Root);
  end;
end;


/// An argument value the params class refuses is an input validation error: a result with isError: true that names
/// the parameter, never a JSON-RPC error object (https://modelcontextprotocol.io/specification/2025-11-25/server/tools
/// section "Error Handling"). The pid 2147483000 is one no target owns, so a tool that ran anyway answers -32099.
procedure TJsonRpcTests.Test_ToolsCall_BadArgumentValue_IsErrorResultNamingIt;
var
  Text: String;
begin
  // Text for an Integer
  Text := ExpectIsErrorResult('{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"attach",'
                            + '"arguments":{"pid":"abc"}}}');
  Assert.IsTrue(Text.Contains('"pid"'), 'pid "abc": the error does not name pid: ' + Text);

  // A number for a Boolean
  Text := ExpectIsErrorResult('{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"set_checked",'
                            + '"arguments":{"path":"frmMain.chkBox","pid":2147483000,"checked":1}}}');
  Assert.IsTrue(Text.Contains('"checked"'), 'checked 1: the error does not name checked: ' + Text);

  // A fraction for an Integer
  Text := ExpectIsErrorResult('{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"click",'
                            + '"arguments":{"path":"frmMain.btnOk","pid":2147483000,"count":1.5}}}');
  Assert.IsTrue(Text.Contains('"count"'), 'count 1.5: the error does not name count: ' + Text);

  // Out of the Integer range
  Text := ExpectIsErrorResult('{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"attach",'
                            + '"arguments":{"pid":99999999999}}}');
  Assert.IsTrue(Text.Contains('"pid"'), 'pid 99999999999: the error does not name pid: ' + Text);
end;


initialization
  TDUnitX.RegisterTestFixture(TJsonRpcTests);

end.
