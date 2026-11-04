unit Autopilot.Mcp.Tool.WaitFor;

{=============================================================================================================
   2026.11.02
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - MCP tool: wait_for
   - Polls a control's Text/Caption every PollIntervalMs until it equals ExpectedText, or deadline expires.
   - Returns matched:true/false with the final observed value, so callers can branch without inspecting a raised error.
   - Exception: a poll that gets -32099 (no target) or -32098 (target frozen) ends the wait at once and returns that error envelope.
   - The polling loop runs on the MCP server side so the bridge worker stays simple.
   - Runs in Autopilot.Mcp.exe (Windows PC-side MCP server); target may be any platform.
=============================================================================================================}

interface

uses
  Winapi.Windows, System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Bridge.Core, Autopilot.Bridge.Log,

  Autopilot.Mcp.ToolBase;

const
  DefaultPollIntervalMs = 100;
  DefaultWaitTimeoutMs  = 10000;

type
  TWaitForParams = class
  private
    FPath          : String;
    FExpectedText  : String;
    FTimeoutMs     : Integer;
    FPollIntervalMs: Integer;
    FPid           : Integer;
  public
    [SchemaDescription('Control path from list_tree: "Form", "Form.Leaf", "Form.A.B.C" or "@TButton#N".')]
    property Path: String read FPath write FPath;

    [SchemaDescription('Text/Caption to wait for (exact match).')]
    property ExpectedText: String read FExpectedText write FExpectedText;

    [Optional]
    [SchemaDescription('Deadline in ms. Default 10000.')]
    property TimeoutMs: Integer read FTimeoutMs write FTimeoutMs;

    [Optional]
    [SchemaDescription('Poll interval in ms. Default 100.')]
    property PollIntervalMs: Integer read FPollIntervalMs write FPollIntervalMs;

    [Optional]
    [SchemaDescription('Target PID. Needed only when several targets run.')]
    property Pid: Integer read FPid write FPid;
  end;

  TWaitForTool = class(TMCPToolBase<TWaitForParams>)
  protected
    function ExecuteWithParams(const Params: TWaitForParams): String; override;
  public
    constructor Create; override;
  end;


IMPLEMENTATION

uses
  MCPServer.Registration;


constructor TWaitForTool.Create;
begin
  inherited;
  FName := 'wait_for';
  FDescription := 'Poll a control''s Text/Caption until it equals a value or the deadline passes.';
end;


{ Pull both fields we care about out of one poll response, in ONE parse.

  AText      - "text" of a successful get_text response; '' on any failure.
  AErrorCode - error.code of an ok:false response; 0 otherwise. }
procedure ParsePollResponse(const AResponseJson: String; OUT AText: String; OUT AErrorCode: Integer);
var
  Root, Result_: TJSONValue;
  Obj: TJSONObject;
  V: TJSONValue;
begin
  AText   := '';
  AErrorCode := 0;
  Root := TJSONObject.ParseJSONValue(AResponseJson);
  if Root = nil then EXIT;
  try
    if not (Root is TJSONObject) then EXIT;
    Obj := TJSONObject(Root);

    V := Obj.GetValue('ok');
    if not (V is TJSONBool) or not TJSONBool(V).AsBoolean then
      begin
        V := Obj.GetValue('error');
        if V is TJSONObject then
          begin
            V := TJSONObject(V).GetValue('code');
            if V is TJSONNumber
            then AErrorCode := TJSONNumber(V).AsInt;
          end;
        EXIT;
      end;
    Result_ := Obj.GetValue('result');
    if not (Result_ is TJSONObject) then EXIT;
    V := TJSONObject(Result_).GetValue('text');
    if V is TJSONString
    then AText := TJSONString(V).Value;
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
  PollCount, PollError: Integer;
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
      ParsePollResponse(Resp, Current, PollError);
      { No target (-32099): hand the answer, with its setup steps, straight back to the AI instead of polling a target that does not exist until the timeout.
        Target not responding (-32098: its pipe stayed busy, or it accepted the connection and did not answer): the whole target process is frozen, so more polls only hide the cause behind a matched:false.
        Hand that answer straight back too. }
      if (PollError = ErrTargetNotRunning) or (PollError = ErrTargetNotResponding)
      then EXIT(Resp);
      if Current = Params.ExpectedText then
        begin
          Matched := TRUE;
          Break;
        end;
      if GetTickCount64 >= Deadline then Break;
      Sleep(PollIv);
    end;

  BridgeLogInfo('mcp', 'wait_for path=' + Params.Path + ' matched=' + BoolToStr(Matched, TRUE) + ' polls=' + IntToStr(PollCount));

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
