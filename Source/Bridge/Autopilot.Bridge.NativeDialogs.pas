unit Autopilot.Bridge.NativeDialogs;

{=============================================================================================================
   2026.08.19
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - Native Win32 dialog escape hatch: reaches MessageBox / Task Dialog / common dialogs with no TComponent
   - EnumerateNativeDialogs: lists this process's visible non-VCL top-level dialog windows as JSON
   - ClickNativeDialogButton: dispatches a button by role keyword, caption, or control id
   - Interface is stdlib-only (System.JSON + NativeUInt); the body is MSWINDOWS-only
=============================================================================================================}

interface

uses
  System.JSON;

/// TRUE on Windows (the only platform with Win32 dialogs the bridge can reach this way).
function NativeDialogsSupported: Boolean;

/// Enumerate native (non-component) top-level dialog windows of THIS process.
/// AExclude = window handles to skip (the framework's own form windows + the app window),
/// so the framework's TForm/TfmxForm windows are not mistaken for OS dialogs.
/// Returns a JSON array (caller owns it); each node is
/// { hwnd, class, caption, text, buttons:[{id,caption,enabled}] }.
/// Empty array when no dialog is up, or always on non-Windows.
function EnumerateNativeDialogs(const AExclude: array of NativeUInt): TJSONArray;

/// Find a native dialog (ATargetDlg=0 -> the topmost one) and click the button picked
/// by ASelector. ASelector accepts a role keyword ('ok'/'cancel'/'yes'/'no'/'retry'/
/// 'abort'/'ignore'/'close'/'tryagain'/'continue'/'help'), a caption (exact then
/// substring, case-insensitive, '&' accelerator stripped), or a numeric control id.
/// Returns TRUE and sets AClickedId / AClickedCaption / AResolvedDlg on a dispatched click.
/// On FALSE, AReason is 'no_dialog' (nothing matched), 'button_not_found', or
/// 'send_failed' (the button was found but SendMessageTimeout did not complete).
/// AVia names the dispatch path actually used: 'BM_CLICK' (we hold the button's own HWND —
/// the button provably exists) or 'WM_COMMAND' (dispatched by control id to a dialog whose
/// button is not enumerable as a child window, e.g. a Task Dialog). The WM_COMMAND path is
/// UNVERIFIABLE: a dialog that has no such command silently ignores the message and the send
/// still completes, so TRUE there means "sent", not "landed" — re-list the dialogs to confirm.
function ClickNativeDialogButton(const AExclude: array of NativeUInt; ATargetDlg: NativeUInt;
  const ASelector: String; OUT AClickedId: Integer; OUT AClickedCaption: String;
  OUT AResolvedDlg: NativeUInt; OUT AReason: String; OUT AVia: String): Boolean;


implementation

{$IFDEF MSWINDOWS}
uses
  Winapi.Windows, Winapi.Messages,
  System.SysUtils, System.StrUtils, System.Generics.Collections;


function NativeDialogsSupported: Boolean;
begin
  Result := TRUE;
end;


{ Win32 reads --------------------------------------------------------------- }

const
  TextReadTimeoutMs = 1000;   // per-read cap; after the first hung read SMTO_ABORTIFHUNG fails the rest fast

// GetWindowText would be simpler, but for a window of THIS process it sends WM_GETTEXT and
// waits with NO timeout (learn.microsoft.com GetWindowTextW, Remarks: "if the target window
// is not responding and it belongs to the calling application, GetWindowText will cause the
// calling application to become unresponsive") — and every window enumerated here IS
// same-process. A dialog owned by a hung non-main thread would freeze the dispatcher, and
// with it the whole app. SendMessageTimeout degrades that to an empty string instead. For a
// window on the CURRENT thread the proc is called directly and the timeout is ignored
// (SendMessageTimeoutW, Remarks), so the normal main-thread-dialog path behaves as before.
function WindowTextOf(AWnd: HWND): String;
var
  Len, Copied: DWORD_PTR;
begin
  Result := '';
  Len := 0;
  if SendMessageTimeout(AWnd, WM_GETTEXTLENGTH, 0, 0, SMTO_ABORTIFHUNG, TextReadTimeoutMs, @Len) = 0 then exit;
  if Len = 0 then exit;
  SetLength(Result, Integer(Len));
  Copied := 0;
  // wParam counts the terminating null too; String[Len] has an implicit #0 slot beyond Len.
  if SendMessageTimeout(AWnd, WM_GETTEXT, WPARAM(Len) + 1, LPARAM(PChar(Result)), SMTO_ABORTIFHUNG, TextReadTimeoutMs, @Copied) = 0 then
    exit('');
  SetLength(Result, Integer(Copied));
end;


function ClassNameOf(AWnd: HWND): String;
var
  Buf: array[0..255] of Char;
  N: Integer;
