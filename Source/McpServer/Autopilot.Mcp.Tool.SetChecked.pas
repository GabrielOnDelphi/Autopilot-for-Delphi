unit Autopilot.Mcp.Tool.SetChecked;

{=============================================================================================================
   2026.06
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - MCP tool: set_checked
   - Toggles a control's Checked property (TCheckBox, TRadioButton, anything with a published Checked).
   - Refuses if the control is disabled.
   - Runs in Autopilot.Mcp.exe (Windows PC-side MCP server); target may be any platform.
=============================================================================================================}

interface

uses
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Mcp.ToolBase;

type
  TSetCheckedParams = class
  private
    FPath   : String;
    FChecked: Boolean;
    FPid    : Integer;
  public
    [SchemaDescription('Path to the control. See list_tree for available paths. ' +
                       'Forms: "Form", "Form.Leaf", "Form.A.B.C". Unnamed components: "@TButton#N".')]
    property Path: String read FPath write FPath;

    [SchemaDescription('TRUE to check, FALSE to uncheck.')]
    property Checked: Boolean read FChecked write FChecked;

    [Optional]
    [SchemaDescription('Optional PID to disambiguate when multiple targets are active.')]
    property Pid: Integer read FPid write FPid;
  end;

  TSetCheckedTool = class(TMCPToolBase<TSetCheckedParams>)
  protected
    function ExecuteWithParams(const Params: TSetCheckedParams): String; override;
  public
    constructor Create; override;
  end;


implementation

uses
  MCPServer.Registration;


constructor TSetCheckedTool.Create;
begin
  inherited;
  FName := 'set_checked';
  FDescription := 'Set the Checked property of a TCheckBox / TRadioButton / similar.';
end;


function TSetCheckedTool.ExecuteWithParams(const Params: TSetCheckedParams): String;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('path', Params.Path);
  Args.AddPair('checked', TJSONBool.Create(Params.Checked));
  Result := RunCommandOnTarget(Cardinal(Params.Pid), BuildRequest(1, 'set_checked', Args));
end;


initialization
  TMCPRegistry.RegisterTool('set_checked',
    function: IMCPTool
    begin
      Result := TSetCheckedTool.Create;
    end
  );


end.
