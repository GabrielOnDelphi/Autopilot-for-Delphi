UNIT Autopilot.Mcp.Tool.DismissDialog;

(*=====================================================
   2026.06.24
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────────────┐
   │  WINDOWS  (PC-side MCP server)       │   runs in Autopilot.Mcp.exe; target may be any platform
   └──────────────────────────────────────┘

   MCP tool: dismiss_dialog
   Lists and dismisses native OS dialogs (MessageBox, Vista Task Dialog, common file
   dialogs) raised by the target. These are raw Win32 windows with no TComponent, so the
   path-based tools (list_tree / click) cannot see them — they return not_found while the
   app's main thread is blocked in the dialog's modal loop.

   Call with no 'button' to LIST the dialogs currently up (each with its buttons); call
   with 'button' to dismiss one by clicking that button. Tip: when a click() may open a
   modal dialog, give it a short timeoutMs and expect main_thread_blocked, then call this.

   Windows targets only. Against an Android FMX target the response is supported:false.
=====================================================*)

INTERFACE

USES
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Mcp.ToolBase;

TYPE
  TDismissDialogParams = CLASS
  PRIVATE
    FButton: String;
    FHwnd  : Int64;
    FPid   : Integer;
  PUBLIC
    [Optional]
    [SchemaDescription('Button to click to dismiss the dialog: a role ("ok", "cancel", "yes", ' +
                       '"no", "retry", "abort", "ignore", "close", "tryagain", "continue"), a button ' +
                       'caption (exact then substring, case-insensitive), or a numeric control id. ' +
                       'Omit to only LIST the native dialogs currently up (with their buttons).')]
    PROPERTY Button: String READ FButton WRITE FButton;

    [Optional]
    [SchemaDescription('Target a specific dialog by its hwnd (from a prior list). Omit to act on the topmost dialog.')]
    PROPERTY Hwnd: Int64 READ FHwnd WRITE FHwnd;

    [Optional]
    [SchemaDescription('Optional PID to disambiguate when multiple targets are active.')]
    PROPERTY Pid: Integer READ FPid WRITE FPid;
  END;

  TDismissDialogTool = CLASS(TMCPToolBase<TDismissDialogParams>)
  PROTECTED
    FUNCTION ExecuteWithParams(CONST Params: TDismissDialogParams): String; OVERRIDE;
  PUBLIC
    CONSTRUCTOR Create; OVERRIDE;
  END;


IMPLEMENTATION

USES
  MCPServer.Registration;


CONSTRUCTOR TDismissDialogTool.Create;
BEGIN
  inherited;
  FName := 'dismiss_dialog';
  FDescription := 'List or dismiss native OS dialogs (MessageBox / Task Dialog / file dialogs) the component tools cannot reach. Windows targets only.';
END;


FUNCTION TDismissDialogTool.ExecuteWithParams(CONST Params: TDismissDialogParams): String;
VAR
  Args: TJSONObject;
BEGIN
  Args := TJSONObject.Create;
  if Trim(Params.Button) <> '' then
    Args.AddPair('button', Params.Button);
  if Params.Hwnd <> 0 then
    Args.AddPair('hwnd', TJSONNumber.Create(Params.Hwnd));
  Result := RunCommandOnTarget(Cardinal(Params.Pid), BuildRequest(1, 'dismiss_dialog', Args));
END;


INITIALIZATION
  TMCPRegistry.RegisterTool('dismiss_dialog',
    FUNCTION: IMCPTool
    BEGIN
      Result := TDismissDialogTool.Create;
    END
  );


END.
