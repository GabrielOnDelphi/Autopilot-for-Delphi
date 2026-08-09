UNIT Autopilot.Mcp.JsonRpc;

(*=====================================================
   2026.06.03
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────────────┐
   │  WINDOWS  (PC-side MCP server)       │   runs in Autopilot.Mcp.exe; target may be any platform
   └──────────────────────────────────────┘

   Single-line JSON-RPC 2.0 dispatcher. Implements the minimum MCP surface
   Claude Code needs:
     initialize, notifications/initialized (notification), ping,
     tools/list, tools/call.

   Everything else returns -32601 Method not found.

   No threads, no transport here — the caller (Autopilot.Mcp.Stdio) drives
   the readln loop. Pure JSON in -> JSON out (or '' for notifications).

   Tool instance caching: each tool name maps to one IMCPTool, created via
   TMCPRegistry on first use and held until shutdown. Matches GDK behavior.

   id handling: every JSON-RPC response must echo the request's id verbatim,
   preserving its JSON type (number, string, null). We clone the raw TJSONValue
   so a number stays a number and a string stays a string.
=====================================================*)

INTERFACE


/// Process one JSON-RPC line. Returns the response line (no trailing newline)
/// or '' if the request was a notification (no response expected).
FUNCTION DispatchLine(CONST ALine: String): String;

/// Drop the cached tool instances. Used by unit tests; production never calls.
PROCEDURE ResetToolCache;


IMPLEMENTATION

USES
  System.SysUtils, System.JSON, System.Generics.Collections,
  Autopilot.Bridge.Core,
  Autopilot.Bridge.Log,
  MCPServer.Types,
  MCPServer.Registration,
  MCPServer.Tool.Base;


CONST
  ErrParseError     = -32700;
  ErrInvalidRequest = -32600;
  ErrMethodNotFound = -32601;
  ErrInvalidParams  = -32602;
  ErrInternal       = -32603;

  ServerName = 'Autopilot.Mcp';

CONST
  /// Versions we accept verbatim on initialize. Anything else negotiates down
  /// to MCP_PROTOCOL_VERSION. Order matters for readability only — lookup is linear.
  GSupportedVersions: array[0..3] of String = (
    '2025-11-25',   // current per spec
    '2025-06-18',
    '2025-03-26',
    '2024-11-05'
  );

TYPE
  /// Holder for the singleton tool-instance cache. Wrapped in a class so we can
  /// hang a class destructor on it (no finalization section, per project rule).
  /// One IMCPTool per tool name, built lazily on first tools/list or tools/call,
  /// reused for the rest of the server's lifetime.
  TToolCache = CLASS
  STRICT PRIVATE
    CLASS VAR FMap: TDictionary<String, IMCPTool>;
    CLASS PROCEDURE EnsureMap;
  PUBLIC
    CLASS FUNCTION Resolve(CONST AName: String): IMCPTool;
    CLASS PROCEDURE Reset;
    CLASS DESTRUCTOR Destroy;
  END;


CLASS PROCEDURE TToolCache.EnsureMap;
BEGIN
  if FMap = NIL then
    FMap := TDictionary<String, IMCPTool>.Create;
END;


CLASS FUNCTION TToolCache.Resolve(CONST AName: String): IMCPTool;
BEGIN
  EnsureMap;
  if FMap.TryGetValue(AName, Result) then EXIT;
  if not TMCPRegistry.HasTool(AName) then EXIT(NIL);
  Result := TMCPRegistry.CreateTool(AName);
  FMap.Add(AName, Result);
END;


CLASS PROCEDURE TToolCache.Reset;
BEGIN
  FreeAndNil(FMap);
END;


CLASS DESTRUCTOR TToolCache.Destroy;
BEGIN
  FreeAndNil(FMap);
END;


PROCEDURE ResetToolCache;
BEGIN
  TToolCache.Reset;
END;


/// Look up (or create-and-cache) the tool by name. Returns NIL if not registered.
FUNCTION ResolveCachedTool(CONST AName: String): IMCPTool;
BEGIN
  Result := TToolCache.Resolve(AName);
END;


/// True iff AVersion is one we accept verbatim during initialize negotiation.
FUNCTION IsSupportedVersion(CONST AVersion: String): Boolean;
VAR
  V: String;
BEGIN
  for V in GSupportedVersions do
    if V = AVersion then EXIT(TRUE);
  Result := FALSE;
END;


/// Clone the request id into the response. The MUST-preserve-type rule of
/// JSON-RPC 2.0 §5: a number response id matches a number request id, etc.
/// AIdNode may be NIL (request had no id field, but we shouldn't get here in
/// that case — notifications are handled earlier) or any TJSONValue subtype.
FUNCTION CloneIdOrNull(AIdNode: TJSONValue): TJSONValue;
BEGIN
  if AIdNode = NIL
    then Result := TJSONNull.Create
    else Result := AIdNode.Clone AS TJSONValue;
END;


