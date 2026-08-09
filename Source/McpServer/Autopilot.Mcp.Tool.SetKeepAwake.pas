UNIT Autopilot.Mcp.Tool.SetKeepAwake;

(*=====================================================
   2026.06.14
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────────────┐
   │  WINDOWS  (PC-side MCP server)       │   runs in Autopilot.Mcp.exe; target may be any platform
   └──────────────────────────────────────┘

   MCP tool: set_keep_awake
   Keeps the target device screen on while it is being driven. On Android the
   bridge sets the FLAG_KEEP_SCREEN_ON window flag, so the screen never turns off
   and the OS does not freeze the (foreground) app — the screen-off freeze is what
   stalls the socket accept otherwise. No-op on Windows targets (a Windows app is
   never frozen by the OS while an automation client drives it).

   The FMX bridge enables this by DEFAULT on Android at StartBridge; this tool lets
   the AI release it (enabled=false) or re-assert it (enabled=true) at runtime.
=====================================================*)

INTERFACE

USES
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Mcp.ToolBase;

TYPE
  TSetKeepAwakeParams = CLASS
  PRIVATE
    FEnabled: Boolean;
    FPid    : Integer;
  PUBLIC
    [SchemaDescription('TRUE to keep the device screen on (Android: sets FLAG_KEEP_SCREEN_ON); ' +
                       'FALSE to release it. No-op on Windows targets. The Android bridge enables this by default.')]
    PROPERTY Enabled: Boolean READ FEnabled WRITE FEnabled;

    [Optional]
    [SchemaDescription('Optional PID to disambiguate when multiple targets are active.')]
    PROPERTY Pid: Integer READ FPid WRITE FPid;
  END;

  TSetKeepAwakeTool = CLASS(TMCPToolBase<TSetKeepAwakeParams>)
  PROTECTED
    FUNCTION ExecuteWithParams(CONST Params: TSetKeepAwakeParams): String; OVERRIDE;
  PUBLIC
    CONSTRUCTOR Create; OVERRIDE;
  END;


IMPLEMENTATION

USES
  MCPServer.Registration;


CONSTRUCTOR TSetKeepAwakeTool.Create;
BEGIN
  inherited;
  FName := 'set_keep_awake';
  FDescription := 'Keep the target device screen on while driving it (Android only; prevents the OS screen-off app freeze). No-op on Windows.';
END;


FUNCTION TSetKeepAwakeTool.ExecuteWithParams(CONST Params: TSetKeepAwakeParams): String;
VAR
  Args: TJSONObject;
BEGIN
  Args := TJSONObject.Create;
  Args.AddPair('enabled', TJSONBool.Create(Params.Enabled));
  Result := RunCommandOnTarget(Cardinal(Params.Pid), BuildRequest(1, 'set_keep_awake', Args));
END;


INITIALIZATION
  TMCPRegistry.RegisterTool('set_keep_awake',
    FUNCTION: IMCPTool
    BEGIN
      Result := TSetKeepAwakeTool.Create;
    END
  );


END.
