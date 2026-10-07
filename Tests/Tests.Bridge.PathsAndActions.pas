unit Tests.Bridge.PathsAndActions;

{=============================================================================================================
   2026.10.06
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for the VCL bridge: path lookup through the visual parent (a control re-parented from another
     form), the list_tree 'parent' field, clicks on action-bound TGraphicControls, execute_action, the
     read-back text of a TAlphaColor property ('claName' / '#AARRGGBB'), and set_property Enabled on a
     disabled control.
   - Three synthetic forms built in code. PathHostForm shows a panel and two buttons that PathOwnerForm and
     PathOwnerForm2 own - the shape Kai met in CubicEditor (a panel of frmEnterFix re-parented into a tab sheet).
   - Every test talks to the bridge over a real pipe, through TBridgeTestClient.
=============================================================================================================}

interface

uses
  Vcl.Forms,
  DUnitX.TestFramework;

type
  [TestFixture]
  TPathActionTests = class
  private
    FPipeName   : String;
    FPipeCounter: Integer;
    FHost       : TForm;    // TPathHostForm; the form classes are private to the implementation
    FOwner      : TForm;    // TPathOwnerForm 'PathOwnerForm' (has the container)
    FOwner2     : TForm;    // TPathOwnerForm 'PathOwnerForm2' (only btnDup)
  public
    [SetupFixture]    procedure SetupFixture;
    [Setup]           procedure Setup;
    [TearDown]        procedure TearDown;
    [TearDownFixture] procedure TearDownFixture;

    [Test] procedure Test_Path_ReparentedPanelResolvesThroughVisualParent;
    [Test] procedure Test_Path_ReparentedButtonClickByAnchoredAndFlatPath;
    [Test] procedure Test_Path_OwnerPathsStillResolve;
    [Test] procedure Test_Path_TwoVisualMatchesReturnAmbiguous;
    [Test] procedure Test_ListTree_ReparentedControlCarriesParentField;
    [Test] procedure Test_Click_ActionBoundSpeedButtonRunsActionExecute;
    [Test] procedure Test_Click_ActionBoundSpeedButtonWithoutOnExecute;
    [Test] procedure Test_ExecuteAction_RunsOnExecute;
    [Test] procedure Test_ReadProperty_NamedAlphaColorReadsClaName;
    [Test] procedure Test_ReadProperty_UnnamedAlphaColorReadsHex;
    [Test] procedure Test_SetProperty_EnabledOnDisabledControlIsAllowed;
    [Test] procedure Test_SetProperty_OtherPropertyOnDisabledControlStillRejected;
  end;


implementation

uses
  Winapi.Windows,
  System.SysUtils, System.Classes, System.JSON, System.Actions, System.Generics.Collections, System.UITypes,
  Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Buttons, Vcl.ActnList,
  Autopilot.Bridge.Core, Autopilot.Bridge.Vcl,
  Bridge.TestClient, Bridge.Tests;


type
  // A published TAlphaColor property on a VCL form (VCL controls rarely have one; FMX controls always do).
  TAlphaColorBox = class(TComponent)
  private
    FFillColor: TAlphaColor;
  published
    property FillColor: TAlphaColor read FFillColor write FFillColor;
  end;

  // The form the user sees: a panel that hosts controls owned by two other forms, plus the action fixtures.
  TPathHostForm = class(TForm)
  public
    PnlTabHost   : TPanel;          // plays the role of MainForm.tabFixEnters
    ActList      : TActionList;
    ActCounted   : TAction;         // has OnExecute; AutoCheck so a run through TCustomAction.Execute is visible
    ActNoHandler : TAction;         // no OnExecute: only ActList.OnExecute runs it, like a standard action
    SbCounted    : TSpeedButton;    // TGraphicControl bound to ActCounted
    SbNoHandler  : TSpeedButton;    // TGraphicControl bound to ActNoHandler
    AcBox        : TAlphaColorBox;
    BtnOff       : TButton;         // disabled again by Setup before every test
    CountedRuns  : Integer;
    CountedSender: TObject;
    NoHandlerRuns: Integer;
    constructor Create(AOwner: TComponent); override;
    procedure ActCountedExecute(Sender: TObject);
    procedure ActListExecute(Action: TBasicAction; var Handled: Boolean);
    procedure ActListUpdate(Action: TBasicAction; var Handled: Boolean);
  end;

  // The form that owns the re-parented controls (plays the role of frmEnterFix). Never shown.
  TPathOwnerForm = class(TForm)
  public
    PnlContainer     : TPanel;      // NIL on the second owner form
    BtnInContainer   : TButton;     // NIL on the second owner form
    BtnDup           : TButton;     // both owner forms have one; both are re-parented into PnlTabHost
    InContainerClicks: Integer;
    constructor CreateFor(AHost: TPathHostForm; const AName: String; AWithContainer: Boolean);
    procedure BtnInContainerClick(Sender: TObject);
  end;


