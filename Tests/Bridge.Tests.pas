unit Bridge.Tests;

{=============================================================================================================
   2026.06
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for the Autopilot VCL bridge: handshake, list_tree, click, get_text, set_text, set_checked, set_property, and dismiss_dialog.
   - Each test builds a synthetic TFixtureForm programmatically, starts the bridge on a per-test pipe name, connects via TBridgeTestClient, asserts the response, then tears down.
   - The bridge's main-thread dispatcher runs via TThread.Queue; RunOnWorkerAndPump keeps the main thread pumping messages while the worker drives the pipe.
=============================================================================================================}

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TBridgeTests = class
  private
    FPipeName: String;
    procedure EnsureFreshPipeName;
  public
    [Setup]    procedure Setup;
    [TearDown] procedure TearDown;
    /// Runs once after the whole fixture. Frees the shared fixture form created
    /// lazily in Setup, so it doesn't leak at process exit.
    [TearDownFixture] procedure TearDownFixture;

    [Test] procedure Test_HandshakeSucceeds;
    [Test] procedure Test_ListTree_FindsKnownControls;
    [Test] procedure Test_GetText_OfLabel;
    [Test] procedure Test_Click_FiresOnClick;
    [Test] procedure Test_Click_DisabledControlReturnsError;
    [Test] procedure Test_Click_CountFiresNTimes;
    [Test] procedure Test_Click_CountZeroReturnsError;
    [Test] procedure Test_Click_CountAboveCapReturnsError;
    [Test] procedure Test_DismissDialog_FractionalHwndReturnsInvalidRequest;
    [Test] procedure Test_Click_CountStopsWhenDisabledMidLoop;
    [Test] procedure Test_Click_CountFiresOnClickPathNTimes;
    [Test] procedure Test_Click_MainThreadBlockedReturnsTimeoutError;
    [Test] procedure Test_GetText_NotFoundReturnsError;
    [Test] procedure Test_UnknownCmdReturnsError;
    [Test] procedure Test_SetText_UpdatesEditValue;
    [Test] procedure Test_SetText_DisabledControlReturnsError;
    [Test] procedure Test_SetChecked_UpdatesCheckbox;
    [Test] procedure Test_SetChecked_DisabledControlReturnsError;
    [Test] procedure Test_ListTree_SyntheticIdForUnnamedComponent;
    [Test] procedure Test_Click_BySyntheticIdFiresOnClick;
    [Test] procedure Test_ListTree_RecursesIntoFrames;
    [Test] procedure Test_Click_FrameChildByFlatPathFiresOnClick;
    [Test] procedure Test_Click_FrameChildByAnchoredPathFiresOnClick;
    [Test] procedure Test_Click_DesignTimeStyleFrameChildFiresOnClick;
    [Test] procedure Test_FindByPath_FormItselfByOneSegmentPath;
    [Test] procedure Test_SetProperty_WritesString;
    [Test] procedure Test_SetProperty_WritesInteger;
    [Test] procedure Test_SetProperty_WritesBoolean;
    [Test] procedure Test_SetProperty_WritesEnumByIdentifier;
    [Test] procedure Test_SetProperty_WritesFloat;
    [Test] procedure Test_SetProperty_UnknownPropertyReturnsListOfWritables;
    [Test] procedure Test_SetProperty_TypeMismatchReturnsUnsupportedAction;
    [Test] procedure Test_SetProperty_DisabledControlReturnsError;
    [Test] procedure Test_SetProperty_WritesSetByBracketLiteral;
    [Test] procedure Test_SetProperty_WritesSetByBareIdentifierList;
    [Test] procedure Test_SetProperty_WritesEmptySet;
    [Test] procedure Test_SetProperty_InvalidSetIdentifierReturnsUnsupportedAction;
    [Test] procedure Test_SetProperty_AvailablePropertiesIncludeCurrentValue;
    [Test] procedure Test_SetProperty_WritesNestedClassMemberLinesText;
    [Test] procedure Test_SetProperty_WritesNestedClassMemberFontSize;
    [Test] procedure Test_SetProperty_DottedFontWriteFlipsParentFontFalse;
    [Test] procedure Test_SetProperty_DottedUnknownInnerListsInnerWritables;
    [Test] procedure Test_SetProperty_DottedOnNonClassOuterReturnsUnsupportedAction;
    [Test] procedure Test_SetProperty_DottedTwoLevelsReturnsUnsupportedAction;
    [Test] procedure Test_SetProperty_DottedOnDisabledControlReturnsControlDisabled;
    [Test] procedure Test_SetProperty_AlphaColorByHexWithAlpha;
    [Test] procedure Test_SetProperty_AlphaColorByHexShortFormAssumesFullAlpha;
    [Test] procedure Test_SetProperty_AlphaColorByClaIdentifier;
    [Test] procedure Test_SetProperty_AlphaColorInvalidValueReturnsUnsupportedAction;
    [Test] procedure Test_SetProperty_AlphaColorCurrentValueRendersAsHash;
    [Test] procedure Test_SetProperty_AlphaColorAvailablePropertiesKindIsAlphacolor;
    [Test] procedure Test_SetProperty_ColorByClIdentifier;
    [Test] procedure Test_SetProperty_ColorByWebHex;
    [Test] procedure Test_SetProperty_ColorInvalidValueReturnsUnsupportedAction;
    [Test] procedure Test_SetProperty_ColorCurrentValueRendersAsName;
    [Test] procedure Test_SetProperty_ColorAvailablePropertiesKindIsColor;
    // Write-side elision: skip Prop.SetValue when the new value equals the
    // live value, so OnChange doesn't fire spuriously. Response carries
    // 'elided: true|false' to let the AI know whether the setter ran.
    [Test] procedure Test_SetProperty_ElisionStringEqualReturnsElidedAndSkipsOnChange;
    [Test] procedure Test_SetProperty_ElisionStringDifferentFiresOnChangeAndReportsElidedFalse;
    [Test] procedure Test_SetProperty_ElisionIntegerEqualReturnsElided;
    [Test] procedure Test_SetProperty_ElisionBooleanEqualReturnsElided;
    [Test] procedure Test_SetProperty_ElisionFloatEqualReturnsElided;
    [Test] procedure Test_SetProperty_ElisionSetEqualReturnsElided;
    [Test] procedure Test_SetProperty_ElisionEnumEqualReturnsElided;
    [Test] procedure Test_SetProperty_ElisionAlphaColorEqualReturnsElided;
    [Test] procedure Test_SetProperty_ElisionColorEqualReturnsElided;
    [Test] procedure Test_SetProperty_ElisionDottedFontSizeEqualReturnsElided;
    [Test] procedure Test_SetProperty_SuccessResponseAlwaysCarriesElidedField;
  end;


implementation

uses
  Winapi.Windows,
  System.SysUtils, System.Classes, System.SyncObjs, System.JSON,
  System.Generics.Collections, System.UITypes, System.UIConsts,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Graphics,
  DUnitX.Exceptions,
  Autopilot.Bridge.Core, Autopilot.Bridge.Vcl,
  Bridge.TestClient;


type
  // Self-contained enum + set type for the set_property tkSet tests. Lives at unit
  // scope so RTTI emits the type info that StringToSet/SetToString need (sets nested
  // inside a class don't always get TypeInfo emitted).
  TFixtureColor = (fcRed, fcGreen, fcBlue, fcYellow);
  TFixtureColors = set of TFixtureColor;

  // A test fixture form with known controls. Built programmatically so DFM-less tests work.
  TFixtureForm = class(TForm)
  private
    // Backing fields for set_property tests. Published below as writable
    // properties so RTTI can find them; TForm itself has no convenient writable
    // Float / Set / TStrings.
    FFloatProp: Single;
    FMySetProp: TFixtureColors;
    FMyLines  : TStrings;            // TStringList behind a TStrings published surface.
    FMyAlpha  : TAlphaColor;
    FMyColor  : TColor;
    procedure SetMyLines(AValue: TStrings);
  published
    property FloatProp:  Single         read FFloatProp write FFloatProp;
    property MySetProp:  TFixtureColors read FMySetProp write FMySetProp;
    // For dotted-propName tests (MyLines.Text via set_property). TStrings is a
    // tkClass property — same RTTI shape as TMemo.Lines, but backed by a plain
    // TStringList so it works without a window handle.
    property MyLines:    TStrings       read FMyLines  write SetMyLines;
    // For TAlphaColor coercion tests. TAlphaColor lives in System.UITypes (RTL,
    // not FMX), so the test target is framework-agnostic — only the RTTI type
    // handle matters. Bridge's TryParseAlphaColor accepts '#RRGGBB' (full
    // alpha), '#AARRGGBB', 'claName', bare names, decimal, or '$hex'.
    property MyAlpha:    TAlphaColor    read FMyAlpha  write FMyAlpha;
    // For TColor coercion tests (VCL only). TColor is BGR-stored, but the bridge
    // accepts 'clName', '#RRGGBB' (web RGB), '$00BBGGRR', or decimal.
    property MyColor:    TColor         read FMyColor  write FMyColor;
  public
    Btn             : TButton;
    BtnDisabled     : TButton;
    BtnSelfDisables : TButton;
    BtnSlow         : TButton;
    BtnUnnamed      : TButton;       // Name = ''; addressable only via synthetic '@TButton#N' ID.
    BtnUnnamedClicks: Integer;
    Frame           : TFrame;        // Owned by form. Tests R4 recursion via runtime-owned children.
    BtnInFrame      : TButton;       // Owned BY Frame, parented to Frame. Runtime-style ownership.
    BtnInFrameClicks: Integer;
    // Design-time-style: button is owned by the FORM (as TReader.ReadDataInner rewires
    // it via Root) but visually Parent'd to the frame. This is what every IDE-placed
    // frame actually looks like at runtime. Important: the recursive list_tree walk
    // already enumerates this button as a sibling of the frame in Form.Components[],
    // so coverage of design-time frames was already correct before R4 — R4's gain is
    // for runtime-created frames (e.g. dynamic plug-in panels).
    BtnOnFrameDesignTime      : TButton;
    BtnOnFrameDesignTimeClicks: Integer;
    Lbl             : TLabel;
    LblClickable    : TLabel;
    Edt             : TEdit;
    EdtDisabled     : TEdit;
    Cbx             : TCheckBox;
    CbxDisabled     : TCheckBox;
    ClickCount      : Integer;
    SelfDisableCount: Integer;
    LabelClickCount : Integer;
    SlowClickCount  : Integer;
    EdtChangeCount  : Integer;       // Fires when Edt.Text is actually changed. Used by elision tests.
    SlowGate        : TEvent;        // BtnSlowClicked waits on this. Tests signal it.
    SlowSleepMs     : Cardinal;      // OnClick sleeps this long (Sleep variant).
    procedure BtnClicked(Sender: TObject);
    procedure BtnSelfDisableClicked(Sender: TObject);
    procedure BtnSlowClicked(Sender: TObject);
    procedure LblClicked(Sender: TObject);
    procedure BtnUnnamedClicked(Sender: TObject);
    procedure BtnInFrameClicked(Sender: TObject);
    procedure BtnOnFrameDesignTimeClicked(Sender: TObject);
    procedure EdtChanged(Sender: TObject);
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

