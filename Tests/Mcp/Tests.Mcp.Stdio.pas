unit Tests.Mcp.Stdio;

{=============================================================================================================
   2026.11.01
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for Autopilot.Mcp.Stdio: how one stdin line, as raw bytes, becomes the answer line.
   - Invalid UTF-8 is refused with -32700 instead of being processed with replaced characters.
   - Non-ASCII text (Latin, Romanian, CJK, and U+1F600, a UTF-16 surrogate pair) passes through unchanged,
     and the answer line stays pure ASCII.
   - This file is pure ASCII on purpose: every non-ASCII character is written as a #$ code.
=============================================================================================================}

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TStdioTests = class
  public
    [Setup] procedure Setup;

    [Test] procedure Test_Decode_InvalidUtf8_ReturnsFalse;
    [Test] procedure Test_Decode_ValidUtf8_ReturnsText;
    [Test] procedure Test_Decode_DropsLeadingBom;
    [Test] procedure Test_Decode_NonAscii_ExactText;
    [Test] procedure Test_ReadLineBytes_KeepsBytesUnchanged;
    [Test] procedure Test_AnswerLine_InvalidUtf8_Returns32700WithNullId;
    [Test] procedure Test_AnswerLine_NonAscii_ComesBackExactly;
  end;


implementation

uses
  System.SysUtils, System.IOUtils, System.JSON, System.Generics.Collections,
  Autopilot.Mcp.JsonRpc,
  Autopilot.Mcp.Stdio;

const
  /// e-acute (U+00E9), s-comma (U+0219), CJK "middle" (U+4E2D), grinning face (U+1F600 = surrogate pair D83D DE00)
  NonAsciiText = #$00E9#$0219#$4E2D#$D83D#$DE00;


/// The UTF-8 bytes of NonAsciiText, written out by hand.
function NonAsciiBytes: TBytes;
begin
  Result := TBytes.Create($C3, $A9,  $C8, $99,  $E4, $B8, $AD,  $F0, $9F, $98, $80);
end;


function AsciiBytes(const AText: String): TBytes;
begin
  Result := TEncoding.ASCII.GetBytes(AText);
end;


function HexOf(const ABytes: TBytes): String;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(ABytes) do
    Result := Result + IntToHex(ABytes[i], 2) + ' ';
end;


procedure AssertSameBytes(const AExpected, AActual: TBytes; const AWhat: String);
var
  i: Integer;
begin
  Assert.AreEqual(Length(AExpected), Length(AActual), AWhat + ': byte count. Expected ' + HexOf(AExpected) + ' got ' + HexOf(AActual));
  for i := 0 to High(AExpected) do
    Assert.AreEqual(Integer(AExpected[i]), Integer(AActual[i]), AWhat + ': byte ' + IntToStr(i) + '. Expected ' + HexOf(AExpected) + ' got ' + HexOf(AActual));
end;


/// FALSE and an empty line for ABytes; AWhat names the case in the failure message.
procedure AssertRefused(const ABytes: TBytes; const AWhat: String);
var
  Line: String;
begin
  Assert.IsFalse(TryDecodeUtf8Line(ABytes, Line), AWhat + ' (' + HexOf(ABytes) + ') was accepted as UTF-8');
  Assert.AreEqual('', Line, AWhat + ': the line must be empty when the bytes are refused');
end;


procedure TStdioTests.Setup;
begin
  ResetToolCache;
end;


procedure TStdioTests.Test_Decode_InvalidUtf8_ReturnsFalse;
begin
  AssertRefused(TBytes.Create($C3, $28),      'a lead byte followed by an ASCII byte');
  AssertRefused(TBytes.Create($FF),           'the byte FF, which never occurs in UTF-8');
  AssertRefused(TBytes.Create($F0, $9F, $98), 'a 4-byte sequence cut after 3 bytes');
  AssertRefused(TBytes.Create($ED, $A0, $80), 'an encoded UTF-16 surrogate (U+D800)');
  AssertRefused(TBytes.Create($C0, $AF),      'an overlong encoding of "/"');
  AssertRefused(AsciiBytes('{"jsonrpc":"2.0","id":1,"method":"ping","x":"') + TBytes.Create($FF) + AsciiBytes('"}'),
                'a JSON line with one FF byte inside a string');
end;


procedure TStdioTests.Test_Decode_ValidUtf8_ReturnsText;
const
  Json = '{"jsonrpc":"2.0","id":1,"method":"ping"}';
var
  Line: String;
