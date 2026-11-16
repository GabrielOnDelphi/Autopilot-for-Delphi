unit Tests.Bridge.CheckListBox;

{=============================================================================================================
   2026.11.15
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for the argument index of set_checked and read_property on a VCL TCheckListBox.
   - set_checked with index checks or unchecks that one item and fires OnClickCheck once, as a mouse click does; a resend of the same state changes nothing and fires nothing.
   - read_property with index and propName Checked reads that one item.
   - A header item, a disabled item, an index out of range, a wrong argument type and index on another control each answer their own error.
=============================================================================================================}

interface

uses
  System.JSON,
  Vcl.Forms,
  DUnitX.TestFramework;

type
  [TestFixture]
  TCheckListBoxTests = class
  private
    FPipeName   : String;
    FPipeCounter: Integer;
    FForm       : TForm;
    function CallCmd(const ACmd, AArgsJson: String): TJSONObject;
  public
    [SetupFixture]    procedure SetupFixture;
    [Setup]           procedure Setup;
    [TearDown]        procedure TearDown;
    [TearDownFixture] procedure TearDownFixture;

    [Test] procedure Test_SetChecked_Index_ChecksItemAndFiresOnClickCheckOnce;
    [Test] procedure Test_SetChecked_Index_UnchecksItem;
    [Test] procedure Test_SetChecked_Index_OutOfRange_Returns32600NamingTheCount;
    [Test] procedure Test_SetChecked_Index_HeaderAndDisabledItem_AreRefused;
    [Test] procedure Test_SetChecked_Index_OnOtherControl_Returns32005;
    [Test] procedure Test_SetChecked_Index_NotAWholeNumber_Returns32600;
    [Test] procedure Test_ReadProperty_Index_ReadsTheItem;
    [Test] procedure Test_ReadProperty_Index_OtherPropNameOrControl_Returns32005;
  end;


implementation

uses
  Winapi.Windows,   // GetCurrentProcessId for the pipe name
  System.SysUtils, System.Classes,
  Vcl.StdCtrls, Vcl.CheckLst,
  Autopilot.Bridge.Core, Autopilot.Bridge.Vcl,
  Bridge.TestClient, Bridge.Tests;


const
  FormName = 'ClbTestForm';
  ClbPath  = FormName + '.clbItems';

type
  // A check list box with two normal items, a header and a disabled item, plus a plain check box.
  TClbForm = class(TForm)
  public
    Clb: TCheckListBox;
    ClickCheckCount: Integer;
    constructor Create(AOwner: TComponent); override;
    procedure ClbClickCheck(Sender: TObject);
  end;


constructor TClbForm.Create(AOwner: TComponent);
var
  Chk: TCheckBox;
begin
  inherited CreateNew(AOwner);
  Name    := FormName;
  Caption := 'Check list box';
  Clb := TCheckListBox.Create(Self);
  Clb.Name   := 'clbItems';
  Clb.Parent := Self;
  Clb.Items.Add('Alpha');
  Clb.Items.Add('Beta');
  Clb.Items.Add('Group');
  Clb.Items.Add('Locked');
  Clb.Header[2]      := TRUE;
  Clb.ItemEnabled[3] := FALSE;
  Clb.OnClickCheck   := ClbClickCheck;
  Chk := TCheckBox.Create(Self);
  Chk.Name    := 'chkPlain';
  Chk.Caption := 'Plain';
  Chk.Parent  := Self;
end;


procedure TClbForm.ClbClickCheck(Sender: TObject);
begin
  Inc(ClickCheckCount);
end;


{ Helpers --------------------------------------------------------------- }

function ErrorMessageOf(ARoot: TJSONObject): String;
var
  V: TJSONValue;
begin
  Result := '';
  if ARoot = NIL then EXIT;
  V := ARoot.GetValue('error');
  if (V is TJSONObject) and (TJSONObject(V).GetValue('message') is TJSONString)
  then Result := TJSONObject(V).GetValue('message').Value;
end;