constructor TFixtureForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Name             := 'FixtureForm';
  Caption          := 'Fixture';
  Width            := 320;
  Height           := 240;
  Position         := poDesigned;
  // Pin the form's inherited font size to 8 so a child control with
  // ParentFont=True reports Font.Size=8. The host default is Segoe UI 9 on
  // Windows 11 (measured), and Setup's 'Btn.Font.Size:=8' would otherwise be a
  // real 9->8 change that flips Btn.ParentFont to False via TControl.FontChanged,
  // breaking the ParentFont=True baseline of the dotted-Font.* tests.
  Font.Size        := 8;
  ClickCount       := 0;
  SelfDisableCount := 0;
  SlowGate         := TEvent.Create(nil, True, False, '');
  // Plain TStringList — works without a window handle, unlike TMemo.Lines.
  FMyLines         := TStringList.Create;
  FMyLines.Text    := 'initial line';

  Btn := TButton.Create(Self);
  Btn.Name    := 'btnTest';
  Btn.Caption := 'Test';
  Btn.Parent  := Self;
  Btn.OnClick := BtnClicked;

  BtnDisabled := TButton.Create(Self);
  BtnDisabled.Name    := 'btnDisabled';
  BtnDisabled.Caption := 'Disabled';
  BtnDisabled.Enabled := False;
  BtnDisabled.Parent  := Self;
  BtnDisabled.OnClick := BtnClicked;

  // Self-disabling button: fires SelfDisableCount, then disables itself on the third click.
  // Lets us verify the bridge re-checks Enabled between iterations and stops cleanly.
  BtnSelfDisables := TButton.Create(Self);
  BtnSelfDisables.Name    := 'btnSelfDisables';
  BtnSelfDisables.Caption := 'SelfDisable';
  BtnSelfDisables.Enabled := True;
  BtnSelfDisables.Parent  := Self;
  BtnSelfDisables.OnClick := BtnSelfDisableClicked;

  // Slow button: OnClick sleeps for SlowSleepMs. Lets us trigger the main_thread_blocked
  // path by sending a click with a short timeoutMs.
  BtnSlow := TButton.Create(Self);
  BtnSlow.Name    := 'btnSlow';
  BtnSlow.Caption := 'Slow';
  BtnSlow.Enabled := True;
  BtnSlow.Parent  := Self;
  BtnSlow.OnClick := BtnSlowClicked;

  Lbl := TLabel.Create(Self);
  Lbl.Name    := 'lblStatus';
  Lbl.Caption := 'Initial';
  Lbl.Parent  := Self;

  // Clickable TLabel — TLabel is TControl but not TWinControl, so the bridge dispatches
  // via the RTTI/OnClick fallback path. Lets us exercise that path with count > 1.
  LblClickable := TLabel.Create(Self);
  LblClickable.Name    := 'lblClickable';
  LblClickable.Caption := 'click me';
  LblClickable.Parent  := Self;
  LblClickable.OnClick := LblClicked;

  Edt := TEdit.Create(Self);
  Edt.Name   := 'edtName';
  Edt.Text   := 'HelloWorld';
  Edt.Parent := Self;
  // OnChange wired AFTER the initial Text assignment so the fixture's startup
  // priming doesn't count. Tests reset EdtChangeCount in Setup.
  Edt.OnChange := EdtChanged;

  EdtDisabled := TEdit.Create(Self);
  EdtDisabled.Name    := 'edtDisabled';
  EdtDisabled.Text    := 'frozen';
  EdtDisabled.Enabled := False;
  EdtDisabled.Parent  := Self;

  Cbx := TCheckBox.Create(Self);
  Cbx.Name    := 'cbxFlag';
  Cbx.Caption := 'Flag';
  Cbx.Checked := False;
  Cbx.Parent  := Self;

  CbxDisabled := TCheckBox.Create(Self);
  CbxDisabled.Name    := 'cbxDisabled';
  CbxDisabled.Caption := 'Disabled';
  CbxDisabled.Checked := False;
  CbxDisabled.Enabled := False;
  CbxDisabled.Parent  := Self;

  // Unnamed button: exercises the synthetic '@TButton#N' path. Owner is Self,
  // so its ComponentIndex is stable for the lifetime of this fixture form.
  BtnUnnamed := TButton.Create(Self);
  BtnUnnamed.Caption := 'Unnamed';
  BtnUnnamed.Parent  := Self;
  BtnUnnamed.OnClick := BtnUnnamedClicked;
  BtnUnnamedClicks   := 0;

  // Nested frame with its own button: exercises R4 (recursive walk into frames).
  // BtnInFrame's Owner is the frame, so Form.Components[] does NOT include it —
  // the bridge has to recurse into Frame.Components[] to find it. This models
  // a runtime-created frame (e.g. a dynamic plug-in panel).
  Frame := TFrame.Create(Self);
  Frame.Name   := 'frmInner';
  Frame.Parent := Self;
  BtnInFrame := TButton.Create(Frame);
  BtnInFrame.Name    := 'btnInFrame';
  BtnInFrame.Caption := 'Inside';
  BtnInFrame.Parent  := Frame;
  BtnInFrame.OnClick := BtnInFrameClicked;
  BtnInFrameClicks   := 0;

  // Design-time-style button: Owner=Form, Parent=Frame. Mirrors what TReader does
  // when loading a frame from a DFM — children get their Owner rewired to Root.
  // This button shows up directly in Form.Components[] (not in Frame.Components[]),
  // and was reachable by the OLD flat walk too — R4 doesn't change anything here.
  // The fixture proves both scenarios are covered.
  BtnOnFrameDesignTime := TButton.Create(Self);
  BtnOnFrameDesignTime.Name    := 'btnOnFrameDT';
  BtnOnFrameDesignTime.Caption := 'DesignTime';
  BtnOnFrameDesignTime.Parent  := Frame;
  BtnOnFrameDesignTime.OnClick := BtnOnFrameDesignTimeClicked;
  BtnOnFrameDesignTimeClicks   := 0;
end;

procedure TFixtureForm.BtnClicked(Sender: TObject);
begin
  Inc(ClickCount);
end;

procedure TFixtureForm.BtnSelfDisableClicked(Sender: TObject);
begin
  Inc(SelfDisableCount);
  if SelfDisableCount >= 3 then
    BtnSelfDisables.Enabled := False;
end;

procedure TFixtureForm.BtnSlowClicked(Sender: TObject);
begin
  Inc(SlowClickCount);
  if SlowSleepMs > 0 then
    // Wait on the gate with a Sleep-equivalent timeout. Test code can
    // unblock us early by signaling SlowGate. Avoids leaving the main
    // thread stuck in Sleep when the test has already moved on.
    SlowGate.WaitFor(SlowSleepMs);
end;


destructor TFixtureForm.Destroy;
begin
  FreeAndNil(SlowGate);
  FreeAndNil(FMyLines);
  inherited;
end;


procedure TFixtureForm.SetMyLines(AValue: TStrings);
begin
  // Standard TStrings setter pattern — Assign so the inner content is copied
  // into the existing TStringList, never overwriting the field with the
  // caller's instance.
  FMyLines.Assign(AValue);
end;

procedure TFixtureForm.LblClicked(Sender: TObject);
begin
  Inc(LabelClickCount);
end;


procedure TFixtureForm.BtnUnnamedClicked(Sender: TObject);
begin
  Inc(BtnUnnamedClicks);
end;


procedure TFixtureForm.BtnInFrameClicked(Sender: TObject);
begin
  Inc(BtnInFrameClicks);
end;


procedure TFixtureForm.BtnOnFrameDesignTimeClicked(Sender: TObject);
begin
  Inc(BtnOnFrameDesignTimeClicks);
end;


procedure TFixtureForm.EdtChanged(Sender: TObject);
begin
  // TEdit.OnChange fires on every real Text assignment. Elision tests assert
  // this counter stays 0 when set_property is called with the current value.
  Inc(EdtChangeCount);
end;


var
  GFixtureForm: TFixtureForm = nil;


{ Helpers --------------------------------------------------------------- }

// Run a closure on a worker thread, while pumping messages on the main thread until
// it finishes. Lets the worker do a synchronous pipe Call(), and lets TThread.Queue
// callbacks fired by the bridge actually run on this (main) thread.
procedure RunOnWorkerAndPump(AProc: TThreadProcedure; ATimeoutMs: Cardinal);
var
  Done    : TEvent;
  WorkerErrMsg: String;
  WorkerErrIsAssertion: Boolean;
  Deadline: UInt64;
  Msg     : TMsg;
begin
  Done := TEvent.Create(nil, True, False, '');
  try
    WorkerErrMsg := '';
    WorkerErrIsAssertion := False;
    TThread.CreateAnonymousThread(
      procedure
      begin
        try
          AProc();
        except
          on E: ETestFailure do
          begin
            WorkerErrMsg := E.Message;
            WorkerErrIsAssertion := True;
          end;
          on E: Exception do
            WorkerErrMsg := E.ClassName + ': ' + E.Message;
        end;
        Done.SetEvent;
      end).Start;

    Deadline := GetTickCount64 + ATimeoutMs;
    while Done.WaitFor(10) <> wrSignaled do
    begin
      // Drain queued messages so TThread.Queue closures fire on this thread.
      while PeekMessage(Msg, 0, 0, 0, PM_REMOVE) do
      begin
        TranslateMessage(Msg);
        DispatchMessage(Msg);
      end;
      // Also drain the TThread queue directly — works even without a window message.
      CheckSynchronize;
      if GetTickCount64 > Deadline then
        raise Exception.Create('RunOnWorkerAndPump: worker did not finish in time');
    end;

    // Re-emit a worker-side failure on this (parent) thread so DUnitX records it. On success we
    // return normally so the caller's post-pump assertions run on the main thread. Do NOT call
    // Assert.Pass here: it raises ETestPass, which aborts the test before any post-pump assertion
    // runs. FailsOnNoAsserts is False in Tests.dpr, so a worker-side-only test needs no main-thread
    // assertion to count as run.
    if WorkerErrIsAssertion then
      Assert.IsTrue(False, WorkerErrMsg)
    else if WorkerErrMsg <> '' then
      raise Exception.Create('Worker thread failed: ' + WorkerErrMsg);
  finally
    Done.Free;
  end;
end;


{ TBridgeTests ---------------------------------------------------------- }

var
  GPipeNameCounter: Integer = 0;   // monotonic, avoids GetTickCount collisions between fast tests.

procedure TBridgeTests.EnsureFreshPipeName;
begin
  // Per-test pipe name. Uses a monotonic counter (not GetTickCount, which has 15-16 ms
  // resolution and can collide between Setup calls that fire within the same tick).
  // PID is constant within the run; counter ensures uniqueness across all tests.
  Inc(GPipeNameCounter);
  FPipeName := '\\.\pipe\AutopilotTest.' + IntToStr(GetCurrentProcessId) +
               '.' + IntToStr(GPipeNameCounter);
end;


