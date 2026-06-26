unit Tests.Mcp.Schema;

{=============================================================================================================
   2026.06
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for TMCPSchemaGenerator: verifies that a params class with mixed property types and [Optional]/[SchemaDescription] attributes produces correct JSON schema output.
=============================================================================================================}

interface

uses
  DUnitX.TestFramework,
  // MCPServer.Types MUST appear in the interface uses clause, not the
  // implementation uses below. The attributes [Optional] and [SchemaDescription]
  // are referenced on the property declarations a few lines below, which is
  // interface-section code. If MCPServer.Types is only imported in the
  // implementation, the compiler can't resolve the attribute class names — it
  // emits a W1074 warning and SILENTLY DROPS the attributes at RTTI time, which
  // breaks the test ("description landed" and "optional → not required") in
  // ways that look like real bugs in the schema generator but aren't.
  MCPServer.Types;

type
  /// A throwaway params class — one [Optional] integer, one required string with
  /// description, one Boolean, one Int64, one float. Public properties so the
  /// schema walker finds them via default RTTI (same as the production tools).
  TFakeParams = class
  private
    FPath    : String;
    FPid     : Integer;
    FChecked : Boolean;
    FCount   : Int64;
    FScale   : Double;
  public
    [SchemaDescription('A required path string.')]
    property Path: String read FPath write FPath;

    [Optional]
    [SchemaDescription('Optional process id.')]
    property Pid: Integer read FPid write FPid;

    property Checked: Boolean read FChecked write FChecked;
    property Count  : Int64   read FCount   write FCount;
    property Scale  : Double  read FScale   write FScale;
  end;

  [TestFixture]
  TSchemaTests = class
  public
    [Test] procedure Test_TopLevelTypeIsObject;
    [Test] procedure Test_StringPropertyMapsToString;
    [Test] procedure Test_IntegerPropertyMapsToNumber;
    [Test] procedure Test_Int64PropertyMapsToNumber;
    [Test] procedure Test_FloatPropertyMapsToNumber;
    [Test] procedure Test_BooleanPropertyMapsToBoolean;
    [Test] procedure Test_DescriptionLandsOnProperty;
    [Test] procedure Test_OptionalPropertyNotInRequired;
    [Test] procedure Test_PropertyNamesAreLowerCased;
  end;


implementation

uses
  System.SysUtils, System.JSON, System.Generics.Collections,
  MCPServer.Schema.Generator;
// MCPServer.Types is already pulled in by the interface uses (it has to be —
// see comment up there).


/// Build a schema for TFakeParams. Caller frees.
function Schema: TJSONObject;
begin
  Result := TMCPSchemaGenerator.GenerateSchema(TFakeParams);
end;


/// Extract the inner type string for a named property — e.g. 'string', 'number',
/// 'boolean'. Returns '' if missing.
function PropType(ASchema: TJSONObject; const AName: String): String;
var
  Props, Entry: TJSONObject;
  TypeNode    : TJSONValue;
begin
  Result := '';
  Props := ASchema.GetValue('properties') AS TJSONObject;
  if Props = nil then Exit;
  Entry := Props.GetValue(AName) AS TJSONObject;
  if Entry = nil then Exit;
  TypeNode := Entry.GetValue('type');
  if TypeNode <> nil then
    Result := TypeNode.Value;
end;


procedure TSchemaTests.Test_TopLevelTypeIsObject;
var
  S: TJSONObject;
begin
  S := Schema;
  try
    Assert.AreEqual('object', S.GetValue('type').Value);
  finally
    S.Free;
  end;
end;

procedure TSchemaTests.Test_StringPropertyMapsToString;
var
  S: TJSONObject;
begin
  S := Schema;
  try
    Assert.AreEqual('string', PropType(S, 'path'));
  finally
    S.Free;
  end;
end;

procedure TSchemaTests.Test_IntegerPropertyMapsToNumber;
var
  S: TJSONObject;
begin
  S := Schema;
  try
    Assert.AreEqual('number', PropType(S, 'pid'));
  finally
    S.Free;
  end;
end;

procedure TSchemaTests.Test_Int64PropertyMapsToNumber;
var
  S: TJSONObject;
begin
  S := Schema;
  try
    Assert.AreEqual('number', PropType(S, 'count'));
  finally
    S.Free;
  end;
end;

procedure TSchemaTests.Test_FloatPropertyMapsToNumber;
var
  S: TJSONObject;
begin
  S := Schema;
  try
    Assert.AreEqual('number', PropType(S, 'scale'));
  finally
    S.Free;
  end;
end;

procedure TSchemaTests.Test_BooleanPropertyMapsToBoolean;
var
  S: TJSONObject;
begin
  S := Schema;
  try
    Assert.AreEqual('boolean', PropType(S, 'checked'));
  finally
    S.Free;
  end;
end;

procedure TSchemaTests.Test_DescriptionLandsOnProperty;
var
  S, Props, Entry: TJSONObject;
  Desc           : TJSONValue;
begin
  S := Schema;
  try
    Props := S.GetValue('properties') AS TJSONObject;
    Assert.IsNotNull(Props, 'properties{} missing');
    Entry := Props.GetValue('path') AS TJSONObject;
    Assert.IsNotNull(Entry, 'properties.path missing');
    Desc  := Entry.GetValue('description');
    Assert.IsNotNull(Desc, 'path.description missing');
    Assert.AreEqual('A required path string.', Desc.Value);
  finally
    S.Free;
  end;
end;

procedure TSchemaTests.Test_OptionalPropertyNotInRequired;
var
  S: TJSONObject;
  ReqArr: TJSONArray;
  i: Integer;
  HasPath, HasPid: Boolean;
begin
  S := Schema;
  try
    ReqArr := S.GetValue('required') AS TJSONArray;
    Assert.IsNotNull(ReqArr, 'required[] missing');
    HasPath := False;
    HasPid  := False;
    for i := 0 to ReqArr.Count - 1 do
    begin
      if ReqArr.Items[i].Value = 'path'    then HasPath := True;
      if ReqArr.Items[i].Value = 'pid'     then HasPid  := True;
    end;
    Assert.IsTrue(HasPath, 'path should be required');
    Assert.IsFalse(HasPid, 'pid should NOT be required (it has [Optional])');
  finally
    S.Free;
  end;
end;

procedure TSchemaTests.Test_PropertyNamesAreLowerCased;
var
  S, Props: TJSONObject;
begin
  S := Schema;
  try
    Props := S.GetValue('properties') AS TJSONObject;
    // We declared them as Path / Pid / Checked / Count / Scale in PascalCase.
    // The schema must lower-case them.
    Assert.IsNotNull(Props.GetValue('path'),    'path missing — lower-casing broke?');
    Assert.IsNotNull(Props.GetValue('pid'),     'pid missing');
    Assert.IsNotNull(Props.GetValue('checked'), 'checked missing');
    Assert.IsNotNull(Props.GetValue('count'),   'count missing');
    Assert.IsNotNull(Props.GetValue('scale'),   'scale missing');
    Assert.IsNull(Props.GetValue('Path'),       'Should NOT have Path with capital P');
  finally
    S.Free;
  end;
end;


initialization
  TDUnitX.RegisterTestFixture(TSchemaTests);

end.
