unit Tests.Bridge.ListTreeFilter;

{=============================================================================================================
   2026.11.17
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for the optional arguments of list_tree (VCL bridge):
       form      - only the nodes of the form with that name (case-insensitive): the form node and every component listed under it.
       formsOnly - only the form nodes.
       x, y      - only the control at that point of the form's client area (TListTreeAtTests).
   - A form that matches no form answers -32001, and the message names the forms that exist.
   - Without the arguments (or with form "" / formsOnly false) the answer is the same as before.
   - The expected nodes are taken from the unfiltered answer of the same bridge, so a filtered answer must be a byte-exact subset of it.
=============================================================================================================}

interface

uses
  System.JSON,
  Vcl.Forms,
  DUnitX.TestFramework;

type
  [TestFixture]
  TListTreeFilterTests = class
  private
    FPipeName   : String;
    FPipeCounter: Integer;
    FFormA      : TForm;
    FFormB      : TForm;
    FFormC      : TForm;
    function CallListTree(const AArgsJson: String): TJSONObject;
  public
    [SetupFixture]    procedure SetupFixture;
    [Setup]           procedure Setup;
    [TearDown]        procedure TearDown;
    [TearDownFixture] procedure TearDownFixture;

    [Test] procedure Test_ListTree_NoFilterArgs_AnswerUnchanged;
    [Test] procedure Test_ListTree_Form_ReturnsOnlyThatFormsNodes;
    [Test] procedure Test_ListTree_Form_IsCaseInsensitive;
    [Test] procedure Test_ListTree_UnknownForm_Returns32001NamingTheForms;
    [Test] procedure Test_ListTree_FormsOnly_ReturnsOnlyFormNodes;
    [Test] procedure Test_ListTree_FormAndFormsOnly_ReturnsThatFormNodeOnly;
    [Test] procedure Test_ListTree_BadArgumentTypes_ReturnInvalidRequest;
    [Test] procedure Test_ListTree_Path_ReturnsTheNodeAndWhatLiesUnderIt;
    [Test] procedure Test_ListTree_Path_OfAForm_EqualsTheFormFilter;
    [Test] procedure Test_ListTree_Path_CombinesWithFormAndFormsOnly;
    [Test] procedure Test_ListTree_Path_UnknownOrBadType_IsRefused;
  end;

  { list_tree x, y: the control at a point of the form's client area (the pixel of an unscaled, uncropped screenshot).
    Every expected point is computed from the controls through Win32 MapWindowPoints, never from constants.
    Every returned path is sent back to read_property Tag: each control of the form has its own Tag, so the round trip shows the path leads to that very control. }
  [TestFixture]
  TListTreeAtTests = class
  private
    FPipeName   : String;
    FPipeCounter: Integer;
    FForm       : TForm;
    function CallListTree(const AArgsJson: String): TJSONObject;
    function ReadTag(const APath: String): String;
    procedure CheckHit(const AWhat: String; AX, AY: Integer; const AExpectedPath: String; AExpectedTag: Integer);
  public
    [SetupFixture]    procedure SetupFixture;
    [Setup]           procedure Setup;
    [TearDown]        procedure TearDown;
    [TearDownFixture] procedure TearDownFixture;

    [Test] procedure Test_ListTreeAt_TwoTabSheets_ReturnsTheControlOnTheActivePage;
    [Test] procedure Test_ListTreeAt_LabelInPanel_ReturnsTheLabel;
    [Test] procedure Test_ListTreeAt_UnownedControl_ClimbsToTheNearestListedParent;
    [Test] procedure Test_ListTreeAt_FormBackground_ReturnsTheFormNode;
    [Test] procedure Test_ListTreeAt_CombinesWithFormsOnlyAndPath;
    [Test] procedure Test_ListTreeAt_MinimizedForm_ReturnsTheSameControl;
    [Test] procedure Test_ListTreeAt_OutsideTheClientArea_Returns32001;
    [Test] procedure Test_ListTreeAt_BadArguments_ReturnInvalidRequest;
  end;


implementation

uses
  Winapi.Windows,   // GetCurrentProcessId for the pipe name
  System.SysUtils, System.Classes, System.Types, System.Generics.Collections,
  Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls,
  Autopilot.Bridge.Core, Autopilot.Bridge.Vcl,
  Bridge.TestClient, Bridge.Tests;


const
  FormAName = 'FilterFormA';
  FormBName = 'FilterFormB';
  FormCName = 'FilterFormC';

type
  // A form with a button and a panel that owns a label (so the walk goes deeper than one level).
  TFilterFormA = class(TForm)
  public
    constructor Create(AOwner: TComponent); override;
  end;

  // A second form with one button: its nodes must never appear in a form=FilterFormA answer.
  TFilterFormB = class(TForm)
  public
    constructor Create(AOwner: TComponent); override;
  end;

  { The form for the path filter.
    pnlC owns lblOwned; lblShown, pnlInner and lblDeep are owned by the form but shown inside pnlC (lblDeep inside pnlInner); btnOutside is outside pnlC. }
  TFilterFormC = class(TForm)
  public
    constructor Create(AOwner: TComponent); override;
  end;


