unit Autopilot.Bridge.NativeDialogs;

{=============================================================================================================
   2026.11.19
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - Native Win32 dialog escape hatch: reaches MessageBox / Task Dialog / common dialogs with no TComponent
   - EnumerateNativeDialogs: lists this process's visible non-VCL top-level dialog windows as JSON (a Task Dialog's text through MSAA)
   - ClickNativeDialogButton: dispatches a button by role keyword, caption, or control id
   - SetNativeDialogFileName: fills the File name box of an Open/Save dialog, then (optionally) clicks a button
   - Interface is stdlib-only (System.JSON + NativeUInt); the body is MSWINDOWS-only
=============================================================================================================}

interface

uses
  System.JSON;

// TRUE on Windows (the only platform with Win32 dialogs the bridge can reach this way).
function NativeDialogsSupported: Boolean;

{ Enumerate native (non-component) top-level dialog windows of THIS process.
  AExclude = window handles to skip (the framework's own form windows + the app window), so the framework's TForm/TfmxForm windows are not mistaken for OS dialogs.
  Returns a JSON array (caller owns it); each node is ( hwnd, class, caption, text, buttons:[(id,caption,enabled)] ).
  buttons holds the VISIBLE Button windows only: a hidden one is never listed, and never matched by ClickNativeDialogButton or SetNativeDialogFileName.
  Empty array when no dialog is up, or always on non-Windows. }
function EnumerateNativeDialogs(const AExclude: array of NativeUInt): TJSONArray;

{ Find a native dialog (ATargetDlg=0 -> the topmost one) and click the button picked by ASelector.
  ASelector accepts a caption (exact, case-insensitive, '&' accelerator stripped), a role keyword ('ok'/'cancel'/'yes'/'no'/'retry'/'abort'/'ignore'/'close'/'tryagain'/'continue'/'help', matched by the button's control id), a caption substring, or a numeric control id.
  The selector must name exactly ONE child Button window: nothing is ever sent by id alone.
  Returns TRUE and sets AClickedId / AClickedCaption / AResolvedDlg on a dispatched click. AClickedId is 0 for a Task Dialog button (it has no control id).
  On FALSE, AReason is 'no_dialog' (nothing matched), 'button_not_found', 'button_ambiguous' (two or more buttons match: id 0 on a Task Dialog, a shared caption substring), 'button_disabled', or 'send_failed' (the button was found but SendMessageTimeout did not complete).
  AVia is always 'BN_CLICKED': the button's own click notification, sent to the button's parent window. A bridge older than 3.8.0 could also answer 'WM_COMMAND' (a blind send by id). }
function ClickNativeDialogButton(const AExclude: array of NativeUInt; ATargetDlg: NativeUInt;
  const ASelector: String; OUT AClickedId: Integer; OUT AClickedCaption: String;
  OUT AResolvedDlg: NativeUInt; OUT AReason: String; OUT AVia: String): Boolean;

{ Fill the "File name" box of a native file dialog (ATargetDlg=0 -> the topmost dialog) and, when ASelector is not empty, click the button it names (the rules of ClickNativeDialogButton).
  The box is the dialog's one VISIBLE Edit window: a Vista Open/Save dialog also holds a hidden Edit (the address bar), and the box has a different control id in the Open and the Save dialog, so it is never picked by id.
  The edit and the button are both resolved before anything is written, so a refusal changes nothing; then the text is set, read back, and only when it reads back exactly AFileName is the button clicked.
  AFileNameSet is TRUE when the box holds AFileName. Returns TRUE when everything asked for was done (the name set, and the click when ASelector is not empty).
  On FALSE, AReason is one of the reasons of ClickNativeDialogButton, or 'edit_not_found' (no visible Edit), 'edit_ambiguous' (two or more), 'edit_disabled', 'filename_not_set' (the box reads back another text, e.g. a name longer than the box accepts). }
function SetNativeDialogFileName(const AExclude: array of NativeUInt; ATargetDlg: NativeUInt;
  const AFileName, ASelector: String; OUT AFileNameSet: Boolean; OUT AClickedId: Integer; OUT AClickedCaption: String;
  OUT AResolvedDlg: NativeUInt; OUT AReason: String; OUT AVia: String): Boolean;

{ The dismiss_dialog answer fields that follow the list, shared by the VCL and the FMX bridge.
  ASelector = '' and AFileName = '': nothing is added (the call only lists).
  ASelector: clicked, and on success clickedId, clickedCaption, dialogHwnd, via; on failure reason.
  AFileName: fileNameSet and dialogHwnd too (the MCP tool sends the button in a second call to that dialog); with ASelector the click runs only after the name reads back. }
procedure AddDismissDialogFields(AWrap: TJSONObject; const AExclude: array of NativeUInt; ATargetDlg: NativeUInt;
  const ASelector, AFileName: String);


implementation

{$IFDEF MSWINDOWS}
uses
  Winapi.Windows, Winapi.Messages, Winapi.ActiveX, Winapi.oleacc,
  System.SysUtils, System.StrUtils, System.Variants, System.Generics.Collections;


function NativeDialogsSupported: Boolean;
begin
  Result := TRUE;
end;


{ Win32 reads --------------------------------------------------------------- }

const
  TextReadTimeoutMs = 1000;   // per-read cap; after the first hung read SMTO_ABORTIFHUNG fails the rest fast

{ GetWindowText would be simpler, but for a window of THIS process it sends WM_GETTEXT and waits with NO timeout (learn.microsoft.com GetWindowTextW, Remarks: "if the target window is not responding and it belongs to the calling application, GetWindowText will cause the calling application to become unresponsive") — and every window enumerated here IS same-process.
  A dialog owned by a hung non-main thread would freeze the dispatcher, and with it the whole app.
  SendMessageTimeout degrades that to an empty string instead.
  For a window on the CURRENT thread the proc is called directly and the timeout is ignored (SendMessageTimeoutW, Remarks), so the normal main-thread-dialog path is unaffected. }
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
  if SendMessageTimeout(AWnd, WM_GETTEXT, WPARAM(Len) + 1, LPARAM(PChar(Result)), SMTO_ABORTIFHUNG, TextReadTimeoutMs, @Copied) = 0 then exit('');
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
    Edits  : TList<HWND>;   // NIL = not wanted; else the VISIBLE Edit windows only
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
  if SameText(Cls, 'Button')
  then
    begin
      { A hidden button is one a person cannot click, so it is neither listed nor matched. A Vista Open/Save dialog holds such buttons: Help (id 1038, disabled) and, on Save, a caption-less id 0. }
      if IsWindowVisible(AWnd)
      then Ctx.Buttons.Add(AWnd);
    end
  else
    if SameText(Cls, 'Static')
    then Ctx.Statics.Add(AWnd)
    else
      if (Ctx.Edits <> NIL) and SameText(Cls, 'Edit') and IsWindowVisible(AWnd)
      then Ctx.Edits.Add(AWnd);
  Result := TRUE;
end;


{ EnumChildWindows walks every descendant, not only the direct children: a Vista file dialog nests its File name Edit 3 levels deep. }
procedure CollectChildren(ADlg: HWND; AButtons, AStatics: TList<HWND>; AEdits: TList<HWND> = NIL);
var
  Ctx: TChildCtx;
begin
  { AButtons gets the VISIBLE Button windows only; AStatics every Static window. }
  Ctx.Buttons := AButtons;
  Ctx.Statics := AStatics;
  Ctx.Edits   := AEdits;
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
  if (WndPid = Ctx.Pid) and IsWindowVisible(AWnd)
  then Ctx.List.Add(AWnd);
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


{ A native dialog = a visible top-level window of this process, not one of OUR windows, that either uses the system dialog class '#32770' (MessageBox / common dialogs) or owns at least one visible child Button (Task Dialog / custom dialog).
  AButtonCount counts the visible buttons only, so a window of another class whose buttons are all hidden is not a dialog. }
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
      if Result <> ''
      then Result := Result + ' ';
      Result := Result + S;
    end;
end;


const
  MaxAccDepth = 6;     // a Task Dialog nests its texts 2-3 levels deep
  MaxAccNodes = 300;   // hard cap on the walk, whatever the dialog holds


{ Appends the name of every static-text / text element under AAcc to AText, depth first. }
procedure CollectAccTexts(const AAcc: IAccessible; ADepth: Integer; var ANodes: Integer; var AText: String);
var
  Count, i: Integer;
  Disp: IDispatch;
  Child: IAccessible;
  Role: OleVariant;
  Name: WideString;
  S: String;
begin
  if (AAcc = NIL) or (ADepth > MaxAccDepth) then EXIT;
  Count := 0;
  if Failed(AAcc.Get_accChildCount(Count)) then EXIT;
  for i := 1 to Count do
    begin
      Inc(ANodes);
      if ANodes > MaxAccNodes then EXIT;
      Disp := NIL;
      Child := NIL;
      if (AAcc.Get_accChild(i, Disp) = S_OK) and (Disp <> NIL) and Supports(Disp, IAccessible, Child)
      then
        begin
          { A full child object: its own name and role, then its children. }
          if Succeeded(Child.Get_accRole(CHILDID_SELF, Role)) and VarIsOrdinal(Role)
            and ((Integer(Role) = ROLE_SYSTEM_STATICTEXT) or (Integer(Role) = ROLE_SYSTEM_TEXT))
            and Succeeded(Child.Get_accName(CHILDID_SELF, Name)) then
            begin
              S := Trim(String(Name));
              if S <> '' then
                if AText = '' then AText := S else AText := AText + ' ' + S;
            end;
          CollectAccTexts(Child, ADepth + 1, ANodes, AText);
        end
      else
        { A simple element: the parent answers for it by child id. }
        if Succeeded(AAcc.Get_accRole(i, Role)) and VarIsOrdinal(Role)
          and ((Integer(Role) = ROLE_SYSTEM_STATICTEXT) or (Integer(Role) = ROLE_SYSTEM_TEXT))
          and Succeeded(AAcc.Get_accName(i, Name)) then
          begin
            S := Trim(String(Name));
            if S <> '' then
              if AText = '' then AText := S else AText := AText + ' ' + S;
          end;
    end;
end;


{ The texts of a Task Dialog (and Delphi 13's ShowMessage / MessageDlg, which show one).
  A Task Dialog draws its main instruction and content inside a DirectUIHWND window: no Static child exists, so JoinStaticText finds nothing.
  MSAA (Active Accessibility) is the documented way to read them; each text is a static-text element of the DirectUIHWND.
  The DirectUIHWND is tested with SendMessageTimeout(WM_NULL) first: AccessibleObjectFromWindow sends WM_GETOBJECT with no timeout, and the guard keeps a hung dialog thread from freezing the caller (as WindowTextOf does for WM_GETTEXT).
  COM is initialized for the call when the thread has no apartment yet; a thread already in another apartment mode works as it is. }
function DirectUIText(ADlg: HWND): String;
var
  DUI: HWND;
  Hr: HRESULT;
  NeedUninit: Boolean;
  Acc: IAccessible;
  Nodes: Integer;
  Dummy: DWORD_PTR;
begin
  Result := '';
  DUI := FindWindowEx(ADlg, 0, 'DirectUIHWND', NIL);
  if DUI = 0 then EXIT;
  if SendMessageTimeout(DUI, WM_NULL, 0, 0, SMTO_ABORTIFHUNG, TextReadTimeoutMs, @Dummy) = 0 then EXIT;
  Hr := CoInitializeEx(NIL, COINIT_APARTMENTTHREADED);
  NeedUninit := Succeeded(Hr);   // S_OK and S_FALSE both need the matching CoUninitialize
  try
    Acc := NIL;
    if Succeeded(AccessibleObjectFromWindow(DUI, OBJID_CLIENT, IID_IAccessible, Acc)) and (Acc <> NIL) then
      begin
        Nodes := 0;
        CollectAccTexts(Acc, 1, Nodes, Result);
      end;
    Acc := NIL;   // release before CoUninitialize
  finally
    if NeedUninit
    then CoUninitialize;
  end;
end;


function BuildDialogNode(ADlg: HWND; const AButtons, AStatics: TList<HWND>): TJSONObject;
var
  Text: String;
begin
  Result := TJSONObject.Create;
  Result.AddPair('hwnd', TJSONNumber.Create(Int64(ADlg)));
  Result.AddPair('class', ClassNameOf(ADlg));
  Result.AddPair('caption', WindowTextOf(ADlg));
  Text := JoinStaticText(AStatics);
  if Text = ''
  then Text := DirectUIText(ADlg);
  Result.AddPair('text', Text);
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
          if LooksLikeDialog(W, Buttons.Count)
          then Result.AddElement(BuildDialogNode(W, Buttons, Statics));
        finally
          FreeAndNil(Buttons);
          FreeAndNil(Statics);
        end;
      end;
  finally
    FreeAndNil(Ctx.List);
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


type
  TButtonMatch = (bmById, bmByExactCaption, bmBySubstring);


{ TRUE when button B matches ASelector in the way AKind names. }
function ButtonMatches(B: HWND; AKind: TButtonMatch; const ASelector: String; AId: Integer): Boolean;
var
  Cap: String;
begin
  case AKind of
    bmById          : Result := GetDlgCtrlID(B) = AId;
    bmByExactCaption: Result := SameText(StripAmp(WindowTextOf(B)), ASelector);
  else
    Cap := StripAmp(WindowTextOf(B));
    Result := (Cap <> '') and ContainsText(Cap, ASelector);
  end;
end;


{ Picks the one button that matches. Exactly one match: TRUE with ABtn. None: FALSE, AReason 'button_not_found'. Two or more: FALSE, AReason 'button_ambiguous' - the first match is never taken, because it may be the wrong one ('all' in 'Yes to All' and 'No to All'; id 0 on every Task Dialog button). }
function PickOneButton(const AButtons: TList<HWND>; AKind: TButtonMatch; const ASelector: String; AId: Integer;
  OUT ABtn: HWND; OUT AReason: String): Boolean;
var
  i, Count: Integer;
begin
  ABtn := 0;
  Count := 0;
  for i := 0 to AButtons.Count - 1 do
    if ButtonMatches(AButtons[i], AKind, ASelector, AId) then
      begin
        Inc(Count);
        if Count = 1
        then ABtn := AButtons[i];
      end;
  case Count of
    0: AReason := 'button_not_found';
    1: AReason := '';
  else
    AReason := 'button_ambiguous';
    ABtn := 0;
  end;
  Result := Count = 1;
end;


{ Resolve ASelector to ONE button window of the dialog.
  On success ABtn is that button's HWND (never 0), AId its control id (0 on a Task Dialog button) and ACap its caption.
  A selector that names no button window, or more than one, is refused with AReason 'button_not_found' / 'button_ambiguous': a refused click is safe, a click on a guessed button can destroy data.
  So nothing is ever dispatched by id alone. Measured on a Task Dialog: WM_COMMAND with an id no button has is ignored, but TDM_CLICK_BUTTON with such an id closes the box and returns that id. }
function ResolveButton(const AButtons: TList<HWND>; const ASelector: String;
  OUT ABtn: HWND; OUT AId: Integer; OUT ACap: String; OUT AReason: String): Boolean;
var
  NumId, RoleId: Integer;
  Sel: String;
begin
  ABtn := 0; AId := 0; ACap := ''; AReason := 'button_not_found'; Result := FALSE;
  Sel := Trim(ASelector);
  if Sel = '' then EXIT;

  if TryStrToInt(Sel, NumId)
  then
    { # By numeric id }
    Result := PickOneButton(AButtons, bmById, Sel, NumId, ABtn, AReason)
  else
    begin
      { # By caption - exact }
      Result := PickOneButton(AButtons, bmByExactCaption, Sel, 0, ABtn, AReason);
      if not Result and (AReason = 'button_not_found') then
        begin
          { # By role keyword }
          { Ahead of the substring pass: a role word ('ok'/'no'/...) is a deliberate intent and must beat a loose caption substring (e.g. 'no' inside 'Ignore').
            Also reaches a localized MessageBox button: 'ok' -> IDOK works even when the caption reads 'Aceptar'.
            A role with no button of that id is refused, never passed on to the substring pass. }
          RoleId := RoleToId(Sel);
          if RoleId <> 0
          then Result := PickOneButton(AButtons, bmById, Sel, RoleId, ABtn, AReason)
          else
            { # By caption - substring (loosest, last) }
            Result := PickOneButton(AButtons, bmBySubstring, Sel, 0, ABtn, AReason);
        end;
    end;

  if Result then
    begin
      AId  := GetDlgCtrlID(ABtn);
      ACap := StripAmp(WindowTextOf(ABtn));
    end;
end;


{ Public: click ------------------------------------------------------------- }

{ The topmost native dialog of this process (ATargetDlg=0), or the one whose handle is ATargetDlg; 0 when none is up. }
function FindNativeDialog(const AExclude: array of NativeUInt; ATargetDlg: NativeUInt): HWND;
var
  Ctx: TTopCtx;
  i: Integer;
  W: HWND;
  Buttons, Statics: TList<HWND>;
begin
  Result := 0;
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
          if (ATargetDlg = 0) or (HWND(ATargetDlg) = W)
          then EXIT(W);
        finally
          FreeAndNil(Buttons);
          FreeAndNil(Statics);
        end;
      end;
  finally
    FreeAndNil(Ctx.List);
  end;
end;


{ Sends the button's own click notification; FALSE with AReason 'send_failed' when it could not be delivered. }
function SendButtonClick(ABtn: HWND; AId: Integer; OUT AReason: String): Boolean;
var
  Parent: HWND;
  Res: DWORD_PTR;
  Sent: LRESULT;
  WParam: Winapi.Windows.WPARAM;
begin
  AReason := '';
  { The button's own click notification, sent where the button itself sends it: to its PARENT window ("The parent window of the button receives this notification code through the WM_COMMAND message", https://learn.microsoft.com/en-us/windows/win32/controls/bn-clicked), with its own id and its HWND in lParam.
    On a MessageBox the parent is the dialog. On a Task Dialog (Delphi's MessageDlg) it is NOT: each button sits in a CtrlNotifySink window inside a DirectUIHWND, with control id 0.
    Measured: WM_COMMAND id 0 sent to the Task Dialog itself makes it return its DEFAULT button (button 'No' gave Yes); sent to the CtrlNotifySink it returns the button clicked.
    Not BM_CLICK: "If the button is in a dialog box and the dialog box is not active, the BM_CLICK message might fail" (https://learn.microsoft.com/en-us/windows/win32/controls/bm-click), and activating the dialog would steal the focus.
    Seen failing: a MessageBox shown during start-up of a LightSaber app (DnaBaser5, Win64) ignored BM_CLICK; WM_COMMAND with its id closed it.
    Same-thread send (the dialog lives on the main thread, where this runs), so the window proc runs synchronously; SMTO_ABORTIFHUNG guards the rare cross-thread dialog. }
  Parent := GetParent(ABtn);
  if Parent = 0 then
    begin
      AReason := 'send_failed';
      EXIT(FALSE);
    end;
  Res := 0;
  WParam := Winapi.Windows.WPARAM((AId and $FFFF) or (BN_CLICKED shl 16));
  Sent := SendMessageTimeout(Parent, WM_COMMAND, WParam, LPARAM(ABtn), SMTO_ABORTIFHUNG, 4000, @Res);

  { A zero return means the send never completed: the window died between our enumeration and the send, or a dialog owned by a non-main thread was hung and SMTO_ABORTIFHUNG bailed out.
    Only the cross-thread case can actually trip it (for a same-thread window the proc is called directly and the timeout is ignored), but answering clicked:true for a click the OS says never landed would send the driver on to its next step against a dialog that is still up.
    Res itself is NOT a success signal. }
  Result := Sent <> 0;
  if not Result
  then AReason := 'send_failed';
end;


function ClickNativeDialogButton(const AExclude: array of NativeUInt; ATargetDlg: NativeUInt;
  const ASelector: String; OUT AClickedId: Integer; OUT AClickedCaption: String;
  OUT AResolvedDlg: NativeUInt; OUT AReason: String; OUT AVia: String): Boolean;
var
  Dlg, MatchBtn: HWND;
  Buttons, Statics: TList<HWND>;
  MatchId: Integer;
  MatchCap: String;
begin
  Result := FALSE;
  AClickedId := 0; AClickedCaption := ''; AResolvedDlg := 0; AReason := ''; AVia := '';

  { # Pick the dialog }
  Dlg := FindNativeDialog(AExclude, ATargetDlg);
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
    if not ResolveButton(Buttons, ASelector, MatchBtn, MatchId, MatchCap, AReason) then EXIT;

    { A real mouse click does nothing on a disabled button, so neither do we. }
    if not IsWindowEnabled(MatchBtn) then
      begin
        AReason := 'button_disabled';
        EXIT;
      end;

    AVia := 'BN_CLICKED';
    if not SendButtonClick(MatchBtn, MatchId, AReason) then EXIT;

    AClickedId := MatchId;
    AClickedCaption := MatchCap;
    Result := TRUE;
  finally
    FreeAndNil(Buttons);
    FreeAndNil(Statics);
  end;
end;


{ Public: file name --------------------------------------------------------- }

function SetNativeDialogFileName(const AExclude: array of NativeUInt; ATargetDlg: NativeUInt;
  const AFileName, ASelector: String; OUT AFileNameSet: Boolean; OUT AClickedId: Integer; OUT AClickedCaption: String;
  OUT AResolvedDlg: NativeUInt; OUT AReason: String; OUT AVia: String): Boolean;
var
  Dlg, Edit, MatchBtn: HWND;
  Buttons, Statics, Edits: TList<HWND>;
  MatchId: Integer;
  MatchCap: String;
  Res: DWORD_PTR;
  Clicking: Boolean;
begin
  Result := FALSE;
  AFileNameSet := FALSE; AClickedId := 0; AClickedCaption := ''; AResolvedDlg := 0; AReason := ''; AVia := '';
  Clicking := Trim(ASelector) <> '';
  MatchBtn := 0;
  MatchId := 0;

  Dlg := FindNativeDialog(AExclude, ATargetDlg);
  if Dlg = 0 then
    begin
      AReason := 'no_dialog';
      EXIT;
    end;
  AResolvedDlg := NativeUInt(Dlg);

  Buttons := TList<HWND>.Create;
  Statics := TList<HWND>.Create;
  Edits   := TList<HWND>.Create;
  try
    CollectChildren(Dlg, Buttons, Statics, Edits);

    { # Resolve the box and the button before anything is written: a refusal changes nothing }
    case Edits.Count of
      0: AReason := 'edit_not_found';
      1: AReason := '';
    else
      AReason := 'edit_ambiguous';
    end;
    if AReason <> '' then EXIT;
    Edit := Edits[0];
    if not IsWindowEnabled(Edit) then
      begin
        AReason := 'edit_disabled';
        EXIT;
      end;
    if Clicking then
      begin
        if not ResolveButton(Buttons, ASelector, MatchBtn, MatchId, MatchCap, AReason) then EXIT;
        if not IsWindowEnabled(MatchBtn) then
          begin
            AReason := 'button_disabled';
            EXIT;
          end;
      end;

    { # Write the name and read it back }
    { WM_SETTEXT through SendMessageTimeout for the reason WindowTextOf gives. Measured on the Vista Open and Save dialogs of TOpenDialog/TSaveDialog: the text set this way is the FileName the dialog returns after its Open/Save button is clicked. }
    Res := 0;
    if SendMessageTimeout(Edit, WM_SETTEXT, 0, LPARAM(PChar(AFileName)), SMTO_ABORTIFHUNG, 4000, @Res) = 0 then
      begin
        AReason := 'send_failed';
        EXIT;
      end;
    AFileNameSet := WindowTextOf(Edit) = AFileName;
    if not AFileNameSet then
      begin
        AReason := 'filename_not_set';
        EXIT;
      end;
    if not Clicking then EXIT(TRUE);

    { # Click }
    AVia := 'BN_CLICKED';
    if not SendButtonClick(MatchBtn, MatchId, AReason) then EXIT;
    AClickedId := MatchId;
    AClickedCaption := MatchCap;
    Result := TRUE;
  finally
    FreeAndNil(Buttons);
    FreeAndNil(Statics);
    FreeAndNil(Edits);
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

function SetNativeDialogFileName(const AExclude: array of NativeUInt; ATargetDlg: NativeUInt;
  const AFileName, ASelector: String; OUT AFileNameSet: Boolean; OUT AClickedId: Integer; OUT AClickedCaption: String;
  OUT AResolvedDlg: NativeUInt; OUT AReason: String; OUT AVia: String): Boolean;
begin
  AFileNameSet := FALSE; AClickedId := 0; AClickedCaption := ''; AResolvedDlg := 0; AVia := '';
  AReason := 'unsupported_platform';
  Result := FALSE;
end;

{$ENDIF}


{ Shared by the VCL and the FMX bridge ----------------------------------------- }

procedure AddDismissDialogFields(AWrap: TJSONObject; const AExclude: array of NativeUInt; ATargetDlg: NativeUInt;
  const ASelector, AFileName: String);
var
  Done, NameSet, Clicking: Boolean;
  ClickedId: Integer;
  ClickedCap, Reason, Via: String;
  ResolvedDlg: NativeUInt;
begin
  Clicking := ASelector <> '';
  if AFileName <> ''
  then
    begin
      Done := SetNativeDialogFileName(AExclude, ATargetDlg, AFileName, ASelector, NameSet, ClickedId, ClickedCap, ResolvedDlg, Reason, Via);
      AWrap.AddPair('fileNameSet', TJSONBool.Create(NameSet));
    end
  else
    if Clicking
    then Done := ClickNativeDialogButton(AExclude, ATargetDlg, ASelector, ClickedId, ClickedCap, ResolvedDlg, Reason, Via)
    else EXIT;

  if Clicking
  then AWrap.AddPair('clicked', TJSONBool.Create(Done));
  if Done and Clicking then
    begin
      AWrap.AddPair('clickedId', TJSONNumber.Create(ClickedId));
      AWrap.AddPair('clickedCaption', ClickedCap);
    end;
  { The MCP tool sends the button in a second call to this same dialog, so a fileName answer names the dialog even without a click. }
  if ResolvedDlg <> 0
  then
    if Done or (AFileName <> '')
    then AWrap.AddPair('dialogHwnd', TJSONNumber.Create(Int64(ResolvedDlg)));
  if Done and Clicking
  then AWrap.AddPair('via', Via);
  if not Done
  then AWrap.AddPair('reason', Reason);
end;


end.