constructor TPathHostForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Name    := 'PathHostForm';
  Caption := 'Path host';

  PnlTabHost := TPanel.Create(Self);
  PnlTabHost.Name   := 'pnlTabHost';
  PnlTabHost.Parent := Self;

  ActList := TActionList.Create(Self);
  ActList.Name     := 'alHost';
  ActList.OnExecute:= ActListExecute;
  ActList.OnUpdate := ActListUpdate;

  // OnExecute is set BEFORE the button is linked, as when a DFM loads: TControl.ActionChange then copies it into the button's OnClick.
  ActCounted := TAction.Create(Self);
  ActCounted.Name       := 'actCounted';
  ActCounted.Caption    := 'Counted';
  ActCounted.AutoCheck  := TRUE;
  ActCounted.OnExecute  := ActCountedExecute;
  ActCounted.ActionList := ActList;

  ActNoHandler := TAction.Create(Self);
  ActNoHandler.Name       := 'actNoHandler';
  ActNoHandler.Caption    := 'NoHandler';
  ActNoHandler.ActionList := ActList;

  SbCounted := TSpeedButton.Create(Self);
  SbCounted.Name   := 'sbCounted';
  SbCounted.Parent := Self;
  SbCounted.Action := ActCounted;

  SbNoHandler := TSpeedButton.Create(Self);
  SbNoHandler.Name   := 'sbNoHandler';
  SbNoHandler.Parent := Self;
  SbNoHandler.Action := ActNoHandler;

  AcBox := TAlphaColorBox.Create(Self);
  AcBox.Name := 'acBox';

  BtnOff := TButton.Create(Self);
  BtnOff.Name   := 'btnOff';
  BtnOff.Parent := Self;
end;


procedure TPathHostForm.ActCountedExecute(Sender: TObject);
begin
  Inc(CountedRuns);
  CountedSender := Sender;
end;


procedure TPathHostForm.ActListExecute(Action: TBasicAction; var Handled: Boolean);
begin
  if Action = ActNoHandler then
  begin
    Inc(NoHandlerRuns);
    Handled := TRUE;
  end;
end;


// TCustomAction.Execute calls Update first. Without a handler here, TApplication.DispatchAction would disable ActNoHandler (DisableIfNoHandler) and the run would never happen.
procedure TPathHostForm.ActListUpdate(Action: TBasicAction; var Handled: Boolean);
begin
  if Action = ActNoHandler then
    Handled := TRUE;
end;


constructor TPathOwnerForm.CreateFor(AHost: TPathHostForm; const AName: String; AWithContainer: Boolean);
begin
  inherited CreateNew(NIL);
  Name    := AName;
  Caption := AName;

  if AWithContainer then
  begin
    PnlContainer := TPanel.Create(Self);
    PnlContainer.Name    := 'pnlContainer';
    PnlContainer.Caption := 'Container';
    PnlContainer.Parent  := AHost.PnlTabHost;     // the re-parent: owned here, shown on the host form

    BtnInContainer := TButton.Create(Self);
    BtnInContainer.Name    := 'btnInContainer';
    BtnInContainer.Caption := 'Inside';
    BtnInContainer.Parent  := PnlContainer;
    BtnInContainer.OnClick := BtnInContainerClick;
  end;

  BtnDup := TButton.Create(Self);
  BtnDup.Name    := 'btnDup';
  BtnDup.Caption := AName;
  BtnDup.Parent  := AHost.PnlTabHost;
end;


procedure TPathOwnerForm.BtnInContainerClick(Sender: TObject);
begin
  Inc(InContainerClicks);
end;


{ Helpers --------------------------------------------------------------- }

function PathArgs(const APath: String): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('path', APath);
end;


// Args for read_property (AValue = '') or set_property.
function PropArgs(const APath, APropName, AValue: String): TJSONObject;
begin
  Result := PathArgs(APath);
  Result.AddPair('propName', APropName);
  if AValue <> '' then
    Result.AddPair('value', AValue);
end;


