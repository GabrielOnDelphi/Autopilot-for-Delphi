UNIT Tests.Mcp.Serializer;

(*=====================================================
   2026.05.19
   DUnitX tests for TMCPSerializer.Deserialize<T>.

   Confirms the case-insensitive lookup, the unknown-key error path, and the
   basic type coercion (string + integer). Covering the full coercion matrix
   (Int64, Float, Boolean, enums) is the schema generator's coverage zone —
   here we exercise only what our nine tool units actually use.
=====================================================*)

INTERFACE

USES
  DUnitX.TestFramework;

TYPE
  /// Same shape as the production TSetPropertyParams / etc.: one string Path,
  /// one Integer Pid. All public, written via default RTTI.
  TFakeParams = CLASS
  PRIVATE
    FPath: String;
    FPid : Integer;
  PUBLIC
    PROPERTY Path: String  READ FPath WRITE FPath;
    PROPERTY Pid : Integer READ FPid  WRITE FPid;
  END;

  [TestFixture]
  TSerializerTests = CLASS
  PUBLIC
    [Test] PROCEDURE Test_DeserializesPlainString;
    [Test] PROCEDURE Test_DeserializesPlainInteger;
    [Test] PROCEDURE Test_CaseInsensitiveLookup_UpperCaseKey;
    [Test] PROCEDURE Test_UnknownKeyRaisesEArgumentException;
    [Test] PROCEDURE Test_NilJsonReturnsFreshInstance;
    [Test] PROCEDURE Test_MissingKeyLeavesDefaultValue;
    [Test] PROCEDURE Test_NumericStringCoercesToInteger;
  END;


IMPLEMENTATION

USES
  System.SysUtils, System.JSON,
  MCPServer.Serializer;


PROCEDURE TSerializerTests.Test_DeserializesPlainString;
VAR
  Js: TJSONObject;
  P : TFakeParams;
BEGIN
  Js := TJSONObject.Create;
  TRY
    Js.AddPair('path', 'frmMain.btnOk');
    P := TMCPSerializer.Deserialize<TFakeParams>(Js);
    TRY
      Assert.AreEqual('frmMain.btnOk', P.Path);
    FINALLY
      P.Free;
    END;
  FINALLY
    Js.Free;
  END;
END;


PROCEDURE TSerializerTests.Test_DeserializesPlainInteger;
VAR
  Js: TJSONObject;
  P : TFakeParams;
BEGIN
  Js := TJSONObject.Create;
  TRY
    Js.AddPair('pid', TJSONNumber.Create(12345));
    P := TMCPSerializer.Deserialize<TFakeParams>(Js);
    TRY
      Assert.AreEqual(12345, P.Pid);
    FINALLY
      P.Free;
    END;
  FINALLY
    Js.Free;
  END;
END;


PROCEDURE TSerializerTests.Test_CaseInsensitiveLookup_UpperCaseKey;
VAR
  Js: TJSONObject;
  P : TFakeParams;
BEGIN
  Js := TJSONObject.Create;
  TRY
    Js.AddPair('PATH', 'X');
    P := TMCPSerializer.Deserialize<TFakeParams>(Js);
    TRY
      Assert.AreEqual('X', P.Path);
    FINALLY
      P.Free;
    END;
  FINALLY
    Js.Free;
  END;
END;


PROCEDURE TSerializerTests.Test_UnknownKeyRaisesEArgumentException;
VAR
  Js: TJSONObject;
BEGIN
  Js := TJSONObject.Create;
  TRY
    Js.AddPair('nonsense', TJSONNumber.Create(1));
    Assert.WillRaise(
      PROCEDURE
      BEGIN
        TMCPSerializer.Deserialize<TFakeParams>(Js).Free;
      END,
      EArgumentException,
      'Unknown key must raise EArgumentException');
  FINALLY
    Js.Free;
  END;
END;


PROCEDURE TSerializerTests.Test_NilJsonReturnsFreshInstance;
VAR
  P: TFakeParams;
BEGIN
  P := TMCPSerializer.Deserialize<TFakeParams>(NIL);
  TRY
    Assert.AreEqual('', P.Path);
    Assert.AreEqual(0, P.Pid);
  FINALLY
    P.Free;
  END;
END;


PROCEDURE TSerializerTests.Test_MissingKeyLeavesDefaultValue;
VAR
  Js: TJSONObject;
  P : TFakeParams;
BEGIN
  Js := TJSONObject.Create;
  TRY
    Js.AddPair('path', 'something');
    P := TMCPSerializer.Deserialize<TFakeParams>(Js);
    TRY
      Assert.AreEqual('something', P.Path);
      Assert.AreEqual(0, P.Pid, 'Pid was not in JSON; should stay 0');
    FINALLY
      P.Free;
    END;
  FINALLY
    Js.Free;
  END;
END;


PROCEDURE TSerializerTests.Test_NumericStringCoercesToInteger;
VAR
  Js: TJSONObject;
  P : TFakeParams;
BEGIN
  Js := TJSONObject.Create;
  TRY
    // GDK behavior: a JSON string holding digits is coerced to the property's
    // declared Integer type. Some clients send pid as a string. Match this.
    Js.AddPair('pid', '42');
    P := TMCPSerializer.Deserialize<TFakeParams>(Js);
    TRY
      Assert.AreEqual(42, P.Pid);
    FINALLY
      P.Free;
    END;
  FINALLY
    Js.Free;
  END;
END;


INITIALIZATION
  TDUnitX.RegisterTestFixture(TSerializerTests);

END.
