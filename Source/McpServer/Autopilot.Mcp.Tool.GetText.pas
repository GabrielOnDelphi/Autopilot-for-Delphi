unit Autopilot.Mcp.Tool.GetText;

{=============================================================================================================
   2026.09
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - MCP tool: get_text
   - Reads the Text or Caption of a control in the target app.
   - Runs in Autopilot.Mcp.exe (Windows PC-side MCP server); target may be any platform.
=============================================================================================================}

interface

uses
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Mcp.ToolBase;

type
  TGetTextParams = class
  private
    FPath: String;
    FPid : Integer;
  public
    [SchemaDescription('Path to the control. See list_tree for available paths. ' +
                       'Forms: "Form", "Form.Leaf", "Form.A.B.C". Unnamed components: "@TButton#N".')]
    property Path: String read FPath write FPath;

    [Optional]
    [SchemaDescription('Optional PID to disambiguate when multiple targets are active.')]
    property Pid: Integer read FPid write FPid;
  end;

  TGetTextTool = class(TMCPToolBase<TGetTextParams>)
  protected
    function ExecuteWithParams(const Params: TGetTextParams): String; override;
  public
    constructor Create; override;
  end;


implementation

uses
  MCPServer.Registration;


constructor TGetTextTool.Create;
begin
  inherited;
  FName := 'get_text';
  FDescription := 'Read the Text/Caption of a control in the running target app.';
end;


function TGetTextTool.ExecuteWithParams(const Params: TGetTextParams): String;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('path', Params.Path);
  Result := RunCommandOnTarget(Cardinal(Params.Pid),
                               BuildRequest(1, 'get_text', Args));
end;


initialization
  TMCPRegistry.RegisterTool('get_text',
    function: IMCPTool
    begin
      Result := TGetTextTool.Create;
    end
  );


end.