constructor TFilterFormC.Create(AOwner: TComponent);
var
  PnlC, PnlInner: TPanel;
  Lbl: TLabel;
  Btn: TButton;
begin
  inherited CreateNew(AOwner);
  Name    := FormCName;
  Caption := 'Filter C';
  Btn := TButton.Create(Self);
  Btn.Name   := 'btnOutside';
  Btn.Parent := Self;
  PnlC := TPanel.Create(Self);
  PnlC.Name   := 'pnlC';
  PnlC.Parent := Self;
  Lbl := TLabel.Create(PnlC);
  Lbl.Name   := 'lblOwned';
  Lbl.Parent := PnlC;
  Lbl := TLabel.Create(Self);
  Lbl.Name   := 'lblShown';
  Lbl.Parent := PnlC;
  PnlInner := TPanel.Create(Self);
  PnlInner.Name   := 'pnlInner';
  PnlInner.Parent := PnlC;
  Lbl := TLabel.Create(Self);
  Lbl.Name   := 'lblDeep';
  Lbl.Parent := PnlInner;
end;


constructor TFilterFormA.Create(AOwner: TComponent);
var
  Btn: TButton;
  Pnl: TPanel;
  Lbl: TLabel;
begin
  inherited CreateNew(AOwner);
  Name    := FormAName;
  Caption := 'Filter A';
  Btn := TButton.Create(Self);
  Btn.Name    := 'btnA';
  Btn.Caption := 'Button A';
  Btn.Parent  := Self;
  Pnl := TPanel.Create(Self);
  Pnl.Name   := 'pnlA';
  Pnl.Parent := Self;
  Lbl := TLabel.Create(Pnl);   // owned by the panel: listed as FilterFormA.pnlA.lblInA
  Lbl.Name    := 'lblInA';
  Lbl.Caption := 'In panel A';
  Lbl.Parent  := Pnl;
end;


constructor TFilterFormB.Create(AOwner: TComponent);
var
  Btn: TButton;
begin
  inherited CreateNew(AOwner);
  Name    := FormBName;
  Caption := 'Filter B';
  Btn := TButton.Create(Self);
  Btn.Name    := 'btnB';
  Btn.Caption := 'Button B';
  Btn.Parent  := Self;
end;


{ Helpers --------------------------------------------------------------- }

// The components array of a successful list_tree answer (owned by ARoot); fails the test otherwise.
function ComponentsOf(ARoot: TJSONObject; const AWhat: String): TJSONArray;
var
  R: TJSONObject;
begin
  R := GetOkResult(ARoot);
  if R = NIL then
    begin
      if ARoot = NIL
      then Assert.Fail(AWhat + ': no answer')
      else Assert.Fail(AWhat + ': list_tree failed: ' + ARoot.ToJSON);
    end;
  Result := R.GetValue('components') as TJSONArray;
  Assert.IsNotNull(Result, AWhat + ': result.components missing');
end;


function StrField(ANode: TJSONValue; const AName: String): String;
var
  V: TJSONValue;
begin
  V := (ANode as TJSONObject).GetValue(AName);
  if V is TJSONString
  then Result := TJSONString(V).Value
  else Result := '';
end;


// The nodes of AComponents whose field 'form' is AForm (exact case), each as ToJSON, one per line.
function NodesOfForm(AComponents: TJSONArray; const AForm: String): String;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to AComponents.Count - 1 do
    if StrField(AComponents.Items[i], 'form') = AForm
    then Result := Result + AComponents.Items[i].ToJSON + sLineBreak;
end;


// Every node of AComponents as ToJSON, one per line.
function AllNodes(AComponents: TJSONArray): String;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to AComponents.Count - 1 do
    Result := Result + AComponents.Items[i].ToJSON + sLineBreak;
end;


// The form nodes of AComponents (path = form name), each as ToJSON, one per line.
function FormNodes(AComponents: TJSONArray): String;
var
  i: Integer;
  Node: TJSONValue;
begin
  Result := '';
  for i := 0 to AComponents.Count - 1 do
    begin
      Node := AComponents.Items[i];
      if StrField(Node, 'path') = StrField(Node, 'form')
      then Result := Result + Node.ToJSON + sLineBreak;
    end;
end;


function HasPath(AComponents: TJSONArray; const APath: String): Boolean;
var
  i: Integer;
begin
  for i := 0 to AComponents.Count - 1 do
    if StrField(AComponents.Items[i], 'path') = APath then EXIT(TRUE);
  Result := FALSE;
end;


function ErrorMessageOf(ARoot: TJSONObject): String;
var
  V: TJSONValue;
begin
  Result := '';
  if ARoot = NIL then EXIT;
  V := ARoot.GetValue('error');
  if V is TJSONObject
  then Result := StrField(V, 'message');
end;