// The result object of a successful answer (owned by ARoot); fails the test otherwise.
function OkResultOf(ARoot: TJSONObject; const AWhat: String): TJSONObject;
begin
  Assert.IsNotNull(ARoot, AWhat + ': no answer');
  Result := GetOkResult(ARoot);
  if Result = NIL
  then Assert.Fail(AWhat + ': failed: ' + ARoot.ToJSON);
end;


{ TCheckListBoxTests ------------------------------------------------------ }

procedure TCheckListBoxTests.SetupFixture;
begin
  FPipeCounter := 0;
  FForm := TClbForm.Create(NIL);
end;


procedure TCheckListBoxTests.Setup;
var
  i: Integer;
begin
  Inc(FPipeCounter);
  FPipeName := '\\.\pipe\AutopilotTestCheckListBox.' + IntToStr(GetCurrentProcessId) + '.' + IntToStr(FPipeCounter);
  // Every test starts with all items unchecked and the event counter at 0.
  for i := 0 to TClbForm(FForm).Clb.Items.Count - 1 do
    TClbForm(FForm).Clb.State[i] := cbUnchecked;
  TClbForm(FForm).ClickCheckCount := 0;
  StartBridgeOnPipe(FPipeName);
end;


procedure TCheckListBoxTests.TearDown;
begin
  StopBridge;
end;


procedure TCheckListBoxTests.TearDownFixture;
begin
  FreeAndNil(FForm);
end;


{ Sends the command ACmd with the arguments AArgsJson and returns the whole answer (the caller frees it). }
function TCheckListBoxTests.CallCmd(const ACmd, AArgsJson: String): TJSONObject;
var
  Root: TJSONObject;
  PipeName, Cmd, ArgsJson: String;
begin
  PipeName := FPipeName;
  Cmd      := ACmd;
  ArgsJson := AArgsJson;
  Root := NIL;
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args: TJSONObject;
    begin
      Args := TJSONObject.ParseJSONValue(ArgsJson) as TJSONObject;   // Call owns Args from here
      Client := TBridgeTestClient.Create;
      try
        if not Client.ConnectAndHandshake(PipeName, 2000) then
          begin
            FreeAndNil(Args);
            Assert.Fail('connect to ' + PipeName + ' failed');
          end;
        Root := Client.Call(1, Cmd, Args);
      finally
        FreeAndNil(Client);
      end;
    end, 5000);
  Result := Root;
end;


procedure TCheckListBoxTests.Test_SetChecked_Index_ChecksItemAndFiresOnClickCheckOnce;
var
  Root: TJSONObject;
  R: TJSONObject;
  Clb: TCheckListBox;
begin
  Clb := TClbForm(FForm).Clb;
  Root := CallCmd('set_checked', '{"path":"' + ClbPath + '","checked":true,"index":1}');
  try
    R := OkResultOf(Root, 'set_checked index 1');
    Assert.IsTrue(Clb.Checked[1], 'item 1 must be checked');
    Assert.IsFalse(Clb.Checked[0], 'item 0 must stay unchecked');
    Assert.AreEqual(1, TClbForm(FForm).ClickCheckCount, 'OnClickCheck must fire once');
    Assert.AreEqual(1, (R.GetValue('index') as TJSONNumber).AsInt, 'answer index: ' + R.ToJSON);
    Assert.AreEqual('Beta', R.GetValue('item').Value, 'answer item: ' + R.ToJSON);
    Assert.IsTrue((R.GetValue('changed') as TJSONBool).AsBoolean, 'answer changed: ' + R.ToJSON);
  finally
    FreeAndNil(Root);
  end;

  // The same state again: nothing changes, nothing fires.
  Root := CallCmd('set_checked', '{"path":"' + ClbPath + '","checked":true,"index":1}');
  try
    R := OkResultOf(Root, 'set_checked index 1 again');
    Assert.IsTrue(Clb.Checked[1], 'item 1 must still be checked');
    Assert.AreEqual(1, TClbForm(FForm).ClickCheckCount, 'a resend must not fire OnClickCheck');
    Assert.IsFalse((R.GetValue('changed') as TJSONBool).AsBoolean, 'a resend must answer changed false: ' + R.ToJSON);
  finally
    FreeAndNil(Root);
  end;
