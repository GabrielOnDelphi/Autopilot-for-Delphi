UNIT Autopilot.Mcp.Tool.ExecuteAction;

(*=====================================================
   2026.05.30
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────────────┐
   │  WINDOWS  (PC-side MCP server)       │   runs in Autopilot.Mcp.exe; target may be any platform
   └──────────────────────────────────────┘

   MCP tool: execute_action
   Fires TBasicAction.Execute by path. Use this when the command is bound to
   a TAction whose OnExecute (not a control's OnClick) carries the logic —
   shortcut-only actions like actFileExit (no menu item or toolbar button)
   are otherwise untriggerable through the bridge, and actions shared by
   several controls (toolbar + menu + shortcut) get a single direct fire
   instead of clicking one of the wired controls.

   For plain controls (TButton, TCheckBox, etc.) use 'click' — it walks the
   OnClick wiring including action-via-control. execute_action rejects
   non-actions with -32005 unsupported_action.

   Inherits the click timeout budget (DefaultTimeoutClickMs, 5000 ms) because
   OnExecute is user code of unknown cost.
=====================================================*)

INTERFACE

USES
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Mcp.ToolBase;

TYPE
  TExecuteActionParams = CLASS
  PRIVATE
    FPath: String;
    FPid : Integer;
  PUBLIC
    [SchemaDescription('Path to a TAction (or any TBasicAction descendant). See list_tree — actions ' +
                       'show up with class:"TAction", e.g. "MainForm.actFileExit". For plain controls ' +
                       'use click instead.')]
    PROPERTY Path: String READ FPath WRITE FPath;

    [Optional]
    [SchemaDescription('Optional PID to disambiguate when multiple targets are active.')]
    PROPERTY Pid: Integer READ FPid WRITE FPid;
  END;

  TExecuteActionTool = CLASS(TMCPToolBase<TExecuteActionParams>)
  PROTECTED
    FUNCTION ExecuteWithParams(CONST Params: TExecuteActionParams): String; OVERRIDE;
  PUBLIC
    CONSTRUCTOR Create; OVERRIDE;
  END;


IMPLEMENTATION

USES
  MCPServer.Registration;


CONSTRUCTOR TExecuteActionTool.Create;
BEGIN
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
END;


FUNCTION TExecuteActionTool.ExecuteWithParams(CONST Params: TExecuteActionParams): String;
VAR
  Args: TJSONObject;
BEGIN
  Args := TJSONObject.Create;
  Args.AddPair('path', Params.Path);
  Result := RunCommandOnTarget(Cardinal(Params.Pid), BuildRequest(1, 'execute_action', Args));
END;


INITIALIZATION
  TMCPRegistry.RegisterTool('execute_action',
    FUNCTION: IMCPTool
    BEGIN
      Result := TExecuteActionTool.Create;
    END
  );


END.
