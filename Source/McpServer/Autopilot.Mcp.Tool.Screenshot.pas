unit Autopilot.Mcp.Tool.Screenshot;

{=============================================================================================================
   2026.09
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - MCP tool: screenshot
   - Captures a form as a base64-encoded PNG. Form name optional; defaults to the target's main form.
   - Returns the PNG inline in the response so Claude Code can display it as an image attachment.
   - Runs in Autopilot.Mcp.exe (Windows PC-side MCP server); target may be any platform.
=============================================================================================================}

interface

uses
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Bridge.Core,
  Autopilot.Mcp.ToolBase;

type
  TScreenshotParams = class
  private
    FForm: String;
    FPid : Integer;
  public
    [Optional]
    [SchemaDescription('Name of the form to capture. Empty/omitted = main form.')]
    property Form: String read FForm write FForm;

    [Optional]
    [SchemaDescription('Optional PID to disambiguate when multiple targets are active.')]
    property Pid: Integer read FPid write FPid;
  end;

  TScreenshotTool = class(TMCPToolBase<TScreenshotParams>)
  protected
    function ExecuteWithParams(const Params: TScreenshotParams): String; override;
  public
    constructor Create; override;
  end;


implementation

uses
  MCPServer.Registration;


constructor TScreenshotTool.Create;
begin
  inherited;
  FName := 'screenshot';
  FDescription := 'Capture a form as a base64-encoded PNG.';
end;


function TScreenshotTool.ExecuteWithParams(const Params: TScreenshotParams): String;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('form', Params.Form);
  // Per-command default of 30 s lives on the bridge side (DefaultTimeoutScreenshotMs).
  Result := RunCommandOnTarget(Cardinal(Params.Pid),
                               BuildRequest(1, 'screenshot', Args),
                               DefaultTimeoutScreenshotMs);
end;


initialization
  TMCPRegistry.RegisterTool('screenshot',
    function: IMCPTool
    begin
      Result := TScreenshotTool.Create;
    end
  );


end.
