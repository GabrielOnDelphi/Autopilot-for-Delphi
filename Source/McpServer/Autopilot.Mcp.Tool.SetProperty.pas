UNIT Autopilot.Mcp.Tool.SetProperty;

(*=====================================================
   2026.05.16
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────────────┐
   │  WINDOWS  (PC-side MCP server)       │   runs in Autopilot.Mcp.exe; target may be any platform
   └──────────────────────────────────────┘

   MCP tool: set_property
   Writes any published, writable property of a control via RTTI. Supersedes the
   special-case set_text and set_checked tools — those remain for the common path
   but set_property covers everything else (Tag, Color, Position, BorderStyle,
   AlphaBlendValue, ItemIndex, etc.).

   Value is passed as a string and coerced by the bridge against the property's
   declared TypeKind (Plans/04 R2). Supported kinds: string, integer, int64,
   boolean, other enum, set-of-enum, float, alphacolor, color. Anything else
   returns unsupported_action.

   TAlphaColor (FMX) accepts '#RRGGBB' (alpha assumed FF), '#AARRGGBB', a cla*
   identifier ('claSkyBlue'), a bare name ('SkyBlue'), decimal, or '$hex'.
   availableProperties returns kind:'alphacolor' for those entries; currentValue
   is rendered as 'claName' (when named) or '#AARRGGBB'.

   TColor (VCL) accepts a cl* identifier ('clRed', 'clBtnFace'), '#RRGGBB' (web
   RGB — bytes go into the low 3 bytes of TColor, which is BGR-stored, so the
   visual result matches the AI's intent), '$00BBGGRR' (Pascal-style hex), or a
   decimal value. availableProperties returns kind:'color' for those entries;
   currentValue is rendered as 'clName' (when ColorToIdent matches) or '#RRGGBB'.

   Dotted propName: 'Outer.Inner' addresses a nested simple property when Outer
   is a tkClass property (e.g. 'Font.Size', 'Lines.Text'). One level of nesting
   only. The bridge resolves the outer to its instance, then writes the inner
   on that instance using the same coercion rules.

   On 'property missing' the bridge attaches error.data.availableProperties (a JSON
   array of {name, kind, currentValue}) so the AI can self-correct on the next call
   without another list_tree round-trip. currentValue is omitted when the getter
   is unreadable or throws. Dotted propName surfaces tkClass entries with
   kind='class' (no currentValue) — those are the candidates for 'X.Inner' writes.

   Write-side elision: on success, the result carries 'elided: true' iff the live
   property value already equalled the coerced new value, so the bridge skipped
   the setter (OnChange did NOT fire). Lets the AI distinguish "I caused a state
   change" from "value was already what I wanted". Read-only-via-getter properties
   (writable but throwing getters, rare) fall through to a real write and report
   elided=false. Comparison is type-aware: string identity, integer/int64 equality
   (TAlphaColor/TColor as 32-bit equality), boolean equality, enum/set ordinal
   equality, float exact-bits equality (no epsilon — Double/Extended round-trip
   cleanly; Single-typed properties may not elide non-Single-exact decimals like
   0.1, but the write goes through harmlessly).
=====================================================*)

INTERFACE

USES
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Mcp.ToolBase;

TYPE
  TSetPropertyParams = CLASS
  PRIVATE
    FPath    : String;
    FPropName: String;
    FValue   : String;
    FPid     : Integer;
  PUBLIC
    [SchemaDescription('Path to the control. See list_tree for available paths. ' +
                       'Forms: "Form", "Form.Leaf", "Form.A.B.C". Unnamed components: "@TButton#N".')]
    PROPERTY Path: String READ FPath WRITE FPath;

    [SchemaDescription('Published property name (case-sensitive Delphi identifier, e.g. "Tag", ' +
                       '"Caption", "Color", "Position", "ItemIndex"). Accepts one level of ' +
                       'nesting via "Outer.Inner" when Outer is a class-typed property — e.g. ' +
                       '"Font.Size", "Font.Color", "Lines.Text". The bridge enumerates writable ' +
                       'properties on the target; if the name is unknown the response includes ' +
                       'error.data.availableProperties — each entry has name, kind, and (when ' +
                       'readable) currentValue. tkClass entries are returned with kind="class" ' +
                       'as candidates for dotted-name writes.')]
    PROPERTY PropName: String READ FPropName WRITE FPropName;

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
    PROPERTY Value: String READ FValue WRITE FValue;

    [Optional]
    [SchemaDescription('Optional PID to disambiguate when multiple targets are active.')]
    PROPERTY Pid: Integer READ FPid WRITE FPid;
  END;

  TSetPropertyTool = CLASS(TMCPToolBase<TSetPropertyParams>)
  PROTECTED
    FUNCTION ExecuteWithParams(CONST Params: TSetPropertyParams): String; OVERRIDE;
  PUBLIC
    CONSTRUCTOR Create; OVERRIDE;
  END;


IMPLEMENTATION

USES
  MCPServer.Registration;


CONSTRUCTOR TSetPropertyTool.Create;
BEGIN
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
END;


FUNCTION TSetPropertyTool.ExecuteWithParams(CONST Params: TSetPropertyParams): String;
VAR
  Args: TJSONObject;
BEGIN
  Args := TJSONObject.Create;
  Args.AddPair('path',     Params.Path);
  Args.AddPair('propName', Params.PropName);
  Args.AddPair('value',    Params.Value);
  Result := RunCommandOnTarget(Cardinal(Params.Pid), BuildRequest(1, 'set_property', Args));
END;


INITIALIZATION
  TMCPRegistry.RegisterTool('set_property',
    FUNCTION: IMCPTool
    BEGIN
      Result := TSetPropertyTool.Create;
    END
  );


END.