// One request/response round trip on a worker thread while this thread pumps the bridge's queue. The caller frees the result (NIL when the frame could not be read).
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
          FreeAndNil(Args);   // Call owns Args only once it runs
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


function StringField(AObj: TJSONObject; const AName: String): String;
var
  V: TJSONValue;
begin
  Result := '';
  if AObj = NIL then exit;
  V := AObj.GetValue(AName);
  if V is TJSONString then
    Result := TJSONString(V).Value;
end;


// The list_tree node whose 'path' is APath, or NIL.
function FindNodeByPath(AComponents: TJSONArray; const APath: String): TJSONObject;
var
  i: Integer;
  Node: TJSONObject;
begin
  Result := NIL;
  for i := 0 to AComponents.Count - 1 do
  begin
    Node := AComponents.Items[i] as TJSONObject;
    if StringField(Node, 'path') = APath then
      exit(Node);
  end;
end;


{ TPathActionTests ------------------------------------------------------- }

procedure TPathActionTests.SetupFixture;
begin
  FPipeCounter := 0;
  FHost   := TPathHostForm.Create(NIL);
  FOwner  := TPathOwnerForm.CreateFor(TPathHostForm(FHost), 'PathOwnerForm',  TRUE);
  FOwner2 := TPathOwnerForm.CreateFor(TPathHostForm(FHost), 'PathOwnerForm2', FALSE);
end;


procedure TPathActionTests.Setup;
begin
  Inc(FPipeCounter);
  FPipeName := '\\.\pipe\AutopilotTestPA.' + IntToStr(GetCurrentProcessId) + '.' + IntToStr(FPipeCounter);

  TPathHostForm(FHost).CountedRuns   := 0;
  TPathHostForm(FHost).CountedSender := NIL;
  TPathHostForm(FHost).NoHandlerRuns := 0;
  TPathHostForm(FHost).ActCounted.Checked := FALSE;
  TPathOwnerForm(FOwner).InContainerClicks := 0;
  TPathHostForm(FHost).BtnOff.Caption := 'Off';
  TPathHostForm(FHost).BtnOff.Enabled := FALSE;

  StartBridgeOnPipe(FPipeName);
end;


procedure TPathActionTests.TearDown;
begin
  StopBridge;
end;


// The owner forms go first: their controls sit on the host's panel.
procedure TPathActionTests.TearDownFixture;
begin
  FreeAndNil(FOwner2);
  FreeAndNil(FOwner);
  FreeAndNil(FHost);
end;


// Kai's case: the panel is owned by PathOwnerForm but shown inside PathHostForm.pnlTabHost.
procedure TPathActionTests.Test_Path_ReparentedPanelResolvesThroughVisualParent;
var
  Root, R: TJSONObject;
begin
  Root := CallBridge(FPipeName, 'get_text', PathArgs('PathHostForm.pnlTabHost.pnlContainer'));
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'anchored path through the visual parent must resolve: ' + ErrorMessageOf(Root));
    Assert.AreEqual('Container', StringField(R, 'text'), 'wrong control for the anchored visual path');
  finally
    FreeAndNil(Root);
  end;

  Root := CallBridge(FPipeName, 'get_text', PathArgs('PathHostForm.pnlContainer'));
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'flat path through the visual parent must resolve: ' + ErrorMessageOf(Root));
    Assert.AreEqual('Container', StringField(R, 'text'), 'wrong control for the flat visual path');
  finally
    FreeAndNil(Root);
  end;
end;


procedure TPathActionTests.Test_Path_ReparentedButtonClickByAnchoredAndFlatPath;
var
  Root, R: TJSONObject;
begin
  Root := CallBridge(FPipeName, 'click', PathArgs('PathHostForm.pnlTabHost.pnlContainer.btnInContainer'));
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'click by the anchored visual path must succeed: ' + ErrorMessageOf(Root));
    Assert.AreEqual('click', StringField(R, 'dispatchedVia'), 'TButton must keep the Click dispatch');
  finally
    FreeAndNil(Root);
  end;
  Assert.AreEqual(1, TPathOwnerForm(FOwner).InContainerClicks, 'the anchored visual path must reach btnInContainer');

  Root := CallBridge(FPipeName, 'click', PathArgs('PathHostForm.btnInContainer'));
  try
    Assert.IsNotNull(GetOkResult(Root), 'click by the flat visual path must succeed: ' + ErrorMessageOf(Root));
  finally
    FreeAndNil(Root);
  end;
  Assert.AreEqual(2, TPathOwnerForm(FOwner).InContainerClicks, 'the flat visual path must reach btnInContainer');