procedure TBridgeTests.Setup;
begin
  EnsureFreshPipeName;
  if GFixtureForm = nil then
    GFixtureForm := TFixtureForm.Create(nil);   // registers in Screen.Forms[]

  GFixtureForm.ClickCount        := 0;
  GFixtureForm.SelfDisableCount  := 0;
  GFixtureForm.LabelClickCount   := 0;
  GFixtureForm.SlowClickCount    := 0;
  GFixtureForm.BtnUnnamedClicks  := 0;
  GFixtureForm.BtnInFrameClicks  := 0;
  GFixtureForm.BtnOnFrameDesignTimeClicks := 0;
  GFixtureForm.SlowSleepMs       := 0;
  GFixtureForm.SlowGate.ResetEvent;
  GFixtureForm.BtnSelfDisables.Enabled := True;
  GFixtureForm.Lbl.Caption       := 'Initial';
  GFixtureForm.Edt.Text          := 'HelloWorld';
  GFixtureForm.EdtDisabled.Text  := 'frozen';
  GFixtureForm.Cbx.Checked       := False;
  GFixtureForm.CbxDisabled.Checked := False;
  GFixtureForm.FloatProp         := 0.0;
  GFixtureForm.MySetProp         := [];
  GFixtureForm.Tag               := 0;
  GFixtureForm.Btn.Tag           := 0;   // Btn.Tag (not just the form's Tag) — Test_SetProperty_WritesInteger sets it to 42; without this reset that 42 leaks into later tests on the shared fixture form
  GFixtureForm.MyLines.Text      := 'initial line';
  GFixtureForm.Btn.ParentFont    := True;
  GFixtureForm.Btn.Font.Size     := 8;
  GFixtureForm.MyAlpha           := TAlphaColor(0);
  GFixtureForm.MyColor           := TColor(0);
  // Reset the OnChange counter AFTER priming Edt.Text — the assignment above
  // may itself fire OnChange (TEdit.SetText short-circuits on equal value, but
  // we shouldn't depend on that). Reset here so each test starts at 0.
  GFixtureForm.EdtChangeCount    := 0;

  StartBridgeOnPipe(FPipeName);
end;


procedure TBridgeTests.TearDown;
begin
  StopBridge;
end;


procedure TBridgeTests.TearDownFixture;
begin
  FreeAndNil(GFixtureForm);
end;


procedure TBridgeTests.Test_HandshakeSucceeds;
var
  PipeName: String;
begin
  PipeName := FPipeName;
  RunOnWorkerAndPump(
    procedure
    var Client: TBridgeTestClient;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000),
                      'expected handshake to succeed');
      finally
        Client.Free;
      end;
    end, 5000);
end;


procedure TBridgeTests.Test_ListTree_FindsKnownControls;
var
  PipeName: String;
  FoundForm, FoundBtn, FoundLbl, FoundEdt: Boolean;
begin
  PipeName := FPipeName;
  FoundForm := False; FoundBtn := False; FoundLbl := False; FoundEdt := False;
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Resp, R: TJSONObject;
      Arr: TJSONArray;
      i: Integer;
      Item: TJSONObject;
      Name: TJSONValue;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Resp := Client.Call(1, 'list_tree', nil);
        try
          R := GetOkResult(Resp);
          Assert.IsNotNull(R, 'list_tree should return ok');
          Arr := R.GetValue('components') AS TJSONArray;
          Assert.IsNotNull(Arr, 'result.components missing');
          for i := 0 to Arr.Count - 1 do
          begin
            Item := Arr.Items[i] AS TJSONObject;
            Name := Item.GetValue('name');
            if Name IS TJSONString then
            begin
              if TJSONString(Name).Value = 'FixtureForm' then FoundForm := True;
              if TJSONString(Name).Value = 'btnTest'     then FoundBtn  := True;
              if TJSONString(Name).Value = 'lblStatus'   then FoundLbl  := True;
              if TJSONString(Name).Value = 'edtName'     then FoundEdt  := True;
            end;
          end;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(FoundForm, 'list_tree should include the form itself as a node');
  Assert.IsTrue(FoundBtn,  'list_tree did not return btnTest');
  Assert.IsTrue(FoundLbl,  'list_tree did not return lblStatus');
  Assert.IsTrue(FoundEdt,  'list_tree did not return edtName');
end;


procedure TBridgeTests.Test_GetText_OfLabel;
var
  PipeName, ReadText: String;
begin
  PipeName := FPipeName;
  ReadText := '';
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp, R: TJSONObject;
      V: TJSONValue;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.lblStatus');
        Resp := Client.Call(2, 'get_text', Args);
        try
          R := GetOkResult(Resp);
          Assert.IsNotNull(R, 'get_text should return ok');
          V := R.GetValue('text');
          Assert.IsTrue(V IS TJSONString, 'result.text not a string');
          ReadText := TJSONString(V).Value;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.AreEqual('Initial', ReadText, 'unexpected label text');
end;


procedure TBridgeTests.Test_Click_FiresOnClick;
var
  PipeName: String;
  CountBefore, CountAfter: Integer;
  DispatchedVia: String;
begin
  PipeName := FPipeName;
  CountBefore := GFixtureForm.ClickCount;
  DispatchedVia := '';
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp, R: TJSONObject;
      V: TJSONValue;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnTest');
        Resp := Client.Call(3, 'click', Args);
        try
          R := GetOkResult(Resp);
          Assert.IsNotNull(R, 'click should return ok');
          V := R.GetValue('dispatchedVia');
          if V IS TJSONString then
            DispatchedVia := TJSONString(V).Value;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  CountAfter := GFixtureForm.ClickCount;
  Assert.AreEqual(CountBefore + 1, CountAfter, 'OnClick should have fired exactly once');
  Assert.AreEqual('click', DispatchedVia, 'expected dispatchedVia=click for TButton');
end;


procedure TBridgeTests.Test_Click_DisabledControlReturnsError;
var
  PipeName: String;
  Code: Integer;
begin
  PipeName := FPipeName;
  Code := 0;
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
        Args.AddPair('path', 'FixtureForm.btnDisabled');
        Resp := Client.Call(4, 'click', Args);
        try
          Code := GetErrorCode(Resp);
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.AreEqual(ErrControlDisabled, Code, 'expected control_disabled error');
end;


procedure TBridgeTests.Test_Click_CountFiresNTimes;
const
  N = 7;
var
  PipeName: String;
  CountBefore, CountAfter, ClicksDispatched: Integer;
  HasStoppedReason: Boolean;
begin
  PipeName := FPipeName;
  CountBefore := GFixtureForm.ClickCount;
  ClicksDispatched := 0;
  HasStoppedReason := False;
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp, R: TJSONObject;
      V: TJSONValue;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('count', TJSONNumber.Create(N));
        Resp := Client.Call(10, 'click', Args);
        try
          R := GetOkResult(Resp);
          Assert.IsNotNull(R, 'click should return ok');
          V := R.GetValue('clicksDispatched');
          Assert.IsTrue(V IS TJSONNumber, 'result.clicksDispatched missing/not a number');
          ClicksDispatched := TJSONNumber(V).AsInt;
          HasStoppedReason := R.GetValue('stoppedReason') <> nil;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  CountAfter := GFixtureForm.ClickCount;
  Assert.AreEqual(N, ClicksDispatched, 'clicksDispatched should equal requested count');
  Assert.AreEqual(CountBefore + N, CountAfter, 'OnClick should have fired N times');
  Assert.IsFalse(HasStoppedReason, 'stoppedReason should be absent on full completion');
end;


procedure TBridgeTests.Test_Click_CountZeroReturnsError;
var
  PipeName: String;
  Code: Integer;
begin
  PipeName := FPipeName;
  Code := 0;
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
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('count', TJSONNumber.Create(0));
        Resp := Client.Call(11, 'click', Args);
        try
          Code := GetErrorCode(Resp);
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.AreEqual(ErrInvalidRequest, Code, 'expected invalid-request for count=0');
end;


procedure TBridgeTests.Test_Click_CountAboveCapReturnsError;
var
  PipeName: String;
  Code: Integer;
begin
  PipeName := FPipeName;
  Code := 0;
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
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('count', TJSONNumber.Create(1001));
        Resp := Client.Call(12, 'click', Args);
        try
          Code := GetErrorCode(Resp);
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.AreEqual(ErrInvalidRequest, Code, 'expected invalid-request for count above cap');
end;


// dismiss_dialog with a fractional hwnd must surface as ErrInvalidRequest (-32600), not the
// ErrInternalError (-32603) that TJSONNumber.AsInt64's EConvertError used to produce. Guards the
// TryJsonInt64 hardening of the hwnd arg. No dialog is up; the parse fails before any dialog work.
procedure TBridgeTests.Test_DismissDialog_FractionalHwndReturnsInvalidRequest;
var
  PipeName: String;
begin
  PipeName := FPipeName;
  // The assertion MUST live inside the worker proc: RunOnWorkerAndPump ends its success path
  // with Assert.Pass (raises ETestPass), so any assertion AFTER it is unreachable. A failure
  // here raises ETestFailure on the worker, which the pump re-emits on the main thread.
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
        Args.AddPair('hwnd', TJSONNumber.Create('1.5'));   // a JSON number that is not an integer
        Resp := Client.Call(50, 'dismiss_dialog', Args);
        try
          Assert.AreEqual(ErrInvalidRequest, GetErrorCode(Resp),
            'fractional hwnd must be ErrInvalidRequest (-32600), not ErrInternalError (-32603)');
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
end;


procedure TBridgeTests.Test_Click_CountStopsWhenDisabledMidLoop;
const
  RequestedN = 10;
var
  PipeName: String;
  ClicksDispatched: Integer;
  StoppedReason: String;
begin
  PipeName := FPipeName;
  ClicksDispatched := 0;
  StoppedReason := '';
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp, R: TJSONObject;
      V: TJSONValue;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnSelfDisables');
        Args.AddPair('count', TJSONNumber.Create(RequestedN));
        Resp := Client.Call(13, 'click', Args);
        try
          R := GetOkResult(Resp);
          Assert.IsNotNull(R, 'click should return ok (partial success)');
          V := R.GetValue('clicksDispatched');
          Assert.IsTrue(V IS TJSONNumber, 'result.clicksDispatched missing/not a number');
          ClicksDispatched := TJSONNumber(V).AsInt;
          V := R.GetValue('stoppedReason');
          if V IS TJSONString then
            StoppedReason := TJSONString(V).Value;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  // Button disables itself on its third click, so loop should run 3 then bail.
  Assert.AreEqual(3, ClicksDispatched, 'expected exactly 3 clicks before button disables itself');
  Assert.AreEqual(3, GFixtureForm.SelfDisableCount, 'OnClick should fire 3 times');
  Assert.AreEqual('disabled', StoppedReason, 'expected stoppedReason=disabled');
end;


procedure TBridgeTests.Test_Click_CountFiresOnClickPathNTimes;
const
  N = 4;
var
  PipeName: String;
  CountBefore, CountAfter, ClicksDispatched: Integer;
  DispatchedVia: String;
begin
  PipeName := FPipeName;
  CountBefore := GFixtureForm.LabelClickCount;
  ClicksDispatched := 0;
  DispatchedVia := '';
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp, R: TJSONObject;
      V: TJSONValue;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.lblClickable');
        Args.AddPair('count', TJSONNumber.Create(N));
        Resp := Client.Call(14, 'click', Args);
        try
          R := GetOkResult(Resp);
          Assert.IsNotNull(R, 'click should return ok');
          V := R.GetValue('clicksDispatched');
          Assert.IsTrue(V IS TJSONNumber, 'result.clicksDispatched missing/not a number');
          ClicksDispatched := TJSONNumber(V).AsInt;
          V := R.GetValue('dispatchedVia');
          if V IS TJSONString then
            DispatchedVia := TJSONString(V).Value;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  CountAfter := GFixtureForm.LabelClickCount;
  Assert.AreEqual('onclick', DispatchedVia, 'TLabel.OnClick must use the RTTI/OnClick path');
  Assert.AreEqual(N, ClicksDispatched, 'clicksDispatched should equal requested count');
  Assert.AreEqual(CountBefore + N, CountAfter, 'TLabel.OnClick should have fired N times');
end;


procedure TBridgeTests.Test_Click_MainThreadBlockedReturnsTimeoutError;
const
  // Worker timeout is short (200 ms). The OnClick blocks on SlowGate for up to
  // GateMaxWaitMs; the test signals the gate once the worker has returned the
  // timeout error so the queued procedure completes promptly. This avoids the
  // long main-thread Sleep that used to race the RTL @HandleAnyException path.
  WorkerTimeoutMs = 200;
  GateMaxWaitMs   = 2000;
