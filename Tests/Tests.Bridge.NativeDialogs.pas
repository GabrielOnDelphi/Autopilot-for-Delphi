unit Tests.Bridge.NativeDialogs;

{=============================================================================================================
   2026.11.19
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for the native-dialog escape hatch (Autopilot.Bridge.NativeDialogs).
   - Raises a real Win32 MessageBox or Task Dialog on a background thread, then enumerates and dismisses it from the test thread — the harder cross-thread path.
   - A click test checks the value the dialog itself returned, never only clicked:true: a click on the wrong button also answers clicked:true.
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
    [Test] procedure Test_TaskDialog_TextIsRead;

    { A Task Dialog built like MessageDlg: the click must make the box return the id of the button the selector names. }
    [Test]
    [TestCase('Role no',          'no,7')]
    [TestCase('Role yes',         'yes,6')]
    [TestCase('Role abort',       'abort,3')]
    [TestCase('Caption substring', 'bor,3')]
    procedure Test_TaskDialog_MessageDlgButtons_ReturnsThatButton(const ASelector: String; AExpectedId: Integer);

    { The default button is not the first one: a click that lands on "the default" or on "the first" is caught. }
    [Test]
    [TestCase('Role yes',   'yes,6')]
    [TestCase('Role abort', 'abort,3')]
    procedure Test_TaskDialog_DefaultIsNo_ReturnsThatButton(const ASelector: String; AExpectedId: Integer);

    { Localized captions (as on a German Windows): a caption names the button; a role or a number cannot be tied to a button, so the click is refused and the box stays up. }
    [Test]
    [TestCase('Caption Nein', 'Nein,7')]
    [TestCase('Caption Ja',   'Ja,6')]
    procedure Test_TaskDialog_LocalizedCaption_ReturnsThatButton(const ASelector: String; AExpectedId: Integer);
    [Test]
    [TestCase('Role no',            'no,button_not_found')]
    [TestCase('Number of a button', '7,button_not_found')]
    [TestCase('Id zero',            '0,button_ambiguous')]
    procedure Test_TaskDialog_LocalizedCaption_UnresolvableSelector_IsRefused(const ASelector, AExpectedReason: String);

    { A caption substring that two buttons share ('all' in 'Yes to All' and 'No to All') is refused, never sent to the first. }
    [Test] procedure Test_TaskDialog_SubstringOnTwoButtons_IsRefused;

    { A Task Dialog with COMMON buttons (TDCBF_OK_BUTTON, TDCBF_CANCEL_BUTTON): the click must return that button. }
    [Test]
    [TestCase('Ok',     'ok,1')]
    [TestCase('Cancel', 'cancel,2')]
    procedure Test_TaskDialog_CommonButtons_ReturnsThatButton(const ASelector: String; AExpectedId: Integer);

    { The classic MessageBox path (real control ids): role and number reach the right button. }
    [Test]
    [TestCase('Role yes',    'yes,6')]
    [TestCase('Role cancel', 'cancel,2')]
    [TestCase('Number 7',    '7,7')]
    procedure Test_MessageBox_YesNoCancel_ReturnsThatButton(const ASelector: String; AExpectedId: Integer);

    { A real Vista Save dialog (IFileSaveDialog): the name typed into its File name box is the name the dialog returns. }
    [Test] procedure Test_FileSaveDialog_FileNameAndSave_ReturnsThatName;
    [Test] procedure Test_FileSaveDialog_FileNameOnly_LeavesTheDialogUp_ThenSaveReturnsThatName;
    { A dialog with no File name box: the name is refused, nothing is clicked, the box stays up. }
    [Test] procedure Test_MessageBox_FileName_IsRefused_NothingClicked;
    [Test] procedure Test_NoDialogUp_FileNameReturnsNoDialog;

    { The hidden buttons of a Vista Open/Save dialog (Help id 1038; on Save also a caption-less id 0) cannot be clicked by a person, so they are neither listed nor matched. }
    [Test]
    [TestCase('Save', 'Save')]
    [TestCase('Open', 'Open')]
    procedure Test_FileDialog_HiddenButtons_AreNotListed(const AKind: String);
    [Test]
    [TestCase('Save', 'Save')]
    [TestCase('Open', 'Open')]
    procedure Test_FileDialog_HiddenButtons_AreNotClicked_CancelStillIs(const AKind: String);
  end;


implementation

uses
  Winapi.Windows, Winapi.Messages, Winapi.CommCtrl, Winapi.ActiveX, Winapi.ShlObj,
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
type
  { Owns a Task Dialog (TaskDialogIndirect, the window Delphi 13's ShowMessage/MessageDlg show) on its own thread. Same lifetime rules as TMsgBoxThread. }
  TTaskDlgThread = class(TThread)
  public
    Caption, MainInstruction, Content: String;
    Returned: Integer;
    Done    : TEvent;
    constructor Create(const ACaption, AMainInstruction, AContent: String);
    destructor Destroy; override;
    procedure Execute; override;
  end;


constructor TTaskDlgThread.Create(const ACaption, AMainInstruction, AContent: String);
begin
  Caption         := ACaption;
  MainInstruction := AMainInstruction;
  Content         := AContent;
  Returned        := 0;
  Done            := TEvent.Create(nil, True, False, '');
  inherited Create(False);
end;


destructor TTaskDlgThread.Destroy;
begin
  inherited;
  FreeAndNil(Done);
end;


procedure TTaskDlgThread.Execute;
var
  Config: TTaskDialogConfig;
  Btn: Integer;
begin
  FillChar(Config, SizeOf(Config), 0);
  Config.cbSize             := SizeOf(Config);
  Config.dwCommonButtons    := TDCBF_OK_BUTTON or TDCBF_CANCEL_BUTTON;
  Config.pszWindowTitle     := PChar(Caption);
  Config.pszMainInstruction := PChar(MainInstruction);
  Config.pszContent         := PChar(Content);
  Btn := 0;
  if Succeeded(TaskDialogIndirect(Config, @Btn, nil, nil))
  then Returned := Btn
  else Returned := -1;
  Done.SetEvent;
end;


type
  { Owns a Task Dialog with CUSTOM buttons only, built the way Vcl.Dialogs.pas InternalDoTaskMessageDlgPosHelp builds the one of MessageDlg: CommonButtons empty, each button's nButtonID = its ModalResult (mrYes = IDYES, mrNo = IDNO, mrAbort = IDABORT), TDF_ALLOW_DIALOG_CANCELLATION, a default button.
    NotifiedId = the id of the last TDN_BUTTON_CLICKED notification (-1 = none). Same lifetime rules as TMsgBoxThread. }
  TTaskDlgButtonsThread = class(TThread)
  public
    Caption   : String;
    Captions  : TArray<String>;
    Ids       : TArray<Integer>;
    DefaultId : Integer;
    Returned  : Integer;
    NotifiedId: Integer;
    Done      : TEvent;
    constructor Create(const ACaption: String; const ACaptions: array of String; const AIds: array of Integer; ADefaultId: Integer);
    destructor Destroy; override;
    procedure Execute; override;
  end;


function TaskDlgButtonsCallback(hwnd: HWND; msg: UINT; wParam: WPARAM; lParam: LPARAM; lpRefData: LONG_PTR): HResult; stdcall;
begin
  if msg = TDN_BUTTON_CLICKED
  then TTaskDlgButtonsThread(lpRefData).NotifiedId := Integer(wParam);
  Result := S_OK;
end;


constructor TTaskDlgButtonsThread.Create(const ACaption: String; const ACaptions: array of String; const AIds: array of Integer; ADefaultId: Integer);
var
  i: Integer;
begin
  System.Assert(Length(ACaptions) = Length(AIds), 'one id per caption');
  Caption := ACaption;
  SetLength(Captions, Length(ACaptions));
  for i := 0 to High(ACaptions) do
    Captions[i] := ACaptions[i];
  SetLength(Ids, Length(AIds));
  for i := 0 to High(AIds) do
    Ids[i] := AIds[i];
  DefaultId  := ADefaultId;
  Returned   := 0;
  NotifiedId := -1;
  Done       := TEvent.Create(nil, True, False, '');
  inherited Create(False);
end;


destructor TTaskDlgButtonsThread.Destroy;
begin
  inherited;
  FreeAndNil(Done);
end;


procedure TTaskDlgButtonsThread.Execute;
var
  Config: TTaskDialogConfig;
  Buttons: TArray<TTaskDialogButton>;
  i, Btn: Integer;
begin
  SetLength(Buttons, Length(Ids));
  for i := 0 to High(Ids) do
    begin
      Buttons[i].nButtonID     := Ids[i];
      Buttons[i].pszButtonText := PChar(Captions[i]);
    end;
  FillChar(Config, SizeOf(Config), 0);
  Config.cbSize             := SizeOf(Config);
  Config.dwFlags            := TDF_ALLOW_DIALOG_CANCELLATION;
  Config.dwCommonButtons    := 0;
  Config.pszWindowTitle     := PChar(Caption);
  Config.pszMainInstruction := 'Autopilot regression test: which button was clicked?';
  Config.cButtons           := Length(Buttons);
  Config.pButtons           := @Buttons[0];
  Config.nDefaultButton     := DefaultId;
  Config.pfCallback         := TaskDlgButtonsCallback;
  Config.lpCallbackData     := LONG_PTR(Self);
  Btn := 0;
  if Succeeded(TaskDialogIndirect(Config, @Btn, nil, nil))
  then Returned := Btn
  else Returned := -1;
  Done.SetEvent;
end;


type
  { Owns a Vista file dialog on its own STA thread: the Save dialog (IFileSaveDialog, the dialog TSaveDialog shows when the app is themed), or with AOpen the Open dialog (IFileOpenDialog, the one of TOpenDialog).
    Returned = the HRESULT of Show; ResultPath = the file system path of GetResult when Show succeeded. Same lifetime rules as TMsgBoxThread. }
  TFileDlgThread = class(TThread)
  public
    Title     : String;
    OpenDialog: Boolean;
    Returned  : HRESULT;
    ResultPath: String;
    Done      : TEvent;
    constructor Create(const ATitle: String; AOpen: Boolean = FALSE);
    destructor Destroy; override;
    procedure Execute; override;
  end;


constructor TFileDlgThread.Create(const ATitle: String; AOpen: Boolean = FALSE);
begin
  Title      := ATitle;
  OpenDialog := AOpen;
  Returned   := E_FAIL;
  ResultPath := '';
  Done       := TEvent.Create(nil, True, False, '');
  inherited Create(False);
end;


destructor TFileDlgThread.Destroy;
begin
  inherited;
  FreeAndNil(Done);
end;


procedure TFileDlgThread.Execute;
var
  Hr: HRESULT;
  Dlg: IFileDialog;
  Item: IShellItem;
  P: LPWSTR;
begin
  Hr := CoInitializeEx(NIL, COINIT_APARTMENTTHREADED);
  try
    Dlg := NIL;
    Item := NIL;
    if OpenDialog
    then Returned := CoCreateInstance(CLSID_FileOpenDialog, NIL, CLSCTX_INPROC_SERVER, IFileDialog, Dlg)
    else Returned := CoCreateInstance(CLSID_FileSaveDialog, NIL, CLSCTX_INPROC_SERVER, IFileDialog, Dlg);
    if Succeeded(Returned) then
      begin
        Dlg.SetTitle(PChar(Title));
        Returned := Dlg.Show(0);
        if Succeeded(Returned) and Succeeded(Dlg.GetResult(Item)) and (Item <> NIL) then
          if Succeeded(Item.GetDisplayName(SIGDN_FILESYSPATH, P)) then
            begin
              ResultPath := P;
              CoTaskMemFree(P);
            end;
      end;
    Item := NIL;   // release before CoUninitialize
    Dlg := NIL;
  finally
    if Succeeded(Hr)
    then CoUninitialize;
    Done.SetEvent;
  end;
end;


{ A file name in %TEMP% that does not exist yet, so the Save dialog asks nothing about overwriting it. }
function NewTempFileName(const ATag: String): String;
begin
  Result := IncludeTrailingPathDelimiter(GetEnvironmentVariable('TEMP')) + 'AP_TEST_D3_' + ATag + '_' + IntToStr(GetCurrentProcessId) + '_' + IntToStr(TThread.GetTickCount64) + '.txt';
  System.Assert(not FileExists(Result), 'the test file name already exists: ' + Result);
end;


{ Closes a dialog still up without the code under test: WM_COMMAND IDCANCEL with the Cancel button's own window (Cancel is a direct child, id 2, in a MessageBox and in a Vista file dialog).
  Frees the thread (ADone is its own event) only when the dialog is gone; otherwise leaves it parked (an untimed WaitFor in TThread.Destroy would hang the runner) and fails. }
procedure FinishByCancel(ATh: TThread; ADone: TEvent; ADlg: NativeUInt);
begin
  if (ADone.WaitFor(0) <> wrSignaled) and (ADlg <> 0) then
    begin
      SendMessageTimeout(HWND(ADlg), WM_COMMAND, WPARAM(IDCANCEL or (BN_CLICKED shl 16)), LPARAM(GetDlgItem(HWND(ADlg), IDCANCEL)), SMTO_ABORTIFHUNG, 2000, nil);
      ADone.WaitFor(3000);
    end;
  if ADone.WaitFor(0) = wrSignaled
  then FreeAndNil(ATh)
  else Assert.Fail('the dialog could not be dismissed; thread left parked to avoid an untimed WaitFor hang');
end;


function DumpEnumProc(AWnd: HWND; AParam: LPARAM): BOOL; stdcall;
var
  Buf: array[0..255] of Char;
  S: String;
begin
  SetString(S, Buf, GetClassName(AWnd, Buf, Length(Buf)));
  TStrings(AParam).Add(S + '(id ' + IntToStr(GetDlgCtrlID(AWnd)) + ')');
  Result := TRUE;
end;


{ The 'text' field of the enumerated dialog whose caption is ACaption; '<no dialog>' when none matches. }
function DialogTextByCaption(const ACaption: String): String;
var
  NoExclude: TArray<NativeUInt>;
  Arr: TJSONArray;
  i: Integer;
  Node: TJSONObject;
begin
  Result := '<no dialog>';
  NoExclude := nil;
  Arr := EnumerateNativeDialogs(NoExclude);
  try
    for i := 0 to Arr.Count - 1 do
      begin
        Node := Arr.Items[i] AS TJSONObject;
        if SameText(Node.GetValue<String>('caption'), ACaption)
        then EXIT(Node.GetValue<String>('text'));
      end;
  finally
    FreeAndNil(Arr);
  end;
end;


{ The class names of every descendant window of ADlg, for a failure message. }
function DescendantClasses(ADlg: HWND): String;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    EnumChildWindows(ADlg, @DumpEnumProc, LPARAM(L));
    L.Delimiter := ',';
    Result := L.DelimitedText;
  finally
    FreeAndNil(L);
  end;
end;


function ButtonEnumProc(AWnd: HWND; AParam: LPARAM): BOOL; stdcall;
var
  Buf: array[0..255] of Char;
  S: String;
begin
  SetString(S, Buf, GetClassName(AWnd, Buf, Length(Buf)));
  if SameText(S, 'Button')
  then TList<HWND>(AParam).Add(AWnd);
  Result := TRUE;
end;


{ The ids of AIds, sorted and comma-joined, so two id lists compare as two strings. }
function JoinSortedIds(AIds: TList<Integer>): String;
var
  i: Integer;
begin
  AIds.Sort;
  Result := '';
  for i := 0 to AIds.Count - 1 do
    begin
      if Result <> ''
      then Result := Result + ',';
      Result := Result + IntToStr(AIds[i]);
    end;
end;


{ The control ids of every Button window under ADlg, read from Win32 apart from the code under test (EnumChildWindows walks all descendants).
  AVisible holds the visible ones, AHidden the hidden ones; each sorted and comma-joined. }
procedure ButtonIdsOf(ADlg: HWND; OUT AVisible, AHidden: String);
var
  Wnds: TList<HWND>;
  Vis, Hid: TList<Integer>;
  W: HWND;
begin
  Wnds := TList<HWND>.Create;
  Vis  := TList<Integer>.Create;
  Hid  := TList<Integer>.Create;
  try
    EnumChildWindows(ADlg, @ButtonEnumProc, LPARAM(Wnds));
    for W in Wnds do
      if IsWindowVisible(W)
      then Vis.Add(GetDlgCtrlID(W))
      else Hid.Add(GetDlgCtrlID(W));
    AVisible := JoinSortedIds(Vis);
    AHidden  := JoinSortedIds(Hid);
  finally
    FreeAndNil(Hid);
    FreeAndNil(Vis);
    FreeAndNil(Wnds);
  end;
end;


{ The button ids that EnumerateNativeDialogs lists for the dialog whose caption is ACaption, sorted and comma-joined; '<no dialog>' when none matches. }
function ListedButtonIds(const ACaption: String): String;
var
  NoExclude: TArray<NativeUInt>;
  Arr, Btns: TJSONArray;
  Ids: TList<Integer>;
  i, k: Integer;
  Node: TJSONObject;
begin
  Result := '<no dialog>';
  NoExclude := nil;
  Ids := TList<Integer>.Create;
  try
    Arr := EnumerateNativeDialogs(NoExclude);
    try
      for i := 0 to Arr.Count - 1 do
        begin
          Node := Arr.Items[i] AS TJSONObject;
          if not SameText(Node.GetValue<String>('caption'), ACaption) then Continue;
          Btns := Node.GetValue('buttons') AS TJSONArray;
          for k := 0 to Btns.Count - 1 do
            Ids.Add((Btns.Items[k] AS TJSONObject).GetValue<Integer>('id'));
          EXIT(JoinSortedIds(Ids));
        end;
    finally
      FreeAndNil(Arr);
    end;
  finally
    FreeAndNil(Ids);
  end;
end;


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


{ Waits up to 5 s for the dialog with this caption; 0 when it never came up or the thread already ended. }
function WaitForDialog(const ACaption: String; ADone: TEvent): NativeUInt;
var
  BtnCount: Integer;
  Deadline: UInt64;
begin
  Result := 0;
  Deadline := TThread.GetTickCount64 + 5000;
  while (Result = 0) and (TThread.GetTickCount64 < Deadline) and (ADone.WaitFor(0) <> wrSignaled) do
    begin
      Result := FindDialogByCaption(ACaption, BtnCount);
      if Result = 0 then TThread.Sleep(50);
    end;
end;


{ Closes a Task Dialog still up without the code under test: TDM_CLICK_BUTTON with an id the box really has (https://learn.microsoft.com/en-us/windows/win32/controls/tdm-click-button).
  Frees the thread only when the box is gone; otherwise leaves it parked (an untimed WaitFor in TThread.Destroy would hang the runner) and fails. }
procedure FinishTaskDlgThread(var ATh: TTaskDlgButtonsThread);
var
  Dlg: NativeUInt;
  BtnCount: Integer;
  Res: DWORD_PTR;
begin
  if ATh = NIL then EXIT;
  if ATh.Done.WaitFor(0) <> wrSignaled then
    begin
      Dlg := FindDialogByCaption(ATh.Caption, BtnCount);
      if Dlg <> 0
      then SendMessageTimeout(HWND(Dlg), TDM_CLICK_BUTTON, WPARAM(ATh.Ids[0]), 0, SMTO_ABORTIFHUNG, 2000, @Res);
      ATh.Done.WaitFor(2000);
    end;
  if ATh.Done.WaitFor(0) = wrSignaled
  then FreeAndNil(ATh)
  else Assert.Fail('the Task Dialog could not be closed; thread left parked to avoid an untimed WaitFor hang');
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
    Assert.AreEqual('BN_CLICKED', Via, 'expected the verified button-HWND dispatch path');

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
// ahead of substring it resolves to IDNO, finds no IDNO button and is refused, so the box stays
// up - exactly what we assert and then clean up.
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
    { This box has no No button, so the click is refused and the box stays up (the finally block below dismisses it with a real button). }
    Clicked := ClickNativeDialogButton(Junk, Dlg, 'no', ClickedId, ClickedCap, Resolved, Reason, Via);
    Assert.IsTrue(Th.Done.WaitFor(500) <> wrSignaled, 'selector ''no'' closed the box (returned ' + IntToStr(Th.Returned) + '): resolved by caption substring (Ignore) instead of role IDNO');
    Assert.IsFalse(Clicked, 'selector ''no'' answered clicked=true on a box with no No button (clickedId ' + IntToStr(ClickedId) + ', via ' + Via + ')');
    Assert.AreEqual('button_not_found', Reason, 'a role with no button of that id must be refused as button_not_found');
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


{ A Task Dialog draws its texts inside a DirectUIHWND window, with no Static child, so the Static walk alone answers text ''. }
procedure TNativeDialogTests.Test_TaskDialog_TextIsRead;
const
  UniqueCap = 'AP_TEST_TASKDIALOG_4410';
  MainText  = 'AP main instruction 4410';
  BodyText  = 'AP content text 4410';
var
  Th: TTaskDlgThread;
  Dlg: NativeUInt;
  BtnCount: Integer;
  Text, Classes: String;
  Deadline: UInt64;
  Res: DWORD_PTR;
begin
  Dlg := 0;
  Th := TTaskDlgThread.Create(UniqueCap, MainText, BodyText);
  try
    BtnCount := 0;
    Deadline := TThread.GetTickCount64 + 5000;
    while (Dlg = 0) and (TThread.GetTickCount64 < Deadline) and (Th.Done.WaitFor(0) <> wrSignaled) do
      begin
        Dlg := FindDialogByCaption(UniqueCap, BtnCount);
        if Dlg = 0 then TThread.Sleep(50);
      end;
    Assert.IsTrue(Dlg <> 0, 'the Task Dialog was not found by EnumerateNativeDialogs (TaskDialogIndirect returned ' + IntToStr(Th.Returned) + ')');
    Classes := DescendantClasses(HWND(Dlg));
    Text := DialogTextByCaption(UniqueCap);
    Assert.Contains(Text, MainText, FALSE, 'the main instruction is missing from text; descendants: ' + Classes);
    Assert.Contains(Text, BodyText, FALSE, 'the content is missing from text; descendants: ' + Classes);
  finally
    { Closed without the code under test: TDM_CLICK_BUTTON with IDCANCEL, a button this box has. }
    if Th.Done.WaitFor(0) <> wrSignaled then
      begin
        if Dlg = 0
        then Dlg := FindDialogByCaption(UniqueCap, BtnCount);
        if Dlg <> 0
        then SendMessageTimeout(HWND(Dlg), TDM_CLICK_BUTTON, IDCANCEL, 0, SMTO_ABORTIFHUNG, 2000, @Res);
        Th.Done.WaitFor(2000);
      end;
    if Th.Done.WaitFor(0) = wrSignaled
    then FreeAndNil(Th)
    else Assert.Fail('the Task Dialog could not be dismissed; thread left parked to avoid an untimed WaitFor hang');
  end;
end;


{ Shows a Task Dialog of AThread, clicks ASelector, and checks that the box closed returning AExpectedId. }
procedure CheckTaskDialogClick(var ATh: TTaskDlgButtonsThread; const ASelector: String; AExpectedId: Integer);
var
  Dlg, Resolved: NativeUInt;
  ClickedId: Integer;
  ClickedCap, Reason, Via: String;
  Clicked: Boolean;
  Junk: TArray<NativeUInt>;
begin
  Junk := nil;
  Dlg := WaitForDialog(ATh.Caption, ATh.Done);
  Assert.IsTrue(Dlg <> 0, 'the Task Dialog was not found (TaskDialogIndirect returned ' + IntToStr(ATh.Returned) + ')');
  Clicked := ClickNativeDialogButton(Junk, Dlg, ASelector, ClickedId, ClickedCap, Resolved, Reason, Via);
  Assert.IsTrue(Clicked, 'ClickNativeDialogButton returned false (' + Reason + ') for selector ' + ASelector);
  Assert.IsTrue(ATh.Done.WaitFor(3000) = wrSignaled, 'the Task Dialog did not close after the click on ' + ASelector + ' (via ' + Via + ')');
  Assert.AreEqual(AExpectedId, ATh.Returned,
    'the Task Dialog returned the wrong button for selector ' + ASelector + ': via ' + Via + ', clickedId ' + IntToStr(ClickedId) +
    ', clickedCaption ' + ClickedCap + ', TDN_BUTTON_CLICKED id ' + IntToStr(ATh.NotifiedId));
end;


{ Shows a Task Dialog of AThread, clicks ASelector, and checks that the click was refused with AExpectedReason and the box is still up. }
procedure CheckTaskDialogRefused(var ATh: TTaskDlgButtonsThread; const ASelector, AExpectedReason: String);
var
  Dlg, Resolved: NativeUInt;
  ClickedId: Integer;
  ClickedCap, Reason, Via: String;
  Clicked: Boolean;
  Junk: TArray<NativeUInt>;
begin
  Junk := nil;
  Dlg := WaitForDialog(ATh.Caption, ATh.Done);
  Assert.IsTrue(Dlg <> 0, 'the Task Dialog was not found (TaskDialogIndirect returned ' + IntToStr(ATh.Returned) + ')');
  Clicked := ClickNativeDialogButton(Junk, Dlg, ASelector, ClickedId, ClickedCap, Resolved, Reason, Via);
  Assert.IsTrue(ATh.Done.WaitFor(500) <> wrSignaled,
    'the Task Dialog closed (returned ' + IntToStr(ATh.Returned) + ') for selector ' + ASelector + ', which names no button for sure (via ' + Via + ')');
  Assert.IsFalse(Clicked, 'ClickNativeDialogButton answered clicked=true for selector ' + ASelector + ' (via ' + Via + ', clickedId ' + IntToStr(ClickedId) + ')');
  Assert.AreEqual(AExpectedReason, Reason, 'wrong refusal reason for selector ' + ASelector);
end;


procedure TNativeDialogTests.Test_TaskDialog_MessageDlgButtons_ReturnsThatButton(const ASelector: String; AExpectedId: Integer);
var
  Th: TTaskDlgButtonsThread;
begin
  Th := TTaskDlgButtonsThread.Create('AP_TEST_X1_MSGDLG_' + ASelector, ['Yes', 'No', 'Abort'], [IDYES, IDNO, IDABORT], IDYES);
  try
    CheckTaskDialogClick(Th, ASelector, AExpectedId);
  finally
    FinishTaskDlgThread(Th);
  end;
end;


procedure TNativeDialogTests.Test_TaskDialog_DefaultIsNo_ReturnsThatButton(const ASelector: String; AExpectedId: Integer);
var
  Th: TTaskDlgButtonsThread;
begin
  Th := TTaskDlgButtonsThread.Create('AP_TEST_X1_DEFNO_' + ASelector, ['Yes', 'No', 'Abort'], [IDYES, IDNO, IDABORT], IDNO);
  try
    CheckTaskDialogClick(Th, ASelector, AExpectedId);
  finally
    FinishTaskDlgThread(Th);
  end;
end;


procedure TNativeDialogTests.Test_TaskDialog_LocalizedCaption_ReturnsThatButton(const ASelector: String; AExpectedId: Integer);
var
  Th: TTaskDlgButtonsThread;
begin
  Th := TTaskDlgButtonsThread.Create('AP_TEST_X1_DE_' + ASelector, ['Ja', 'Nein', 'Abbrechen'], [IDYES, IDNO, IDABORT], IDYES);
  try
    CheckTaskDialogClick(Th, ASelector, AExpectedId);
  finally
    FinishTaskDlgThread(Th);
  end;
end;


procedure TNativeDialogTests.Test_TaskDialog_LocalizedCaption_UnresolvableSelector_IsRefused(const ASelector, AExpectedReason: String);
var
  Th: TTaskDlgButtonsThread;
begin
  Th := TTaskDlgButtonsThread.Create('AP_TEST_X1_DEREF_' + ASelector, ['Ja', 'Nein', 'Abbrechen'], [IDYES, IDNO, IDABORT], IDYES);
  try
    CheckTaskDialogRefused(Th, ASelector, AExpectedReason);
  finally
    FinishTaskDlgThread(Th);
  end;
end;


procedure TNativeDialogTests.Test_TaskDialog_SubstringOnTwoButtons_IsRefused;
const
  mrNoToAll  = 13;   // System.UITypes: mrAll = mrContinue + 1 = 12, mrNoToAll = 13, mrYesToAll = 14
  mrYesToAll = 14;
var
  Th: TTaskDlgButtonsThread;
begin
  Th := TTaskDlgButtonsThread.Create('AP_TEST_X1_TOALL', ['Yes to All', 'No to All', 'Cancel'], [mrYesToAll, mrNoToAll, IDCANCEL], mrNoToAll);
  try
    CheckTaskDialogRefused(Th, 'all', 'button_ambiguous');
  finally
    FinishTaskDlgThread(Th);
  end;
end;


procedure TNativeDialogTests.Test_TaskDialog_CommonButtons_ReturnsThatButton(const ASelector: String; AExpectedId: Integer);
var
  Th: TTaskDlgThread;
  Dlg, Resolved: NativeUInt;
  BtnCount, ClickedId: Integer;
  ClickedCap, Reason, Via, Cap: String;
  Clicked: Boolean;
  Junk: TArray<NativeUInt>;
  Res: DWORD_PTR;
begin
  Junk := nil;
  Cap := 'AP_TEST_X1_COMMON_' + ASelector;
  Th := TTaskDlgThread.Create(Cap, 'Common buttons', 'OK and Cancel are TDCBF common buttons.');
  try
    Dlg := WaitForDialog(Cap, Th.Done);
    Assert.IsTrue(Dlg <> 0, 'the Task Dialog was not found (TaskDialogIndirect returned ' + IntToStr(Th.Returned) + ')');
    Clicked := ClickNativeDialogButton(Junk, Dlg, ASelector, ClickedId, ClickedCap, Resolved, Reason, Via);
    Assert.IsTrue(Clicked, 'ClickNativeDialogButton returned false (' + Reason + ') for selector ' + ASelector);
    Assert.IsTrue(Th.Done.WaitFor(3000) = wrSignaled, 'the Task Dialog did not close after the click on ' + ASelector);
    Assert.AreEqual(AExpectedId, Th.Returned, 'the Task Dialog returned the wrong button for selector ' + ASelector + ' (clickedCaption ' + ClickedCap + ')');
  finally
    { Closed without the code under test: TDM_CLICK_BUTTON with IDCANCEL, a button this box has. }
    if Th.Done.WaitFor(0) <> wrSignaled then
      begin
        Dlg := FindDialogByCaption(Cap, BtnCount);
        if Dlg <> 0
        then SendMessageTimeout(HWND(Dlg), TDM_CLICK_BUTTON, IDCANCEL, 0, SMTO_ABORTIFHUNG, 2000, @Res);
        Th.Done.WaitFor(2000);
      end;
    if Th.Done.WaitFor(0) = wrSignaled
    then FreeAndNil(Th)
    else Assert.Fail('the Task Dialog could not be dismissed; thread left parked to avoid an untimed WaitFor hang');
  end;
end;


procedure TNativeDialogTests.Test_MessageBox_YesNoCancel_ReturnsThatButton(const ASelector: String; AExpectedId: Integer);
var
  Th: TMsgBoxThread;
  Dlg, Resolved: NativeUInt;
  ClickedId: Integer;
  ClickedCap, Reason, Via: String;
  Clicked: Boolean;
  Junk: TArray<NativeUInt>;
begin
  Junk := nil;
  Dlg := 0;
  Th := TMsgBoxThread.Create('AP_TEST_X1_MSGBOX_' + ASelector, MB_YESNOCANCEL or MB_ICONQUESTION);
  try
    Dlg := WaitForDialog(Th.Caption, Th.Done);
    Assert.IsTrue(Dlg <> 0, 'native MessageBox was not found by EnumerateNativeDialogs');
    Clicked := ClickNativeDialogButton(Junk, Dlg, ASelector, ClickedId, ClickedCap, Resolved, Reason, Via);
    Assert.IsTrue(Clicked, 'ClickNativeDialogButton returned false (' + Reason + ')');
    Assert.AreEqual('BN_CLICKED', Via, 'expected the button-HWND dispatch path');
    Assert.IsTrue(Th.Done.WaitFor(3000) = wrSignaled, 'MessageBox did not close after the click');
    Assert.AreEqual(AExpectedId, Th.Returned, 'MessageBox returned the wrong button for selector ' + ASelector);
  finally
    { Closed without the code under test: WM_COMMAND IDCANCEL with the Cancel button's own window, the notification a click on it sends. }
    if (Th.Done.WaitFor(0) <> wrSignaled) and (Dlg <> 0) then
      begin
        SendMessageTimeout(HWND(Dlg), WM_COMMAND, WPARAM(IDCANCEL or (BN_CLICKED shl 16)), LPARAM(GetDlgItem(HWND(Dlg), IDCANCEL)), SMTO_ABORTIFHUNG, 2000, nil);
        Th.Done.WaitFor(2000);
      end;
    if Th.Done.WaitFor(0) = wrSignaled
    then FreeAndNil(Th)
    else Assert.Fail('MessageBox could not be dismissed; thread left parked to avoid an untimed WaitFor hang');
  end;
end;


procedure TNativeDialogTests.Test_FileSaveDialog_FileNameAndSave_ReturnsThatName;
var
  Th: TFileDlgThread;
  Dlg, Resolved: NativeUInt;
  ClickedId: Integer;
  ClickedCap, Reason, Via, Name: String;
  Done, NameSet: Boolean;
  Junk: TArray<NativeUInt>;
begin
  Junk := nil;
  Dlg := 0;
  Name := NewTempFileName('SAVE');
  Th := TFileDlgThread.Create('AP_TEST_D3_SAVE_DIALOG');
  try
    Dlg := WaitForDialog(Th.Title, Th.Done);
    Assert.IsTrue(Dlg <> 0, 'the Save dialog was not found (Show returned $' + IntToHex(Th.Returned, 8) + ')');
    Done := SetNativeDialogFileName(Junk, Dlg, Name, 'ok', NameSet, ClickedId, ClickedCap, Resolved, Reason, Via);
    Assert.IsTrue(Done, 'SetNativeDialogFileName returned false (' + Reason + ')');
    Assert.IsTrue(NameSet, 'fileNameSet must be TRUE');
    Assert.AreEqual(IDOK, ClickedId, 'the click went to another button (' + ClickedCap + ')');
    Assert.IsTrue(Dlg = Resolved, 'resolved another dialog');
    Assert.IsTrue(Th.Done.WaitFor(3000) = wrSignaled, 'the Save dialog did not close after the click on ' + ClickedCap);
    Assert.AreEqual(S_OK, Th.Returned, 'Show did not return S_OK: the dialog was cancelled or failed');
    Assert.AreEqual(Name, Th.ResultPath, 'the dialog returned another file name');
  finally
    FinishByCancel(Th, Th.Done, Dlg);
  end;
end;


procedure TNativeDialogTests.Test_FileSaveDialog_FileNameOnly_LeavesTheDialogUp_ThenSaveReturnsThatName;
var
  Th: TFileDlgThread;
  Dlg, Resolved: NativeUInt;
  ClickedId: Integer;
  ClickedCap, Reason, Via, Name: String;
  Done, NameSet: Boolean;
  Junk: TArray<NativeUInt>;
begin
  Junk := nil;
  Dlg := 0;
  Name := NewTempFileName('ONLY');
  Th := TFileDlgThread.Create('AP_TEST_D3_NAME_ONLY_DIALOG');
  try
    Dlg := WaitForDialog(Th.Title, Th.Done);
    Assert.IsTrue(Dlg <> 0, 'the Save dialog was not found (Show returned $' + IntToHex(Th.Returned, 8) + ')');
    Done := SetNativeDialogFileName(Junk, Dlg, Name, '', NameSet, ClickedId, ClickedCap, Resolved, Reason, Via);
    Assert.IsTrue(Done, 'SetNativeDialogFileName returned false (' + Reason + ')');
    Assert.IsTrue(NameSet, 'fileNameSet must be TRUE');
    Assert.IsTrue(Dlg = Resolved, 'resolved another dialog');
    Assert.IsTrue(Th.Done.WaitFor(500) <> wrSignaled, 'the dialog closed although no button was asked for');

    { The box kept the name: the plain click returns it. }
    Assert.IsTrue(ClickNativeDialogButton(Junk, Dlg, 'ok', ClickedId, ClickedCap, Resolved, Reason, Via), 'the click on ok failed (' + Reason + ')');
    Assert.IsTrue(Th.Done.WaitFor(3000) = wrSignaled, 'the Save dialog did not close after the click on ' + ClickedCap);
    Assert.AreEqual(S_OK, Th.Returned, 'Show did not return S_OK: the dialog was cancelled or failed');
    Assert.AreEqual(Name, Th.ResultPath, 'the dialog returned another file name');
  finally
    FinishByCancel(Th, Th.Done, Dlg);
  end;
end;


procedure TNativeDialogTests.Test_MessageBox_FileName_IsRefused_NothingClicked;
var
  Th: TMsgBoxThread;
  Dlg, Resolved: NativeUInt;
  ClickedId: Integer;
  ClickedCap, Reason, Via: String;
  Done, NameSet: Boolean;
  Junk: TArray<NativeUInt>;
begin
  Junk := nil;
  Dlg := 0;
  Th := TMsgBoxThread.Create('AP_TEST_D3_MSGBOX', MB_YESNOCANCEL or MB_ICONQUESTION);
  try
    Dlg := WaitForDialog(Th.Caption, Th.Done);
    Assert.IsTrue(Dlg <> 0, 'native MessageBox was not found by EnumerateNativeDialogs');
    Done := SetNativeDialogFileName(Junk, Dlg, 'x.txt', 'yes', NameSet, ClickedId, ClickedCap, Resolved, Reason, Via);
    Assert.IsTrue(Th.Done.WaitFor(500) <> wrSignaled, 'the box closed (returned ' + IntToStr(Th.Returned) + '): a button was clicked although the name could not be set');
    Assert.IsFalse(Done, 'answered done for a box with no File name box');
    Assert.IsFalse(NameSet, 'fileNameSet must be FALSE');
    Assert.AreEqual('edit_not_found', Reason, 'wrong refusal reason');
  finally
    FinishByCancel(Th, Th.Done, Dlg);
  end;
end;


procedure TNativeDialogTests.Test_NoDialogUp_FileNameReturnsNoDialog;
var
  ClickedId: Integer;
  ClickedCap, Reason, Via: String;
  Resolved: NativeUInt;
  NameSet: Boolean;
  NoExclude: TArray<NativeUInt>;
begin
  NoExclude := nil;
  Assert.IsFalse(SetNativeDialogFileName(NoExclude, 0, 'x.txt', 'ok', NameSet, ClickedId, ClickedCap, Resolved, Reason, Via), 'must fail when no dialog is up');
  Assert.IsFalse(NameSet, 'fileNameSet must be FALSE');
  Assert.AreEqual('no_dialog', Reason, 'expected reason no_dialog');
end;


procedure TNativeDialogTests.Test_FileDialog_HiddenButtons_AreNotListed(const AKind: String);
var
  Th: TFileDlgThread;
  Dlg: NativeUInt;
  Visible, Hidden: String;
begin
  Dlg := 0;
  Th := TFileDlgThread.Create('AP_TEST_HIDDEN_LIST_' + AKind, SameText(AKind, 'Open'));
  try
    Dlg := WaitForDialog(Th.Title, Th.Done);
    Assert.IsTrue(Dlg <> 0, 'the ' + AKind + ' dialog was not found (Show returned $' + IntToHex(Th.Returned, 8) + ')');
    ButtonIdsOf(HWND(Dlg), Visible, Hidden);
    Assert.IsTrue(Hidden <> '', 'the ' + AKind + ' dialog holds no hidden Button window, so this test proves nothing; descendants: ' + DescendantClasses(HWND(Dlg)));
    Assert.AreEqual(Visible, ListedButtonIds(Th.Title), 'the list must hold exactly the visible buttons of the ' + AKind + ' dialog (hidden ids: ' + Hidden + ')');
  finally
    FinishByCancel(Th, Th.Done, Dlg);
  end;
end;


procedure TNativeDialogTests.Test_FileDialog_HiddenButtons_AreNotClicked_CancelStillIs(const AKind: String);
var
  Th: TFileDlgThread;
  Dlg, Resolved: NativeUInt;
  ClickedId: Integer;
  ClickedCap, Reason, Via, Visible, Hidden, Sel: String;
  Selectors: TArray<String>;
  Clicked: Boolean;
  Junk: TArray<NativeUInt>;
begin
  Junk := nil;
  Dlg := 0;
  Th := TFileDlgThread.Create('AP_TEST_HIDDEN_CLICK_' + AKind, SameText(AKind, 'Open'));
  try
    Dlg := WaitForDialog(Th.Title, Th.Done);
    Assert.IsTrue(Dlg <> 0, 'the ' + AKind + ' dialog was not found (Show returned $' + IntToHex(Th.Returned, 8) + ')');
    ButtonIdsOf(HWND(Dlg), Visible, Hidden);
    Assert.IsTrue(Pos(',1038,', ',' + Hidden + ',') > 0, 'the ' + AKind + ' dialog holds no hidden Help button (id 1038), so this test proves nothing; hidden ids: ' + Hidden + '; visible ids: ' + Visible);

    { # The hidden buttons }
    { The hidden Help button by caption and by id, then on Save the hidden caption-less id 0.
      Id 0 comes last: where hidden buttons are matched, 'Help' and '1038' stop at button_disabled and send nothing, while id 0 sends a real click to a hidden button. }
    Selectors := ['Help', '1038'];
    if not SameText(AKind, 'Open')
    then Selectors := Selectors + ['0'];
    for Sel in Selectors do
      begin
        Clicked := ClickNativeDialogButton(Junk, Dlg, Sel, ClickedId, ClickedCap, Resolved, Reason, Via);
        Assert.AreEqual('button_not_found', Reason, 'selector ' + Sel + ' must name no button of the ' + AKind + ' dialog: a hidden button is not one a person can click (clicked ' + BoolToStr(Clicked, TRUE) + ', clickedId ' + IntToStr(ClickedId) + ')');
        Assert.IsFalse(Clicked, 'selector ' + Sel + ' answered clicked=true');
        Assert.IsTrue(Th.Done.WaitFor(300) <> wrSignaled, 'the ' + AKind + ' dialog closed after selector ' + Sel + ' (Show returned $' + IntToHex(Th.Returned, 8) + ')');
      end;

    { # A visible button still resolves }
    Clicked := ClickNativeDialogButton(Junk, Dlg, 'cancel', ClickedId, ClickedCap, Resolved, Reason, Via);
    Assert.IsTrue(Clicked, 'the click on cancel failed (' + Reason + ')');
    Assert.IsTrue(Th.Done.WaitFor(3000) = wrSignaled, 'the ' + AKind + ' dialog did not close after the click on ' + ClickedCap);
    Assert.AreEqual(HResultFromWin32(ERROR_CANCELLED), Th.Returned, 'Show must answer "cancelled" after the click on Cancel');
  finally
    FinishByCancel(Th, Th.Done, Dlg);
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
