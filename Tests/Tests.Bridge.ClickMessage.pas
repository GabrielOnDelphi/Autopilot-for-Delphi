unit Tests.Bridge.ClickMessage;

{=============================================================================================================
   2026.11.15
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for click mode='message' on the classes that are not button-class controls (VCL).
   - The click is queued to the main thread and runs after the answer, the same click the default mode runs.
   - A TMenuItem and a TToolButton whose OnClick opens a modal form: the click answers at once, and a second command is answered while the modal form is open.
   - A TLabel with OnClick: the click runs once, after the answer.
   - count=2 on a label whose OnClick frees it: the second queued click finds no control and is skipped.
=============================================================================================================}

interface

uses
  System.JSON,
  Vcl.Forms,
  DUnitX.TestFramework;

type
  [TestFixture]
  TClickMessageTests = class
  private
    FPipeName   : String;
    FPipeCounter: Integer;
    FForm       : TForm;
    procedure runModalCase(const APath: String);
  public
    [SetupFixture]    procedure SetupFixture;
    [Setup]           procedure Setup;
    [TearDown]        procedure TearDown;
    [TearDownFixture] procedure TearDownFixture;

    [Test] procedure Test_ModeMessage_MenuItemOpensModal_SecondCommandAnswers;
    [Test] procedure Test_ModeMessage_ToolButtonOpensModal_SecondCommandAnswers;
    [Test] procedure Test_ModeMessage_LabelWithOnClick_RunsOnce;
    [Test] procedure Test_ModeMessage_Count2_OnClickFreesControl_SecondIsSkipped;
  end;


implementation

uses
  Winapi.Windows, Winapi.Messages,
  System.SysUtils, System.Classes, System.SyncObjs, System.UITypes,
  Vcl.Controls, Vcl.StdCtrls, Vcl.Menus, Vcl.ComCtrls,
  Autopilot.Bridge.Core, Autopilot.Bridge.Vcl,
  Bridge.TestClient, Bridge.Tests;


const
  FormName      = 'CmTestForm';
  ModalFormName = 'CmModalForm';
  WaitModalMs   = 3000;

type
  // The modal form that the menu item and the tool button open. OnShow tells the test it is open, and gives it the window handle to close it.
  TCmModalForm = class(TForm)
  public
    LblModal: TLabel;
    OnShown : TProc<HWND>;
    constructor Create(AOwner: TComponent); override;
    procedure FormShown(Sender: TObject);
  end;

  // A popup menu item, a tool button and two labels, each with its own OnClick.
  TCmForm = class(TForm)
  public
    Popup      : TPopupMenu;
    MnuModal   : TMenuItem;
    ToolBar    : TToolBar;
    TbtModal   : TToolButton;
    LblClick   : TLabel;
    LblSelfFree: TLabel;       // created by the test that clicks it: its OnClick frees it
    ModalOpens     : Integer;
    ModalResultSeen: Integer;
    ModalClosed    : Boolean;
    ModalShown     : TEvent;
    ModalHwnd      : HWND;
    LabelClicks    : Integer;
    SelfFreeClicks : Integer;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure OpenModal(Sender: TObject);
    procedure LblClicked(Sender: TObject);
    procedure LblSelfFreeClicked(Sender: TObject);
  end;


constructor TCmModalForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Name     := ModalFormName;
  Caption  := 'Autopilot test - modal form';
  Position := poDesigned;
  SetBounds(40, 40, 260, 120);
  LblModal := TLabel.Create(Self);
  LblModal.Name    := 'lblModal';
  LblModal.Caption := 'Modal open';
  LblModal.Parent  := Self;
  OnShow := FormShown;
end;


procedure TCmModalForm.FormShown(Sender: TObject);
begin
  if Assigned(OnShown)
  then OnShown(Handle);
end;


constructor TCmForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Name    := FormName;
  Caption := 'Click mode=message';
  ModalShown := TEvent.Create(NIL, TRUE, FALSE, '');

  Popup := TPopupMenu.Create(Self);
  Popup.Name := 'pmTest';
  MnuModal := TMenuItem.Create(Self);
  MnuModal.Name    := 'mnuModal';
  MnuModal.Caption := 'Open modal';
  MnuModal.OnClick := OpenModal;
  Popup.Items.Add(MnuModal);

  ToolBar := TToolBar.Create(Self);
  ToolBar.Name   := 'tbTest';
  ToolBar.Parent := Self;
  TbtModal := TToolButton.Create(Self);
  TbtModal.Name    := 'tbtModal';
  TbtModal.Caption := 'Modal';
  TbtModal.Parent  := ToolBar;
  TbtModal.OnClick := OpenModal;

  LblClick := TLabel.Create(Self);
  LblClick.Name    := 'lblClick';
  LblClick.Caption := 'click me';
  LblClick.Parent  := Self;
  LblClick.OnClick := LblClicked;
end;


destructor TCmForm.Destroy;
begin
  FreeAndNil(ModalShown);
  inherited;
end;


