unit Tests.Bridge.SendKeys;

{=============================================================================================================
   2026.10.12
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for the VCL bridge command send_keys: OnKeyDown with the Shift state of a chord, typed text
     (one OnKeyPress per character), an action ShortCut, the Default button on Enter, the Cancel button on
     Escape, an unknown key name, a disabled control, a control that cannot take the focus, and the keyboard
     state restored after the call.
   - Two synthetic forms, shown off-screen with WS_EX_NOACTIVATE (a control must be showing to take the focus,
     and the forms must not take the focus from the user's own window).
   - Every test talks to the bridge over a real pipe, through TBridgeTestClient.
=============================================================================================================}

interface

uses
  Vcl.Forms,
  DUnitX.TestFramework;

type
  [TestFixture]
  TSendKeysTests = class
  private
    FPipeName   : String;
    FPipeCounter: Integer;
    FKeys       : TForm;    // TKeysForm 'KeysForm'
    FAct        : TForm;    // TKeysActionForm 'KeysActionForm'
  public
    [SetupFixture]    procedure SetupFixture;
    [Setup]           procedure Setup;
    [TearDown]        procedure TearDown;
    [TearDownFixture] procedure TearDownFixture;

    [Test] procedure Test_SendKeys_CtrlS_OnKeyDownGetsKeyAndShift;
    [Test] procedure Test_SendKeys_TextTypesIntoEditOneKeyPressPerChar;
    [Test] procedure Test_SendKeys_ActionShortCutRunsOnExecute;
    [Test] procedure Test_SendKeys_EnterClicksDefaultButton;
    [Test] procedure Test_SendKeys_EnterAfterAnotherButtonHadFocus;
    [Test] procedure Test_SendKeys_EscapeClicksCancelButton;
    [Test] procedure Test_SendKeys_UnknownKeyNameRejectedAndNothingSent;
    [Test] procedure Test_SendKeys_DisabledControlRejected;
    [Test] procedure Test_SendKeys_LabelCannotTakeFocus;
    [Test] procedure Test_SendKeys_CtrlIsUpAfterTheCall;
    [Test] procedure Test_Click_ModeMessageOnMinimizedForm;
  end;


implementation

uses
  Winapi.Windows, Winapi.Messages,
  System.SysUtils, System.Classes, System.JSON, System.Actions, System.UITypes,
  Vcl.Controls, Vcl.StdCtrls, Vcl.ActnList, Vcl.Menus,
  Autopilot.Bridge.Core, Autopilot.Bridge.Vcl,
  Bridge.TestClient, Bridge.Tests;


type
  { A form that is shown but never activated and never raised: off-screen, WS_EX_NOACTIVATE, no SetZOrder. }
  TQuietForm = class(TForm)
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure SetZOrder(TopMost: Boolean); override;
  public
    procedure ShowQuietly;
  end;

  TKeysForm = class(TQuietForm)
  public
    EdtKeys      : TEdit;
    EdtOff       : TEdit;      // disabled
    LblInfo      : TLabel;
    BtnOk        : TButton;    // Default
    BtnCancel    : TButton;    // Cancel
    LastKey      : Word;
    LastShift    : TShiftState;
    KeyDownCount : Integer;
    KeyPressCount: Integer;
    OkClicks     : Integer;
    CancelClicks : Integer;
    constructor Create(AOwner: TComponent); override;
    procedure EdtKeysKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure EdtKeysKeyPress(Sender: TObject; var Key: Char);
    procedure BtnOkClick(Sender: TObject);
    procedure BtnCancelClick(Sender: TObject);
  end;

  TKeysActionForm = class(TQuietForm)
  public
    EdtAct    : TEdit;
    ActList   : TActionList;
    ActSave   : TAction;       // ShortCut Ctrl+S
    SaveRuns  : Integer;
    constructor Create(AOwner: TComponent); override;
    procedure ActSaveExecute(Sender: TObject);
  end;


procedure TQuietForm.CreateParams(var Params: TCreateParams);
begin
  inherited;
  Params.ExStyle := Params.ExStyle or WS_EX_NOACTIVATE or WS_EX_TOOLWINDOW;
end;


procedure TQuietForm.SetZOrder(TopMost: Boolean);
begin
  // Never raise the window: TCustomForm.Show ends in BringToFront.
end;


procedure TQuietForm.ShowQuietly;
begin
  Position := poDesigned;
  SetBounds(-20000, -20000, 300, 200);
  Visible := TRUE;
end;


constructor TKeysForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Name    := 'KeysForm';
  Caption := 'Keys';

  EdtKeys := TEdit.Create(Self);
  EdtKeys.Name       := 'edtKeys';
  EdtKeys.Parent     := Self;
  EdtKeys.OnKeyDown  := EdtKeysKeyDown;
  EdtKeys.OnKeyPress := EdtKeysKeyPress;

  EdtOff := TEdit.Create(Self);
  EdtOff.Name    := 'edtOff';
  EdtOff.Parent  := Self;
  EdtOff.Top     := 30;
  EdtOff.Text    := '';
  EdtOff.Enabled := FALSE;

  LblInfo := TLabel.Create(Self);
  LblInfo.Name    := 'lblInfo';
  LblInfo.Parent  := Self;
  LblInfo.Top     := 60;
  LblInfo.Caption := 'info';

  BtnOk := TButton.Create(Self);
  BtnOk.Name    := 'btnOk';
  BtnOk.Parent  := Self;
  BtnOk.Top     := 90;
  BtnOk.Default := TRUE;
  BtnOk.OnClick := BtnOkClick;

  BtnCancel := TButton.Create(Self);
  BtnCancel.Name    := 'btnCancel';
  BtnCancel.Parent  := Self;
  BtnCancel.Top     := 120;
  BtnCancel.Cancel  := TRUE;
  BtnCancel.OnClick := BtnCancelClick;
end;


procedure TKeysForm.EdtKeysKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  LastKey   := Key;
  LastShift := Shift;
  Inc(KeyDownCount);
end;


procedure TKeysForm.EdtKeysKeyPress(Sender: TObject; var Key: Char);
begin
  Inc(KeyPressCount);
end;


procedure TKeysForm.BtnOkClick(Sender: TObject);
begin
  Inc(OkClicks);
end;


procedure TKeysForm.BtnCancelClick(Sender: TObject);
begin
  Inc(CancelClicks);
end;


constructor TKeysActionForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Name    := 'KeysActionForm';
  Caption := 'Keys action';

  EdtAct := TEdit.Create(Self);
  EdtAct.Name   := 'edtAct';
  EdtAct.Parent := Self;
  EdtAct.Text   := '';     // a TEdit created in code takes its Name as Text

  ActList := TActionList.Create(Self);
  ActList.Name := 'alKeys';

  ActSave := TAction.Create(Self);
  ActSave.Name       := 'actSave';
  ActSave.ShortCut   := ShortCut(Ord('S'), [ssCtrl]);
  ActSave.OnExecute  := ActSaveExecute;
  ActSave.ActionList := ActList;
end;


procedure TKeysActionForm.ActSaveExecute(Sender: TObject);
begin
  Inc(SaveRuns);
end;


{ Helpers --------------------------------------------------------------- }

function KeysArgs(const APath, AKeys, AText: String): TJSONObject;
begin
  Result := TJSONObject.Create;
  if APath <> '' then Result.AddPair('path', APath);
  if AKeys <> '' then Result.AddPair('keys', AKeys);
  if AText <> '' then Result.AddPair('text', AText);
end;


// One request/response round trip on a worker thread while this thread pumps the bridge's queue. The caller frees the result.
function CallBridge(const APipeName, ACmd: String; AArgs: TJSONObject): TJSONObject;
var
  Root: TJSONObject;
  PipeName, Cmd: String;
  Args: TJSONObject;
begin
  Root     := NIL;
  PipeName := APipeName;
  Cmd      := ACmd;
  Args     := AArgs;
  RunOnWorkerAndPump(
    procedure
    var Client: TBridgeTestClient;
    begin
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


function ErrorMessageOf(ARoot: TJSONObject): String;
var
  V: TJSONValue;
begin
  Result := '';
  if ARoot = NIL then exit('(no response)');
  V := ARoot.GetValue('error');
  if V is TJSONObject then
  begin
    V := TJSONObject(V).GetValue('message');
    if V is TJSONString then
      Result := TJSONString(V).Value;
  end;
end;


// Sends send_keys and asserts success. Returns the 'target' field.
function SendKeysOk(const APipeName, APath, AKeys, AText: String): String;
var
  Root, R: TJSONObject;
  V: TJSONValue;
begin
  Result := '';
  Root := CallBridge(APipeName, 'send_keys', KeysArgs(APath, AKeys, AText));
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'send_keys failed: ' + ErrorMessageOf(Root));
    V := R.GetValue('target');
    if V is TJSONString then
      Result := TJSONString(V).Value;
    Assert.AreEqual('keymessages', (R.GetValue('via') as TJSONString).Value, 'via');
  finally
    FreeAndNil(Root);
  end;
end;


{ TSendKeysTests --------------------------------------------------------- }

procedure TSendKeysTests.SetupFixture;
begin
  FPipeCounter := 0;
  FKeys := TKeysForm.Create(NIL);
  FAct  := TKeysActionForm.Create(NIL);
  TQuietForm(FKeys).ShowQuietly;
  TQuietForm(FAct).ShowQuietly;
end;


procedure TSendKeysTests.Setup;
var
  F: TKeysForm;
begin
  Inc(FPipeCounter);
  FPipeName := '\\.\pipe\AutopilotTestSK.' + IntToStr(GetCurrentProcessId) + '.' + IntToStr(FPipeCounter);

  F := TKeysForm(FKeys);
  F.EdtKeys.Text    := '';
  F.LastKey         := 0;
  F.LastShift       := [];
  F.KeyDownCount    := 0;
  F.KeyPressCount   := 0;
  F.OkClicks        := 0;
  F.CancelClicks    := 0;
  TKeysActionForm(FAct).SaveRuns := 0;

  StartBridgeOnPipe(FPipeName);
end;


procedure TSendKeysTests.TearDown;
begin
  StopBridge;
end;


procedure TSendKeysTests.TearDownFixture;
begin
  FreeAndNil(FAct);
  FreeAndNil(FKeys);
end;


procedure TSendKeysTests.Test_SendKeys_CtrlS_OnKeyDownGetsKeyAndShift;
var
  F: TKeysForm;
begin
  F := TKeysForm(FKeys);
  Assert.AreEqual('KeysForm.edtKeys', SendKeysOk(FPipeName, 'KeysForm.edtKeys', 'Ctrl+S', ''), 'target');
  Assert.AreEqual(Integer(Ord('S')), Integer(F.LastKey), 'OnKeyDown key');
  Assert.IsTrue(F.LastShift * [ssCtrl, ssShift, ssAlt] = [ssCtrl], 'OnKeyDown Shift must be exactly [ssCtrl]; ssShift=' +
                BoolToStr(ssShift in F.LastShift, TRUE) + ' ssAlt=' + BoolToStr(ssAlt in F.LastShift, TRUE) + ' ssCtrl=' + BoolToStr(ssCtrl in F.LastShift, TRUE));
end;


procedure TSendKeysTests.Test_SendKeys_TextTypesIntoEditOneKeyPressPerChar;
var
  F: TKeysForm;
begin
  F := TKeysForm(FKeys);
  SendKeysOk(FPipeName, 'KeysForm.edtKeys', '', 'aB3 x');
  Assert.AreEqual('aB3 x', F.EdtKeys.Text, 'typed text');
  Assert.AreEqual(5, F.KeyPressCount, 'one OnKeyPress per character');
  Assert.AreEqual(5, F.KeyDownCount, 'one OnKeyDown per character');
end;


procedure TSendKeysTests.Test_SendKeys_ActionShortCutRunsOnExecute;
begin
  SendKeysOk(FPipeName, 'KeysActionForm.edtAct', 'ctrl+s', '');
  Assert.AreEqual(1, TKeysActionForm(FAct).SaveRuns, 'Ctrl+S must run the action');
  Assert.AreEqual('', TKeysActionForm(FAct).EdtAct.Text, 'the shortcut must not type into the edit');
end;


procedure TSendKeysTests.Test_SendKeys_EnterClicksDefaultButton;
var
  F: TKeysForm;
begin
  F := TKeysForm(FKeys);
  SendKeysOk(FPipeName, 'KeysForm.edtKeys', 'Enter', 'hi');
  Assert.AreEqual(1, F.OkClicks, 'Enter must click the Default button');
  Assert.AreEqual(0, F.CancelClicks, 'Enter must not click the Cancel button');
  Assert.AreEqual('hi', F.EdtKeys.Text, 'text is typed before the keys');
end;


{ The demo app case: a button had the focus while the form was active, then the form was deactivated. That button still acts as the default (TCustomButton.CMFocusChanged), so without a focus-change notice Enter on the edit clicked it. }
procedure TSendKeysTests.Test_SendKeys_EnterAfterAnotherButtonHadFocus;
var
  F: TKeysForm;
begin
  F := TKeysForm(FKeys);
  F.Perform(CM_FOCUSCHANGED, 0, LPARAM(F.BtnCancel));
  SendKeysOk(FPipeName, 'KeysForm.edtKeys', 'Enter', '');
  Assert.AreEqual(0, F.CancelClicks, 'Enter clicked the button that had the focus earlier');
  Assert.AreEqual(1, F.OkClicks, 'Enter must click the Default button');
end;


procedure TSendKeysTests.Test_SendKeys_EscapeClicksCancelButton;
var
  F: TKeysForm;
begin
  F := TKeysForm(FKeys);
  SendKeysOk(FPipeName, 'KeysForm.edtKeys', 'Esc', '');
  Assert.AreEqual(1, F.CancelClicks, 'Escape must click the Cancel button');
  Assert.AreEqual(0, F.OkClicks, 'Escape must not click the Default button');
end;


procedure TSendKeysTests.Test_SendKeys_UnknownKeyNameRejectedAndNothingSent;
var
  F: TKeysForm;
  Root: TJSONObject;
begin
  F := TKeysForm(FKeys);
  Root := CallBridge(FPipeName, 'send_keys', KeysArgs('KeysForm.edtKeys', 'A Ctrl+Bogus', 'xyz'));
  try
    Assert.AreEqual(ErrInvalidRequest, GetErrorCode(Root), 'unknown key name: ' + ErrorMessageOf(Root));
    Assert.Contains(ErrorMessageOf(Root), 'Bogus', 'the message must name the bad token');
  finally
    FreeAndNil(Root);
  end;
  Assert.AreEqual('', F.EdtKeys.Text, 'nothing may be typed');
  Assert.AreEqual(0, F.KeyDownCount, 'no key may be sent');
end;


procedure TSendKeysTests.Test_SendKeys_DisabledControlRejected;
var
  Root: TJSONObject;
begin
  Root := CallBridge(FPipeName, 'send_keys', KeysArgs('KeysForm.edtOff', 'A', ''));
  try
    Assert.AreEqual(ErrControlDisabled, GetErrorCode(Root), 'disabled: ' + ErrorMessageOf(Root));
  finally
    FreeAndNil(Root);
  end;
  Assert.AreEqual('', TKeysForm(FKeys).EdtOff.Text, 'a disabled edit must stay empty');
end;


procedure TSendKeysTests.Test_SendKeys_LabelCannotTakeFocus;
var
  Root: TJSONObject;
begin
  Root := CallBridge(FPipeName, 'send_keys', KeysArgs('KeysForm.lblInfo', 'A', ''));
  try
    Assert.AreEqual(ErrUnsupportedAction, GetErrorCode(Root), 'label: ' + ErrorMessageOf(Root));
  finally
    FreeAndNil(Root);
  end;
end;


procedure TSendKeysTests.Test_SendKeys_CtrlIsUpAfterTheCall;
var
  F: TKeysForm;
begin
  F := TKeysForm(FKeys);
  SendKeysOk(FPipeName, 'KeysForm.edtKeys', 'Ctrl+Shift+Z', '');
  Assert.IsTrue(F.LastShift * [ssCtrl, ssShift] = [ssCtrl, ssShift], 'the chord must reach OnKeyDown with Ctrl and Shift');
  Assert.AreEqual(0, Integer(GetKeyState(VK_CONTROL) and $8000), 'Ctrl must be up after send_keys');
  Assert.AreEqual(0, Integer(GetKeyState(VK_SHIFT) and $8000), 'Shift must be up after send_keys');
end;


{ click mode=message on a button of a MINIMIZED form (a customer's app, or the E2E demo started with SW_SHOWMINNOACTIVE): the click must run once the queue is pumped. }
procedure TSendKeysTests.Test_Click_ModeMessageOnMinimizedForm;
var
  F: TKeysForm;
  Root: TJSONObject;
  Args: TJSONObject;
  Msg: TMsg;
  Deadline: UInt64;
begin
  F := TKeysForm(FKeys);
  ShowWindow(F.Handle, SW_SHOWMINNOACTIVE);
  try
    Assert.IsTrue(IsIconic(F.Handle), 'the form must be minimized for this test');
    Args := TJSONObject.Create;
    Args.AddPair('path', 'KeysForm.btnOk');
    Args.AddPair('mode', 'message');
    Root := CallBridge(FPipeName, 'click', Args);
    try
      Assert.IsNotNull(GetOkResult(Root), 'click mode=message failed: ' + ErrorMessageOf(Root));
    finally
      FreeAndNil(Root);
    end;
    // Drain this thread's queue and the synchronize queue for a short while: the click runs after the answer.
    Deadline := GetTickCount64 + 500;
    while (F.OkClicks = 0) and (GetTickCount64 < Deadline) do
    begin
      CheckSynchronize(10);
      while PeekMessage(Msg, 0, 0, 0, PM_REMOVE) do
      begin
        TranslateMessage(Msg);
        DispatchMessage(Msg);
      end;
    end;
    Assert.AreEqual(1, F.OkClicks, 'the queued click on a minimized form must run exactly once');
  finally
    ShowWindow(F.Handle, SW_SHOWNOACTIVATE);
  end;
end;


initialization
  TDUnitX.RegisterTestFixture(TSendKeysTests);

end.
