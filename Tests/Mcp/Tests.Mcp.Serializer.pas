unit Tests.Mcp.Serializer;

{=============================================================================================================
   2026.11.01
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for TMCPSerializer.Deserialize<T>: case-insensitive key lookup, unknown-key error path, basic type coercion (string, integer, numeric-string-to-integer).
   - The argument checks: a missing required parameter, a JSON null, a value of the wrong JSON type, an unknown
     enumeration value and an unsupported property type. Each error names the parameter.
=============================================================================================================}

interface

uses
  System.Types,
  DUnitX.TestFramework,
  // MCPServer.Types must stay in the INTERFACE uses: the [Optional] attributes below are interface code, and
  // without the unit there the compiler only warns (W1074) and drops them (see Tests.Mcp.Schema).
  MCPServer.Types;

type
  /// Same shape as the production TSetPropertyParams / etc.: one required string Path,
  /// one [Optional] Integer Pid. All public, written via default RTTI.
  TFakeParams = class
  private
    FPath: String;
    FPid : Integer;
  public
    property Path: String  read FPath write FPath;
    [Optional]
    property Pid : Integer read FPid  write FPid;
  end;

  /// One property of every kind the serializer fills, all [Optional], so a test can send any one key alone.
  TFakeTypedParams = class
  private
    FPath   : String;
    FPid    : Integer;
    FBig    : Int64;
    FScale  : Double;
    FChecked: Boolean;
  public
    [Optional] property Path   : String  read FPath    write FPath;
    [Optional] property Pid    : Integer read FPid     write FPid;
    [Optional] property Big    : Int64   read FBig     write FBig;
    [Optional] property Scale  : Double  read FScale   write FScale;
    [Optional] property Checked: Boolean read FChecked write FChecked;
  end;

  TFakeMode = (fmAuto, fmMessage);

  TFakeEnumParams = class
  private
    FMode: TFakeMode;
  public
    [Optional] property Mode: TFakeMode read FMode write FMode;
  end;

  /// A record property: a kind the serializer cannot fill.
  TFakeRecordParams = class
  private
    FPt: TPoint;
  public
    property Pt: TPoint read FPt write FPt;
  end;

  [TestFixture]
  TSerializerTests = class
  public
    [Test] procedure Test_DeserializesPlainString;
    [Test] procedure Test_DeserializesPlainInteger;
    [Test] procedure Test_CaseInsensitiveLookup_UpperCaseKey;
    [Test] procedure Test_UnknownKeyRaisesEArgumentException;
    [Test] procedure Test_NilJsonReturnsFreshInstance;
    [Test] procedure Test_MissingKeyLeavesDefaultValue;
    [Test] procedure Test_NumericStringCoercesToInteger;
    [Test] procedure Test_NullCountsAsAbsent;
    [Test] procedure Test_MissingRequiredParamRaisesNamingIt;
    [Test] procedure Test_NonNumericTextForIntegerRaises;
    [Test] procedure Test_FractionForIntegerRaises;
    [Test] procedure Test_WrongTypeForBooleanRaises;
    [Test] procedure Test_ObjectOrArrayForStringRaises;
    [Test] procedure Test_KeptCoercionsStillWork;
    [Test] procedure Test_UnknownEnumNameRaisesListingNames;
    [Test] procedure Test_OutOfRangeEnumOrdinalRaises;
    [Test] procedure Test_EnumNameOrdinalAndEmptyText;
    [Test] procedure Test_RecordPropertyRaisesNamingIt;
  end;


implementation

uses
  System.SysUtils, System.JSON,
  MCPServer.Serializer;


/// Fill AInstance from AJsonText.
procedure FillFrom(AInstance: TObject; const AJsonText: String);
var
  Js: TJSONObject;
begin
  Js := TJSONObject.ParseJSONValue(AJsonText) as TJSONObject;
  try
    Assert.IsNotNull(Js, 'test JSON does not parse: ' + AJsonText);
    TMCPSerializer.FillObject(AInstance, Js);
  finally
    FreeAndNil(Js);
  end;
