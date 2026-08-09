UNIT Bridge.Tests;

{=====================================================
   DUnitX tests for the Autopilot bridge.

   The bridge does not require a visible form — it walks Screen.Forms[]
   which contains any TCustomForm constructed during the test.

   Each test:
     1. Programmatically builds a form with controls.
     2. Starts the bridge on a synthetic pipe name (PID-independent for repeatable tests).
     3. Connects the test client.
     4. Exercises one command.
     5. Asserts the response, then tears everything down.

   The bridge's main-thread dispatcher is invoked via TThread.Queue, which DUnitX
   drains because the test runner pumps the message queue around each test.
   However, the client runs on the test thread (which IS the main thread when
   DUnitX runs from a VCL host). To avoid blocking the main thread on a synchronous
   Call(), each test spins up the client on a worker thread.
=====================================================}

INTERFACE

USES
  DUnitX.TestFramework;

TYPE
  [TestFixture]
  TBridgeTests = CLASS
  PRIVATE
    FPipeName: String;
    PROCEDURE EnsureFreshPipeName;
  PUBLIC
    [Setup]    PROCEDURE Setup;
    [TearDown] PROCEDURE TearDown;

    [Test] PROCEDURE Test_HandshakeSucceeds;
    [Test] PROCEDURE Test_ListTree_FindsKnownControls;
    [Test] PROCEDURE Test_GetText_OfLabel;
    [Test] PROCEDURE Test_Click_FiresOnClick;
    [Test] PROCEDURE Test_Click_DisabledControlReturnsError;
    [Test] PROCEDURE Test_Click_CountFiresNTimes;
    [Test] PROCEDURE Test_Click_CountZeroReturnsError;
    [Test] PROCEDURE Test_Click_CountAboveCapReturnsError;
    [Test] PROCEDURE Test_Click_CountStopsWhenDisabledMidLoop;
    [Test] PROCEDURE Test_Click_CountFiresOnClickPathNTimes;
    [Test] PROCEDURE Test_Click_MainThreadBlockedReturnsTimeoutError;
    [Test] PROCEDURE Test_GetText_NotFoundReturnsError;
    [Test] PROCEDURE Test_UnknownCmdReturnsError;
    [Test] PROCEDURE Test_SetText_UpdatesEditValue;
    [Test] PROCEDURE Test_SetText_DisabledControlReturnsError;
    [Test] PROCEDURE Test_SetChecked_UpdatesCheckbox;
    [Test] PROCEDURE Test_SetChecked_DisabledControlReturnsError;
    [Test] PROCEDURE Test_ListTree_SyntheticIdForUnnamedComponent;
    [Test] PROCEDURE Test_Click_BySyntheticIdFiresOnClick;
    [Test] PROCEDURE Test_ListTree_RecursesIntoFrames;
    [Test] PROCEDURE Test_Click_FrameChildByFlatPathFiresOnClick;
    [Test] PROCEDURE Test_Click_FrameChildByAnchoredPathFiresOnClick;
    [Test] PROCEDURE Test_Click_DesignTimeStyleFrameChildFiresOnClick;
    [Test] PROCEDURE Test_FindByPath_FormItselfByOneSegmentPath;
    [Test] PROCEDURE Test_SetProperty_WritesString;
    [Test] PROCEDURE Test_SetProperty_WritesInteger;
    [Test] PROCEDURE Test_SetProperty_WritesBoolean;
    [Test] PROCEDURE Test_SetProperty_WritesEnumByIdentifier;
    [Test] PROCEDURE Test_SetProperty_WritesFloat;
    [Test] PROCEDURE Test_SetProperty_UnknownPropertyReturnsListOfWritables;
    [Test] PROCEDURE Test_SetProperty_TypeMismatchReturnsUnsupportedAction;
    [Test] PROCEDURE Test_SetProperty_DisabledControlReturnsError;
    [Test] PROCEDURE Test_SetProperty_WritesSetByBracketLiteral;
    [Test] PROCEDURE Test_SetProperty_WritesSetByBareIdentifierList;
    [Test] PROCEDURE Test_SetProperty_WritesEmptySet;
    [Test] PROCEDURE Test_SetProperty_InvalidSetIdentifierReturnsUnsupportedAction;
    [Test] PROCEDURE Test_SetProperty_AvailablePropertiesIncludeCurrentValue;
    [Test] PROCEDURE Test_SetProperty_WritesNestedClassMemberLinesText;
    [Test] PROCEDURE Test_SetProperty_WritesNestedClassMemberFontSize;
    [Test] PROCEDURE Test_SetProperty_DottedFontWriteFlipsParentFontFalse;
    [Test] PROCEDURE Test_SetProperty_DottedUnknownInnerListsInnerWritables;
    [Test] PROCEDURE Test_SetProperty_DottedOnNonClassOuterReturnsUnsupportedAction;
    [Test] PROCEDURE Test_SetProperty_DottedTwoLevelsReturnsUnsupportedAction;
    [Test] PROCEDURE Test_SetProperty_DottedOnDisabledControlReturnsControlDisabled;
    [Test] PROCEDURE Test_SetProperty_AlphaColorByHexWithAlpha;
    [Test] PROCEDURE Test_SetProperty_AlphaColorByHexShortFormAssumesFullAlpha;
    [Test] PROCEDURE Test_SetProperty_AlphaColorByClaIdentifier;
    [Test] PROCEDURE Test_SetProperty_AlphaColorInvalidValueReturnsUnsupportedAction;
    [Test] PROCEDURE Test_SetProperty_AlphaColorCurrentValueRendersAsHash;
    [Test] PROCEDURE Test_SetProperty_AlphaColorAvailablePropertiesKindIsAlphacolor;
    [Test] PROCEDURE Test_SetProperty_ColorByClIdentifier;
    [Test] PROCEDURE Test_SetProperty_ColorByWebHex;
    [Test] PROCEDURE Test_SetProperty_ColorInvalidValueReturnsUnsupportedAction;
    [Test] PROCEDURE Test_SetProperty_ColorCurrentValueRendersAsName;
    [Test] PROCEDURE Test_SetProperty_ColorAvailablePropertiesKindIsColor;
    // Write-side elision: skip Prop.SetValue when the new value equals the
    // live value, so OnChange doesn't fire spuriously. Response carries
    // 'elided: true|false' to let the AI know whether the setter ran.
    [Test] PROCEDURE Test_SetProperty_ElisionStringEqualReturnsElidedAndSkipsOnChange;
    [Test] PROCEDURE Test_SetProperty_ElisionStringDifferentFiresOnChangeAndReportsElidedFalse;
    [Test] PROCEDURE Test_SetProperty_ElisionIntegerEqualReturnsElided;
    [Test] PROCEDURE Test_SetProperty_ElisionBooleanEqualReturnsElided;
    [Test] PROCEDURE Test_SetProperty_ElisionFloatEqualReturnsElided;
    [Test] PROCEDURE Test_SetProperty_ElisionSetEqualReturnsElided;
    [Test] PROCEDURE Test_SetProperty_ElisionEnumEqualReturnsElided;
    [Test] PROCEDURE Test_SetProperty_ElisionAlphaColorEqualReturnsElided;
    [Test] PROCEDURE Test_SetProperty_ElisionColorEqualReturnsElided;
    [Test] PROCEDURE Test_SetProperty_ElisionDottedFontSizeEqualReturnsElided;
    [Test] PROCEDURE Test_SetProperty_SuccessResponseAlwaysCarriesElidedField;
  END;


IMPLEMENTATION

USES
  Winapi.Windows,
  System.SysUtils, System.Classes, System.SyncObjs, System.JSON,
  System.Generics.Collections, System.UITypes, System.UIConsts,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Graphics,
  DUnitX.Exceptions,
  Autopilot.Bridge.Core, Autopilot.Bridge.Vcl,
  Bridge.TestClient;


TYPE
  // Self-contained enum + set type for the set_property tkSet tests. Lives at unit
  // scope so RTTI emits the type info that StringToSet/SetToString need (sets nested
  // inside a class don't always get TypeInfo emitted).
  TFixtureColor = (fcRed, fcGreen, fcBlue, fcYellow);
  TFixtureColors = SET OF TFixtureColor;

  // A test fixture form with known controls. Built programmatically so DFM-less tests work.
  TFixtureForm = CLASS(TForm)
  PRIVATE
    // Backing fields for set_property tests. Published below as writable
    // properties so RTTI can find them; TForm itself has no convenient writable
    // Float / Set / TStrings.
    FFloatProp: Single;
    FMySetProp: TFixtureColors;
    FMyLines  : TStrings;            // TStringList behind a TStrings published surface.
    FMyAlpha  : TAlphaColor;
    FMyColor  : TColor;
    PROCEDURE SetMyLines(AValue: TStrings);
  PUBLISHED
    PROPERTY FloatProp:  Single         READ FFloatProp WRITE FFloatProp;
    PROPERTY MySetProp:  TFixtureColors READ FMySetProp WRITE FMySetProp;
    // For dotted-propName tests (MyLines.Text via set_property). TStrings is a
    // tkClass property — same RTTI shape as TMemo.Lines, but backed by a plain
    // TStringList so it works without a window handle.
    PROPERTY MyLines:    TStrings       READ FMyLines  WRITE SetMyLines;
    // For TAlphaColor coercion tests. TAlphaColor lives in System.UITypes (RTL,
    // not FMX), so the test target is framework-agnostic — only the RTTI type
    // handle matters. Bridge's TryParseAlphaColor accepts '#RRGGBB' (full
    // alpha), '#AARRGGBB', 'claName', bare names, decimal, or '$hex'.
    PROPERTY MyAlpha:    TAlphaColor    READ FMyAlpha  WRITE FMyAlpha;
    // For TColor coercion tests (VCL only). TColor is BGR-stored, but the bridge
    // accepts 'clName', '#RRGGBB' (web RGB), '$00BBGGRR', or decimal.
    PROPERTY MyColor:    TColor         READ FMyColor  WRITE FMyColor;
  PUBLIC
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
    PROCEDURE BtnClicked(Sender: TObject);
    PROCEDURE BtnSelfDisableClicked(Sender: TObject);
    PROCEDURE BtnSlowClicked(Sender: TObject);
    PROCEDURE LblClicked(Sender: TObject);
    PROCEDURE BtnUnnamedClicked(Sender: TObject);
    PROCEDURE BtnInFrameClicked(Sender: TObject);
    PROCEDURE BtnOnFrameDesignTimeClicked(Sender: TObject);
    PROCEDURE EdtChanged(Sender: TObject);
    CONSTRUCTOR Create(AOwner: TComponent); OVERRIDE;
    DESTRUCTOR Destroy; OVERRIDE;
  END;