{ Sends ACmd with the arguments AArgsJson ('' = no arguments) to the bridge on APipeName and returns the whole answer (the caller frees it). }
function CallCommand(const APipeName, ACmd, AArgsJson: String): TJSONObject;
var
  Root: TJSONObject;
begin
  Root := NIL;
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args: TJSONObject;
    begin
      if AArgsJson = ''
      then Args := NIL
      else Args := TJSONObject.ParseJSONValue(AArgsJson) as TJSONObject;   // Call owns Args from here
      Client := TBridgeTestClient.Create;
      try
        if not Client.ConnectAndHandshake(APipeName, 2000) then
          begin
            FreeAndNil(Args);
            Assert.Fail('connect to ' + APipeName + ' failed');
          end;
        Root := Client.Call(1, ACmd, Args);
      finally
        FreeAndNil(Client);
      end;
    end, 5000);
  Result := Root;
end;


{ TListTreeFilterTests ---------------------------------------------------- }

procedure TListTreeFilterTests.SetupFixture;
begin
  FPipeCounter := 0;
  FFormA := TFilterFormA.Create(NIL);
  FFormB := TFilterFormB.Create(NIL);
  FFormC := TFilterFormC.Create(NIL);
end;


procedure TListTreeFilterTests.Setup;
begin
  Inc(FPipeCounter);
  FPipeName := '\\.\pipe\AutopilotTestListTreeFilter.' + IntToStr(GetCurrentProcessId) + '.' + IntToStr(FPipeCounter);
  StartBridgeOnPipe(FPipeName);
end;


procedure TListTreeFilterTests.TearDown;
begin
  StopBridge;
end;


procedure TListTreeFilterTests.TearDownFixture;
begin
  FreeAndNil(FFormC);
  FreeAndNil(FFormB);
  FreeAndNil(FFormA);
end;


{ Sends list_tree with the arguments AArgsJson ('' = no arguments) and returns the whole answer (the caller frees it). }
function TListTreeFilterTests.CallListTree(const AArgsJson: String): TJSONObject;
var
  Root: TJSONObject;
  PipeName, ArgsJson: String;
begin
  PipeName := FPipeName;
  ArgsJson := AArgsJson;
  Root := NIL;
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args: TJSONObject;
    begin
      if ArgsJson = ''
      then Args := NIL
      else Args := TJSONObject.ParseJSONValue(ArgsJson) as TJSONObject;   // Call owns Args from here
      Client := TBridgeTestClient.Create;
      try
        if not Client.ConnectAndHandshake(PipeName, 2000) then
          begin
            FreeAndNil(Args);
            Assert.Fail('connect to ' + PipeName + ' failed');
          end;
        Root := Client.Call(1, 'list_tree', Args);
      finally
        FreeAndNil(Client);
      end;
    end, 5000);
  Result := Root;
end;


{ A pin, green before the filter existed: an empty argument object, form "" and formsOnly false all give the answer of a call without arguments. }
procedure TListTreeFilterTests.Test_ListTree_NoFilterArgs_AnswerUnchanged;
var
  Plain, Empty, NoForm, NotOnly: TJSONObject;
  Expected: String;
begin
  Plain := NIL; Empty := NIL; NoForm := NIL; NotOnly := NIL;
  try
    Plain   := CallListTree('');
    Empty   := CallListTree('{}');
    NoForm  := CallListTree('{"form":""}');
    NotOnly := CallListTree('{"formsOnly":false}');
    Expected := AllNodes(ComponentsOf(Plain, 'no arguments'));
    Assert.IsTrue(HasPath(ComponentsOf(Plain, 'no arguments'), FormAName + '.pnlA.lblInA'), 'the unfiltered answer must list the nested label');
    Assert.IsTrue(HasPath(ComponentsOf(Plain, 'no arguments'), FormBName + '.btnB'), 'the unfiltered answer must list the other form''s button');
    Assert.AreEqual(Expected, AllNodes(ComponentsOf(Empty,   '{}')),                  '{} must give the unfiltered answer');
    Assert.AreEqual(Expected, AllNodes(ComponentsOf(NoForm,  'form ""')),             'form "" must give the unfiltered answer');
    Assert.AreEqual(Expected, AllNodes(ComponentsOf(NotOnly, 'formsOnly false')),     'formsOnly false must give the unfiltered answer');
  finally
    FreeAndNil(NotOnly);
    FreeAndNil(NoForm);
    FreeAndNil(Empty);
    FreeAndNil(Plain);
  end;
end;


procedure TListTreeFilterTests.Test_ListTree_Form_ReturnsOnlyThatFormsNodes;
var
  Plain, Filtered: TJSONObject;
  Comps: TJSONArray;
  Expected: String;
  i: Integer;