end;


/// Fill a fresh AClass instance from AJsonText. Returns the message of the EArgumentException that raises;
/// fails the test when none does.
function FillErrorOf(AClass: TClass; const AJsonText: String): String;
var
  Instance: TObject;
begin
  Result := '';
  Instance := AClass.Create;
  try
    try
      FillFrom(Instance, AJsonText);
    except
      on E: EArgumentException do
        EXIT(E.Message);
    end;
    Assert.Fail('no EArgumentException for ' + AJsonText);
  finally
    FreeAndNil(Instance);
  end;
end;


procedure TSerializerTests.Test_DeserializesPlainString;
var
  Js: TJSONObject;
  P : TFakeParams;
begin
  Js := TJSONObject.Create;
  try
    Js.AddPair('path', 'frmMain.btnOk');
    P := TMCPSerializer.Deserialize<TFakeParams>(Js);
    try
      Assert.AreEqual('frmMain.btnOk', P.Path);
    finally
      P.Free;
    end;
  finally
    Js.Free;
  end;
end;


procedure TSerializerTests.Test_DeserializesPlainInteger;
var
  Js: TJSONObject;
  P : TFakeParams;
begin
  Js := TJSONObject.Create;
  try
    Js.AddPair('path', 'frmMain.btnOk');   // Path is required
    Js.AddPair('pid', TJSONNumber.Create(12345));
    P := TMCPSerializer.Deserialize<TFakeParams>(Js);
    try
      Assert.AreEqual(12345, P.Pid);
    finally
      P.Free;
    end;
  finally
    Js.Free;
  end;
end;


procedure TSerializerTests.Test_CaseInsensitiveLookup_UpperCaseKey;
var
  Js: TJSONObject;
  P : TFakeParams;
begin
  Js := TJSONObject.Create;
  try
    Js.AddPair('PATH', 'X');
    P := TMCPSerializer.Deserialize<TFakeParams>(Js);
    try
      Assert.AreEqual('X', P.Path);
    finally
      P.Free;
    end;
  finally
    Js.Free;
  end;
end;


procedure TSerializerTests.Test_UnknownKeyRaisesEArgumentException;
var
  Js: TJSONObject;
begin
  Js := TJSONObject.Create;
  try
    Js.AddPair('nonsense', TJSONNumber.Create(1));
    Assert.WillRaise(
      procedure
      begin
        TMCPSerializer.Deserialize<TFakeParams>(Js).Free;
      end,
      EArgumentException,
      'Unknown key must raise EArgumentException');
  finally
    Js.Free;
  end;
end;


procedure TSerializerTests.Test_NilJsonReturnsFreshInstance;
var
  P: TFakeParams;
begin
  P := TMCPSerializer.Deserialize<TFakeParams>(nil);
  try
    Assert.AreEqual('', P.Path);
    Assert.AreEqual(0, P.Pid);
  finally
    P.Free;
  end;
end;


procedure TSerializerTests.Test_MissingKeyLeavesDefaultValue;
var
  Js: TJSONObject;
  P : TFakeParams;
begin
  Js := TJSONObject.Create;
  try
    Js.AddPair('path', 'something');
    P := TMCPSerializer.Deserialize<TFakeParams>(Js);
    try
      Assert.AreEqual('something', P.Path);
      Assert.AreEqual(0, P.Pid, 'Pid was not in JSON; should stay 0');
    finally
      P.Free;
    end;
  finally
    Js.Free;
  end;
end;


procedure TSerializerTests.Test_NumericStringCoercesToInteger;
var
  Js: TJSONObject;
  P : TFakeParams;
begin
  Js := TJSONObject.Create;
  try
    // GDK behavior: a JSON string holding digits is coerced to the property's
    // declared Integer type. Some clients send pid as a string. Match this.
    Js.AddPair('path', 'frmMain.btnOk');   // Path is required
    Js.AddPair('pid', '42');
    P := TMCPSerializer.Deserialize<TFakeParams>(Js);
    try
      Assert.AreEqual(42, P.Pid);
    finally
      P.Free;
    end;
  finally
    Js.Free;
  end;
