unit Autopilot.Mcp.Tool.DismissDialog;

{=============================================================================================================
   2026.09
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - MCP tool: dismiss_dialog
   - Lists and dismisses native OS dialogs (MessageBox, Vista Task Dialog, common file dialogs) raised by
     the target. These are raw Win32 windows with no TComponent, so the path-based tools (list_tree / click)
     cannot see them — they return not_found while the app's main thread is blocked in the dialog's modal loop.
   - Call with no 'button' to LIST the dialogs currently up; call with 'button' to dismiss one.
   - Windows targets only. Against an Android FMX target the response is supported:false.
   - Runs in Autopilot.Mcp.exe (Windows PC-side MCP server); target may be any platform.
=============================================================================================================}

interface

uses
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Mcp.ToolBase;

type
  TDismissDialogParams = class
  private
    FButton: String;
    FHwnd  : Int64;
    FPid   : Integer;
  public
    [Optional]
    [SchemaDescription('Button to click to dismiss the dialog: a role ("ok", "cancel", "yes", ' +
                       '"no", "retry", "abort", "ignore", "close", "tryagain", "continue"), a button ' +
                       'caption (exact then substring, case-insensitive), or a numeric control id. ' +
                       'Omit to only LIST the native dialogs currently up (with their buttons).')]
    property Button: String read FButton write FButton;

    [Optional]
    [SchemaDescription('Target a specific dialog by its hwnd (from a prior list). Omit to act on the topmost dialog.')]
    property Hwnd: Int64 read FHwnd write FHwnd;

    [Optional]
    [SchemaDescription('Optional PID to disambiguate when multiple targets are active.')]
    property Pid: Integer read FPid write FPid;
  end;

  TDismissDialogTool = class(TMCPToolBase<TDismissDialogParams>)
  protected
    function ExecuteWithParams(const Params: TDismissDialogParams): String; override;
  public
    constructor Create; override;
  end;


implementation

uses
  MCPServer.Registration;


constructor TDismissDialogTool.Create;
begin
  inherited;
  FName := 'dismiss_dialog';
  FDescription := 'List or dismiss native OS dialogs (MessageBox / Task Dialog / file dialogs) the component tools cannot reach. Windows targets only.';
end;


function TDismissDialogTool.ExecuteWithParams(const Params: TDismissDialogParams): String;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  if Trim(Params.Button) <> ''
  then Args.AddPair('button', Params.Button);
  if Params.Hwnd <> 0
  then Args.AddPair('hwnd', TJSONNumber.Create(Params.Hwnd));
  Result := RunCommandOnTarget(Cardinal(Params.Pid), BuildRequest(1, 'dismiss_dialog', Args));
end;


initialization
  TMCPRegistry.RegisterTool('dismiss_dialog',
    function: IMCPTool
    begin
      Result := TDismissDialogTool.Create;
    end
  );


end.
