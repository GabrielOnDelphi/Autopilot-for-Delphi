unit Autopilot.Mcp.Tool.Click;

{=============================================================================================================
   2026.06
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - MCP tool: click
   - Dispatches a click to a control. Path format: "FormName.ComponentName" or "FormName.Panel.NestedComponent".
   - '*.Name' wildcards the form. Optional count parameter; scales timeoutMs proportionally.
   - Runs in Autopilot.Mcp.exe (Windows PC-side MCP server); target may be any platform.
=============================================================================================================}

interface

uses
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Mcp.ToolBase;

type
  TClickParams = class
  private
    FPath : String;
    FPid  : Integer;
    FCount: Integer;
  public
    [SchemaDescription('Path to the control. See list_tree for available paths. ' +
                       'Forms: "Form", "Form.Leaf", "Form.A.B.C". Unnamed components: "@TButton#N".')]
    property Path: String read FPath write FPath;

    [Optional]
    [SchemaDescription('Optional PID to disambiguate when multiple targets are active.')]
    property Pid: Integer read FPid write FPid;

    [Optional]
    [SchemaDescription('How many times to click in one round-trip. Default 1. Valid range 1..1000; ' +
                       'values outside that range are rejected with an error. Re-checks Enabled ' +
                       'between iterations and stops early with stoppedReason="disabled" if the control ' +
                       'gets disabled by a previous click.')]
    property Count: Integer read FCount write FCount;
  end;

  TClickTool = class(TMCPToolBase<TClickParams>)
  protected
    function ExecuteWithParams(const Params: TClickParams): String; override;
  public
    constructor Create; override;
  end;


implementation

uses
  Autopilot.Bridge.Core,
  MCPServer.Registration;


constructor TClickTool.Create;
begin
  inherited;
  FName := 'click';
  FDescription := 'Click a control on a running target form by path.';
end;


function TClickTool.ExecuteWithParams(const Params: TClickParams): String;
const
  PerClickBudgetMs = 100;   // generous per-click budget; OnClick handlers averaging < 100 ms.
var
  Args: TJSONObject;
  TimeoutMs: Cardinal;
begin
  Args := TJSONObject.Create;
  Args.AddPair('path', Params.Path);
  // Forward Count whenever the caller set it to anything other than the class-default 0.
  // Sending count=0 reaches the bridge and is rejected there with a clear error, which is
  // better than silently swallowing it here and dispatching one click.
  if Params.Count <> 0
  then Args.AddPair('count', TJSONNumber.Create(Params.Count));

  // Scale the worker-side wait with the requested count so the timeout fires only after
  // a genuinely stuck dispatch, not after a legitimate long count loop. Mitigates Plans/04 R1
  // by reducing the window where main-thread-blocked fires while the queued procedure is still
  // running. Default 5000 ms for count <= 1; extra 100 ms per extra click.
  if Params.Count > 1
  then TimeoutMs := DefaultTimeoutClickMs + Cardinal(Params.Count - 1) * PerClickBudgetMs
  else TimeoutMs := 0;   // 0 = let bridge use its per-command default
  Result := RunCommandOnTarget(Cardinal(Params.Pid),
                               BuildRequest(1, 'click', Args, TimeoutMs),
                               TimeoutMs);
end;


initialization
  TMCPRegistry.RegisterTool('click',
    function: IMCPTool
    begin
      Result := TClickTool.Create;
    end
  );


end.