begin
  Plain := NIL; Filtered := NIL;
  try
    Plain    := CallListTree('');
    Filtered := CallListTree('{"form":"' + FormAName + '"}');
    Expected := NodesOfForm(ComponentsOf(Plain, 'no arguments'), FormAName);
    Comps    := ComponentsOf(Filtered, 'form ' + FormAName);

    Assert.AreEqual(4, Comps.Count, 'FilterFormA has 4 nodes: the form, btnA, pnlA and pnlA.lblInA. Got: ' + AllNodes(Comps));
    for i := 0 to Comps.Count - 1 do
      Assert.AreEqual(FormAName, StrField(Comps.Items[i], 'form'), 'a node of another form leaked in: ' + Comps.Items[i].ToJSON);
    Assert.AreEqual(FormAName, StrField(Comps.Items[0], 'path'), 'the first node must be the form itself');
    Assert.AreEqual(Expected, AllNodes(Comps), 'the nodes must be exactly the FilterFormA nodes of the unfiltered answer, in the same order');
  finally
    FreeAndNil(Filtered);
    FreeAndNil(Plain);
  end;
end;


procedure TListTreeFilterTests.Test_ListTree_Form_IsCaseInsensitive;
var
  Exact, Lower: TJSONObject;
  Comps: TJSONArray;
begin
  Exact := NIL; Lower := NIL;
  try
    Exact := CallListTree('{"form":"' + FormAName + '"}');
    Lower := CallListTree('{"form":"' + LowerCase(FormAName) + '"}');
    Comps := ComponentsOf(Lower, 'form ' + LowerCase(FormAName));
    Assert.AreEqual(4, Comps.Count, 'form in lower case must still find FilterFormA. Got: ' + AllNodes(Comps));
    Assert.AreEqual(FormAName, StrField(Comps.Items[0], 'path'), 'the path keeps the form''s own spelling');
    Assert.AreEqual(AllNodes(ComponentsOf(Exact, 'form ' + FormAName)), AllNodes(Comps), 'lower case and exact case must give the same nodes');
  finally
    FreeAndNil(Lower);
    FreeAndNil(Exact);
  end;
end;


procedure TListTreeFilterTests.Test_ListTree_UnknownForm_Returns32001NamingTheForms;
var
  Root: TJSONObject;
  Msg: String;
begin
  Root := CallListTree('{"form":"NoSuchFormXyz"}');
  try
    Assert.IsNotNull(Root, 'no answer');
    Assert.IsNull(GetOkResult(Root), 'an unknown form must not succeed: ' + Root.ToJSON);
    Assert.AreEqual(ErrNotFound, GetErrorCode(Root), 'an unknown form must answer -32001: ' + Root.ToJSON);
    Msg := ErrorMessageOf(Root);
    Assert.IsTrue(Msg.Contains('NoSuchFormXyz'), 'the message must name the form asked for: ' + Msg);
    Assert.IsTrue(Msg.Contains(FormAName), 'the message must list FilterFormA: ' + Msg);
    Assert.IsTrue(Msg.Contains(FormBName), 'the message must list FilterFormB: ' + Msg);
  finally
    FreeAndNil(Root);
  end;
end;


procedure TListTreeFilterTests.Test_ListTree_FormsOnly_ReturnsOnlyFormNodes;
var
  Plain, Only: TJSONObject;
  Comps: TJSONArray;
  i: Integer;
begin
  Plain := NIL; Only := NIL;
  try
    Plain := CallListTree('');
    Only  := CallListTree('{"formsOnly":true}');
    Comps := ComponentsOf(Only, 'formsOnly');
    for i := 0 to Comps.Count - 1 do
      Assert.AreEqual(StrField(Comps.Items[i], 'form'), StrField(Comps.Items[i], 'path'), 'formsOnly returned a node that is not a form: ' + Comps.Items[i].ToJSON);
    Assert.IsTrue(HasPath(Comps, FormAName), 'FilterFormA must be listed');
    Assert.IsTrue(HasPath(Comps, FormBName), 'FilterFormB must be listed');
    Assert.IsFalse(HasPath(Comps, FormAName + '.btnA'), 'a child control must not be listed');
    Assert.AreEqual(FormNodes(ComponentsOf(Plain, 'no arguments')), AllNodes(Comps), 'the form nodes must be exactly those of the unfiltered answer, in the same order');
  finally
    FreeAndNil(Only);
    FreeAndNil(Plain);
  end;
end;


procedure TListTreeFilterTests.Test_ListTree_FormAndFormsOnly_ReturnsThatFormNodeOnly;
var
  Root: TJSONObject;
  Comps: TJSONArray;
begin
  Root := CallListTree('{"form":"' + FormBName + '","formsOnly":true}');
  try
    Comps := ComponentsOf(Root, 'form + formsOnly');
    Assert.AreEqual(1, Comps.Count, 'form and formsOnly together must give that one form node. Got: ' + AllNodes(Comps));
    Assert.AreEqual(FormBName, StrField(Comps.Items[0], 'path'), 'wrong node');
  finally
    FreeAndNil(Root);
  end;
end;


procedure TListTreeFilterTests.Test_ListTree_BadArgumentTypes_ReturnInvalidRequest;
var
  Root: TJSONObject;