CONSTRUCTOR TFixtureForm.Create(AOwner: TComponent);
BEGIN
  inherited CreateNew(AOwner);
  Name             := 'FixtureForm';
  Caption          := 'Fixture';
  Width            := 320;
  Height           := 240;
  Position         := poDesigned;
  // Pin the form's inherited font size to 8 so a child control with
  // ParentFont=TRUE reports Font.Size=8. The host default is Segoe UI 9 on
  // Windows 11 (measured), and Setup's 'Btn.Font.Size:=8' would otherwise be a
  // real 9->8 change that flips Btn.ParentFont to FALSE via TControl.FontChanged,
  // breaking the ParentFont=TRUE baseline of the dotted-Font.* tests.
  Font.Size        := 8;
  ClickCount       := 0;
  SelfDisableCount := 0;
  SlowGate         := TEvent.Create(NIL, TRUE, FALSE, '');
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
  BtnDisabled.Enabled := FALSE;
  BtnDisabled.Parent  := Self;
  BtnDisabled.OnClick := BtnClicked;

  // Self-disabling button: fires SelfDisableCount, then disables itself on the third click.
  // Lets us verify the bridge re-checks Enabled between iterations and stops cleanly.
  BtnSelfDisables := TButton.Create(Self);
  BtnSelfDisables.Name    := 'btnSelfDisables';
  BtnSelfDisables.Caption := 'SelfDisable';
  BtnSelfDisables.Enabled := TRUE;
  BtnSelfDisables.Parent  := Self;
  BtnSelfDisables.OnClick := BtnSelfDisableClicked;

  // Slow button: OnClick sleeps for SlowSleepMs. Lets us trigger the main_thread_blocked
  // path by sending a click with a short timeoutMs.
  BtnSlow := TButton.Create(Self);
  BtnSlow.Name    := 'btnSlow';
  BtnSlow.Caption := 'Slow';
  BtnSlow.Enabled := TRUE;
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
  EdtDisabled.Enabled := FALSE;
  EdtDisabled.Parent  := Self;

  Cbx := TCheckBox.Create(Self);
  Cbx.Name    := 'cbxFlag';
  Cbx.Caption := 'Flag';
  Cbx.Checked := FALSE;
  Cbx.Parent  := Self;

  CbxDisabled := TCheckBox.Create(Self);
  CbxDisabled.Name    := 'cbxDisabled';
  CbxDisabled.Caption := 'Disabled';
  CbxDisabled.Checked := FALSE;
  CbxDisabled.Enabled := FALSE;
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
END;

PROCEDURE TFixtureForm.BtnClicked(Sender: TObject);
BEGIN
  Inc(ClickCount);
END;

PROCEDURE TFixtureForm.BtnSelfDisableClicked(Sender: TObject);
BEGIN
  Inc(SelfDisableCount);
  if SelfDisableCount >= 3 then
    BtnSelfDisables.Enabled := FALSE;
END;

PROCEDURE TFixtureForm.BtnSlowClicked(Sender: TObject);
BEGIN
  Inc(SlowClickCount);
  if SlowSleepMs > 0 then
    // Wait on the gate with a Sleep-equivalent timeout. Test code can
    // unblock us early by signaling SlowGate. Avoids leaving the main
    // thread stuck in Sleep when the test has already moved on.
    SlowGate.WaitFor(SlowSleepMs);
END;


DESTRUCTOR TFixtureForm.Destroy;
BEGIN
  FreeAndNil(SlowGate);
  FreeAndNil(FMyLines);
  inherited;
END;


PROCEDURE TFixtureForm.SetMyLines(AValue: TStrings);
BEGIN
  // Standard TStrings setter pattern — Assign so the inner content is copied
  // into the existing TStringList, never overwriting the field with the
  // caller's instance.
  FMyLines.Assign(AValue);
END;

PROCEDURE TFixtureForm.LblClicked(Sender: TObject);
BEGIN
  Inc(LabelClickCount);
END;


PROCEDURE TFixtureForm.BtnUnnamedClicked(Sender: TObject);
BEGIN
  Inc(BtnUnnamedClicks);
END;


PROCEDURE TFixtureForm.BtnInFrameClicked(Sender: TObject);
BEGIN
  Inc(BtnInFrameClicks);
END;


PROCEDURE TFixtureForm.BtnOnFrameDesignTimeClicked(Sender: TObject);
BEGIN
  Inc(BtnOnFrameDesignTimeClicks);
END;


PROCEDURE TFixtureForm.EdtChanged(Sender: TObject);
BEGIN
  // TEdit.OnChange fires on every real Text assignment. Elision tests assert
  // this counter stays 0 when set_property is called with the current value.
  Inc(EdtChangeCount);
END;


VAR
  GFixtureForm: TFixtureForm = NIL;


{ Helpers --------------------------------------------------------------- }

// Run a closure on a worker thread, while pumping messages on the main thread until
// it finishes. Lets the worker do a synchronous pipe Call(), and lets TThread.Queue
// callbacks fired by the bridge actually run on this (main) thread.
PROCEDURE RunOnWorkerAndPump(AProc: TThreadProcedure; ATimeoutMs: Cardinal);
VAR
  Done    : TEvent;
  WorkerErrMsg: String;
  WorkerErrIsAssertion: Boolean;
  WorkerAssertCount: Integer;
  Deadline: UInt64;
  Msg     : TMsg;
BEGIN
  Done := TEvent.Create(NIL, TRUE, FALSE, '');
  TRY
    WorkerErrMsg := '';
    WorkerErrIsAssertion := FALSE;
    WorkerAssertCount := 0;
    TThread.CreateAnonymousThread(
      PROCEDURE
      BEGIN
        TRY
          AProc();
          // The worker did at least one Assert.* if it got here without throwing.
          // We count it so the parent thread can re-emit it.
          Inc(WorkerAssertCount);
        EXCEPT
          ON E: ETestFailure DO
          BEGIN
            WorkerErrMsg := E.Message;
            WorkerErrIsAssertion := TRUE;
          END;
          ON E: Exception DO
            WorkerErrMsg := E.ClassName + ': ' + E.Message;
        END;
        Done.SetEvent;
      END).Start;

    Deadline := GetTickCount64 + ATimeoutMs;
    WHILE Done.WaitFor(10) <> wrSignaled DO
    BEGIN
      // Drain queued messages so TThread.Queue closures fire on this thread.
      WHILE PeekMessage(Msg, 0, 0, 0, PM_REMOVE) DO
      BEGIN
        TranslateMessage(Msg);
        DispatchMessage(Msg);
      END;
      // Also drain the TThread queue directly — works even without a window message.
      CheckSynchronize;
      if GetTickCount64 > Deadline then
        raise Exception.Create('RunOnWorkerAndPump: worker did not finish in time');
    END;

    // Re-emit the result on this (parent) thread so DUnitX sees the assertion.
    if WorkerErrIsAssertion then
      Assert.IsTrue(FALSE, WorkerErrMsg)
    else if WorkerErrMsg <> '' then
      raise Exception.Create('Worker thread failed: ' + WorkerErrMsg)
    else if WorkerAssertCount > 0 then
      Assert.Pass;  // record success so DUnitX's "no assertions" check is satisfied
  FINALLY
    Done.Free;
  END;
END;


{ TBridgeTests ---------------------------------------------------------- }

VAR
  GPipeNameCounter: Integer = 0;   // monotonic, avoids GetTickCount collisions between fast tests.

PROCEDURE TBridgeTests.EnsureFreshPipeName;
BEGIN
  // Per-test pipe name. Uses a monotonic counter (not GetTickCount, which has 15-16 ms
  // resolution and can collide between Setup calls that fire within the same tick).
  // PID is constant within the run; counter ensures uniqueness across all tests.
  Inc(GPipeNameCounter);
  FPipeName := '\\.\pipe\AutopilotTest.' + IntToStr(GetCurrentProcessId) +
               '.' + IntToStr(GPipeNameCounter);
END;


PROCEDURE TBridgeTests.Setup;
BEGIN
  EnsureFreshPipeName;
  if GFixtureForm = NIL then
    GFixtureForm := TFixtureForm.Create(NIL);   // registers in Screen.Forms[]

  GFixtureForm.ClickCount        := 0;
  GFixtureForm.SelfDisableCount  := 0;
  GFixtureForm.LabelClickCount   := 0;
  GFixtureForm.SlowClickCount    := 0;
  GFixtureForm.BtnUnnamedClicks  := 0;
  GFixtureForm.BtnInFrameClicks  := 0;
  GFixtureForm.BtnOnFrameDesignTimeClicks := 0;
  GFixtureForm.SlowSleepMs       := 0;
  GFixtureForm.SlowGate.ResetEvent;
  GFixtureForm.BtnSelfDisables.Enabled := TRUE;
  GFixtureForm.Lbl.Caption       := 'Initial';
  GFixtureForm.Edt.Text          := 'HelloWorld';
  GFixtureForm.EdtDisabled.Text  := 'frozen';
  GFixtureForm.Cbx.Checked       := FALSE;
  GFixtureForm.CbxDisabled.Checked := FALSE;
  GFixtureForm.FloatProp         := 0.0;
  GFixtureForm.MySetProp         := [];
  GFixtureForm.Tag               := 0;
  GFixtureForm.MyLines.Text      := 'initial line';
  GFixtureForm.Btn.ParentFont    := TRUE;
  GFixtureForm.Btn.Font.Size     := 8;
  GFixtureForm.MyAlpha           := TAlphaColor(0);
  GFixtureForm.MyColor           := TColor(0);
  // Reset the OnChange counter AFTER priming Edt.Text — the assignment above
  // may itself fire OnChange (TEdit.SetText short-circuits on equal value, but
  // we shouldn't depend on that). Reset here so each test starts at 0.
  GFixtureForm.EdtChangeCount    := 0;

  StartBridgeOnPipe(FPipeName);
END;


PROCEDURE TBridgeTests.TearDown;
BEGIN
  StopBridge;
END;


PROCEDURE TBridgeTests.Test_HandshakeSucceeds;
VAR
  PipeName: String;
BEGIN
  PipeName := FPipeName;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR Client: TBridgeTestClient;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000),
                      'expected handshake to succeed');
      FINALLY
        Client.Free;
      END;
    END, 5000);
END;


PROCEDURE TBridgeTests.Test_ListTree_FindsKnownControls;
VAR
  PipeName: String;
  FoundForm, FoundBtn, FoundLbl, FoundEdt: Boolean;
