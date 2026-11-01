unit Autopilot.Mcp.Tool.SetKeepAwake;

{=============================================================================================================
   2026.09
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - MCP tool: set_keep_awake
   - Keeps the target device screen on while it is being driven.
     On Android the bridge sets the FLAG_KEEP_SCREEN_ON window flag, preventing the OS screen-off app freeze that stalls socket accept.
   - No-op on Windows targets (a Windows app is never OS-frozen while an automation client drives it).
   - The FMX bridge enables this by default on Android at StartBridge; this tool allows runtime toggling.
   - Runs in Autopilot.Mcp.exe (Windows PC-side MCP server); target may be any platform.
=============================================================================================================}

interface

uses
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Mcp.ToolBase;

type
  TSetKeepAwakeParams = class
  private
    FEnabled: Boolean;
    FPid    : Integer;
  public
    [SchemaDescription('TRUE keeps the screen on, FALSE releases it. On by default on Android.')]
    property Enabled: Boolean read FEnabled write FEnabled;

    [Optional]
    [SchemaDescription('Target PID. Needed only when several targets run.')]
    property Pid: Integer read FPid write FPid;
  end;

  TSetKeepAwakeTool = class(TMCPToolBase<TSetKeepAwakeParams>)
  protected
    function ExecuteWithParams(const Params: TSetKeepAwakeParams): String; override;
  public
    constructor Create; override;
  end;


implementation

uses
  MCPServer.Registration;


constructor TSetKeepAwakeTool.Create;
begin
  inherited;
  FName := 'set_keep_awake';
  FDescription := 'Keep the Android screen on, so the OS does not freeze the app. No-op on Windows.';
end;


function TSetKeepAwakeTool.ExecuteWithParams(const Params: TSetKeepAwakeParams): String;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('enabled', TJSONBool.Create(Params.Enabled));
  Result := RunCommandOnTarget(Cardinal(Params.Pid), BuildRequest(1, 'set_keep_awake', Args));
end;


initialization
  TMCPRegistry.RegisterTool('set_keep_awake',
    function: IMCPTool
    begin
      Result := TSetKeepAwakeTool.Create;
    end
  );


end.
