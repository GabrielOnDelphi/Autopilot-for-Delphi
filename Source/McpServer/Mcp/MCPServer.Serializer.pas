unit MCPServer.Serializer;

// Derived from GDK

{=============================================================================================================
   2026.09
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   One-way (JSON -> Delphi) RTTI deserializer for the tool params classes.
   The reverse direction is unused — our tools always produce JSON strings manually.

   Behavior we keep from GDK so the existing nine tool units work unchanged:
     - Property names match case-insensitively, with '_' stripped from the JSON key.
       So path / Path / PATH / p_a_t_h all resolve.
     - Unknown keys raise EArgumentException with a list of accepted names.
       This catches Claude typos early.
     - Type coercion:
         * tkInteger / tkInt64  -- JSON number, or numeric string.
         * tkFloat              -- JSON number, or numeric string (invariant '.').
         * tkString family      -- JSON string (or other types via .Value).
         * Boolean              -- JSON bool, or 'true'/'false' string (case-insensitive).
         * Other enumerations   -- string (resolved via GetEnumValue) or ordinal.

   Generic surface intentionally minimal: one method Deserialize<T>. The generic constraint is
   `class, constructor` because we need T.Create.

   Stdlib only.
=============================================================================================================}

interface

uses
  System.JSON;

type
  TMCPSerializer = class
  public
    /// Create a fresh T and populate writable public properties from AJson.
    /// Raises EArgumentException if AJson contains a key that doesn't match any
    /// writable property of T (after case-insensitive normalization).
    class function Deserialize<T: class, constructor>(AJson: TJSONObject): T;

    /// Populate every writable property of AInstance from matching keys in AJson.
    /// Unknown keys raise EArgumentException with a list of accepted names.
    class procedure FillObject(AInstance: TObject; AJson: TJSONObject);
  end;


implementation

uses
  System.SysUtils, System.Rtti, System.TypInfo, System.Classes;


/// Lower-case + strip '_'. The single normalization rule shared between key
/// lookup and unknown-key validation, so the two stay in sync.
function NormalizeKey(const AName: String): String; inline;
begin
  Result := LowerCase(AName).Replace('_', '', [rfReplaceAll]);
end;


/// Find AJson[APropName] by normalized comparison. Returns nil if not present.
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


/// Convert a JSON value to a TValue compatible with the destination property type.
/// Returns TValue.Empty if AJson is nil or the type isn't supported — caller skips
/// the assignment in that case (leaves Delphi default in place).
function JsonToValue(AJson: TJSONValue; AType: TRttiType): TValue;
var
  EnumOrdinal: Integer;
begin
  Result := TValue.Empty;
  if AJson = nil then Exit;

  case AType.TypeKind of
    tkInteger:
      if AJson is TJSONNumber
        then Result := TJSONNumber(AJson).AsInt
        else Result := StrToIntDef(AJson.Value, 0);

    tkInt64:
      if AJson is TJSONNumber
        then Result := TJSONNumber(AJson).AsInt64
        else Result := StrToInt64Def(AJson.Value, 0);

    tkFloat:
      if AJson is TJSONNumber
        then Result := TJSONNumber(AJson).AsDouble
        else Result := StrToFloatDef(AJson.Value, 0, FormatSettings.Invariant);

    tkString, tkLString, tkWString, tkUString:
      Result := AJson.Value;

    tkEnumeration:
      if AType.Handle = TypeInfo(Boolean) then
      begin
        if AJson is TJSONBool
          then Result := TJSONBool(AJson).AsBoolean
          else Result := SameText(AJson.Value, 'true');
      end
      else
      begin
        if AJson is TJSONNumber then
          Result := TValue.FromOrdinal(AType.Handle, TJSONNumber(AJson).AsInt)
        else
        begin
          EnumOrdinal := GetEnumValue(AType.Handle, AJson.Value);
          if EnumOrdinal >= 0
            then Result := TValue.FromOrdinal(AType.Handle, EnumOrdinal)
            else Result := TValue.FromOrdinal(AType.Handle, StrToIntDef(AJson.Value, 0));
        end;
      end;
  end;
end;


/// The actual filling step. Walks every writable property of AInstance and
/// looks for a matching key in AJson. Unknown keys raise.
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
          raise EArgumentException.CreateFmt(
            'Unknown parameter "%s". Valid parameters: %s.',
            [Pair.JsonString.Value, String.Join(', ', KnownNames.ToStringArray)]);
      end;

      // Second pass: assign each writable property if a matching key is present.
      for Prop in T.GetProperties do
      begin
        if not Prop.IsWritable then Continue;
        JsonValue := FindJsonValueCI(AJson, Prop.Name);
        if JsonValue = nil then Continue;
        PropValue := JsonToValue(JsonValue, Prop.PropertyType);
        if not PropValue.IsEmpty then
          Prop.SetValue(AInstance, PropValue);
      end;
    finally
      Ctx.Free;
    end;
  finally
    KnownNormSet.Free;
    KnownNames.Free;
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
