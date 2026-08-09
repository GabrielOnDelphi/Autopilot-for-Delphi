UNIT Tests.Mcp.JsonRpc;

(*=====================================================
   2026.05.19
   DUnitX tests for the JSON-RPC dispatcher.

   Covers the plumbing only — initialize negotiation, ping, error codes,
   id-type preservation, notification handling. The tool registry stays
   empty across these tests (we don't pull in the nine production tool
   units), so tools/list returns an empty array and tools/call returns
   the "not found" content.
=====================================================*)

INTERFACE

USES
  DUnitX.TestFramework;

TYPE
  [TestFixture]
  TJsonRpcTests = CLASS
  PUBLIC
    [Setup] PROCEDURE Setup;

    [Test] PROCEDURE Test_Initialize_EchoesSupportedVersion;
    [Test] PROCEDURE Test_Initialize_FallsBackForBogusVersion;
    [Test] PROCEDURE Test_Initialize_ReturnsServerInfo;
    [Test] PROCEDURE Test_Ping_ReturnsEmptyObject;
    [Test] PROCEDURE Test_UnknownMethod_Returns32601;
    [Test] PROCEDURE Test_MalformedJson_Returns32700;
    [Test] PROCEDURE Test_NotificationsInitialized_ReturnsEmptyString;
    [Test] PROCEDURE Test_NoIdWithUnknownMethod_ReturnsEmptyString;
    [Test] PROCEDURE Test_NumericIdPreserved;
    [Test] PROCEDURE Test_StringIdPreserved;
    [Test] PROCEDURE Test_NullIdPreserved;
    [Test] PROCEDURE Test_BatchArrayRejectedAsInvalidRequest;
    [Test] PROCEDURE Test_ToolsList_ReturnsTools_Array;
    [Test] PROCEDURE Test_ToolsCall_UnknownToolReturnsIsErrorTrue;
  END;


IMPLEMENTATION

USES
  System.SysUtils, System.JSON,
  Autopilot.Mcp.JsonRpc;


/// Parse the dispatcher's response and return the root JSON object. Caller frees.
FUNCTION Parse(CONST AResponse: String): TJSONObject;
VAR
  V: TJSONValue;
BEGIN
  V := TJSONObject.ParseJSONValue(AResponse);
  Assert.IsTrue(V IS TJSONObject, 'Response is not a JSON object: ' + AResponse);
  Result := TJSONObject(V);
END;


/// Pull a nested JSONObject by path 'a.b.c'. Returns NIL if any segment missing.
FUNCTION Drill(ARoot: TJSONObject; CONST APath: String): TJSONObject;
VAR
  Parts: TArray<String>;
  Cur  : TJSONValue;
  Next : TJSONValue;
  i    : Integer;
BEGIN
  Result := NIL;
  Parts := APath.Split(['.']);
  Cur := ARoot;
  for i := 0 to High(Parts) do
  begin
    if not (Cur IS TJSONObject) then EXIT;
    Next := TJSONObject(Cur).GetValue(Parts[i]);
    if Next = NIL then EXIT;
    Cur := Next;
  end;
  if Cur IS TJSONObject then
    Result := TJSONObject(Cur);
END;


PROCEDURE TJsonRpcTests.Setup;
BEGIN
  // Each test gets a clean tool cache. The registry is whatever production code
  // wired up (empty in this test exe since we don't 'uses' the nine tool units).
  ResetToolCache;
END;


PROCEDURE TJsonRpcTests.Test_Initialize_EchoesSupportedVersion;
VAR
  Resp: String;
  Root: TJSONObject;
  Result_: TJSONObject;
BEGIN
  Resp := DispatchLine('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}');
  Root := Parse(Resp);
  TRY
    Result_ := Root.GetValue('result') AS TJSONObject;
    Assert.IsNotNull(Result_, 'result missing');
    Assert.AreEqual('2024-11-05', Result_.GetValue('protocolVersion').Value);
  FINALLY
    Root.Free;
  END;
END;


