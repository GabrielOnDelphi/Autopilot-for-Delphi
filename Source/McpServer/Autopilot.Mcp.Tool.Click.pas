UNIT Autopilot.Mcp.Tool.Click;

(*=====================================================
   2026.05.12 — added optional count parameter; scales timeoutMs proportionally.
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────────────┐
   │  WINDOWS  (PC-side MCP server)       │   runs in Autopilot.Mcp.exe; target may be any platform
   └──────────────────────────────────────┘

   MCP tool: click
   Dispatches a click to a control. Path format: "FormName.ComponentName"
   or "FormName.Panel.NestedComponent". '*.Name' wildcards the form.
=====================================================*)

INTERFACE

USES
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Mcp.ToolBase;

TYPE
  TClickParams = CLASS
  PRIVATE
    FPath : String;
    FPid  : Integer;
    FCount: Integer;
  PUBLIC
    [SchemaDescription('Path to the control. See list_tree for available paths. ' +
                       'Forms: "Form", "Form.Leaf", "Form.A.B.C". Unnamed components: "@TButton#N".')]
    PROPERTY Path: String READ FPath WRITE FPath;

    [Optional]
    [SchemaDescription('Optional PID to disambiguate when multiple targets are active.')]
    PROPERTY Pid: Integer READ FPid WRITE FPid;

    [Optional]
    [SchemaDescription('How many times to click in one round-trip. Default 1. Valid range 1..1000; ' +
                       'values outside that range are rejected with an error. Re-checks Enabled ' +
                       'between iterations and stops early with stoppedReason="disabled" if the control ' +
                       'gets disabled by a previous click.')]
    PROPERTY Count: Integer READ FCount WRITE FCount;
  END;

  TClickTool = CLASS(TMCPToolBase<TClickParams>)
  PROTECTED
    FUNCTION ExecuteWithParams(CONST Params: TClickParams): String; OVERRIDE;
  PUBLIC
    CONSTRUCTOR Create; OVERRIDE;
  END;


IMPLEMENTATION

USES
  MCPServer.Registration;


CONSTRUCTOR TClickTool.Create;
BEGIN
  inherited;
  FName := 'click';
  FDescription := 'Click a control on a running target form by path.';
END;


FUNCTION TClickTool.ExecuteWithParams(CONST Params: TClickParams): String;
CONST
  PerClickBudgetMs = 100;   // generous per-click budget; OnClick handlers averaging < 100 ms.
VAR
  Args: TJSONObject;
  TimeoutMs: Cardinal;
BEGIN
  Args := TJSONObject.Create;
  Args.AddPair('path', Params.Path);
  // Forward Count whenever the caller set it to anything other than the class-default 0.
  // Sending count=0 reaches the bridge and is rejected there with a clear error, which is
  // better than silently swallowing it here and dispatching one click.
  if Params.Count <> 0 then
    Args.AddPair('count', TJSONNumber.Create(Params.Count));

  // Scale the worker-side wait with the requested count so the timeout fires only after
  // a genuinely stuck dispatch, not after a legitimate long count loop. Mitigates Plans/04 R1
  // by reducing the window where main-thread-blocked fires while the queued procedure is still
  // running. Default 5000 ms for count <= 1; extra 100 ms per extra click.
  if Params.Count > 1 then
    TimeoutMs := Cardinal(Params.Count) * PerClickBudgetMs
  else
    TimeoutMs := 0;   // 0 = let bridge use its per-command default
  Result := RunCommandOnTarget(Cardinal(Params.Pid),
                               BuildRequest(1, 'click', Args, TimeoutMs),
                               TimeoutMs);
END;


INITIALIZATION
  TMCPRegistry.RegisterTool('click',
    FUNCTION: IMCPTool
    BEGIN
      Result := TClickTool.Create;
    END
  );


END.