var
  PipeName: String;
  Code: Integer;
begin
  PipeName := FPipeName;
  Code := 0;
  GFixtureForm.SlowSleepMs := GateMaxWaitMs;
  GFixtureForm.SlowGate.ResetEvent;
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
        Args.AddPair('path', 'FixtureForm.btnSlow');
        Resp := Client.Call(20, 'click', Args, WorkerTimeoutMs);
        try
          Code := GetErrorCode(Resp);
        finally
          Resp.Free;
        end;
        // We got the timeout response back. The queued procedure is still
        // waiting on SlowGate. Releasing it lets it finish cleanly so the
        // dispatch slot is released on both sides before TearDown fires.
        GFixtureForm.SlowGate.SetEvent;
      finally
        Client.Free;
      end;
    end, GateMaxWaitMs + 3000);
  Assert.AreEqual(ErrMainThreadBlocked, Code, 'expected main_thread_blocked when OnClick exceeds timeoutMs');
  Assert.AreEqual(1, GFixtureForm.SlowClickCount, 'OnClick should still have run on the main thread');
end;


procedure TBridgeTests.Test_GetText_NotFoundReturnsError;
var
  PipeName: String;
  Code: Integer;
begin
  PipeName := FPipeName;
  Code := 0;
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
        Args.AddPair('path', 'FixtureForm.bogusComponent');
        Resp := Client.Call(5, 'get_text', Args);
        try
          Code := GetErrorCode(Resp);
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.AreEqual(ErrNotFound, Code, 'expected not_found error');
end;


procedure TBridgeTests.Test_UnknownCmdReturnsError;
var
  PipeName: String;
  Code: Integer;
begin
  PipeName := FPipeName;
  Code := 0;
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Resp: TJSONObject;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Resp := Client.Call(6, 'frobnicate', nil);
        try
          Code := GetErrorCode(Resp);
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.AreEqual(ErrUnsupportedAction, Code, 'expected unsupported_action error');
end;


procedure TBridgeTests.Test_SetText_UpdatesEditValue;
const
  NewText = 'rewritten by bridge';
var
  PipeName: String;
  Ok: Boolean;
begin
  PipeName := FPipeName;
  Ok := False;
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
        Args.AddPair('path', 'FixtureForm.edtName');
        Args.AddPair('text', NewText);
        Resp := Client.Call(30, 'set_text', Args);
        try
          Ok := GetOkResult(Resp) <> nil;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Ok, 'set_text should return ok');
  Assert.AreEqual(NewText, GFixtureForm.Edt.Text, 'edit Text should be updated');
end;


procedure TBridgeTests.Test_SetText_DisabledControlReturnsError;
var
  PipeName: String;
  Code: Integer;
begin
  PipeName := FPipeName;
  Code := 0;
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
        Args.AddPair('path', 'FixtureForm.edtDisabled');
        Args.AddPair('text', 'should not land');
        Resp := Client.Call(31, 'set_text', Args);
        try
          Code := GetErrorCode(Resp);
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.AreEqual(ErrControlDisabled, Code, 'expected control_disabled error');
  Assert.AreEqual('frozen', GFixtureForm.EdtDisabled.Text, 'disabled edit should keep original text');
end;


procedure TBridgeTests.Test_SetChecked_UpdatesCheckbox;
var
  PipeName: String;
  Ok: Boolean;
begin
  PipeName := FPipeName;
  Ok := False;
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
        Args.AddPair('path', 'FixtureForm.cbxFlag');
        Args.AddPair('checked', TJSONBool.Create(True));
        Resp := Client.Call(32, 'set_checked', Args);
        try
          Ok := GetOkResult(Resp) <> nil;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Ok, 'set_checked should return ok');
  Assert.IsTrue(GFixtureForm.Cbx.Checked, 'checkbox should be checked after set_checked');
end;


procedure TBridgeTests.Test_SetChecked_DisabledControlReturnsError;
var
  PipeName: String;
  Code: Integer;
begin
  PipeName := FPipeName;
  Code := 0;
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
        Args.AddPair('path', 'FixtureForm.cbxDisabled');
        Args.AddPair('checked', TJSONBool.Create(True));
        Resp := Client.Call(33, 'set_checked', Args);
        try
          Code := GetErrorCode(Resp);
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.AreEqual(ErrControlDisabled, Code, 'expected control_disabled error');
  Assert.IsFalse(GFixtureForm.CbxDisabled.Checked, 'disabled checkbox should not change');
end;


procedure TBridgeTests.Test_ListTree_SyntheticIdForUnnamedComponent;
var
  PipeName, FoundSyntheticName: String;
  FoundSynthetic: Boolean;
begin
  PipeName := FPipeName;
  FoundSynthetic := False;
  FoundSyntheticName := '';
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Resp, R: TJSONObject;
      Arr: TJSONArray;
      i: Integer;
      Item: TJSONObject;
      NameVal, SyntheticVal: TJSONValue;
      NodeName: String;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Resp := Client.Call(40, 'list_tree', nil);
        try
          R := GetOkResult(Resp);
          Assert.IsNotNull(R, 'list_tree should return ok');
          Arr := R.GetValue('components') AS TJSONArray;
          Assert.IsNotNull(Arr, 'result.components missing');
          for i := 0 to Arr.Count - 1 do
          begin
            Item := Arr.Items[i] AS TJSONObject;
            NameVal := Item.GetValue('name');
            if not (NameVal IS TJSONString) then Continue;
            NodeName := TJSONString(NameVal).Value;
            if (NodeName <> '') and (NodeName[1] = '@') then
            begin
              SyntheticVal := Item.GetValue('synthetic');
              if (SyntheticVal IS TJSONBool) and TJSONBool(SyntheticVal).AsBoolean then
              begin
                FoundSynthetic := True;
                FoundSyntheticName := NodeName;
                Break;
              end;
            end;
          end;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(FoundSynthetic, 'list_tree should emit a synthetic node for the unnamed button');
  Assert.StartsWith('@TButton#', FoundSyntheticName, 'synthetic name should be @TButton#<index>');
end;


procedure TBridgeTests.Test_Click_BySyntheticIdFiresOnClick;
var
  PipeName, SyntheticPath: String;
  ClicksBefore, ClicksAfter: Integer;
  DispatchedVia: String;
begin
  PipeName := FPipeName;
  // Build the synthetic path the same way the bridge does — anchored on the unnamed
  // button's actual ComponentIndex so the test stays correct if the fixture grows.
  SyntheticPath := 'FixtureForm.@TButton#' + IntToStr(GFixtureForm.BtnUnnamed.ComponentIndex);
  ClicksBefore := GFixtureForm.BtnUnnamedClicks;
  DispatchedVia := '';
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp, R: TJSONObject;
      V: TJSONValue;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', SyntheticPath);
        Resp := Client.Call(41, 'click', Args);
        try
          R := GetOkResult(Resp);
          Assert.IsNotNull(R, 'click should return ok via synthetic path');
          V := R.GetValue('dispatchedVia');
          if V IS TJSONString then
            DispatchedVia := TJSONString(V).Value;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  ClicksAfter := GFixtureForm.BtnUnnamedClicks;
  Assert.AreEqual(ClicksBefore + 1, ClicksAfter, 'OnClick should have fired exactly once via synthetic path');
  Assert.AreEqual('click', DispatchedVia, 'expected dispatchedVia=click for TButton via synthetic path');
end;


procedure TBridgeTests.Test_ListTree_RecursesIntoFrames;
var
  PipeName: String;
  FoundFrame, FoundInner: Boolean;
  InnerPath: String;
begin
  PipeName := FPipeName;
  FoundFrame := False;
  FoundInner := False;
  InnerPath := '';
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Resp, R: TJSONObject;
      Arr: TJSONArray;
      i: Integer;
      Item: TJSONObject;
      NameVal, PathVal: TJSONValue;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Resp := Client.Call(50, 'list_tree', nil);
        try
          R := GetOkResult(Resp);
          Assert.IsNotNull(R, 'list_tree should return ok');
          Arr := R.GetValue('components') AS TJSONArray;
          Assert.IsNotNull(Arr, 'result.components missing');
          for i := 0 to Arr.Count - 1 do
          begin
            Item := Arr.Items[i] AS TJSONObject;
            NameVal := Item.GetValue('name');
            if not (NameVal IS TJSONString) then Continue;
            if TJSONString(NameVal).Value = 'frmInner'   then FoundFrame := True;
            if TJSONString(NameVal).Value = 'btnInFrame' then
            begin
              FoundInner := True;
              PathVal := Item.GetValue('path');
              if PathVal IS TJSONString then
                InnerPath := TJSONString(PathVal).Value;
            end;
          end;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(FoundFrame, 'list_tree should include the frame');
  Assert.IsTrue(FoundInner, 'list_tree should recurse into the frame and include its child button');
  Assert.AreEqual('FixtureForm.frmInner.btnInFrame', InnerPath,
                  'frame-child path should be Form.Frame.Child (anchored)');
end;


procedure TBridgeTests.Test_Click_FrameChildByFlatPathFiresOnClick;
var
  PipeName: String;
  ClicksBefore, ClicksAfter: Integer;
begin
  PipeName := FPipeName;
  ClicksBefore := GFixtureForm.BtnInFrameClicks;
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
        // Flat 2-part path: recursive search should find the button inside the frame.
        Args.AddPair('path', 'FixtureForm.btnInFrame');
        Resp := Client.Call(51, 'click', Args);
        try
          Assert.IsNotNull(GetOkResult(Resp), 'click via flat path should return ok');
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  ClicksAfter := GFixtureForm.BtnInFrameClicks;
  Assert.AreEqual(ClicksBefore + 1, ClicksAfter, 'flat-path click should reach the frame child');
end;


procedure TBridgeTests.Test_Click_FrameChildByAnchoredPathFiresOnClick;
var
  PipeName: String;
  ClicksBefore, ClicksAfter: Integer;
begin
  PipeName := FPipeName;
  ClicksBefore := GFixtureForm.BtnInFrameClicks;
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
        // Anchored 3-part path: each segment is a direct child of the previous.
        Args.AddPair('path', 'FixtureForm.frmInner.btnInFrame');
        Resp := Client.Call(52, 'click', Args);
        try
          Assert.IsNotNull(GetOkResult(Resp), 'click via anchored path should return ok');
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  ClicksAfter := GFixtureForm.BtnInFrameClicks;
  Assert.AreEqual(ClicksBefore + 1, ClicksAfter, 'anchored-path click should reach the frame child');
end;


procedure TBridgeTests.Test_Click_DesignTimeStyleFrameChildFiresOnClick;
var
  PipeName: String;
  ClicksBefore, ClicksAfter: Integer;
begin
  PipeName := FPipeName;
  ClicksBefore := GFixtureForm.BtnOnFrameDesignTimeClicks;
  // BtnOnFrameDesignTime is owned by the form (not by the frame). This mirrors
  // DFM-loaded frames: TReader.ReadDataInner sets each child's Owner to Root
  // (the form), regardless of visual parenting. The flat 2-part path must still
  // find it — it lives directly in Form.Components[].
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
        Args.AddPair('path', 'FixtureForm.btnOnFrameDT');
        Resp := Client.Call(60, 'click', Args);
        try
          Assert.IsNotNull(GetOkResult(Resp), 'click should return ok');
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  ClicksAfter := GFixtureForm.BtnOnFrameDesignTimeClicks;
  Assert.AreEqual(ClicksBefore + 1, ClicksAfter,
                  'design-time-style frame child (Owner=Form, Parent=Frame) should be clickable via flat path');