begin
  N := GetClassName(AWnd, Buf, Length(Buf));
  SetString(Result, Buf, N);
end;


// Drop '&' accelerator markers so a caption reported / matched is what the user sees.
function StripAmp(const S: String): String;
begin
  Result := StringReplace(S, '&', '', [rfReplaceAll]);
end;


{ Child enumeration --------------------------------------------------------- }

type
  TChildCtx = record
    Buttons: TList<HWND>;
    Statics: TList<HWND>;
  end;
  PChildCtx = ^TChildCtx;

  TTopCtx = record
    Pid : DWORD;
    List: TList<HWND>;
  end;
  PTopCtx = ^TTopCtx;


function ChildEnumProc(AWnd: HWND; AParam: LPARAM): BOOL; stdcall;
var
  Ctx: PChildCtx;
  Cls: String;
begin
  Ctx := PChildCtx(AParam);
  Cls := ClassNameOf(AWnd);
  if SameText(Cls, 'Button') then
    Ctx.Buttons.Add(AWnd)
  else if SameText(Cls, 'Static') then
    Ctx.Statics.Add(AWnd);
  Result := TRUE;
end;


procedure CollectChildren(ADlg: HWND; AButtons, AStatics: TList<HWND>);
var
  Ctx: TChildCtx;
begin
  Ctx.Buttons := AButtons;
  Ctx.Statics := AStatics;
  EnumChildWindows(ADlg, @ChildEnumProc, LPARAM(@Ctx));
end;


function TopEnumProc(AWnd: HWND; AParam: LPARAM): BOOL; stdcall;
var
  Ctx: PTopCtx;
  WndPid: DWORD;
begin
  Ctx := PTopCtx(AParam);
  WndPid := 0;
  GetWindowThreadProcessId(AWnd, WndPid);
  if (WndPid = Ctx.Pid) and IsWindowVisible(AWnd) then
    Ctx.List.Add(AWnd);
  Result := TRUE;
end;


function InExclude(AWnd: HWND; const AExclude: array of NativeUInt): Boolean;
var
  i: Integer;
begin
  for i := Low(AExclude) to High(AExclude) do
    if HWND(AExclude[i]) = AWnd then exit(TRUE);
  Result := FALSE;
end;


// A native dialog = a visible top-level window of this process, not one of OUR windows,
// that either uses the system dialog class '#32770' (MessageBox / common dialogs) or owns
// at least one child Button (Task Dialog / custom dialog).
function LooksLikeDialog(AWnd: HWND; AButtonCount: Integer): Boolean;
begin
  Result := SameText(ClassNameOf(AWnd), '#32770') or (AButtonCount > 0);
end;


{ JSON shaping -------------------------------------------------------------- }

function BuildButtonsArray(const AButtons: TList<HWND>): TJSONArray;
var
  i: Integer;
  B: HWND;
  Node: TJSONObject;
begin
  Result := TJSONArray.Create;
  for i := 0 to AButtons.Count - 1 do
  begin
    B := AButtons[i];
    Node := TJSONObject.Create;
    Node.AddPair('id', TJSONNumber.Create(GetDlgCtrlID(B)));
    Node.AddPair('caption', StripAmp(WindowTextOf(B)));
    Node.AddPair('enabled', TJSONBool.Create(IsWindowEnabled(B)));
    Result.AddElement(Node);
  end;
end;


function JoinStaticText(const AStatics: TList<HWND>): String;
var
  i: Integer;
  S: String;
begin
  Result := '';
  for i := 0 to AStatics.Count - 1 do
  begin
    S := Trim(WindowTextOf(AStatics[i]));
    if S = '' then Continue;
    if Result <> '' then Result := Result + ' ';
    Result := Result + S;
  end;
end;


function BuildDialogNode(ADlg: HWND; const AButtons, AStatics: TList<HWND>): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('hwnd', TJSONNumber.Create(Int64(ADlg)));
  Result.AddPair('class', ClassNameOf(ADlg));
  Result.AddPair('caption', WindowTextOf(ADlg));
  Result.AddPair('text', JoinStaticText(AStatics));
  Result.AddPair('buttons', BuildButtonsArray(AButtons));
end;


{ Public: enumerate --------------------------------------------------------- }

function EnumerateNativeDialogs(const AExclude: array of NativeUInt): TJSONArray;
var
  Ctx: TTopCtx;
  i: Integer;
  W: HWND;
  Buttons, Statics: TList<HWND>;