end;


procedure TCheckListBoxTests.Test_SetChecked_Index_UnchecksItem;
var
  Root: TJSONObject;
  Clb: TCheckListBox;
begin
  Clb := TClbForm(FForm).Clb;
  Clb.Checked[0] := TRUE;   // fires no event (Vcl.CheckLst.pas, SetChecked)
  Root := CallCmd('set_checked', '{"path":"' + ClbPath + '","checked":false,"index":0}');
  try
    OkResultOf(Root, 'set_checked index 0 false');
    Assert.IsFalse(Clb.Checked[0], 'item 0 must be unchecked');
    Assert.AreEqual(1, TClbForm(FForm).ClickCheckCount, 'OnClickCheck must fire once');
  finally
    FreeAndNil(Root);
  end;
end;


procedure TCheckListBoxTests.Test_SetChecked_Index_OutOfRange_Returns32600NamingTheCount;
var
  Root: TJSONObject;
begin
  Root := CallCmd('set_checked', '{"path":"' + ClbPath + '","checked":true,"index":4}');
  try
    Assert.AreEqual(ErrInvalidRequest, GetErrorCode(Root), 'index 4 of 4 items must answer -32600: ' + Root.ToJSON);
    Assert.IsTrue(ErrorMessageOf(Root).Contains('4 items'), 'the message must name the item count: ' + ErrorMessageOf(Root));
  finally
    FreeAndNil(Root);
  end;

  Root := CallCmd('set_checked', '{"path":"' + ClbPath + '","checked":true,"index":-1}');
  try
    Assert.AreEqual(ErrInvalidRequest, GetErrorCode(Root), 'index -1 must answer -32600: ' + Root.ToJSON);
  finally
    FreeAndNil(Root);
  end;
  Assert.AreEqual(0, TClbForm(FForm).ClickCheckCount, 'a refused index must fire nothing');
end;


procedure TCheckListBoxTests.Test_SetChecked_Index_HeaderAndDisabledItem_AreRefused;
var
  Root: TJSONObject;
  Clb: TCheckListBox;
begin
  Clb := TClbForm(FForm).Clb;
  Root := CallCmd('set_checked', '{"path":"' + ClbPath + '","checked":true,"index":2}');
  try
    Assert.AreEqual(ErrUnsupportedAction, GetErrorCode(Root), 'a header item must answer -32005: ' + Root.ToJSON);
    Assert.IsTrue(ErrorMessageOf(Root).Contains('header'), 'the message must say header: ' + ErrorMessageOf(Root));
  finally
    FreeAndNil(Root);
  end;

  Root := CallCmd('set_checked', '{"path":"' + ClbPath + '","checked":true,"index":3}');
  try
    Assert.AreEqual(ErrControlDisabled, GetErrorCode(Root), 'a disabled item must answer -32003: ' + Root.ToJSON);
  finally
    FreeAndNil(Root);
  end;
  Assert.AreEqual(cbUnchecked, Clb.State[2], 'the header item must stay unchanged');
  Assert.AreEqual(cbUnchecked, Clb.State[3], 'the disabled item must stay unchanged');
  Assert.AreEqual(0, TClbForm(FForm).ClickCheckCount, 'a refused item must fire nothing');
end;


procedure TCheckListBoxTests.Test_SetChecked_Index_OnOtherControl_Returns32005;
var
  Root: TJSONObject;
begin
  Root := CallCmd('set_checked', '{"path":"' + FormName + '.chkPlain","checked":true,"index":0}');
  try
    Assert.AreEqual(ErrUnsupportedAction, GetErrorCode(Root), 'index on a TCheckBox must answer -32005: ' + Root.ToJSON);
    Assert.IsTrue(ErrorMessageOf(Root).Contains('TCheckListBox'), 'the message must name TCheckListBox: ' + ErrorMessageOf(Root));
  finally
    FreeAndNil(Root);
  end;
