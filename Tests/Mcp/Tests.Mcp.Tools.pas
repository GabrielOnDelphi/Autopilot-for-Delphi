unit Tests.Mcp.Tools;

{=============================================================================================================
   2026.11.02
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for the MCP tool layer, driven through the JSON-RPC dispatcher the way Claude Code calls it.
   - Tests.exe links all fifteen tool units, so the tool registry is the production one.
   - No target is needed: most calls name a pid no target owns (UnknownPid), which exercises the
     -32099 target_not_running path whatever else runs on the machine. The screenshot and busy-pipe
     tests announce a fake target instead (TFakePipeBridge / TBusyPipe in a TPrivateDiscovery folder,
     Tests.Mcp.PipeClient) and call it with this process's own pid.
=============================================================================================================}

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TMcpToolTests = class
  public
    [Setup] procedure Setup;

    [Test] procedure Test_ListTree_UnknownPid_Returns32099WithRecipe;
    [Test] procedure Test_Attach_UnknownPid_ReturnsHintAndSetup;
    [Test] procedure Test_WaitFor_UnknownPid_FailsFast;
    [Test] procedure Test_ToolsListAndInstructions_AllAscii;
    [Test] procedure Test_FindBridgeFolder_PackageLayout;
    [Test] procedure Test_FindBridgeFolder_BuildFolderLayout;
    [Test] procedure Test_WiringSteps_NameTheBridgeFolder;
    [Test] procedure Test_FindGetItBridgeEntry_PicksOnlyTheCatalogBridgeFolder;
    [Test] procedure Test_WiringSteps_GetItInstall_AddsNoSecondCopy;
    [Test] procedure Test_WiringSteps_SayDpmNeedsNoFolder;
    [Test] procedure Test_Screenshot_ReturnsImageBlockThenTextBlock;
    [Test] procedure Test_Screenshot_FailedCapture_StaysOneTextBlock;
    [Test] procedure Test_Screenshot_ForwardsPathAndMaxWidthOnlyWhenGiven;
    [Test] procedure Test_ListTree_ForwardsFormAndFormsOnlyOnlyWhenGiven;
    [Test] procedure Test_ListTree_ForwardsPathOnlyWhenGiven;
    [Test] procedure Test_ListTree_ForwardsXAndYOnlyWhenBothGiven;
    [Test] procedure Test_ListTree_XY_AnswerWithoutX_IsError;
    [Test] procedure Test_ListTree_XWithoutY_IsError;
    [Test] procedure Test_SetCheckedAndReadProperty_ForwardIndexOnlyWhenGiven;
    [Test] procedure Test_CallMethod_ForwardsNameArgsAndTimeout;
    [Test] procedure Test_CallMethod_BadArguments_IsErrorNamingTheParameter;
    [Test] procedure Test_CallMethod_SchemaDeclaresArgsAsObject;
    [Test] procedure Test_DismissDialog_FileName_OldBridge_IsErrorAndNoButtonSent;
    [Test] procedure Test_DismissDialog_FileName_Refused_AnswersClickedFalse;
    [Test] procedure Test_BusyPipe_Returns32098;
    [Test] procedure Test_WaitFor_BusyPipe_Returns32098AtOnce;
  end;


implementation

uses
  Winapi.Windows,
  System.SysUtils, System.Classes, System.IOUtils, System.JSON, System.Diagnostics, System.Generics.Collections,
  System.NetEncoding,
  Autopilot.Bridge.Core,
  Autopilot.Mcp.JsonRpc,
  Autopilot.Mcp.PipeClient,
  Autopilot.Mcp.ToolBase,
  Tests.Mcp.PipeClient;

const
  UnknownPid = 2147483000;   // far above the process ids Windows hands out in practice

  // A 1x1 PNG in base64, cut the way the bridge sends it: TNetEncoding.Base64 puts a CRLF after every 76
  // characters (c:\Delphi\Delphi 13\source\rtl\common\System.NetEncoding.pas, kCharsPerLine / kLineSeparator).
  PngB64Line1 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9';
  PngB64Line2 = 'awAAAABJRU5ErkJggg==';


/// Call one tool through the dispatcher. Returns content[0].text; AIsError = the result's isError flag.
function CallTool(const AName, AArgsJson: String; OUT AIsError: Boolean): String;
var
  V: TJSONValue;
  Root, Result_: TJSONObject;
  Content: TJSONArray;
begin
  V := TJSONObject.ParseJSONValue(DispatchLine('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"'
                                               + AName + '","arguments":' + AArgsJson + '}}'));
  Assert.IsTrue(V is TJSONObject, 'tools/call answer is not a JSON object');
  Root := TJSONObject(V);
  try
    Result_ := Root.GetValue('result') as TJSONObject;
    Assert.IsNotNull(Result_, 'result missing');
    V := Result_.GetValue('isError');
    AIsError := (V is TJSONBool) and TJSONBool(V).AsBoolean;
    Content := Result_.GetValue('content') as TJSONArray;
    Assert.IsNotNull(Content, 'result.content missing');
    Assert.AreEqual(1, Content.Count, 'result.content must hold one item');
    Result := (Content.Items[0] as TJSONObject).GetValue('text').Value;
  finally
    FreeAndNil(Root);
  end;
end;


/// Call one tool through the dispatcher. Returns the whole parsed JSON-RPC answer; the caller frees it.
function CallToolRoot(const AName, AArgsJson: String): TJSONObject;
var
  V: TJSONValue;
begin
  V := TJSONObject.ParseJSONValue(DispatchLine('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"'
                                               + AName + '","arguments":' + AArgsJson + '}}'));
  if not (V is TJSONObject) then
  begin
    FreeAndNil(V);
    Assert.Fail('tools/call answer is not a JSON object');
  end;
  Result := TJSONObject(V);
end;


/// What the bridge answers a screenshot command with (Autopilot.Bridge.Vcl.HandleScreenshot), plus a
/// top-level probe field extraField, which the text block must keep (ExtractImage removes only "image").
function FakeScreenshotResponse: String;
var
  Root, Res: TJSONObject;
