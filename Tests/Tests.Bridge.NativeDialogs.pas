unit Tests.Bridge.NativeDialogs;

{=============================================================================================================
   2026.09
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for the native-dialog escape hatch (Autopilot.Bridge.NativeDialogs).
   - Raises a real Win32 MessageBox on a background thread, then enumerates and dismisses it by role from the test thread — the harder cross-thread path.
   - A cancel-fallback in the finally block guarantees the MessageBox is always closed, so a failing test cannot hang the suite on TThread.WaitFor.
=============================================================================================================}

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TNativeDialogTests = class
  public
    [Test] procedure Test_EnumerateFindsMessageBox_AndDismissByRole;
    [Test] procedure Test_DismissByRole_RoleBeatsCaptionSubstring;
    [Test] procedure Test_NoDialogUp_ClickReturnsNoDialog;
  end;


implementation

uses
  Winapi.Windows,
  System.SysUtils, System.Classes, System.SyncObjs, System.JSON, System.Generics.Collections,
  Autopilot.Bridge.NativeDialogs;

type
  // Owns a MessageBox on its own thread. Done is set after the box returns, so the test
  // can wait on it WITHOUT a blocking TThread.WaitFor (which would hang if the box stayed up).
  TMsgBoxThread = class(TThread)
  public
    Caption : String;
    Flags   : Cardinal;
    Returned: Integer;
    Done    : TEvent;
    constructor Create(const ACaption: String; AFlags: Cardinal);
    destructor Destroy; override;
    procedure Execute; override;
  end;


constructor TMsgBoxThread.Create(const ACaption: String; AFlags: Cardinal);
begin
  Caption  := ACaption;
  Flags    := AFlags;
  Returned := 0;
  Done     := TEvent.Create(nil, True, False, '');
  inherited Create(False);   // FreeOnTerminate stays False — the test controls lifetime
end;


destructor TMsgBoxThread.Destroy;
begin
  inherited;                 // TThread.Destroy: Terminate + WaitFor (safe only once Done is signalled)
  FreeAndNil(Done);
end;


procedure TMsgBoxThread.Execute;
begin
  Returned := MessageBox(0, 'A native modal dialog from the test.', PChar(Caption), Flags);
  Done.SetEvent;
end;


// Find the enumerated dialog whose caption matches, returning its hwnd (0 if absent) and
// how many buttons it reported.
function FindDialogByCaption(const ACaption: String; out AButtonCount: Integer): NativeUInt;
var
  NoExclude: TArray<NativeUInt>;
  Arr, Btns: TJSONArray;
  i: Integer;
  Node: TJSONObject;
begin
  Result := 0;
  AButtonCount := 0;
  NoExclude := nil;
  Arr := EnumerateNativeDialogs(NoExclude);
  try
    for i := 0 to Arr.Count - 1 do
    begin
      Node := Arr.Items[i] AS TJSONObject;
      if SameText(Node.GetValue<String>('caption'), ACaption) then
      begin
        Result := NativeUInt(Node.GetValue<Int64>('hwnd'));
        Btns := Node.GetValue('buttons') AS TJSONArray;
        if Btns <> nil then AButtonCount := Btns.Count;
        Exit;
      end;
    end;
  finally
    Arr.Free;
  end;
end;


procedure TNativeDialogTests.Test_EnumerateFindsMessageBox_AndDismissByRole;
const
  UniqueCap = 'AP_TEST_DIALOG_7731';
var
  Th: TMsgBoxThread;
  Dlg, Resolved: NativeUInt;
  BtnCount, ClickedId: Integer;
  ClickedCap, Reason, Via: String;
  Deadline: UInt64;
  Clicked: Boolean;
  Junk: TArray<NativeUInt>;
