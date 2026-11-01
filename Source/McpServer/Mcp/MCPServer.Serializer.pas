unit MCPServer.Serializer;

// Derived from GDK Software's Delphi-MCP-Server (MIT) - see thirdparty-notices.txt

{=============================================================================================================
   2026.11.01
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   One-way (JSON -> Delphi) RTTI deserializer for the tool params classes.
   The reverse direction is unused — our tools always produce JSON strings manually.

   Rules:
     - Property names match case-insensitively, with '_' stripped from the JSON key.
       So path / Path / PATH / p_a_t_h all resolve.
     - Unknown keys raise EArgumentException with a list of accepted names.
       This catches Claude typos early.
     - A JSON null counts as an absent key.
     - A property without [Optional] is required: absent or null, it raises EArgumentException.
     - Accepted JSON values; anything else raises EArgumentException:
         * tkInteger / tkInt64  -- JSON number or text holding a whole number that fits the type.
         * tkFloat              -- JSON number, or numeric text (invariant '.').
         * tkString family      -- JSON string, number or Boolean (its JSON text).
                                   Not an object or array.
         * Boolean              -- JSON bool, or the text 'true'/'false' (any case).
         * Other enumerations   -- a value name (GetEnumValue), or an ordinal in range as a number or text.
                                   Empty text keeps the property's value.
         * Any other type kind  -- refused (MCPServer.Schema.Generator refuses it too).
     - Every conversion error names the parameter: 'Parameter "<name>": ...'.

   Generic surface intentionally minimal: one method Deserialize<T>.
   The generic constraint is `class, constructor` because we need T.Create.

   Stdlib only.
=============================================================================================================}

interface

uses
  System.JSON;