end;


procedure TBridgeTests.Test_FindByPath_FormItselfByOneSegmentPath;
var
  PipeName, ReadText: String;
begin
  PipeName := FPipeName;
  ReadText := '';
  // Round-trip check: list_tree emits the form node with path='FixtureForm'.
  // get_text against that same path must resolve back to the form itself and
  // read its Caption.
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp, R: TJSONObject;
      V: TJSONValue;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Resp := Client.Call(61, 'get_text', Args);
        try
          R := GetOkResult(Resp);
          Assert.IsNotNull(R, 'get_text on form path should return ok');
          V := R.GetValue('text');
          Assert.IsTrue(V IS TJSONString, 'result.text should be a string');
          ReadText := TJSONString(V).Value;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.AreEqual('Fixture', ReadText, 'one-segment path should resolve to the form itself');
end;


procedure TBridgeTests.Test_SetProperty_WritesString;
var
  PipeName: String;
  Ok: Boolean;
begin
  PipeName := FPipeName;
  Ok := False;
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
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('propName', 'Caption');
        Args.AddPair('value', 'set by set_property');
        Resp := Client.Call(70, 'set_property', Args);
        try
          Ok := GetOkResult(Resp) <> nil;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok for a writable string property');
  Assert.AreEqual('set by set_property', GFixtureForm.Btn.Caption, 'Caption should be updated');
end;


procedure TBridgeTests.Test_SetProperty_WritesInteger;
var
  PipeName: String;
  Ok: Boolean;
begin
  PipeName := FPipeName;
  Ok := False;
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
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('propName', 'Tag');
        Args.AddPair('value', '42');
        Resp := Client.Call(71, 'set_property', Args);
        try
          Ok := GetOkResult(Resp) <> nil;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok for a writable integer property');
  Assert.AreEqual(NativeInt(42), GFixtureForm.Btn.Tag, 'Tag should be 42');
end;


procedure TBridgeTests.Test_SetProperty_WritesBoolean;
var
  PipeName: String;
  Ok: Boolean;
begin
  PipeName := FPipeName;
  Ok := False;
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
        Args.AddPair('path', 'FixtureForm.cbxFlag');
        Args.AddPair('propName', 'Checked');
        Args.AddPair('value', 'true');
        Resp := Client.Call(72, 'set_property', Args);
        try
          Ok := GetOkResult(Resp) <> nil;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok for a writable boolean property');
  Assert.IsTrue(GFixtureForm.Cbx.Checked, 'cbxFlag.Checked should be True');
end;


procedure TBridgeTests.Test_SetProperty_WritesEnumByIdentifier;
var
  PipeName: String;
  Ok: Boolean;
begin
  PipeName := FPipeName;
  Ok := False;
  // TForm.Position is TPosition (enum). poDesigned = 0, poDefault = 1, etc.
  // Default in fixture form Setup is poDesigned. Switch it to poDefaultSizeOnly.
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
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'Position');
        Args.AddPair('value', 'poDefaultSizeOnly');
        Resp := Client.Call(73, 'set_property', Args);
        try
          Ok := GetOkResult(Resp) <> nil;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Ok, 'set_property should accept enum identifier');
  Assert.AreEqual(Ord(poDefaultSizeOnly), Ord(GFixtureForm.Position), 'Position should change to poDefaultSizeOnly');
end;


procedure TBridgeTests.Test_SetProperty_WritesFloat;
var
  PipeName: String;
  Ok: Boolean;
begin
  PipeName := FPipeName;
  Ok := False;
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
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'FloatProp');
        Args.AddPair('value', '3.14');
        Resp := Client.Call(74, 'set_property', Args);
        try
          Ok := GetOkResult(Resp) <> nil;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok for a writable float property');
  Assert.AreEqual(Single(3.14), GFixtureForm.FloatProp, 0.001, 'FloatProp should be 3.14');
end;


procedure TBridgeTests.Test_SetProperty_UnknownPropertyReturnsListOfWritables;
var
  PipeName: String;
  Code: Integer;
  HasCaption, HasTag: Boolean;
begin
  PipeName := FPipeName;
  Code := 0;
  HasCaption := False;
  HasTag := False;
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
      Data, Item: TJSONObject;
      Arr: TJSONArray;
      i: Integer;
      V: TJSONValue;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('propName', 'NoSuchProperty');
        Args.AddPair('value', 'whatever');
        Resp := Client.Call(75, 'set_property', Args);
        try
          Code := GetErrorCode(Resp);
          Data := GetErrorData(Resp);
          if Data <> nil then
          begin
            Arr := Data.GetValue('availableProperties') AS TJSONArray;
            if Arr <> nil then
              for i := 0 to Arr.Count - 1 do
              begin
                Item := Arr.Items[i] AS TJSONObject;
                V := Item.GetValue('name');
                if V IS TJSONString then
                begin
                  if TJSONString(V).Value = 'Caption' then HasCaption := True;
                  if TJSONString(V).Value = 'Tag'     then HasTag     := True;
                end;
              end;
          end;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.AreEqual(ErrRttiPropertyMissing, Code, 'expected rtti_property_missing');
  Assert.IsTrue(HasCaption, 'availableProperties should list Caption');
  Assert.IsTrue(HasTag,     'availableProperties should list Tag');
end;


procedure TBridgeTests.Test_SetProperty_TypeMismatchReturnsUnsupportedAction;
var
  PipeName: String;
  Code: Integer;
begin
  PipeName := FPipeName;
  Code := 0;
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
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('propName', 'Tag');
        Args.AddPair('value', 'not a number');
        Resp := Client.Call(76, 'set_property', Args);
        try
          Code := GetErrorCode(Resp);
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.AreEqual(ErrUnsupportedAction, Code,
                  'non-numeric value for integer property should return unsupported_action');
  Assert.AreEqual(NativeInt(0), GFixtureForm.Btn.Tag, 'Tag should remain at its default 0');
end;


procedure TBridgeTests.Test_SetProperty_DisabledControlReturnsError;
var
  PipeName: String;
  Code: Integer;
begin
  PipeName := FPipeName;
  Code := 0;
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
        Args.AddPair('path', 'FixtureForm.btnDisabled');
        Args.AddPair('propName', 'Caption');
        Args.AddPair('value', 'should not land');
        Resp := Client.Call(77, 'set_property', Args);
        try
          Code := GetErrorCode(Resp);
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.AreEqual(ErrControlDisabled, Code, 'expected control_disabled error');
  Assert.AreEqual('Disabled', GFixtureForm.BtnDisabled.Caption, 'disabled button caption should be unchanged');
end;


procedure TBridgeTests.Test_SetProperty_WritesSetByBracketLiteral;
var
  PipeName: String;
  Ok: Boolean;
begin
  PipeName := FPipeName;
  Ok := False;
  GFixtureForm.MySetProp := [];
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp, R: TJSONObject;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MySetProp');
        Args.AddPair('value', '[fcRed,fcBlue]');
        Resp := Client.Call(78, 'set_property', Args);
        try
          R := GetOkResult(Resp);
          Ok := R <> nil;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok for a set literal');
  Assert.IsTrue(fcRed  in GFixtureForm.MySetProp, 'fcRed should be set');
  Assert.IsTrue(fcBlue in GFixtureForm.MySetProp, 'fcBlue should be set');
  Assert.IsFalse(fcGreen in GFixtureForm.MySetProp, 'fcGreen should NOT be set');
end;


procedure TBridgeTests.Test_SetProperty_WritesSetByBareIdentifierList;
var
  PipeName: String;
  Ok: Boolean;
begin
  PipeName := FPipeName;
  Ok := False;
  GFixtureForm.MySetProp := [];
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp, R: TJSONObject;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MySetProp');
        Args.AddPair('value', 'fcGreen,fcYellow');
        Resp := Client.Call(79, 'set_property', Args);
        try
          R := GetOkResult(Resp);
          Ok := R <> nil;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Ok, 'set_property should accept a bare comma list (no brackets)');
  Assert.IsTrue(fcGreen  in GFixtureForm.MySetProp, 'fcGreen should be set');
  Assert.IsTrue(fcYellow in GFixtureForm.MySetProp, 'fcYellow should be set');
  Assert.IsFalse(fcRed   in GFixtureForm.MySetProp, 'fcRed should NOT be set');
end;


procedure TBridgeTests.Test_SetProperty_WritesEmptySet;
var
  PipeName: String;
  Ok: Boolean;
begin
  PipeName := FPipeName;
  Ok := False;
  GFixtureForm.MySetProp := [fcRed, fcGreen];
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp, R: TJSONObject;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MySetProp');
        Args.AddPair('value', '[]');
        Resp := Client.Call(80, 'set_property', Args);
        try
          R := GetOkResult(Resp);
          Ok := R <> nil;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Ok, 'set_property should accept the empty-set literal "[]"');
  Assert.IsTrue(GFixtureForm.MySetProp = [], 'MySetProp should now be empty');
end;


procedure TBridgeTests.Test_SetProperty_InvalidSetIdentifierReturnsUnsupportedAction;
var
  PipeName: String;
  Code: Integer;
begin
  PipeName := FPipeName;
  Code := 0;
  GFixtureForm.MySetProp := [fcRed];
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
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MySetProp');
        Args.AddPair('value', '[fcPuce]');     // not a member of TFixtureColor
        Resp := Client.Call(81, 'set_property', Args);
        try
          Code := GetErrorCode(Resp);
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.AreEqual(ErrUnsupportedAction, Code,
                  'invalid set identifier should return unsupported_action');
  Assert.IsTrue(GFixtureForm.MySetProp = [fcRed],
                'MySetProp should be untouched after a bad set value');
end;


procedure TBridgeTests.Test_SetProperty_AvailablePropertiesIncludeCurrentValue;
var
  PipeName: String;
  CaptionCurrent, TagCurrent, FloatCurrent: String;
  HasCaptionCurrent, HasTagCurrent, HasFloatCurrent: Boolean;
begin
  PipeName := FPipeName;
  HasCaptionCurrent := False;
  HasTagCurrent := False;
  HasFloatCurrent := False;
  CaptionCurrent := '';
  TagCurrent := '';
  FloatCurrent := '';
  // Set known, distinctive values so we can spot them in the response.
  GFixtureForm.Btn.Caption := 'CurrentCaption42';
  GFixtureForm.Btn.Tag     := 7;
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
      Data, Item: TJSONObject;
      Arr: TJSONArray;
      i: Integer;
      NameV, CurV: TJSONValue;
      PName: String;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('propName', 'NoSuchProperty');
        Args.AddPair('value', '');
        Resp := Client.Call(82, 'set_property', Args);
        try
          Data := GetErrorData(Resp);
          Assert.IsNotNull(Data, 'expected error.data on unknown property');
          Arr := Data.GetValue('availableProperties') AS TJSONArray;
          Assert.IsNotNull(Arr, 'availableProperties array missing');
          for i := 0 to Arr.Count - 1 do
          begin
            Item := Arr.Items[i] AS TJSONObject;
            NameV := Item.GetValue('name');
            if not (NameV IS TJSONString) then Continue;
            PName := TJSONString(NameV).Value;
            CurV := Item.GetValue('currentValue');
            if not (CurV IS TJSONString) then Continue;
            if PName = 'Caption' then begin HasCaptionCurrent := True; CaptionCurrent := TJSONString(CurV).Value; end;
            if PName = 'Tag'     then begin HasTagCurrent     := True; TagCurrent     := TJSONString(CurV).Value; end;
            if PName = 'Enabled' then begin {smoke-check boolean kind is read} end;
            if PName = 'Width'   then begin {smoke-check integer kind is read} end;
            // FloatProp is on TFixtureForm, not on Btn — won't show here. We check it
            // via a second test below. Keep this fixture path focused on the button's
            // own published properties.
            // Mark FloatCurrent as observed if it does appear on Btn (it doesn't, but
            // referencing the variable keeps it from being dead-stripped to a warning).
            if PName = 'FloatProp' then begin HasFloatCurrent := True; FloatCurrent := TJSONString(CurV).Value; end;
          end;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(HasCaptionCurrent, 'expected Caption.currentValue in availableProperties');
  Assert.AreEqual('CurrentCaption42', CaptionCurrent,
                  'Caption.currentValue should reflect the live caption');
  Assert.IsTrue(HasTagCurrent, 'expected Tag.currentValue in availableProperties');
  Assert.AreEqual('7', TagCurrent, 'Tag.currentValue should be "7"');
  // Touch the float variables so the compiler doesn't flag them as unused-but-assigned.
  if HasFloatCurrent then Assert.IsNotEmpty(FloatCurrent);
