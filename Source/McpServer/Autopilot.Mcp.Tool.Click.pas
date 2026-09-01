unit Autopilot.Mcp.Tool.Click;

{=============================================================================================================
   2026.09.01
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - MCP tool: click
   - Dispatches a click to a control. Path format: "FormName.ComponentName" or "FormName.Panel.NestedComponent".
   - '*.Name' wildcards the form. Optional count parameter; scales timeoutMs proportionally.
   - Optional timeoutMs parameter overrides the bridge's main-thread wait (short value + dismiss_dialog = the modal-dialog recipe).
   - Optional mode parameter: 'message' posts BM_CLICK asynchronously (VCL button-class controls only) —
     presses a modal-opening button without blocking; FMX targets reject it with -32005.
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
    FMode : String;
    FTimeoutMs: Integer;
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

    [Optional]
    [SchemaDescription('Dispatch mode. Omit (or "auto") for the default path (Click method / OnClick). ' +
                       '"message": VCL-on-Windows only — posts BM_CLICK to a button-class control ' +
                       '(TButton/TBitBtn/TCheckBox/TRadioButton) and returns at once; the click runs when ' +
                       'the app next pumps messages. Use it to press a button whose OnClick opens a modal ' +
                       'dialog: the response returns immediately (no -32004), then call dismiss_dialog. ' +
                       'FMX targets reject it with -32005. Response reports dispatchedVia="message".')]
    property Mode: String read FMode write FMode;

    [Optional]
    [SchemaDescription('Override the bridge''s main-thread wait for this call, in milliseconds. ' +
                       'Default: 5000 for a single click, 5000 + (count-1)*100 for batched clicks. ' +
                       'Pass a short value (e.g. 500) when the click is expected to open a modal ' +
                       'dialog and block — expect -32004 main_thread_blocked, then call dismiss_dialog.')]
    property TimeoutMs: Integer read FTimeoutMs write FTimeoutMs;
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
  MaxClickCount    = 1000;  // mirrors MaxClickCount in the bridge dispatchers.
var
  Args: TJSONObject;
  TimeoutMs: Cardinal;
  BudgetedCount: Integer;
begin
  Args := TJSONObject.Create;
  Args.AddPair('path', Params.Path);
  // Forward Count whenever the caller set it to anything other than the class-default 0.
  // Sending count=0 reaches the bridge and is rejected there with a clear error, which is
  // better than silently swallowing it here and dispatching one click.
  if Params.Count <> 0
  then Args.AddPair('count', TJSONNumber.Create(Params.Count));

  // Forward mode verbatim when set; the bridge validates it ("auto"/"message") so a typo
  // comes back as a clear ErrInvalidRequest instead of being silently swallowed here.
  if Params.Mode <> ''
  then Args.AddPair('mode', Params.Mode);

  // Caller-supplied timeoutMs wins (the documented modal-dialog recipe: pass a short
  // timeout, expect -32004, then dismiss_dialog). Otherwise scale the worker-side wait
  // with the requested count so the timeout fires only after a genuinely stuck dispatch,
  // not after a legitimate long count loop. Mitigates Plans/04 R1 by reducing the window
  // where main-thread-blocked fires while the queued procedure is still running.
  // Default 5000 ms for count <= 1; extra 100 ms per extra click.
  if Params.TimeoutMs > 0
  then TimeoutMs := Cardinal(Params.TimeoutMs)
  else if Params.Count > 1
  then
    begin
      // Clamp to the bridge's own cap BEFORE the arithmetic. The bridge rejects anything
      // above MaxClickCount, but that rejection happens after this timeout is computed and
      // sent, so an out-of-range Count is multiplied here first: above ~43 M it overflows
      // Cardinal, which raises EIntOverflow under {$Q+} (Debug and PreRelease) and wraps
      // silently to a nonsense timeout under {$Q-} (Release). Either way the caller loses
      // the bridge's clear "count out of range" and gets a vague failure instead. Clamping
      // costs nothing: no more than MaxClickCount clicks can ever run.
      BudgetedCount := Params.Count;
      if BudgetedCount > MaxClickCount
      then BudgetedCount := MaxClickCount;
      TimeoutMs := DefaultTimeoutClickMs + Cardinal(BudgetedCount - 1) * PerClickBudgetMs;
    end
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