end;


// Regression: the owner paths that resolved before the fix still resolve, to the same control.
procedure TPathActionTests.Test_Path_OwnerPathsStillResolve;
var
  Root, R: TJSONObject;
begin
  Root := CallBridge(FPipeName, 'click', PathArgs('PathOwnerForm.btnInContainer'));
  try
    Assert.IsNotNull(GetOkResult(Root), 'the owner path must still resolve: ' + ErrorMessageOf(Root));
  finally
    FreeAndNil(Root);
  end;
  Assert.AreEqual(1, TPathOwnerForm(FOwner).InContainerClicks, 'the owner path must reach btnInContainer');

  Root := CallBridge(FPipeName, 'get_text', PathArgs('PathOwnerForm2.btnDup'));
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'the owner path of a duplicated name must still resolve: ' + ErrorMessageOf(Root));
    Assert.AreEqual('PathOwnerForm2', StringField(R, 'text'), 'the owner path must pick its own form''s btnDup');
  finally
    FreeAndNil(Root);
  end;

  Root := CallBridge(FPipeName, 'get_text', PathArgs('PathHostForm.noSuchControl'));
  try
    Assert.AreEqual(ErrNotFound, GetErrorCode(Root), 'a name that exists nowhere must stay -32001');
  finally
    FreeAndNil(Root);
  end;
end;


// btnDup of PathOwnerForm and btnDup of PathOwnerForm2 both sit on PathHostForm.pnlTabHost.
procedure TPathActionTests.Test_Path_TwoVisualMatchesReturnAmbiguous;
var
  Root: TJSONObject;
  Msg: String;
begin
  Root := CallBridge(FPipeName, 'get_text', PathArgs('PathHostForm.btnDup'));
  try
    Assert.AreEqual(ErrAmbiguousPath, GetErrorCode(Root), 'two visual matches for a flat path must be -32002: ' + ErrorMessageOf(Root));
    Msg := ErrorMessageOf(Root);
  finally
    FreeAndNil(Root);
  end;
  Assert.Contains(Msg, 'PathOwnerForm.btnDup',  FALSE, 'the message must name the first candidate by its owner path');
  Assert.Contains(Msg, 'PathOwnerForm2.btnDup', FALSE, 'the message must name the second candidate by its owner path');

  Root := CallBridge(FPipeName, 'get_text', PathArgs('PathHostForm.pnlTabHost.btnDup'));
  try
    Assert.AreEqual(ErrAmbiguousPath, GetErrorCode(Root), 'two visual matches for an anchored path must be -32002: ' + ErrorMessageOf(Root));
  finally
    FreeAndNil(Root);
  end;
end;


procedure TPathActionTests.Test_ListTree_ReparentedControlCarriesParentField;
var
  Root, R, Node: TJSONObject;
  Arr: TJSONArray;
begin
  Root := CallBridge(FPipeName, 'list_tree', NIL);
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'list_tree should return ok');
    Arr := R.GetValue('components') as TJSONArray;
    Assert.IsNotNull(Arr, 'result.components missing');

    Node := FindNodeByPath(Arr, 'PathOwnerForm.pnlContainer');
    Assert.IsNotNull(Node, 'the re-parented panel must be listed under its owner form');
    Assert.AreEqual('PathHostForm.pnlTabHost', StringField(Node, 'parent'), 'a re-parented control must carry its visual parent');

    Node := FindNodeByPath(Arr, 'PathOwnerForm.btnDup');
    Assert.IsNotNull(Node, 'PathOwnerForm.btnDup must be listed');
    Assert.AreEqual('PathHostForm.pnlTabHost', StringField(Node, 'parent'), 'a re-parented button must carry its visual parent');

    // Its visual parent (pnlContainer) belongs to the same owner form: not re-parented, no field.
    Node := FindNodeByPath(Arr, 'PathOwnerForm.btnInContainer');
    Assert.IsNotNull(Node, 'PathOwnerForm.btnInContainer must be listed');
    Assert.IsNull(Node.GetValue('parent'), 'a control inside its own form''s panel must not carry a parent field');

    Node := FindNodeByPath(Arr, 'PathHostForm.pnlTabHost');
    Assert.IsNotNull(Node, 'PathHostForm.pnlTabHost must be listed');
    Assert.IsNull(Node.GetValue('parent'), 'an ordinary control must not carry a parent field');

    Node := FindNodeByPath(Arr, 'PathHostForm');
    Assert.IsNotNull(Node, 'the host form node must be listed');
    Assert.IsNull(Node.GetValue('parent'), 'a top-level form must not carry a parent field');
  finally
    FreeAndNil(Root);
  end;