procedure TCmForm.OpenModal(Sender: TObject);
var
  Modal: TCmModalForm;
begin
  Inc(ModalOpens);
  Modal := TCmModalForm.Create(NIL);
  try
    Modal.OnShown :=
      procedure(AHandle: HWND)
      begin
        ModalHwnd := AHandle;   // written before the event is set, so the worker reads it after its WaitFor
        ModalShown.SetEvent;
      end;
    ModalResultSeen := Modal.ShowModal;
  finally
    FreeAndNil(Modal);
  end;
  ModalHwnd   := 0;
  ModalClosed := TRUE;
end;


procedure TCmForm.LblClicked(Sender: TObject);
begin
  Inc(LabelClicks);
end;


procedure TCmForm.LblSelfFreeClicked(Sender: TObject);
begin
  Inc(SelfFreeClicks);
  FreeAndNil(LblSelfFree);   // Sender frees itself inside its own OnClick
end;


{ Helpers --------------------------------------------------------------- }

function StrOf(AObj: TJSONObject; const AName: String): String;
var
  V: TJSONValue;
begin
  Result := '';
  if AObj = NIL then EXIT;
  V := AObj.GetValue(AName);
  if V is TJSONString
  then Result := TJSONString(V).Value;
end;


function IntOf(AObj: TJSONObject; const AName: String): Integer;
var
  V: TJSONValue;
begin
  Result := -1;
  if AObj = NIL then EXIT;
  V := AObj.GetValue(AName);
  if V is TJSONNumber
  then Result := TJSONNumber(V).AsInt;
end;


{ Runs the queued procedures and the messages of this (main) thread for AMs milliseconds, or until ADone answers TRUE. }
procedure PumpFor(AMs: Cardinal; const ADone: TFunc<Boolean>);
var
  Deadline: UInt64;
  Msg: TMsg;
begin
  Deadline := GetTickCount64 + AMs;
  repeat
    CheckSynchronize(10);
    while PeekMessage(Msg, 0, 0, 0, PM_REMOVE) do
      begin
        TranslateMessage(Msg);
        DispatchMessage(Msg);
      end;
  until (Assigned(ADone) and ADone()) or (GetTickCount64 >= Deadline);
end;


{ TClickMessageTests ------------------------------------------------------ }

procedure TClickMessageTests.SetupFixture;
begin
  FPipeCounter := 0;
  FForm := TCmForm.Create(NIL);
end;


procedure TClickMessageTests.Setup;
var
  F: TCmForm;
begin
  Inc(FPipeCounter);
  FPipeName := '\\.\pipe\AutopilotTestClickMessage.' + IntToStr(GetCurrentProcessId) + '.' + IntToStr(FPipeCounter);
  F := TCmForm(FForm);
  F.ModalOpens      := 0;
  F.ModalResultSeen := 0;
  F.ModalClosed     := FALSE;
  F.ModalHwnd       := 0;
  F.ModalShown.ResetEvent;
  F.LabelClicks     := 0;
  F.SelfFreeClicks  := 0;
  StartBridgeOnPipe(FPipeName);
end;


procedure TClickMessageTests.TearDown;
begin
  PumpFor(50, NIL);   // a click still queued must not run in the next test
  StopBridge;
end;


procedure TClickMessageTests.TearDownFixture;
begin
  FreeAndNil(FForm);
end;


{ The click on APath opens the modal form from the queued click.
  The worker waits until the modal form is shown (OnShow), then sends get_text to a label on the modal form: the bridge must answer it while the modal form is open.
  The worker closes the modal form with WM_CLOSE in its finally, so the test cannot hang inside ShowModal. }
procedure TClickMessageTests.runModalCase(const APath: String);
var
  F: TCmForm;
  PipeName, Path, ClickVia, ClickErr, ModalText, ModalErr: String;
  ClickOk, Shown: Boolean;
