unit Tests.Mcp.JsonRpc;

{=============================================================================================================
   2026.06
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for the MCP JSON-RPC dispatcher: initialize negotiation, ping, error codes (-32601/-32700), id-type preservation (numeric/string/null), notification handling.
   - Tool registry is empty in this test exe (no production tool units linked), so tools/list returns an empty array.
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
    [Test] procedure Test_ToolsCall_UnknownToolReturnsIsErrorTrue;
  end;


implementation

uses
  System.SysUtils, System.JSON,
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


procedure TJsonRpcTests.Setup;
begin
  // Each test gets a clean tool cache. The registry is whatever production code
  // wired up (empty in this test exe since we don't 'uses' the nine tool units).
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
    // The Tests.exe does not link the nine tool units, so the registry is empty
    // here. We just verify the array exists and is well-formed.
    Assert.IsTrue(Tools.Count >= 0);
  finally
    Root.Free;
  end;
end;


procedure TJsonRpcTests.Test_ToolsCall_UnknownToolReturnsIsErrorTrue;
var
  Resp: String;
  Root, Result_: TJSONObject;
  IsErr: TJSONValue;
begin
  Resp := DispatchLine('{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"does_not_exist","arguments":{}}}');
  Root := Parse(Resp);
  try
    Result_ := Root.GetValue('result') AS TJSONObject;
    Assert.IsNotNull(Result_);
    IsErr := Result_.GetValue('isError');
    Assert.IsNotNull(IsErr, 'isError missing for unknown tool');
    Assert.IsTrue((IsErr AS TJSONBool).AsBoolean, 'isError should be true');
  finally
    Root.Free;
  end;
end;


initialization
  TDUnitX.RegisterTestFixture(TJsonRpcTests);

end.