end;


// TControl.Click (Vcl.Controls.pas) runs ActionLink.Execute -> TCustomAction.Execute: Sender is the action and AutoCheck toggles Checked. Calling the copied OnClick(Self) does neither.
procedure TPathActionTests.Test_Click_ActionBoundSpeedButtonRunsActionExecute;
var
  Root, R: TJSONObject;
begin
  Root := CallBridge(FPipeName, 'click', PathArgs('PathHostForm.sbCounted'));
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'click on an action-bound TSpeedButton must succeed: ' + ErrorMessageOf(Root));
    Assert.AreEqual('click', StringField(R, 'dispatchedVia'), 'an action-bound control must be dispatched through Click');
  finally
    FreeAndNil(Root);
  end;
  Assert.AreEqual(1, TPathHostForm(FHost).CountedRuns, 'the action''s OnExecute must run exactly once');
  Assert.IsTrue(TPathHostForm(FHost).CountedSender = TPathHostForm(FHost).ActCounted, 'OnExecute must receive the action as Sender (TCustomAction.Execute ran)');
  Assert.IsTrue(TPathHostForm(FHost).ActCounted.Checked, 'AutoCheck must toggle Checked (TCustomAction.Execute ran)');
end;


// A standard action (TFileExit, TEditCopy) has no OnExecute, so the button's OnClick stays NIL.
procedure TPathActionTests.Test_Click_ActionBoundSpeedButtonWithoutOnExecute;
var
  Root, R: TJSONObject;
begin
  Root := CallBridge(FPipeName, 'click', PathArgs('PathHostForm.sbNoHandler'));
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'click on a TSpeedButton bound to an action without OnExecute must succeed: ' + ErrorMessageOf(Root));
    Assert.AreEqual('click', StringField(R, 'dispatchedVia'), 'an action-bound control must be dispatched through Click');
  finally
    FreeAndNil(Root);
  end;
  Assert.AreEqual(1, TPathHostForm(FHost).NoHandlerRuns, 'the action must run once, through TActionList.OnExecute');
end;


procedure TPathActionTests.Test_ExecuteAction_RunsOnExecute;
var
  Root, R: TJSONObject;
  V: TJSONValue;
begin
  Root := CallBridge(FPipeName, 'execute_action', PathArgs('PathHostForm.actCounted'));
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'execute_action must succeed: ' + ErrorMessageOf(Root));
    Assert.AreEqual('Execute', StringField(R, 'dispatchedVia'), 'execute_action reports dispatchedVia=Execute');
    V := R.GetValue('executed');
    Assert.IsTrue((V is TJSONBool) and TJSONBool(V).AsBoolean, 'executed must be TRUE when OnExecute ran');
  finally
    FreeAndNil(Root);
  end;
  Assert.AreEqual(1, TPathHostForm(FHost).CountedRuns, 'execute_action must run OnExecute exactly once');
  Assert.IsTrue(TPathHostForm(FHost).CountedSender = TPathHostForm(FHost).ActCounted, 'OnExecute must receive the action as Sender');
end;


// set_property PathHostForm.acBox.FillColor := AValue. Fails the test on an error; returns the 'elided' flag.
function SetFill(const APipeName, AValue: String): Boolean;
var
  Root, R: TJSONObject;
  V: TJSONValue;
begin
  Root := CallBridge(APipeName, 'set_property', PropArgs('PathHostForm.acBox', 'FillColor', AValue));
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'set_property FillColor=' + AValue + ' must succeed: ' + ErrorMessageOf(Root));
    V := R.GetValue('elided');
    Assert.IsTrue(V is TJSONBool, 'set_property must report elided');
    Result := TJSONBool(V).AsBoolean;
  finally
    FreeAndNil(Root);
  end;
end;


// read_property PathHostForm.acBox.FillColor. Returns 'value'; AKind receives 'kind'.
function ReadFill(const APipeName: String; OUT AKind: String): String;
var
  Root, R: TJSONObject;
begin
  Root := CallBridge(APipeName, 'read_property', PropArgs('PathHostForm.acBox', 'FillColor', ''));
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'read_property FillColor must succeed: ' + ErrorMessageOf(Root));
    AKind  := StringField(R, 'kind');
    Result := StringField(R, 'value');
  finally
    FreeAndNil(Root);
  end;