end;


/// A JSON null counts as an absent key: an [Optional] property keeps its default instead of receiving the text 'null'.
procedure TSerializerTests.Test_NullCountsAsAbsent;
var
  P: TFakeTypedParams;
begin
  P := TFakeTypedParams.Create;
  try
    FillFrom(P, '{"path":null,"pid":5}');
    Assert.AreEqual('', P.Path, 'a null path must leave Path empty');
    Assert.AreEqual(5, P.Pid);
  finally
    FreeAndNil(P);
  end;
end;


/// A property without [Optional] is required: absent or null, the call is refused naming the parameter, before
/// any tool code runs. Given, it is accepted.
procedure TSerializerTests.Test_MissingRequiredParamRaisesNamingIt;
var
  Msg: String;
  P: TFakeParams;
begin
  Msg := FillErrorOf(TFakeParams, '{"pid":1}');
  Assert.IsTrue(Msg.Contains('"path"'), 'message does not name path: ' + Msg);

  Msg := FillErrorOf(TFakeParams, '{"path":null,"pid":1}');
  Assert.IsTrue(Msg.Contains('"path"'), 'null path: message does not name path: ' + Msg);

  P := TFakeParams.Create;
  try
    FillFrom(P, '{"path":"x"}');
    Assert.AreEqual('x', P.Path);
  finally
    FreeAndNil(P);
  end;
end;


/// Text that is not a whole number used to become 0 without a word.
procedure TSerializerTests.Test_NonNumericTextForIntegerRaises;
var
  Msg: String;
begin
  Msg := FillErrorOf(TFakeTypedParams, '{"pid":"abc"}');
  Assert.IsTrue(Msg.Contains('"pid"'), 'pid "abc": message does not name pid: ' + Msg);

  Msg := FillErrorOf(TFakeTypedParams, '{"pid":"99999999999"}');
  Assert.IsTrue(Msg.Contains('"pid"'), 'pid too large for Integer: message does not name pid: ' + Msg);

  Msg := FillErrorOf(TFakeTypedParams, '{"big":"abc"}');
  Assert.IsTrue(Msg.Contains('"big"'), 'big "abc": message does not name big: ' + Msg);

  Msg := FillErrorOf(TFakeTypedParams, '{"pid":true}');
  Assert.IsTrue(Msg.Contains('"pid"'), 'pid true: message does not name pid: ' + Msg);
end;


/// A fraction for an integer is refused as an argument error that names the parameter.
procedure TSerializerTests.Test_FractionForIntegerRaises;
var
  Msg: String;
begin
  Msg := FillErrorOf(TFakeTypedParams, '{"pid":1.5}');
  Assert.IsTrue(Msg.Contains('"pid"'), 'message does not name pid: ' + Msg);

  Msg := FillErrorOf(TFakeTypedParams, '{"big":2.5}');
  Assert.IsTrue(Msg.Contains('"big"'), 'message does not name big: ' + Msg);
end;


/// A number or a word other than true/false for a Boolean used to become FALSE.
procedure TSerializerTests.Test_WrongTypeForBooleanRaises;
var
  Msg: String;
begin
  Msg := FillErrorOf(TFakeTypedParams, '{"checked":1}');
  Assert.IsTrue(Msg.Contains('"checked"'), 'checked 1: message does not name checked: ' + Msg);

  Msg := FillErrorOf(TFakeTypedParams, '{"checked":"yes"}');
  Assert.IsTrue(Msg.Contains('"checked"'), 'checked "yes": message does not name checked: ' + Msg);
end;


/// An object or an array has no text to give a String property.
procedure TSerializerTests.Test_ObjectOrArrayForStringRaises;
var
  Msg: String;
