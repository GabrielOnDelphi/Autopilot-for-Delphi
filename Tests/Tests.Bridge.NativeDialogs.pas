UNIT Tests.Bridge.NativeDialogs;

{=====================================================
   DUnitX tests for the native-dialog escape hatch (Autopilot.Bridge.NativeDialogs).

   A native MessageBox has no TComponent, so the path-based bridge tools cannot see it.
   This fixture raises a REAL MessageBox on a background thread (which blocks that thread
   in its own modal loop), then from the main test thread enumerates the dialog and
   dispatches one of its buttons by role — exactly what HandleDismissDialog does on the
   bridge's main thread, but here the click is cross-thread, which is the harder path.

   Safety: a cancel-fallback in the finally block guarantees the MessageBox is closed even
   if the assertion path fails, so a regression cannot hang the whole suite on TThread.WaitFor.
=====================================================}

INTERFACE

USES
  DUnitX.TestFramework;

TYPE
  [TestFixture]
  TNativeDialogTests = CLASS
  PUBLIC
    [Test] PROCEDURE Test_EnumerateFindsMessageBox_AndDismissByRole;
    [Test] PROCEDURE Test_NoDialogUp_ClickReturnsNoDialog;
  END;


IMPLEMENTATION

USES
  Winapi.Windows,
  System.SysUtils, System.Classes, System.SyncObjs, System.JSON, System.Generics.Collections,
  Autopilot.Bridge.NativeDialogs;

TYPE
  // Owns a MessageBox on its own thread. Done is set after the box returns, so the test
  // can wait on it WITHOUT a blocking TThread.WaitFor (which would hang if the box stayed up).
  TMsgBoxThread = CLASS(TThread)
  PUBLIC
    Caption : String;
    Returned: Integer;
    Done    : TEvent;
    CONSTRUCTOR Create(CONST ACaption: String);
    DESTRUCTOR Destroy; OVERRIDE;
    PROCEDURE Execute; OVERRIDE;
  END;


CONSTRUCTOR TMsgBoxThread.Create(CONST ACaption: String);
BEGIN
  Caption  := ACaption;
  Returned := 0;
  Done     := TEvent.Create(NIL, TRUE, FALSE, '');
  inherited Create(FALSE);   // FreeOnTerminate stays FALSE — the test controls lifetime
END;


DESTRUCTOR TMsgBoxThread.Destroy;
BEGIN
  inherited;                 // TThread.Destroy: Terminate + WaitFor (safe only once Done is signalled)
  FreeAndNil(Done);
END;


PROCEDURE TMsgBoxThread.Execute;
BEGIN
  Returned := MessageBox(0, 'A native modal dialog from the test.', PChar(Caption), MB_YESNOCANCEL or MB_ICONQUESTION);
  Done.SetEvent;
END;


// Find the enumerated dialog whose caption matches, returning its hwnd (0 if absent) and
// how many buttons it reported.
FUNCTION FindDialogByCaption(CONST ACaption: String; OUT AButtonCount: Integer): NativeUInt;
VAR
  NoExclude: TArray<NativeUInt>;
  Arr, Btns: TJSONArray;
  i: Integer;
  Node: TJSONObject;
BEGIN
  Result := 0;
  AButtonCount := 0;
  NoExclude := NIL;
  Arr := EnumerateNativeDialogs(NoExclude);
  TRY
    for i := 0 to Arr.Count - 1 do
    begin
      Node := Arr.Items[i] AS TJSONObject;
      if SameText(Node.GetValue<String>('caption'), ACaption) then
      begin
        Result := NativeUInt(Node.GetValue<Int64>('hwnd'));
        Btns := Node.GetValue('buttons') AS TJSONArray;
        if Btns <> NIL then AButtonCount := Btns.Count;
        EXIT;
      end;
    end;
  FINALLY
    Arr.Free;
  END;
END;


PROCEDURE TNativeDialogTests.Test_EnumerateFindsMessageBox_AndDismissByRole;
CONST
  UniqueCap = 'AP_TEST_DIALOG_7731';
VAR
  Th: TMsgBoxThread;
  Dlg, Resolved: NativeUInt;
  BtnCount, ClickedId: Integer;
  ClickedCap, Reason: String;
  Deadline: UInt64;
  Clicked: Boolean;
  Junk: TArray<NativeUInt>;
BEGIN
  Junk := NIL;
  Th := TMsgBoxThread.Create(UniqueCap);
  TRY
    { # Wait for the box to appear }
    Dlg := 0; BtnCount := 0;
    Deadline := TThread.GetTickCount64 + 5000;
    while (Dlg = 0) and (TThread.GetTickCount64 < Deadline) do
    begin
      Dlg := FindDialogByCaption(UniqueCap, BtnCount);
      if Dlg = 0 then TThread.Sleep(50);
    end;
    Assert.IsTrue(Dlg <> 0, 'native MessageBox was not found by EnumerateNativeDialogs');
    Assert.IsTrue(BtnCount >= 3, 'expected at least Yes/No/Cancel buttons, got ' + IntToStr(BtnCount));

    { # Dismiss by role }
    Clicked := ClickNativeDialogButton(Junk, Dlg, 'no', ClickedId, ClickedCap, Resolved, Reason);
    Assert.IsTrue(Clicked, 'ClickNativeDialogButton returned false (' + Reason + ')');
    Assert.AreEqual(IDNO, ClickedId, 'dispatched the wrong control id');

    { # The box must have returned IDNO }
    Assert.IsTrue(Th.Done.WaitFor(3000) = wrSignaled, 'MessageBox did not close after dismiss');
    Assert.AreEqual(IDNO, Th.Returned, 'MessageBox returned the wrong button');
  FINALLY
    // If anything above failed with the box still up, force it closed so Th.Free's WaitFor
    // cannot hang the runner.
    if Th.Done.WaitFor(0) <> wrSignaled then
    begin
      ClickNativeDialogButton(Junk, 0, 'cancel', ClickedId, ClickedCap, Resolved, Reason);
      Th.Done.WaitFor(2000);
    end;
    Th.Free;
  END;
END;


PROCEDURE TNativeDialogTests.Test_NoDialogUp_ClickReturnsNoDialog;
VAR
  ClickedId: Integer;
  ClickedCap, Reason: String;
  Resolved: NativeUInt;
  NoExclude: TArray<NativeUInt>;
BEGIN
  NoExclude := NIL;
  // No native dialog is up in this fixture, so the topmost-dialog lookup finds nothing.
  Assert.IsFalse(ClickNativeDialogButton(NoExclude, 0, 'ok', ClickedId, ClickedCap, Resolved, Reason),
                 'click should fail when no dialog is up');
  Assert.AreEqual('no_dialog', Reason, 'expected reason no_dialog');
END;


INITIALIZATION
  TDUnitX.RegisterTestFixture(TNativeDialogTests);


END.
