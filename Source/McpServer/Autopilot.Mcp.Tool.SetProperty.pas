unit Autopilot.Mcp.Tool.SetProperty;

{=============================================================================================================
   2026.09
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - MCP tool: set_property
   - Writes any published, writable property of a control via RTTI. Supersedes set_text and set_checked for
     everything else (Tag, Color, Position, BorderStyle, AlphaBlendValue, ItemIndex, etc.).
   - Value is passed as a string and coerced by the bridge against the property's declared TypeKind.
   - Supports: string, integer, int64, boolean, enum, set-of-enum, float, TAlphaColor, TColor.
   - Dotted propName ('Font.Size', 'Lines.Text') addresses a nested simple property one level deep.
   - On success, result carries elided:true iff the live value already equalled the new value.
   - Runs in Autopilot.Mcp.exe (Windows PC-side MCP server); target may be any platform.
=============================================================================================================}

interface

uses
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Mcp.ToolBase;

type
  TSetPropertyParams = class
  private
    FPath    : String;
    FPropName: String;
    FValue   : String;
    FPid     : Integer;
  public
    [SchemaDescription('Control path from list_tree: "Form", "Form.Leaf", "Form.A.B.C" or "@TButton#N".')]
    property Path: String read FPath write FPath;

    [SchemaDescription('Published property name, case-sensitive ("Tag", "Caption", "ItemIndex"). One ' +
                       'nesting level via "Outer.Inner" when Outer is a class property ("Font.Size", ' +
                       '"Lines.Text"). Unknown name -> error.data.availableProperties: name, kind, ' +
                       'currentValue; kind="class" entries can be the Outer.')]
    property PropName: String read FPropName write FPropName;

    [SchemaDescription('Value as a string, converted to the property''s RTTI type. Boolean: ' +
                       '"true"/"false"/"1"/"0". Enum: identifier ("poDesigned") or ordinal. Set: "[a,b]", ' +
                       '"a,b", "[]" or ordinal. Float: period as decimal separator. TAlphaColor (FMX): ' +
                       '"#RRGGBB" (alpha FF), "#AARRGGBB", "claSkyBlue", "SkyBlue", decimal or "$hex". ' +
                       'TColor (VCL): "clRed", "#RRGGBB", "$00BBGGRR" or decimal.')]
    property Value: String read FValue write FValue;

    [Optional]
    [SchemaDescription('Target PID. Needed only when several targets run.')]
    property Pid: Integer read FPid write FPid;
  end;

  TSetPropertyTool = class(TMCPToolBase<TSetPropertyParams>)
  protected
    function ExecuteWithParams(const Params: TSetPropertyParams): String; override;
  public
    constructor Create; override;
  end;


implementation

uses
  MCPServer.Registration;


constructor TSetPropertyTool.Create;
begin
  inherited;
  FName := 'set_property';
  FDescription := 'Set a writable published property of a control via RTTI, for anything set_text / ' +
                  'set_checked do not cover (Tag, Color, Left, ItemIndex, Visible...). ' +
                  'Result elided:true = the value was already equal, so the setter was skipped ' +
                  'and OnChange did not fire.';
end;


function TSetPropertyTool.ExecuteWithParams(const Params: TSetPropertyParams): String;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('path',     Params.Path);
  Args.AddPair('propName', Params.PropName);
  Args.AddPair('value',    Params.Value);
  Result := RunCommandOnTarget(Cardinal(Params.Pid), BuildRequest(1, 'set_property', Args));
end;


initialization
  TMCPRegistry.RegisterTool('set_property',
    function: IMCPTool
    begin
      Result := TSetPropertyTool.Create;
    end
  );


end.
