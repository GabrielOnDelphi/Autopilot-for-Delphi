unit Autopilot.Mcp.Tool.SetText;

{=============================================================================================================
   2026.06
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - MCP tool: set_text
   - Writes a control's Text (preferred) or Caption property by path.
   - Refuses if the control is disabled, or if the property exists but is read-only.
   - Runs in Autopilot.Mcp.exe (Windows PC-side MCP server); target may be any platform.
=============================================================================================================}

interface

uses
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Mcp.ToolBase;

type
  TSetTextParams = class
  private
    FPath: String;
    FText: String;
    FPid : Integer;
  public
    [SchemaDescription('Path to the control. See list_tree for available paths. ' +
                       'Forms: "Form", "Form.Leaf", "Form.A.B.C". Unnamed components: "@TButton#N".')]
    property Path: String read FPath write FPath;

    [SchemaDescription('Value to write to the control''s Text (preferred) or Caption.')]
    property Text: String read FText write FText;

    [Optional]
    [SchemaDescription('Optional PID to disambiguate when multiple targets are active.')]
    property Pid: Integer read FPid write FPid;
  end;

  TSetTextTool = class(TMCPToolBase<TSetTextParams>)
  protected
    function ExecuteWithParams(const Params: TSetTextParams): String; override;
  public
    constructor Create; override;
  end;


implementation

uses
  MCPServer.Registration;


constructor TSetTextTool.Create;
begin
  inherited;
  FName := 'set_text';
  FDescription := 'Set the Text (preferred) or Caption of a control on a running target form.';
end;


function TSetTextTool.ExecuteWithParams(const Params: TSetTextParams): String;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('path', Params.Path);
  Args.AddPair('text', Params.Text);
  Result := RunCommandOnTarget(Cardinal(Params.Pid), BuildRequest(1, 'set_text', Args));
end;


initialization
  TMCPRegistry.RegisterTool('set_text',
    function: IMCPTool
    begin
      Result := TSetTextTool.Create;
    end
  );


end.