/// Build the {jsonrpc:'2.0', id, result:<inner>} envelope. Takes ownership of
/// AInner and ACloneOfId.
FUNCTION BuildOkEnvelope(ACloneOfId: TJSONValue; AInner: TJSONValue): String;
VAR
  Resp: TJSONObject;
BEGIN
  Resp := TJSONObject.Create;
  TRY
    Resp.AddPair('jsonrpc', '2.0');
    Resp.AddPair('id', ACloneOfId);
    Resp.AddPair('result', AInner);
    Result := Resp.ToJSON;
  FINALLY
    Resp.Free;
  END;
END;


/// Build the {jsonrpc:'2.0', id, error:{code,message}} envelope. Takes ownership
/// of ACloneOfId.
FUNCTION BuildErrorEnvelope(ACloneOfId: TJSONValue; ACode: Integer; CONST AMsg: String): String;
VAR
  Resp, Err: TJSONObject;
BEGIN
  Err := TJSONObject.Create;
  Err.AddPair('code', TJSONNumber.Create(ACode));
  Err.AddPair('message', AMsg);

  Resp := TJSONObject.Create;
  TRY
    Resp.AddPair('jsonrpc', '2.0');
    Resp.AddPair('id', ACloneOfId);
    Resp.AddPair('error', Err);
    Result := Resp.ToJSON;
  FINALLY
    Resp.Free;
  END;
END;


/// Negotiate the protocolVersion the client sent against our supported list.
/// AParams may be NIL (no params on initialize is unusual but legal).
FUNCTION NegotiateVersion(AParams: TJSONObject): String;
VAR
  Node: TJSONValue;
BEGIN
  Result := MCP_PROTOCOL_VERSION;
  if AParams = NIL then EXIT;
  Node := AParams.GetValue('protocolVersion');
  if (Node <> NIL) and IsSupportedVersion(Node.Value) then
    Result := Node.Value;
END;


/// Build the result object for the initialize request.
FUNCTION BuildInitializeResult(AParams: TJSONObject): TJSONObject;
VAR
  Caps, ToolsCap, ServerInfo: TJSONObject;
BEGIN
  ToolsCap := TJSONObject.Create; // empty {} — we don't support listChanged
  Caps     := TJSONObject.Create;
  Caps.AddPair('tools', ToolsCap);

  ServerInfo := TJSONObject.Create;
  ServerInfo.AddPair('name', ServerName);
  ServerInfo.AddPair('version', BridgeVersion);

  Result := TJSONObject.Create;
  Result.AddPair('protocolVersion', NegotiateVersion(AParams));
  Result.AddPair('capabilities', Caps);
  Result.AddPair('serverInfo', ServerInfo);
END;


/// Build the tools/list result: {tools:[ {name,description,inputSchema}, ... ]}.
FUNCTION BuildToolListResult: TJSONObject;
VAR
  ToolsArr: TJSONArray;
  Names   : TArray<String>;
  Name    : String;
  Tool    : IMCPTool;
  Entry   : TJSONObject;
BEGIN
  ToolsArr := TJSONArray.Create;
  Result   := TJSONObject.Create;
  Result.AddPair('tools', ToolsArr);

  Names := TMCPRegistry.GetToolNames;
  for Name in Names do
  begin
    Tool := ResolveCachedTool(Name);
    if Tool = NIL then Continue; // shouldn't happen — Names came from the registry

    Entry := TJSONObject.Create;
    Entry.AddPair('name', Tool.Name);
    Entry.AddPair('description', Tool.Description);
    // Tool.InputSchema returns a fresh TJSONObject — we own it now.
    Entry.AddPair('inputSchema', Tool.InputSchema);
    ToolsArr.AddElement(Entry);
  end;
END;


/// True iff the tool's response string represents an error. Tries to parse it
/// as JSON and looks at the conventional shape {ok:false} or {error:{...}}.
/// Falls back to the GDK heuristic of "starts with Error:" if the string is
/// not parseable JSON — that catches exception messages we wrap with that
/// prefix in BuildToolCallResult.
FUNCTION DetectIsError(CONST AText: String): Boolean;
VAR
  Parsed: TJSONValue;
  Obj   : TJSONObject;
  OkVal : TJSONValue;
BEGIN
  Parsed := TJSONObject.ParseJSONValue(AText);
  TRY
    if Parsed IS TJSONObject then
    begin
      Obj := TJSONObject(Parsed);
      OkVal := Obj.GetValue('ok');
      if (OkVal IS TJSONBool) and (not TJSONBool(OkVal).AsBoolean) then
        EXIT(TRUE);
      if Obj.GetValue('error') <> NIL then
        EXIT(TRUE);
      EXIT(FALSE);
    end;
  FINALLY
    Parsed.Free;
  END;

  // Not parseable JSON — fall back to the prefix heuristic.
  Result := AText.StartsWith('Error:');
END;


/// Wrap a plain text payload (the tool's return string) in the MCP tools/call
/// content[] structure: {content:[{type:'text', text:<s>}], isError:<bool>}.
FUNCTION WrapToolCallContent(CONST AText: String; AIsError: Boolean): TJSONObject;
VAR
  Item, Outer: TJSONObject;
  Arr        : TJSONArray;