type
  TMCPSerializer = class
  public
    { Create a fresh T and populate writable public properties from AJson.
      Raises EArgumentException if AJson contains a key that doesn't match any writable property of T (after case-insensitive normalization). }
    class function Deserialize<T: class, constructor>(AJson: TJSONObject): T;

    { Populate every writable property of AInstance from matching keys in AJson.
      Raises EArgumentException for an unknown key, a missing required parameter and a value that does not fit its property. }
    class procedure FillObject(AInstance: TObject; AJson: TJSONObject);
  end;


implementation

uses
  System.SysUtils, System.Rtti, System.TypInfo, System.Classes,
  MCPServer.Types;


{ Lower-case + strip '_'.
  The single normalization rule shared between key lookup and unknown-key validation, so the two stay in sync. }
function NormalizeKey(const AName: String): String; inline;
begin
  Result := LowerCase(AName).Replace('_', '', [rfReplaceAll]);
end;


{ Find AJson[APropName] by normalized comparison.
  Returns nil if not present. }
function FindJsonValueCI(AJson: TJSONObject; const APropName: String): TJSONValue;
var
  Pair: TJSONPair;
  Target: String;
begin
  // Fast path: exact match (the common case for Claude — it sends lower-case keys).
  Result := AJson.GetValue(APropName);
  if Result <> nil then Exit;

  Target := NormalizeKey(APropName);
  for Pair in AJson do
    if NormalizeKey(Pair.JsonString.Value) = Target then
      Exit(Pair.JsonValue);

  Result := nil;
end;


{ TRUE for a JSON number or a JSON string: the two that carry a text a number can be read from.
  TJSONNumber is tested on its own because it descends from TJSONString only up to Delphi 12. }
function IsNumberOrText(AJson: TJSONValue): Boolean;
begin
  Result := (AJson is TJSONNumber) or (AJson is TJSONString);
end;


{ Raise the EArgumentException for a value that does not fit its property.
  FillObject puts the parameter name in front. }
procedure RaiseWrongValue(AJson: TJSONValue; const AExpected: String);
begin
  raise EArgumentException.Create('expected ' + AExpected + ', got ' + Copy(AJson.ToJSON, 1, 80) + '.');
end;


{ An enumeration other than Boolean: a value name, or an ordinal in range given as a number or as text.
  Empty text gives TValue.Empty, so the property keeps its value. }
function JsonToEnum(AJson: TJSONValue; AType: TRttiEnumerationType): TValue;
var
  Ordinal: Integer;
  Found  : Boolean;
begin
  Ordinal := -1;
  Found   := FALSE;
  if AJson is TJSONNumber then   // tested before TJSONString: up to Delphi 12 a number is a TJSONString too
    Found := TryStrToInt(AJson.Value, Ordinal)
  else
    if AJson is TJSONString then
    begin
      if AJson.Value = '' then
        EXIT(TValue.Empty);
      Ordinal := GetEnumValue(AType.Handle, AJson.Value);
      Found   := (Ordinal >= 0) or TryStrToInt(AJson.Value, Ordinal);
    end;

  if not Found or (Ordinal < AType.MinValue) or (Ordinal > AType.MaxValue) then
    raise EArgumentException.Create('invalid value ' + Copy(AJson.ToJSON, 1, 80) + '. Valid values: ' + String.Join(', ', EnumValueNames(AType)) + '.');

  Result := TValue.FromOrdinal(AType.Handle, Ordinal);
end;


{ Convert a JSON value (never nil, never TJSONNull) to a TValue for a property of type AType.
  Raises EArgumentException when the value does not fit the type, or the type kind is not supported.
  TValue.Empty (enumeration, empty text) means: leave the property as it is. }
function JsonToValue(AJson: TJSONValue; AType: TRttiType): TValue;
var
  IntValue  : Integer;
  Int64Value: Int64;
  FloatValue: Double;
begin
  IntValue   := 0;
  Int64Value := 0;
  FloatValue := 0;
  case AType.TypeKind of
    tkInteger:
      begin
        if not (IsNumberOrText(AJson) and TryStrToInt(AJson.Value, IntValue)) then
          RaiseWrongValue(AJson, 'a whole number in the Integer range');
        Result := IntValue;
      end;

    tkInt64:
      begin
        if not (IsNumberOrText(AJson) and TryStrToInt64(AJson.Value, Int64Value)) then
          RaiseWrongValue(AJson, 'a whole number in the Int64 range');
        Result := Int64Value;
      end;

    tkFloat:
      if AJson is TJSONNumber
        then Result := TJSONNumber(AJson).AsDouble
        else
          begin
            if not ((AJson is TJSONString) and TryStrToFloat(AJson.Value, FloatValue, FormatSettings.Invariant)) then
              RaiseWrongValue(AJson, 'a number');
            Result := FloatValue;
          end;

    tkString, tkLString, tkWString, tkUString:
      begin
        if not (IsNumberOrText(AJson) or (AJson is TJSONBool)) then
          RaiseWrongValue(AJson, 'a string');
        Result := AJson.Value;
      end;

    tkEnumeration:
      if AType.Handle = TypeInfo(Boolean) then
      begin
        if AJson is TJSONBool then
          Result := TJSONBool(AJson).AsBoolean
        else
          if (AJson is TJSONString) and SameText(AJson.Value, 'true') then
            Result := TRUE
          else
            if (AJson is TJSONString) and SameText(AJson.Value, 'false') then
              Result := FALSE
            else
              RaiseWrongValue(AJson, 'true or false');
      end
      else
        Result := JsonToEnum(AJson, TRttiEnumerationType(AType));
  else
    raise EArgumentException.Create('its type ' + AType.Name + ' is not supported in a tool params class.');
  end;
end;


{ The actual filling step.
  Walks every writable property of AInstance and looks for a matching key in AJson.
  Unknown keys, missing required parameters and values that do not fit raise. }
class procedure TMCPSerializer.FillObject(AInstance: TObject; AJson: TJSONObject);
var
  Ctx          : TRttiContext;
  T            : TRttiType;
  Prop         : TRttiProperty;
  Pair         : TJSONPair;
  JsonValue    : TJSONValue;
  PropValue    : TValue;
  KnownNormSet : TStringList;
  KnownNames   : TStringList;
  KeyNorm      : String;
begin
  KnownNormSet := TStringList.Create;
  KnownNames   := TStringList.Create;
  try
    KnownNormSet.CaseSensitive := false;
    KnownNormSet.Sorted        := true;
    KnownNormSet.Duplicates    := dupIgnore;

    Ctx := TRttiContext.Create;
    try
      T := Ctx.GetType(AInstance.ClassType);

      // First pass: build the accepted-key set.
      for Prop in T.GetProperties do
        if Prop.IsWritable then
        begin
          KnownNormSet.Add(NormalizeKey(Prop.Name));
          KnownNames.Add(LowerCase(Prop.Name));
        end;

      // Validate every incoming key against the set. Unknown keys = typos = raise early.
      for Pair in AJson do
      begin
        KeyNorm := NormalizeKey(Pair.JsonString.Value);
        if KnownNormSet.IndexOf(KeyNorm) < 0 then
          raise EArgumentException.CreateFmt('Unknown parameter "%s". Valid parameters: %s.', [Pair.JsonString.Value, String.Join(', ', KnownNames.ToStringArray)]);
      end;

      { Second pass: assign each writable property if a matching key is present.
        A JSON null counts as absent.
        A required property (one the schema lists under "required": readable, writable, no [Optional]) must be there. }
      for Prop in T.GetProperties do
      begin
        if not Prop.IsWritable then Continue;
        JsonValue := FindJsonValueCI(AJson, Prop.Name);
        if (JsonValue = nil) or (JsonValue is TJSONNull) then
        begin
          if Prop.IsReadable and not IsOptionalProperty(Prop) then
            raise EArgumentException.Create('Missing required parameter "' + LowerCase(Prop.Name) + '".');
          Continue;
        end;

        try
          PropValue := JsonToValue(JsonValue, Prop.PropertyType);
        except
          on E: EArgumentException do
            raise EArgumentException.Create('Parameter "' + LowerCase(Prop.Name) + '": ' + E.Message);
        end;
        if not PropValue.IsEmpty then
          Prop.SetValue(AInstance, PropValue);
      end;
    finally
      Ctx.Free;
    end;
  finally
    FreeAndNil(KnownNormSet);
    FreeAndNil(KnownNames);
  end;
end;


class function TMCPSerializer.Deserialize<T>(AJson: TJSONObject): T;
begin
  Result := T.Create;
  try
    if AJson <> nil then
      TMCPSerializer.FillObject(Result, AJson);
  except
    Result.Free;
    raise;
  end;
end;


end.
