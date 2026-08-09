UNIT Autopilot.Mcp.Tool.ReadProperty;

(*=====================================================
   2026.05.20
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────────────┐
   │  WINDOWS  (PC-side MCP server)       │   runs in Autopilot.Mcp.exe; target may be any platform
   └──────────────────────────────────────┘

   MCP tool: read_property
   Reads any readable published property of a control via RTTI. Companion to
   set_property — the format of the returned 'value' string is exactly what
   set_property would accept back. Use this when you want live state of a
   property whose name you already know (saves a deliberate-typo round-trip
   through set_property + availableProperties).

   Return shape on success:
     { path, propName, value, kind }
   where 'value' is the type-aware string form (TColor → 'clName' / '#RRGGBB',
   TAlphaColor → 'claName' / '#AARRGGBB', enum → identifier, set → '[a,b]',
   bool → 'true'/'false', integer/int64 → decimal, float → invariant locale).

   On unknown propName: -32006 rtti_property_missing carrying
   error.data.availableProperties (a JSON array of {name, kind, currentValue?})
   enumerating the READABLE published surface of the target. The list is a
   superset of set_property's availableProperties (which gates on IsWritable),
   so write-only-then-removed properties on legacy components still show up.

   On disabled targets: read_property does NOT enforce Enabled. Reading state
   off a disabled control is a common debugging need (e.g. "why is btnSave
   greyed out? what's its Action.Enabled?").

   On class-typed leaf names (Font, Brush, Lines, Fill): returned as
   unsupported_action with a hint to use a dotted propName ('Font.Size',
   'Lines.Text') to drill into the leaf. tkClass entries in availableProperties
   carry kind:'class' as the cue.
=====================================================*)

INTERFACE

USES
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Mcp.ToolBase;

TYPE
  TReadPropertyParams = CLASS
  PRIVATE
    FPath    : String;
    FPropName: String;
    FPid     : Integer;
  PUBLIC
    [SchemaDescription('Path to the control. See list_tree for available paths. ' +
                       'Forms: "Form", "Form.Leaf", "Form.A.B.C". Unnamed components: "@TButton#N".')]
    PROPERTY Path: String READ FPath WRITE FPath;

    [SchemaDescription('Published property name (case-sensitive Delphi identifier, e.g. "Tag", ' +
                       '"Caption", "Color", "Position", "ItemIndex"). Accepts one level of ' +
                       'nesting via "Outer.Inner" when Outer is a class-typed property — e.g. ' +
                       '"Font.Size", "Font.Color", "Lines.Text". If the name is unknown the ' +
                       'response includes error.data.availableProperties — each entry has name, ' +
                       'kind, and (when readable) currentValue. tkClass entries are returned ' +
                       'with kind="class" as candidates for dotted-name reads.')]
    PROPERTY PropName: String READ FPropName WRITE FPropName;

    [Optional]
    [SchemaDescription('Optional PID to disambiguate when multiple targets are active.')]
    PROPERTY Pid: Integer READ FPid WRITE FPid;
  END;

  TReadPropertyTool = CLASS(TMCPToolBase<TReadPropertyParams>)
  PROTECTED
    FUNCTION ExecuteWithParams(CONST Params: TReadPropertyParams): String; OVERRIDE;
  PUBLIC
    CONSTRUCTOR Create; OVERRIDE;
  END;


IMPLEMENTATION

USES
  MCPServer.Registration;


CONSTRUCTOR TReadPropertyTool.Create;
BEGIN
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
END;


FUNCTION TReadPropertyTool.ExecuteWithParams(CONST Params: TReadPropertyParams): String;
VAR
  Args: TJSONObject;
BEGIN
  Args := TJSONObject.Create;
  Args.AddPair('path',     Params.Path);
  Args.AddPair('propName', Params.PropName);
  Result := RunCommandOnTarget(Cardinal(Params.Pid), BuildRequest(1, 'read_property', Args));
END;


INITIALIZATION
  TMCPRegistry.RegisterTool('read_property',
    FUNCTION: IMCPTool
    BEGIN
      Result := TReadPropertyTool.Create;
    END
  );


END.