BEGIN
  PipeName := FPipeName;
  FoundForm := FALSE; FoundBtn := FALSE; FoundLbl := FALSE; FoundEdt := FALSE;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Resp, R: TJSONObject;
      Arr: TJSONArray;
      i: Integer;
      Item: TJSONObject;
      Name: TJSONValue;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Resp := Client.Call(1, 'list_tree', NIL);
        TRY
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
              if TJSONString(Name).Value = 'FixtureForm' then FoundForm := TRUE;
              if TJSONString(Name).Value = 'btnTest'     then FoundBtn  := TRUE;
              if TJSONString(Name).Value = 'lblStatus'   then FoundLbl  := TRUE;
              if TJSONString(Name).Value = 'edtName'     then FoundEdt  := TRUE;
            end;
          end;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(FoundForm, 'list_tree should include the form itself as a node');
  Assert.IsTrue(FoundBtn,  'list_tree did not return btnTest');
  Assert.IsTrue(FoundLbl,  'list_tree did not return lblStatus');
  Assert.IsTrue(FoundEdt,  'list_tree did not return edtName');
END;


PROCEDURE TBridgeTests.Test_GetText_OfLabel;
VAR
  PipeName, ReadText: String;
BEGIN
  PipeName := FPipeName;
  ReadText := '';
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp, R: TJSONObject;
      V: TJSONValue;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.lblStatus');
        Resp := Client.Call(2, 'get_text', Args);
        TRY
          R := GetOkResult(Resp);
          Assert.IsNotNull(R, 'get_text should return ok');
          V := R.GetValue('text');
          Assert.IsTrue(V IS TJSONString, 'result.text not a string');
          ReadText := TJSONString(V).Value;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.AreEqual('Initial', ReadText, 'unexpected label text');
END;


PROCEDURE TBridgeTests.Test_Click_FiresOnClick;
VAR
  PipeName: String;
  CountBefore, CountAfter: Integer;
  DispatchedVia: String;
BEGIN
  PipeName := FPipeName;
  CountBefore := GFixtureForm.ClickCount;
  DispatchedVia := '';
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp, R: TJSONObject;
      V: TJSONValue;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnTest');
        Resp := Client.Call(3, 'click', Args);
        TRY
          R := GetOkResult(Resp);
          Assert.IsNotNull(R, 'click should return ok');
          V := R.GetValue('dispatchedVia');
          if V IS TJSONString then
            DispatchedVia := TJSONString(V).Value;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  CountAfter := GFixtureForm.ClickCount;
  Assert.AreEqual(CountBefore + 1, CountAfter, 'OnClick should have fired exactly once');
  Assert.AreEqual('click', DispatchedVia, 'expected dispatchedVia=click for TButton');
END;


PROCEDURE TBridgeTests.Test_Click_DisabledControlReturnsError;
VAR
  PipeName: String;
  Code: Integer;
BEGIN
  PipeName := FPipeName;
  Code := 0;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnDisabled');
        Resp := Client.Call(4, 'click', Args);
        TRY
          Code := GetErrorCode(Resp);
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.AreEqual(ErrControlDisabled, Code, 'expected control_disabled error');
END;


PROCEDURE TBridgeTests.Test_Click_CountFiresNTimes;
CONST
  N = 7;
VAR
  PipeName: String;
  CountBefore, CountAfter, ClicksDispatched: Integer;
  HasStoppedReason: Boolean;
BEGIN
  PipeName := FPipeName;
  CountBefore := GFixtureForm.ClickCount;
  ClicksDispatched := 0;
  HasStoppedReason := FALSE;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp, R: TJSONObject;
      V: TJSONValue;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('count', TJSONNumber.Create(N));
        Resp := Client.Call(10, 'click', Args);
        TRY
          R := GetOkResult(Resp);
          Assert.IsNotNull(R, 'click should return ok');
          V := R.GetValue('clicksDispatched');
          Assert.IsTrue(V IS TJSONNumber, 'result.clicksDispatched missing/not a number');
          ClicksDispatched := TJSONNumber(V).AsInt;
          HasStoppedReason := R.GetValue('stoppedReason') <> NIL;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  CountAfter := GFixtureForm.ClickCount;
  Assert.AreEqual(N, ClicksDispatched, 'clicksDispatched should equal requested count');
  Assert.AreEqual(CountBefore + N, CountAfter, 'OnClick should have fired N times');
  Assert.IsFalse(HasStoppedReason, 'stoppedReason should be absent on full completion');
END;


PROCEDURE TBridgeTests.Test_Click_CountZeroReturnsError;
VAR
  PipeName: String;
  Code: Integer;
BEGIN
  PipeName := FPipeName;
  Code := 0;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('count', TJSONNumber.Create(0));
        Resp := Client.Call(11, 'click', Args);
        TRY
          Code := GetErrorCode(Resp);
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.AreEqual(ErrInvalidRequest, Code, 'expected invalid-request for count=0');
END;


PROCEDURE TBridgeTests.Test_Click_CountAboveCapReturnsError;
VAR
  PipeName: String;
  Code: Integer;
BEGIN
  PipeName := FPipeName;
  Code := 0;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('count', TJSONNumber.Create(1001));
        Resp := Client.Call(12, 'click', Args);
        TRY
          Code := GetErrorCode(Resp);
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.AreEqual(ErrInvalidRequest, Code, 'expected invalid-request for count above cap');
END;


PROCEDURE TBridgeTests.Test_Click_CountStopsWhenDisabledMidLoop;
CONST
  RequestedN = 10;
VAR
  PipeName: String;
  ClicksDispatched: Integer;
  StoppedReason: String;
BEGIN
  PipeName := FPipeName;
  ClicksDispatched := 0;
  StoppedReason := '';
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp, R: TJSONObject;
      V: TJSONValue;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnSelfDisables');
        Args.AddPair('count', TJSONNumber.Create(RequestedN));
        Resp := Client.Call(13, 'click', Args);
        TRY
          R := GetOkResult(Resp);
          Assert.IsNotNull(R, 'click should return ok (partial success)');
          V := R.GetValue('clicksDispatched');
          Assert.IsTrue(V IS TJSONNumber, 'result.clicksDispatched missing/not a number');
          ClicksDispatched := TJSONNumber(V).AsInt;
          V := R.GetValue('stoppedReason');
          if V IS TJSONString then
            StoppedReason := TJSONString(V).Value;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  // Button disables itself on its third click, so loop should run 3 then bail.
  Assert.AreEqual(3, ClicksDispatched, 'expected exactly 3 clicks before button disables itself');
  Assert.AreEqual(3, GFixtureForm.SelfDisableCount, 'OnClick should fire 3 times');
  Assert.AreEqual('disabled', StoppedReason, 'expected stoppedReason=disabled');
END;


PROCEDURE TBridgeTests.Test_Click_CountFiresOnClickPathNTimes;
CONST
  N = 4;
VAR
  PipeName: String;
  CountBefore, CountAfter, ClicksDispatched: Integer;
  DispatchedVia: String;
BEGIN
  PipeName := FPipeName;
  CountBefore := GFixtureForm.LabelClickCount;
  ClicksDispatched := 0;
  DispatchedVia := '';
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp, R: TJSONObject;
      V: TJSONValue;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.lblClickable');
        Args.AddPair('count', TJSONNumber.Create(N));
        Resp := Client.Call(14, 'click', Args);
        TRY
          R := GetOkResult(Resp);
          Assert.IsNotNull(R, 'click should return ok');
          V := R.GetValue('clicksDispatched');
          Assert.IsTrue(V IS TJSONNumber, 'result.clicksDispatched missing/not a number');
          ClicksDispatched := TJSONNumber(V).AsInt;
          V := R.GetValue('dispatchedVia');
          if V IS TJSONString then
            DispatchedVia := TJSONString(V).Value;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  CountAfter := GFixtureForm.LabelClickCount;
  Assert.AreEqual('onclick', DispatchedVia, 'TLabel.OnClick must use the RTTI/OnClick path');
  Assert.AreEqual(N, ClicksDispatched, 'clicksDispatched should equal requested count');
  Assert.AreEqual(CountBefore + N, CountAfter, 'TLabel.OnClick should have fired N times');
END;


PROCEDURE TBridgeTests.Test_Click_MainThreadBlockedReturnsTimeoutError;
CONST
  // Worker timeout is short (200 ms). The OnClick blocks on SlowGate for up to
  // GateMaxWaitMs; the test signals the gate once the worker has returned the
  // timeout error so the queued procedure completes promptly. This avoids the
  // long main-thread Sleep that used to race the RTL @HandleAnyException path.
  WorkerTimeoutMs = 200;
  GateMaxWaitMs   = 2000;
VAR
  PipeName: String;
  Code: Integer;
BEGIN
  PipeName := FPipeName;
  Code := 0;
  GFixtureForm.SlowSleepMs := GateMaxWaitMs;
  GFixtureForm.SlowGate.ResetEvent;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnSlow');
        Resp := Client.Call(20, 'click', Args, WorkerTimeoutMs);
        TRY
          Code := GetErrorCode(Resp);
        FINALLY
          Resp.Free;
        END;
        // We got the timeout response back. The queued procedure is still
        // waiting on SlowGate. Releasing it lets it finish cleanly so the
        // dispatch slot is released on both sides before TearDown fires.
        GFixtureForm.SlowGate.SetEvent;
      FINALLY
        Client.Free;
      END;
    END, GateMaxWaitMs + 3000);
  Assert.AreEqual(ErrMainThreadBlocked, Code, 'expected main_thread_blocked when OnClick exceeds timeoutMs');
  Assert.AreEqual(1, GFixtureForm.SlowClickCount, 'OnClick should still have run on the main thread');
END;


PROCEDURE TBridgeTests.Test_GetText_NotFoundReturnsError;
VAR
  PipeName: String;
  Code: Integer;
BEGIN
  PipeName := FPipeName;
  Code := 0;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.bogusComponent');
        Resp := Client.Call(5, 'get_text', Args);
        TRY
          Code := GetErrorCode(Resp);
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.AreEqual(ErrNotFound, Code, 'expected not_found error');
END;


PROCEDURE TBridgeTests.Test_UnknownCmdReturnsError;
VAR
  PipeName: String;
  Code: Integer;
BEGIN
  PipeName := FPipeName;
  Code := 0;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Resp := Client.Call(6, 'frobnicate', NIL);
        TRY
          Code := GetErrorCode(Resp);
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.AreEqual(ErrUnsupportedAction, Code, 'expected unsupported_action error');
END;


PROCEDURE TBridgeTests.Test_SetText_UpdatesEditValue;
CONST
  NewText = 'rewritten by bridge';
VAR
  PipeName: String;
  Ok: Boolean;
BEGIN
  PipeName := FPipeName;
  Ok := FALSE;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.edtName');
        Args.AddPair('text', NewText);
        Resp := Client.Call(30, 'set_text', Args);
        TRY
          Ok := GetOkResult(Resp) <> NIL;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Ok, 'set_text should return ok');
  Assert.AreEqual(NewText, GFixtureForm.Edt.Text, 'edit Text should be updated');
