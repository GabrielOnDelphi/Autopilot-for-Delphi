unit MCPServer.Schema.Generator;

// Derived from GDK

(*=============================================================================================================
   2026.09
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   JSON Schema generator from a Delphi class via RTTI. One public class method builds a
   {type:'object', properties:{...}, required:[...]} object that the MCP server hands back inside
   tools/list under each tool's inputSchema.

   Behavior matches what GDK produced so the nine tool units render identical schemas without code
   changes:
     - Walk every public writable property (writable means it has a setter).
     - Lower-case the property name in the JSON.
     - tkInteger / tkInt64 / tkFloat   -> 'number'  (matches GDK; tkInt64 would be 'integer' in
                                                     strict JSON Schema, but Claude accepts 'number').
     - tkUString / tkString / tkLString / tkWString -> 'string'
     - Boolean (tkEnumeration with TypeInfo(Boolean)) -> 'boolean'
     - Other enumerations -> 'string'
     - Skip the property entry in the required[] array iff it carries [Optional].
     - If it carries [SchemaDescription], write its text into description.

   Stdlib only. Generics: the only thing borderline here is TArray<String> inside
   System.Rtti.GetProperties (returned by the RTL — not ours), so we don't introduce any new
   generics.
*=================================================================================================================*)

interface

uses
  System.JSON;

type
  TMCPSchemaGenerator = class
  public
    /// Build the JSON Schema object for ACls. Caller owns the result.
    class function GenerateSchema(ACls: TClass): TJSONObject;
  end;


implementation

uses
  System.SysUtils, System.Rtti, System.TypInfo,
  MCPServer.Types;


/// Returns the JSON Schema "type" string for a Delphi RTTI type. See header
/// comment for the mapping table.
function RttiTypeToJsonType(AType: TRttiType): String;
begin
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
end;


/// True iff the property carries an [Optional] attribute.
function IsOptional(AProp: TRttiProperty): Boolean;
var
  Attr: TCustomAttribute;
begin
  for Attr in AProp.GetAttributes do
    if Attr is OptionalAttribute then
      Exit(true);
  Result := false;
end;


/// Returns the [SchemaDescription] text, or '' if absent.
function DescriptionOf(AProp: TRttiProperty): String;
var
  Attr: TCustomAttribute;
begin
  for Attr in AProp.GetAttributes do
    if Attr is SchemaDescriptionAttribute then Exit(SchemaDescriptionAttribute(Attr).Description);
  Result := '';
end;


class function TMCPSchemaGenerator.GenerateSchema(ACls: TClass): TJSONObject;
var
  Ctx        : TRttiContext;
  RttiType   : TRttiType;
  Prop       : TRttiProperty;
  Props      : TJSONObject;
  Required   : TJSONArray;
  PropSchema : TJSONObject;
  Desc, Name : String;
begin
  Result := TJSONObject.Create;
  try
    Props    := TJSONObject.Create;
    Required := TJSONArray.Create;
    Result.AddPair('type', 'object');
    Result.AddPair('properties', Props);

    Ctx := TRttiContext.Create;
    try
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
    finally
      Ctx.Free;
    end;

    if Required.Count > 0
      then Result.AddPair('required', Required)
      else Required.Free;
  except
    FreeAndNil(Result);
    raise;
  end;
end;


end.