begin
  Root := CallListTree('{"form":5}');
  try
    Assert.IsNotNull(Root, 'no answer for form 5');
    Assert.AreEqual(ErrInvalidRequest, GetErrorCode(Root), 'form that is not a string must answer -32600: ' + Root.ToJSON);
    Assert.IsTrue(ErrorMessageOf(Root).Contains('form'), 'the message must name the argument: ' + Root.ToJSON);
  finally
    FreeAndNil(Root);
  end;

  Root := CallListTree('{"formsOnly":"yes"}');
  try
    Assert.IsNotNull(Root, 'no answer for formsOnly "yes"');
    Assert.AreEqual(ErrInvalidRequest, GetErrorCode(Root), 'formsOnly that is not a Boolean must answer -32600: ' + Root.ToJSON);
    Assert.IsTrue(ErrorMessageOf(Root).Contains('formsOnly'), 'the message must name the argument: ' + Root.ToJSON);
  finally
    FreeAndNil(Root);
  end;
end;


// The nodes of AComponents whose path is one of APaths, in the order of AComponents, each as ToJSON, one per line.
function NodesWithPaths(AComponents: TJSONArray; const APaths: array of String): String;
var
  i, k: Integer;
begin
  Result := '';
  for i := 0 to AComponents.Count - 1 do
    for k := 0 to High(APaths) do
      if StrField(AComponents.Items[i], 'path') = APaths[k] then
        begin
          Result := Result + AComponents.Items[i].ToJSON + sLineBreak;
          Break;
        end;
end;


{ path keeps the node and every component under it: owned by it (lblOwned) or shown inside it (lblShown, and lblDeep through pnlInner).
  Each node is byte-identical to the same node of the unfiltered answer, in the same order. }
procedure TListTreeFilterTests.Test_ListTree_Path_ReturnsTheNodeAndWhatLiesUnderIt;
var
  Plain, Filtered: TJSONObject;
  Comps: TJSONArray;
  Expected: String;
begin
  Plain := NIL; Filtered := NIL;
  try
    Plain    := CallListTree('');
    Filtered := CallListTree('{"path":"' + FormCName + '.pnlC"}');
    Expected := NodesWithPaths(ComponentsOf(Plain, 'no arguments'),
                  [FormCName + '.pnlC', FormCName + '.pnlC.lblOwned', FormCName + '.lblShown', FormCName + '.pnlInner', FormCName + '.lblDeep']);
    Comps := ComponentsOf(Filtered, 'path pnlC');
    Assert.AreEqual(5, Comps.Count, 'pnlC, lblOwned, lblShown, pnlInner and lblDeep. Got: ' + AllNodes(Comps));
    Assert.IsFalse(HasPath(Comps, FormCName + '.btnOutside'), 'a control outside pnlC must not be listed');
    Assert.IsFalse(HasPath(Comps, FormCName), 'the form node must not be listed');
    Assert.AreEqual(Expected, AllNodes(Comps), 'the nodes must be exactly those of the unfiltered answer, in the same order');
  finally
    FreeAndNil(Filtered);
    FreeAndNil(Plain);
  end;
end;


procedure TListTreeFilterTests.Test_ListTree_Path_OfAForm_EqualsTheFormFilter;
var
  ByForm, ByPath: TJSONObject;
begin
  ByForm := NIL; ByPath := NIL;
  try
    ByForm := CallListTree('{"form":"' + FormCName + '"}');
    ByPath := CallListTree('{"path":"' + FormCName + '"}');
    Assert.AreEqual(AllNodes(ComponentsOf(ByForm, 'form C')), AllNodes(ComponentsOf(ByPath, 'path C')), 'path of a form must give what form gives');
  finally
    FreeAndNil(ByPath);
    FreeAndNil(ByForm);
  end;
end;


// The filters just combine: a node is listed only when every filter given keeps it.
procedure TListTreeFilterTests.Test_ListTree_Path_CombinesWithFormAndFormsOnly;
var
  Root: TJSONObject;
begin
  Root := CallListTree('{"path":"' + FormCName + '.pnlC","form":"' + FormAName + '"}');
  try
    Assert.AreEqual(0, ComponentsOf(Root, 'path in C, form A').Count, 'pnlC lies in another form: nothing is left. Got: ' + Root.ToJSON);
  finally
    FreeAndNil(Root);
  end;

  Root := CallListTree('{"path":"' + FormCName + '.pnlC","formsOnly":true}');
  try
    Assert.AreEqual(0, ComponentsOf(Root, 'path pnlC, formsOnly').Count, 'no form lies under pnlC. Got: ' + Root.ToJSON);
  finally
    FreeAndNil(Root);
  end;

  Root := CallListTree('{"path":"' + FormCName + '","formsOnly":true}');
  try
    Assert.AreEqual(1, ComponentsOf(Root, 'path C, formsOnly').Count, 'the form node of C only. Got: ' + Root.ToJSON);
    Assert.AreEqual(FormCName, StrField(ComponentsOf(Root, 'path C, formsOnly').Items[0], 'path'), 'wrong node');
  finally
    FreeAndNil(Root);
  end;
end;


