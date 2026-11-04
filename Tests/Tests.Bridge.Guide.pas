unit Tests.Bridge.Guide;

{=============================================================================================================
   2026.11.04
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for the field 'guide' of list_tree: a form with a published string property AutopilotGuide
     gets that text on its own node, and on no other node.
   - A form without the property, with an empty guide, or with an AutopilotGuide that is not a string, gets no field.
   - A getter that raises gives that form node a field 'guideError' instead; the rest of the tree still arrives.
   - Win32 only (TRaiseCounter reads the Delphi exception record), like Tests.Bridge.PropertyTypes.
=============================================================================================================}

interface

uses
  System.JSON,
  Vcl.Forms,
  DUnitX.TestFramework;

type
  [TestFixture]
  TGuideTests = class
  private
    FPipeName   : String;
    FPipeCounter: Integer;
    FGuided     : TForm;
    FUnguided   : TForm;
    FIntGuide   : TForm;
    FEmptyGuide : TForm;
    function ListTreeComponents(OUT ARoot: TJSONObject; OUT ACastCount: Integer): TJSONArray;
  public
    [SetupFixture]    procedure SetupFixture;
    [Setup]           procedure Setup;
    [TearDown]        procedure TearDown;
    [TearDownFixture] procedure TearDownFixture;

    [Test] procedure Test_ListTree_GuidedFormNodeHasGuideText;
    [Test] procedure Test_ListTree_FormWithoutGuidePropertyHasNoGuide;
    [Test] procedure Test_ListTree_IntegerGuideHasNoGuideAndRaisesNothing;
    [Test] procedure Test_ListTree_EmptyGuideHasNoGuide;
    [Test] procedure Test_ListTree_ChildOfGuidedFormHasNoGuide;
    [Test] procedure Test_ListTree_RaisingGuideGivesGuideErrorAndKeepsTree;
  end;


implementation

uses
  Winapi.Windows,   // GetCurrentProcessId for the pipe name
  System.SysUtils, System.Classes, System.Generics.Collections,
  Vcl.StdCtrls,
  Autopilot.Bridge.Vcl,
  Bridge.TestClient, Bridge.Tests, Tests.RaiseCounter;


const
  GuideText = 'GuideForm is a test fixture. btnChild writes nothing.';
  RaisingGuideMsg = 'guide getter is broken';

type
  // A form with a guide and one child control.
  TGuidedForm = class(TForm)
  private
    function GetAutopilotGuide: String;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property AutopilotGuide: String read GetAutopilotGuide;
  end;

  // A plain form: no AutopilotGuide.
  TUnguidedForm = class(TForm)
  public
    constructor Create(AOwner: TComponent); override;
  end;

  // AutopilotGuide is an Integer: the bridge must not read it as a string.
  TIntGuideForm = class(TForm)
  private
    function GetAutopilotGuide: Integer;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property AutopilotGuide: Integer read GetAutopilotGuide;
  end;

  // AutopilotGuide is an empty string.
  TEmptyGuideForm = class(TForm)
  private
    function GetAutopilotGuide: String;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property AutopilotGuide: String read GetAutopilotGuide;
  end;

  // The AutopilotGuide getter raises: a bug in the app developer's own code.
  TRaisingGuideForm = class(TForm)
  private
    function GetAutopilotGuide: String;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property AutopilotGuide: String read GetAutopilotGuide;
  end;


{ TGuidedForm }

constructor TGuidedForm.Create(AOwner: TComponent);
var
  Btn: TButton;
begin
  inherited CreateNew(AOwner);
  Name    := 'GuideForm';
  Caption := 'Guided';
  Btn := TButton.Create(Self);
  Btn.Name    := 'btnChild';
  Btn.Caption := 'Child';
  Btn.Parent  := Self;
end;


function TGuidedForm.GetAutopilotGuide: String;
begin
  Result := GuideText;
end;


{ TUnguidedForm }

constructor TUnguidedForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Name    := 'UnguidedForm';
  Caption := 'Unguided';
end;


{ TIntGuideForm }

constructor TIntGuideForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Name    := 'IntGuideForm';
  Caption := 'Integer guide';
end;


function TIntGuideForm.GetAutopilotGuide: Integer;
begin
  Result := 7;
end;