END;


PROCEDURE TBridgeTests.Test_SetText_DisabledControlReturnsError;
VAR
  PipeName: String;
  Code: Integer;
BEGIN
  PipeName := FPipeName;
  Code := 0;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.edtDisabled');
        Args.AddPair('text', 'should not land');
        Resp := Client.Call(31, 'set_text', Args);
        TRY
          Code := GetErrorCode(Resp);
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.AreEqual(ErrControlDisabled, Code, 'expected control_disabled error');
  Assert.AreEqual('frozen', GFixtureForm.EdtDisabled.Text, 'disabled edit should keep original text');
END;


PROCEDURE TBridgeTests.Test_SetChecked_UpdatesCheckbox;
VAR
  PipeName: String;
  Ok: Boolean;
BEGIN
  PipeName := FPipeName;
  Ok := FALSE;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.cbxFlag');
        Args.AddPair('checked', TJSONBool.Create(TRUE));
        Resp := Client.Call(32, 'set_checked', Args);
        TRY
          Ok := GetOkResult(Resp) <> NIL;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Ok, 'set_checked should return ok');
  Assert.IsTrue(GFixtureForm.Cbx.Checked, 'checkbox should be checked after set_checked');
END;


PROCEDURE TBridgeTests.Test_SetChecked_DisabledControlReturnsError;
VAR
  PipeName: String;
  Code: Integer;
BEGIN
  PipeName := FPipeName;
  Code := 0;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.cbxDisabled');
        Args.AddPair('checked', TJSONBool.Create(TRUE));
        Resp := Client.Call(33, 'set_checked', Args);
        TRY
          Code := GetErrorCode(Resp);
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.AreEqual(ErrControlDisabled, Code, 'expected control_disabled error');
  Assert.IsFalse(GFixtureForm.CbxDisabled.Checked, 'disabled checkbox should not change');
END;


PROCEDURE TBridgeTests.Test_ListTree_SyntheticIdForUnnamedComponent;
VAR
  PipeName, FoundSyntheticName: String;
  FoundSynthetic: Boolean;
BEGIN
  PipeName := FPipeName;
  FoundSynthetic := FALSE;
  FoundSyntheticName := '';
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Resp, R: TJSONObject;
      Arr: TJSONArray;
      i: Integer;
      Item: TJSONObject;
      NameVal, SyntheticVal: TJSONValue;
      NodeName: String;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Resp := Client.Call(40, 'list_tree', NIL);
        TRY
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
                FoundSynthetic := TRUE;
                FoundSyntheticName := NodeName;
                Break;
              end;
            end;
          end;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(FoundSynthetic, 'list_tree should emit a synthetic node for the unnamed button');
  Assert.StartsWith('@TButton#', FoundSyntheticName, 'synthetic name should be @TButton#<index>');
END;


PROCEDURE TBridgeTests.Test_Click_BySyntheticIdFiresOnClick;
VAR
  PipeName, SyntheticPath: String;
  ClicksBefore, ClicksAfter: Integer;
  DispatchedVia: String;
BEGIN
  PipeName := FPipeName;
  // Build the synthetic path the same way the bridge does — anchored on the unnamed
  // button's actual ComponentIndex so the test stays correct if the fixture grows.
  SyntheticPath := 'FixtureForm.@TButton#' + IntToStr(GFixtureForm.BtnUnnamed.ComponentIndex);
  ClicksBefore := GFixtureForm.BtnUnnamedClicks;
  DispatchedVia := '';
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp, R: TJSONObject;
      V: TJSONValue;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', SyntheticPath);
        Resp := Client.Call(41, 'click', Args);
        TRY
          R := GetOkResult(Resp);
          Assert.IsNotNull(R, 'click should return ok via synthetic path');
          V := R.GetValue('dispatchedVia');
          if V IS TJSONString then
            DispatchedVia := TJSONString(V).Value;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  ClicksAfter := GFixtureForm.BtnUnnamedClicks;
  Assert.AreEqual(ClicksBefore + 1, ClicksAfter, 'OnClick should have fired exactly once via synthetic path');
  Assert.AreEqual('click', DispatchedVia, 'expected dispatchedVia=click for TButton via synthetic path');
END;


PROCEDURE TBridgeTests.Test_ListTree_RecursesIntoFrames;
VAR
  PipeName: String;
  FoundFrame, FoundInner: Boolean;
  InnerPath: String;
BEGIN
  PipeName := FPipeName;
  FoundFrame := FALSE;
  FoundInner := FALSE;
  InnerPath := '';
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Resp, R: TJSONObject;
      Arr: TJSONArray;
      i: Integer;
      Item: TJSONObject;
      NameVal, PathVal: TJSONValue;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Resp := Client.Call(50, 'list_tree', NIL);
        TRY
          R := GetOkResult(Resp);
          Assert.IsNotNull(R, 'list_tree should return ok');
          Arr := R.GetValue('components') AS TJSONArray;
          Assert.IsNotNull(Arr, 'result.components missing');
          for i := 0 to Arr.Count - 1 do
          begin
            Item := Arr.Items[i] AS TJSONObject;
            NameVal := Item.GetValue('name');
            if not (NameVal IS TJSONString) then Continue;
            if TJSONString(NameVal).Value = 'frmInner'   then FoundFrame := TRUE;
            if TJSONString(NameVal).Value = 'btnInFrame' then
            begin
              FoundInner := TRUE;
              PathVal := Item.GetValue('path');
              if PathVal IS TJSONString then
                InnerPath := TJSONString(PathVal).Value;
            end;
          end;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(FoundFrame, 'list_tree should include the frame');
  Assert.IsTrue(FoundInner, 'list_tree should recurse into the frame and include its child button');
  Assert.AreEqual('FixtureForm.frmInner.btnInFrame', InnerPath,
                  'frame-child path should be Form.Frame.Child (anchored)');
END;


PROCEDURE TBridgeTests.Test_Click_FrameChildByFlatPathFiresOnClick;
VAR
  PipeName: String;
  ClicksBefore, ClicksAfter: Integer;
BEGIN
  PipeName := FPipeName;
  ClicksBefore := GFixtureForm.BtnInFrameClicks;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        // Flat 2-part path: recursive search should find the button inside the frame.
        Args.AddPair('path', 'FixtureForm.btnInFrame');
        Resp := Client.Call(51, 'click', Args);
        TRY
          Assert.IsNotNull(GetOkResult(Resp), 'click via flat path should return ok');
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  ClicksAfter := GFixtureForm.BtnInFrameClicks;
  Assert.AreEqual(ClicksBefore + 1, ClicksAfter, 'flat-path click should reach the frame child');
END;


PROCEDURE TBridgeTests.Test_Click_FrameChildByAnchoredPathFiresOnClick;
VAR
  PipeName: String;
  ClicksBefore, ClicksAfter: Integer;
BEGIN
  PipeName := FPipeName;
  ClicksBefore := GFixtureForm.BtnInFrameClicks;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        // Anchored 3-part path: each segment is a direct child of the previous.
        Args.AddPair('path', 'FixtureForm.frmInner.btnInFrame');
        Resp := Client.Call(52, 'click', Args);
        TRY
          Assert.IsNotNull(GetOkResult(Resp), 'click via anchored path should return ok');
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  ClicksAfter := GFixtureForm.BtnInFrameClicks;
  Assert.AreEqual(ClicksBefore + 1, ClicksAfter, 'anchored-path click should reach the frame child');
END;


PROCEDURE TBridgeTests.Test_Click_DesignTimeStyleFrameChildFiresOnClick;
VAR
  PipeName: String;
  ClicksBefore, ClicksAfter: Integer;
BEGIN
  PipeName := FPipeName;
  ClicksBefore := GFixtureForm.BtnOnFrameDesignTimeClicks;
  // BtnOnFrameDesignTime is owned by the form (not by the frame). This mirrors
  // DFM-loaded frames: TReader.ReadDataInner sets each child's Owner to Root
  // (the form), regardless of visual parenting. The flat 2-part path must still
  // find it — it lives directly in Form.Components[].
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnOnFrameDT');
        Resp := Client.Call(60, 'click', Args);
        TRY
          Assert.IsNotNull(GetOkResult(Resp), 'click should return ok');
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  ClicksAfter := GFixtureForm.BtnOnFrameDesignTimeClicks;
  Assert.AreEqual(ClicksBefore + 1, ClicksAfter,
                  'design-time-style frame child (Owner=Form, Parent=Frame) should be clickable via flat path');
END;


PROCEDURE TBridgeTests.Test_FindByPath_FormItselfByOneSegmentPath;
VAR
  PipeName, ReadText: String;
BEGIN
  PipeName := FPipeName;
  ReadText := '';
  // Round-trip check: list_tree emits the form node with path='FixtureForm'.
  // get_text against that same path must resolve back to the form itself and
  // read its Caption.
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp, R: TJSONObject;
      V: TJSONValue;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Resp := Client.Call(61, 'get_text', Args);
        TRY
          R := GetOkResult(Resp);
          Assert.IsNotNull(R, 'get_text on form path should return ok');
          V := R.GetValue('text');
          Assert.IsTrue(V IS TJSONString, 'result.text should be a string');
          ReadText := TJSONString(V).Value;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.AreEqual('Fixture', ReadText, 'one-segment path should resolve to the form itself');
END;


PROCEDURE TBridgeTests.Test_SetProperty_WritesString;
VAR
  PipeName: String;
  Ok: Boolean;
BEGIN
  PipeName := FPipeName;
  Ok := FALSE;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('propName', 'Caption');
        Args.AddPair('value', 'set by set_property');
        Resp := Client.Call(70, 'set_property', Args);
        TRY
          Ok := GetOkResult(Resp) <> NIL;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok for a writable string property');
  Assert.AreEqual('set by set_property', GFixtureForm.Btn.Caption, 'Caption should be updated');
END;


PROCEDURE TBridgeTests.Test_SetProperty_WritesInteger;
VAR
  PipeName: String;
  Ok: Boolean;
BEGIN
  PipeName := FPipeName;
  Ok := FALSE;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('propName', 'Tag');
        Args.AddPair('value', '42');
        Resp := Client.Call(71, 'set_property', Args);
        TRY
          Ok := GetOkResult(Resp) <> NIL;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok for a writable integer property');
  Assert.AreEqual(NativeInt(42), GFixtureForm.Btn.Tag, 'Tag should be 42');
END;


PROCEDURE TBridgeTests.Test_SetProperty_WritesBoolean;
VAR
  PipeName: String;
  Ok: Boolean;
BEGIN
  PipeName := FPipeName;
  Ok := FALSE;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.cbxFlag');
        Args.AddPair('propName', 'Checked');
        Args.AddPair('value', 'true');
        Resp := Client.Call(72, 'set_property', Args);
        TRY
          Ok := GetOkResult(Resp) <> NIL;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok for a writable boolean property');
  Assert.IsTrue(GFixtureForm.Cbx.Checked, 'cbxFlag.Checked should be TRUE');
