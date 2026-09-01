unit Tests.Mcp.Serializer;

{=============================================================================================================
   2026.09
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for TMCPSerializer.Deserialize<T>: case-insensitive key lookup, unknown-key error path, basic type coercion (string, integer, numeric-string-to-integer).
=============================================================================================================}

interface

uses
  DUnitX.TestFramework;

type
  /// Same shape as the production TSetPropertyParams / etc.: one string Path,
  /// one Integer Pid. All public, written via default RTTI.
  TFakeParams = class
  private
    FPath: String;
    FPid : Integer;
  public
    property Path: String  read FPath write FPath;
    property Pid : Integer read FPid  write FPid;
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
  end;


implementation

uses
  System.SysUtils, System.JSON,
  MCPServer.Serializer;


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


initialization
  TDUnitX.RegisterTestFixture(TSerializerTests);

end.