BEGIN
  Item := TJSONObject.Create;
  Item.AddPair('type', 'text');
  Item.AddPair('text', AText);

  Arr := TJSONArray.Create;
  Arr.AddElement(Item);

  Outer := TJSONObject.Create;
  Outer.AddPair('content', Arr);
  if AIsError then
    Outer.AddPair('isError', TJSONBool.Create(TRUE));
  Result := Outer;
END;


/// Build the tools/call result. Reads name + arguments from AParams (either
/// may be missing or wrong-typed — handle gracefully), resolves the tool,
/// runs it, and wraps the output. AParams may be NIL.
FUNCTION BuildToolCallResult(AParams: TJSONObject): TJSONObject;
VAR
  ToolName  : String;
  NameNode  : TJSONValue;
  ArgsNode  : TJSONValue;
  Args      : TJSONObject;
  ArgsOwned : Boolean;
  Tool      : IMCPTool;
  Text      : String;
BEGIN
  ToolName := '';
  if AParams <> NIL then
  begin
    NameNode := AParams.GetValue('name');
    if NameNode IS TJSONString then
      ToolName := NameNode.Value;
  end;

  if ToolName = '' then
    EXIT(WrapToolCallContent('Error: tools/call missing required "name" parameter', TRUE));

  // Extract arguments. The spec lets clients omit "arguments" entirely or send
  // null; either is treated as an empty object.
  Args      := NIL;
  ArgsOwned := FALSE;
  if AParams <> NIL then
  begin
    ArgsNode := AParams.GetValue('arguments');
    if ArgsNode IS TJSONObject then
      Args := TJSONObject(ArgsNode);
  end;
  if Args = NIL then
  begin
    Args := TJSONObject.Create;
    ArgsOwned := TRUE;
  end;

  TRY
    Tool := ResolveCachedTool(ToolName);
    if Tool = NIL then
      EXIT(WrapToolCallContent('Error: Tool not found: ' + ToolName, TRUE));

    TRY
      Text := Tool.Execute(Args);
    EXCEPT
      ON E: Exception DO
        EXIT(WrapToolCallContent('Error executing tool: ' + E.Message, TRUE));
    END;
    Result := WrapToolCallContent(Text, DetectIsError(Text));
  FINALLY
    if ArgsOwned then Args.Free;
  END;
END;


FUNCTION DispatchLine(CONST ALine: String): String;
VAR
  Parsed   : TJSONValue;
  Req      : TJSONObject;
  IdNode   : TJSONValue;
  Method   : String;
  MethodVal: TJSONValue;
  Params   : TJSONObject;
  ParamsVal: TJSONValue;
  Inner    : TJSONObject;
BEGIN
  Parsed := TJSONObject.ParseJSONValue(ALine);
  if Parsed = NIL then
    EXIT(BuildErrorEnvelope(TJSONNull.Create, ErrParseError, 'Parse error'));

  TRY
    if not (Parsed IS TJSONObject) then
      // Batch arrays land here too — MCP doesn't use batches; reject.
      EXIT(BuildErrorEnvelope(TJSONNull.Create, ErrInvalidRequest, 'Invalid request: expected JSON object'));

    Req := TJSONObject(Parsed);

    MethodVal := Req.GetValue('method');
    if not (MethodVal IS TJSONString) then
      EXIT(BuildErrorEnvelope(CloneIdOrNull(Req.GetValue('id')),
                              ErrInvalidRequest, 'Invalid request: missing "method"'));
    Method := MethodVal.Value;

    IdNode := Req.GetValue('id');  // owned by Parsed — do not free

    ParamsVal := Req.GetValue('params');
    if ParamsVal IS TJSONObject
      then Params := TJSONObject(ParamsVal)
      else Params := NIL;

    // Notifications: no id, no response. Spec uses 'notifications/initialized'.
    if IdNode = NIL then
    begin
      if Method = 'notifications/initialized' then
        BridgeLogInfo('mcp', 'client initialized');
      EXIT('');
    end;

    TRY
      if Method = 'initialize' then
        Inner := BuildInitializeResult(Params)
      else if Method = 'ping' then
        Inner := TJSONObject.Create
      else if Method = 'tools/list' then
        Inner := BuildToolListResult
      else if Method = 'tools/call' then
        Inner := BuildToolCallResult(Params)
      else
        EXIT(BuildErrorEnvelope(CloneIdOrNull(IdNode), ErrMethodNotFound, 'Method not found: ' + Method));

      Result := BuildOkEnvelope(CloneIdOrNull(IdNode), Inner);
    EXCEPT
      ON E: Exception DO
      BEGIN
        BridgeLogError('mcp', 'dispatch ' + Method + ': ' + E.ClassName + ': ' + E.Message);
        Result := BuildErrorEnvelope(CloneIdOrNull(IdNode), ErrInternal,
                                     E.ClassName + ': ' + E.Message);
      END;
    END;
  FINALLY
    Parsed.Free;
  END;
END;


END.
