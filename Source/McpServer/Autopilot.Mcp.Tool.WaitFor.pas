UNIT Autopilot.Mcp.Tool.WaitFor;

(*=====================================================
   2026.05.13
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────────────┐
   │  WINDOWS  (PC-side MCP server)       │   runs in Autopilot.Mcp.exe; target may be any platform
   └──────────────────────────────────────┘

   MCP tool: wait_for
   Polls a control's Text/Caption every PollIntervalMs until it equals AnExpected
   string, or the deadline expires. Returns matched=TRUE/FALSE with the final
   observed value, so callers can branch without inspecting a thrown error.

   Phase-2 MVP: only Text/Caption is polled. Extending to Checked/Enabled/Visible
   needs either a generic get_property bridge command or per-type tools — deferred.

   The polling loop runs on the MCP server side so the bridge worker stays simple.
=====================================================*)

INTERFACE

USES
  Winapi.Windows,
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Bridge.Core,
  Autopilot.Bridge.Log,
  Autopilot.Mcp.PipeClient,
  Autopilot.Mcp.ToolBase;

CONST
  DefaultPollIntervalMs = 100;
  DefaultWaitTimeoutMs  = 10_000;

TYPE
  TWaitForParams = CLASS
  PRIVATE
    FPath          : String;
    FExpectedText  : String;
    FTimeoutMs     : Integer;
    FPollIntervalMs: Integer;
    FPid           : Integer;
  PUBLIC
    [SchemaDescription('Path to the control whose Text/Caption is polled. See list_tree for paths. ' +
                       'Forms: "Form", "Form.Leaf", "Form.A.B.C". Unnamed components: "@TButton#N".')]
    PROPERTY Path: String READ FPath WRITE FPath;

    [SchemaDescription('Polls until the control''s Text/Caption equals this value (exact match).')]
    PROPERTY ExpectedText: String READ FExpectedText WRITE FExpectedText;

    [Optional]
    [SchemaDescription('Overall deadline in milliseconds. Default 10000.')]
    PROPERTY TimeoutMs: Integer READ FTimeoutMs WRITE FTimeoutMs;

    [Optional]
    [SchemaDescription('How often to poll, in milliseconds. Default 100.')]
    PROPERTY PollIntervalMs: Integer READ FPollIntervalMs WRITE FPollIntervalMs;

    [Optional]
    [SchemaDescription('Optional PID to disambiguate when multiple targets are active.')]
    PROPERTY Pid: Integer READ FPid WRITE FPid;
  END;

  TWaitForTool = CLASS(TMCPToolBase<TWaitForParams>)
  PROTECTED
    FUNCTION ExecuteWithParams(CONST Params: TWaitForParams): String; OVERRIDE;
  PUBLIC
    CONSTRUCTOR Create; OVERRIDE;
  END;


IMPLEMENTATION

USES
  MCPServer.Registration;


CONSTRUCTOR TWaitForTool.Create;
BEGIN
  inherited;
  FName := 'wait_for';
  FDescription := 'Wait until a control''s Text/Caption equals a target value, polling at a fixed interval.';
END;


// Pull "text" out of a successful get_text response, or '' on failure.
FUNCTION ExtractTextFromResponse(CONST AResponseJson: String): String;
VAR
  Root, Result_: TJSONValue;
  Obj: TJSONObject;
  V: TJSONValue;
BEGIN
  Result := '';
  Root := TJSONObject.ParseJSONValue(AResponseJson);
  if Root = NIL then EXIT;
  TRY
    if not (Root IS TJSONObject) then EXIT;
    Obj := TJSONObject(Root);
    V := Obj.GetValue('ok');
    if not (V IS TJSONBool) or not TJSONBool(V).AsBoolean then EXIT;
    Result_ := Obj.GetValue('result');
    if not (Result_ IS TJSONObject) then EXIT;
    V := TJSONObject(Result_).GetValue('text');
    if V IS TJSONString then
      Result := TJSONString(V).Value;
  FINALLY
    Root.Free;
  END;
END;


FUNCTION TWaitForTool.ExecuteWithParams(CONST Params: TWaitForParams): String;
VAR
  Args, Wrap: TJSONObject;
  Resp: String;
  Deadline: UInt64;
  PollIv, OverallTimeout: Cardinal;
  Current: String;
  Matched: Boolean;
  PollCount: Integer;
BEGIN
  if Params.TimeoutMs > 0 then
    OverallTimeout := Params.TimeoutMs
  else
    OverallTimeout := DefaultWaitTimeoutMs;
  if Params.PollIntervalMs > 0 then
    PollIv := Params.PollIntervalMs
  else
    PollIv := DefaultPollIntervalMs;

  Deadline := GetTickCount64 + OverallTimeout;
  Matched   := FALSE;
  Current   := '';
  PollCount := 0;

  WHILE TRUE DO
  BEGIN
    Args := TJSONObject.Create;
    Args.AddPair('path', Params.Path);
    Resp := RunCommandOnTarget(Cardinal(Params.Pid), BuildRequest(1, 'get_text', Args));
    Inc(PollCount);
    Current := ExtractTextFromResponse(Resp);
    if Current = Params.ExpectedText then
    begin
      Matched := TRUE;
      Break;
    end;
    if GetTickCount64 >= Deadline then Break;
    Sleep(PollIv);
  END;

  BridgeLogInfo('mcp', 'wait_for path=' + Params.Path + ' matched=' + BoolToStr(Matched, TRUE) +
                       ' polls=' + IntToStr(PollCount));

  Wrap := TJSONObject.Create;
  TRY
    Wrap.AddPair('matched', TJSONBool.Create(Matched));
    Wrap.AddPair('currentValue', Current);
    Wrap.AddPair('expectedValue', Params.ExpectedText);
    Wrap.AddPair('pollCount', TJSONNumber.Create(PollCount));
    Result := Wrap.ToJSON;
  FINALLY
    Wrap.Free;
  END;
END;


INITIALIZATION
  TMCPRegistry.RegisterTool('wait_for',
    FUNCTION: IMCPTool
    BEGIN
      Result := TWaitForTool.Create;
    END
  );


END.