procedure TListTreeFilterTests.Test_ListTree_Path_UnknownOrBadType_IsRefused;
var
  Root: TJSONObject;
begin
  Root := CallListTree('{"path":"' + FormCName + '.noSuchControl"}');
  try
    Assert.AreEqual(ErrNotFound, GetErrorCode(Root), 'an unknown path must answer -32001: ' + Root.ToJSON);
    Assert.IsTrue(ErrorMessageOf(Root).Contains('noSuchControl'), 'the message must name the path: ' + Root.ToJSON);
  finally
    FreeAndNil(Root);
  end;

  Root := CallListTree('{"path":7}');
  try
    Assert.AreEqual(ErrInvalidRequest, GetErrorCode(Root), 'a path that is not a string must answer -32600: ' + Root.ToJSON);
    Assert.IsTrue(ErrorMessageOf(Root).Contains('path'), 'the message must name the argument: ' + Root.ToJSON);
  finally
    FreeAndNil(Root);
  end;
end;


{ TListTreeAtTests ------------------------------------------------------- }

const
  AtFormName = 'AtForm';

type
  { pgc holds two tab sheets with a button at the same place (btnOne, btnTwo).
    pnlHost owns lblInPanel and shows btnUnowned, a button that no component owns, so list_tree never lists it.
    Each control has its own Tag (the form 1), for the read_property round trip. }
  TAtForm = class(TForm)
  public
    Pgc       : TPageControl;
    TsOne     : TTabSheet;
    TsTwo     : TTabSheet;
    BtnOne    : TButton;
    BtnTwo    : TButton;
    PnlHost   : TPanel;
    LblInPanel: TLabel;
    BtnUnowned: TButton;
    constructor Create(AOwner: TComponent); override;
  end;


constructor TAtForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Name         := AtFormName;
  Caption      := 'At';
  Tag          := 1;
  Position     := poDesigned;
  SetBounds(40, 40, 420, 260);

  Pgc := TPageControl.Create(Self);
  Pgc.Name   := 'pgc';
  Pgc.Tag    := 2;
  Pgc.Parent := Self;
  Pgc.SetBounds(10, 10, 200, 150);
  TsOne := TTabSheet.Create(Self);
  TsOne.Name        := 'tsOne';
  TsOne.Tag         := 3;
  TsOne.PageControl := Pgc;
  TsTwo := TTabSheet.Create(Self);
  TsTwo.Name        := 'tsTwo';
  TsTwo.Tag         := 4;
  TsTwo.PageControl := Pgc;
  BtnOne := TButton.Create(Self);
  BtnOne.Name   := 'btnOne';
  BtnOne.Tag    := 5;
  BtnOne.Parent := TsOne;
  BtnOne.SetBounds(20, 20, 80, 25);
  BtnTwo := TButton.Create(Self);
  BtnTwo.Name   := 'btnTwo';
  BtnTwo.Tag    := 6;
  BtnTwo.Parent := TsTwo;
  BtnTwo.SetBounds(20, 20, 80, 25);   // the same place as btnOne, on the other page
  Pgc.ActivePage := TsTwo;

  PnlHost := TPanel.Create(Self);
  PnlHost.Name   := 'pnlHost';
  PnlHost.Tag    := 7;
  PnlHost.Parent := Self;
  PnlHost.SetBounds(230, 10, 160, 150);
  LblInPanel := TLabel.Create(PnlHost);   // owned by the panel: AtForm.pnlHost.lblInPanel
  LblInPanel.Name     := 'lblInPanel';
  LblInPanel.Tag      := 8;
  LblInPanel.AutoSize := FALSE;
  LblInPanel.Parent   := PnlHost;
  LblInPanel.SetBounds(10, 10, 100, 20);
  BtnUnowned := TButton.Create(NIL);      // the panel frees it: a TWinControl frees its child controls
  BtnUnowned.Name   := 'btnUnowned';
  BtnUnowned.Tag    := 9;
  BtnUnowned.Parent := PnlHost;
  BtnUnowned.SetBounds(10, 60, 100, 25);
end;


// The middle of ACtrl in the client coordinates of AForm, mapped by Win32 from the client coordinates of its parent.
function MiddleInForm(AForm: TForm; ACtrl: TControl): TPoint;
begin
  Assert.IsTrue(AForm.HandleAllocated and ACtrl.Parent.HandleAllocated, 'fixture: the form and the parent of ' + ACtrl.Name + ' must have a window');
  Result := Point(ACtrl.Left + ACtrl.Width div 2, ACtrl.Top + ACtrl.Height div 2);
  MapWindowPoints(ACtrl.Parent.Handle, AForm.Handle, Result, 1);
end;


function PointArgs(AX, AY: Integer; const AExtra: String = ''): String;
begin
  Result := '{"form":"' + AtFormName + '","x":' + IntToStr(AX) + ',"y":' + IntToStr(AY) + AExtra + '}';
end;


procedure TListTreeAtTests.SetupFixture;
begin
  FPipeCounter := 0;
  FForm := TAtForm.Create(NIL);
  FForm.Visible := TRUE;   // ShowWindow alone would show only the form's own window, not the child windows (Tests.Bridge.ScreenshotNative)