END;


PROCEDURE TBridgeTests.Test_SetProperty_WritesEnumByIdentifier;
VAR
  PipeName: String;
  Ok: Boolean;
BEGIN
  PipeName := FPipeName;
  Ok := FALSE;
  // TForm.Position is TPosition (enum). poDesigned = 0, poDefault = 1, etc.
  // Default in fixture form Setup is poDesigned. Switch it to poDefaultSizeOnly.
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'Position');
        Args.AddPair('value', 'poDefaultSizeOnly');
        Resp := Client.Call(73, 'set_property', Args);
        TRY
          Ok := GetOkResult(Resp) <> NIL;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Ok, 'set_property should accept enum identifier');
  Assert.AreEqual(Ord(poDefaultSizeOnly), Ord(GFixtureForm.Position), 'Position should change to poDefaultSizeOnly');
END;


PROCEDURE TBridgeTests.Test_SetProperty_WritesFloat;
VAR
  PipeName: String;
  Ok: Boolean;
BEGIN
  PipeName := FPipeName;
  Ok := FALSE;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'FloatProp');
        Args.AddPair('value', '3.14');
        Resp := Client.Call(74, 'set_property', Args);
        TRY
          Ok := GetOkResult(Resp) <> NIL;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok for a writable float property');
  Assert.AreEqual(Single(3.14), GFixtureForm.FloatProp, 0.001, 'FloatProp should be 3.14');
END;


PROCEDURE TBridgeTests.Test_SetProperty_UnknownPropertyReturnsListOfWritables;
VAR
  PipeName: String;
  Code: Integer;
  HasCaption, HasTag: Boolean;
BEGIN
  PipeName := FPipeName;
  Code := 0;
  HasCaption := FALSE;
  HasTag := FALSE;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
      Data, Item: TJSONObject;
      Arr: TJSONArray;
      i: Integer;
      V: TJSONValue;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('propName', 'NoSuchProperty');
        Args.AddPair('value', 'whatever');
        Resp := Client.Call(75, 'set_property', Args);
        TRY
          Code := GetErrorCode(Resp);
          Data := GetErrorData(Resp);
          if Data <> NIL then
          begin
            Arr := Data.GetValue('availableProperties') AS TJSONArray;
            if Arr <> NIL then
              for i := 0 to Arr.Count - 1 do
              begin
                Item := Arr.Items[i] AS TJSONObject;
                V := Item.GetValue('name');
                if V IS TJSONString then
                begin
                  if TJSONString(V).Value = 'Caption' then HasCaption := TRUE;
                  if TJSONString(V).Value = 'Tag'     then HasTag     := TRUE;
                end;
              end;
          end;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.AreEqual(ErrRttiPropertyMissing, Code, 'expected rtti_property_missing');
  Assert.IsTrue(HasCaption, 'availableProperties should list Caption');
  Assert.IsTrue(HasTag,     'availableProperties should list Tag');
END;


PROCEDURE TBridgeTests.Test_SetProperty_TypeMismatchReturnsUnsupportedAction;
VAR
  PipeName: String;
  Code: Integer;
BEGIN
  PipeName := FPipeName;
  Code := 0;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('propName', 'Tag');
        Args.AddPair('value', 'not a number');
        Resp := Client.Call(76, 'set_property', Args);
        TRY
          Code := GetErrorCode(Resp);
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.AreEqual(ErrUnsupportedAction, Code,
                  'non-numeric value for integer property should return unsupported_action');
  Assert.AreEqual(NativeInt(0), GFixtureForm.Btn.Tag, 'Tag should remain at its default 0');
END;


PROCEDURE TBridgeTests.Test_SetProperty_DisabledControlReturnsError;
VAR
  PipeName: String;
  Code: Integer;
BEGIN
  PipeName := FPipeName;
  Code := 0;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnDisabled');
        Args.AddPair('propName', 'Caption');
        Args.AddPair('value', 'should not land');
        Resp := Client.Call(77, 'set_property', Args);
        TRY
          Code := GetErrorCode(Resp);
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.AreEqual(ErrControlDisabled, Code, 'expected control_disabled error');
  Assert.AreEqual('Disabled', GFixtureForm.BtnDisabled.Caption, 'disabled button caption should be unchanged');
END;


PROCEDURE TBridgeTests.Test_SetProperty_WritesSetByBracketLiteral;
VAR
  PipeName: String;
  Ok: Boolean;
BEGIN
  PipeName := FPipeName;
  Ok := FALSE;
  GFixtureForm.MySetProp := [];
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp, R: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MySetProp');
        Args.AddPair('value', '[fcRed,fcBlue]');
        Resp := Client.Call(78, 'set_property', Args);
        TRY
          R := GetOkResult(Resp);
          Ok := R <> NIL;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok for a set literal');
  Assert.IsTrue(fcRed  in GFixtureForm.MySetProp, 'fcRed should be set');
  Assert.IsTrue(fcBlue in GFixtureForm.MySetProp, 'fcBlue should be set');
  Assert.IsFalse(fcGreen in GFixtureForm.MySetProp, 'fcGreen should NOT be set');
END;


PROCEDURE TBridgeTests.Test_SetProperty_WritesSetByBareIdentifierList;
VAR
  PipeName: String;
  Ok: Boolean;
BEGIN
  PipeName := FPipeName;
  Ok := FALSE;
  GFixtureForm.MySetProp := [];
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp, R: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MySetProp');
        Args.AddPair('value', 'fcGreen,fcYellow');
        Resp := Client.Call(79, 'set_property', Args);
        TRY
          R := GetOkResult(Resp);
          Ok := R <> NIL;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Ok, 'set_property should accept a bare comma list (no brackets)');
  Assert.IsTrue(fcGreen  in GFixtureForm.MySetProp, 'fcGreen should be set');
  Assert.IsTrue(fcYellow in GFixtureForm.MySetProp, 'fcYellow should be set');
  Assert.IsFalse(fcRed   in GFixtureForm.MySetProp, 'fcRed should NOT be set');
END;


PROCEDURE TBridgeTests.Test_SetProperty_WritesEmptySet;
VAR
  PipeName: String;
  Ok: Boolean;
BEGIN
  PipeName := FPipeName;
  Ok := FALSE;
  GFixtureForm.MySetProp := [fcRed, fcGreen];
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp, R: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MySetProp');
        Args.AddPair('value', '[]');
        Resp := Client.Call(80, 'set_property', Args);
        TRY
          R := GetOkResult(Resp);
          Ok := R <> NIL;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Ok, 'set_property should accept the empty-set literal "[]"');
  Assert.IsTrue(GFixtureForm.MySetProp = [], 'MySetProp should now be empty');
END;


PROCEDURE TBridgeTests.Test_SetProperty_InvalidSetIdentifierReturnsUnsupportedAction;
VAR
  PipeName: String;
  Code: Integer;
BEGIN
  PipeName := FPipeName;
  Code := 0;
  GFixtureForm.MySetProp := [fcRed];
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MySetProp');
        Args.AddPair('value', '[fcPuce]');     // not a member of TFixtureColor
        Resp := Client.Call(81, 'set_property', Args);
        TRY
          Code := GetErrorCode(Resp);
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.AreEqual(ErrUnsupportedAction, Code,
                  'invalid set identifier should return unsupported_action');
  Assert.IsTrue(GFixtureForm.MySetProp = [fcRed],
                'MySetProp should be untouched after a bad set value');
END;


PROCEDURE TBridgeTests.Test_SetProperty_AvailablePropertiesIncludeCurrentValue;
VAR
  PipeName: String;
  CaptionCurrent, TagCurrent, FloatCurrent: String;
  HasCaptionCurrent, HasTagCurrent, HasFloatCurrent: Boolean;
BEGIN
  PipeName := FPipeName;
  HasCaptionCurrent := FALSE;
  HasTagCurrent := FALSE;
  HasFloatCurrent := FALSE;
  CaptionCurrent := '';
  TagCurrent := '';
  FloatCurrent := '';
  // Set known, distinctive values so we can spot them in the response.
  GFixtureForm.Btn.Caption := 'CurrentCaption42';
  GFixtureForm.Btn.Tag     := 7;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
      Data, Item: TJSONObject;
      Arr: TJSONArray;
      i: Integer;
      NameV, CurV: TJSONValue;
      PName: String;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('propName', 'NoSuchProperty');
        Args.AddPair('value', '');
        Resp := Client.Call(82, 'set_property', Args);
        TRY
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
            if PName = 'Caption' then begin HasCaptionCurrent := TRUE; CaptionCurrent := TJSONString(CurV).Value; end;
            if PName = 'Tag'     then begin HasTagCurrent     := TRUE; TagCurrent     := TJSONString(CurV).Value; end;
            if PName = 'Enabled' then begin {smoke-check boolean kind is read} end;
            if PName = 'Width'   then begin {smoke-check integer kind is read} end;
            // FloatProp is on TFixtureForm, not on Btn — won't show here. We check it
            // via a second test below. Keep this fixture path focused on the button's
            // own published properties.
            // Mark FloatCurrent as observed if it does appear on Btn (it doesn't, but
            // referencing the variable keeps it from being dead-stripped to a warning).
            if PName = 'FloatProp' then begin HasFloatCurrent := TRUE; FloatCurrent := TJSONString(CurV).Value; end;
          end;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(HasCaptionCurrent, 'expected Caption.currentValue in availableProperties');
  Assert.AreEqual('CurrentCaption42', CaptionCurrent,
                  'Caption.currentValue should reflect the live caption');
  Assert.IsTrue(HasTagCurrent, 'expected Tag.currentValue in availableProperties');
  Assert.AreEqual('7', TagCurrent, 'Tag.currentValue should be "7"');
  // Touch the float variables so the compiler doesn't flag them as unused-but-assigned.
  if HasFloatCurrent then Assert.IsNotEmpty(FloatCurrent);
END;


// Headline tkClass test: write TStrings.Text via dotted propName. The fixture
// form exposes MyLines: TStrings (backed by a TStringList) — same RTTI shape
// as TMemo.Lines without needing a window handle. The bridge resolves the
// outer MyLines getter, then recurses onto the TStrings instance to set Text.
PROCEDURE TBridgeTests.Test_SetProperty_WritesNestedClassMemberLinesText;
VAR
  PipeName: String;
  Ok: Boolean;
