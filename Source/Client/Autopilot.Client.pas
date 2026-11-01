unit Autopilot.Client;

{=============================================================================================================
   2026.10.13
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - Delphi client for the Autopilot bridge: a DUnitX test (or a DUnit test, or a console program) drives a running VCL or FMX app with no AI.
     TAutopilotApp starts the app (Start) or finds a running one (Attach), sends one bridge command per call and turns an error answer into an exception
   - One pipe connection per command: open, hello/helloAck, one request, one answer, close.
     Every read and write has a deadline (the command's timeout + IoDeadlineGraceMs), so a frozen app fails the call instead of hanging the test run
   - Never call it from the main thread of the process whose bridge answers: the bridge runs every command on that main thread, so the call would wait for itself.
     A separate test EXE is the normal case; a worker thread of the app's own process works too.
     A main-thread call to its own process raises EInvalidOpException
   - The test EXE and the app must run as the same Windows user: the bridge pipe accepts only its owner
   - One TAutopilotApp per thread.
     Windows only.
     No VCL, no FMX, no DUnitX
=============================================================================================================}

interface

uses
  Winapi.Windows,
  System.SysUtils, System.Classes, System.JSON,
  Autopilot.Bridge.Core;

const
  ClientStartTimeoutMs = 15000;   // Start: how long the app may take until its bridge writes the discovery file
  ClientCloseTimeoutMs = 5000;    // Close: how long the app may take to end after WM_CLOSE
  ClientWaitTimeoutMs  = 5000;    // WaitForText
  ClientPollIntervalMs = 100;     // WaitForText polls get_text this often
  ClientDialogTimeoutMs = 2000;   // DismissDialog: how long to wait for a dialog to appear

type
  { The bridge answered ok:false.
    Code: the error code of the answer (ErrNotFound -32001, ErrControlDisabled -32003, ErrMainThreadBlocked -32004, ErrUnsupportedAction -32005, ErrRttiPropertyMissing -32006, ErrInternalError -32603 ... in Autopilot.Bridge.Core).
    Data: error.data as JSON text, '' when absent (for a wrong property name: the availableProperties list).
    After -32004 the message also names the native dialogs that are open in the app, because a modal box is the usual reason for a blocked main thread.
    The client raises it itself with Code ErrProtocolMismatch (-32097) when the bridge speaks another protocol version or sends an answer that is not a JSON object with the request's id.
    A raising event handler or property setter that the bridge catches arrives as Code ErrInternalError (-32603): measured for execute_action (OnExecute), set_property (the setter) and set_checked (OnClick). }
  EAutopilotError = class(Exception)
  public
    Code: Integer;
    Data: String;
    constructor CreateCode(ACode: Integer; const AMessage: String; const AData: String = '');
  end;

  { Click only: the control's OnClick raised.
    The bridge caught the exception and answered ok with stoppedReason 'exception:<ClassName>'.
    Code is ErrInternalError (-32603); Data is the click answer as JSON text.
    Derived from EAutopilotError: DUnitX's Assert.WillRaise(..., EAutopilotError) wants the exact class, so use Assert.WillRaiseDescendant to accept both. }
  EAutopilotHandlerError = class(EAutopilotError);

  { Re-exported from Autopilot.Bridge.Core, so a test needs only this unit in its uses clause to catch them.
    ETargetNotRunning: there is no app to talk to - Start failed, no discovery file, the app ended, its pipe is gone.
    ETargetNotResponding: the app accepted the connection but did not answer in time, its pipe stayed busy, or Close had to kill it. }
  ETargetNotRunning    = Autopilot.Bridge.Core.ETargetNotRunning;
  ETargetNotResponding = Autopilot.Bridge.Core.ETargetNotResponding;

  { How Start shows the app's main window.
    swMinimizedNoFocus asks Windows for a start without the focus, but the app decides: measured 2026-10-13, the FMX demo held the foreground window for about 170 ms after Start, and the minimized VCL demo stayed the foreground window from Start until Close.
    So keys a person types during a test run can reach the app under test. }
  TStartWindow = (
    swMinimizedNoFocus,   // SW_SHOWMINNOACTIVE: minimized; the app may still take the foreground (see above)
    swNormal);            // SW_SHOWNORMAL: shown and activated, for an app that does not work when it starts minimized

  TAutopilotApp = class
  private
    FPid        : Cardinal;
    FPipeName   : String;
    FProcess    : THandle;    // 0 when not known
    FJob        : THandle;    // Start only: the job object that ends the app together with this process
    FStartedByUs: Boolean;
    FNextId     : Int64;
    function  ProcessEnded(OUT AExitInfo: String): Boolean;
    procedure CheckStillRunning;
    procedure RaiseConnectionClosed(const AWhat: String);
    function  OpenPipe(ATimeoutMs: Cardinal): THandle;
    procedure ReadHello(AStream: TStream);
    function  Exchange(const ACmd: String; AArgs: TJSONObject; ATimeoutMs: Cardinal): TJSONObject;
    function  Request(const ACmd: String; AArgs: TJSONObject; ATimeoutMs: Cardinal; AListDialogsWhenBlocked: Boolean): TJSONObject;
    procedure Send(const ACmd: String; AArgs: TJSONObject);
    function  RequestString(const ACmd: String; AArgs: TJSONObject; const AField: String; AListDialogsWhenBlocked: Boolean): String;
    function  OpenDialogsNote: String;
    function  DialogIsOpen(AHwnd: Int64): Boolean;
    function  WaitForDiscovery(const ADiscoveryFile, AExePath: String; ATimeoutMs: Cardinal): String;
    function  WaitForEnd(ATimeoutMs: Cardinal): Boolean;
    function  Kill: String;
    procedure DeleteDiscoveryFileIfEnded;
  protected
    { Aims the client at a known pipe.
      The client's own tests use it; Start and Attach build on it.
      APid: the process that owns the pipe; 0 = unknown (no liveness check while opening, no pid check of the hello). }
    constructor CreateForPipe(const APipeName: String; APid: Cardinal);
  public
    { Starts ExePath (a full path) in its own folder, with Params as its command line, and waits until its bridge writes %TEMP%\Autopilot\active\<pid>.pipe.
      The app joins a job object, so it ends together with the test EXE, however the test EXE ends.
      Window: swMinimizedNoFocus (default) or swNormal.
      Raises ETargetNotRunning when ExePath does not exist, when the app ends first (the message has its exit code), or after StartTimeoutMs (the message has the text of any dialog box the app shows, e.g. a startup error); in the last case the app is killed.
      In a DUnitX [SetupFixture] make Start the last statement: DUnitX runs no [TearDownFixture] after a setup that raised. }
    class function Start(const ExePath: String; const Params: String = ''; StartTimeoutMs: Cardinal = ClientStartTimeoutMs; Window: TStartWindow = swMinimizedNoFocus): TAutopilotApp;

    { Connects to a running app.
      Pid = 0 takes the only running target.
      Raises ETargetNotRunning when no target (or none with that pid) runs, and when Pid = 0 while several run (the message lists their pids). }
    class function Attach(Pid: Cardinal = 0): TAutopilotApp;

    { Never raises.
      Kills the app when Start started it and it still runs (call Close first for a clean end).
      An attached app keeps running. }
    destructor Destroy; override;

    { Posts WM_CLOSE to the app's TApplication (VCL) or TFMAppClass (FMX) window and waits until the app ends, so OnCloseQuery, OnClose and the bridge's own shutdown run.
      If the app still runs after TimeoutMs (a "Save changes?" box, a hang), Close kills it and raises ETargetNotResponding with the text of any dialog box it shows.
      Does nothing when the app has already ended. }
    procedure Close(TimeoutMs: Cardinal = ClientCloseTimeoutMs);

    { The commands.
      Path: 'Form', 'Form.Control' or 'Form.A.B' (the paths list_tree shows).
      Each one raises EAutopilotError when the bridge answers ok:false, ETargetNotResponding or ETargetNotRunning when the app cannot answer.
      Default timeouts (the bridge's own): 5000 ms for the commands that run event handlers, 30000 ms for Screenshot, 2000 ms for the rest.
      An event handler that raises (measured on the VCL bridge, 2026-10-13):
      - Click: EAutopilotHandlerError (the bridge catches the exception and reports stoppedReason).
      - ExecuteAction (OnExecute), SetProperty (the property setter), SetChecked (OnClick): EAutopilotError -32603.
      - SetText (OnChange of a TEdit) and SendKeys (OnKeyDown): NOT reported to the client.
        The exception is raised inside a window message, so the VCL hands it to Application.HandleException: the app's Application.OnException (or madExcept) sees it, and the command answers ok.
        With no handler the VCL shows its error box, which blocks the app's main thread, so a command then ends in -32004 and its message names the box [not measured].
        Check the effect of such a command with GetText. }

    { Returns clicksDispatched: less than Count when the control became disabled or was freed by a click.
      Raises EAutopilotHandlerError when OnClick raised.
      TimeoutMs = 0: 5000 ms + 100 ms per extra click.
      A short TimeoutMs + the -32004 it gives + DismissDialog is the modal-dialog recipe for FMX. }
    function  Click(const Path: String; Count: Integer = 1; TimeoutMs: Cardinal = 0): Integer;
    { click mode='message': returns before the click runs.
      For a VCL button-class control (TButton, TBitBtn, TCheckBox, TRadioButton) whose OnClick opens a modal dialog; then call DismissDialog.
      FMX answers -32005. }
    procedure ClickAsync(const Path: String);
    procedure SetText(const Path, Text: String);
    function  GetText(const Path: String): String;
    procedure SetChecked(const Path: String; Checked: Boolean);
    function  ReadProperty(const Path, PropName: String): String;
    procedure SetProperty(const Path, PropName, Value: String);
    { FALSE when the action has no OnExecute handler }
    function  ExecuteAction(const Path: String): Boolean;
    { Keys: chords separated by spaces ('Ctrl+S', 'Enter', 'Ctrl+A Delete').
      Text: typed one character at a time, before the keys.
      Path '' = the focused control of the active form. }
    procedure SendKeys(const Path, Keys: String; const Text: String = '');
    { Clicks a button of a native dialog (MessageBox, ShowMessage, MessageDlg, a file dialog): Button is a role ('ok', 'cancel', 'yes', 'no', 'retry', 'abort', 'ignore', 'close'), a button caption or a control id.
      Waits for the dialog: while the bridge answers that no dialog is open (reason 'no_dialog'), it asks again every 50 ms until TimeoutMs has passed.
      Needed after ClickAsync, which returns before the click runs, so the dialog the click opens may not exist yet (measured: 1 ms after ClickAsync it did not).
      TRUE only when the dialog is gone: the bridge clicked the button's own window (BM_CLICK), or, after a blind WM_COMMAND, the dialog left the list within 1000 ms.
      FALSE when no dialog appeared within TimeoutMs, at once when the open dialog has no such button or the click was not delivered, and when the dialog stayed. }
    function  DismissDialog(const Button: String; TimeoutMs: Cardinal = ClientDialogTimeoutMs): Boolean;
    { Saves a PNG of a form ('frmMain') or of one control ('frmMain.pnlTop'). Path '' = the main form. }
    procedure Screenshot(const Path, PngFileName: String);
    { Polls get_text every ClientPollIntervalMs until the text equals Expected (TRUE) or TimeoutMs passes (FALSE).
      An error answer (a control that does not exist yet) does not end the wait; ETargetNotRunning, ETargetNotResponding and a protocol mismatch end it at once. }
    function  WaitForText(const Path, Expected: String; TimeoutMs: Cardinal = ClientWaitTimeoutMs): Boolean;
    { Any bridge command.
      Args is consumed (Call frees it, also when it raises); NIL = no arguments.
      Returns the answer's 'result' object, which the caller frees.
      Raises like the commands above, but checks no stoppedReason. }
    function  Call(const Cmd: String; Args: TJSONObject; TimeoutMs: Cardinal = 0): TJSONObject;

    property Pid: Cardinal read FPid;
  end;


implementation

uses
  Winapi.Messages,   // WM_CLOSE, WM_GETTEXT, WM_GETTEXTLENGTH
  System.Types, System.IOUtils, System.Generics.Collections, System.NetEncoding, System.Diagnostics,
  Autopilot.Bridge.Log;

const
  LogTag               = 'client';
  PipeRetryMs          = 25;     // between two tries to open a pipe that does not exist (yet), or to find the discovery file
  BusyWaitSliceMs      = 100;    // the longest WaitNamedPipe on a busy pipe before the next liveness check
  RecreateYieldMs      = 5;      // after a busy pipe vanished: retry the open with SwitchToThread this long, then sleep
  DialogProbeTimeoutMs = 1000;   // the dialog list after a -32004: the main thread may still be blocked
  DialogGoneTimeoutMs  = 1000;   // DismissDialog: how long a blind (WM_COMMAND) click may take to close the dialog
  DialogPollMs         = 50;     // DismissDialog: between two tries while no dialog is open yet
  KillWaitMs           = 2000;
  MaxClickCount        = 1000;   // the bridge's cap on click count
  PerClickBudgetMs     = 100;
  TextReadTimeoutMs    = 1000;


{ EAutopilotError ---------------------------------------------------------- }

constructor EAutopilotError.CreateCode(ACode: Integer; const AMessage, AData: String);
begin
  inherited Create(AMessage);
  Code := ACode;
  Data := AData;
end;


{ JSON helpers ------------------------------------------------------------- }

function JsonStr(AObj: TJSONObject; const AName: String): String;
var
  V: TJSONValue;
begin
  V := AObj.GetValue(AName);
  if V is TJSONString
  then Result := TJSONString(V).Value
  else Result := '';
end;


function JsonBool(AObj: TJSONObject; const AName: String): Boolean;
var
  V: TJSONValue;
begin
  V := AObj.GetValue(AName);
  Result := (V is TJSONBool) and TJSONBool(V).AsBoolean;
end;


function NewArgs(const APath: String): TJSONObject;
begin
  Result := TJSONObject.Create;
  if APath <> ''
  then Result.AddPair('path', APath);
end;


{ The bridge's per-command timeouts.
  They are decided in Autopilot.Bridge.Worker (ServeOneRequest); the client sends the value in every request and builds its own deadline from the same number. }
function DefaultTimeoutFor(const ACmd: String): Cardinal;
begin
  if (ACmd = 'click') or (ACmd = 'set_text') or (ACmd = 'set_checked') or (ACmd = 'set_property') or (ACmd = 'execute_action') or (ACmd = 'dismiss_dialog') or (ACmd = 'send_keys')
  then Result := DefaultTimeoutClickMs
  else
    if ACmd = 'screenshot'
    then Result := DefaultTimeoutScreenshotMs
    else Result := DefaultTimeoutListMs;
end;


// The I/O deadline: the command's timeout + IoDeadlineGraceMs, kept below INFINITE
function DeadlineFor(ATimeoutMs: Cardinal): Cardinal;
begin
  if ATimeoutMs >= High(Cardinal) - IoDeadlineGraceMs
  then Result := High(Cardinal) - 1
  else Result := ATimeoutMs + IoDeadlineGraceMs;
end;


{ Discovery ---------------------------------------------------------------- }

function DiscoveryFolderPath: String;
begin
  Result := TPath.Combine(TPath.GetTempPath, 'Autopilot\active');
end;


function DiscoveryFileOf(APid: Cardinal): String;
begin
  Result := TPath.Combine(DiscoveryFolderPath, UIntToStr(APid) + '.pipe');
end;


function IsPidAlive(APid: Cardinal): Boolean;
var
  H: THandle;
begin
  if APid = 0 then EXIT(FALSE);
  H := OpenProcess(SYNCHRONIZE, FALSE, APid);
  { ERROR_INVALID_PARAMETER (87) is what Windows answers when no process has this pid - the only failure that means dead.
    Anything else (ERROR_ACCESS_DENIED, 5) means a process with that pid exists but may not be opened: reporting it dead would delete a live target's discovery file, which its bridge writes only once.
    Measured 2026-08-11: a free pid gives 87, a live SYSTEM-owned process gives 5. }
  if H = 0 then EXIT(GetLastError <> ERROR_INVALID_PARAMETER);
  try
    { A zero-timeout wait is the unambiguous liveness probe: an exit code of 259 (STILL_ACTIVE) cannot fool it.
      "<> WAIT_OBJECT_0", not "= WAIT_TIMEOUT": an unexpected WAIT_FAILED errs on alive. }
    Result := WaitForSingleObject(H, 0) <> WAIT_OBJECT_0;
  finally
    CloseHandle(H);
  end;
end;


{ Reads the pipe name from a discovery file.
  FALSE when the file cannot be read now (the caller tries again later) or is empty.
  The bridge writes the file through a rename, so a failed read is a race with a delete. }
function TryReadPipeName(const AFile: String; OUT APipeName: String): Boolean;
var
  Stream: TFileStream;
  Bytes: TBytes;
  Encoding: TEncoding;
  BomLength: Integer;
begin
  APipeName := '';
  try
    Stream := TFileStream.Create(AFile, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Bytes, Integer(Stream.Size));   // a discovery file holds one pipe name
      if Length(Bytes) > 0
      then Stream.ReadBuffer(Bytes[0], Length(Bytes));
    finally
      FreeAndNil(Stream);
    end;
  except
    on E: EFOpenError do
      begin
        BridgeLogWarn(LogTag, 'cannot read ' + AFile + ': ' + E.Message);
        EXIT(FALSE);
      end;
    on E: EReadError do
      begin
        BridgeLogWarn(LogTag, 'cannot read ' + AFile + ': ' + E.Message);
        EXIT(FALSE);
      end;
  end;
  Encoding := NIL;
  BomLength := TEncoding.GetBufferEncoding(Bytes, Encoding, TEncoding.UTF8);   // the bridge may write a UTF-8 BOM
  APipeName := Trim(Encoding.GetString(Bytes, BomLength, Length(Bytes) - BomLength));
  Result := APipeName <> '';
end;


type
  TTargetEntry = record
    Pid     : Cardinal;
    PipeName: String;
  end;


{ The live targets in the discovery folder. A file whose process has ended is stale (StopBridge never ran): it is deleted. }
function ListTargets: TArray<TTargetEntry>;
var
  Files: TStringDynArray;   // the exact type TDirectory.GetFiles returns; older compilers do not accept TArray<String> here
  i: Integer;
  Entry: TTargetEntry;
  PipeName: String;
  PidVal: Cardinal;
  Acc: TList<TTargetEntry>;
begin
  Result := NIL;
  if not TDirectory.Exists(DiscoveryFolderPath) then EXIT;
  Acc := TList<TTargetEntry>.Create;
  try
    Files := TDirectory.GetFiles(DiscoveryFolderPath, '*.pipe');
    for i := 0 to High(Files) do
      begin
        if not TryStrToUInt(TPath.GetFileNameWithoutExtension(Files[i]), PidVal) then Continue;
        if not IsPidAlive(PidVal) then
          begin
            if not System.SysUtils.DeleteFile(Files[i])
            then BridgeLogWarn(LogTag, 'cannot delete the stale discovery file ' + Files[i] + ': ' + SysErrorMessage(GetLastError));
            Continue;
          end;
        if not TryReadPipeName(Files[i], PipeName) then Continue;
        Entry.Pid      := PidVal;
        Entry.PipeName := PipeName;
        Acc.Add(Entry);
      end;
    Result := Acc.ToArray;
  finally
    FreeAndNil(Acc);
  end;
end;


{ Windows of a process ----------------------------------------------------- }

function ClassNameOf(AWnd: HWND): String;
var
  Buf: array[0..255] of Char;
  N: Integer;
begin
  N := GetClassName(AWnd, Buf, Length(Buf));
  SetString(Result, Buf, N);
end;


{ The text of a window of another process. SendMessageTimeout with SMTO_ABORTIFHUNG: a hung app must not hang the test. }
function WindowTextOf(AWnd: HWND): String;
var
  Len, Copied: DWORD_PTR;
begin
  Result := '';
  Len := 0;
  if SendMessageTimeout(AWnd, WM_GETTEXTLENGTH, 0, 0, SMTO_ABORTIFHUNG, TextReadTimeoutMs, @Len) = 0 then EXIT;
  if Len = 0 then EXIT;
  SetLength(Result, Integer(Len));
  Copied := 0;
  // wParam counts the terminating null too; String[Len] has an implicit #0 slot beyond Len
  if SendMessageTimeout(AWnd, WM_GETTEXT, WPARAM(Len) + 1, LPARAM(PChar(Result)), SMTO_ABORTIFHUNG, TextReadTimeoutMs, @Copied) = 0 then EXIT('');
  SetLength(Result, Integer(Copied));
end;


type
  { What one EnumWindows pass finds for one process }
  TWindowScan = class
  public
    Pid      : DWORD;
    AppWindow: HWND;          // the first TApplication (VCL) or TFMAppClass (FMX) window
    Boxes    : TStringList;   // the text of each #32770 dialog box
    constructor Create(APid: DWORD);
    destructor Destroy; override;
  end;


constructor TWindowScan.Create(APid: DWORD);
begin
  inherited Create;
  Pid   := APid;
  Boxes := TStringList.Create;
end;


destructor TWindowScan.Destroy;
begin
  FreeAndNil(Boxes);
  inherited;
end;


function CollectStaticText(AWnd: HWND; AParam: LPARAM): BOOL; stdcall;
var
  S: String;
begin
  Result := TRUE;
  if not SameText(ClassNameOf(AWnd), 'Static') then EXIT;
  S := Trim(WindowTextOf(AWnd));
  if S <> ''
  then TStringList(Pointer(AParam)).Add(S);
end;


// '"Caption: text"' of a dialog box: its caption and the text of its Static controls
function DialogBoxText(AWnd: HWND): String;
var
  Lines: TStringList;
  i: Integer;
begin
  Lines := TStringList.Create;
  try
    EnumChildWindows(AWnd, @CollectStaticText, LPARAM(Lines));
    Result := '"' + Trim(WindowTextOf(AWnd));
    for i := 0 to Lines.Count - 1 do
      begin
        if i = 0
        then Result := Result + ': '
        else Result := Result + ' ';
        Result := Result + StringReplace(Lines[i], sLineBreak, ' ', [rfReplaceAll]);
      end;
    Result := Result + '"';
  finally
    FreeAndNil(Lines);
  end;
end;


function ScanTopWindow(AWnd: HWND; AParam: LPARAM): BOOL; stdcall;
var
  Scan: TWindowScan;
  WndPid: DWORD;
  Cls: String;
begin
  Result := TRUE;
  Scan := TWindowScan(Pointer(AParam));
  WndPid := 0;
  GetWindowThreadProcessId(AWnd, WndPid);
  if WndPid <> Scan.Pid then EXIT;
  Cls := ClassNameOf(AWnd);
  if Cls = '#32770'
  then Scan.Boxes.Add(DialogBoxText(AWnd))
  else
    if (Scan.AppWindow = 0) and ((Cls = 'TApplication') or (Cls = 'TFMAppClass'))
    then Scan.AppWindow := AWnd;
end;


// The top-level windows of APid. The caller frees the result.
function ScanWindowsOf(APid: DWORD): TWindowScan;
begin
  Result := TWindowScan.Create(APid);
  EnumWindows(@ScanTopWindow, LPARAM(Result));
end;


// '. Dialog boxes the app shows: "...", "..."', or '' when it shows none
function DialogBoxesNote(APid: DWORD): String;
var
  Scan: TWindowScan;
  i: Integer;
begin
  Result := '';
  Scan := ScanWindowsOf(APid);
  try
    for i := 0 to Scan.Boxes.Count - 1 do
      begin
        if i = 0
        then Result := '. Dialog boxes the app shows: '
        else Result := Result + ', ';
        Result := Result + Scan.Boxes[i];
      end;
  finally
    FreeAndNil(Scan);
  end;
end;


// The open native dialogs in a dismiss_dialog answer, as '"Caption: text", ...'; '' when none
function DescribeDialogs(AResult: TJSONObject): String;
var
  V: TJSONValue;
  Arr: TJSONArray;
  Item: TJSONObject;
  i: Integer;
begin
  Result := '';
  V := AResult.GetValue('dialogs');
  if not (V is TJSONArray) then EXIT;
  Arr := TJSONArray(V);
  for i := 0 to Arr.Count - 1 do
    if Arr.Items[i] is TJSONObject then
      begin
        Item := TJSONObject(Arr.Items[i]);
        if Result <> ''
        then Result := Result + ', ';
        Result := Result + '"' + JsonStr(Item, 'caption');
        if JsonStr(Item, 'text') <> ''
        then Result := Result + ': ' + JsonStr(Item, 'text');
        Result := Result + '"';
      end;
end;


{ The pipe stream ---------------------------------------------------------- }

type
  { THandleStream cannot serve an overlapped pipe handle (its ReadFile passes no OVERLAPPED, which is invalid on a FILE_FLAG_OVERLAPPED handle).
    This stream does the same job with a deadline per operation: each Read/Write is an overlapped I/O plus an event wait; when the deadline passes, the operation is cancelled (CancelIoEx) and ETargetNotResponding raised, so a frozen app (a breakpoint, a hang) cannot block the caller for ever.
    It does not own the pipe handle: Exchange closes it. }
  TDeadlinePipeStream = class(TStream)
  strict private
    FPipe     : THandle;
    FEvent    : THandle;     // manual-reset; reused across operations (one at a time)
    FTimeoutMs: Cardinal;
    function RunOverlapped(AIsRead: Boolean; var Buffer; Count: Longint): Longint;
  public
    constructor Create(APipe: THandle; ATimeoutMs: Cardinal);
    destructor Destroy; override;
    function Read (var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;


constructor TDeadlinePipeStream.Create(APipe: THandle; ATimeoutMs: Cardinal);
begin
  inherited Create;
  FPipe      := APipe;
  FTimeoutMs := ATimeoutMs;
  FEvent := CreateEventW(NIL, TRUE, FALSE, NIL);
  if FEvent = 0
  then RaiseLastOSError;
end;


destructor TDeadlinePipeStream.Destroy;
begin
  if FEvent <> 0
  then CloseHandle(FEvent);
  inherited;
end;


function TDeadlinePipeStream.RunOverlapped(AIsRead: Boolean; var Buffer; Count: Longint): Longint;
var
  Ov     : TOverlapped;
  Started: Boolean;
  Dummy  : DWORD;      // ReadFile/WriteFile demand a var here even for overlapped calls; the real count comes from GetOverlappedResult
  N      : DWORD;
  Err    : DWORD;
  OpWord : String;
begin
  if Count <= 0 then EXIT(0);

  Ov := Default(TOverlapped);
  ResetEvent(FEvent);
  Ov.hEvent := FEvent;

  if AIsRead
  then Started := ReadFile (FPipe, Buffer, Count, Dummy, @Ov)
  else Started := WriteFile(FPipe, Buffer, Count, Dummy, @Ov);

  if not Started then
    begin
      Err := GetLastError;
      if Err <> ERROR_IO_PENDING then
        begin
          // Immediate failure. A closed peer reads as EOF (0), so TBridgeWire.TryReadFrame takes its normal FALSE path; anything else is a real OS error.
          if AIsRead and ((Err = ERROR_BROKEN_PIPE) or (Err = ERROR_PIPE_NOT_CONNECTED))
          then EXIT(0)
          else RaiseLastOSError(Err);
        end;

      { TRAP: from here to GetOverlappedResult the kernel may still write into Ov and Buffer.
        Only Win32 calls that cannot raise may stand here: a statement that raises (a log line, a check) would leave this routine while the I/O is pending, and the kernel would then write into freed memory. }
      // Deadline hit: cancel the pending operation. ERROR_NOT_FOUND (it completed in the race window) is fine - GetOverlappedResult below resolves either way.
      if WaitForSingleObject(FEvent, FTimeoutMs) <> WAIT_OBJECT_0
      then CancelIoEx(FPipe, @Ov);
    end;

  { Single collection point for every path (synchronous completion, signaled wait, after the cancel).
    bWait = TRUE also guarantees the kernel is done with Ov and Buffer before they leave scope - mandatory after CancelIoEx. }
  if not GetOverlappedResult(FPipe, Ov, N, TRUE) then
    begin
      Err := GetLastError;
      if Err = ERROR_OPERATION_ABORTED then
        begin
          if AIsRead
          then OpWord := 'reply'
          else OpWord := 'accept data';
          raise ETargetNotResponding.Create('Autopilot: the app accepted the pipe connection but did not ' + OpWord + ' within ' + UIntToStr(FTimeoutMs) + ' ms - stopped on a breakpoint, or hung?');
        end;
      if AIsRead and ((Err = ERROR_BROKEN_PIPE) or (Err = ERROR_PIPE_NOT_CONNECTED)) then EXIT(0);
      RaiseLastOSError(Err);
    end;
  Result := Longint(N);
end;


function TDeadlinePipeStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := RunOverlapped(TRUE, Buffer, Count);
end;


function TDeadlinePipeStream.Write(const Buffer; Count: Longint): Longint;
begin
  // An overlapped WriteFile does not change the buffer; the var cast only fits RunOverlapped's shared signature
  Result := RunOverlapped(FALSE, PByte(@Buffer)^, Count);
end;


function TDeadlinePipeStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  // A pipe cannot seek. TBridgeWire never seeks; this only satisfies the abstract method.
  raise ENotSupportedException.Create('TDeadlinePipeStream cannot seek');
end;


procedure WriteHelloAck(AStream: TStream);
var
  Ack, Inner: TJSONObject;
begin
  Inner := TJSONObject.Create;
  Ack := TJSONObject.Create;
  try
    Inner.AddPair('protocolVersion', TJSONNumber.Create(ProtocolVersion));
    Ack.AddPair('helloAck', Inner);
    Inner := NIL;   // Ack owns it now
    TBridgeWire.WriteFrame(AStream, Ack.ToJSON);
  finally
    FreeAndNil(Inner);
    FreeAndNil(Ack);
  end;
end;


// The error code, message and data of an ok:false answer
procedure ReadErrorOf(ARoot: TJSONObject; OUT ACode: Integer; OUT AMessage, AData: String);
var
  V, ErrObj: TJSONValue;
  N: Int64;
begin
  ACode    := ErrInternalError;
  AMessage := 'the bridge answered ok:false without an error object';
  AData    := '';
  ErrObj := ARoot.GetValue('error');
  if not (ErrObj is TJSONObject) then EXIT;
  if TryJsonInt64(TJSONObject(ErrObj).GetValue('code'), N) and (N >= Low(Integer)) and (N <= High(Integer))
  then ACode := Integer(N);
  V := TJSONObject(ErrObj).GetValue('message');
  if V is TJSONString
  then AMessage := TJSONString(V).Value;
  V := TJSONObject(ErrObj).GetValue('data');
  if V <> NIL
  then AData := V.ToJSON;
end;


{ TAutopilotApp - process -------------------------------------------------- }

constructor TAutopilotApp.CreateForPipe(const APipeName: String; APid: Cardinal);
begin
  inherited Create;
  FPipeName := APipeName;
  FPid      := APid;
  if (APid <> 0) and (APid <> GetCurrentProcessId) then
    begin
      FProcess := OpenProcess(SYNCHRONIZE or PROCESS_QUERY_INFORMATION or PROCESS_TERMINATE, FALSE, APid);
      if FProcess = 0
      then FProcess := OpenProcess(SYNCHRONIZE, FALSE, APid);   // still 0: the liveness check falls back to IsPidAlive
    end;
end;


destructor TAutopilotApp.Destroy;
begin
  if FStartedByUs and (FProcess <> 0) and (WaitForSingleObject(FProcess, 0) = WAIT_TIMEOUT) then
    begin
      TerminateProcess(FProcess, 1);
      WaitForSingleObject(FProcess, KillWaitMs);
      BridgeLogWarn(LogTag, 'Destroy killed pid ' + UIntToStr(FPid) + ', which Start had started (call Close first for a clean end)');
    end;
  if FStartedByUs
  then DeleteDiscoveryFileIfEnded;
  if FProcess <> 0
  then CloseHandle(FProcess);
  if FJob <> 0
  then CloseHandle(FJob);   // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE ends anything the app started too
  inherited;
end;


// TRUE when the app's process has ended. AExitInfo: ' with exit code N' when the code is known, else ''.
function TAutopilotApp.ProcessEnded(OUT AExitInfo: String): Boolean;
var
  Code: DWORD;
begin
  AExitInfo := '';
  if FProcess <> 0
  then
    begin
      Result := WaitForSingleObject(FProcess, 0) = WAIT_OBJECT_0;
      if Result and GetExitCodeProcess(FProcess, Code)
      then AExitInfo := ' with exit code ' + UIntToStr(Code);
    end
  else Result := (FPid <> 0) and (FPid <> GetCurrentProcessId) and not IsPidAlive(FPid);
end;


procedure TAutopilotApp.CheckStillRunning;
var
  ExitInfo: String;
begin
  if ProcessEnded(ExitInfo)
  then raise ETargetNotRunning.Create('Autopilot: the app (pid ' + UIntToStr(FPid) + ') has ended' + ExitInfo);
end;


function TAutopilotApp.WaitForEnd(ATimeoutMs: Cardinal): Boolean;
var
  Deadline: UInt64;
  ExitInfo: String;
begin
  if FProcess <> 0 then EXIT(WaitForSingleObject(FProcess, ATimeoutMs) = WAIT_OBJECT_0);
  Deadline := GetTickCount64 + ATimeoutMs;
  repeat
    if ProcessEnded(ExitInfo) then EXIT(TRUE);
    Sleep(50);
  until GetTickCount64 >= Deadline;
  Result := ProcessEnded(ExitInfo);
end;


// Ends the app at once. Returns the sentence for the exception message.
function TAutopilotApp.Kill: String;
var
  H: THandle;
  Done: Boolean;
begin
  if FProcess <> 0
  then
    begin
      Done := TerminateProcess(FProcess, 1);
      if Done
      then WaitForSingleObject(FProcess, KillWaitMs);
    end
  else
    begin
      H := OpenProcess(PROCESS_TERMINATE or SYNCHRONIZE, FALSE, FPid);
      Done := (H <> 0) and TerminateProcess(H, 1);
      if H <> 0 then
        try
          if Done
          then WaitForSingleObject(H, KillWaitMs);
        finally
          CloseHandle(H);
        end;
    end;
  if Done
  then
    begin
      BridgeLogWarn(LogTag, 'killed pid ' + UIntToStr(FPid));
      DeleteDiscoveryFileIfEnded;
      Result := 'the app was killed';
    end
  else Result := 'killing the app failed: ' + SysErrorMessage(GetLastError);
end;


// A discovery file whose process has ended is stale: StopBridge never ran
procedure TAutopilotApp.DeleteDiscoveryFileIfEnded;
var
  ExitInfo, FileName: String;
begin
  if (FPid = 0) or not ProcessEnded(ExitInfo) then EXIT;
  FileName := DiscoveryFileOf(FPid);
  if FileExists(FileName) and not System.SysUtils.DeleteFile(FileName)
  then BridgeLogWarn(LogTag, 'cannot delete the stale discovery file ' + FileName + ': ' + SysErrorMessage(GetLastError));
end;


class function TAutopilotApp.Start(const ExePath, Params: String; StartTimeoutMs: Cardinal; Window: TStartWindow): TAutopilotApp;
var
  SI: TStartupInfo;
  PI: TProcessInformation;
  Limits: TJobObjectExtendedLimitInformation;
  CmdLine, WorkDir, DiscoveryFile: String;
  WorkDirPtr: PChar;
begin
  if not FileExists(ExePath)
  then raise ETargetNotRunning.Create('Autopilot.Start: file not found: ' + ExePath);

  Result := TAutopilotApp.CreateForPipe('', 0);
  try
    Result.FStartedByUs := TRUE;

    { # Job object: the app ends together with this process, even when no teardown runs }
    Result.FJob := CreateJobObject(NIL, NIL);
    if Result.FJob = 0
    then BridgeLogWarn(LogTag, 'Start: CreateJobObject failed (' + SysErrorMessage(GetLastError) + '): the app will not end together with this process')
    else
      begin
        Limits := Default(TJobObjectExtendedLimitInformation);
        Limits.BasicLimitInformation.LimitFlags := JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if not SetInformationJobObject(Result.FJob, JobObjectExtendedLimitInformation, @Limits, SizeOf(Limits))
        then BridgeLogWarn(LogTag, 'Start: SetInformationJobObject failed (' + SysErrorMessage(GetLastError) + '): the app will not end together with this process');
      end;

    { # The process, suspended until it is in the job }
    SI := Default(TStartupInfo);
    SI.cb := SizeOf(SI);
    SI.dwFlags := STARTF_USESHOWWINDOW;   // the RTL of the app reads wShowWindow into CmdShow (System.GetCmdShow)
    if Window = swNormal
    then SI.wShowWindow := SW_SHOWNORMAL
    else SI.wShowWindow := SW_SHOWMINNOACTIVE;
    CmdLine := '"' + ExePath + '"';
    if Params <> ''
    then CmdLine := CmdLine + ' ' + Params;
    UniqueString(CmdLine);   // CreateProcessW may write into its command line buffer
    WorkDir := ExtractFileDir(ExePath);
    if WorkDir = ''
    then WorkDirPtr := NIL
    else WorkDirPtr := PChar(WorkDir);
    PI := Default(TProcessInformation);
    if not CreateProcess(PChar(ExePath), PChar(CmdLine), NIL, NIL, FALSE, CREATE_SUSPENDED, NIL, WorkDirPtr, SI, PI)
    then raise ETargetNotRunning.Create('Autopilot.Start: cannot start ' + ExePath + ': ' + SysErrorMessage(GetLastError));
    Result.FProcess := PI.hProcess;
    Result.FPid     := PI.dwProcessId;
    try
      if (Result.FJob <> 0) and not AssignProcessToJobObject(Result.FJob, PI.hProcess)
      then BridgeLogWarn(LogTag, 'Start: AssignProcessToJobObject failed (' + SysErrorMessage(GetLastError) + '): the app will not end together with this process');
      { A discovery file with this pid is left over from an earlier process that ended without StopBridge: this one has not run a line yet }
      DiscoveryFile := DiscoveryFileOf(Result.FPid);
      if FileExists(DiscoveryFile) and not System.SysUtils.DeleteFile(DiscoveryFile)
      then BridgeLogWarn(LogTag, 'Start: cannot delete the stale discovery file ' + DiscoveryFile + ': ' + SysErrorMessage(GetLastError));
      if ResumeThread(PI.hThread) = $FFFFFFFF
      then RaiseLastOSError;
    finally
      CloseHandle(PI.hThread);
    end;
    BridgeLogInfo(LogTag, 'Start: pid ' + UIntToStr(Result.FPid) + ' ' + ExePath + ' ' + Params);

    Result.FPipeName := Result.WaitForDiscovery(DiscoveryFile, ExePath, StartTimeoutMs);
  except
    FreeAndNil(Result);   // kills the app if it runs, closes the job
    raise;
  end;
end;


function TAutopilotApp.WaitForDiscovery(const ADiscoveryFile, AExePath: String; ATimeoutMs: Cardinal): String;
var
  Deadline: UInt64;
  ExitInfo: String;
begin
  Deadline := GetTickCount64 + ATimeoutMs;
  repeat
    if FileExists(ADiscoveryFile) and TryReadPipeName(ADiscoveryFile, Result) then EXIT;
    if ProcessEnded(ExitInfo)
    then raise ETargetNotRunning.Create('Autopilot.Start: ' + ExtractFileName(AExePath) + ' (pid ' + UIntToStr(FPid) + ') ended' + ExitInfo + ' before its bridge came up');
    Sleep(PipeRetryMs);
  until GetTickCount64 >= Deadline;
  raise ETargetNotRunning.Create('Autopilot.Start: ' + ExtractFileName(AExePath) + ' (pid ' + UIntToStr(FPid) + ') runs, but no bridge wrote ' + ADiscoveryFile + ' within ' + UIntToStr(ATimeoutMs) + ' ms. Likely causes: the app was built without the ' + 'AUTOPILOT define, it never calls StartBridge, or it waits in a startup error box' + DialogBoxesNote(FPid) + '. The app was killed');
end;


class function TAutopilotApp.Attach(Pid: Cardinal): TAutopilotApp;
var
  Targets: TArray<TTargetEntry>;
  i, Chosen: Integer;
  Pids: String;
begin
  Targets := ListTargets;
  Chosen := -1;
  if Pid <> 0
  then
    begin
      for i := 0 to High(Targets) do
        if Targets[i].Pid = Pid
        then Chosen := i;
      if Chosen < 0
      then raise ETargetNotRunning.Create('Autopilot.Attach: no Autopilot target with pid ' + UIntToStr(Pid) + ' is running (no live ' + DiscoveryFileOf(Pid) + ')');
    end
  else
    begin
      if Length(Targets) = 0
      then raise ETargetNotRunning.Create('Autopilot.Attach: no Autopilot target is running (' + DiscoveryFolderPath + ' holds no live entry)');
      if Length(Targets) > 1 then
        begin
          Pids := '';
          for i := 0 to High(Targets) do
            begin
              if Pids <> ''
              then Pids := Pids + ', ';
              Pids := Pids + UIntToStr(Targets[i].Pid);
            end;
          raise ETargetNotRunning.Create('Autopilot.Attach: ' + IntToStr(Length(Targets)) + ' Autopilot targets are running (pids ' + Pids + '); pass the pid of the app to Attach');
        end;
      Chosen := 0;
    end;
  Result := TAutopilotApp.CreateForPipe(Targets[Chosen].PipeName, Targets[Chosen].Pid);
  BridgeLogInfo(LogTag, 'Attach: pid ' + UIntToStr(Result.FPid) + ' ' + Result.FPipeName);
end;


procedure TAutopilotApp.Close(TimeoutMs: Cardinal);
var
  ExitInfo, Boxes, Killed: String;
  Scan: TWindowScan;
  AppWnd: HWND;
begin
  if FPid = 0
  then raise ETargetNotRunning.Create('Autopilot.Close: this TAutopilotApp has no app; create it with TAutopilotApp.Start or TAutopilotApp.Attach');
  if FPid = GetCurrentProcessId
  then raise EInvalidOpException.Create('Autopilot.Close: the app is this process (pid ' + UIntToStr(FPid) + ')');
  if ProcessEnded(ExitInfo) then
    begin
      DeleteDiscoveryFileIfEnded;
      EXIT;
    end;

  Scan := ScanWindowsOf(FPid);
  try
    AppWnd := Scan.AppWindow;
  finally
    FreeAndNil(Scan);
  end;
  if (AppWnd = 0) or not PostMessage(AppWnd, WM_CLOSE, 0, 0) then
    begin
      Boxes  := DialogBoxesNote(FPid);
      Killed := Kill;
      raise ETargetNotResponding.Create('Autopilot.Close: the app (pid ' + UIntToStr(FPid) + ') has no TApplication or TFMAppClass window ' + 'that takes WM_CLOSE' + Boxes + '; ' + Killed);
    end;

  if WaitForEnd(TimeoutMs) then
    begin
      ProcessEnded(ExitInfo);
      BridgeLogInfo(LogTag, 'Close: pid ' + UIntToStr(FPid) + ' ended' + ExitInfo);
      DeleteDiscoveryFileIfEnded;
      EXIT;
    end;

  Boxes  := DialogBoxesNote(FPid);   // read while the app still runs
  Killed := Kill;
  raise ETargetNotResponding.Create('Autopilot.Close: the app (pid ' + UIntToStr(FPid) + ') did not end within ' + UIntToStr(TimeoutMs) + ' ms of WM_CLOSE (a "Save changes?" box, an OnCloseQuery that refuses, or a hang)' + Boxes + '; ' + Killed);
end;


{ TAutopilotApp - transport ------------------------------------------------ }

procedure TAutopilotApp.RaiseConnectionClosed(const AWhat: String);
var
  ExitInfo: String;
begin
  if ProcessEnded(ExitInfo)
  then raise ETargetNotRunning.Create('Autopilot: the app (pid ' + UIntToStr(FPid) + ') ended' + ExitInfo + '; its bridge ' + AWhat);
  raise ETargetNotResponding.Create('Autopilot: the bridge on ' + FPipeName + ' ' + AWhat + ' (it is shutting down, or it refused the request)');
end;


function TAutopilotApp.OpenPipe(ATimeoutMs: Cardinal): THandle;
var
  Deadline, Tick, Left: UInt64;
  Err: DWORD;
  E: EOSError;
  SeenBusy: Boolean;
  SinceBusy: TStopwatch;
begin
  Deadline  := GetTickCount64 + ATimeoutMs;
  SeenBusy  := FALSE;
  SinceBusy := TStopwatch.Create;
  repeat
    // FILE_FLAG_OVERLAPPED is a choice per handle: the bridge's end stays synchronous. TDeadlinePipeStream needs it.
    Result := CreateFileW(PWideChar(FPipeName), GENERIC_READ or GENERIC_WRITE, 0, NIL, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, 0);
    if Result <> INVALID_HANDLE_VALUE then EXIT;
    { ERROR_FILE_NOT_FOUND: the bridge is not listening yet (cold start), or not yet again after the previous connection.
      ERROR_PIPE_BUSY: its only pipe instance serves another client, or the bridge is between two connections.
      Anything else (ERROR_ACCESS_DENIED: another Windows user) is permanent. }
    Err := GetLastError;
    if (Err <> ERROR_FILE_NOT_FOUND) and (Err <> ERROR_PIPE_BUSY) then Break;
    CheckStillRunning;   // a crashed app fails now, with its exit code, not at the end of the timeout
    Tick := GetTickCount64;
    if Tick >= Deadline then Break;

    { How the bridge moves from one connection to the next (measured 2026-10-13, a command sent right after the previous one): the open finds the pipe busy (the old instance still exists); the bridge closes that instance about 0.1 ms later (the pipe is gone: ERROR_FILE_NOT_FOUND) and creates the next one within about 0.2 ms.
      A Sleep(25) at either step lasts about 33 ms on Windows, because of the timer tick. }
    if Err = ERROR_PIPE_BUSY
    then
      begin
        { WaitNamedPipe returns as soon as the bridge waits for a client again (a pending ConnectNamedPipe), at once when the bridge closes the instance (measured: FALSE with ERROR_FILE_NOT_FOUND), and at the latest after the slice, so the liveness check above runs at least once per slice.
          Its TRUE reserves nothing (another client may open the instance first), so the loop opens again whatever it returns.
          Never pass 0: that is NMPWAIT_USE_DEFAULT_WAIT, the server's default time-out. https://learn.microsoft.com/en-us/windows/win32/api/namedpipeapi/nf-namedpipeapi-waitnamedpipew }
        Left := Deadline - Tick;
        if Left > BusyWaitSliceMs
        then Left := BusyWaitSliceMs;
        WaitNamedPipeW(PWideChar(FPipeName), DWORD(Left));
        SeenBusy  := TRUE;
        SinceBusy := TStopwatch.StartNew;
      end
    else
      if SeenBusy and (SinceBusy.ElapsedMilliseconds < RecreateYieldMs)
      then SwitchToThread    // the pipe vanished right after it was busy: the bridge is creating the next instance
      else Sleep(PipeRetryMs);
  until GetTickCount64 >= Deadline;

  if Err = ERROR_PIPE_BUSY
  then raise ETargetNotResponding.Create('Autopilot: pipe ' + FPipeName + ' stayed busy for ' + UIntToStr(ATimeoutMs) + ' ms: the app serves another client, or it is frozen (stopped on a breakpoint, or hung)');
  if Err = ERROR_FILE_NOT_FOUND
  then raise ETargetNotRunning.Create('Autopilot: pipe ' + FPipeName + ' did not appear within ' + UIntToStr(ATimeoutMs) + ' ms: the app has stopped its bridge (StopBridge), or it is closing');
  E := EOSError.Create('Autopilot: cannot open pipe ' + FPipeName + ': ' + SysErrorMessage(Err) + ' (code ' + UIntToStr(Err) + '). The pipe accepts only the Windows user that runs the app: run the test as that user');
  E.ErrorCode := Err;
  raise E;
end;


{ Checks the bridge's hello: a JSON object with hello.protocolVersion = ProtocolVersion, and (rule 9) not the bridge of this process when this is the main thread. }
procedure TAutopilotApp.ReadHello(AStream: TStream);
var
  Raw: String;
  Root, V: TJSONValue;
  Hello: TJSONObject;
  HelloVersion, HelloPid: Int64;
begin
  if not TBridgeWire.TryReadFrame(AStream, Raw)
  then RaiseConnectionClosed('closed the connection before its hello');
  Root := TJSONObject.ParseJSONValue(Raw);
  try
    if Root is TJSONObject
    then V := TJSONObject(Root).GetValue('hello')
    else V := NIL;
    if not (V is TJSONObject)
    then raise EAutopilotError.CreateCode(ErrProtocolMismatch, 'Autopilot: the first frame on ' + FPipeName + ' is not a hello: ' + Copy(Raw, 1, 200));
    Hello := TJSONObject(V);
    if not TryJsonInt64(Hello.GetValue('protocolVersion'), HelloVersion)
    then raise EAutopilotError.CreateCode(ErrProtocolMismatch, 'Autopilot: the hello on ' + FPipeName + ' has no protocolVersion: ' + Copy(Raw, 1, 200));
    if HelloVersion <> ProtocolVersion
    then raise EAutopilotError.CreateCode(ErrProtocolMismatch, 'Autopilot: protocol mismatch on ' + FPipeName + ': the bridge speaks protocol ' + IntToStr(HelloVersion) + ', this client speaks protocol ' + IntToStr(ProtocolVersion) + '. Use the client unit of the same Autopilot release as the bridge');
    if TryJsonInt64(Hello.GetValue('pid'), HelloPid) then
      begin
        if (HelloPid = GetCurrentProcessId) and (GetCurrentThreadId = MainThreadID)
        then raise EInvalidOpException.Create('Autopilot: called from the main thread of the process whose bridge answers (pid ' + IntToStr(HelloPid) + '). The bridge runs every command on that main thread, so this call would wait for itself and ' + 'fail with -32004 after its timeout. Call the client from a worker thread, or from a separate test EXE');
        if (FPid <> 0) and (HelloPid <> FPid)
        then raise ETargetNotRunning.Create('Autopilot: pipe ' + FPipeName + ' belongs to pid ' + IntToStr(HelloPid) + ', not to the app (pid ' + UIntToStr(FPid) + ')');
      end;
  finally
    FreeAndNil(Root);
  end;
end;


{ One round trip on a new connection: open, hello, helloAck, the request, the answer, close.
  Consumes AArgs.
  Returns the parsed answer (the caller frees it). }
function TAutopilotApp.Exchange(const ACmd: String; AArgs: TJSONObject; ATimeoutMs: Cardinal): TJSONObject;
var
  Req: TJSONObject;
  ReqText, Frame: String;
  Id, AnswerId: Int64;
  Pipe: THandle;
  Stream: TDeadlinePipeStream;
  Parsed: TJSONValue;
begin
  { # The request. Built first, so AArgs belongs to Req (and is freed) whatever happens next }
  Inc(FNextId);
  Id := FNextId;
  Req := TJSONObject.Create;
  try
    Req.AddPair('id', TJSONNumber.Create(Id));
    Req.AddPair('cmd', ACmd);
    if AArgs = NIL
    then AArgs := TJSONObject.Create;
    Req.AddPair('args', AArgs);
    AArgs := NIL;   // Req owns it now
    Req.AddPair('timeoutMs', TJSONNumber.Create(Int64(ATimeoutMs)));
    ReqText := Req.ToJSON;
  finally
    FreeAndNil(Req);
    FreeAndNil(AArgs);   // only when AddPair raised before Req took it
  end;

  if FPipeName = ''
  then raise ETargetNotRunning.Create('Autopilot: this TAutopilotApp has no app; create it with TAutopilotApp.Start or TAutopilotApp.Attach');

  { # The round trip }
  Pipe := OpenPipe(ATimeoutMs);
  try
    Stream := TDeadlinePipeStream.Create(Pipe, DeadlineFor(ATimeoutMs));
    try
      ReadHello(Stream);
      WriteHelloAck(Stream);
      TBridgeWire.WriteFrame(Stream, ReqText);
      if not TBridgeWire.TryReadFrame(Stream, Frame)
      then RaiseConnectionClosed('closed the connection without answering ' + ACmd);
    finally
      FreeAndNil(Stream);
    end;
  finally
    CloseHandle(Pipe);
  end;

  { # The answer: a JSON object with the request's id }
  Parsed := TJSONObject.ParseJSONValue(Frame);
  if not (Parsed is TJSONObject) then
    begin
      FreeAndNil(Parsed);
      raise EAutopilotError.CreateCode(ErrProtocolMismatch, 'Autopilot ' + ACmd + ': the answer is not a JSON object: ' + Copy(Frame, 1, 200));
    end;
  Result := TJSONObject(Parsed);
  if not TryJsonInt64(Result.GetValue('id'), AnswerId) or (AnswerId <> Id) then
    begin
      FreeAndNil(Result);
      raise EAutopilotError.CreateCode(ErrProtocolMismatch, 'Autopilot ' + ACmd + ': the answer does not carry the id ' + IntToStr(Id) + ' of the request: ' + Copy(Frame, 1, 200));
    end;
end;


{ Sends one command.
  Returns a copy of the answer's 'result' object (the caller frees it); raises EAutopilotError on ok:false.
  AListDialogsWhenBlocked: after a -32004, list the open native dialogs into the message (one more round trip). }
function TAutopilotApp.Request(const ACmd: String; AArgs: TJSONObject; ATimeoutMs: Cardinal; AListDialogsWhenBlocked: Boolean): TJSONObject;
var
  Root: TJSONObject;
  V: TJSONValue;
  Code: Integer;
  Msg, Data: String;
begin
  if ATimeoutMs = 0
  then ATimeoutMs := DefaultTimeoutFor(ACmd);
  Root := Exchange(ACmd, AArgs, ATimeoutMs);
  try
    if JsonBool(Root, 'ok') then
      begin
        V := Root.GetValue('result');
        if V is TJSONObject
        then Result := TJSONObject(V.Clone)
        else Result := TJSONObject.Create;
        EXIT;
      end;
    ReadErrorOf(Root, Code, Msg, Data);
  finally
    FreeAndNil(Root);
  end;
  if (Code = ErrMainThreadBlocked) and AListDialogsWhenBlocked
  then Msg := Msg + OpenDialogsNote;
  raise EAutopilotError.CreateCode(Code, 'Autopilot ' + ACmd + ': ' + Msg + ' (error ' + IntToStr(Code) + ')', Data);
end;


procedure TAutopilotApp.Send(const ACmd: String; AArgs: TJSONObject);
var
  R: TJSONObject;
begin
  R := Request(ACmd, AArgs, 0, TRUE);
  FreeAndNil(R);
end;


function TAutopilotApp.RequestString(const ACmd: String; AArgs: TJSONObject; const AField: String; AListDialogsWhenBlocked: Boolean): String;
var
  R: TJSONObject;
begin
  R := Request(ACmd, AArgs, 0, AListDialogsWhenBlocked);
  try
    Result := JsonStr(R, AField);
  finally
    FreeAndNil(R);
  end;
end;


{ After a -32004: which native dialogs are open in the app.
  The text is added to the message of the -32004 that is raised next, so a failure of this extra round trip is reported there, not hidden. }
function TAutopilotApp.OpenDialogsNote: String;

  function NotListed(E: Exception): String;
  begin
    BridgeLogWarn(LogTag, 'the dialog list after a -32004 failed: ' + E.ClassName + ': ' + E.Message);
    Result := '. The open native dialogs could not be listed (' + E.ClassName + ': ' + E.Message + ')';
  end;

var
  R: TJSONObject;
  Found: String;
begin
  try
    R := Request('dismiss_dialog', NIL, DialogProbeTimeoutMs, FALSE);
    try
      Found := DescribeDialogs(R);
    finally
      FreeAndNil(R);
    end;
  except
    on E: EAutopilotError      do EXIT(NotListed(E));
    on E: ETargetNotResponding do EXIT(NotListed(E));
    on E: ETargetNotRunning    do EXIT(NotListed(E));
    on E: EOSError             do EXIT(NotListed(E));
  end;
  if Found = ''
  then Result := '. No native dialog is open in the app (a long event handler, a breakpoint, or a dialog that is a form)'
  else Result := '. Native dialogs open in the app: ' + Found + ' (DismissDialog closes one)';
end;


function TAutopilotApp.DialogIsOpen(AHwnd: Int64): Boolean;
var
  R: TJSONObject;
  V: TJSONValue;
  Arr: TJSONArray;
  i: Integer;
  H: Int64;
begin
  Result := FALSE;
  R := Request('dismiss_dialog', NIL, 0, FALSE);
  try
    V := R.GetValue('dialogs');
    if V is TJSONArray then
      begin
        Arr := TJSONArray(V);
        for i := 0 to Arr.Count - 1 do
          if (Arr.Items[i] is TJSONObject) and TryJsonInt64(TJSONObject(Arr.Items[i]).GetValue('hwnd'), H) and (H = AHwnd) then EXIT(TRUE);
      end;
  finally
    FreeAndNil(R);
  end;
end;


{ TAutopilotApp - commands ------------------------------------------------- }

function TAutopilotApp.Click(const Path: String; Count: Integer; TimeoutMs: Cardinal): Integer;
var
  Args, R: TJSONObject;
  Budget: Integer;
  Stopped, Answer: String;
  N: Int64;
begin
  Args := NewArgs(Path);
  if Count <> 1
  then Args.AddPair('count', TJSONNumber.Create(Count));   // the bridge rejects a count outside 1..1000 with -32600
  if (TimeoutMs = 0) and (Count > 1) then
    begin
      // Clamp before the arithmetic, so an absurd Count reaches the bridge's clear rejection instead of an overflow here
      Budget := Count;
      if Budget > MaxClickCount
      then Budget := MaxClickCount;
      TimeoutMs := DefaultTimeoutClickMs + Cardinal(Budget - 1) * PerClickBudgetMs;
    end;
  R := Request('click', Args, TimeoutMs, TRUE);
  try
    Stopped := JsonStr(R, 'stoppedReason');
    if TryJsonInt64(R.GetValue('clicksDispatched'), N) and (N >= 0) and (N <= High(Integer))
    then Result := Integer(N)
    else Result := 0;
    Answer := R.ToJSON;
  finally
    FreeAndNil(R);
  end;
  if Copy(Stopped, 1, Length('exception:')) = 'exception:'
  then raise EAutopilotHandlerError.CreateCode(ErrInternalError, 'Autopilot click ' + Path + ': the OnClick handler raised ' + Copy(Stopped, Length('exception:') + 1, MaxInt) + ' after ' + IntToStr(Result) + ' successful clicks (the bridge caught it; the app''s own exception handler never saw it)', Answer);
end;


procedure TAutopilotApp.ClickAsync(const Path: String);
var
  Args: TJSONObject;
begin
  Args := NewArgs(Path);
  Args.AddPair('mode', 'message');
  Send('click', Args);
end;


procedure TAutopilotApp.SetText(const Path, Text: String);
var
  Args: TJSONObject;
begin
  Args := NewArgs(Path);
  Args.AddPair('text', Text);
  Send('set_text', Args);
end;


function TAutopilotApp.GetText(const Path: String): String;
begin
  Result := RequestString('get_text', NewArgs(Path), 'text', TRUE);
end;


procedure TAutopilotApp.SetChecked(const Path: String; Checked: Boolean);
var
  Args: TJSONObject;
begin
  Args := NewArgs(Path);
  Args.AddPair('checked', TJSONBool.Create(Checked));
  Send('set_checked', Args);
end;


function TAutopilotApp.ReadProperty(const Path, PropName: String): String;
var
  Args: TJSONObject;
begin
  Args := NewArgs(Path);
  Args.AddPair('propName', PropName);
  Result := RequestString('read_property', Args, 'value', TRUE);
end;


procedure TAutopilotApp.SetProperty(const Path, PropName, Value: String);
var
  Args: TJSONObject;
begin
  Args := NewArgs(Path);
  Args.AddPair('propName', PropName);
  Args.AddPair('value', Value);
  Send('set_property', Args);
end;


function TAutopilotApp.ExecuteAction(const Path: String): Boolean;
var
  R: TJSONObject;
begin
  R := Request('execute_action', NewArgs(Path), 0, TRUE);
  try
    Result := JsonBool(R, 'executed');
  finally
    FreeAndNil(R);
  end;
end;


procedure TAutopilotApp.SendKeys(const Path, Keys, Text: String);
var
  Args: TJSONObject;
begin
  Args := NewArgs(Path);
  if Keys <> ''
  then Args.AddPair('keys', Keys);
  if Text <> ''
  then Args.AddPair('text', Text);
  Send('send_keys', Args);
end;


function TAutopilotApp.DismissDialog(const Button: String; TimeoutMs: Cardinal): Boolean;
var
  Args, R: TJSONObject;
  Clicked: Boolean;
  Via, Reason: String;
  DialogHwnd: Int64;
  Deadline: UInt64;
begin
  if Trim(Button) = ''
  then raise EArgumentException.Create('Autopilot.DismissDialog: Button is empty; pass a role (ok, cancel, yes, no, retry, abort, ignore, close), ' + 'a button caption or a control id');

  { # Wait for the dialog: after ClickAsync the click, and with it the dialog, comes only after the click's answer }
  Deadline := GetTickCount64 + TimeoutMs;
  repeat
    Args := TJSONObject.Create;
    Args.AddPair('button', Button);
    R := Request('dismiss_dialog', Args, 0, FALSE);
    try
      Clicked := JsonBool(R, 'clicked');
      Via     := JsonStr(R, 'via');
      Reason  := JsonStr(R, 'reason');   // when not clicked: 'no_dialog', 'button_not_found' or 'send_failed'
      TryJsonInt64(R.GetValue('dialogHwnd'), DialogHwnd);   // 0 when absent
    finally
      FreeAndNil(R);
    end;
    if Clicked then Break;
    if Reason <> 'no_dialog' then EXIT(FALSE);   // a dialog is open, but the click cannot land on it
    if GetTickCount64 >= Deadline then EXIT(FALSE);
    Sleep(DialogPollMs);
  until FALSE;
  if not SameText(Via, 'WM_COMMAND') then EXIT(TRUE);   // BM_CLICK: the button's own window took the click

  { A blind WM_COMMAND by id answers "clicked" even on a dialog that has no such command.
    The dialog leaves the list only once it really closed: watch the list. }
  Deadline := GetTickCount64 + DialogGoneTimeoutMs;
  repeat
    if not DialogIsOpen(DialogHwnd) then EXIT(TRUE);
    Sleep(50);
  until GetTickCount64 >= Deadline;
  Result := FALSE;
end;


procedure TAutopilotApp.Screenshot(const Path, PngFileName: String);
var
  R: TJSONObject;
  Image: String;
  Bytes: TBytes;
begin
  R := Request('screenshot', NewArgs(Path), 0, TRUE);
  try
    Image := JsonStr(R, 'image');
  finally
    FreeAndNil(R);
  end;
  if Image = ''
  then raise EAutopilotError.CreateCode(ErrProtocolMismatch, 'Autopilot screenshot ' + Path + ': the answer has no image');
  Bytes := TNetEncoding.Base64.DecodeStringToBytes(Image);
  if ExtractFileDir(PngFileName) <> ''
  then ForceDirectories(ExtractFileDir(PngFileName));
  TFile.WriteAllBytes(PngFileName, Bytes);
end;


function TAutopilotApp.WaitForText(const Path, Expected: String; TimeoutMs: Cardinal): Boolean;
var
  Deadline: UInt64;
  Current, LastError: String;
  Polls: Integer;
begin
  Deadline  := GetTickCount64 + TimeoutMs;
  Current   := '';
  LastError := '';
  Polls     := 0;
  repeat
    Inc(Polls);
    try
      Current := RequestString('get_text', NewArgs(Path), 'text', FALSE);   // ETargetNotRunning and ETargetNotResponding end the wait
      if Current = Expected then EXIT(TRUE);
      LastError := '';
    except
      // A control that does not exist yet, or a main thread busy for a moment: poll again. A protocol mismatch never heals.
      on E: EAutopilotError do
        begin
          if E.Code = ErrProtocolMismatch
          then raise;
          LastError := E.Message;
        end;
    end;
    if GetTickCount64 >= Deadline then Break;
    Sleep(ClientPollIntervalMs);
  until FALSE;
  if LastError <> ''
  then LastError := '; last error: ' + LastError;
  BridgeLogInfo(LogTag, 'WaitForText ' + Path + ': "' + Expected + '" not seen within ' + UIntToStr(TimeoutMs) + ' ms (' + IntToStr(Polls) + ' polls); last text "' + Current + '"' + LastError);
  Result := FALSE;
end;


function TAutopilotApp.Call(const Cmd: String; Args: TJSONObject; TimeoutMs: Cardinal): TJSONObject;
begin
  Result := Request(Cmd, Args, TimeoutMs, TRUE);
end;


end.
