unit Tests.Bridge.EventHandlers;

{=============================================================================================================
   2026.11.04
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for read_property on an event property (kind 'event'): the answer names the handler routine
     as '<ClassName>.<MethodName>' plus the 'unit' of the class that declares it.
   - Covers: a published handler, no handler, a handler declared in the base form class, a method that is not
     published, a handler with no instance (Data = NIL), an action's OnExecute (direct and through Action.OnExecute),
     set_property on an event (still rejected), and the events in availableProperties.
   - VCL bridge only. The FMX bridge shares DescribeEventHandler (Autopilot.Bridge.Core) and is checked by the
     E2E script (Tests\E2E tests\Test-AllTools.ps1 -Framework FMX).
=============================================================================================================}

interface

uses
  System.JSON,
  Vcl.Forms,
  DUnitX.TestFramework;

type
  [TestFixture]
  TEventHandlerTests = class
  private
    FPipeName   : String;
    FPipeCounter: Integer;
    FForm       : TForm;
    function ReadProp(const APath, APropName: String): TJSONObject;
  public
    [SetupFixture]    procedure SetupFixture;
    [Setup]           procedure Setup;
    [TearDown]        procedure TearDown;
    [TearDownFixture] procedure TearDownFixture;

    [Test] procedure Test_ReadProperty_PublishedHandlerGivesClassMethodAndUnit;
    [Test] procedure Test_ReadProperty_NoHandlerGivesEmptyValue;
    [Test] procedure Test_ReadProperty_InheritedHandlerNamesTheDeclaringClass;
    [Test] procedure Test_ReadProperty_UnpublishedMethodGivesMarkedText;
    [Test] procedure Test_ReadProperty_HandlerWithoutInstanceGivesMarkedText;
    [Test] procedure Test_ReadProperty_ActionOnExecute;
    [Test] procedure Test_ReadProperty_DottedActionOnExecute;
    [Test] procedure Test_SetProperty_OnEventIsRejectedAndHandlerStays;
    [Test] procedure Test_ReadProperty_AvailablePropertiesListsEvents;
  end;


implementation

uses
  Winapi.Windows,   // GetCurrentProcessId for the pipe name
  System.SysUtils, System.Classes, System.Actions, System.Generics.Collections,
  Vcl.StdCtrls, Vcl.ActnList,
  Autopilot.Bridge.Core, Autopilot.Bridge.Vcl,
  Bridge.TestClient, Bridge.Tests;


const
  ThisUnit = 'Tests.Bridge.EventHandlers';

type
  // The base class of the fixture form: declares BaseClick, which the derived form assigns to btnInherited.
  TEventBaseForm = class(TForm)
  published
    procedure BaseClick(Sender: TObject);
  end;

  TEventForm = class(TEventBaseForm)
  private
    procedure HiddenClick(Sender: TObject);   // not published: MethodName cannot find it
  public
    BtnOwn      : TButton;   // OnClick = OwnClick
    BtnInherited: TButton;   // OnClick = BaseClick (declared in TEventBaseForm)
    BtnNone     : TButton;   // no OnClick
    BtnHidden   : TButton;   // OnClick = HiddenClick
    BtnNoData   : TButton;   // OnClick with Code set and Data = NIL
    BtnAct      : TButton;   // Action = ActRun
    ActList     : TActionList;
    ActRun      : TAction;   // OnExecute = ActRunExecute
    constructor Create(AOwner: TComponent); override;
  published
    procedure OwnClick(Sender: TObject);
    procedure ActRunExecute(Sender: TObject);
  end;


// A plain routine (no class) whose address goes into a TMethod with Data = NIL.
procedure PlainRoutine;
begin
end;


{ TEventBaseForm }

procedure TEventBaseForm.BaseClick(Sender: TObject);
begin
end;


{ TEventForm }

constructor TEventForm.Create(AOwner: TComponent);
var
  M : TMethod;
  Ev: TNotifyEvent;

  function MakeButton(const AName: String): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Name   := AName;
    Result.Parent := Self;
  end;

begin
  inherited CreateNew(AOwner);
  Name    := 'EventForm';
  Caption := 'Event handlers';

  BtnOwn := MakeButton('btnOwn');
  BtnOwn.OnClick := OwnClick;

  BtnInherited := MakeButton('btnInherited');
  BtnInherited.OnClick := BaseClick;

  BtnNone := MakeButton('btnNone');

  BtnHidden := MakeButton('btnHidden');
  BtnHidden.OnClick := HiddenClick;

  BtnNoData := MakeButton('btnNoData');
  M.Code := @PlainRoutine;
  M.Data := NIL;
  TMethod(Ev) := M;
  BtnNoData.OnClick := Ev;

  ActList := TActionList.Create(Self);
  ActList.Name := 'actList';
  ActRun := TAction.Create(Self);
  ActRun.Name       := 'actRun';
  ActRun.Caption    := 'Run';
  ActRun.ActionList := ActList;
  ActRun.OnExecute  := ActRunExecute;

  BtnAct := MakeButton('btnAct');
  BtnAct.Action := ActRun;
