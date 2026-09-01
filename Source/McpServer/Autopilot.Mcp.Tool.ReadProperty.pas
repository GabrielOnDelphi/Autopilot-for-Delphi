unit Autopilot.Mcp.Tool.ReadProperty;

{=============================================================================================================
   2026.09
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - MCP tool: read_property
   - Reads any readable published property of a control via RTTI. Companion to set_property — the returned
     'value' string is exactly what set_property would accept back.
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
    [SchemaDescription('Path to the control. See list_tree for available paths. ' +
                       'Forms: "Form", "Form.Leaf", "Form.A.B.C". Unnamed components: "@TButton#N".')]
    property Path: String read FPath write FPath;

    [SchemaDescription('Published property name (case-sensitive Delphi identifier, e.g. "Tag", ' +
                       '"Caption", "Color", "Position", "ItemIndex"). Accepts one level of ' +
                       'nesting via "Outer.Inner" when Outer is a class-typed property — e.g. ' +
                       '"Font.Size", "Font.Color", "Lines.Text". If the name is unknown the ' +
                       'response includes error.data.availableProperties — each entry has name, ' +
                       'kind, and (when readable) currentValue. tkClass entries are returned ' +
                       'with kind="class" as candidates for dotted-name reads.')]
    property PropName: String read FPropName write FPropName;

    [Optional]
    [SchemaDescription('Optional PID to disambiguate when multiple targets are active.')]
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
  FDescription := 'Read any readable published property of a control via RTTI. ' +
                  'Companion to set_property — the returned "value" string is exactly what ' +
                  'set_property would accept back (TColor → "clName"/"#RRGGBB", TAlphaColor → ' +
                  '"claName"/"#AARRGGBB", enum → identifier, set → "[a,b]", bool → "true"/"false"). ' +
                  'Dotted propName ("Font.Size", "Lines.Text") drills into a tkClass outer — one ' +
                  'level only. Does NOT enforce Enabled: reading a disabled control''s state is a ' +
                  'common debugging need. Returns error.data.availableProperties on unknown ' +
                  'propName, enumerating the readable surface (superset of set_property''s ' +
                  'writable list). Use this instead of writing Diag.SaveToFile scratchpad files in ' +
                  'the target — one round-trip per live value, no recompile.';
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
