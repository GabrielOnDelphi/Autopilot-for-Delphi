unit Autopilot.Mcp.Tool.WaitFor;

{=============================================================================================================
   2026.06
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - MCP tool: wait_for
   - Polls a control's Text/Caption every PollIntervalMs until it equals ExpectedText, or deadline expires.
   - Returns matched:true/false with the final observed value, so callers can branch without inspecting a
     raised error.
   - The polling loop runs on the MCP server side so the bridge worker stays simple.
   - Runs in Autopilot.Mcp.exe (Windows PC-side MCP server); target may be any platform.
=============================================================================================================}

interface

uses
  Winapi.Windows,
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Bridge.Core,
  Autopilot.Bridge.Log,
  Autopilot.Mcp.PipeClient,
  Autopilot.Mcp.ToolBase;

const
  DefaultPollIntervalMs = 100;
  DefaultWaitTimeoutMs  = 10_000;

type
  TWaitForParams = class
  private
    FPath          : String;
    FExpectedText  : String;
    FTimeoutMs     : Integer;
    FPollIntervalMs: Integer;
    FPid           : Integer;
  public
    [SchemaDescription('Path to the control whose Text/Caption is polled. See list_tree for paths. ' +
                       'Forms: "Form", "Form.Leaf", "Form.A.B.C". Unnamed components: "@TButton#N".')]
    property Path: String read FPath write FPath;

    [SchemaDescription('Polls until the control''s Text/Caption equals this value (exact match).')]
    property ExpectedText: String read FExpectedText write FExpectedText;

    [Optional]
    [SchemaDescription('Overall deadline in milliseconds. Default 10000.')]
    property TimeoutMs: Integer read FTimeoutMs write FTimeoutMs;

    [Optional]
    [SchemaDescription('How often to poll, in milliseconds. Default 100.')]
    property PollIntervalMs: Integer read FPollIntervalMs write FPollIntervalMs;

    [Optional]
    [SchemaDescription('Optional PID to disambiguate when multiple targets are active.')]
    property Pid: Integer read FPid write FPid;
  end;

  TWaitForTool = class(TMCPToolBase<TWaitForParams>)
  protected
    function ExecuteWithParams(const Params: TWaitForParams): String; override;
  public
    constructor Create; override;
  end;


implementation

uses
  MCPServer.Registration;


constructor TWaitForTool.Create;
begin
  inherited;
  FName := 'wait_for';
  FDescription := 'Wait until a control''s Text/Caption equals a target value, polling at a fixed interval.';
end;


// Pull "text" out of a successful get_text response, or '' on failure.
function ExtractTextFromResponse(const AResponseJson: String): String;
var
  Root, Result_: TJSONValue;
  Obj: TJSONObject;
  V: TJSONValue;
begin
  Result := '';
  Root := TJSONObject.ParseJSONValue(AResponseJson);
  if Root = nil then EXIT;
  try
    if not (Root is TJSONObject) then EXIT;
    Obj := TJSONObject(Root);
    V := Obj.GetValue('ok');
    if not (V is TJSONBool) or not TJSONBool(V).AsBoolean then EXIT;
    Result_ := Obj.GetValue('result');
    if not (Result_ is TJSONObject) then EXIT;
    V := TJSONObject(Result_).GetValue('text');
    if V is TJSONString
    then Result := TJSONString(V).Value;
  finally
    FreeAndNil(Root);
  end;
end;


function TWaitForTool.ExecuteWithParams(const Params: TWaitForParams): String;
var
  Args, Wrap: TJSONObject;
  Resp: String;
  Deadline: UInt64;
  PollIv, OverallTimeout: Cardinal;
  Current: String;
  Matched: Boolean;
  PollCount: Integer;
begin
  if Params.TimeoutMs > 0
  then OverallTimeout := Params.TimeoutMs
  else OverallTimeout := DefaultWaitTimeoutMs;
  if Params.PollIntervalMs > 0
  then PollIv := Params.PollIntervalMs
  else PollIv := DefaultPollIntervalMs;

  Deadline := GetTickCount64 + OverallTimeout;
  Matched   := FALSE;
  Current   := '';
  PollCount := 0;

  while TRUE do
  begin
    Args := TJSONObject.Create;
    Args.AddPair('path', Params.Path);
    Resp := RunCommandOnTarget(Cardinal(Params.Pid), BuildRequest(1, 'get_text', Args));
    Inc(PollCount);
    Current := ExtractTextFromResponse(Resp);
    if Current = Params.ExpectedText
    then begin
      Matched := TRUE;
      Break;
    end;
    if GetTickCount64 >= Deadline then Break;
    Sleep(PollIv);
  end;

  BridgeLogInfo('mcp', 'wait_for path=' + Params.Path + ' matched=' + BoolToStr(Matched, TRUE) +
                       ' polls=' + IntToStr(PollCount));

  Wrap := TJSONObject.Create;
  try
    Wrap.AddPair('matched', TJSONBool.Create(Matched));
    Wrap.AddPair('currentValue', Current);
    Wrap.AddPair('expectedValue', Params.ExpectedText);
    Wrap.AddPair('pollCount', TJSONNumber.Create(PollCount));
    Result := Wrap.ToJSON;
  finally
    FreeAndNil(Wrap);
  end;
end;


initialization
  TMCPRegistry.RegisterTool('wait_for',
    function: IMCPTool
    begin
      Result := TWaitForTool.Create;
    end
  );


end.
