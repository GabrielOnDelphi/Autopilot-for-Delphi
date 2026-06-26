unit Autopilot.Mcp.JsonRpc;

{=============================================================================================================
   2026.06
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   Single-line JSON-RPC 2.0 dispatcher for the Autopilot MCP server. Implements the minimum MCP
   surface Claude Code needs: initialize, notifications/initialized (notification), ping, tools/list,
   tools/call. Everything else returns -32601 Method not found.

   No threads, no transport here — the caller (Autopilot.Mcp.Stdio) drives the readln loop.
   Pure JSON in -> JSON out (or '' for notifications).

   Tool instance caching: each tool name maps to one IMCPTool, created via TMCPRegistry on first
   use and held until shutdown.

   id handling: every JSON-RPC response must echo the request's id verbatim, preserving its JSON
   type (number, string, nil). We clone the raw TJSONValue so a number stays a number and a string
   stays a string.
=============================================================================================================}

interface


/// Process one JSON-RPC line. Returns the response line (no trailing newline)
/// or '' if the request was a notification (no response expected).
function DispatchLine(const ALine: String): String;

/// Drop the cached tool instances. Used by unit tests; production never calls.
procedure ResetToolCache;


implementation

uses
  System.SysUtils, System.JSON, System.Generics.Collections,
  Autopilot.Bridge.Core,
  Autopilot.Bridge.Log,
  MCPServer.Types,
  MCPServer.Registration,
  MCPServer.Tool.Base;


const
  ErrParseError     = -32700;
  ErrInvalidRequest = -32600;
  ErrMethodNotFound = -32601;
  ErrInvalidParams  = -32602;
  ErrInternal       = -32603;

  ServerName = 'Autopilot.Mcp';

const
  /// Versions we accept verbatim on initialize. Anything else negotiates down
  /// to MCP_PROTOCOL_VERSION. Order matters for readability only — lookup is linear.
  GSupportedVersions: array[0..3] of String = (
    '2025-11-25',   // current per spec
    '2025-06-18',
    '2025-03-26',
    '2024-11-05'
  );

type
  /// Holder for the singleton tool-instance cache. Wrapped in a class so we can
  /// hang a class destructor on it (no finalization section, per project rule).
  /// One IMCPTool per tool name, built lazily on first tools/list or tools/call,
  /// reused for the rest of the server's lifetime.
  TToolCache = class
  strict private
    class var FMap: TDictionary<String, IMCPTool>;
    class procedure EnsureMap;
  public
    class function Resolve(const AName: String): IMCPTool;
    class procedure Reset;
    class destructor Destroy;
  end;


class procedure TToolCache.EnsureMap;
begin
  if FMap = nil then
    FMap := TDictionary<String, IMCPTool>.Create;
end;


class function TToolCache.Resolve(const AName: String): IMCPTool;
begin
  EnsureMap;
  if FMap.TryGetValue(AName, Result) then Exit;
  if not TMCPRegistry.HasTool(AName) then Exit(nil);
  Result := TMCPRegistry.CreateTool(AName);
  FMap.Add(AName, Result);
end;


class procedure TToolCache.Reset;
begin
  FreeAndNil(FMap);
end;


class destructor TToolCache.Destroy;
begin
  FreeAndNil(FMap);
end;


procedure ResetToolCache;
begin
  TToolCache.Reset;
end;


/// Look up (or create-and-cache) the tool by name. Returns nil if not registered.
function ResolveCachedTool(const AName: String): IMCPTool;
begin
  Result := TToolCache.Resolve(AName);
end;


/// True iff AVersion is one we accept verbatim during initialize negotiation.
function IsSupportedVersion(const AVersion: String): Boolean;
var
  V: String;
begin
  for V in GSupportedVersions do
    if V = AVersion then Exit(true);
  Result := false;
end;


/// Clone the request id into the response. The MUST-preserve-type rule of
/// JSON-RPC 2.0 §5: a number response id matches a number request id, etc.
/// AIdNode may be nil (request had no id field, but we shouldn't get here in
/// that case — notifications are handled earlier) or any TJSONValue subtype.
function CloneIdOrNull(AIdNode: TJSONValue): TJSONValue;
begin
  if AIdNode = nil
    then Result := TJSONNull.Create
    else Result := AIdNode.Clone as TJSONValue;
end;


/// Build the {jsonrpc:'2.0', id, result:<inner>} envelope. Takes ownership of
/// AInner and ACloneOfId.
function BuildOkEnvelope(ACloneOfId: TJSONValue; AInner: TJSONValue): String;
var
  Resp: TJSONObject;