{ TEmptyGuideForm }

constructor TEmptyGuideForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Name    := 'EmptyGuideForm';
  Caption := 'Empty guide';
end;


function TEmptyGuideForm.GetAutopilotGuide: String;
begin
  Result := '';
end;


{ TRaisingGuideForm }

constructor TRaisingGuideForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Name    := 'RaisingGuideForm';
  Caption := 'Raising guide';
end;


function TRaisingGuideForm.GetAutopilotGuide: String;
begin
  raise EInvalidOperation.Create(RaisingGuideMsg);
end;


{ Helpers --------------------------------------------------------------- }

// The list_tree node whose 'path' is APath, or NIL.
function FindNode(AComponents: TJSONArray; const APath: String): TJSONObject;
var
  i: Integer;
  Node: TJSONObject;
  V: TJSONValue;
begin
  Result := NIL;
  for i := 0 to AComponents.Count - 1 do
  begin
    Node := AComponents.Items[i] as TJSONObject;
    V := Node.GetValue('path');
    if (V is TJSONString) and (TJSONString(V).Value = APath) then
      exit(Node);
  end;
end;


{ TGuideTests ------------------------------------------------------------- }

procedure TGuideTests.SetupFixture;
begin
  FPipeCounter := 0;
  FGuided     := TGuidedForm.Create(NIL);
  FUnguided   := TUnguidedForm.Create(NIL);
  FIntGuide   := TIntGuideForm.Create(NIL);
  FEmptyGuide := TEmptyGuideForm.Create(NIL);
end;


procedure TGuideTests.Setup;
begin
  Inc(FPipeCounter);
  FPipeName := '\\.\pipe\AutopilotTestGuide.' + IntToStr(GetCurrentProcessId) + '.' + IntToStr(FPipeCounter);
  StartBridgeOnPipe(FPipeName);
end;


procedure TGuideTests.TearDown;
begin
  StopBridge;
end;


procedure TGuideTests.TearDownFixture;
begin
  FreeAndNil(FEmptyGuide);
  FreeAndNil(FIntGuide);
  FreeAndNil(FUnguided);
  FreeAndNil(FGuided);
end;


{ Runs list_tree and counts the EInvalidCast raises of the whole process meanwhile.
  ARoot is the whole answer (the caller frees it); the result is its 'components' array, owned by ARoot. }
function TGuideTests.ListTreeComponents(OUT ARoot: TJSONObject; OUT ACastCount: Integer): TJSONArray;
var
  Root, R: TJSONObject;
  PipeName: String;
begin
  PipeName := FPipeName;
  Root := NIL;
  TRaiseCounter.Install(EInvalidCast);
  try
    RunOnWorkerAndPump(
      procedure
      var Client: TBridgeTestClient;
      begin
        Client := TBridgeTestClient.Create;
        try
          if not Client.ConnectAndHandshake(PipeName, 2000) then
            Assert.Fail('connect to ' + PipeName + ' failed');
          Root := Client.Call(1, 'list_tree', NIL);
        finally
          FreeAndNil(Client);
        end;
      end, 5000);
    ACastCount := TRaiseCounter.Count;
  finally
    TRaiseCounter.Uninstall;
  end;

  ARoot := Root;
  R := GetOkResult(Root);
  Assert.IsNotNull(R, 'list_tree must succeed');
  Result := R.GetValue('components') as TJSONArray;
  Assert.IsNotNull(Result, 'list_tree must return components');
end;


procedure TGuideTests.Test_ListTree_GuidedFormNodeHasGuideText;
var
  Root, Node: TJSONObject;
  Components: TJSONArray;
  Casts: Integer;
  V: TJSONValue;
begin
  Root := NIL;
  try
    Components := ListTreeComponents(Root, Casts);
    Node := FindNode(Components, 'GuideForm');
    Assert.IsNotNull(Node, 'GuideForm must be listed');
    V := Node.GetValue('guide');
    Assert.IsTrue(V is TJSONString, 'the node of a form with AutopilotGuide must carry a string field guide');
    Assert.AreEqual(GuideText, TJSONString(V).Value, 'guide must be exactly the text of AutopilotGuide');
  finally
    FreeAndNil(Root);
  end;
end;


