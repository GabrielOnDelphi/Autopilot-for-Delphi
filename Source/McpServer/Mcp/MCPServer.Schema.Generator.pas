unit MCPServer.Schema.Generator;

// Derived from GDK Software's Delphi-MCP-Server (MIT) - see thirdparty-notices.txt

(*=============================================================================================================
   2026.11.01
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   JSON Schema generator from a Delphi class via RTTI.
   One public class method builds a {type:'object', properties:{...}, required:[...]} object that the MCP server hands back inside tools/list under each tool's inputSchema.

   Mapping:
     - Walk every public property that is readable and writable (writable means it has a setter).
     - Lower-case the property name in the JSON.
     - tkInteger / tkInt64 -> 'integer' (so a client that validates against the schema refuses 1.5)
     - tkFloat             -> 'number'
     - tkUString / tkString / tkLString / tkWString -> 'string'
     - Boolean (tkEnumeration with TypeInfo(Boolean)) -> 'boolean'
     - Other enumerations -> 'string', plus 'enum' = the value names in ordinal order
     - Any other type kind (record, class, set, array, char, variant...) raises EArgumentException naming the property: MCPServer.Serializer cannot fill it, so publishing it would invite an argument that is lost.
     - Skip the property entry in the required[] array iff it carries [Optional].
     - If it carries [SchemaDescription], write its text into description.

   Stdlib only.
   Generics: the only thing borderline here is TArray<String> inside System.Rtti.GetProperties (returned by the RTL — not ours), so we don't introduce any new generics.
*=================================================================================================================*)

interface

uses
  System.JSON;

type
  TMCPSchemaGenerator = class
  public
    { Build the JSON Schema object for ACls.
      Caller owns the result. }
    class function GenerateSchema(ACls: TClass): TJSONObject;
  end;


implementation

uses
  System.SysUtils, System.Rtti, System.TypInfo,
  MCPServer.Types;


{ Returns the JSON Schema "type" string for the type of AProp.
  See header comment for the mapping table.
  Raises EArgumentException for a type kind outside that table. }
function JsonTypeOf(AProp: TRttiProperty): String;
var
  PropType: TRttiType;
begin
  PropType := AProp.PropertyType;
  case PropType.TypeKind of
    tkInteger, tkInt64: Result := 'integer';
    tkFloat: Result := 'number';
    tkString, tkLString, tkWString, tkUString: Result := 'string';
    tkEnumeration:
      if PropType.Handle = TypeInfo(Boolean)
      then Result := 'boolean'
      else Result := 'string';
  else
    raise EArgumentException.Create('Parameter "' + LowerCase(AProp.Name) + '": its type ' + PropType.Name + ' is not supported in a tool params class.');
  end;
end;


{ The 'enum' list of an enumeration property: its value names.
  NIL for every other type, Boolean included.
  The caller owns the result. }
function EnumListOf(AType: TRttiType): TJSONArray;
var
  Name: String;
begin
  if not (AType is TRttiEnumerationType) or (AType.Handle = TypeInfo(Boolean)) then EXIT(NIL);

  Result := TJSONArray.Create;
  for Name in EnumValueNames(TRttiEnumerationType(AType)) do
    Result.Add(Name);
end;


// Returns the [SchemaDescription] text, or '' if absent.
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
  EnumList   : TJSONArray;
  Desc, Name : String;
begin
  Result   := TJSONObject.Create;
  Required := TJSONArray.Create;
  try
    try
      Props := TJSONObject.Create;
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
            PropSchema.AddPair('type', JsonTypeOf(Prop));

            EnumList := EnumListOf(Prop.PropertyType);
            if EnumList <> NIL
            then PropSchema.AddPair('enum', EnumList);

            Desc := DescriptionOf(Prop);
            if Desc <> ''
            then PropSchema.AddPair('description', Desc);

            if not IsOptionalProperty(Prop)
            then Required.Add(Name);
          end;
      finally
        Ctx.Free;
      end;

      if Required.Count > 0 then
        begin
          Result.AddPair('required', Required);
          Required := NIL;   // Result owns it now
        end;
    finally
      FreeAndNil(Required);
    end;
  except
    FreeAndNil(Result);
    raise;
  end;
end;


end.