BEGIN
  PipeName := FPipeName;
  Ok := FALSE;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MyLines.Text');
        Args.AddPair('value', 'line one'#13#10'line two');
        Resp := Client.Call(83, 'set_property', Args);
        TRY
          Ok := GetOkResult(Resp) <> NIL;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok for a dotted tkClass.tkString path');
  // TStrings.Text round-trips with a trailing CRLF on get; compare lines content
  // via Trim so we don't depend on that surface detail.
  Assert.AreEqual('line one'#13#10'line two',
                  Trim(GFixtureForm.MyLines.Text),
                  'MyLines.Text should reflect the two-line value');
END;


// Second tkClass test: Font.Size on a TButton. Font is published on every
// TControl as a tkClass property; TFont.Size is a writable Integer. Verifies
// the dotted path works for tkClass.tkInteger too.
PROCEDURE TBridgeTests.Test_SetProperty_WritesNestedClassMemberFontSize;
VAR
  PipeName: String;
  Ok: Boolean;
BEGIN
  PipeName := FPipeName;
  Ok := FALSE;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('propName', 'Font.Size');
        Args.AddPair('value', '18');
        Resp := Client.Call(84, 'set_property', Args);
        TRY
          Ok := GetOkResult(Resp) <> NIL;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok for a dotted tkClass.tkInteger path');
  Assert.AreEqual(18, GFixtureForm.Btn.Font.Size, 'btnTest.Font.Size should be 18');
END;


// 2026-05-20: bridge now turns ParentFont off before a dotted Font.* write.
// The VCL does the same flip itself as a side effect of TControl.FontChanged,
// so the post-write end state was always Font.Size=N and ParentFont=FALSE
// even without the bridge's help. The bridge pre-flip matters in the elision
// path (no actual SetValue → no FontChanged → no VCL auto-flip), and pins
// the contract: after any set_property Font.* call, ParentFont is FALSE.
// Verify both legs: the size landed AND ParentFont is now FALSE.
PROCEDURE TBridgeTests.Test_SetProperty_DottedFontWriteFlipsParentFontFalse;
VAR
  PipeName: String;
  Ok: Boolean;
BEGIN
  // Per-test SetUp resets ParentFont:=TRUE and Font.Size:=8. Confirm baseline
  // before the bridge call so a failure here points at the test setup, not at
  // the bridge.
  Assert.IsTrue(GFixtureForm.Btn.ParentFont,
                'precondition: Btn.ParentFont must be TRUE for this test');
  Assert.AreEqual(8, GFixtureForm.Btn.Font.Size,
                  'precondition: Btn.Font.Size must be 8 for this test');

  PipeName := FPipeName;
  Ok := FALSE;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('propName', 'Font.Size');
        Args.AddPair('value', '20');
        Resp := Client.Call(184, 'set_property', Args);
        TRY
          Ok := GetOkResult(Resp) <> NIL;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Ok, 'set_property Font.Size=20 should succeed');
  Assert.AreEqual(20, GFixtureForm.Btn.Font.Size,
                  'Btn.Font.Size should be 20 after the bridge write');
  Assert.IsFalse(GFixtureForm.Btn.ParentFont,
                 'bridge should have auto-flipped Btn.ParentFont to FALSE so the size sticks');
END;


// When the outer is tkClass but the inner name is wrong, availableProperties
// should enumerate the INNER class's writable surface (TFont in this case),
// not the outer component's. Verifies HandleSetProperty uses AFailedInstance.
PROCEDURE TBridgeTests.Test_SetProperty_DottedUnknownInnerListsInnerWritables;
VAR
  PipeName: String;
  Code: Integer;
  HasFontSize, HasFontColor, HasFontName, HasButtonCaption: Boolean;
BEGIN
  PipeName := FPipeName;
  Code := 0;
  HasFontSize := FALSE;
  HasFontColor := FALSE;
  HasFontName := FALSE;
  HasButtonCaption := FALSE;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
      Data, Item: TJSONObject;
      Arr: TJSONArray;
      i: Integer;
      V: TJSONValue;
      PName: String;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('propName', 'Font.NoSuchInner');
        Args.AddPair('value', 'whatever');
        Resp := Client.Call(85, 'set_property', Args);
        TRY
          Code := GetErrorCode(Resp);
          Data := GetErrorData(Resp);
          if Data <> NIL then
          begin
            Arr := Data.GetValue('availableProperties') AS TJSONArray;
            if Arr <> NIL then
              for i := 0 to Arr.Count - 1 do
              begin
                Item := Arr.Items[i] AS TJSONObject;
                V := Item.GetValue('name');
                if V IS TJSONString then
                begin
                  PName := TJSONString(V).Value;
                  if PName = 'Size'    then HasFontSize  := TRUE;
                  if PName = 'Color'   then HasFontColor := TRUE;
                  if PName = 'Name'    then HasFontName  := TRUE;
                  if PName = 'Caption' then HasButtonCaption := TRUE;
                end;
              end;
          end;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.AreEqual(ErrRttiPropertyMissing, Code, 'expected rtti_property_missing');
  Assert.IsTrue(HasFontSize,  'availableProperties should list TFont.Size when inner name was bogus');
  Assert.IsTrue(HasFontColor, 'availableProperties should list TFont.Color');
  Assert.IsTrue(HasFontName,  'availableProperties should list TFont.Name');
  Assert.IsFalse(HasButtonCaption,
                 'availableProperties should NOT include TButton.Caption — we asked about Font, not the button');
END;


// Dotted propName where the outer is not tkClass (e.g. 'Caption.Length' on a
// button) should return unsupported_action — TCaption is a String, not a class.
PROCEDURE TBridgeTests.Test_SetProperty_DottedOnNonClassOuterReturnsUnsupportedAction;
VAR
  PipeName: String;
  Code: Integer;
BEGIN
  PipeName := FPipeName;
  Code := 0;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('propName', 'Caption.Length');
        Args.AddPair('value', '5');
        Resp := Client.Call(86, 'set_property', Args);
        TRY
          Code := GetErrorCode(Resp);
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.AreEqual(ErrUnsupportedAction, Code,
                  'dotted propName on non-class outer should return unsupported_action');
END;


// Pin the disabled-control gate's interaction with dotted propName. The check
// sits on the OUTER component (TButton), not the inner TPersistent. So
// 'btnDisabled.Font.Size := 14' returns control_disabled and the inner value
// stays at its pre-call setting — even though TFont itself has no Enabled.
// This locks the contract; a future change that decides nested writes should
// bypass the gate must update this test deliberately.
PROCEDURE TBridgeTests.Test_SetProperty_DottedOnDisabledControlReturnsControlDisabled;
VAR
  PipeName: String;
  Code: Integer;
  SizeBefore, SizeAfter: Integer;
BEGIN
  PipeName := FPipeName;
  Code := 0;
  GFixtureForm.BtnDisabled.Font.Size := 9;
  SizeBefore := GFixtureForm.BtnDisabled.Font.Size;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnDisabled');
        Args.AddPair('propName', 'Font.Size');
        Args.AddPair('value', '14');
        Resp := Client.Call(88, 'set_property', Args);
        TRY
          Code := GetErrorCode(Resp);
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  SizeAfter := GFixtureForm.BtnDisabled.Font.Size;
  Assert.AreEqual(ErrControlDisabled, Code,
                  'dotted write on disabled control should return control_disabled');
  Assert.AreEqual(SizeBefore, SizeAfter,
                  'Font.Size on disabled control should NOT change');
END;


// Two levels of nesting ('Font.Color.Red') is intentionally not supported.
// The error should be unsupported_action, not a silent walk into arbitrarily
// deep structure.
PROCEDURE TBridgeTests.Test_SetProperty_DottedTwoLevelsReturnsUnsupportedAction;
VAR
  PipeName: String;
  Code: Integer;
BEGIN
  PipeName := FPipeName;
  Code := 0;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('propName', 'Font.A.B');
        Args.AddPair('value', '1');
        Resp := Client.Call(87, 'set_property', Args);
        TRY
          Code := GetErrorCode(Resp);
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.AreEqual(ErrUnsupportedAction, Code,
                  'two-level dotted propName should be rejected with unsupported_action');
END;


// 8-digit ARGB hex: alpha + RGB explicit. Verifies the bridge writes the
// exact 32-bit value, not a coerced/truncated variant.
PROCEDURE TBridgeTests.Test_SetProperty_AlphaColorByHexWithAlpha;
VAR
  PipeName: String;
  Ok: Boolean;
BEGIN
  PipeName := FPipeName;
  Ok := FALSE;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MyAlpha');
        Args.AddPair('value', '#80FF8000');     // 50% alpha, full red, half green, no blue
        Resp := Client.Call(89, 'set_property', Args);
        TRY
          Ok := GetOkResult(Resp) <> NIL;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok for an 8-digit ARGB hex');
  Assert.AreEqual(Cardinal($80FF8000), Cardinal(GFixtureForm.MyAlpha),
                  'MyAlpha should be exactly $80FF8000');
END;


// 6-digit RGB short form: alpha is implicit FF. Without this convenience the
// AI would have to remember to prepend FF to every web-style color literal.
PROCEDURE TBridgeTests.Test_SetProperty_AlphaColorByHexShortFormAssumesFullAlpha;
VAR
  PipeName: String;
  Ok: Boolean;
BEGIN
  PipeName := FPipeName;
  Ok := FALSE;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MyAlpha');
        Args.AddPair('value', '#FF8000');       // 6 digits — alpha assumed FF
        Resp := Client.Call(90, 'set_property', Args);
        TRY
          Ok := GetOkResult(Resp) <> NIL;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok for a 6-digit RGB hex');
  Assert.AreEqual(Cardinal($FFFF8000), Cardinal(GFixtureForm.MyAlpha),
                  'MyAlpha should be $FFFF8000 (alpha defaulted to FF)');
END;


// 'claSkyBlue' identifier — resolved via System.UIConsts. Confirms the named
// path through StringToAlphaColor works end-to-end.
PROCEDURE TBridgeTests.Test_SetProperty_AlphaColorByClaIdentifier;
VAR
  PipeName: String;
  Ok: Boolean;
BEGIN
  PipeName := FPipeName;
  Ok := FALSE;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MyAlpha');
        Args.AddPair('value', 'claSkyBlue');
        Resp := Client.Call(91, 'set_property', Args);
        TRY
          Ok := GetOkResult(Resp) <> NIL;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok for "claSkyBlue"');
  Assert.AreEqual(Cardinal(claSkyBlue), Cardinal(GFixtureForm.MyAlpha),
                  'MyAlpha should match claSkyBlue');
END;


// Garbage input — not a hex literal, not a cla* identifier, not a number.
// Must return unsupported_action with the property unchanged.
PROCEDURE TBridgeTests.Test_SetProperty_AlphaColorInvalidValueReturnsUnsupportedAction;
VAR
  PipeName: String;
  Code: Integer;
  AlphaBefore: TAlphaColor;
