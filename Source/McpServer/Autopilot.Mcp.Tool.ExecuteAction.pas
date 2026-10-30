unit Autopilot.Mcp.Tool.ExecuteAction;

{=============================================================================================================
   2026.09
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - MCP tool: execute_action
   - Fires TBasicAction.Execute by path. Use when the command is bound to a TAction whose OnExecute (not a
     control's OnClick) carries the logic — shortcut-only actions like actFileExit (no menu item or toolbar
     button) are otherwise unreachable through the bridge.
   - For plain controls (TButton, TCheckBox, etc.) use 'click' instead.
   - Inherits the click timeout budget (DefaultTimeoutClickMs, 5000 ms) because OnExecute is user code.
   - Runs in Autopilot.Mcp.exe (Windows PC-side MCP server); target may be any platform.
=============================================================================================================}

interface

uses
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Mcp.ToolBase;

type
  TExecuteActionParams = class
  private
    FPath: String;
    FPid : Integer;
  public
    [SchemaDescription('Path to a TAction (any TBasicAction), e.g. "MainForm.actFileExit". ' +
                       'list_tree shows it with class "TAction".')]
    property Path: String read FPath write FPath;

    [Optional]
    [SchemaDescription('Target PID. Needed only when several targets run.')]
    property Pid: Integer read FPid write FPid;
  end;

  TExecuteActionTool = class(TMCPToolBase<TExecuteActionParams>)
  protected
    function ExecuteWithParams(const Params: TExecuteActionParams): String; override;
  public
    constructor Create; override;
  end;


implementation

uses
  MCPServer.Registration;


constructor TExecuteActionTool.Create;
begin
  inherited;
  FName := 'execute_action';
  FDescription := 'Fire a TAction''s OnExecute by path. Use it for shortcut-only actions that no ' +
                  'control clicks. For plain controls use click. Refuses a disabled action (-32003) ' +
                  'and a non-action (-32005). executed=false in the result means the action has ' +
                  'no OnExecute handler.';
end;


function TExecuteActionTool.ExecuteWithParams(const Params: TExecuteActionParams): String;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('path', Params.Path);
  Result := RunCommandOnTarget(Cardinal(Params.Pid), BuildRequest(1, 'execute_action', Args));
end;


initialization
  TMCPRegistry.RegisterTool('execute_action',
    function: IMCPTool
    begin
      Result := TExecuteActionTool.Create;
    end
  );


end.