end;


procedure TListTreeAtTests.Setup;
begin
  Inc(FPipeCounter);
  FPipeName := '\\.\pipe\AutopilotTestListTreeAt.' + IntToStr(GetCurrentProcessId) + '.' + IntToStr(FPipeCounter);
  StartBridgeOnPipe(FPipeName);
end;


procedure TListTreeAtTests.TearDown;
begin
  StopBridge;
end;


procedure TListTreeAtTests.TearDownFixture;
begin
  FreeAndNil(FForm);
end;


function TListTreeAtTests.CallListTree(const AArgsJson: String): TJSONObject;
begin
  Result := CallCommand(FPipeName, 'list_tree', AArgsJson);
end;


// The value read_property gives for the Tag of APath; fails the test when the path does not resolve.
function TListTreeAtTests.ReadTag(const APath: String): String;
var
  Root, R: TJSONObject;
begin
  Root := CallCommand(FPipeName, 'read_property', '{"path":"' + APath + '","propName":"Tag"}');
  try
    R := GetOkResult(Root);
    if R = NIL
    then Assert.Fail('read_property Tag of ' + APath + ' failed: ' + Root.ToJSON);
    Result := StrField(R, 'value');
  finally
    FreeAndNil(Root);
  end;
end;


{ list_tree at AX, AY must answer exactly one node, at AExpectedPath, byte-identical to the node with that path in the form=AtForm answer, with the point in the answer's x and y.
  The path must lead back to the control whose Tag is AExpectedTag. }
procedure TListTreeAtTests.CheckHit(const AWhat: String; AX, AY: Integer; const AExpectedPath: String; AExpectedTag: Integer);
var
  Root, Full, R: TJSONObject;
  Comps, FullComps: TJSONArray;
  i: Integer;
  Expected: String;
begin
  Full := CallListTree('{"form":"' + AtFormName + '"}');
  Root := CallListTree(PointArgs(AX, AY));
  try
    FullComps := ComponentsOf(Full, AWhat + ', the full answer');
    Expected := '';
    for i := 0 to FullComps.Count - 1 do
      if StrField(FullComps.Items[i], 'path') = AExpectedPath
      then Expected := FullComps.Items[i].ToJSON;
    Assert.AreNotEqual('', Expected, AWhat + ': fixture: the full answer must list ' + AExpectedPath);

    Comps := ComponentsOf(Root, AWhat);
    Assert.AreEqual(1, Comps.Count, AWhat + ': the answer must hold exactly one node: ' + Root.ToJSON);
    Assert.AreEqual(Expected, Comps.Items[0].ToJSON, AWhat + ': the node must be the one the full answer lists at ' + AExpectedPath);
    R := GetOkResult(Root);
    Assert.AreEqual(IntToStr(AX), R.GetValue('x').Value, AWhat + ': the answer must carry x');
    Assert.AreEqual(IntToStr(AY), R.GetValue('y').Value, AWhat + ': the answer must carry y');
  finally
    FreeAndNil(Root);
    FreeAndNil(Full);
  end;
  Assert.AreEqual(IntToStr(AExpectedTag), ReadTag(AExpectedPath), AWhat + ': the path must lead back to the control with Tag ' + IntToStr(AExpectedTag));
end;


{ ControlAtPos with AllLevels would also find btnOne on the hidden page; the walk goes one level at a time, so only the active page counts. }
procedure TListTreeAtTests.Test_ListTreeAt_TwoTabSheets_ReturnsTheControlOnTheActivePage;
var
  F: TAtForm;
  P: TPoint;
begin
  F := TAtForm(FForm);
  P := MiddleInForm(F, F.BtnTwo);
  // The inactive page has no window yet, so MiddleInForm cannot map btnOne: both buttons and both pages must have the same bounds instead.
  Assert.IsTrue(F.BtnOne.BoundsRect = F.BtnTwo.BoundsRect, 'fixture: both buttons must have the same bounds');
  Assert.IsTrue(F.TsOne.BoundsRect = F.TsTwo.BoundsRect, 'fixture: both pages must have the same bounds');
  CheckHit('tsTwo active', P.X, P.Y, AtFormName + '.btnTwo', 6);
  F.Pgc.ActivePage := F.TsOne;
  try
    CheckHit('tsOne active', P.X, P.Y, AtFormName + '.btnOne', 5);
  finally
    F.Pgc.ActivePage := F.TsTwo;
  end;
end;


procedure TListTreeAtTests.Test_ListTreeAt_LabelInPanel_ReturnsTheLabel;
var
  P: TPoint;
begin
  P := MiddleInForm(FForm, TAtForm(FForm).LblInPanel);
  CheckHit('the label', P.X, P.Y, AtFormName + '.pnlHost.lblInPanel', 8);
end;


{ btnUnowned is not in list_tree (no form owns it), so its path would not lead anywhere: the answer climbs to the panel that shows it. }
procedure TListTreeAtTests.Test_ListTreeAt_UnownedControl_ClimbsToTheNearestListedParent;
var
  P: TPoint;