begin
  Resp := TJSONObject.Create;
  try
    Resp.AddPair('jsonrpc', '2.0');
    Resp.AddPair('id', ACloneOfId);
    Resp.AddPair('result', AInner);
    Result := Resp.ToJSON;
  finally
    Resp.Free;
  end;
end;


/// Build the {jsonrpc:'2.0', id, error:{code,message}} envelope. Takes ownership
/// of ACloneOfId.
function BuildErrorEnvelope(ACloneOfId: TJSONValue; ACode: Integer; const AMsg: String): String;
var
  Resp, Err: TJSONObject;
begin
  Err := TJSONObject.Create;
  Err.AddPair('code', TJSONNumber.Create(ACode));
  Err.AddPair('message', AMsg);

  Resp := TJSONObject.Create;
  try
    Resp.AddPair('jsonrpc', '2.0');
    Resp.AddPair('id', ACloneOfId);
    Resp.AddPair('error', Err);
    Result := Resp.ToJSON;
  finally
    Resp.Free;
  end;
end;


/// Negotiate the protocolVersion the client sent against our supported list.
/// AParams may be nil (no params on initialize is unusual but legal).
function NegotiateVersion(AParams: TJSONObject): String;
var
  Node: TJSONValue;
begin
  Result := MCP_PROTOCOL_VERSION;
  if AParams = nil then Exit;
  Node := AParams.GetValue('protocolVersion');
  if (Node <> nil) and IsSupportedVersion(Node.Value) then
    Result := Node.Value;
end;


/// Build the result object for the initialize request.
function BuildInitializeResult(AParams: TJSONObject): TJSONObject;
var
  Caps, ToolsCap, ServerInfo: TJSONObject;
begin
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
end;


/// Build the tools/list result: {tools:[ {name,description,inputSchema}, ... ]}.
function BuildToolListResult: TJSONObject;
var
  ToolsArr: TJSONArray;
  Names   : TArray<String>;
  Name    : String;
  Tool    : IMCPTool;
  Entry   : TJSONObject;
begin
  ToolsArr := TJSONArray.Create;
  Result   := TJSONObject.Create;
  Result.AddPair('tools', ToolsArr);

  Names := TMCPRegistry.GetToolNames;
  for Name in Names do
  begin
    Tool := ResolveCachedTool(Name);
    if Tool = nil then Continue; // shouldn't happen — Names came from the registry

    Entry := TJSONObject.Create;
    Entry.AddPair('name', Tool.Name);
    Entry.AddPair('description', Tool.Description);
    // Tool.InputSchema returns a fresh TJSONObject — we own it now.
    Entry.AddPair('inputSchema', Tool.InputSchema);
    ToolsArr.AddElement(Entry);
  end;
end;


/// True iff the tool's response string represents an error. Tries to parse it
/// as JSON and looks at the conventional shape {ok:false} or {error:{...}}.
/// Falls back to the heuristic of "starts with Error:" if the string is not
/// parseable JSON — that catches exception messages we wrap with that prefix
/// in BuildToolCallResult.
function DetectIsError(const AText: String): Boolean;
var
  Parsed: TJSONValue;
  Obj   : TJSONObject;
  OkVal : TJSONValue;
begin
  Parsed := TJSONObject.ParseJSONValue(AText);
  try
    if Parsed is TJSONObject then
    begin
      Obj := TJSONObject(Parsed);
      OkVal := Obj.GetValue('ok');
      if (OkVal is TJSONBool) and (not TJSONBool(OkVal).AsBoolean) then
        Exit(true);
      if Obj.GetValue('error') <> nil then
        Exit(true);
      Exit(false);
    end;
  finally
    Parsed.Free;
  end;

  // Not parseable JSON — fall back to the prefix heuristic.
  Result := AText.StartsWith('Error:');
end;


/// Wrap a plain text payload (the tool's return string) in the MCP tools/call
/// content[] structure: {content:[{type:'text', text:<s>}], isError:<bool>}.
function WrapToolCallContent(const AText: String; AIsError: Boolean): TJSONObject;
var
  Item, Outer: TJSONObject;
  Arr        : TJSONArray;
begin
  Item := TJSONObject.Create;
  Item.AddPair('type', 'text');
  Item.AddPair('text', AText);

  Arr := TJSONArray.Create;
  Arr.AddElement(Item);

  Outer := TJSONObject.Create;
  Outer.AddPair('content', Arr);
  if AIsError then
    Outer.AddPair('isError', TJSONBool.Create(true));
  Result := Outer;