end;


// AI-INSTRUCTIONS promises 'claRed'. System.UIConsts.AlphaColorToString strips the prefix and gives 'Red'.
procedure TPathActionTests.Test_ReadProperty_NamedAlphaColorReadsClaName;
var
  Kind, Value: String;
begin
  TPathHostForm(FHost).AcBox.FillColor := 0;
  Assert.IsFalse(SetFill(FPipeName, 'claRed'), 'the first write of claRed changes the value, so it must not be elided');
  Assert.AreEqual(Cardinal($FFFF0000), Cardinal(TPathHostForm(FHost).AcBox.FillColor), 'claRed must store $FFFF0000');

  Value := ReadFill(FPipeName, Kind);
  Assert.AreEqual('alphacolor', Kind, 'a TAlphaColor property must read with kind alphacolor');
  Assert.AreEqual('claRed', Value, 'a named TAlphaColor must read back as cla + name');

  Assert.IsTrue(SetFill(FPipeName, Value), 'writing back the value just read must be elided');
  Assert.IsTrue(SetFill(FPipeName, 'Red'), 'the bare name Red must parse to the same value, so it must be elided');
end;


// $FFFF8000 has no name in System.UIConsts, so it reads back as 8 hex digits.
procedure TPathActionTests.Test_ReadProperty_UnnamedAlphaColorReadsHex;
var
  Kind, Value: String;
begin
  TPathHostForm(FHost).AcBox.FillColor := 0;
  Assert.IsFalse(SetFill(FPipeName, '#FFFF8000'), 'the first write of #FFFF8000 changes the value, so it must not be elided');
  Assert.AreEqual(Cardinal($FFFF8000), Cardinal(TPathHostForm(FHost).AcBox.FillColor), '#FFFF8000 must store $FFFF8000');

  Value := ReadFill(FPipeName, Kind);
  Assert.AreEqual('alphacolor', Kind, 'a TAlphaColor property must read with kind alphacolor');
  Assert.AreEqual('#FFFF8000', Value, 'an unnamed TAlphaColor must read back as #AARRGGBB');

  Assert.IsTrue(SetFill(FPipeName, Value), 'writing back the value just read must be elided');
end;


// Without this exception, a control disabled through set_property could never be enabled again by any tool.
procedure TPathActionTests.Test_SetProperty_EnabledOnDisabledControlIsAllowed;
var
  Root, R: TJSONObject;
  V: TJSONValue;
begin
  // FALSE on a disabled control: allowed too (and elided, the value does not change). Lower case: the name match ignores case.
  Root := CallBridge(FPipeName, 'set_property', PropArgs('PathHostForm.btnOff', 'enabled', 'false'));
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'set_property enabled=false on a disabled control must succeed: ' + ErrorMessageOf(Root));
    V := R.GetValue('elided');
    Assert.IsTrue((V is TJSONBool) and TJSONBool(V).AsBoolean, 'enabled=false on a disabled control changes nothing, so it must be elided');
  finally
    FreeAndNil(Root);
  end;
  Assert.IsFalse(TPathHostForm(FHost).BtnOff.Enabled, 'btnOff must still be disabled');

  Root := CallBridge(FPipeName, 'set_property', PropArgs('PathHostForm.btnOff', 'Enabled', 'true'));
  try
    Assert.IsNotNull(GetOkResult(Root), 'set_property Enabled=true on a disabled control must succeed: ' + ErrorMessageOf(Root));
  finally
    FreeAndNil(Root);
  end;
  Assert.IsTrue(TPathHostForm(FHost).BtnOff.Enabled, 'btnOff must be enabled after set_property Enabled=true');
end;


procedure TPathActionTests.Test_SetProperty_OtherPropertyOnDisabledControlStillRejected;
var
  Root: TJSONObject;
begin
  Root := CallBridge(FPipeName, 'set_property', PropArgs('PathHostForm.btnOff', 'Caption', 'should not land'));
  try
    Assert.AreEqual(ErrControlDisabled, GetErrorCode(Root), 'Caption on a disabled control must still be -32003: ' + ErrorMessageOf(Root));
  finally
    FreeAndNil(Root);
  end;
  Assert.AreEqual('Off', TPathHostForm(FHost).BtnOff.Caption, 'the caption of the disabled button must be unchanged');
end;


initialization
  TDUnitX.RegisterTestFixture(TPathActionTests);

end.