end;


// Headline tkClass test: write TStrings.Text via dotted propName. The fixture
// form exposes MyLines: TStrings (backed by a TStringList) — same RTTI shape
// as TMemo.Lines without needing a window handle. The bridge resolves the
// outer MyLines getter, then recurses onto the TStrings instance to set Text.
procedure TBridgeTests.Test_SetProperty_WritesNestedClassMemberLinesText;
var
  PipeName: String;
  Ok: Boolean;
begin
  PipeName := FPipeName;
  Ok := False;
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
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MyLines.Text');
        Args.AddPair('value', 'line one'#13#10'line two');
        Resp := Client.Call(83, 'set_property', Args);
        try
          Ok := GetOkResult(Resp) <> nil;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok for a dotted tkClass.tkString path');
  // TStrings.Text round-trips with a trailing CRLF on get; compare lines content
  // via Trim so we don't depend on that surface detail.
  Assert.AreEqual('line one'#13#10'line two',
                  Trim(GFixtureForm.MyLines.Text),
                  'MyLines.Text should reflect the two-line value');
end;


// Second tkClass test: Font.Size on a TButton. Font is published on every
// TControl as a tkClass property; TFont.Size is a writable Integer. Verifies
// the dotted path works for tkClass.tkInteger too.
procedure TBridgeTests.Test_SetProperty_WritesNestedClassMemberFontSize;
var
  PipeName: String;
  Ok: Boolean;
begin
  PipeName := FPipeName;
  Ok := False;
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
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('propName', 'Font.Size');
        Args.AddPair('value', '18');
        Resp := Client.Call(84, 'set_property', Args);
        try
          Ok := GetOkResult(Resp) <> nil;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok for a dotted tkClass.tkInteger path');
  Assert.AreEqual(18, GFixtureForm.Btn.Font.Size, 'btnTest.Font.Size should be 18');
end;


// 2026-05-20: bridge now turns ParentFont off before a dotted Font.* write.
// The VCL does the same flip itself as a side effect of TControl.FontChanged,
// so the post-write end state was always Font.Size=N and ParentFont=False
// even without the bridge's help. The bridge pre-flip matters in the elision
// path (no actual SetValue → no FontChanged → no VCL auto-flip), and pins
// the contract: after any set_property Font.* call, ParentFont is False.
// Verify both legs: the size landed AND ParentFont is now False.
procedure TBridgeTests.Test_SetProperty_DottedFontWriteFlipsParentFontFalse;
var
  PipeName: String;
  Ok: Boolean;
begin
  // Per-test SetUp resets ParentFont:=True and Font.Size:=8. Confirm baseline
  // before the bridge call so a failure here points at the test setup, not at
  // the bridge.
  Assert.IsTrue(GFixtureForm.Btn.ParentFont,
                'precondition: Btn.ParentFont must be True for this test');
  Assert.AreEqual(8, GFixtureForm.Btn.Font.Size,
                  'precondition: Btn.Font.Size must be 8 for this test');

  PipeName := FPipeName;
  Ok := False;
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
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('propName', 'Font.Size');
        Args.AddPair('value', '20');
        Resp := Client.Call(184, 'set_property', Args);
        try
          Ok := GetOkResult(Resp) <> nil;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Ok, 'set_property Font.Size=20 should succeed');
  Assert.AreEqual(20, GFixtureForm.Btn.Font.Size,
                  'Btn.Font.Size should be 20 after the bridge write');
  Assert.IsFalse(GFixtureForm.Btn.ParentFont,
                 'bridge should have auto-flipped Btn.ParentFont to False so the size sticks');
end;


// When the outer is tkClass but the inner name is wrong, availableProperties
// should enumerate the INNER class's writable surface (TFont in this case),
// not the outer component's. Verifies HandleSetProperty uses AFailedInstance.
procedure TBridgeTests.Test_SetProperty_DottedUnknownInnerListsInnerWritables;
var
  PipeName: String;
  Code: Integer;
  HasFontSize, HasFontColor, HasFontName, HasButtonCaption: Boolean;
begin
  PipeName := FPipeName;
  Code := 0;
  HasFontSize := False;
  HasFontColor := False;
  HasFontName := False;
  HasButtonCaption := False;
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
      Data, Item: TJSONObject;
      Arr: TJSONArray;
      i: Integer;
      V: TJSONValue;
      PName: String;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('propName', 'Font.NoSuchInner');
        Args.AddPair('value', 'whatever');
        Resp := Client.Call(85, 'set_property', Args);
        try
          Code := GetErrorCode(Resp);
          Data := GetErrorData(Resp);
          if Data <> nil then
          begin
            Arr := Data.GetValue('availableProperties') AS TJSONArray;
            if Arr <> nil then
              for i := 0 to Arr.Count - 1 do
              begin
                Item := Arr.Items[i] AS TJSONObject;
                V := Item.GetValue('name');
                if V IS TJSONString then
                begin
                  PName := TJSONString(V).Value;
                  if PName = 'Size'    then HasFontSize  := True;
                  if PName = 'Color'   then HasFontColor := True;
                  if PName = 'Name'    then HasFontName  := True;
                  if PName = 'Caption' then HasButtonCaption := True;
                end;
              end;
          end;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.AreEqual(ErrRttiPropertyMissing, Code, 'expected rtti_property_missing');
  Assert.IsTrue(HasFontSize,  'availableProperties should list TFont.Size when inner name was bogus');
  Assert.IsTrue(HasFontColor, 'availableProperties should list TFont.Color');
  Assert.IsTrue(HasFontName,  'availableProperties should list TFont.Name');
  Assert.IsFalse(HasButtonCaption,
                 'availableProperties should NOT include TButton.Caption — we asked about Font, not the button');
end;


// Dotted propName where the outer is not tkClass (e.g. 'Caption.Length' on a
// button) should return unsupported_action — TCaption is a String, not a class.
procedure TBridgeTests.Test_SetProperty_DottedOnNonClassOuterReturnsUnsupportedAction;
var
  PipeName: String;
  Code: Integer;
begin
  PipeName := FPipeName;
  Code := 0;
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
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('propName', 'Caption.Length');
        Args.AddPair('value', '5');
        Resp := Client.Call(86, 'set_property', Args);
        try
          Code := GetErrorCode(Resp);
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.AreEqual(ErrUnsupportedAction, Code,
                  'dotted propName on non-class outer should return unsupported_action');
end;


// Pin the disabled-control gate's interaction with dotted propName. The check
// sits on the OUTER component (TButton), not the inner TPersistent. So
// 'btnDisabled.Font.Size := 14' returns control_disabled and the inner value
// stays at its pre-call setting — even though TFont itself has no Enabled.
// This locks the contract; a future change that decides nested writes should
// bypass the gate must update this test deliberately.
procedure TBridgeTests.Test_SetProperty_DottedOnDisabledControlReturnsControlDisabled;
var
  PipeName: String;
  Code: Integer;
  SizeBefore, SizeAfter: Integer;
begin
  PipeName := FPipeName;
  Code := 0;
  GFixtureForm.BtnDisabled.Font.Size := 9;
  SizeBefore := GFixtureForm.BtnDisabled.Font.Size;
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
        Args.AddPair('path', 'FixtureForm.btnDisabled');
        Args.AddPair('propName', 'Font.Size');
        Args.AddPair('value', '14');
        Resp := Client.Call(88, 'set_property', Args);
        try
          Code := GetErrorCode(Resp);
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  SizeAfter := GFixtureForm.BtnDisabled.Font.Size;
  Assert.AreEqual(ErrControlDisabled, Code,
                  'dotted write on disabled control should return control_disabled');
  Assert.AreEqual(SizeBefore, SizeAfter,
                  'Font.Size on disabled control should NOT change');
end;


// Two levels of nesting ('Font.Color.Red') is intentionally not supported.
// The error should be unsupported_action, not a silent walk into arbitrarily
// deep structure.
procedure TBridgeTests.Test_SetProperty_DottedTwoLevelsReturnsUnsupportedAction;
var
  PipeName: String;
  Code: Integer;
begin
  PipeName := FPipeName;
  Code := 0;
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
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('propName', 'Font.A.B');
        Args.AddPair('value', '1');
        Resp := Client.Call(87, 'set_property', Args);
        try
          Code := GetErrorCode(Resp);
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.AreEqual(ErrUnsupportedAction, Code,
                  'two-level dotted propName should be rejected with unsupported_action');
end;


// 8-digit ARGB hex: alpha + RGB explicit. Verifies the bridge writes the
// exact 32-bit value, not a coerced/truncated variant.
procedure TBridgeTests.Test_SetProperty_AlphaColorByHexWithAlpha;
var
  PipeName: String;
  Ok: Boolean;
begin
  PipeName := FPipeName;
  Ok := False;
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
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MyAlpha');
        Args.AddPair('value', '#80FF8000');     // 50% alpha, full red, half green, no blue
        Resp := Client.Call(89, 'set_property', Args);
        try
          Ok := GetOkResult(Resp) <> nil;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok for an 8-digit ARGB hex');
  Assert.AreEqual(Cardinal($80FF8000), Cardinal(GFixtureForm.MyAlpha),
                  'MyAlpha should be exactly $80FF8000');
end;


// 6-digit RGB short form: alpha is implicit FF. Without this convenience the
// AI would have to remember to prepend FF to every web-style color literal.
procedure TBridgeTests.Test_SetProperty_AlphaColorByHexShortFormAssumesFullAlpha;
var
  PipeName: String;
  Ok: Boolean;
begin
  PipeName := FPipeName;
  Ok := False;
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
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MyAlpha');
        Args.AddPair('value', '#FF8000');       // 6 digits — alpha assumed FF
        Resp := Client.Call(90, 'set_property', Args);
        try
          Ok := GetOkResult(Resp) <> nil;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok for a 6-digit RGB hex');
  Assert.AreEqual(Cardinal($FFFF8000), Cardinal(GFixtureForm.MyAlpha),
                  'MyAlpha should be $FFFF8000 (alpha defaulted to FF)');
end;


// 'claSkyBlue' identifier — resolved via System.UIConsts. Confirms the named
// path through StringToAlphaColor works end-to-end.
procedure TBridgeTests.Test_SetProperty_AlphaColorByClaIdentifier;
var
  PipeName: String;
  Ok: Boolean;