begin
  Assert.IsTrue(TryDecodeUtf8Line(TBytes.Create($C3, $A9), Line), 'C3 A9 is valid UTF-8');
  Assert.AreEqual(String(#$00E9), Line);

  Assert.IsTrue(TryDecodeUtf8Line(AsciiBytes(Json), Line), 'an ASCII line is valid UTF-8');
  Assert.AreEqual(Json, Line);

  Assert.IsTrue(TryDecodeUtf8Line(NIL, Line), 'an empty line is valid UTF-8');
  Assert.AreEqual('', Line);
end;


/// PowerShell's pipe to a native program puts EF BB BF in front of the first line.
procedure TStdioTests.Test_Decode_DropsLeadingBom;
var
  Line: String;
begin
  Assert.IsTrue(TryDecodeUtf8Line(TBytes.Create($EF, $BB, $BF) + AsciiBytes('{"a":1}'), Line), 'BOM + ASCII');
  Assert.AreEqual('{"a":1}', Line);
end;


procedure TStdioTests.Test_Decode_NonAscii_ExactText;
var
  Line: String;
begin
  Assert.IsTrue(TryDecodeUtf8Line(NonAsciiBytes, Line), 'non-ASCII UTF-8 must be accepted');
  Assert.AreEqual(5, Length(Line), 'four characters, the last one a surrogate pair');
  Assert.AreEqual(NonAsciiText, Line);
end;


/// The stdio loop reads Input into a UTF8String so that Readln copies the bytes of a line unchanged. A conversion
/// there would turn invalid bytes into U+FFFD (EF BF BD) before TryDecodeUtf8Line could see them.
procedure TStdioTests.Test_ReadLineBytes_KeepsBytesUnchanged;
var
  FileName: String;
  F: TextFile;
  Line1, Line2, Expected1, Expected2: TBytes;
begin
  Expected1 := AsciiBytes('{"t":"') + NonAsciiBytes + AsciiBytes('"}');
  Expected2 := TBytes.Create($C3, $28, $FF);

  FileName := TPath.GetTempFileName;
  try
    TFile.WriteAllBytes(FileName, Expected1 + TBytes.Create(13, 10) + Expected2 + TBytes.Create(10));

    AssignFile(F, FileName);
    Reset(F);
    try
      SetTextCodePage(F, CP_UTF8);   // what EnableUtf8Io does to Input
      Line1 := ReadLineBytes(F);
      Line2 := ReadLineBytes(F);
    finally
      CloseFile(F);
    end;
  finally
    System.SysUtils.DeleteFile(FileName);
  end;

  AssertSameBytes(Expected1, Line1, 'valid non-ASCII line');
  AssertSameBytes(Expected2, Line2, 'invalid line');
end;


procedure TStdioTests.Test_AnswerLine_InvalidUtf8_Returns32700WithNullId;
var
  Resp: String;
  V: TJSONValue;
  Root, ErrObj: TJSONObject;
begin
  Resp := AnswerLine(AsciiBytes('{"jsonrpc":"2.0","id":1,"method":"ping","x":"') + TBytes.Create($FF) + AsciiBytes('"}'));
  V := TJSONObject.ParseJSONValue(Resp);
  try
    Assert.IsTrue(V is TJSONObject, 'the answer is not a JSON object: ' + Resp);
    Root := TJSONObject(V);
    Assert.IsTrue(Root.GetValue('error') is TJSONObject, 'the answer must be an error: ' + Resp);
    ErrObj := TJSONObject(Root.GetValue('error'));
    Assert.AreEqual(-32700, (ErrObj.GetValue('code') as TJSONNumber).AsInt, 'error.code: ' + Resp);
    Assert.IsTrue(Root.GetValue('id') is TJSONNull, 'id must be null: ' + Resp);
  finally
    FreeAndNil(V);
  end;
end;


/// A tools/call whose tool name is raw non-ASCII UTF-8 comes back with that exact name in the error text, and the
/// answer line is pure ASCII (System.JSON writes every character above 127 as \u escapes).
procedure TStdioTests.Test_AnswerLine_NonAscii_ComesBackExactly;
var
  Resp, Text: String;
  V: TJSONValue;
  Root, Res: TJSONObject;
  i: Integer;
begin
  Resp := AnswerLine(AsciiBytes('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"') + NonAsciiBytes
                   + AsciiBytes('","arguments":{}}}'));
  for i := 1 to Length(Resp) do
    Assert.IsTrue(Ord(Resp[i]) < 128, 'answer character ' + IntToStr(i) + ' is not ASCII: ' + Resp);

  V := TJSONObject.ParseJSONValue(Resp);
  try
    Assert.IsTrue(V is TJSONObject, 'the answer is not a JSON object: ' + Resp);
    Root := TJSONObject(V);
    if Root.GetValue('error') is TJSONObject
    then Text := TJSONObject(Root.GetValue('error')).GetValue('message').Value
    else
      begin
        Res := Root.GetValue('result') as TJSONObject;
        Assert.IsNotNull(Res, 'neither error nor result: ' + Resp);
        Text := ((Res.GetValue('content') as TJSONArray).Items[0] as TJSONObject).GetValue('text').Value;
      end;
    Assert.IsTrue(Text.Contains(NonAsciiText), 'the tool name did not come back unchanged: ' + Resp);
  finally
    FreeAndNil(V);
  end;
end;


initialization
  TDUnitX.RegisterTestFixture(TStdioTests);

end.
