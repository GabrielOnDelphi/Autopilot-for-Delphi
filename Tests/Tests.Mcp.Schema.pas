UNIT Tests.Mcp.Schema;

(*=====================================================
   2026.06.03
   DUnitX tests for TMCPSchemaGenerator.

   We declare a throwaway params class with a mix of types and attributes,
   feed it to GenerateSchema, and inspect the resulting JSON.
=====================================================*)

INTERFACE

USES
  DUnitX.TestFramework,
  // MCPServer.Types MUST appear in the INTERFACE uses clause, not the
  // IMPLEMENTATION uses below. The attributes [Optional] and [SchemaDescription]
  // are referenced on the property declarations a few lines below, which is
  // INTERFACE-section code. If MCPServer.Types is only imported in the
  // IMPLEMENTATION, the compiler can't resolve the attribute class names — it
  // emits a W1074 warning and SILENTLY DROPS the attributes at RTTI time, which
  // breaks the test ("description landed" and "optional → not required") in
  // ways that look like real bugs in the schema generator but aren't.
  MCPServer.Types;

TYPE
  /// A throwaway params class — one [Optional] integer, one required string with
  /// description, one Boolean, one Int64, one float. Public properties so the
  /// schema walker finds them via default RTTI (same as the production tools).
  TFakeParams = CLASS
  PRIVATE
    FPath    : String;
    FPid     : Integer;
    FChecked : Boolean;
    FCount   : Int64;
    FScale   : Double;
  PUBLIC
    [SchemaDescription('A required path string.')]
    PROPERTY Path: String READ FPath WRITE FPath;

    [Optional]
    [SchemaDescription('Optional process id.')]
    PROPERTY Pid: Integer READ FPid WRITE FPid;

    PROPERTY Checked: Boolean READ FChecked WRITE FChecked;
    PROPERTY Count  : Int64   READ FCount   WRITE FCount;
    PROPERTY Scale  : Double  READ FScale   WRITE FScale;
  END;

  [TestFixture]
  TSchemaTests = CLASS
  PUBLIC
    [Test] PROCEDURE Test_TopLevelTypeIsObject;
    [Test] PROCEDURE Test_StringPropertyMapsToString;
    [Test] PROCEDURE Test_IntegerPropertyMapsToNumber;
    [Test] PROCEDURE Test_Int64PropertyMapsToNumber;
    [Test] PROCEDURE Test_FloatPropertyMapsToNumber;
    [Test] PROCEDURE Test_BooleanPropertyMapsToBoolean;
    [Test] PROCEDURE Test_DescriptionLandsOnProperty;
    [Test] PROCEDURE Test_OptionalPropertyNotInRequired;
    [Test] PROCEDURE Test_PropertyNamesAreLowerCased;
  END;


IMPLEMENTATION

USES
  System.SysUtils, System.JSON, System.Generics.Collections,
  MCPServer.Schema.Generator;
// MCPServer.Types is already pulled in by the INTERFACE uses (it has to be —
// see comment up there).


/// Build a schema for TFakeParams. Caller frees.
FUNCTION Schema: TJSONObject;
BEGIN
  Result := TMCPSchemaGenerator.GenerateSchema(TFakeParams);
END;


/// Extract the inner type string for a named property — e.g. 'string', 'number',
/// 'boolean'. Returns '' if missing.
FUNCTION PropType(ASchema: TJSONObject; CONST AName: String): String;
VAR
  Props, Entry: TJSONObject;
  TypeNode    : TJSONValue;
BEGIN
  Result := '';
  Props := ASchema.GetValue('properties') AS TJSONObject;
  if Props = NIL then EXIT;
  Entry := Props.GetValue(AName) AS TJSONObject;
  if Entry = NIL then EXIT;
  TypeNode := Entry.GetValue('type');
  if TypeNode <> NIL then
    Result := TypeNode.Value;
END;


PROCEDURE TSchemaTests.Test_TopLevelTypeIsObject;
VAR
  S: TJSONObject;
BEGIN
  S := Schema;
  TRY
    Assert.AreEqual('object', S.GetValue('type').Value);
  FINALLY
    S.Free;
  END;