BEGIN
  PipeName := FPipeName;
  Code := 0;
  GFixtureForm.MyAlpha := TAlphaColor($DEADBEEF);
  AlphaBefore := GFixtureForm.MyAlpha;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MyAlpha');
        Args.AddPair('value', 'notacolor');
        Resp := Client.Call(92, 'set_property', Args);
        TRY
          Code := GetErrorCode(Resp);
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.AreEqual(ErrUnsupportedAction, Code,
                  'garbage TAlphaColor input should return unsupported_action');
  Assert.AreEqual(Cardinal(AlphaBefore), Cardinal(GFixtureForm.MyAlpha),
                  'MyAlpha should be unchanged on failed parse');
END;


// Readback formatting: availableProperties.currentValue for a TAlphaColor
// property must render as 'claName' (when named) or '#AARRGGBB' (otherwise),
// not as a decimal — so the AI can paste it straight back into set_property.
PROCEDURE TBridgeTests.Test_SetProperty_AlphaColorCurrentValueRendersAsHash;
VAR
  PipeName: String;
  CurStr: String;
  HasMyAlpha: Boolean;
BEGIN
  PipeName := FPipeName;
  HasMyAlpha := FALSE;
  CurStr := '';
  GFixtureForm.MyAlpha := TAlphaColor($80FF8000);
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
      Data, Item: TJSONObject;
      Arr: TJSONArray;
      i: Integer;
      NameV, CurV: TJSONValue;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'NoSuchProperty');
        Args.AddPair('value', '');
        Resp := Client.Call(93, 'set_property', Args);
        TRY
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
              HasMyAlpha := TRUE;
              CurStr := TJSONString(CurV).Value;
            end;
            Break;
          end;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(HasMyAlpha, 'expected MyAlpha.currentValue in availableProperties');
  // $80FF8000 isn't a known cla* constant; expect '#80FF8000' (or 'x80FF8000'
  // depending on Delphi version — accept either lowercase first char).
  Assert.IsTrue((CurStr = '#80FF8000') or (CurStr = 'x80FF8000'),
                'MyAlpha currentValue should be hex-shaped, got "' + CurStr + '"');
END;


// availableProperties kind annotation: TAlphaColor entries should report
// kind:'alphacolor' rather than 'integer', so the AI knows to send hex/named
// values without first failing on a raw integer attempt.
PROCEDURE TBridgeTests.Test_SetProperty_AlphaColorAvailablePropertiesKindIsAlphacolor;
VAR
  PipeName: String;
  Kind: String;
  Found: Boolean;
BEGIN
  PipeName := FPipeName;
  Found := FALSE;
  Kind := '';
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
      Data, Item: TJSONObject;
      Arr: TJSONArray;
      i: Integer;
      NameV, KindV: TJSONValue;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'NoSuchProperty');
        Args.AddPair('value', '');
        Resp := Client.Call(94, 'set_property', Args);
        TRY
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
              Found := TRUE;
              Kind := TJSONString(KindV).Value;
            end;
            Break;
          end;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Found, 'expected MyAlpha entry in availableProperties');
  Assert.AreEqual('alphacolor', Kind, 'TAlphaColor entries should be labelled kind:"alphacolor"');
END;


// 'clRed' identifier — resolved via System.UIConsts IdentToColor. Confirms
// the named-color path works end-to-end via the bridge's TryStringToColorCompat.
PROCEDURE TBridgeTests.Test_SetProperty_ColorByClIdentifier;
VAR
  PipeName: String;
  Ok: Boolean;
BEGIN
  PipeName := FPipeName;
  Ok := FALSE;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MyColor');
        Args.AddPair('value', 'clRed');
        Resp := Client.Call(95, 'set_property', Args);
        TRY
          Ok := GetOkResult(Resp) <> NIL;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok for "clRed"');
  Assert.AreEqual(Integer(clRed), Integer(GFixtureForm.MyColor),
                  'MyColor should match clRed');
END;


// '#FF0080' — web-style RGB hex. The byte order TryStringToColorCompat uses
// produces the BGR-stored TColor the AI would expect from a web color literal.
PROCEDURE TBridgeTests.Test_SetProperty_ColorByWebHex;
VAR
  PipeName: String;
  Ok: Boolean;
BEGIN
  PipeName := FPipeName;
  Ok := FALSE;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MyColor');
        Args.AddPair('value', '#FF0080');     // R=FF, G=00, B=80
        Resp := Client.Call(96, 'set_property', Args);
        TRY
          Ok := GetOkResult(Resp) <> NIL;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok for "#FF0080"');
  // TColor stores BGR in the low 3 bytes: B=80, G=00, R=FF → $008000FF.
  Assert.AreEqual(Integer($008000FF), Integer(GFixtureForm.MyColor),
                  'MyColor should be $008000FF (web RGB #FF0080 in BGR storage)');
END;


// Garbage input — not a cl* identifier, not a hex literal, not a number.
// Must return unsupported_action with the property unchanged.
PROCEDURE TBridgeTests.Test_SetProperty_ColorInvalidValueReturnsUnsupportedAction;
VAR
  PipeName: String;
  Code: Integer;
  ColorBefore: TColor;
BEGIN
  PipeName := FPipeName;
  Code := 0;
  GFixtureForm.MyColor := TColor($00BEEF42);
  ColorBefore := GFixtureForm.MyColor;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MyColor');
        Args.AddPair('value', 'notacolor');
        Resp := Client.Call(97, 'set_property', Args);
        TRY
          Code := GetErrorCode(Resp);
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.AreEqual(ErrUnsupportedAction, Code,
                  'garbage TColor input should return unsupported_action');
  Assert.AreEqual(Integer(ColorBefore), Integer(GFixtureForm.MyColor),
                  'MyColor should be unchanged on failed parse');
END;


// Readback formatting: availableProperties.currentValue for a TColor property
// must render as 'clName' (when the integer maps to a known identifier) so the
// AI can paste it straight back into set_property without a hex round-trip.
PROCEDURE TBridgeTests.Test_SetProperty_ColorCurrentValueRendersAsName;
VAR
  PipeName: String;
  CurStr: String;
  HasMyColor: Boolean;
BEGIN
  PipeName := FPipeName;
  HasMyColor := FALSE;
  CurStr := '';
  GFixtureForm.MyColor := clRed;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
      Data, Item: TJSONObject;
      Arr: TJSONArray;
      i: Integer;
      NameV, CurV: TJSONValue;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'NoSuchProperty');
        Args.AddPair('value', '');
        Resp := Client.Call(98, 'set_property', Args);
        TRY
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
              HasMyColor := TRUE;
              CurStr := TJSONString(CurV).Value;
            end;
            Break;
          end;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(HasMyColor, 'expected MyColor.currentValue in availableProperties');
  Assert.AreEqual('clRed', CurStr,
                  'MyColor=clRed should render as "clRed", got "' + CurStr + '"');
END;


// availableProperties kind annotation: TColor entries should report
// kind:'color' rather than 'integer', so the AI knows to send named/hex
// values without first failing on a raw integer attempt.
PROCEDURE TBridgeTests.Test_SetProperty_ColorAvailablePropertiesKindIsColor;
VAR
  PipeName: String;
  Kind: String;
  Found: Boolean;
BEGIN
  PipeName := FPipeName;
  Found := FALSE;
  Kind := '';
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp: TJSONObject;
      Data, Item: TJSONObject;
      Arr: TJSONArray;
      i: Integer;
      NameV, KindV: TJSONValue;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'NoSuchProperty');
        Args.AddPair('value', '');
        Resp := Client.Call(99, 'set_property', Args);
        TRY
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
              Found := TRUE;
              Kind := TJSONString(KindV).Value;
            end;
            Break;
          end;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Found, 'expected MyColor entry in availableProperties');
  Assert.AreEqual('color', Kind, 'TColor entries should be labelled kind:"color"');
END;


// Helper: read the success-response 'elided' boolean. Returns FALSE if missing
// or wrong type — caller's assertion will reveal that case.
FUNCTION GetElidedFlag(AResult: TJSONObject; OUT APresent: Boolean): Boolean;
VAR V: TJSONValue;
BEGIN
  Result   := FALSE;
  APresent := FALSE;
  if AResult = NIL then EXIT;
  V := AResult.GetValue('elided');
  if not (V IS TJSONBool) then EXIT;
  APresent := TRUE;
  Result   := TJSONBool(V).AsBoolean;
END;


// Elision — string equality. Edt.Text already 'HelloWorld'; writing it again
// should be elided. Verified two ways: response carries elided=true, AND
// Edt.OnChange did not fire (EdtChangeCount stayed at 0).
PROCEDURE TBridgeTests.Test_SetProperty_ElisionStringEqualReturnsElidedAndSkipsOnChange;
VAR
  PipeName: String;
  Elided, Present, Ok: Boolean;
  ChangesAfter: Integer;
BEGIN
  PipeName     := FPipeName;
  Elided       := FALSE;
  Present      := FALSE;
  Ok           := FALSE;
  Assert.AreEqual('HelloWorld', GFixtureForm.Edt.Text, 'fixture precondition');
  Assert.AreEqual(0, GFixtureForm.EdtChangeCount, 'fixture precondition: no priming OnChange');
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp, OkRes: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.edtName');
        Args.AddPair('propName', 'Text');
        Args.AddPair('value', 'HelloWorld');           // same as live value
        Resp := Client.Call(200, 'set_property', Args);
        TRY
          OkRes := GetOkResult(Resp);
          Ok := OkRes <> NIL;
          if Ok then Elided := GetElidedFlag(OkRes, Present);
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  ChangesAfter := GFixtureForm.EdtChangeCount;
  Assert.IsTrue(Ok, 'set_property should return ok even when eliding');
  Assert.IsTrue(Present, 'success response must carry elided field');
  Assert.IsTrue(Elided, 'string-equal write should be elided');
  Assert.AreEqual(0, ChangesAfter, 'OnChange must NOT fire on an elided write');
END;


// Elision — string different. Writing a new value to Edt.Text reports
// elided=false AND fires OnChange once. Pins the negative side of the contract.
PROCEDURE TBridgeTests.Test_SetProperty_ElisionStringDifferentFiresOnChangeAndReportsElidedFalse;
VAR
  PipeName: String;
  Elided, Present, Ok: Boolean;
  ChangesAfter: Integer;