end;


procedure TCheckListBoxTests.Test_SetChecked_Index_NotAWholeNumber_Returns32600;
var
  Root: TJSONObject;
begin
  Root := CallCmd('set_checked', '{"path":"' + ClbPath + '","checked":true,"index":"1"}');
  try
    Assert.AreEqual(ErrInvalidRequest, GetErrorCode(Root), 'index "1" must answer -32600: ' + Root.ToJSON);
    Assert.IsTrue(ErrorMessageOf(Root).Contains('index'), 'the message must name the argument: ' + ErrorMessageOf(Root));
  finally
    FreeAndNil(Root);
  end;

  Root := CallCmd('set_checked', '{"path":"' + ClbPath + '","checked":true,"index":1.5}');
  try
    Assert.AreEqual(ErrInvalidRequest, GetErrorCode(Root), 'index 1.5 must answer -32600: ' + Root.ToJSON);
  finally
    FreeAndNil(Root);
  end;
  Assert.AreEqual(0, TClbForm(FForm).ClickCheckCount, 'a bad index must fire nothing');
end;


procedure TCheckListBoxTests.Test_ReadProperty_Index_ReadsTheItem;
var
  Root: TJSONObject;
  R: TJSONObject;
begin
  TClbForm(FForm).Clb.Checked[1] := TRUE;
  Root := CallCmd('read_property', '{"path":"' + ClbPath + '","propName":"Checked","index":1}');
  try
    R := OkResultOf(Root, 'read_property index 1');
    Assert.AreEqual('true', R.GetValue('value').Value, 'value: ' + R.ToJSON);
    Assert.AreEqual('boolean', R.GetValue('kind').Value, 'kind: ' + R.ToJSON);
    Assert.AreEqual('Beta', R.GetValue('item').Value, 'item: ' + R.ToJSON);
    Assert.AreEqual(4, (R.GetValue('itemCount') as TJSONNumber).AsInt, 'itemCount: ' + R.ToJSON);
  finally
    FreeAndNil(Root);
  end;

  Root := CallCmd('read_property', '{"path":"' + ClbPath + '","propName":"checked","index":0}');
  try
    R := OkResultOf(Root, 'read_property index 0, propName in lower case');
    Assert.AreEqual('false', R.GetValue('value').Value, 'value: ' + R.ToJSON);
  finally
    FreeAndNil(Root);
  end;

  Root := CallCmd('read_property', '{"path":"' + ClbPath + '","propName":"Checked","index":7}');
  try
    Assert.AreEqual(ErrInvalidRequest, GetErrorCode(Root), 'index 7 must answer -32600: ' + Root.ToJSON);
    Assert.IsTrue(ErrorMessageOf(Root).Contains('4 items'), 'the message must name the item count: ' + ErrorMessageOf(Root));
  finally
    FreeAndNil(Root);
  end;
end;


procedure TCheckListBoxTests.Test_ReadProperty_Index_OtherPropNameOrControl_Returns32005;
var
  Root: TJSONObject;
begin
  Root := CallCmd('read_property', '{"path":"' + ClbPath + '","propName":"Tag","index":0}');
  try
    Assert.AreEqual(ErrUnsupportedAction, GetErrorCode(Root), 'index with propName Tag must answer -32005: ' + Root.ToJSON);
  finally
    FreeAndNil(Root);
  end;

  Root := CallCmd('read_property', '{"path":"' + FormName + '.chkPlain","propName":"Checked","index":0}');
  try
    Assert.AreEqual(ErrUnsupportedAction, GetErrorCode(Root), 'index on a TCheckBox must answer -32005: ' + Root.ToJSON);
  finally
    FreeAndNil(Root);
  end;
end;


initialization
  TDUnitX.RegisterTestFixture(TCheckListBoxTests);

end.