procedure TGuideTests.Test_ListTree_FormWithoutGuidePropertyHasNoGuide;
var
  Root, Node: TJSONObject;
  Components: TJSONArray;
  Casts: Integer;
begin
  Root := NIL;
  try
    Components := ListTreeComponents(Root, Casts);
    Node := FindNode(Components, 'UnguidedForm');
    Assert.IsNotNull(Node, 'UnguidedForm must be listed');
    Assert.IsNull(Node.GetValue('guide'), 'a form without AutopilotGuide must get no guide field');
    Assert.AreEqual('Unguided', (Node.GetValue('text') as TJSONString).Value, 'the other fields of the form node must stay');
  finally
    FreeAndNil(Root);
  end;
end;


procedure TGuideTests.Test_ListTree_IntegerGuideHasNoGuideAndRaisesNothing;
var
  Root, Node: TJSONObject;
  Components: TJSONArray;
  Casts: Integer;
begin
  Root := NIL;
  try
    Components := ListTreeComponents(Root, Casts);
    Assert.AreEqual(0, Casts, 'list_tree must raise no EInvalidCast on an Integer AutopilotGuide');
    Node := FindNode(Components, 'IntGuideForm');
    Assert.IsNotNull(Node, 'IntGuideForm must be listed');
    Assert.IsNull(Node.GetValue('guide'), 'an Integer AutopilotGuide must give no guide field');
  finally
    FreeAndNil(Root);
  end;
end;


procedure TGuideTests.Test_ListTree_EmptyGuideHasNoGuide;
var
  Root, Node: TJSONObject;
  Components: TJSONArray;
  Casts: Integer;
begin
  Root := NIL;
  try
    Components := ListTreeComponents(Root, Casts);
    Node := FindNode(Components, 'EmptyGuideForm');
    Assert.IsNotNull(Node, 'EmptyGuideForm must be listed');
    Assert.IsNull(Node.GetValue('guide'), 'an empty AutopilotGuide must give no guide field');
  finally
    FreeAndNil(Root);
  end;
end;


procedure TGuideTests.Test_ListTree_ChildOfGuidedFormHasNoGuide;
var
  Root, Node: TJSONObject;
  Components: TJSONArray;
  Casts: Integer;
begin
  Root := NIL;
  try
    Components := ListTreeComponents(Root, Casts);
    Node := FindNode(Components, 'GuideForm.btnChild');
    Assert.IsNotNull(Node, 'btnChild must be listed');
    Assert.IsNull(Node.GetValue('guide'), 'the guide belongs to the form node only, never to a child');
    Assert.AreEqual('Child', (Node.GetValue('text') as TJSONString).Value, 'wrong text for btnChild');
  finally
    FreeAndNil(Root);
  end;
end;


{ The raising form lives only in this test: while it exists, the old bridge fails every list_tree. }
procedure TGuideTests.Test_ListTree_RaisingGuideGivesGuideErrorAndKeepsTree;
var
  Raising: TForm;
  Root, Node: TJSONObject;
  Components: TJSONArray;
  Casts: Integer;
  V: TJSONValue;
begin
  Root := NIL;
  Raising := TRaisingGuideForm.Create(NIL);
  try
    Components := ListTreeComponents(Root, Casts);

    Node := FindNode(Components, 'RaisingGuideForm');
    Assert.IsNotNull(Node, 'RaisingGuideForm must be listed');
    Assert.IsNull(Node.GetValue('guide'), 'a raising AutopilotGuide must give no guide field');
    V := Node.GetValue('guideError');
    Assert.IsTrue(V is TJSONString, 'a raising AutopilotGuide must give a string field guideError');
    Assert.AreEqual('EInvalidOperation: ' + RaisingGuideMsg, TJSONString(V).Value, 'guideError must be the exception class and message');

    Node := FindNode(Components, 'GuideForm');
    Assert.IsNotNull(Node, 'the other forms must still be listed');
    Assert.AreEqual(GuideText, (Node.GetValue('guide') as TJSONString).Value, 'the guide of another form must stay');
    Assert.IsNull(Node.GetValue('guideError'), 'a working guide must give no guideError');
  finally
    FreeAndNil(Root);
    FreeAndNil(Raising);
  end;
end;


initialization
  TDUnitX.RegisterTestFixture(TGuideTests);

end.