end;


/// Build the tools/call result. Reads name + arguments from AParams (either
/// may be missing or wrong-typed — handle gracefully), resolves the tool,
/// runs it, and wraps the output. AParams may be nil.
function BuildToolCallResult(AParams: TJSONObject): TJSONObject;
var
  ToolName  : String;
  NameNode  : TJSONValue;
  ArgsNode  : TJSONValue;
  Args      : TJSONObject;
  ArgsOwned : Boolean;
  Tool      : IMCPTool;
  Text      : String;
begin
  ToolName := '';
  if AParams <> nil then
  begin
    NameNode := AParams.GetValue('name');
    if NameNode is TJSONString then
      ToolName := NameNode.Value;
  end;

  if ToolName = '' then
    Exit(WrapToolCallContent('Error: tools/call missing required "name" parameter', true));

  // Extract arguments. The spec lets clients omit "arguments" entirely or send
  // nil; either is treated as an empty object.
  Args      := nil;
  ArgsOwned := false;
  if AParams <> nil then
  begin
    ArgsNode := AParams.GetValue('arguments');
    if ArgsNode is TJSONObject then
      Args := TJSONObject(ArgsNode);
  end;
  if Args = nil then
  begin
    Args := TJSONObject.Create;
    ArgsOwned := true;
  end;

  try
    Tool := ResolveCachedTool(ToolName);
    if Tool = nil then
      Exit(WrapToolCallContent('Error: Tool not found: ' + ToolName, true));

    try
      Text := Tool.Execute(Args);
    except
      on E: Exception do
        Exit(WrapToolCallContent('Error executing tool: ' + E.Message, true));
    end;
    Result := WrapToolCallContent(Text, DetectIsError(Text));
  finally
    if ArgsOwned then Args.Free;
  end;
end;


function DispatchLine(const ALine: String): String;
var
  Parsed   : TJSONValue;
  Req      : TJSONObject;
  IdNode   : TJSONValue;
  Method   : String;
  MethodVal: TJSONValue;
  Params   : TJSONObject;
  ParamsVal: TJSONValue;
  Inner    : TJSONObject;
begin
  Parsed := TJSONObject.ParseJSONValue(ALine);
  if Parsed = nil then
    Exit(BuildErrorEnvelope(TJSONNull.Create, ErrParseError, 'Parse error'));

  try
    if not (Parsed is TJSONObject) then
      // Batch arrays land here too — MCP doesn't use batches; reject.
      Exit(BuildErrorEnvelope(TJSONNull.Create, ErrInvalidRequest, 'Invalid request: expected JSON object'));

    Req := TJSONObject(Parsed);

    MethodVal := Req.GetValue('method');
    if not (MethodVal is TJSONString) then
      Exit(BuildErrorEnvelope(CloneIdOrNull(Req.GetValue('id')),
                              ErrInvalidRequest, 'Invalid request: missing "method"'));
    Method := MethodVal.Value;

    IdNode := Req.GetValue('id');  // owned by Parsed — do not free

    ParamsVal := Req.GetValue('params');
    if ParamsVal is TJSONObject
      then Params := TJSONObject(ParamsVal)
      else Params := nil;

    // Notifications: no id, no response. Spec uses 'notifications/initialized'.
    if IdNode = nil then
    begin
      if Method = 'notifications/initialized' then
        BridgeLogInfo('mcp', 'client initialized');
      Exit('');
    end;

    try
      if Method = 'initialize' then
        Inner := BuildInitializeResult(Params)
      else if Method = 'ping' then
        Inner := TJSONObject.Create
      else if Method = 'tools/list' then
        Inner := BuildToolListResult
      else if Method = 'tools/call' then
        Inner := BuildToolCallResult(Params)
      else
        Exit(BuildErrorEnvelope(CloneIdOrNull(IdNode), ErrMethodNotFound, 'Method not found: ' + Method));

      Result := BuildOkEnvelope(CloneIdOrNull(IdNode), Inner);
    except
      on E: Exception do
      begin
        BridgeLogError('mcp', 'dispatch ' + Method + ': ' + E.ClassName + ': ' + E.Message);
        Result := BuildErrorEnvelope(CloneIdOrNull(IdNode), ErrInternal, E.ClassName + ': ' + E.Message);
      end;
    end;
  finally
    Parsed.Free;
  end;
end;


end.