end;


procedure TEventForm.OwnClick(Sender: TObject);
begin
end;


procedure TEventForm.HiddenClick(Sender: TObject);
begin
end;


procedure TEventForm.ActRunExecute(Sender: TObject);
begin
end;


{ Helpers --------------------------------------------------------------- }

function PropArgs(const APath, APropName: String): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('path', APath);
  Result.AddPair('propName', APropName);
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


// The string field AName of AObj; '<absent>' when it is missing or not a string.
function Field(AObj: TJSONObject; const AName: String): String;
var
  V: TJSONValue;
begin
  V := AObj.GetValue(AName);
  if V is TJSONString
  then Result := TJSONString(V).Value
  else Result := '<absent>';
end;


{ TEventHandlerTests ------------------------------------------------------ }

procedure TEventHandlerTests.SetupFixture;
begin
  FPipeCounter := 0;
  FForm := TEventForm.Create(NIL);
end;


procedure TEventHandlerTests.Setup;
begin
  Inc(FPipeCounter);
  FPipeName := '\\.\pipe\AutopilotTestEvents.' + IntToStr(GetCurrentProcessId) + '.' + IntToStr(FPipeCounter);
  StartBridgeOnPipe(FPipeName);
end;


procedure TEventHandlerTests.TearDown;
begin
  StopBridge;
end;


procedure TEventHandlerTests.TearDownFixture;
begin
  FreeAndNil(FForm);
end;


function TEventHandlerTests.ReadProp(const APath, APropName: String): TJSONObject;
begin
  Result := CallBridge(FPipeName, 'read_property', PropArgs(APath, APropName));
end;


procedure TEventHandlerTests.Test_ReadProperty_PublishedHandlerGivesClassMethodAndUnit;
var
  Root, R: TJSONObject;
begin
  Root := ReadProp('EventForm.btnOwn', 'OnClick');
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'read_property OnClick must succeed: ' + ErrorMessageOf(Root));
    Assert.AreEqual('TEventForm.OwnClick', Field(R, 'value'), 'value must be <ClassName>.<MethodName>');
    Assert.AreEqual('event', Field(R, 'kind'), 'kind must be event');
    Assert.AreEqual(ThisUnit, Field(R, 'unit'), 'unit must be the unit that declares TEventForm');
  finally
    FreeAndNil(Root);
  end;
end;


procedure TEventHandlerTests.Test_ReadProperty_NoHandlerGivesEmptyValue;
var
  Root, R: TJSONObject;
begin
  Root := ReadProp('EventForm.btnNone', 'OnClick');
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'read_property OnClick with no handler must succeed: ' + ErrorMessageOf(Root));
    Assert.AreEqual('', Field(R, 'value'), 'no handler must give an empty value');
    Assert.AreEqual('event', Field(R, 'kind'), 'kind must be event');
    Assert.IsNull(R.GetValue('unit'), 'no handler must give no unit field');
  finally
    FreeAndNil(Root);
  end;
end;


procedure TEventHandlerTests.Test_ReadProperty_InheritedHandlerNamesTheDeclaringClass;
var
  Root, R: TJSONObject;
begin
  Root := ReadProp('EventForm.btnInherited', 'OnClick');
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'read_property OnClick must succeed: ' + ErrorMessageOf(Root));
    Assert.AreEqual('TEventBaseForm.BaseClick', Field(R, 'value'), 'a handler declared in the base form must name the base class, not TEventForm');
    Assert.AreEqual(ThisUnit, Field(R, 'unit'), 'unit must be the unit of the declaring class');
  finally
    FreeAndNil(Root);
  end;
end;


procedure TEventHandlerTests.Test_ReadProperty_UnpublishedMethodGivesMarkedText;
var
  Root, R: TJSONObject;
begin
  Root := ReadProp('EventForm.btnHidden', 'OnClick');
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'read_property of an unpublished handler must succeed, never raise: ' + ErrorMessageOf(Root));
    Assert.AreEqual('(unpublished method of TEventForm)', Field(R, 'value'), 'an unpublished handler must give the marked text with the class of Data');
    Assert.AreEqual('event', Field(R, 'kind'), 'kind must be event');
    Assert.AreEqual(ThisUnit, Field(R, 'unit'), 'unit must be the unit of the class of Data');
  finally
    FreeAndNil(Root);
  end;
end;


procedure TEventHandlerTests.Test_ReadProperty_HandlerWithoutInstanceGivesMarkedText;
var
  Root, R: TJSONObject;