END;

PROCEDURE TSchemaTests.Test_StringPropertyMapsToString;
VAR
  S: TJSONObject;
BEGIN
  S := Schema;
  TRY
    Assert.AreEqual('string', PropType(S, 'path'));
  FINALLY
    S.Free;
  END;
END;

PROCEDURE TSchemaTests.Test_IntegerPropertyMapsToNumber;
VAR
  S: TJSONObject;
BEGIN
  S := Schema;
  TRY
    Assert.AreEqual('number', PropType(S, 'pid'));
  FINALLY
    S.Free;
  END;
END;

PROCEDURE TSchemaTests.Test_Int64PropertyMapsToNumber;
VAR
  S: TJSONObject;
BEGIN
  S := Schema;
  TRY
    Assert.AreEqual('number', PropType(S, 'count'));
  FINALLY
    S.Free;
  END;
END;

PROCEDURE TSchemaTests.Test_FloatPropertyMapsToNumber;
VAR
  S: TJSONObject;
BEGIN
  S := Schema;
  TRY
    Assert.AreEqual('number', PropType(S, 'scale'));
  FINALLY
    S.Free;
  END;
END;

PROCEDURE TSchemaTests.Test_BooleanPropertyMapsToBoolean;
VAR
  S: TJSONObject;
BEGIN
  S := Schema;
  TRY
    Assert.AreEqual('boolean', PropType(S, 'checked'));
  FINALLY
    S.Free;
  END;
END;

PROCEDURE TSchemaTests.Test_DescriptionLandsOnProperty;
VAR
  S, Props, Entry: TJSONObject;
  Desc           : TJSONValue;
BEGIN
  S := Schema;
  TRY
    Props := S.GetValue('properties') AS TJSONObject;
    Assert.IsNotNull(Props, 'properties{} missing');
    Entry := Props.GetValue('path') AS TJSONObject;
    Assert.IsNotNull(Entry, 'properties.path missing');
    Desc  := Entry.GetValue('description');
    Assert.IsNotNull(Desc, 'path.description missing');
    Assert.AreEqual('A required path string.', Desc.Value);
  FINALLY
    S.Free;
  END;
END;

PROCEDURE TSchemaTests.Test_OptionalPropertyNotInRequired;
VAR
  S: TJSONObject;
  ReqArr: TJSONArray;
  i: Integer;
  HasPath, HasPid: Boolean;
BEGIN
  S := Schema;
  TRY
    ReqArr := S.GetValue('required') AS TJSONArray;
    Assert.IsNotNull(ReqArr, 'required[] missing');
    HasPath := FALSE;
    HasPid  := FALSE;
    for i := 0 to ReqArr.Count - 1 do
    begin
      if ReqArr.Items[i].Value = 'path'    then HasPath := TRUE;
      if ReqArr.Items[i].Value = 'pid'     then HasPid  := TRUE;
    end;
    Assert.IsTrue(HasPath, 'path should be required');
    Assert.IsFalse(HasPid, 'pid should NOT be required (it has [Optional])');
  FINALLY
    S.Free;
  END;
END;

PROCEDURE TSchemaTests.Test_PropertyNamesAreLowerCased;
VAR
  S, Props: TJSONObject;
BEGIN
  S := Schema;
  TRY
    Props := S.GetValue('properties') AS TJSONObject;
    // We declared them as Path / Pid / Checked / Count / Scale in PascalCase.
    // The schema must lower-case them.
    Assert.IsNotNull(Props.GetValue('path'),    'path missing — lower-casing broke?');
    Assert.IsNotNull(Props.GetValue('pid'),     'pid missing');
    Assert.IsNotNull(Props.GetValue('checked'), 'checked missing');
    Assert.IsNotNull(Props.GetValue('count'),   'count missing');
    Assert.IsNotNull(Props.GetValue('scale'),   'scale missing');
    Assert.IsNull(Props.GetValue('Path'),       'Should NOT have Path with capital P');
  FINALLY
    S.Free;
  END;
END;


INITIALIZATION
  TDUnitX.RegisterTestFixture(TSchemaTests);

END.