begin
  F := TCmForm(FForm);
  PipeName := FPipeName;
  Path     := APath;
  ClickOk  := FALSE;
  Shown    := FALSE;
  ClickVia := '';
  ClickErr := '';
  ModalText := '';
  ModalErr  := '';
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    begin
      Client := TBridgeTestClient.Create;
      try
        if not Client.ConnectAndHandshake(PipeName, 2000) then EXIT;
        Args := TJSONObject.Create;
        Args.AddPair('path', Path);
        Args.AddPair('mode', 'message');
        Resp := Client.Call(1, 'click', Args, 2000);
        try
          ClickOk  := GetOkResult(Resp) <> NIL;
          ClickVia := StrOf(GetOkResult(Resp), 'dispatchedVia');
          if not ClickOk
          then ClickErr := Resp.ToJSON;
        finally
          FreeAndNil(Resp);
        end;
        if not ClickOk then EXIT;
        Shown := F.ModalShown.WaitFor(WaitModalMs) = wrSignaled;
        if not Shown then EXIT;
        // The second command, while the modal form opened by the queued click is still open.
        Args := TJSONObject.Create;
        Args.AddPair('path', ModalFormName + '.lblModal');
        Resp := Client.Call(2, 'get_text', Args, 2000);
        try
          ModalText := StrOf(GetOkResult(Resp), 'text');
          if GetOkResult(Resp) = NIL
          then ModalErr := Resp.ToJSON;
        finally
          FreeAndNil(Resp);
        end;
      finally
        // A modal form that opened late would keep the main thread inside ShowModal for ever: wait for it once more, then close it.
        if ClickOk and not Shown
        then F.ModalShown.WaitFor(WaitModalMs);
        if F.ModalHwnd <> 0
        then PostMessage(F.ModalHwnd, WM_CLOSE, 0, 0);
        FreeAndNil(Client);
      end;
    end, WaitModalMs + 6000);
  PumpFor(2000, function: Boolean begin Result := F.ModalClosed or (F.ModalOpens = 0); end);

  Assert.IsTrue(ClickOk, 'click mode=message on ' + APath + ' must answer ok: ' + ClickErr);
  Assert.AreEqual('message', ClickVia, 'dispatchedVia');
  Assert.IsTrue(Shown, 'the queued click must open the modal form');
  Assert.AreEqual('Modal open', ModalText, 'get_text sent while the modal form is open must be answered: ' + ModalErr);
  Assert.AreEqual(1, F.ModalOpens, 'the click must run exactly once');
  Assert.IsTrue(F.ModalClosed, 'the modal form must be closed by WM_CLOSE');
  Assert.AreEqual(Integer(mrCancel), F.ModalResultSeen, 'WM_CLOSE gives mrCancel');
end;


procedure TClickMessageTests.Test_ModeMessage_MenuItemOpensModal_SecondCommandAnswers;
begin
  runModalCase(FormName + '.mnuModal');
end;


procedure TClickMessageTests.Test_ModeMessage_ToolButtonOpensModal_SecondCommandAnswers;
begin
  runModalCase(FormName + '.tbtModal');
end;


procedure TClickMessageTests.Test_ModeMessage_LabelWithOnClick_RunsOnce;
var
  F: TCmForm;
  PipeName, Via, Raw: String;
  Dispatched: Integer;
begin
  F := TCmForm(FForm);
  PipeName := FPipeName;
  Via := '';
  Raw := '';
  Dispatched := -1;
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', FormName + '.lblClick');
        Args.AddPair('mode', 'message');
        Resp := Client.Call(3, 'click', Args);
        try
          Raw        := Resp.ToJSON;
          Via        := StrOf(GetOkResult(Resp), 'dispatchedVia');
          Dispatched := IntOf(GetOkResult(Resp), 'clicksDispatched');
        finally
          FreeAndNil(Resp);
        end;
      finally
        FreeAndNil(Client);
      end;
    end, 5000);
  PumpFor(300, NIL);
  Assert.AreEqual('message', Via, 'dispatchedVia. Answer: ' + Raw);
  Assert.AreEqual(1, Dispatched, 'clicksDispatched');
  Assert.AreEqual(1, F.LabelClicks, 'the queued click must run OnClick exactly once');
end;


procedure TClickMessageTests.Test_ModeMessage_Count2_OnClickFreesControl_SecondIsSkipped;
var
  F: TCmForm;
  PipeName, Raw: String;
  Dispatched: Integer;
begin
  F := TCmForm(FForm);
  PipeName := FPipeName;
  Raw := '';
  Dispatched := -1;
  F.LblSelfFree := TLabel.Create(F);
  try
    F.LblSelfFree.Name    := 'lblSelfFree';
    F.LblSelfFree.Caption := 'frees itself';
    F.LblSelfFree.Parent  := F;
    F.LblSelfFree.OnClick := F.LblSelfFreeClicked;
    RunOnWorkerAndPump(
      procedure
      var
        Client: TBridgeTestClient;
        Args, Resp: TJSONObject;
      begin
        Client := TBridgeTestClient.Create;
        try
          Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
          Args := TJSONObject.Create;
          Args.AddPair('path', FormName + '.lblSelfFree');
          Args.AddPair('mode', 'message');
          Args.AddPair('count', TJSONNumber.Create(2));
          Resp := Client.Call(4, 'click', Args);
          try
            Raw        := Resp.ToJSON;
            Dispatched := IntOf(GetOkResult(Resp), 'clicksDispatched');
          finally
            FreeAndNil(Resp);
          end;
        finally
          FreeAndNil(Client);
        end;
      end, 5000);
    PumpFor(300, NIL);
    Assert.AreEqual(2, Dispatched, 'both clicks are queued, so clicksDispatched=2. Answer: ' + Raw);
    Assert.AreEqual(1, F.SelfFreeClicks, 'the first queued click frees the label; the second must find no control and be skipped');
    Assert.IsNull(F.LblSelfFree, 'the OnClick should have freed the label');
  finally
    FreeAndNil(F.LblSelfFree);   // still there only when the click never ran
  end;
end;


initialization
  TDUnitX.RegisterTestFixture(TClickMessageTests);

end.
