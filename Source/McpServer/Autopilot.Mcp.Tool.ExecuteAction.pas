unit Autopilot.Mcp.Tool.ExecuteAction;

{=============================================================================================================
   2026.06
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
    [SchemaDescription('Path to a TAction (or any TBasicAction descendant). See list_tree — actions ' +
                       'show up with class:"TAction", e.g. "MainForm.actFileExit". For plain controls ' +
                       'use click instead.')]
    property Path: String read FPath write FPath;

    [Optional]
    [SchemaDescription('Optional PID to disambiguate when multiple targets are active.')]
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
  FDescription := 'Fire a TAction''s OnExecute by path (the action behind a button/menu/shortcut). ' +
                  'Use this for shortcut-only actions that no control clicks, or to fire a command ' +
                  'shared by several controls with one round-trip. For plain controls use click. ' +
                  'Honors Enabled (refuses disabled actions with -32003) — base TBasicAction.Execute ' +
                  'would fire OnExecute regardless, which would give a misleading "it worked" on a ' +
                  'logically-disabled command. Returns {path, dispatchedVia:"Execute", executed:bool}; ' +
                  'executed=false means the action had no OnExecute handler (a real, reportable ' +
                  'state, not an error). Rejects non-actions with -32005.';
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