begin
  Root := TJSONObject.Create;
  try
    Root.AddPair('id', TJSONNumber.Create(1));
    Root.AddPair('ok', TJSONBool.Create(TRUE));
    Res := TJSONObject.Create;
    Root.AddPair('result', Res);
    Res.AddPair('form', 'frmFake');
    Res.AddPair('width', TJSONNumber.Create(321));
    Res.AddPair('height', TJSONNumber.Create(123));
    Res.AddPair('encoding', 'base64');
    Res.AddPair('format', 'png');
    Res.AddPair('image', PngB64Line1 + #13#10 + PngB64Line2);
    Root.AddPair('extraField', 'EXTRA-PROBE');
    Result := Root.ToJSON;
  finally
    FreeAndNil(Root);
  end;
end;


/// Parse a tool's {ok:false,error:{code,message}} text. Returns error.code; AMessage = error.message.
function ErrorCodeOf(const AText: String; OUT AMessage: String): Integer;
var
  V, ErrV: TJSONValue;
begin
  V := TJSONObject.ParseJSONValue(AText);
  try
    Assert.IsTrue(V is TJSONObject, 'tool text is not a JSON object: ' + AText);
    ErrV := TJSONObject(V).GetValue('error');
    Assert.IsTrue(ErrV is TJSONObject, 'tool text has no error object: ' + AText);
    Result   := (TJSONObject(ErrV).GetValue('code') as TJSONNumber).AsInt;
    AMessage := TJSONObject(ErrV).GetValue('message').Value;
  finally
    FreeAndNil(V);
  end;
end;


/// The first key or string value under AValue that holds a character above #127, described with its
/// JSON path and the text around it. '' when everything is 7-bit ASCII.
function FindNonAscii(AValue: TJSONValue; const APath: String): String;
var
  S: String;
  i, From: Integer;
  Pair: TJSONPair;
begin
  Result := '';
  if AValue is TJSONString then
  begin
    S := TJSONString(AValue).Value;
    for i := 1 to Length(S) do
      if Ord(S[i]) > 127 then
      begin
        From := i - 30;
        if From < 1 then From := 1;
        EXIT(APath + ': char $' + IntToHex(Ord(S[i]), 4) + ' in "' + Copy(S, From, 60) + '"');
      end;
  end
  else
    if AValue is TJSONObject then
      for Pair in TJSONObject(AValue) do
      begin
        Result := FindNonAscii(Pair.JsonString, APath + '.<key>');
        if Result = '' then Result := FindNonAscii(Pair.JsonValue, APath + '.' + Pair.JsonString.Value);
        if Result <> '' then EXIT;
      end
    else
      if AValue is TJSONArray then
        for i := 0 to TJSONArray(AValue).Count - 1 do
        begin
          Result := FindNonAscii(TJSONArray(AValue).Items[i], APath + '[' + IntToStr(i) + ']');
          if Result <> '' then EXIT;
        end;
end;


/// Create an empty file, and the folders above it.
procedure MakeEmptyFile(const AFileName: String);
var
  F: TFileStream;
begin
  ForceDirectories(ExtractFilePath(AFileName));
  F := TFileStream.Create(AFileName, fmCreate);
  FreeAndNil(F);
end;


procedure TMcpToolTests.Setup;
begin
  ResetToolCache;
end;


/// The case a new user meets first: the app is not running, or was built without the bridge. The answer
/// must be a coded error (so a script can tell it from a server bug) that carries the setup steps.
procedure TMcpToolTests.Test_ListTree_UnknownPid_Returns32099WithRecipe;
var
  Text, Msg: String;
  IsErr: Boolean;
begin
  Text := CallTool('list_tree', '{"pid":' + IntToStr(UnknownPid) + '}', IsErr);
  Assert.IsTrue(IsErr, 'isError must be TRUE: ' + Text);
  Assert.AreEqual(ErrTargetNotRunning, ErrorCodeOf(Text, Msg), 'wrong error code: ' + Text);
  Assert.IsTrue(Msg.Contains(IntToStr(UnknownPid)),      'message does not name the pid: ' + Msg);
  Assert.IsTrue(Msg.Contains('StartBridge'),             'message lacks the StartBridge step: ' + Msg);
  Assert.IsTrue(Msg.Contains('AUTOPILOT'),               'message lacks the AUTOPILOT define: ' + Msg);
  Assert.IsTrue(Msg.Contains('Autopilot.Bridge.Vcl'),    'message does not name the VCL bridge unit: ' + Msg);
  Assert.IsTrue(Msg.Contains('Autopilot.Bridge.Fmx'),    'message does not name the FMX bridge unit: ' + Msg);
end;


/// An empty target list is an answer, not an error - but it must say what to do next. And the setup steps
/// ride every attach answer: the server instructions only point at attach for them.
procedure TMcpToolTests.Test_Attach_UnknownPid_ReturnsHintAndSetup;
var
  Text, Hint, Setup: String;
  IsErr: Boolean;
  V: TJSONValue;
  Running: Integer;
begin
  Running := Length(ListTargets);
  Text := CallTool('attach', '{"pid":' + IntToStr(UnknownPid) + '}', IsErr);
  Assert.IsFalse(IsErr, 'an empty target list must not be flagged as an error: ' + Text);

  V := TJSONObject.ParseJSONValue(Text);
  try
    Assert.IsTrue(V is TJSONObject, 'attach answer is not a JSON object: ' + Text);
    Assert.AreEqual(0, (TJSONObject(V).GetValue('count') as TJSONNumber).AsInt, 'count: ' + Text);
    Assert.IsTrue(TJSONObject(V).GetValue('hint') is TJSONString, 'hint missing: ' + Text);
    Assert.IsTrue(TJSONObject(V).GetValue('setup') is TJSONString, 'setup missing: ' + Text);
    Hint  := TJSONObject(V).GetValue('hint').Value;
    Setup := TJSONObject(V).GetValue('setup').Value;
  finally
    FreeAndNil(V);
  end;

  Assert.IsTrue(Setup.Contains('StartBridge'),          'setup lacks the StartBridge step: ' + Setup);
  Assert.IsTrue(Setup.Contains('AUTOPILOT'),            'setup lacks the AUTOPILOT define: ' + Setup);
  Assert.IsTrue(Setup.Contains('Autopilot.Bridge.Vcl'), 'setup does not name the VCL bridge unit: ' + Setup);
  Assert.IsTrue(Setup.Contains('Autopilot.Bridge.Fmx'), 'setup does not name the FMX bridge unit: ' + Setup);

  // No target at all -> point at the setup steps. Other targets running -> point at them instead.
  if Running = 0
  then Assert.IsTrue(Hint.Contains('"setup"'), 'hint does not point at the setup steps: ' + Hint)
  else Assert.IsTrue(Hint.Contains('attach without pid'), 'hint does not point at the running targets: ' + Hint);
end;


/// wait_for polls through the same path as every tool. Once "no target" became an error answer instead of an
/// exception, a missing early exit would make it poll a target that does not exist until its timeout.
procedure TMcpToolTests.Test_WaitFor_UnknownPid_FailsFast;
var
  Text, Msg: String;
  IsErr: Boolean;
  Watch: TStopwatch;
begin
  Watch := TStopwatch.StartNew;
  Text := CallTool('wait_for', '{"path":"frmMain.lblStatus","expectedText":"done","timeoutMs":10000,"pid":'
                               + IntToStr(UnknownPid) + '}', IsErr);
  Watch.Stop;
  Assert.IsTrue(IsErr, 'isError must be TRUE: ' + Text);
  Assert.AreEqual(ErrTargetNotRunning, ErrorCodeOf(Text, Msg), 'wrong error code: ' + Text);
  Assert.IsTrue(Msg.Contains('StartBridge'), 'message lacks the bridge-wiring steps: ' + Msg);
  Assert.IsTrue(Watch.ElapsedMilliseconds < 5000,
                'wait_for took ' + IntToStr(Watch.ElapsedMilliseconds) + ' ms: it polled on instead of failing fast');
end;


/// A .pas file saved without a UTF-8 BOM is compiled in the ANSI code page, so an em dash in it reaches the AI as
/// three garbage characters. The tool list and the server instructions stay pure ASCII to rule that out for good.
procedure TMcpToolTests.Test_ToolsListAndInstructions_AllAscii;
var
  V: TJSONValue;
  Root, Result_: TJSONObject;
  Tools: TJSONArray;
begin
  V := TJSONObject.ParseJSONValue(DispatchLine('{"jsonrpc":"2.0","id":5,"method":"tools/list"}'));
  Assert.IsTrue(V is TJSONObject, 'tools/list answer is not a JSON object');
  Root := TJSONObject(V);
  try
    Result_ := Root.GetValue('result') as TJSONObject;
    Assert.IsNotNull(Result_, 'result missing');
    Tools := Result_.GetValue('tools') as TJSONArray;
    Assert.IsNotNull(Tools, 'result.tools missing');
    Assert.AreEqual(15, Tools.Count, 'tool count');
    Assert.AreEqual('', FindNonAscii(Tools, 'tools'), 'non-ASCII character in the tool list');
  finally
    FreeAndNil(Root);
  end;

  V := TJSONObject.ParseJSONValue(DispatchLine('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'));
  Assert.IsTrue(V is TJSONObject, 'initialize answer is not a JSON object');
  Root := TJSONObject(V);
  try
    Result_ := Root.GetValue('result') as TJSONObject;
    Assert.IsNotNull(Result_, 'result missing');
    Assert.IsTrue(Result_.GetValue('instructions') is TJSONString, 'result.instructions missing');
    Assert.AreEqual('', FindNonAscii(Result_.GetValue('instructions'), 'instructions'), 'non-ASCII character in the instructions');
  finally
    FreeAndNil(Root);
  end;
end;


/// The setup steps name the bridge folder only if it really is on disk, in the layout of the Autopilot package
/// (Source\McpServer\Autopilot.Mcp.exe beside Source\Bridge\). The retired release-package layout
/// (Autopilot.Mcp.exe beside Bridge\) is no longer searched.
procedure TMcpToolTests.Test_FindBridgeFolder_PackageLayout;
var
  Root: String;
begin
  Root := TPath.Combine(TPath.GetTempPath, 'AutopilotBridgeProbe-' + TGUID.NewGuid.ToString);
  try
    ForceDirectories(Root + '\Source\McpServer');
    Assert.AreEqual('', FindBridgeFolder(Root + '\Source\McpServer\'), 'reported a bridge folder that does not exist');
    Assert.AreEqual('', FindBridgeFolder(''), 'an empty EXE folder must find nothing');

    MakeEmptyFile(Root + '\Source\Bridge\Autopilot.Bridge.Vcl.pas');
    Assert.AreEqual(Root + '\Source\Bridge', FindBridgeFolder(Root + '\Source\McpServer\'), 'package layout');
    Assert.AreEqual(Root + '\Source\Bridge', FindBridgeFolder(Root + '\Source\McpServer'),  'package layout, EXE folder given without a trailing backslash');

    MakeEmptyFile(Root + '\Bridge\Autopilot.Bridge.Vcl.pas');
    Assert.AreEqual('', FindBridgeFolder(Root + '\'), 'the retired layout (EXE beside Bridge\) must find nothing');
  finally
    TDirectory.Delete(Root, TRUE);
  end;
end;


/// A build of the cloned repository runs from Source\McpServer\Win32_<config>\, two levels below Source\Bridge\.
procedure TMcpToolTests.Test_FindBridgeFolder_BuildFolderLayout;
var
  Root: String;
begin
  Root := TPath.Combine(TPath.GetTempPath, 'AutopilotBridgeProbe-' + TGUID.NewGuid.ToString);
  try
    ForceDirectories(Root + '\Source\McpServer\Win32_Release');
    Assert.AreEqual('', FindBridgeFolder(Root + '\Source\McpServer\Win32_Release\'), 'reported a bridge folder that does not exist');

    MakeEmptyFile(Root + '\Source\Bridge\Autopilot.Bridge.Vcl.pas');
    Assert.AreEqual(Root + '\Source\Bridge', FindBridgeFolder(Root + '\Source\McpServer\Win32_Release\'), 'build folder layout');
    Assert.AreEqual(Root + '\Source\Bridge', FindBridgeFolder(Root + '\Source\McpServer\Win32_Release'),  'build folder layout, no trailing backslash');
  finally
    TDirectory.Delete(Root, TRUE);
  end;
end;


/// A found folder is named in step 1. With none found, step 1 still says which folder to look for,
/// and where the bridge source comes from for a reader who has none (the demo download carries no bridge).
procedure TMcpToolTests.Test_WiringSteps_NameTheBridgeFolder;
var
  Steps: String;
begin
  Steps := BridgeWiringStepsFor('C:\Tools\Autopilot\Bridge');
  Assert.IsTrue(Steps.Contains('Put the folder C:\Tools\Autopilot\Bridge '), 'step 1 does not name the folder that was found: ' + Steps);
  Assert.IsTrue(Steps.Contains('StartBridge'), 'the StartBridge step is missing: ' + Steps);

  Steps := BridgeWiringStepsFor('');
  Assert.IsTrue(Steps.Contains('Autopilot.Bridge.Vcl.pas'), 'with no folder found, step 1 does not name the file to look for: ' + Steps);
  Assert.IsTrue(Steps.Contains('the Source\Bridge folder of the Autopilot package'), 'with no folder found, step 1 does not name the package folder: ' + Steps);
  Assert.IsTrue(Steps.Contains('public on GitHub: https://github.com/GabrielOnDelphi/Autopilot-for-Delphi'), 'with no folder found, step 1 does not say where the bridge source comes from: ' + Steps);
  Assert.IsFalse(Steps.Contains('paid seat'), 'the steps must not tie the bridge source to a paid seat: ' + Steps);
  Assert.IsFalse(Steps.ToLower.Contains('repository'), 'the steps must not mention a repository: ' + Steps);
  Assert.IsFalse(Steps.Contains('release package'), 'the steps must not mention the retired release package: ' + Steps);
  Assert.IsTrue(Steps.Contains('StartBridge'), 'the StartBridge step is missing: ' + Steps);
end;


/// The entry is the one a real GetIt install wrote (measured on Delphi 13: AddOptionPath of the
/// GetIt entry AutopilotForDelphi, registry value Library\Win32\Search Path).
procedure TMcpToolTests.Test_FindGetItBridgeEntry_PicksOnlyTheCatalogBridgeFolder;
const
  GetItEntry = '$(BDSCatalogRepository)\AutopilotForDelphi\Autopilot-for-Delphi-3.8.0\Source\Bridge\';
begin
  Assert.AreEqual(GetItEntry, FindGetItBridgeEntry('$(BDSLIB)\$(Platform)\release;' + GetItEntry + ';$(BDS)\source\DUnitX'), 'entry in the middle');
  Assert.AreEqual(GetItEntry, FindGetItBridgeEntry(GetItEntry), 'the only entry');
  Assert.AreEqual('$(BDSCatalogRepository)\AutopilotForDelphi\Autopilot-for-Delphi-3.9.0\Source\Bridge', FindGetItBridgeEntry('c:\x;$(BDSCatalogRepository)\AutopilotForDelphi\Autopilot-for-Delphi-3.9.0\Source\Bridge'), 'no trailing backslash, other version');
  Assert.AreEqual('', FindGetItBridgeEntry(''), 'empty Library Path');
  Assert.AreEqual('', FindGetItBridgeEntry('C:\Projects\Autopilot\Source\Bridge;$(BDS)\lib'), 'a bridge folder that GetIt did not install');
  Assert.AreEqual('', FindGetItBridgeEntry('$(BDSCatalogRepository)\SomeOther\Source;$(BDSCatalogRepository)\X\Source\Bridges'), 'catalog entries of other packages');
end;


/// The Library Path reaches every project, so with a GetIt install the AI must add no folder,
/// not even the one found beside the MCP server: that would put a second copy of the bridge on the paths.
procedure TMcpToolTests.Test_WiringSteps_GetItInstall_AddsNoSecondCopy;
const
  GetItEntry = '$(BDSCatalogRepository)\AutopilotForDelphi\Autopilot-for-Delphi-3.8.0\Source\Bridge\';
var
  Steps: String;
begin
  Steps := BridgeWiringStepsFor('C:\Tools\Autopilot\Bridge', GetItEntry);
  Assert.IsTrue(Steps.Contains(GetItEntry), 'step 1 does not name the GetIt Library Path entry: ' + Steps);
  Assert.IsTrue(Steps.Contains('GetIt'), 'step 1 does not say the bridge came through GetIt: ' + Steps);
  Assert.IsFalse(Steps.Contains('Put the folder'), 'step 1 still asks for a folder on the search path: ' + Steps);
  Assert.IsTrue(Steps.Contains('Autopilot.Bridge.Vcl'), 'the uses clause part of step 1 is missing: ' + Steps);
  Assert.IsTrue(Steps.Contains('StartBridge'), 'the StartBridge step is missing: ' + Steps);
  Assert.IsTrue(Steps.Contains('AUTOPILOT'), 'the define step is missing: ' + Steps);
end;


/// The MCP server cannot see the project, so every variant says how to spot a DPM install
/// (dpm install writes the package id into the .dproj and puts the bridge on $(DPMSearch)).
procedure TMcpToolTests.Test_WiringSteps_SayDpmNeedsNoFolder;
var
  Variants: TArray<String>;
  Steps: String;
begin
  Variants := [BridgeWiringStepsFor('C:\Tools\Autopilot\Bridge'), BridgeWiringStepsFor(''),
               BridgeWiringStepsFor('', '$(BDSCatalogRepository)\AutopilotForDelphi\Autopilot-for-Delphi-3.8.0\Source\Bridge\')];
  for Steps in Variants do
    begin
      Assert.IsTrue(Steps.Contains('GabrielMoraru.Autopilot'), 'the DPM package id is missing: ' + Steps);
      Assert.IsTrue(Steps.Contains('$(DPMSearch)'), 'the DPM search path is missing: ' + Steps);
    end;
end;


/// The picture must reach the AI host as an MCP image content block (type "image", raw base64 in "data",
/// "mimeType"), not as base64 inside text - a host shows only the first as a picture, and a 64 KB text
/// result is written to a file instead (Kai, 2026-08-25). Every other field of the bridge's answer,
/// the probe field extraField included, follows in a text block, without the base64.
procedure TMcpToolTests.Test_Screenshot_ReturnsImageBlockThenTextBlock;
var
  Fake: TFakePipeBridge;
  Discovery: TPrivateDiscovery;
  Root, Result_, Block, Answer, Res: TJSONObject;
  Content: TJSONArray;
  V: TJSONValue;
  Data, Text: String;
  Png: TBytes;
begin
  Fake := TFakePipeBridge.Create(FakeScreenshotResponse);
  try
    Fake.WaitUntilReady;
    Discovery := TPrivateDiscovery.Create(Fake.PipeName);
    try
      Root := CallToolRoot('screenshot', '{"pid":' + IntToStr(GetCurrentProcessId) + '}');
    finally
      FreeAndNil(Discovery);
    end;
  finally
    FreeAndNil(Fake);
  end;

  try
    Result_ := Root.GetValue('result') as TJSONObject;
    Assert.IsNotNull(Result_, 'result missing: ' + Root.ToJSON);
    V := Result_.GetValue('isError');
    Assert.IsFalse((V is TJSONBool) and TJSONBool(V).AsBoolean, 'isError set: ' + Result_.ToJSON);
    Content := Result_.GetValue('content') as TJSONArray;
    Assert.IsNotNull(Content, 'result.content missing');
    Assert.AreEqual(2, Content.Count, 'content must hold an image block and a text block: ' + Result_.ToJSON);

    // Block 1: the picture
    Block := Content.Items[0] as TJSONObject;
    Assert.AreEqual('image', Block.GetValue('type').Value, 'first block');
    Assert.AreEqual('image/png', Block.GetValue('mimeType').Value, 'mimeType');
    Data := Block.GetValue('data').Value;
    Assert.AreEqual(PngB64Line1 + PngB64Line2, Data, 'data must be the base64 without the line break');
    Png := TNetEncoding.Base64.DecodeStringToBytes(Data);
    Assert.IsTrue((Length(Png) > 8) and (Png[0] = $89) and (Png[1] = Ord('P')) and (Png[2] = Ord('N')) and (Png[3] = Ord('G')),
                  'data does not decode to a PNG');

    // Block 2: the rest of the answer
    Block := Content.Items[1] as TJSONObject;
    Assert.AreEqual('text', Block.GetValue('type').Value, 'second block');
    Text := Block.GetValue('text').Value;
    Assert.IsFalse(Text.Contains(PngB64Line1) or Text.Contains(PngB64Line2), 'base64 left in the text block: ' + Text);
    V := TJSONObject.ParseJSONValue(Text);
    try
      Assert.IsTrue(V is TJSONObject, 'the text block is not JSON: ' + Text);
      Answer := TJSONObject(V);
      Assert.IsTrue((Answer.GetValue('ok') is TJSONBool) and TJSONBool(Answer.GetValue('ok')).AsBoolean, 'ok: ' + Text);
      Res := Answer.GetValue('result') as TJSONObject;
      Assert.IsNotNull(Res, 'result missing in the text block: ' + Text);
      Assert.IsNull(Res.GetValue('image'), 'the image field is still in the text block: ' + Text);
      Assert.AreEqual('frmFake', Res.GetValue('form').Value, 'form: ' + Text);
      Assert.IsTrue(Res.GetValue('width') is TJSONNumber, 'width missing: ' + Text);
      Assert.AreEqual(321, TJSONNumber(Res.GetValue('width')).AsInt, 'width');
      Assert.IsTrue(Res.GetValue('height') is TJSONNumber, 'height missing: ' + Text);
      Assert.AreEqual(123, TJSONNumber(Res.GetValue('height')).AsInt, 'height');
      Assert.IsTrue(Answer.GetValue('extraField') is TJSONString, 'extraField lost: ' + Text);
      Assert.AreEqual('EXTRA-PROBE', Answer.GetValue('extraField').Value, 'extraField');
    finally
      FreeAndNil(V);
    end;
  finally
    FreeAndNil(Root);
  end;
end;


/// A screenshot that failed in the target carries no picture: the answer stays one text block, flagged
/// isError, with the bridge's error code.
procedure TMcpToolTests.Test_Screenshot_FailedCapture_StaysOneTextBlock;
var
  Fake: TFakePipeBridge;
  Discovery: TPrivateDiscovery;
  Text, Msg: String;
  IsErr: Boolean;
begin
  Fake := TFakePipeBridge.Create('{"id":1,"ok":false,"error":{"code":-32001,"message":"no form named frmNope"}}');
  try
    Fake.WaitUntilReady;
    Discovery := TPrivateDiscovery.Create(Fake.PipeName);
    try
      Text := CallTool('screenshot', '{"form":"frmNope","pid":' + IntToStr(GetCurrentProcessId) + '}', IsErr);
    finally
      FreeAndNil(Discovery);
    end;
  finally
    FreeAndNil(Fake);
  end;

  Assert.IsTrue(IsErr, 'isError must be TRUE: ' + Text);
  Assert.AreEqual(ErrNotFound, ErrorCodeOf(Text, Msg), 'wrong error code: ' + Text);
  Assert.IsTrue(Msg.Contains('frmNope'), 'message does not name the form: ' + Msg);
end;


/// Calls screenshot with AArgsJson (pid added) against a fake target. Returns the args object of the request the
/// fake target received; the caller frees it.
function SentScreenshotArgs(const AArgsJson: String): TJSONObject;
var
  Fake: TFakePipeBridge;
  Discovery: TPrivateDiscovery;
  Root: TJSONObject;
  Sent: String;
  V: TJSONValue;
begin
  Fake := TFakePipeBridge.Create(FakeScreenshotResponse);
  try
    Fake.WaitUntilReady;
    Discovery := TPrivateDiscovery.Create(Fake.PipeName);
    try
      Root := CallToolRoot('screenshot', '{"pid":' + IntToStr(GetCurrentProcessId) + AArgsJson + '}');
      FreeAndNil(Root);
    finally
      FreeAndNil(Discovery);
    end;
    Sent := Fake.SawRequest;
  finally
    FreeAndNil(Fake);
  end;

  V := TJSONObject.ParseJSONValue(Sent);
  try
    Assert.IsTrue(V is TJSONObject, 'the fake target received no JSON request: ' + Sent);
    Assert.AreEqual('screenshot', TJSONObject(V).GetValue('cmd').Value, 'cmd: ' + Sent);
    Assert.IsTrue(TJSONObject(V).GetValue('args') is TJSONObject, 'args missing: ' + Sent);
    Result := TJSONObject(TJSONObject(V).GetValue('args').Clone);
  finally
    FreeAndNil(V);
  end;
end;


/// path and maxWidth reach the bridge only when the caller gives them, so a call without them sends the request
/// every older server sent, and an older bridge answers it as before.
procedure TMcpToolTests.Test_Screenshot_ForwardsPathAndMaxWidthOnlyWhenGiven;
var
  Args: TJSONObject;
begin
  Args := SentScreenshotArgs(',"form":"frmFake","path":"frmFake.pnlBox","maxWidth":640');
  try
    Assert.IsTrue(Args.GetValue('path') is TJSONString, 'path not forwarded: ' + Args.ToJSON);
    Assert.AreEqual('frmFake.pnlBox', Args.GetValue('path').Value, 'path');
    Assert.IsTrue(Args.GetValue('maxWidth') is TJSONNumber, 'maxWidth not forwarded as a number: ' + Args.ToJSON);
    Assert.AreEqual(640, TJSONNumber(Args.GetValue('maxWidth')).AsInt, 'maxWidth');
    Assert.AreEqual('frmFake', Args.GetValue('form').Value, 'form');
  finally
    FreeAndNil(Args);
  end;

  Args := SentScreenshotArgs(',"form":"frmFake"');
  try
    Assert.AreEqual(1, Args.Count, 'only form may be sent when path and maxWidth are not given: ' + Args.ToJSON);
    Assert.AreEqual('frmFake', Args.GetValue('form').Value, 'form');
  finally
    FreeAndNil(Args);
  end;

  // A negative maxWidth goes to the bridge, which answers -32600; the server does not drop it.
  Args := SentScreenshotArgs(',"maxWidth":-5');
  try
    Assert.IsTrue(Args.GetValue('maxWidth') is TJSONNumber, 'a negative maxWidth must be forwarded: ' + Args.ToJSON);
    Assert.AreEqual(-5, TJSONNumber(Args.GetValue('maxWidth')).AsInt, 'negative maxWidth');
  finally
    FreeAndNil(Args);
  end;
end;


/// Calls list_tree with AArgsJson (pid added) against a fake target. Returns the args object of the request the
/// fake target received; the caller frees it.
function SentListTreeArgs(const AArgsJson: String): TJSONObject;
var
  Fake: TFakePipeBridge;
  Discovery: TPrivateDiscovery;
  Root: TJSONObject;
  Sent: String;
  V: TJSONValue;
begin
  Fake := TFakePipeBridge.Create('{"id":1,"ok":true,"result":{"components":[]}}');
  try
    Fake.WaitUntilReady;
    Discovery := TPrivateDiscovery.Create(Fake.PipeName);
    try
      Root := CallToolRoot('list_tree', '{"pid":' + IntToStr(GetCurrentProcessId) + AArgsJson + '}');
      FreeAndNil(Root);
    finally
      FreeAndNil(Discovery);
    end;
    Sent := Fake.SawRequest;
  finally
    FreeAndNil(Fake);
  end;

  V := TJSONObject.ParseJSONValue(Sent);
  try
    Assert.IsTrue(V is TJSONObject, 'the fake target received no JSON request: ' + Sent);
    Assert.AreEqual('list_tree', TJSONObject(V).GetValue('cmd').Value, 'cmd: ' + Sent);
    Assert.IsTrue(TJSONObject(V).GetValue('args') is TJSONObject, 'args missing: ' + Sent);
    Result := TJSONObject(TJSONObject(V).GetValue('args').Clone);
  finally
    FreeAndNil(V);
  end;
end;


/// form and formsOnly reach the bridge only when the caller gives them (form not empty, formsOnly TRUE), so a call
/// without them sends the request every older server sent: an empty args object.
procedure TMcpToolTests.Test_ListTree_ForwardsFormAndFormsOnlyOnlyWhenGiven;
var
  Args: TJSONObject;
begin
  Args := SentListTreeArgs(',"form":"frmFake","formsOnly":true');
  try
    Assert.IsTrue(Args.GetValue('form') is TJSONString, 'form not forwarded: ' + Args.ToJSON);
    Assert.AreEqual('frmFake', Args.GetValue('form').Value, 'form');
    Assert.IsTrue(Args.GetValue('formsOnly') is TJSONBool, 'formsOnly not forwarded as a Boolean: ' + Args.ToJSON);
    Assert.IsTrue(TJSONBool(Args.GetValue('formsOnly')).AsBoolean, 'formsOnly must be true');
  finally
    FreeAndNil(Args);
  end;

  Args := SentListTreeArgs('');
  try
    Assert.AreEqual(0, Args.Count, 'nothing may be sent when form and formsOnly are not given: ' + Args.ToJSON);
  finally
    FreeAndNil(Args);
  end;

  Args := SentListTreeArgs(',"form":"","formsOnly":false');
  try
    Assert.AreEqual(0, Args.Count, 'an empty form and formsOnly false must not be sent: ' + Args.ToJSON);
  finally
    FreeAndNil(Args);
  end;
end;


/// Calls list_tree with AArgsJson (pid added) against a fake target that answers AAnswer. Returns the tool's text;
/// AIsErr is the isError flag.
function ListTreeAgainst(const AAnswer, AArgsJson: String; OUT AIsErr: Boolean): String;
var
  Fake: TFakePipeBridge;
  Discovery: TPrivateDiscovery;
begin
  Fake := TFakePipeBridge.Create(AAnswer);
  try
    Fake.WaitUntilReady;
    Discovery := TPrivateDiscovery.Create(Fake.PipeName);
    try
      Result := CallTool('list_tree', '{"pid":' + IntToStr(GetCurrentProcessId) + AArgsJson + '}', AIsErr);
    finally
      FreeAndNil(Discovery);
    end;
  finally
    FreeAndNil(Fake);
  end;
end;


/// x and y reach the bridge only when both are given (0 is a valid coordinate), so a call without them sends the
/// request every older server sent.
procedure TMcpToolTests.Test_ListTree_ForwardsXAndYOnlyWhenBothGiven;
var
  Args: TJSONObject;
begin
  Args := SentListTreeArgs(',"form":"frmFake","x":10,"y":0');
  try
    Assert.IsTrue(Args.GetValue('x') is TJSONNumber, 'x not forwarded: ' + Args.ToJSON);
    Assert.AreEqual(10, TJSONNumber(Args.GetValue('x')).AsInt, 'x');
    Assert.IsTrue(Args.GetValue('y') is TJSONNumber, 'y = 0 not forwarded: ' + Args.ToJSON);
    Assert.AreEqual(0, TJSONNumber(Args.GetValue('y')).AsInt, 'y');
  finally
    FreeAndNil(Args);
  end;

  Args := SentListTreeArgs(',"form":"frmFake"');
  try
    Assert.IsNull(Args.GetValue('x'), 'x may not be sent when it is not given: ' + Args.ToJSON);
    Assert.IsNull(Args.GetValue('y'), 'y may not be sent when it is not given: ' + Args.ToJSON);
  finally
    FreeAndNil(Args);
  end;
end;


{ An older bridge ignores x and y and returns the whole form: without the answer field x the tool must
  answer isError instead of passing on a tree the AI would read as the hit. The answer of a new bridge passes. }
procedure TMcpToolTests.Test_ListTree_XY_AnswerWithoutX_IsError;
var
  IsErr: Boolean;
  Text: String;
begin
  Text := ListTreeAgainst('{"id":1,"ok":true,"result":{"components":[{"form":"frmFake","name":"frmFake","path":"frmFake","class":"TForm"}]}}',
                          ',"form":"frmFake","x":10,"y":20', IsErr);
  Assert.IsTrue(IsErr, 'an answer without x must be isError: ' + Text);
  Assert.IsTrue(Text.Contains('older than this MCP server'), 'the error must say the bridge is older than the MCP server: ' + Text);

  Text := ListTreeAgainst('{"id":1,"ok":true,"result":{"components":[],"x":10,"y":20}}',
                          ',"form":"frmFake","x":10,"y":20', IsErr);
  Assert.IsFalse(IsErr, 'the answer of a bridge that knows x and y must pass: ' + Text);
end;


/// x without y (or y without x) is refused by the tool itself.
procedure TMcpToolTests.Test_ListTree_XWithoutY_IsError;
var
  IsErr: Boolean;
  Text: String;
begin
  Text := ListTreeAgainst('{"id":1,"ok":true,"result":{"components":[],"x":10,"y":20}}', ',"form":"frmFake","x":10', IsErr);
  Assert.IsTrue(IsErr, 'x without y must be isError: ' + Text);
  Assert.IsTrue(Text.Contains('together'), 'the tool itself must refuse it, not an unknown-parameter error: ' + Text);
  Text := ListTreeAgainst('{"id":1,"ok":true,"result":{"components":[],"x":10,"y":20}}', ',"form":"frmFake","y":10', IsErr);
  Assert.IsTrue(IsErr, 'y without x must be isError: ' + Text);
  Assert.IsTrue(Text.Contains('together'), 'the tool itself must refuse it, not an unknown-parameter error: ' + Text);
end;


/// path reaches the bridge only when it is not empty, so a call without it sends an empty args object, as before.
procedure TMcpToolTests.Test_ListTree_ForwardsPathOnlyWhenGiven;
var
  Args: TJSONObject;
begin
  Args := SentListTreeArgs(',"path":"frmFake.pnlA"');
  try
    Assert.IsTrue(Args.GetValue('path') is TJSONString, 'path not forwarded: ' + Args.ToJSON);
    Assert.AreEqual('frmFake.pnlA', Args.GetValue('path').Value, 'path');
  finally
    FreeAndNil(Args);
  end;

  Args := SentListTreeArgs(',"path":""');
  try
    Assert.AreEqual(0, Args.Count, 'an empty path must not be sent: ' + Args.ToJSON);
  finally
    FreeAndNil(Args);
  end;
end;


/// Calls the tool ATool with AArgsJson (pid added) against a fake target that answers an empty result.
/// Returns the args object of the request the fake target received; the caller frees it.
function SentToolArgs(const ATool, AArgsJson: String): TJSONObject;
var
  Fake: TFakePipeBridge;
  Discovery: TPrivateDiscovery;
  Root: TJSONObject;
  Sent: String;
  V: TJSONValue;
begin
  Fake := TFakePipeBridge.Create('{"id":1,"ok":true,"result":{}}');
  try
    Fake.WaitUntilReady;
    Discovery := TPrivateDiscovery.Create(Fake.PipeName);
    try
      Root := CallToolRoot(ATool, '{"pid":' + IntToStr(GetCurrentProcessId) + AArgsJson + '}');
      FreeAndNil(Root);
    finally
      FreeAndNil(Discovery);
    end;
    Sent := Fake.SawRequest;
  finally
    FreeAndNil(Fake);
  end;

  V := TJSONObject.ParseJSONValue(Sent);
  try
    Assert.IsTrue(V is TJSONObject, 'the fake target received no JSON request: ' + Sent);
    Assert.AreEqual(ATool, TJSONObject(V).GetValue('cmd').Value, 'cmd: ' + Sent);
    Assert.IsTrue(TJSONObject(V).GetValue('args') is TJSONObject, 'args missing: ' + Sent);
    Result := TJSONObject(TJSONObject(V).GetValue('args').Clone);
  finally
    FreeAndNil(V);
  end;
end;


/// index reaches the bridge only when the caller gives it, and 0 is a real index, so a call without it sends the
/// request every older server sent.
procedure TMcpToolTests.Test_SetCheckedAndReadProperty_ForwardIndexOnlyWhenGiven;
var
  Args: TJSONObject;
begin
  Args := SentToolArgs('set_checked', ',"path":"frmFake.clb","checked":true,"index":0');
  try
    Assert.IsTrue(Args.GetValue('index') is TJSONNumber, 'set_checked: index 0 not forwarded as a number: ' + Args.ToJSON);
    Assert.AreEqual(0, TJSONNumber(Args.GetValue('index')).AsInt, 'set_checked: index');
  finally
    FreeAndNil(Args);
  end;

  Args := SentToolArgs('set_checked', ',"path":"frmFake.chk","checked":false');
  try
    Assert.AreEqual('{"path":"frmFake.chk","checked":false}', Args.ToJSON, 'set_checked without index must send what older servers sent');
  finally
    FreeAndNil(Args);
  end;

  Args := SentToolArgs('read_property', ',"path":"frmFake.clb","propName":"Checked","index":2');
  try
    Assert.IsTrue(Args.GetValue('index') is TJSONNumber, 'read_property: index not forwarded as a number: ' + Args.ToJSON);
    Assert.AreEqual(2, TJSONNumber(Args.GetValue('index')).AsInt, 'read_property: index');
  finally
    FreeAndNil(Args);
  end;

  Args := SentToolArgs('read_property', ',"path":"frmFake.btn","propName":"Tag"');
  try
    Assert.AreEqual('{"path":"frmFake.btn","propName":"Tag"}', Args.ToJSON, 'read_property without index must send what older servers sent');
  finally
    FreeAndNil(Args);
  end;
end;


/// Calls call_method with AArgsJson (pid added) against a fake target. Returns the whole request the fake target
/// received; the caller frees it.
function SentCallMethodRequest(const AArgsJson: String): TJSONObject;
var
  Fake: TFakePipeBridge;
  Discovery: TPrivateDiscovery;
  Root: TJSONObject;
  Sent: String;
  V: TJSONValue;
begin
  Fake := TFakePipeBridge.Create('{"id":1,"ok":true,"result":{"name":"demo.x","result":null}}');
  try
    Fake.WaitUntilReady;
    Discovery := TPrivateDiscovery.Create(Fake.PipeName);
    try
      Root := CallToolRoot('call_method', '{"pid":' + IntToStr(GetCurrentProcessId) + AArgsJson + '}');
      FreeAndNil(Root);
    finally
      FreeAndNil(Discovery);
    end;
    Sent := Fake.SawRequest;
  finally
    FreeAndNil(Fake);
  end;

  V := TJSONObject.ParseJSONValue(Sent);
  try
    Assert.IsTrue(V is TJSONObject, 'the fake target received no JSON request: ' + Sent);
    Assert.AreEqual('call_method', TJSONObject(V).GetValue('cmd').Value, 'cmd: ' + Sent);
    Assert.IsTrue(TJSONObject(V).GetValue('args') is TJSONObject, 'args missing: ' + Sent);
  except
    FreeAndNil(V);   // a failed assert raises past Result: free the parsed request here
    raise;
  end;
  Result := TJSONObject(V);
end;


/// call_method forwards name, args (as an object) and timeoutMs; without them it sends an empty args object and no timeoutMs.
procedure TMcpToolTests.Test_CallMethod_ForwardsNameArgsAndTimeout;
var
  Req, Args: TJSONObject;
begin
  Req := SentCallMethodRequest(',"name":"demo.x","args":{"a":1,"s":"t"},"timeoutMs":9000');
  try
    Args := Req.GetValue('args') as TJSONObject;
    Assert.AreEqual('demo.x', Args.GetValue('name').Value, 'name: ' + Req.ToJSON);
    Assert.IsTrue(Args.GetValue('args') is TJSONObject, 'args.args must be an object: ' + Req.ToJSON);
    Assert.AreEqual('{"a":1,"s":"t"}', Args.GetValue('args').ToJSON, 'args.args: ' + Req.ToJSON);
    Assert.IsTrue(Req.GetValue('timeoutMs') is TJSONNumber, 'timeoutMs must reach the bridge: ' + Req.ToJSON);
    Assert.AreEqual('9000', Req.GetValue('timeoutMs').Value, 'timeoutMs');
  finally
    FreeAndNil(Req);
  end;

  // Some AI clients send a nested object as its JSON text.
  Req := SentCallMethodRequest(',"name":"demo.x","args":"{\"a\":2}"');
  try
    Args := Req.GetValue('args') as TJSONObject;
    Assert.IsTrue(Args.GetValue('args') is TJSONObject, 'args given as JSON text must reach the bridge as an object: ' + Req.ToJSON);
    Assert.AreEqual('{"a":2}', Args.GetValue('args').ToJSON, 'args.args from text');
  finally
    FreeAndNil(Req);
  end;

  Req := SentCallMethodRequest('');
  try
    Assert.AreEqual(0, (Req.GetValue('args') as TJSONObject).Count, 'without name the bridge args must be empty (the list): ' + Req.ToJSON);
    Assert.IsNull(Req.GetValue('timeoutMs'), 'without timeoutMs the bridge default must apply: ' + Req.ToJSON);
  finally
    FreeAndNil(Req);
  end;
end;


/// A wrong argument never reaches the target: the tool answers isError with the parameter's name.
procedure TMcpToolTests.Test_CallMethod_BadArguments_IsErrorNamingTheParameter;
var
  IsError: Boolean;
  Text: String;
begin
  Text := CallTool('call_method', '{"name":5}', IsError);
  Assert.IsTrue(IsError, 'name 5 must be refused: ' + Text);
  Assert.IsTrue(Text.Contains('"name"'), 'the message must name the parameter: ' + Text);

  Text := CallTool('call_method', '{"name":"demo.x","args":[1]}', IsError);
  Assert.IsTrue(IsError, 'args [1] must be refused: ' + Text);
  Assert.IsTrue(Text.Contains('"args"'), 'the message must name the parameter: ' + Text);

  Text := CallTool('call_method', '{"name":"demo.x","timeoutMs":-1}', IsError);
  Assert.IsTrue(IsError, 'timeoutMs -1 must be refused: ' + Text);
  Assert.IsTrue(Text.Contains('timeoutms'), 'the message must name the parameter: ' + Text);

  Text := CallTool('call_method', '{"nmae":"demo.x"}', IsError);
  Assert.IsTrue(IsError, 'an unknown key must be refused: ' + Text);
  Assert.IsTrue(Text.Contains('nmae'), 'the message must name the unknown key: ' + Text);

  Text := CallTool('call_method', '{"args":{"a":1}}', IsError);
  Assert.IsTrue(IsError, 'args without name must be refused: ' + Text);
  Assert.IsTrue(Text.Contains('"name"'), 'the message must say that name is missing: ' + Text);
end;


/// The schema of call_method declares args as an object (the generated schemas cannot), and no parameter is required.
procedure TMcpToolTests.Test_CallMethod_SchemaDeclaresArgsAsObject;
var
  V: TJSONValue;
  Root: TJSONObject;
  Tools: TJSONArray;
  Tool, Schema, Props: TJSONObject;
  i: Integer;
begin
  V := TJSONObject.ParseJSONValue(DispatchLine('{"jsonrpc":"2.0","id":5,"method":"tools/list"}'));
  Assert.IsTrue(V is TJSONObject, 'tools/list answer is not a JSON object');
  Root := TJSONObject(V);
  try
    Tools := (Root.GetValue('result') as TJSONObject).GetValue('tools') as TJSONArray;
    Tool := NIL;
    for i := 0 to Tools.Count - 1 do
      if (Tools.Items[i] as TJSONObject).GetValue('name').Value = 'call_method'
      then Tool := Tools.Items[i] as TJSONObject;
    Assert.IsNotNull(Tool, 'call_method missing from tools/list');
    Schema := Tool.GetValue('inputSchema') as TJSONObject;
    Assert.IsNotNull(Schema, 'inputSchema missing');
    Assert.AreEqual('object', Schema.GetValue('type').Value, 'schema type');
    Props := Schema.GetValue('properties') as TJSONObject;
    Assert.AreEqual('string',  (Props.GetValue('name')      as TJSONObject).GetValue('type').Value, 'name type');
    Assert.AreEqual('object',  (Props.GetValue('args')      as TJSONObject).GetValue('type').Value, 'args type');
    Assert.AreEqual('integer', (Props.GetValue('timeoutms') as TJSONObject).GetValue('type').Value, 'timeoutms type');
    Assert.AreEqual('integer', (Props.GetValue('pid')       as TJSONObject).GetValue('type').Value, 'pid type');
    Assert.IsNull(Schema.GetValue('required'), 'no parameter of call_method is required');
  finally
    FreeAndNil(Root);
  end;
end;


/// Calls dismiss_dialog with AArgsJson (pid added) against a fake target that answers AFakeAnswer to ONE request.
/// Returns the tool's text; ASent = the request the fake target received; AIsError = the result's isError flag.
function DismissDialogAgainst(const AFakeAnswer, AArgsJson: String; OUT ASent: String; OUT AIsError: Boolean): String;
var
  Fake: TFakePipeBridge;
  Discovery: TPrivateDiscovery;
begin
  Fake := TFakePipeBridge.Create(AFakeAnswer);
  try
    Fake.WaitUntilReady;
    Discovery := TPrivateDiscovery.Create(Fake.PipeName);
    try
      Result := CallTool('dismiss_dialog', '{"pid":' + IntToStr(GetCurrentProcessId) + AArgsJson + '}', AIsError);
    finally
      FreeAndNil(Discovery);
    end;
    ASent := Fake.SawRequest;
  finally
    FreeAndNil(Fake);
  end;
end;


/// A bridge older than 3.8.0 ignores fileName and would click Save at once with whatever the box holds. So the tool
/// sends fileName alone first; an answer without fileNameSet is such a bridge, and the tool stops with an error
/// before it ever sends the button.
procedure TMcpToolTests.Test_DismissDialog_FileName_OldBridge_IsErrorAndNoButtonSent;
const
  OldBridgeAnswer = '{"id":1,"ok":true,"result":{"dialogs":[{"hwnd":1234,"class":"#32770","caption":"Save As","text":"",'
                  + '"buttons":[{"id":1,"caption":"Save","enabled":true},{"id":2,"caption":"Cancel","enabled":true}]}],'
                  + '"supported":true,"platform":"windows"}}';
var
  Text, Sent: String;
  IsErr: Boolean;
  V: TJSONValue;
  Args: TJSONObject;
begin
  Text := DismissDialogAgainst(OldBridgeAnswer, ',"fileName":"C:\\x\\a.txt","button":"save"', Sent, IsErr);
  Assert.IsTrue(IsErr, 'an answer without fileNameSet must give isError: ' + Text);
  Assert.IsTrue(Text.Contains('3.8.0'), 'the message must name the bridge version that knows fileName: ' + Text);
  Assert.IsTrue(Text.Contains('no button was clicked'), 'the message must say that nothing was clicked: ' + Text);

  V := TJSONObject.ParseJSONValue(Sent);
  try
    Assert.IsTrue(V is TJSONObject, 'the fake target received no JSON request: ' + Sent);
    Assert.AreEqual('dismiss_dialog', TJSONObject(V).GetValue('cmd').Value, 'cmd: ' + Sent);
    Args := TJSONObject(V).GetValue('args') as TJSONObject;
    Assert.IsNotNull(Args, 'args missing: ' + Sent);
    Assert.AreEqual('C:\x\a.txt', Args.GetValue('fileName').Value, 'fileName not forwarded: ' + Sent);
    Assert.IsNull(Args.GetValue('button'), 'the first call must not carry the button: ' + Sent);
  finally
    FreeAndNil(V);
  end;
end;


/// The bridge refused the name (no File name box): the answer is passed on with clicked:false added, and no second
/// call is made (the fake target answers only one).
procedure TMcpToolTests.Test_DismissDialog_FileName_Refused_AnswersClickedFalse;
const
  RefusedAnswer = '{"id":1,"ok":true,"result":{"dialogs":[],"supported":true,"platform":"windows",'
                + '"fileNameSet":false,"dialogHwnd":1234,"reason":"edit_not_found"}}';
var
  Text, Sent: String;
  IsErr: Boolean;
  V: TJSONValue;
  Res: TJSONObject;
begin
  Text := DismissDialogAgainst(RefusedAnswer, ',"fileName":"a.txt","button":"save"', Sent, IsErr);
  Assert.IsFalse(IsErr, 'a refused name is an answer, not an error: ' + Text);
  V := TJSONObject.ParseJSONValue(Text);
  try
    Assert.IsTrue(V is TJSONObject, 'the tool text is not JSON: ' + Text);
    Res := TJSONObject(V).GetValue('result') as TJSONObject;
    Assert.IsNotNull(Res, 'result missing: ' + Text);
    Assert.IsTrue(Res.GetValue('clicked') is TJSONBool, 'clicked missing: ' + Text);
    Assert.IsFalse(TJSONBool(Res.GetValue('clicked')).AsBoolean, 'clicked must be false: ' + Text);
    Assert.AreEqual('edit_not_found', Res.GetValue('reason').Value, 'reason: ' + Text);
  finally
    FreeAndNil(V);
  end;
  Assert.IsFalse(Sent.Contains('"button"'), 'the only request sent must not carry the button: ' + Sent);
end;


/// GitHub issue #2: the target's pipe stays busy (its bridge worker is frozen with an old connection open).
/// The tool must answer the documented -32098 envelope, not raise "could not open pipe ... (code 231)".
procedure TMcpToolTests.Test_BusyPipe_Returns32098;
var
  Busy: TBusyPipe;
  Discovery: TPrivateDiscovery;
  Text, Msg: String;
begin
  Busy := TBusyPipe.Create;
  try
    Discovery := TPrivateDiscovery.Create(Busy.PipeName);
    try
      try
        Text := RunCommandOnTarget(GetCurrentProcessId, BuildRequest(1, 'get_text', nil), 300);
      except
        on E: Exception do
          Assert.Fail('RunCommandOnTarget raised ' + E.ClassName + ' instead of answering -32098: ' + E.Message);
      end;
    finally
      FreeAndNil(Discovery);
    end;
  finally
    FreeAndNil(Busy);
  end;

  Assert.AreEqual(ErrTargetNotResponding, ErrorCodeOf(Text, Msg), 'wrong error code: ' + Text);
  Assert.IsTrue(Msg.Contains('busy'), 'message does not say the pipe is busy: ' + Msg);
end;


/// -32098 means the whole target process is frozen, so more polls only hide the cause: wait_for hands the first
/// -32098 straight back to the AI, as it does with -32099, instead of polling to its deadline and answering
/// matched:false. One poll against the busy pipe costs about 5 s (DefaultTimeoutClickMs); three would fit in
/// the 12 s deadline.
procedure TMcpToolTests.Test_WaitFor_BusyPipe_Returns32098AtOnce;
var
  Busy: TBusyPipe;
  Discovery: TPrivateDiscovery;
  Text, Msg: String;
  IsErr: Boolean;
  Watch: TStopwatch;
begin
  Busy := TBusyPipe.Create;
  try
    Discovery := TPrivateDiscovery.Create(Busy.PipeName);
    try
      Watch := TStopwatch.StartNew;
      Text := CallTool('wait_for', '{"path":"frmMain.lblStatus","expectedText":"done","timeoutMs":12000,"pid":'
                                   + IntToStr(GetCurrentProcessId) + '}', IsErr);
      Watch.Stop;
    finally
      FreeAndNil(Discovery);
    end;
  finally
    FreeAndNil(Busy);
  end;

  Assert.IsTrue(IsErr, 'isError must be TRUE: ' + Text);
  Assert.AreEqual(ErrTargetNotResponding, ErrorCodeOf(Text, Msg), 'wrong error code: ' + Text);
  Assert.IsTrue(Msg.Contains('busy'), 'message does not say the pipe is busy: ' + Msg);
  Assert.IsTrue(Watch.ElapsedMilliseconds < 10000,
                'wait_for took ' + IntToStr(Watch.ElapsedMilliseconds) + ' ms: it polled on instead of failing fast');
end;


initialization
  TDUnitX.RegisterTestFixture(TMcpToolTests);

end.
