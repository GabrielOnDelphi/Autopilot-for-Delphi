unit Autopilot.Mcp.Tool.SetProperty;

{=============================================================================================================
   2026.06
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
    [SchemaDescription('Path to the control. See list_tree for available paths. ' +
                       'Forms: "Form", "Form.Leaf", "Form.A.B.C". Unnamed components: "@TButton#N".')]
    property Path: String read FPath write FPath;

    [SchemaDescription('Published property name (case-sensitive Delphi identifier, e.g. "Tag", ' +
                       '"Caption", "Color", "Position", "ItemIndex"). Accepts one level of ' +
                       'nesting via "Outer.Inner" when Outer is a class-typed property — e.g. ' +
                       '"Font.Size", "Font.Color", "Lines.Text". The bridge enumerates writable ' +
                       'properties on the target; if the name is unknown the response includes ' +
                       'error.data.availableProperties — each entry has name, kind, and (when ' +
                       'readable) currentValue. tkClass entries are returned with kind="class" ' +
                       'as candidates for dotted-name writes.')]
    property PropName: String read FPropName write FPropName;

    [SchemaDescription('Value as a string. The bridge coerces it against the property''s declared ' +
                       'RTTI type: string/integer/int64/boolean/enum/set/float/alphacolor/color. Booleans accept ' +
                       '"true"/"false"/"1"/"0". Enums accept either the identifier (e.g. ' +
                       '"poDesigned") or its ordinal. Sets accept a bracket literal like ' +
                       '"[biSystemMenu,biMinimize]", a bare comma list "biSystemMenu,biMinimize", ' +
                       'the empty set "[]", or a numeric ordinal. Floats use period as the decimal separator. ' +
                       'TAlphaColor (FMX colors) accepts "#RRGGBB" (alpha assumed FF), "#AARRGGBB", ' +
                       '"claSkyBlue" (any cla* identifier), bare names like "SkyBlue", decimal, or "$hex". ' +
                       'TColor (VCL colors) accepts "clRed" (any cl* identifier), "#RRGGBB" (web RGB), ' +
                       '"$00BBGGRR" (Pascal hex), or a decimal value.')]
    property Value: String read FValue write FValue;

    [Optional]
    [SchemaDescription('Optional PID to disambiguate when multiple targets are active.')]
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
  FDescription := 'Set any writable published property of a control via RTTI. ' +
                  'Use for everything not covered by set_text / set_checked (e.g. Tag, Color, ' +
                  'Left, ItemIndex, Visible, BorderStyle, BevelEdges). Supported type kinds: ' +
                  'string, integer, int64, boolean, enum, set-of-enum, float, alphacolor, color. ' +
                  'TAlphaColor (FMX) accepts "#RRGGBB" (alpha assumed FF), "#AARRGGBB", or any ' +
                  '"claName" / bare name. Readback renders as "claName" or "#AARRGGBB". ' +
                  'TColor (VCL) accepts "clRed" / any cl* identifier, "#RRGGBB" (web RGB), ' +
                  '"$00BBGGRR" Pascal hex, or a decimal. Readback renders as "clName" or "#RRGGBB". ' +
                  'Dotted propName ("Font.Size", "Lines.Text") writes through a tkClass outer to ' +
                  'a simple inner — one level only. ' +
                  'Returns error.data.availableProperties on unknown property names — each entry ' +
                  'has name, kind, and (when readable) currentValue, letting one round-trip ' +
                  'discover both the writable surface and the live state. ' +
                  'On success the result carries elided:true iff the live value already equalled ' +
                  'the new value (setter skipped, OnChange did NOT fire); elided:false means the ' +
                  'write actually happened. Useful for detecting "no-op resends" without a follow-up read.';
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