begin
  Result := TJSONArray.Create;
  Ctx.Pid := GetCurrentProcessId;
  Ctx.List := TList<HWND>.Create;
  try
    EnumWindows(@TopEnumProc, LPARAM(@Ctx));
    for i := 0 to Ctx.List.Count - 1 do
    begin
      W := Ctx.List[i];
      if InExclude(W, AExclude) then Continue;
      Buttons := TList<HWND>.Create;
      Statics := TList<HWND>.Create;
      try
        CollectChildren(W, Buttons, Statics);
        if LooksLikeDialog(W, Buttons.Count) then
          Result.AddElement(BuildDialogNode(W, Buttons, Statics));
      finally
        Buttons.Free;
        Statics.Free;
      end;
    end;
  finally
    Ctx.List.Free;
  end;
end;


{ Button selection ---------------------------------------------------------- }

// Standard dialog control ids (Winapi.Windows): IDOK=1 .. IDCONTINUE=11.
function RoleToId(const S: String): Integer;
var
  L: String;
begin
  L := LowerCase(Trim(S));
  if L = 'ok'       then exit(IDOK);
  if L = 'cancel'   then exit(IDCANCEL);
  if L = 'abort'    then exit(IDABORT);
  if L = 'retry'    then exit(IDRETRY);
  if L = 'ignore'   then exit(IDIGNORE);
  if L = 'yes'      then exit(IDYES);
  if L = 'no'       then exit(IDNO);
  if L = 'close'    then exit(IDCLOSE);
  if L = 'help'     then exit(IDHELP);
  if (L = 'tryagain') or (L = 'try again') then exit(IDTRYAGAIN);
  if L = 'continue' then exit(IDCONTINUE);
  Result := 0;
end;


// Resolve ASelector against the dialog's buttons. On success ABtn is the matching
// button HWND (0 when matched by id/role but the button is not separately enumerable,
// e.g. a Task Dialog — the caller can still dispatch WM_COMMAND by id) and AId its id.
function ResolveButton(const AButtons: TList<HWND>; const ASelector: String;
  OUT ABtn: HWND; OUT AId: Integer; OUT ACap: String): Boolean;
var
  i, NumId, RoleId: Integer;
  Sel, Cap: String;
  B: HWND;