PROCEDURE TJsonRpcTests.Test_Initialize_FallsBackForBogusVersion;
VAR
  Resp: String;
  Root, Result_: TJSONObject;
  Ver: String;
BEGIN
  Resp := DispatchLine('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"never-shipped"}}');
  Root := Parse(Resp);
  TRY
    Result_ := Root.GetValue('result') AS TJSONObject;
    Ver := Result_.GetValue('protocolVersion').Value;
    // We don't pin the literal version string — it's a const in MCPServer.Types.
    // Just confirm it's a real YYYY-MM-DD-ish value and not the bogus one.
    Assert.AreNotEqual('never-shipped', Ver);
    Assert.IsTrue(Ver.StartsWith('20'), 'Expected a date-like version, got: ' + Ver);
  FINALLY
    Root.Free;
  END;
END;


PROCEDURE TJsonRpcTests.Test_Initialize_ReturnsServerInfo;
VAR
  Resp: String;
  Root, Info: TJSONObject;
BEGIN
  Resp := DispatchLine('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}');
  Root := Parse(Resp);
  TRY
    Info := Drill(Root, 'result.serverInfo');
    Assert.IsNotNull(Info, 'result.serverInfo missing');
    Assert.AreEqual('Autopilot.Mcp', Info.GetValue('name').Value);
    Assert.IsNotNull(Info.GetValue('version'), 'serverInfo.version missing');
  FINALLY
    Root.Free;
  END;
END;


PROCEDURE TJsonRpcTests.Test_Ping_ReturnsEmptyObject;
VAR
  Resp: String;
  Root, Result_: TJSONObject;
BEGIN
  Resp := DispatchLine('{"jsonrpc":"2.0","id":99,"method":"ping"}');
  Root := Parse(Resp);
  TRY
    Result_ := Root.GetValue('result') AS TJSONObject;
    Assert.IsNotNull(Result_);
    Assert.AreEqual(0, Result_.Count, 'result should be {} (zero keys)');
  FINALLY
    Root.Free;
  END;
END;


PROCEDURE TJsonRpcTests.Test_UnknownMethod_Returns32601;
VAR
  Resp: String;
  Root, ErrObj: TJSONObject;
BEGIN
  Resp := DispatchLine('{"jsonrpc":"2.0","id":7,"method":"nope"}');
  Root := Parse(Resp);
  TRY
    ErrObj := Root.GetValue('error') AS TJSONObject;
    Assert.IsNotNull(ErrObj, 'error missing');
    Assert.AreEqual(-32601, (ErrObj.GetValue('code') AS TJSONNumber).AsInt);
  FINALLY
    Root.Free;
  END;
END;


PROCEDURE TJsonRpcTests.Test_MalformedJson_Returns32700;
VAR
  Resp: String;
  Root, ErrObj: TJSONObject;
BEGIN
  Resp := DispatchLine('{"jsonrpc":"2.0",-broken-');
  Root := Parse(Resp);
  TRY
    ErrObj := Root.GetValue('error') AS TJSONObject;
    Assert.AreEqual(-32700, (ErrObj.GetValue('code') AS TJSONNumber).AsInt);
    Assert.IsTrue(Root.GetValue('id') IS TJSONNull, 'id should be null on parse error');
  FINALLY
    Root.Free;
  END;
END;


PROCEDURE TJsonRpcTests.Test_NotificationsInitialized_ReturnsEmptyString;
VAR
  Resp: String;
BEGIN
  Resp := DispatchLine('{"jsonrpc":"2.0","method":"notifications/initialized"}');
  Assert.AreEqual('', Resp, 'Notifications must produce no response');
END;


PROCEDURE TJsonRpcTests.Test_NoIdWithUnknownMethod_ReturnsEmptyString;
VAR
  Resp: String;
BEGIN
  // A request without "id" is a notification per JSON-RPC 2.0, even for
  // unknown methods. We must not respond.
  Resp := DispatchLine('{"jsonrpc":"2.0","method":"unknown_no_id"}');
  Assert.AreEqual('', Resp);