begin
  PipeName := FPipeName;
  Ok := False;
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
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MyAlpha');
        Args.AddPair('value', 'claSkyBlue');
        Resp := Client.Call(91, 'set_property', Args);
        try
          Ok := GetOkResult(Resp) <> nil;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok for "claSkyBlue"');
  Assert.AreEqual(Cardinal(claSkyBlue), Cardinal(GFixtureForm.MyAlpha),
                  'MyAlpha should match claSkyBlue');
end;


// Garbage input — not a hex literal, not a cla* identifier, not a number.
// Must return unsupported_action with the property unchanged.
procedure TBridgeTests.Test_SetProperty_AlphaColorInvalidValueReturnsUnsupportedAction;
var
  PipeName: String;
  Code: Integer;
  AlphaBefore: TAlphaColor;
begin
  PipeName := FPipeName;
  Code := 0;
  GFixtureForm.MyAlpha := TAlphaColor($DEADBEEF);
  AlphaBefore := GFixtureForm.MyAlpha;
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
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MyAlpha');
        Args.AddPair('value', 'notacolor');
        Resp := Client.Call(92, 'set_property', Args);
        try
          Code := GetErrorCode(Resp);
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.AreEqual(ErrUnsupportedAction, Code,
                  'garbage TAlphaColor input should return unsupported_action');
  Assert.AreEqual(Cardinal(AlphaBefore), Cardinal(GFixtureForm.MyAlpha),
                  'MyAlpha should be unchanged on failed parse');
end;


// Readback formatting: availableProperties.currentValue for a TAlphaColor
// property must render as 'claName' (when named) or '#AARRGGBB' (otherwise),
// not as a decimal — so the AI can paste it straight back into set_property.
procedure TBridgeTests.Test_SetProperty_AlphaColorCurrentValueRendersAsHash;
var
  PipeName: String;
  CurStr: String;
  HasMyAlpha: Boolean;
begin
  PipeName := FPipeName;
  HasMyAlpha := False;
  CurStr := '';
  GFixtureForm.MyAlpha := TAlphaColor($80FF8000);
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
      Data, Item: TJSONObject;
      Arr: TJSONArray;
      i: Integer;
      NameV, CurV: TJSONValue;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'NoSuchProperty');
        Args.AddPair('value', '');
        Resp := Client.Call(93, 'set_property', Args);
        try
          Data := GetErrorData(Resp);
          Assert.IsNotNull(Data, 'expected error.data on unknown property');
          Arr := Data.GetValue('availableProperties') AS TJSONArray;
          Assert.IsNotNull(Arr, 'availableProperties array missing');
          for i := 0 to Arr.Count - 1 do
          begin
            Item := Arr.Items[i] AS TJSONObject;
            NameV := Item.GetValue('name');
            if not (NameV IS TJSONString) then Continue;
            if TJSONString(NameV).Value <> 'MyAlpha' then Continue;
            CurV := Item.GetValue('currentValue');
            if CurV IS TJSONString then
            begin
              HasMyAlpha := True;
              CurStr := TJSONString(CurV).Value;
            end;
            Break;
          end;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(HasMyAlpha, 'expected MyAlpha.currentValue in availableProperties');
  // $80FF8000 isn't a known cla* constant; expect '#80FF8000' (or 'x80FF8000'
  // depending on Delphi version — accept either lowercase first char).
  Assert.IsTrue((CurStr = '#80FF8000') or (CurStr = 'x80FF8000'),
                'MyAlpha currentValue should be hex-shaped, got "' + CurStr + '"');
end;


// availableProperties kind annotation: TAlphaColor entries should report
// kind:'alphacolor' rather than 'integer', so the AI knows to send hex/named
// values without first failing on a raw integer attempt.
procedure TBridgeTests.Test_SetProperty_AlphaColorAvailablePropertiesKindIsAlphacolor;
var
  PipeName: String;
  Kind: String;
  Found: Boolean;
begin
  PipeName := FPipeName;
  Found := False;
  Kind := '';
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
      Data, Item: TJSONObject;
      Arr: TJSONArray;
      i: Integer;
      NameV, KindV: TJSONValue;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'NoSuchProperty');
        Args.AddPair('value', '');
        Resp := Client.Call(94, 'set_property', Args);
        try
          Data := GetErrorData(Resp);
          Arr := Data.GetValue('availableProperties') AS TJSONArray;
          for i := 0 to Arr.Count - 1 do
          begin
            Item := Arr.Items[i] AS TJSONObject;
            NameV := Item.GetValue('name');
            if not (NameV IS TJSONString) then Continue;
            if TJSONString(NameV).Value <> 'MyAlpha' then Continue;
            KindV := Item.GetValue('kind');
            if KindV IS TJSONString then
            begin
              Found := True;
              Kind := TJSONString(KindV).Value;
            end;
            Break;
          end;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Found, 'expected MyAlpha entry in availableProperties');
  Assert.AreEqual('alphacolor', Kind, 'TAlphaColor entries should be labelled kind:"alphacolor"');
end;


// 'clRed' identifier — resolved via System.UIConsts IdentToColor. Confirms
// the named-color path works end-to-end via the bridge's TryStringToColorCompat.
procedure TBridgeTests.Test_SetProperty_ColorByClIdentifier;
var
  PipeName: String;
  Ok: Boolean;
begin
  PipeName := FPipeName;
  Ok := False;
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
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MyColor');
        Args.AddPair('value', 'clRed');
        Resp := Client.Call(95, 'set_property', Args);
        try
          Ok := GetOkResult(Resp) <> nil;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok for "clRed"');
  Assert.AreEqual(Integer(clRed), Integer(GFixtureForm.MyColor),
                  'MyColor should match clRed');
end;


// '#FF0080' — web-style RGB hex. The byte order TryStringToColorCompat uses
// produces the BGR-stored TColor the AI would expect from a web color literal.
procedure TBridgeTests.Test_SetProperty_ColorByWebHex;
var
  PipeName: String;
  Ok: Boolean;
begin
  PipeName := FPipeName;
  Ok := False;
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
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MyColor');
        Args.AddPair('value', '#FF0080');     // R=FF, G=00, B=80
        Resp := Client.Call(96, 'set_property', Args);
        try
          Ok := GetOkResult(Resp) <> nil;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok for "#FF0080"');
  // TColor stores BGR in the low 3 bytes: B=80, G=00, R=FF → $008000FF.
  Assert.AreEqual(Integer($008000FF), Integer(GFixtureForm.MyColor),
                  'MyColor should be $008000FF (web RGB #FF0080 in BGR storage)');
end;


// Garbage input — not a cl* identifier, not a hex literal, not a number.
// Must return unsupported_action with the property unchanged.
procedure TBridgeTests.Test_SetProperty_ColorInvalidValueReturnsUnsupportedAction;
var
  PipeName: String;
  Code: Integer;
  ColorBefore: TColor;
begin
  PipeName := FPipeName;
  Code := 0;
  GFixtureForm.MyColor := TColor($00BEEF42);
  ColorBefore := GFixtureForm.MyColor;
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
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MyColor');
        Args.AddPair('value', 'notacolor');
        Resp := Client.Call(97, 'set_property', Args);
        try
          Code := GetErrorCode(Resp);
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.AreEqual(ErrUnsupportedAction, Code,
                  'garbage TColor input should return unsupported_action');
  Assert.AreEqual(Integer(ColorBefore), Integer(GFixtureForm.MyColor),
                  'MyColor should be unchanged on failed parse');
end;


// Readback formatting: availableProperties.currentValue for a TColor property
// must render as 'clName' (when the integer maps to a known identifier) so the
// AI can paste it straight back into set_property without a hex round-trip.
procedure TBridgeTests.Test_SetProperty_ColorCurrentValueRendersAsName;
var
  PipeName: String;
  CurStr: String;
  HasMyColor: Boolean;
begin
  PipeName := FPipeName;
  HasMyColor := False;
  CurStr := '';
  GFixtureForm.MyColor := clRed;
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
      Data, Item: TJSONObject;
      Arr: TJSONArray;
      i: Integer;
      NameV, CurV: TJSONValue;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'NoSuchProperty');
        Args.AddPair('value', '');
        Resp := Client.Call(98, 'set_property', Args);
        try
          Data := GetErrorData(Resp);
          Assert.IsNotNull(Data, 'expected error.data on unknown property');
          Arr := Data.GetValue('availableProperties') AS TJSONArray;
          Assert.IsNotNull(Arr, 'availableProperties array missing');
          for i := 0 to Arr.Count - 1 do
          begin
            Item := Arr.Items[i] AS TJSONObject;
            NameV := Item.GetValue('name');
            if not (NameV IS TJSONString) then Continue;
            if TJSONString(NameV).Value <> 'MyColor' then Continue;
            CurV := Item.GetValue('currentValue');
            if CurV IS TJSONString then
            begin
              HasMyColor := True;
              CurStr := TJSONString(CurV).Value;
            end;
            Break;
          end;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(HasMyColor, 'expected MyColor.currentValue in availableProperties');
  Assert.AreEqual('clRed', CurStr,
                  'MyColor=clRed should render as "clRed", got "' + CurStr + '"');
end;


// availableProperties kind annotation: TColor entries should report
// kind:'color' rather than 'integer', so the AI knows to send named/hex
// values without first failing on a raw integer attempt.
procedure TBridgeTests.Test_SetProperty_ColorAvailablePropertiesKindIsColor;
var
  PipeName: String;
  Kind: String;
  Found: Boolean;
begin
  PipeName := FPipeName;
  Found := False;
  Kind := '';
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
      Data, Item: TJSONObject;
      Arr: TJSONArray;
      i: Integer;
      NameV, KindV: TJSONValue;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'NoSuchProperty');
        Args.AddPair('value', '');
        Resp := Client.Call(99, 'set_property', Args);
        try
          Data := GetErrorData(Resp);
          Arr := Data.GetValue('availableProperties') AS TJSONArray;
          for i := 0 to Arr.Count - 1 do
          begin
            Item := Arr.Items[i] AS TJSONObject;
            NameV := Item.GetValue('name');
            if not (NameV IS TJSONString) then Continue;
            if TJSONString(NameV).Value <> 'MyColor' then Continue;
            KindV := Item.GetValue('kind');
            if KindV IS TJSONString then
            begin
              Found := True;
              Kind := TJSONString(KindV).Value;
            end;
            Break;
          end;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Found, 'expected MyColor entry in availableProperties');
  Assert.AreEqual('color', Kind, 'TColor entries should be labelled kind:"color"');
end;


// Helper: read the success-response 'elided' boolean. Returns False if missing
// or wrong type — caller's assertion will reveal that case.
function GetElidedFlag(AResult: TJSONObject; out APresent: Boolean): Boolean;
var V: TJSONValue;
begin
  Result   := False;
  APresent := False;
  if AResult = nil then Exit;
  V := AResult.GetValue('elided');
  if not (V IS TJSONBool) then Exit;
  APresent := True;
  Result   := TJSONBool(V).AsBoolean;
end;


// Elision — string equality. Edt.Text already 'HelloWorld'; writing it again
// should be elided. Verified two ways: response carries elided=true, AND
// Edt.OnChange did not fire (EdtChangeCount stayed at 0).
procedure TBridgeTests.Test_SetProperty_ElisionStringEqualReturnsElidedAndSkipsOnChange;
var
  PipeName: String;
  Elided, Present, Ok: Boolean;
  ChangesAfter: Integer;