begin
  ABtn := 0; AId := 0; ACap := ''; Result := FALSE;
  Sel := Trim(ASelector);
  if Sel = '' then exit;

  { # By numeric id }
  if TryStrToInt(Sel, NumId) then
  begin
    for i := 0 to AButtons.Count - 1 do
      if GetDlgCtrlID(AButtons[i]) = NumId then
      begin
        ABtn := AButtons[i]; AId := NumId; ACap := StripAmp(WindowTextOf(ABtn));
        exit(TRUE);
      end;
    AId := NumId; exit(TRUE);   // not enumerable as a child Button; dispatch by id
  end;

  { # By caption — exact }
  for i := 0 to AButtons.Count - 1 do
  begin
    B := AButtons[i]; Cap := StripAmp(WindowTextOf(B));
    if SameText(Cap, Sel) then
    begin ABtn := B; AId := GetDlgCtrlID(B); ACap := Cap; exit(TRUE); end;
  end;

  { # By role keyword }
  // Ahead of the substring pass: a role word ('ok'/'no'/...) is a deliberate intent and must
  // beat a loose caption substring (e.g. 'no' inside 'Ignore'). Also reaches a localized common
  // button — 'ok' -> IDOK works even when the caption reads 'Aceptar'.
  RoleId := RoleToId(Sel);
  if RoleId <> 0 then
  begin
    for i := 0 to AButtons.Count - 1 do
      if GetDlgCtrlID(AButtons[i]) = RoleId then
      begin
        ABtn := AButtons[i]; AId := RoleId; ACap := StripAmp(WindowTextOf(ABtn));
        exit(TRUE);
      end;
    AId := RoleId; exit(TRUE);   // common button without a separate HWND; dispatch by id
  end;

  { # By caption — substring (loosest, last) }
  for i := 0 to AButtons.Count - 1 do
  begin
    B := AButtons[i]; Cap := StripAmp(WindowTextOf(B));
    if (Cap <> '') and ContainsText(Cap, Sel) then
    begin ABtn := B; AId := GetDlgCtrlID(B); ACap := Cap; exit(TRUE); end;
  end;
end;


{ Public: click ------------------------------------------------------------- }

function ClickNativeDialogButton(const AExclude: array of NativeUInt; ATargetDlg: NativeUInt;
  const ASelector: String; OUT AClickedId: Integer; OUT AClickedCaption: String;
  OUT AResolvedDlg: NativeUInt; OUT AReason: String; OUT AVia: String): Boolean;
var
  Ctx: TTopCtx;
  i: Integer;
  W, Dlg, MatchBtn: HWND;
  Buttons, Statics: TList<HWND>;
  MatchId: Integer;
  MatchCap: String;
  Res: DWORD_PTR;
  Sent: LRESULT;
  WParam: Winapi.Windows.WPARAM;
begin
  Result := FALSE;
  AClickedId := 0; AClickedCaption := ''; AResolvedDlg := 0; AReason := ''; AVia := '';

  { # Pick the dialog }
  Dlg := 0;
  Ctx.Pid := GetCurrentProcessId;
  Ctx.List := TList<HWND>.Create;
  try
    EnumWindows(@TopEnumProc, LPARAM(@Ctx));   // Z-order: first match is topmost
    for i := 0 to Ctx.List.Count - 1 do
    begin
      W := Ctx.List[i];
      if InExclude(W, AExclude) then Continue;
      Buttons := TList<HWND>.Create;
      Statics := TList<HWND>.Create;
      try
        CollectChildren(W, Buttons, Statics);
        if not LooksLikeDialog(W, Buttons.Count) then Continue;
        if (ATargetDlg = 0) or (HWND(ATargetDlg) = W) then
        begin
          Dlg := W;
          Break;
        end;
      finally
        Buttons.Free;
        Statics.Free;
      end;
    end;
  finally
    Ctx.List.Free;
  end;

  if Dlg = 0 then
  begin
    AReason := 'no_dialog';
    exit;
  end;
  AResolvedDlg := NativeUInt(Dlg);

  { # Resolve + dispatch the button }
  Buttons := TList<HWND>.Create;
  Statics := TList<HWND>.Create;
  try
    CollectChildren(Dlg, Buttons, Statics);
    if not ResolveButton(Buttons, ASelector, MatchBtn, MatchId, MatchCap) then
    begin
      AReason := 'button_not_found';
      exit;
    end;

    // Same-thread send (the dialog lives on the main thread, where this runs), so the
    // window proc is invoked synchronously: the button's WM_COMMAND reaches the dialog,
    // which calls EndDialog and unwinds its modal loop. SMTO_ABORTIFHUNG guards the rare
    // cross-thread dialog. BM_CLICK when we have the button HWND; WM_COMMAND-by-id when we
    // only resolved a standard id (Task Dialog common button with no enumerable child).
    Res := 0;
    if MatchBtn <> 0 then
    begin
      AVia := 'BM_CLICK';
      Sent := SendMessageTimeout(MatchBtn, BM_CLICK, 0, 0, SMTO_ABORTIFHUNG, 4000, @Res);
    end
    else
    begin
      // Unverifiable path, reported as such through AVia. A dialog with no command for this
      // id just ignores the message and the send still completes, so nothing in the return
      // values can tell "dismissed" from "ignored". The dialog's own reply is not a signal
      // either: DefDlgProc's return for an unhandled WM_COMMAND is not contractual (the
      // DialogProc TRUE/FALSE convention is documented for dialog procedures YOU write, and
      // the docs state the return is ignored for several messages), and we have not measured
      // what MessageBoxW / the Task Dialog actually return - so it is not used.
      AVia := 'WM_COMMAND';
      WParam := Winapi.Windows.WPARAM((MatchId and $FFFF) or (BN_CLICKED shl 16));
      Sent := SendMessageTimeout(Dlg, WM_COMMAND, WParam, 0, SMTO_ABORTIFHUNG, 4000, @Res);
    end;

    // A zero return means the send never completed: the window died between our enumeration
    // and the send, or a dialog owned by a non-main thread was hung and SMTO_ABORTIFHUNG
    // bailed out. Only the cross-thread case can actually trip it (for a same-thread window
    // the proc is called directly and the timeout is ignored), but answering clicked:true for
    // a click the OS says never landed would send the driver on to its next step against a
    // dialog that is still up. Res itself is NOT a success signal - BM_CLICK returns zero.
    if Sent = 0 then
    begin
      AReason := 'send_failed';
      exit;
    end;

    AClickedId := MatchId;
    AClickedCaption := MatchCap;
    Result := TRUE;
  finally
    Buttons.Free;
    Statics.Free;
  end;
end;

{$ELSE}   // Non-Windows: no Win32 dialogs to reach. Uniform empty/unsupported answers.

function NativeDialogsSupported: Boolean;
begin
  Result := FALSE;
end;

function EnumerateNativeDialogs(const AExclude: array of NativeUInt): TJSONArray;
begin
  Result := TJSONArray.Create;
end;

function ClickNativeDialogButton(const AExclude: array of NativeUInt; ATargetDlg: NativeUInt;
  const ASelector: String; OUT AClickedId: Integer; OUT AClickedCaption: String;
  OUT AResolvedDlg: NativeUInt; OUT AReason: String; OUT AVia: String): Boolean;
begin
  AClickedId := 0; AClickedCaption := ''; AResolvedDlg := 0; AVia := '';
  AReason := 'unsupported_platform';
  Result := FALSE;
end;

{$ENDIF}


end.
