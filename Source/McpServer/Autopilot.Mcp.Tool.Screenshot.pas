UNIT Autopilot.Mcp.Tool.Screenshot;

(*=====================================================
   2026.05.13
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────────────┐
   │  WINDOWS  (PC-side MCP server)       │   runs in Autopilot.Mcp.exe; target may be any platform
   └──────────────────────────────────────┘

   MCP tool: screenshot
   Captures a form as a base64-encoded PNG. Form name optional; defaults to the
   target's main form. Returns the PNG inline in the response so Claude Code can
   display it as an image attachment.
=====================================================*)

INTERFACE

USES
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Bridge.Core,
  Autopilot.Mcp.ToolBase;

TYPE
  TScreenshotParams = CLASS
  PRIVATE
    FForm: String;
    FPid : Integer;
  PUBLIC
    [Optional]
    [SchemaDescription('Name of the form to capture. Empty/omitted = main form.')]
    PROPERTY Form: String READ FForm WRITE FForm;

    [Optional]
    [SchemaDescription('Optional PID to disambiguate when multiple targets are active.')]
    PROPERTY Pid: Integer READ FPid WRITE FPid;
  END;

  TScreenshotTool = CLASS(TMCPToolBase<TScreenshotParams>)
  PROTECTED
    FUNCTION ExecuteWithParams(CONST Params: TScreenshotParams): String; OVERRIDE;
  PUBLIC
    CONSTRUCTOR Create; OVERRIDE;
  END;


IMPLEMENTATION

USES
  MCPServer.Registration;


CONSTRUCTOR TScreenshotTool.Create;
BEGIN
  inherited;
  FName := 'screenshot';
  FDescription := 'Capture a form as a base64-encoded PNG.';
END;


FUNCTION TScreenshotTool.ExecuteWithParams(CONST Params: TScreenshotParams): String;
VAR
  Args: TJSONObject;
BEGIN
  Args := TJSONObject.Create;
  Args.AddPair('form', Params.Form);
  // Per-command default of 30 s lives on the bridge side (DefaultTimeoutScreenshotMs).
  Result := RunCommandOnTarget(Cardinal(Params.Pid),
                               BuildRequest(1, 'screenshot', Args),
                               DefaultTimeoutScreenshotMs);
END;


INITIALIZATION
  TMCPRegistry.RegisterTool('screenshot',
    FUNCTION: IMCPTool
    BEGIN
      Result := TScreenshotTool.Create;
    END
  );


END.