begin
  P := MiddleInForm(FForm, TAtForm(FForm).BtnUnowned);
  CheckHit('the unowned button', P.X, P.Y, AtFormName + '.pnlHost', 7);
end;


procedure TListTreeAtTests.Test_ListTreeAt_FormBackground_ReturnsTheFormNode;
begin
  CheckHit('the form background', 5, FForm.ClientHeight - 5, AtFormName, 1);
end;


{ The filters combine by intersection: formsOnly keeps the hit only when it is the form, path only when it lies under that control. }
procedure TListTreeAtTests.Test_ListTreeAt_CombinesWithFormsOnlyAndPath;
var
  P: TPoint;
  Root: TJSONObject;
begin
  P := MiddleInForm(FForm, TAtForm(FForm).LblInPanel);

  Root := CallListTree(PointArgs(P.X, P.Y, ',"formsOnly":true'));
  try
    Assert.AreEqual(0, ComponentsOf(Root, 'formsOnly').Count, 'formsOnly on a label must answer no node: ' + Root.ToJSON);
  finally
    FreeAndNil(Root);
  end;

  Root := CallListTree(PointArgs(P.X, P.Y, ',"path":"' + AtFormName + '.pnlHost"'));
  try
    Assert.AreEqual(1, ComponentsOf(Root, 'path pnlHost').Count, 'the label lies under pnlHost: ' + Root.ToJSON);
    Assert.AreEqual(AtFormName + '.pnlHost.lblInPanel', StrField(ComponentsOf(Root, 'path pnlHost').Items[0], 'path'));
  finally
    FreeAndNil(Root);
  end;

  Root := CallListTree(PointArgs(P.X, P.Y, ',"path":"' + AtFormName + '.pgc"'));
  try
    Assert.AreEqual(0, ComponentsOf(Root, 'path pgc').Count, 'the label does not lie under pgc: ' + Root.ToJSON);
  finally
    FreeAndNil(Root);
  end;
end;


{ A minimized form keeps its restored client size in VCL (TCustomForm.GetClientRect), while Win32 GetClientRect answers 0 x 0: the point must still find the control. }
procedure TListTreeAtTests.Test_ListTreeAt_MinimizedForm_ReturnsTheSameControl;
var
  P, PLabel: TPoint;
begin
  P      := MiddleInForm(FForm, TAtForm(FForm).BtnTwo);
  PLabel := MiddleInForm(FForm, TAtForm(FForm).LblInPanel);
  ShowWindow(FForm.Handle, SW_SHOWMINNOACTIVE);
  try
    Assert.IsTrue(IsIconic(FForm.Handle), 'fixture: the form must be minimized');
    CheckHit('minimized, btnTwo', P.X, P.Y, AtFormName + '.btnTwo', 6);
    CheckHit('minimized, the label', PLabel.X, PLabel.Y, AtFormName + '.pnlHost.lblInPanel', 8);
  finally
    ShowWindow(FForm.Handle, SW_SHOWNOACTIVATE);
  end;
end;


procedure TListTreeAtTests.Test_ListTreeAt_OutsideTheClientArea_Returns32001;
var
  Root: TJSONObject;
  Args: TArray<String>;
  i: Integer;
begin
  Args := [PointArgs(FForm.ClientWidth, 0), PointArgs(0, FForm.ClientHeight), PointArgs(-1, 5)];
  for i := 0 to High(Args) do
    begin
      Root := CallListTree(Args[i]);
      try
        Assert.AreEqual(ErrNotFound, GetErrorCode(Root), Args[i] + ' must answer -32001: ' + Root.ToJSON);
        Assert.IsTrue(ErrorMessageOf(Root).Contains(IntToStr(FForm.ClientWidth) + ' x ' + IntToStr(FForm.ClientHeight)), 'the message must give the client size: ' + Root.ToJSON);
      finally
        FreeAndNil(Root);
      end;
    end;
end;


procedure TListTreeAtTests.Test_ListTreeAt_BadArguments_ReturnInvalidRequest;
var
  Root: TJSONObject;
  Args: TArray<String>;
  i: Integer;
begin
  Args := ['{"form":"' + AtFormName + '","x":5}',
           '{"form":"' + AtFormName + '","y":5}',
           '{"form":"' + AtFormName + '","x":"5","y":5}',
           '{"form":"' + AtFormName + '","x":5,"y":2.5}',
           '{"x":5,"y":5}'];
  for i := 0 to High(Args) do
    begin
      Root := CallListTree(Args[i]);
      try
        Assert.AreEqual(ErrInvalidRequest, GetErrorCode(Root), Args[i] + ' must answer -32600: ' + Root.ToJSON);
      finally
        FreeAndNil(Root);
      end;
    end;
end;


initialization
  TDUnitX.RegisterTestFixture(TListTreeFilterTests);
  TDUnitX.RegisterTestFixture(TListTreeAtTests);

end.