begin
  Msg := FillErrorOf(TFakeTypedParams, '{"path":{"a":1}}');
  Assert.IsTrue(Msg.Contains('"path"'), 'object: message does not name path: ' + Msg);

  Msg := FillErrorOf(TFakeTypedParams, '{"path":[1,2]}');
  Assert.IsTrue(Msg.Contains('"path"'), 'array: message does not name path: ' + Msg);
end;


/// The coercions chosen on purpose stay: digits as text for a number, "true"/"false" in any case for a Boolean,
/// a number or a Boolean for a String (its JSON text).
procedure TSerializerTests.Test_KeptCoercionsStillWork;
var
  P: TFakeTypedParams;
begin
  P := TFakeTypedParams.Create;
  try
    FillFrom(P, '{"pid":"42","big":"9000000000","scale":"1.5","checked":"TRUE"}');
    Assert.AreEqual(42, P.Pid);
    Assert.AreEqual(Int64(9000000000), P.Big);
    Assert.AreEqual(Double(1.5), P.Scale, 0.000001);
    Assert.IsTrue(P.Checked, 'checked "TRUE" must give TRUE');

    FillFrom(P, '{"checked":"false","path":42}');
    Assert.IsFalse(P.Checked, 'checked "false" must give FALSE');
    Assert.AreEqual('42', P.Path);

    FillFrom(P, '{"path":true,"checked":true,"scale":2}');
    Assert.AreEqual('true', P.Path);
    Assert.IsTrue(P.Checked);
    Assert.AreEqual(Double(2), P.Scale, 0.000001);
  finally
    FreeAndNil(P);
  end;
end;


/// An unknown enumeration name used to become the first value without a word. The error lists the valid names.
procedure TSerializerTests.Test_UnknownEnumNameRaisesListingNames;
var
  Msg: String;
begin
  Msg := FillErrorOf(TFakeEnumParams, '{"mode":"purple"}');
  Assert.IsTrue(Msg.Contains('"mode"'), 'message does not name mode: ' + Msg);
  Assert.IsTrue(Msg.Contains('fmAuto, fmMessage'), 'message does not list the valid names: ' + Msg);
end;


/// An ordinal outside the enumeration used to be stored as an invalid value.
procedure TSerializerTests.Test_OutOfRangeEnumOrdinalRaises;
var
  Msg: String;
begin
  Msg := FillErrorOf(TFakeEnumParams, '{"mode":7}');
  Assert.IsTrue(Msg.Contains('"mode"'), 'number 7: message does not name mode: ' + Msg);

  Msg := FillErrorOf(TFakeEnumParams, '{"mode":"7"}');
  Assert.IsTrue(Msg.Contains('"mode"'), 'text "7": message does not name mode: ' + Msg);
end;


/// A name or an ordinal in range sets the value; empty text keeps the value the property had.
procedure TSerializerTests.Test_EnumNameOrdinalAndEmptyText;
var
  P: TFakeEnumParams;
begin
  P := TFakeEnumParams.Create;
  try
    FillFrom(P, '{"mode":"fmMessage"}');
    Assert.IsTrue(P.Mode = fmMessage, 'name fmMessage');

    P.Mode := fmAuto;
    FillFrom(P, '{"mode":1}');
    Assert.IsTrue(P.Mode = fmMessage, 'ordinal 1');

    FillFrom(P, '{"mode":""}');
    Assert.IsTrue(P.Mode = fmMessage, 'empty text must keep fmMessage, got ordinal ' + IntToStr(Ord(P.Mode)));
  finally
    FreeAndNil(P);
  end;
end;


/// A record property used to be skipped without a word, so the tool ran without the argument the caller sent.
procedure TSerializerTests.Test_RecordPropertyRaisesNamingIt;
var
  Msg: String;
begin
  Msg := FillErrorOf(TFakeRecordParams, '{"pt":{"x":1}}');
  Assert.IsTrue(Msg.Contains('"pt"'), 'message does not name pt: ' + Msg);
end;


initialization
  TDUnitX.RegisterTestFixture(TSerializerTests);

end.
