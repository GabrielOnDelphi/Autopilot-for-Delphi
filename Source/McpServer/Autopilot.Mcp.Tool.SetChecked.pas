unit Autopilot.Mcp.Tool.SetChecked;

{=============================================================================================================
   2026.09
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
    FIndex  : Integer;
    FPid    : Integer;
  public
    { The serializer leaves an absent optional Integer at the value it had after construction, and 0 is a valid index. }
    procedure AfterConstruction; override;

    [SchemaDescription('Control path from list_tree: "Form", "Form.Leaf", "Form.A.B.C" or "@TButton#N".')]
    property Path: String read FPath write FPath;

    [SchemaDescription('TRUE to check, FALSE to uncheck.')]
    property Checked: Boolean read FChecked write FChecked;

    [Optional]
    [SchemaDescription('VCL TCheckListBox only: the 0-based item to check or uncheck (the order of Items.Text). Omit for any other control.')]
    property Index: Integer read FIndex write FIndex;

    [Optional]
    [SchemaDescription('Target PID. Needed only when several targets run.')]
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


const
  IndexAbsent = Low(Integer);   // no index given: the request carries no "index", byte-identical to before


procedure TSetCheckedParams.AfterConstruction;
begin
  inherited;
  FIndex := IndexAbsent;
end;


constructor TSetCheckedTool.Create;
begin
  inherited;
  FName := 'set_checked';
  FDescription := 'Set the Checked property of a TCheckBox / TRadioButton / similar. ' + 'A VCL TDBCheckBox is clicked like a user, so the value reaches the field buffer ' + '(dataBound=true); a refused toggle fails with -32005. ' + 'For one item of a VCL TCheckListBox pass index; OnClickCheck fires only when the state changes.';
end;


function TSetCheckedTool.ExecuteWithParams(const Params: TSetCheckedParams): String;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('path', Params.Path);
  Args.AddPair('checked', TJSONBool.Create(Params.Checked));
  if Params.Index <> IndexAbsent
  then Args.AddPair('index', TJSONNumber.Create(Params.Index));
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
