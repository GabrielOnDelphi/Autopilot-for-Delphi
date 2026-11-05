unit Autopilot.Mcp.Tool.ReadProperty;

{=============================================================================================================
   2026.09
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - MCP tool: read_property
   - Reads any readable published property of a control via RTTI.
     Companion to set_property — the returned 'value' string is exactly what set_property would accept back.
   - On unknown propName: -32006 rtti_property_missing carrying error.data.availableProperties.
   - Does NOT enforce Enabled: reading a disabled control's state is a common debugging need.
   - Runs in Autopilot.Mcp.exe (Windows PC-side MCP server); target may be any platform.
=============================================================================================================}

interface

uses
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Mcp.ToolBase;

type
  TReadPropertyParams = class
  private
    FPath    : String;
    FPropName: String;
    FPid     : Integer;
  public
    [SchemaDescription('Control path from list_tree: "Form", "Form.Leaf", "Form.A.B.C" or "@TButton#N".')]
    property Path: String read FPath write FPath;

    [SchemaDescription('Published property name, case-sensitive ("Tag", "Caption", "ItemIndex"). One ' + 'nesting level via "Outer.Inner" when Outer is a class property ("Font.Size", ' + '"Lines.Text"). Unknown name -> error.data.availableProperties: name, kind, ' + 'currentValue; kind="class" entries can be the Outer.')]
    property PropName: String read FPropName write FPropName;

    [Optional]
    [SchemaDescription('Target PID. Needed only when several targets run.')]
    property Pid: Integer read FPid write FPid;
  end;

  TReadPropertyTool = class(TMCPToolBase<TReadPropertyParams>)
  protected
    function ExecuteWithParams(const Params: TReadPropertyParams): String; override;
  public
    constructor Create; override;
  end;


implementation

uses
  MCPServer.Registration;


constructor TReadPropertyTool.Create;
begin
  inherited;
  FName := 'read_property';
  FDescription := 'Read a published property of a control via RTTI. The returned "value" is in the ' + 'format set_property accepts (TColor "clName"/"#RRGGBB", TAlphaColor ' + '"claName"/"#AARRGGBB", enum identifier, set "[a,b]", bool "true"/"false"). ' + 'Works on disabled controls. Use it to read live values instead of adding ' + 'debug output to the target. An event ("OnClick", "OnExecute") gives kind ' + '"event", value "TClass.Method" and "unit": the handler in the source.';
end;


function TReadPropertyTool.ExecuteWithParams(const Params: TReadPropertyParams): String;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('path',     Params.Path);
  Args.AddPair('propName', Params.PropName);
  Result := RunCommandOnTarget(Cardinal(Params.Pid), BuildRequest(1, 'read_property', Args));
end;


initialization
  TMCPRegistry.RegisterTool('read_property',
    function: IMCPTool
    begin
      Result := TReadPropertyTool.Create;
    end
  );


end.
