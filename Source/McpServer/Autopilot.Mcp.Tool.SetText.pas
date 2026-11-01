unit Autopilot.Mcp.Tool.SetText;

{=============================================================================================================
   2026.09
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
    [SchemaDescription('Control path from list_tree: "Form", "Form.Leaf", "Form.A.B.C" or "@TButton#N".')]
    property Path: String read FPath write FPath;

    [SchemaDescription('New value for Text (preferred) or Caption.')]
    property Text: String read FText write FText;

    [Optional]
    [SchemaDescription('Target PID. Needed only when several targets run.')]
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
  FDescription := 'Set the Text (preferred) or Caption of a control. ' + 'A VCL data-aware control (TDBEdit, TDBMemo) is edited like a typing user: ' + 'the value reaches the field buffer and the result carries dataBound=true; ' + 'a read-only control, field or dataset fails with -32005.';
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