END;


PROCEDURE TJsonRpcTests.Test_NumericIdPreserved;
VAR
  Resp: String;
  Root: TJSONObject;
BEGIN
  Resp := DispatchLine('{"jsonrpc":"2.0","id":42,"method":"ping"}');
  Root := Parse(Resp);
  TRY
    Assert.IsTrue(Root.GetValue('id') IS TJSONNumber, 'id should be a TJSONNumber');
    Assert.AreEqual(Int64(42), (Root.GetValue('id') AS TJSONNumber).AsInt64);
  FINALLY
    Root.Free;
  END;
END;


PROCEDURE TJsonRpcTests.Test_StringIdPreserved;
VAR
  Resp: String;
  Root: TJSONObject;
BEGIN
  Resp := DispatchLine('{"jsonrpc":"2.0","id":"hello","method":"ping"}');
  Root := Parse(Resp);
  TRY
    Assert.IsTrue(Root.GetValue('id') IS TJSONString, 'id should be a TJSONString');
    Assert.AreEqual('hello', Root.GetValue('id').Value);
  FINALLY
    Root.Free;
  END;
END;


PROCEDURE TJsonRpcTests.Test_NullIdPreserved;
VAR
  Resp: String;
  Root: TJSONObject;
BEGIN
  // A literal "id":null is NOT a notification — it's a request whose id
  // happens to be null. We respond, echoing id=null.
  Resp := DispatchLine('{"jsonrpc":"2.0","id":null,"method":"ping"}');
  Root := Parse(Resp);
  TRY
    Assert.IsTrue(Root.GetValue('id') IS TJSONNull, 'id should be a TJSONNull');
  FINALLY
    Root.Free;
  END;
END;


PROCEDURE TJsonRpcTests.Test_BatchArrayRejectedAsInvalidRequest;
VAR
  Resp: String;
  Root, ErrObj: TJSONObject;
BEGIN
  Resp := DispatchLine('[{"jsonrpc":"2.0","id":1,"method":"ping"}]');
  Root := Parse(Resp);
  TRY
    ErrObj := Root.GetValue('error') AS TJSONObject;
    Assert.AreEqual(-32600, (ErrObj.GetValue('code') AS TJSONNumber).AsInt);
  FINALLY
    Root.Free;
  END;
END;


PROCEDURE TJsonRpcTests.Test_ToolsList_ReturnsTools_Array;
VAR
  Resp: String;
  Root, Result_: TJSONObject;
  Tools: TJSONArray;
BEGIN
  Resp := DispatchLine('{"jsonrpc":"2.0","id":5,"method":"tools/list"}');
  Root := Parse(Resp);
  TRY
    Result_ := Root.GetValue('result') AS TJSONObject;
    Tools := Result_.GetValue('tools') AS TJSONArray;
    Assert.IsNotNull(Tools, 'result.tools missing');
    // The Tests.exe does not link the nine tool units, so the registry is empty
    // here. We just verify the array exists and is well-formed.
    Assert.IsTrue(Tools.Count >= 0);
  FINALLY
    Root.Free;
  END;
END;


PROCEDURE TJsonRpcTests.Test_ToolsCall_UnknownToolReturnsIsErrorTrue;
VAR
  Resp: String;
  Root, Result_: TJSONObject;
  IsErr: TJSONValue;
BEGIN
  Resp := DispatchLine('{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"does_not_exist","arguments":{}}}');
  Root := Parse(Resp);
  TRY
    Result_ := Root.GetValue('result') AS TJSONObject;
    Assert.IsNotNull(Result_);
    IsErr := Result_.GetValue('isError');
    Assert.IsNotNull(IsErr, 'isError missing for unknown tool');
    Assert.IsTrue((IsErr AS TJSONBool).AsBoolean, 'isError should be true');
  FINALLY
    Root.Free;
  END;
END;


INITIALIZATION
  TDUnitX.RegisterTestFixture(TJsonRpcTests);

END.