begin
  Junk := nil;
  Th := TMsgBoxThread.Create(UniqueCap, MB_YESNOCANCEL or MB_ICONQUESTION);
  try
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
    Clicked := ClickNativeDialogButton(Junk, Dlg, 'no', ClickedId, ClickedCap, Resolved, Reason, Via);
    Assert.IsTrue(Clicked, 'ClickNativeDialogButton returned false (' + Reason + ')');
    Assert.AreEqual(IDNO, ClickedId, 'dispatched the wrong control id');
    // This box HAS a real No button window, so the verified path must be the one used.
    // The twin test below pins the opposite case.
    Assert.AreEqual('BM_CLICK', Via, 'expected the verified button-HWND dispatch path');

    { # The box must have returned IDNO }
    Assert.IsTrue(Th.Done.WaitFor(3000) = wrSignaled, 'MessageBox did not close after dismiss');
    Assert.AreEqual(IDNO, Th.Returned, 'MessageBox returned the wrong button');
  finally
    // If anything above failed with the box still up, force it closed so Th.Free's WaitFor
    // cannot hang the runner.
    if Th.Done.WaitFor(0) <> wrSignaled then
    begin
      ClickNativeDialogButton(Junk, 0, 'cancel', ClickedId, ClickedCap, Resolved, Reason, Via);
      Th.Done.WaitFor(2000);
    end;
    // Th.Free -> TThread.Destroy does an UNTIMED Terminate+WaitFor; Execute is parked in a
    // blocking MessageBox that ignores Terminated, so Free only returns once the box is gone.
    // If the cancel fallback ALSO failed to close it, Done is still unsignalled here -> Free
    // would hang the whole runner. Leak the parked thread instead (it dies with the process)
    // and fail loudly: a leaked thread in an already-failing test beats a frozen suite.
    if Th.Done.WaitFor(0) = wrSignaled
    then Th.Free
    else Assert.Fail('MessageBox could not be dismissed; thread left parked to avoid an untimed WaitFor hang');
  end;
end;


// Selector precedence: a role keyword must beat a loose caption substring.
// Abort/Retry/Ignore has no 'No' button, but 'Ignore' contains the substring 'no'. With the
// substring pass ahead of the role pass, selector 'no' wrongly resolves to IDIGNORE; with role
// ahead of substring it correctly resolves to IDNO (no IDNO control exists, so it falls through
// to id-dispatch, MatchBtn=0, and the box stays up — exactly what we assert and then clean up).
procedure TNativeDialogTests.Test_DismissByRole_RoleBeatsCaptionSubstring;
const
  UniqueCap = 'AP_TEST_DIALOG_ROLE_5520';
var
  Th: TMsgBoxThread;
  Dlg, Resolved: NativeUInt;
  BtnCount, ClickedId: Integer;
  ClickedCap, Reason, Via: String;
  Deadline: UInt64;
  Clicked: Boolean;
  Junk: TArray<NativeUInt>;
begin
  Junk := nil;
  Th := TMsgBoxThread.Create(UniqueCap, MB_ABORTRETRYIGNORE or MB_ICONERROR);
  try
    { # Wait for the box to appear }
    Dlg := 0; BtnCount := 0;
    Deadline := TThread.GetTickCount64 + 5000;
    while (Dlg = 0) and (TThread.GetTickCount64 < Deadline) do
    begin
      Dlg := FindDialogByCaption(UniqueCap, BtnCount);
      if Dlg = 0 then TThread.Sleep(50);
    end;
    Assert.IsTrue(Dlg <> 0, 'native MessageBox was not found by EnumerateNativeDialogs');

    { # 'no' must resolve by role (IDNO), not by the 'Ig[no]re' substring (IDIGNORE) }
    Clicked := ClickNativeDialogButton(Junk, Dlg, 'no', ClickedId, ClickedCap, Resolved, Reason, Via);
    Assert.IsTrue(Clicked, 'ClickNativeDialogButton returned false (' + Reason + ')');
    Assert.AreEqual(IDNO, ClickedId, 'selector ''no'' resolved by caption substring (Ignore) instead of role IDNO');
    // This box has NO No button, so the id was dispatched blind and the box is still up even
    // though Clicked is TRUE (the finally block below dismisses it via a real button). That is
    // the unverifiable WM_COMMAND-by-id path, and 'via' is the only thing that reports it.
    Assert.AreEqual('WM_COMMAND', Via, 'expected the unverified dispatch-by-id path');
  finally
    // IDNO has no control on this box, so the resolve above left it up; dismiss it via a real
    // button (Abort). Under a regression the substring path already closed it via Ignore, so
    // Done is signalled and this block is a no-op. Done-gated Free avoids an untimed WaitFor hang.
    if Th.Done.WaitFor(0) <> wrSignaled then
    begin
      ClickNativeDialogButton(Junk, 0, 'abort', ClickedId, ClickedCap, Resolved, Reason, Via);   // 0 = topmost (our box is the only dialog up)
      Th.Done.WaitFor(2000);
    end;
    if Th.Done.WaitFor(0) = wrSignaled
    then Th.Free
    else Assert.Fail('MessageBox could not be dismissed; thread left parked to avoid an untimed WaitFor hang');
  end;
end;


procedure TNativeDialogTests.Test_NoDialogUp_ClickReturnsNoDialog;
var
  ClickedId: Integer;
  ClickedCap, Reason, Via: String;
  Resolved: NativeUInt;
  NoExclude: TArray<NativeUInt>;
begin
  NoExclude := nil;
  // No native dialog is up in this fixture, so the topmost-dialog lookup finds nothing.
  Assert.IsFalse(ClickNativeDialogButton(NoExclude, 0, 'ok', ClickedId, ClickedCap, Resolved, Reason, Via),
                 'click should fail when no dialog is up');
  Assert.AreEqual('no_dialog', Reason, 'expected reason no_dialog');
end;


initialization
  TDUnitX.RegisterTestFixture(TNativeDialogTests);


end.
