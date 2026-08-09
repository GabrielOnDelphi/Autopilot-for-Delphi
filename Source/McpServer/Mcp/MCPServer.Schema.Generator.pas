UNIT MCPServer.Schema.Generator;

//Derivated from GDK

(*=====================================================
   2026.05.19
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────────────┐
   │  WINDOWS  (PC-side MCP server)       │   runs in Autopilot.Mcp.exe; target may be any platform
   └──────────────────────────────────────┘

   JSON Schema generator from a Delphi class via RTTI. One public class method
   builds a {type:'object', properties:{...}, required:[...]} object that the
   MCP server hands back inside tools/list under each tool's inputSchema.

   Behavior matches what GDK produced so the nine tool units render identical
   schemas without code changes:
     - Walk every PUBLIC writable property (writable means it has a setter).
     - Lower-case the property name in the JSON.
     - tkInteger / tkInt64 / tkFloat   -> 'number'  (matches GDK; tkInt64 would be
                                                     'integer' in strict JSON Schema,
                                                     but Claude accepts 'number').
     - tkUString / tkString / tkLString / tkWString -> 'string'
     - Boolean (tkEnumeration with TypeInfo(Boolean)) -> 'boolean'
     - Other enums -> 'string'
     - Skip the property entry in the required[] array iff it carries [Optional].
     - If it carries [SchemaDescription], write its text into description.

   Stdlib only. Generics: the only thing borderline here is TArray<String>
   inside System.Rtti.GetProperties (returned by the RTL — not ours), so we
   don't introduce any new generics.
=====================================================*)

INTERFACE

USES
  System.JSON;

TYPE
  TMCPSchemaGenerator = CLASS
  PUBLIC
    /// Build the JSON Schema object for ACls. Caller owns the result.
    CLASS FUNCTION GenerateSchema(ACls: TClass): TJSONObject;
  END;


IMPLEMENTATION

USES
  System.SysUtils, System.Rtti, System.TypInfo,
  MCPServer.Types;


/// Returns the JSON Schema "type" string for a Delphi RTTI type. See header
/// comment for the mapping table.
FUNCTION RttiTypeToJsonType(AType: TRttiType): String;
BEGIN
  case AType.TypeKind of
    tkInteger, tkInt64, tkFloat: Result := 'number';
    tkString, tkLString, tkWString, tkUString: Result := 'string';
    tkEnumeration:
      if AType.Handle = TypeInfo(Boolean)
        then Result := 'boolean'
        else Result := 'string';
  else
    Result := 'string';
  end;
END;


/// TRUE iff the property carries an [Optional] attribute.
FUNCTION IsOptional(AProp: TRttiProperty): Boolean;
VAR
  Attr: TCustomAttribute;
BEGIN
  for Attr in AProp.GetAttributes do
    if Attr IS OptionalAttribute then
      EXIT(TRUE);
  Result := FALSE;
END;


/// Returns the [SchemaDescription] text, or '' if absent.
FUNCTION DescriptionOf(AProp: TRttiProperty): String;
VAR
  Attr: TCustomAttribute;
BEGIN
  for Attr in AProp.GetAttributes do
    if Attr IS SchemaDescriptionAttribute then EXIT(SchemaDescriptionAttribute(Attr).Description);
  Result := '';
END;


CLASS FUNCTION TMCPSchemaGenerator.GenerateSchema(ACls: TClass): TJSONObject;
VAR
  Ctx        : TRttiContext;
  RttiType   : TRttiType;
  Prop       : TRttiProperty;
  Props      : TJSONObject;
  Required   : TJSONArray;
  PropSchema : TJSONObject;
  Desc, Name : String;
BEGIN
  Result := TJSONObject.Create;
  TRY
    Props    := TJSONObject.Create;
    Required := TJSONArray.Create;
    Result.AddPair('type', 'object');
    Result.AddPair('properties', Props);

    Ctx := TRttiContext.Create;
    TRY
      RttiType := Ctx.GetType(ACls);
      for Prop in RttiType.GetProperties do
      begin
        // A property without a writer is irrelevant — we can't fill it from JSON.
        if not (Prop.IsReadable and Prop.IsWritable) then Continue;

        Name       := LowerCase(Prop.Name);
        PropSchema := TJSONObject.Create;
        Props.AddPair(Name, PropSchema);
        PropSchema.AddPair('type', RttiTypeToJsonType(Prop.PropertyType));

        Desc := DescriptionOf(Prop);
        if Desc <> '' then
          PropSchema.AddPair('description', Desc);

        if not IsOptional(Prop) then
          Required.Add(Name);
      end;
    FINALLY
      Ctx.Free;
    END;

    if Required.Count > 0
      then Result.AddPair('required', Required)
      else Required.Free;
  EXCEPT
    FreeAndNil(Result);
    raise;
  END;
END;


END.