begin
  PipeName     := FPipeName;
  Elided       := False;
  Present      := False;
  Ok           := False;
  Assert.AreEqual('HelloWorld', GFixtureForm.Edt.Text, 'fixture precondition');
  Assert.AreEqual(0, GFixtureForm.EdtChangeCount, 'fixture precondition: no priming OnChange');
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp, OkRes: TJSONObject;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.edtName');
        Args.AddPair('propName', 'Text');
        Args.AddPair('value', 'HelloWorld');           // same as live value
        Resp := Client.Call(200, 'set_property', Args);
        try
          OkRes := GetOkResult(Resp);
          Ok := OkRes <> nil;
          if Ok then Elided := GetElidedFlag(OkRes, Present);
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  ChangesAfter := GFixtureForm.EdtChangeCount;
  Assert.IsTrue(Ok, 'set_property should return ok even when eliding');
  Assert.IsTrue(Present, 'success response must carry elided field');
  Assert.IsTrue(Elided, 'string-equal write should be elided');
  Assert.AreEqual(0, ChangesAfter, 'OnChange must NOT fire on an elided write');
end;


// Elision — string different. Writing a new value to Edt.Text reports
// elided=false AND fires OnChange once. Pins the negative side of the contract.
procedure TBridgeTests.Test_SetProperty_ElisionStringDifferentFiresOnChangeAndReportsElidedFalse;
var
  PipeName: String;
  Elided, Present, Ok: Boolean;
  ChangesAfter: Integer;
begin
  PipeName     := FPipeName;
  Elided       := True;             // start True; will assert it became False
  Present      := False;
  Ok           := False;
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp, OkRes: TJSONObject;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.edtName');
        Args.AddPair('propName', 'Text');
        Args.AddPair('value', 'NewValue');             // different from 'HelloWorld'
        Resp := Client.Call(201, 'set_property', Args);
        try
          OkRes := GetOkResult(Resp);
          Ok := OkRes <> nil;
          if Ok then Elided := GetElidedFlag(OkRes, Present);
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  ChangesAfter := GFixtureForm.EdtChangeCount;
  Assert.IsTrue(Ok, 'set_property should succeed on a real write');
  Assert.IsTrue(Present, 'success response must carry elided field');
  Assert.IsFalse(Elided, 'string-different write must NOT be elided');
  Assert.AreEqual('NewValue', GFixtureForm.Edt.Text, 'live Text should reflect the write');
  Assert.AreEqual(1, ChangesAfter, 'OnChange should fire exactly once on a real write');
end;


// Elision — integer. Tag starts at 0 (Setup); writing '0' should elide.
procedure TBridgeTests.Test_SetProperty_ElisionIntegerEqualReturnsElided;
var
  PipeName: String;
  Elided, Present, Ok: Boolean;
begin
  PipeName := FPipeName;
  Elided   := False;
  Present  := False;
  Ok       := False;
  Assert.AreEqual(NativeInt(0), GFixtureForm.Tag, 'fixture precondition');
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp, OkRes: TJSONObject;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'Tag');
        Args.AddPair('value', '0');                    // same as live
        Resp := Client.Call(202, 'set_property', Args);
        try
          OkRes := GetOkResult(Resp);
          Ok := OkRes <> nil;
          if Ok then Elided := GetElidedFlag(OkRes, Present);
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok');
  Assert.IsTrue(Present, 'elided field must be present');
  Assert.IsTrue(Elided, 'integer-equal write should be elided');
end;


// Elision — boolean. Cbx.Checked starts at False; writing 'false' elides.
procedure TBridgeTests.Test_SetProperty_ElisionBooleanEqualReturnsElided;
var
  PipeName: String;
  Elided, Present, Ok: Boolean;
begin
  PipeName := FPipeName;
  Elided   := False;
  Present  := False;
  Ok       := False;
  Assert.IsFalse(GFixtureForm.Cbx.Checked, 'fixture precondition');
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp, OkRes: TJSONObject;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.cbxFlag');
        Args.AddPair('propName', 'Checked');
        Args.AddPair('value', 'false');                // same as live
        Resp := Client.Call(203, 'set_property', Args);
        try
          OkRes := GetOkResult(Resp);
          Ok := OkRes <> nil;
          if Ok then Elided := GetElidedFlag(OkRes, Present);
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok');
  Assert.IsTrue(Present, 'elided field must be present');
  Assert.IsTrue(Elided, 'boolean-equal write should be elided');
end;


// Elision — float. FloatProp starts at 0.0; writing '0' elides (parser-equal).
procedure TBridgeTests.Test_SetProperty_ElisionFloatEqualReturnsElided;
var
  PipeName: String;
  Elided, Present, Ok: Boolean;
begin
  PipeName := FPipeName;
  Elided   := False;
  Present  := False;
  Ok       := False;
  GFixtureForm.FloatProp := 1.25;                      // pick something exact in binary
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp, OkRes: TJSONObject;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'FloatProp');
        Args.AddPair('value', '1.25');                 // exact-bits match
        Resp := Client.Call(204, 'set_property', Args);
        try
          OkRes := GetOkResult(Resp);
          Ok := OkRes <> nil;
          if Ok then Elided := GetElidedFlag(OkRes, Present);
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok');
  Assert.IsTrue(Present, 'elided field must be present');
  Assert.IsTrue(Elided, 'float-equal write (exact bits) should be elided');
end;


// Elision — set. MySetProp starts at []; writing '[]' elides. Tests the
// ordinal-equality path for sets.
procedure TBridgeTests.Test_SetProperty_ElisionSetEqualReturnsElided;
var
  PipeName: String;
  Elided, Present, Ok: Boolean;
begin
  PipeName := FPipeName;
  Elided   := False;
  Present  := False;
  Ok       := False;
  GFixtureForm.MySetProp := [fcRed, fcBlue];           // distinctive starting state
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp, OkRes: TJSONObject;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MySetProp');
        Args.AddPair('value', '[fcRed,fcBlue]');       // same elements, same ordinal
        Resp := Client.Call(205, 'set_property', Args);
        try
          OkRes := GetOkResult(Resp);
          Ok := OkRes <> nil;
          if Ok then Elided := GetElidedFlag(OkRes, Present);
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok');
  Assert.IsTrue(Present, 'elided field must be present');
  Assert.IsTrue(Elided, 'set-equal write should be elided');
end;


// Elision — enum. Force Position to poDesigned (independent of test ordering —
// Test_SetProperty_WritesEnumByIdentifier earlier in the suite leaves it on
// poDefaultSizeOnly), then write it back and confirm the bridge elides.
procedure TBridgeTests.Test_SetProperty_ElisionEnumEqualReturnsElided;
var
  PipeName: String;
  Elided, Present, Ok: Boolean;
begin
  PipeName := FPipeName;
  Elided   := False;
  Present  := False;
  Ok       := False;
  GFixtureForm.Position := poDesigned;
  Assert.AreEqual(Ord(poDesigned), Ord(GFixtureForm.Position), 'fixture precondition');
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp, OkRes: TJSONObject;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'Position');
        Args.AddPair('value', 'poDesigned');           // same as live
        Resp := Client.Call(206, 'set_property', Args);
        try
          OkRes := GetOkResult(Resp);
          Ok := OkRes <> nil;
          if Ok then Elided := GetElidedFlag(OkRes, Present);
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok');
  Assert.IsTrue(Present, 'elided field must be present');
  Assert.IsTrue(Elided, 'enum-equal write should be elided');
end;


// Elision — TAlphaColor. Set to a known color, then write the same hex back.
procedure TBridgeTests.Test_SetProperty_ElisionAlphaColorEqualReturnsElided;
var
  PipeName: String;
  Elided, Present, Ok: Boolean;
begin
  PipeName := FPipeName;
  Elided   := False;
  Present  := False;
  Ok       := False;
  GFixtureForm.MyAlpha := TAlphaColor($FFFF8000);      // opaque orange
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp, OkRes: TJSONObject;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MyAlpha');
        Args.AddPair('value', '#FF8000');              // 6-digit form, alpha=FF assumed
        Resp := Client.Call(207, 'set_property', Args);
        try
          OkRes := GetOkResult(Resp);
          Ok := OkRes <> nil;
          if Ok then Elided := GetElidedFlag(OkRes, Present);
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok');
  Assert.IsTrue(Present, 'elided field must be present');
  Assert.IsTrue(Elided, 'TAlphaColor-equal write should be elided');
end;


// Elision — TColor (VCL only). Set to clRed, then write 'clRed' back.
procedure TBridgeTests.Test_SetProperty_ElisionColorEqualReturnsElided;
var
  PipeName: String;
  Elided, Present, Ok: Boolean;
begin
  PipeName := FPipeName;
  Elided   := False;
  Present  := False;
  Ok       := False;
  GFixtureForm.MyColor := clRed;
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp, OkRes: TJSONObject;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MyColor');
        Args.AddPair('value', 'clRed');                // same as live
        Resp := Client.Call(208, 'set_property', Args);
        try
          OkRes := GetOkResult(Resp);
          Ok := OkRes <> nil;
          if Ok then Elided := GetElidedFlag(OkRes, Present);
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok');
  Assert.IsTrue(Present, 'elided field must be present');
  Assert.IsTrue(Elided, 'TColor-equal write should be elided');
end;


// Elision — dotted propName. Btn.Font.Size starts at 8 in Setup; writing '8' elides.
// Pins that the recursive call into the inner tkClass also honors elision.
procedure TBridgeTests.Test_SetProperty_ElisionDottedFontSizeEqualReturnsElided;
var
  PipeName: String;
  Elided, Present, Ok: Boolean;
begin
  PipeName := FPipeName;
  Elided   := False;
  Present  := False;
  Ok       := False;
  Assert.AreEqual(Single(8), Single(GFixtureForm.Btn.Font.Size), 0.001, 'fixture precondition');
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp, OkRes: TJSONObject;
    begin
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('propName', 'Font.Size');
        Args.AddPair('value', '8');                    // same as live
        Resp := Client.Call(209, 'set_property', Args);
        try
          OkRes := GetOkResult(Resp);
          Ok := OkRes <> nil;
          if Ok then Elided := GetElidedFlag(OkRes, Present);
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok');
  Assert.IsTrue(Present, 'elided field must be present');
  Assert.IsTrue(Elided, 'dotted Font.Size-equal write should be elided');
end;


// Contract pin: success responses ALWAYS carry the 'elided' field (true or false).
// Earlier set_property tests don't check this — adding one explicit guard so a
// future refactor that drops the field on some path is caught.
procedure TBridgeTests.Test_SetProperty_SuccessResponseAlwaysCarriesElidedField;
var
  PipeName: String;
  Present, Ok: Boolean;
begin
  PipeName := FPipeName;
  Present  := False;
  Ok       := False;
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args, Resp, OkRes: TJSONObject;
      Dummy: Boolean;
    begin
      Dummy  := False;
      Client := TBridgeTestClient.Create;
      try
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        // Use a write that changes the value, so this also covers the non-elided
        // success path. The elision tests cover the elided=true side.
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('propName', 'Caption');
        Args.AddPair('value', 'OtherCaption');
        Resp := Client.Call(210, 'set_property', Args);
        try
          OkRes := GetOkResult(Resp);
          Ok := OkRes <> nil;
          if Ok then Dummy := GetElidedFlag(OkRes, Present);
          // Touch Dummy so it doesn't get H2077'd as unused.
          if Dummy then ;
        finally
          Resp.Free;
        end;
      finally
        Client.Free;
      end;
    end, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok');
  Assert.IsTrue(Present, 'every success response must carry elided field');
end;


initialization
  TDUnitX.RegisterTestFixture(TBridgeTests);

finalization
  FreeAndNil(GFixtureForm);


end.
