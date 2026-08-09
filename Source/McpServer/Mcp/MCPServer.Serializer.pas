UNIT MCPServer.Serializer;

//Derivated from GDK

(*=====================================================
   2026.05.19
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────────────┐
   │  WINDOWS  (PC-side MCP server)       │   runs in Autopilot.Mcp.exe; target may be any platform
   └──────────────────────────────────────┘

   One-way (JSON -> Delphi) RTTI deserializer for the tool params classes.
   The reverse direction is unused — our tools always produce JSON strings
   manually.

   Behavior we keep from GDK so the existing nine tool units work unchanged:
     - Property names match case-insensitively, with '_' stripped from the
       JSON key. So path / Path / PATH / p_a_t_h all resolve.
     - Unknown keys raise EArgumentException with a list of accepted names.
       This catches Claude typos early.
     - Type coercion:
         * tkInteger / tkInt64  -- JSON number, or numeric string.
         * tkFloat              -- JSON number, or numeric string (invariant '.')
         * tkString family      -- JSON string (or other types via .Value).
         * Boolean              -- JSON bool, or 'true'/'false' string (case-insens.)
         * Other enums          -- string (resolved via GetEnumValue) or ordinal.

   Generic surface intentionally minimal: one method `Deserialize<T>`. The
   generic constraint is `class, constructor` because we need T.Create.

   Stdlib only.
=====================================================*)

INTERFACE

USES
  System.JSON;

TYPE
  TMCPSerializer = CLASS
  PUBLIC
    /// Create a fresh T and populate writable public properties from AJson.
    /// Raises EArgumentException if AJson contains a key that doesn't match any
    /// writable property of T (after case-insensitive normalization).
    CLASS FUNCTION Deserialize<T: CLASS, CONSTRUCTOR>(AJson: TJSONObject): T;

    /// Populate every writable property of AInstance from matching keys in AJson.
    /// Unknown keys raise EArgumentException with a list of accepted names.
    CLASS PROCEDURE FillObject(AInstance: TObject; AJson: TJSONObject);
  END;


IMPLEMENTATION

USES
  System.SysUtils, System.Rtti, System.TypInfo, System.Classes;


/// Lower-case + strip '_'. The single normalization rule shared between key
/// lookup and unknown-key validation, so the two stay in sync.
FUNCTION NormalizeKey(CONST AName: String): String; INLINE;
BEGIN
  Result := LowerCase(AName).Replace('_', '', [rfReplaceAll]);
END;


/// Find AJson[APropName] by normalized comparison. Returns NIL if not present.
FUNCTION FindJsonValueCI(AJson: TJSONObject; CONST APropName: String): TJSONValue;
VAR
  Pair: TJSONPair;
  Target: String;
BEGIN
  // Fast path: exact match (the common case for Claude — it sends lower-case keys).
  Result := AJson.GetValue(APropName);
  if Result <> NIL then EXIT;

  Target := NormalizeKey(APropName);
  for Pair in AJson do
    if NormalizeKey(Pair.JsonString.Value) = Target then
      EXIT(Pair.JsonValue);

  Result := NIL;
END;


/// Convert a JSON value to a TValue compatible with the destination property type.
/// Returns TValue.Empty if AJson is nil or the type isn't supported — caller skips
/// the assignment in that case (leaves Delphi default in place).
FUNCTION JsonToValue(AJson: TJSONValue; AType: TRttiType): TValue;
VAR
  EnumOrdinal: Integer;
BEGIN
  Result := TValue.Empty;
  if AJson = NIL then EXIT;

  case AType.TypeKind of
    tkInteger:
      if AJson IS TJSONNumber
        then Result := TJSONNumber(AJson).AsInt
        else Result := StrToIntDef(AJson.Value, 0);

    tkInt64:
      if AJson IS TJSONNumber
        then Result := TJSONNumber(AJson).AsInt64
        else Result := StrToInt64Def(AJson.Value, 0);

    tkFloat:
      if AJson IS TJSONNumber
        then Result := TJSONNumber(AJson).AsDouble
        else Result := StrToFloatDef(AJson.Value, 0, FormatSettings.Invariant);

    tkString, tkLString, tkWString, tkUString:
      Result := AJson.Value;

    tkEnumeration:
      if AType.Handle = TypeInfo(Boolean) then
      begin
        if AJson IS TJSONBool
          then Result := TJSONBool(AJson).AsBoolean
          else Result := SameText(AJson.Value, 'true');
      end
      else
      begin
        if AJson IS TJSONNumber then
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
END;


/// Build the comma-joined list of accepted (writable) property names on ACls,
/// shown in the EArgumentException when an unknown key arrives.
FUNCTION AcceptedKeysList(ACls: TClass): String;
VAR
  Ctx : TRttiContext;
  T   : TRttiType;
  Prop: TRttiProperty;
  L   : TStringList;
BEGIN
  L := TStringList.Create;
  TRY
    Ctx := TRttiContext.Create;
    TRY
      T := Ctx.GetType(ACls);
      for Prop in T.GetProperties do
        if Prop.IsWritable then
          L.Add(LowerCase(Prop.Name));
    FINALLY
      Ctx.Free;
    END;
    Result := String.Join(', ', L.ToStringArray);
  FINALLY
    L.Free;
  END;
END;


/// The actual filling step. Walks every writable property of AInstance and
/// looks for a matching key in AJson. Unknown keys raise.
CLASS PROCEDURE TMCPSerializer.FillObject(AInstance: TObject; AJson: TJSONObject);
VAR
  Ctx          : TRttiContext;
  T            : TRttiType;
  Prop         : TRttiProperty;
  Pair         : TJSONPair;
  JsonValue    : TJSONValue;
  PropValue    : TValue;
  KnownNormSet : TStringList;
  KnownNames   : TStringList;
  KeyNorm      : String;
BEGIN
  KnownNormSet := TStringList.Create;
  KnownNames   := TStringList.Create;
  TRY
    KnownNormSet.CaseSensitive := FALSE;
    KnownNormSet.Sorted        := TRUE;
    KnownNormSet.Duplicates    := dupIgnore;

    Ctx := TRttiContext.Create;
    TRY
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
        if JsonValue = NIL then Continue;
        PropValue := JsonToValue(JsonValue, Prop.PropertyType);
        if not PropValue.IsEmpty then
          Prop.SetValue(AInstance, PropValue);
      end;
    FINALLY
      Ctx.Free;
    END;
  FINALLY
    KnownNormSet.Free;
    KnownNames.Free;
  END;
END;


CLASS FUNCTION TMCPSerializer.Deserialize<T>(AJson: TJSONObject): T;
BEGIN
  Result := T.Create;
  TRY
    if AJson <> NIL then
      TMCPSerializer.FillObject(Result, AJson);
  EXCEPT
    Result.Free;
    raise;
  END;
END;


END.