BEGIN
  PipeName     := FPipeName;
  Elided       := TRUE;             // start TRUE; will assert it became FALSE
  Present      := FALSE;
  Ok           := FALSE;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp, OkRes: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.edtName');
        Args.AddPair('propName', 'Text');
        Args.AddPair('value', 'NewValue');             // different from 'HelloWorld'
        Resp := Client.Call(201, 'set_property', Args);
        TRY
          OkRes := GetOkResult(Resp);
          Ok := OkRes <> NIL;
          if Ok then Elided := GetElidedFlag(OkRes, Present);
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  ChangesAfter := GFixtureForm.EdtChangeCount;
  Assert.IsTrue(Ok, 'set_property should succeed on a real write');
  Assert.IsTrue(Present, 'success response must carry elided field');
  Assert.IsFalse(Elided, 'string-different write must NOT be elided');
  Assert.AreEqual('NewValue', GFixtureForm.Edt.Text, 'live Text should reflect the write');
  Assert.AreEqual(1, ChangesAfter, 'OnChange should fire exactly once on a real write');
END;


// Elision — integer. Tag starts at 0 (Setup); writing '0' should elide.
PROCEDURE TBridgeTests.Test_SetProperty_ElisionIntegerEqualReturnsElided;
VAR
  PipeName: String;
  Elided, Present, Ok: Boolean;
BEGIN
  PipeName := FPipeName;
  Elided   := FALSE;
  Present  := FALSE;
  Ok       := FALSE;
  Assert.AreEqual(NativeInt(0), GFixtureForm.Tag, 'fixture precondition');
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp, OkRes: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'Tag');
        Args.AddPair('value', '0');                    // same as live
        Resp := Client.Call(202, 'set_property', Args);
        TRY
          OkRes := GetOkResult(Resp);
          Ok := OkRes <> NIL;
          if Ok then Elided := GetElidedFlag(OkRes, Present);
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok');
  Assert.IsTrue(Present, 'elided field must be present');
  Assert.IsTrue(Elided, 'integer-equal write should be elided');
END;


// Elision — boolean. Cbx.Checked starts at FALSE; writing 'false' elides.
PROCEDURE TBridgeTests.Test_SetProperty_ElisionBooleanEqualReturnsElided;
VAR
  PipeName: String;
  Elided, Present, Ok: Boolean;
BEGIN
  PipeName := FPipeName;
  Elided   := FALSE;
  Present  := FALSE;
  Ok       := FALSE;
  Assert.IsFalse(GFixtureForm.Cbx.Checked, 'fixture precondition');
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp, OkRes: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.cbxFlag');
        Args.AddPair('propName', 'Checked');
        Args.AddPair('value', 'false');                // same as live
        Resp := Client.Call(203, 'set_property', Args);
        TRY
          OkRes := GetOkResult(Resp);
          Ok := OkRes <> NIL;
          if Ok then Elided := GetElidedFlag(OkRes, Present);
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok');
  Assert.IsTrue(Present, 'elided field must be present');
  Assert.IsTrue(Elided, 'boolean-equal write should be elided');
END;


// Elision — float. FloatProp starts at 0.0; writing '0' elides (parser-equal).
PROCEDURE TBridgeTests.Test_SetProperty_ElisionFloatEqualReturnsElided;
VAR
  PipeName: String;
  Elided, Present, Ok: Boolean;
BEGIN
  PipeName := FPipeName;
  Elided   := FALSE;
  Present  := FALSE;
  Ok       := FALSE;
  GFixtureForm.FloatProp := 1.25;                      // pick something exact in binary
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp, OkRes: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'FloatProp');
        Args.AddPair('value', '1.25');                 // exact-bits match
        Resp := Client.Call(204, 'set_property', Args);
        TRY
          OkRes := GetOkResult(Resp);
          Ok := OkRes <> NIL;
          if Ok then Elided := GetElidedFlag(OkRes, Present);
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok');
  Assert.IsTrue(Present, 'elided field must be present');
  Assert.IsTrue(Elided, 'float-equal write (exact bits) should be elided');
END;


// Elision — set. MySetProp starts at []; writing '[]' elides. Tests the
// ordinal-equality path for sets.
PROCEDURE TBridgeTests.Test_SetProperty_ElisionSetEqualReturnsElided;
VAR
  PipeName: String;
  Elided, Present, Ok: Boolean;
BEGIN
  PipeName := FPipeName;
  Elided   := FALSE;
  Present  := FALSE;
  Ok       := FALSE;
  GFixtureForm.MySetProp := [fcRed, fcBlue];           // distinctive starting state
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp, OkRes: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MySetProp');
        Args.AddPair('value', '[fcRed,fcBlue]');       // same elements, same ordinal
        Resp := Client.Call(205, 'set_property', Args);
        TRY
          OkRes := GetOkResult(Resp);
          Ok := OkRes <> NIL;
          if Ok then Elided := GetElidedFlag(OkRes, Present);
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok');
  Assert.IsTrue(Present, 'elided field must be present');
  Assert.IsTrue(Elided, 'set-equal write should be elided');
END;


// Elision — enum. Force Position to poDesigned (independent of test ordering —
// Test_SetProperty_WritesEnumByIdentifier earlier in the suite leaves it on
// poDefaultSizeOnly), then write it back and confirm the bridge elides.
PROCEDURE TBridgeTests.Test_SetProperty_ElisionEnumEqualReturnsElided;
VAR
  PipeName: String;
  Elided, Present, Ok: Boolean;
BEGIN
  PipeName := FPipeName;
  Elided   := FALSE;
  Present  := FALSE;
  Ok       := FALSE;
  GFixtureForm.Position := poDesigned;
  Assert.AreEqual(Ord(poDesigned), Ord(GFixtureForm.Position), 'fixture precondition');
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp, OkRes: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'Position');
        Args.AddPair('value', 'poDesigned');           // same as live
        Resp := Client.Call(206, 'set_property', Args);
        TRY
          OkRes := GetOkResult(Resp);
          Ok := OkRes <> NIL;
          if Ok then Elided := GetElidedFlag(OkRes, Present);
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok');
  Assert.IsTrue(Present, 'elided field must be present');
  Assert.IsTrue(Elided, 'enum-equal write should be elided');
END;


// Elision — TAlphaColor. Set to a known color, then write the same hex back.
PROCEDURE TBridgeTests.Test_SetProperty_ElisionAlphaColorEqualReturnsElided;
VAR
  PipeName: String;
  Elided, Present, Ok: Boolean;
BEGIN
  PipeName := FPipeName;
  Elided   := FALSE;
  Present  := FALSE;
  Ok       := FALSE;
  GFixtureForm.MyAlpha := TAlphaColor($FFFF8000);      // opaque orange
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp, OkRes: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MyAlpha');
        Args.AddPair('value', '#FF8000');              // 6-digit form, alpha=FF assumed
        Resp := Client.Call(207, 'set_property', Args);
        TRY
          OkRes := GetOkResult(Resp);
          Ok := OkRes <> NIL;
          if Ok then Elided := GetElidedFlag(OkRes, Present);
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok');
  Assert.IsTrue(Present, 'elided field must be present');
  Assert.IsTrue(Elided, 'TAlphaColor-equal write should be elided');
END;


// Elision — TColor (VCL only). Set to clRed, then write 'clRed' back.
PROCEDURE TBridgeTests.Test_SetProperty_ElisionColorEqualReturnsElided;
VAR
  PipeName: String;
  Elided, Present, Ok: Boolean;
BEGIN
  PipeName := FPipeName;
  Elided   := FALSE;
  Present  := FALSE;
  Ok       := FALSE;
  GFixtureForm.MyColor := clRed;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp, OkRes: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm');
        Args.AddPair('propName', 'MyColor');
        Args.AddPair('value', 'clRed');                // same as live
        Resp := Client.Call(208, 'set_property', Args);
        TRY
          OkRes := GetOkResult(Resp);
          Ok := OkRes <> NIL;
          if Ok then Elided := GetElidedFlag(OkRes, Present);
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok');
  Assert.IsTrue(Present, 'elided field must be present');
  Assert.IsTrue(Elided, 'TColor-equal write should be elided');
END;


// Elision — dotted propName. Btn.Font.Size starts at 8 in Setup; writing '8' elides.
// Pins that the recursive call into the inner tkClass also honors elision.
PROCEDURE TBridgeTests.Test_SetProperty_ElisionDottedFontSizeEqualReturnsElided;
VAR
  PipeName: String;
  Elided, Present, Ok: Boolean;
BEGIN
  PipeName := FPipeName;
  Elided   := FALSE;
  Present  := FALSE;
  Ok       := FALSE;
  Assert.AreEqual(Single(8), Single(GFixtureForm.Btn.Font.Size), 0.001, 'fixture precondition');
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp, OkRes: TJSONObject;
    BEGIN
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('propName', 'Font.Size');
        Args.AddPair('value', '8');                    // same as live
        Resp := Client.Call(209, 'set_property', Args);
        TRY
          OkRes := GetOkResult(Resp);
          Ok := OkRes <> NIL;
          if Ok then Elided := GetElidedFlag(OkRes, Present);
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok');
  Assert.IsTrue(Present, 'elided field must be present');
  Assert.IsTrue(Elided, 'dotted Font.Size-equal write should be elided');
END;


// Contract pin: success responses ALWAYS carry the 'elided' field (true or false).
// Earlier set_property tests don't check this — adding one explicit guard so a
// future refactor that drops the field on some path is caught.
PROCEDURE TBridgeTests.Test_SetProperty_SuccessResponseAlwaysCarriesElidedField;
VAR
  PipeName: String;
  Present, Ok: Boolean;
BEGIN
  PipeName := FPipeName;
  Present  := FALSE;
  Ok       := FALSE;
  RunOnWorkerAndPump(
    PROCEDURE
    VAR
      Client: TBridgeTestClient;
      Args, Resp, OkRes: TJSONObject;
      Dummy: Boolean;
    BEGIN
      Dummy  := FALSE;
      Client := TBridgeTestClient.Create;
      TRY
        Assert.IsTrue(Client.ConnectAndHandshake(PipeName, 2000), 'connect');
        // Use a write that changes the value, so this also covers the non-elided
        // success path. The elision tests cover the elided=true side.
        Args := TJSONObject.Create;
        Args.AddPair('path', 'FixtureForm.btnTest');
        Args.AddPair('propName', 'Caption');
        Args.AddPair('value', 'OtherCaption');
        Resp := Client.Call(210, 'set_property', Args);
        TRY
          OkRes := GetOkResult(Resp);
          Ok := OkRes <> NIL;
          if Ok then Dummy := GetElidedFlag(OkRes, Present);
          // Touch Dummy so it doesn't get H2077'd as unused.
          if Dummy then ;
        FINALLY
          Resp.Free;
        END;
      FINALLY
        Client.Free;
      END;
    END, 5000);
  Assert.IsTrue(Ok, 'set_property should return ok');
  Assert.IsTrue(Present, 'every success response must carry elided field');
END;


INITIALIZATION
  TDUnitX.RegisterTestFixture(TBridgeTests);

FINALIZATION
  FreeAndNil(GFixtureForm);


END.