begin
  Root := ReadProp('EventForm.btnNoData', 'OnClick');
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'read_property of a handler with Data = NIL must succeed, never raise: ' + ErrorMessageOf(Root));
    Assert.AreEqual('(routine without an instance)', Field(R, 'value'), 'Data = NIL must give the marked text');
    Assert.AreEqual('event', Field(R, 'kind'), 'kind must be event');
    Assert.IsNull(R.GetValue('unit'), 'Data = NIL must give no unit field');
  finally
    FreeAndNil(Root);
  end;
end;


procedure TEventHandlerTests.Test_ReadProperty_ActionOnExecute;
var
  Root, R: TJSONObject;
begin
  Root := ReadProp('EventForm.actRun', 'OnExecute');
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'read_property OnExecute of an action must succeed: ' + ErrorMessageOf(Root));
    Assert.AreEqual('TEventForm.ActRunExecute', Field(R, 'value'), 'an action''s OnExecute must name its handler');
    Assert.AreEqual('event', Field(R, 'kind'), 'kind must be event');
    Assert.AreEqual(ThisUnit, Field(R, 'unit'), 'unit must be the unit of TEventForm');
  finally
    FreeAndNil(Root);
  end;
end;


procedure TEventHandlerTests.Test_ReadProperty_DottedActionOnExecute;
var
  Root, R: TJSONObject;
begin
  Root := ReadProp('EventForm.btnAct', 'Action.OnExecute');
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'read_property Action.OnExecute must succeed: ' + ErrorMessageOf(Root));
    Assert.AreEqual('TEventForm.ActRunExecute', Field(R, 'value'), 'Action.OnExecute must name the handler of the bound action');
    Assert.AreEqual('event', Field(R, 'kind'), 'kind must be event');
  finally
    FreeAndNil(Root);
  end;
end;


procedure TEventHandlerTests.Test_SetProperty_OnEventIsRejectedAndHandlerStays;
var
  Root: TJSONObject;
  Args: TJSONObject;
  Ev    : TNotifyEvent;
  Before: TMethod;
  After : TMethod;
begin
  Ev := TEventForm(FForm).BtnOwn.OnClick;
  Before := TMethod(Ev);
  Args := PropArgs('EventForm.btnOwn', 'OnClick');
  Args.AddPair('value', 'TEventForm.ActRunExecute');
  Root := CallBridge(FPipeName, 'set_property', Args);
  try
    Assert.IsNull(GetOkResult(Root), 'set_property on an event must fail');
    Assert.AreEqual(ErrUnsupportedAction, GetErrorCode(Root), 'set_property on an event must answer unsupported_action: ' + ErrorMessageOf(Root));
  finally
    FreeAndNil(Root);
  end;
  Ev := TEventForm(FForm).BtnOwn.OnClick;
  After := TMethod(Ev);
  Assert.IsTrue((After.Code = Before.Code) and (After.Data = Before.Data), 'the handler must stay unchanged');
  Assert.IsTrue(After.Code = TEventForm.MethodAddress('OwnClick'), 'the handler must still be OwnClick');
end;


procedure TEventHandlerTests.Test_ReadProperty_AvailablePropertiesListsEvents;
var
  Root, Data, Node, OnClickNode, OnEnterNode: TJSONObject;
  Avail: TJSONArray;
  i: Integer;
begin
  Root := ReadProp('EventForm.btnOwn', 'NoSuchProp');
  try
    Assert.AreEqual(ErrRttiPropertyMissing, GetErrorCode(Root), 'an unknown propName must answer rtti_property_missing');
    Data := GetErrorData(Root);
    Assert.IsNotNull(Data, 'the error must carry data');
    Avail := Data.GetValue('availableProperties') as TJSONArray;
    Assert.IsNotNull(Avail, 'the error data must carry availableProperties');
    OnClickNode := NIL;
    OnEnterNode := NIL;
    for i := 0 to Avail.Count - 1 do
    begin
      Node := Avail.Items[i] as TJSONObject;
      if Field(Node, 'name') = 'OnClick' then OnClickNode := Node;
      if Field(Node, 'name') = 'OnEnter' then OnEnterNode := Node;
    end;
    Assert.IsNotNull(OnClickNode, 'availableProperties must list OnClick');
    Assert.AreEqual('event', Field(OnClickNode, 'kind'), 'OnClick must be listed with kind event');
    Assert.AreEqual('TEventForm.OwnClick', Field(OnClickNode, 'currentValue'), 'an assigned event must carry its handler as currentValue');
    Assert.IsNotNull(OnEnterNode, 'availableProperties must list OnEnter (no handler)');
    Assert.AreEqual('event', Field(OnEnterNode, 'kind'), 'OnEnter must be listed with kind event');
    Assert.IsNull(OnEnterNode.GetValue('currentValue'), 'an event with no handler must carry no currentValue');
  finally
    FreeAndNil(Root);
  end;
end;


initialization
  TDUnitX.RegisterTestFixture(TEventHandlerTests);

end.
