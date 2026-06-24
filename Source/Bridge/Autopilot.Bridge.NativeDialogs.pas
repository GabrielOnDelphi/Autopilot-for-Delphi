UNIT Autopilot.Bridge.NativeDialogs;

(*=====================================================
   2026.06.24
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────┐
   │  SHARED interface / WIN32 body  │   portable types; the body is MSWINDOWS-only
   └──────────────────────────────┘

   Native-dialog escape hatch.

   The component-tree tools (list_tree / click / set_property) walk Screen.Forms[]
   and the TComponent graph. An OS dialog raised by MessageBox / Application.MessageBox
   / a Vista Task Dialog (ShowMessage, MessageDlg) / a common file dialog is NOT a
   VCL/FMX component — it is a raw Win32 window with no TComponent and no RTTI, so the
   path-based tools return -32001 not_found against it. This unit reaches those dialogs
   directly through Win32 window messaging (EnumWindows + child Button HWNDs + WM_COMMAND),
   which is independent of the component model.

   Why this still works while a modal dialog "blocks" the app: a visible native dialog
   means the main thread is running a nested modal message loop (that loop is the only
   thing painting the dialog). That loop pumps WM_NULL -> TApplication.WndProc ->
   CheckSynchronize (Vcl.Forms.pas:13085), so the bridge's TThread.Queue marshalling
   still reaches the main thread. The dispatcher runs there, enumerates the dialog, and
   SendMessage()s its button — same-thread, so it dispatches synchronously and EndDialog
   unwinds the modal loop. See CLAUDE.md "Native dialogs".

   The interface is stdlib-only (System.JSON + NativeUInt for handles) so .Vcl and .Fmx
   can call it with no platform guard. On non-Windows the bodies return empty/unsupported.
=====================================================*)

INTERFACE

USES
  System.JSON;

/// TRUE on Windows (the only platform with Win32 dialogs the bridge can reach this way).
FUNCTION NativeDialogsSupported: Boolean;

/// Enumerate native (non-component) top-level dialog windows of THIS process.
/// AExclude = window handles to skip (the framework's own form windows + the app window),
/// so the framework's TForm/TfmxForm windows are not mistaken for OS dialogs.
/// Returns a JSON array (caller owns it); each node is
/// { hwnd, class, caption, text, buttons:[{id,caption,enabled}] }.
/// Empty array when no dialog is up, or always on non-Windows.
FUNCTION EnumerateNativeDialogs(CONST AExclude: ARRAY OF NativeUInt): TJSONArray;

/// Find a native dialog (ATargetDlg=0 -> the topmost one) and click the button picked
/// by ASelector. ASelector accepts a role keyword ('ok'/'cancel'/'yes'/'no'/'retry'/
/// 'abort'/'ignore'/'close'/'tryagain'/'continue'/'help'), a caption (exact then
/// substring, case-insensitive, '&' accelerator stripped), or a numeric control id.
/// Returns TRUE and sets AClickedId / AClickedCaption / AResolvedDlg on a dispatched click.
/// On FALSE, AReason is 'no_dialog' (nothing matched) or 'button_not_found'.
FUNCTION ClickNativeDialogButton(CONST AExclude: ARRAY OF NativeUInt; ATargetDlg: NativeUInt;
  CONST ASelector: String; OUT AClickedId: Integer; OUT AClickedCaption: String;
  OUT AResolvedDlg: NativeUInt; OUT AReason: String): Boolean;


IMPLEMENTATION

{$IFDEF MSWINDOWS}
USES
  Winapi.Windows, Winapi.Messages,
  System.SysUtils, System.StrUtils, System.Generics.Collections;


FUNCTION NativeDialogsSupported: Boolean;
BEGIN
  Result := TRUE;
END;


{ Win32 reads --------------------------------------------------------------- }

FUNCTION WindowTextOf(AWnd: HWND): String;
VAR
  Len: Integer;
BEGIN
  Len := GetWindowTextLength(AWnd);
  if Len <= 0 then EXIT('');
  SetLength(Result, Len);
  Len := GetWindowText(AWnd, PChar(Result), Len + 1);   // nMaxCount includes the null terminator
  if Len < 0 then Len := 0;
  SetLength(Result, Len);
END;


FUNCTION ClassNameOf(AWnd: HWND): String;
VAR
  Buf: ARRAY[0..255] OF Char;
  N: Integer;
BEGIN
  N := GetClassName(AWnd, Buf, Length(Buf));
  SetString(Result, Buf, N);
END;


// Drop '&' accelerator markers so a caption reported / matched is what the user sees.
FUNCTION StripAmp(CONST S: String): String;
BEGIN
  Result := StringReplace(S, '&', '', [rfReplaceAll]);
END;


{ Child enumeration --------------------------------------------------------- }

TYPE
  TChildCtx = RECORD
    Buttons: TList<HWND>;
    Statics: TList<HWND>;
  END;
  PChildCtx = ^TChildCtx;

  TTopCtx = RECORD
    Pid : DWORD;
    List: TList<HWND>;
  END;
  PTopCtx = ^TTopCtx;


FUNCTION ChildEnumProc(AWnd: HWND; AParam: LPARAM): BOOL; STDCALL;
VAR
  Ctx: PChildCtx;
  Cls: String;
BEGIN
  Ctx := PChildCtx(AParam);
  Cls := ClassNameOf(AWnd);
  if SameText(Cls, 'Button') then
    Ctx.Buttons.Add(AWnd)
  else if SameText(Cls, 'Static') then
    Ctx.Statics.Add(AWnd);
  Result := TRUE;
END;


PROCEDURE CollectChildren(ADlg: HWND; AButtons, AStatics: TList<HWND>);
VAR
  Ctx: TChildCtx;
BEGIN
  Ctx.Buttons := AButtons;
  Ctx.Statics := AStatics;
  EnumChildWindows(ADlg, @ChildEnumProc, LPARAM(@Ctx));
END;


FUNCTION TopEnumProc(AWnd: HWND; AParam: LPARAM): BOOL; STDCALL;
VAR
  Ctx: PTopCtx;
  WndPid: DWORD;
BEGIN
  Ctx := PTopCtx(AParam);
  WndPid := 0;
  GetWindowThreadProcessId(AWnd, WndPid);
  if (WndPid = Ctx.Pid) and IsWindowVisible(AWnd) then
    Ctx.List.Add(AWnd);
  Result := TRUE;
END;


FUNCTION InExclude(AWnd: HWND; CONST AExclude: ARRAY OF NativeUInt): Boolean;
VAR
  i: Integer;
BEGIN
  for i := Low(AExclude) to High(AExclude) do
    if HWND(AExclude[i]) = AWnd then EXIT(TRUE);
  Result := FALSE;
END;


// A native dialog = a visible top-level window of this process, not one of OUR windows,
// that either uses the system dialog class '#32770' (MessageBox / common dialogs) or owns
// at least one child Button (Task Dialog / custom dialog).
FUNCTION LooksLikeDialog(AWnd: HWND; AButtonCount: Integer): Boolean;
BEGIN
  Result := SameText(ClassNameOf(AWnd), '#32770') or (AButtonCount > 0);
END;


{ JSON shaping -------------------------------------------------------------- }

FUNCTION BuildButtonsArray(CONST AButtons: TList<HWND>): TJSONArray;
VAR
  i: Integer;
  B: HWND;
  Node: TJSONObject;
BEGIN
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
END;


FUNCTION JoinStaticText(CONST AStatics: TList<HWND>): String;
VAR
  i: Integer;
  S: String;
BEGIN
  Result := '';
  for i := 0 to AStatics.Count - 1 do
  begin
    S := Trim(WindowTextOf(AStatics[i]));
    if S = '' then Continue;
    if Result <> '' then Result := Result + ' ';
    Result := Result + S;
  end;
END;


FUNCTION BuildDialogNode(ADlg: HWND; CONST AButtons, AStatics: TList<HWND>): TJSONObject;
BEGIN
  Result := TJSONObject.Create;
  Result.AddPair('hwnd', TJSONNumber.Create(Int64(ADlg)));
  Result.AddPair('class', ClassNameOf(ADlg));
  Result.AddPair('caption', WindowTextOf(ADlg));
  Result.AddPair('text', JoinStaticText(AStatics));
  Result.AddPair('buttons', BuildButtonsArray(AButtons));
END;


{ Public: enumerate --------------------------------------------------------- }

FUNCTION EnumerateNativeDialogs(CONST AExclude: ARRAY OF NativeUInt): TJSONArray;
VAR
  Ctx: TTopCtx;
  i: Integer;
  W: HWND;
  Buttons, Statics: TList<HWND>;
BEGIN
  Result := TJSONArray.Create;
  Ctx.Pid := GetCurrentProcessId;
  Ctx.List := TList<HWND>.Create;
  TRY
    EnumWindows(@TopEnumProc, LPARAM(@Ctx));
    for i := 0 to Ctx.List.Count - 1 do
    begin
      W := Ctx.List[i];
      if InExclude(W, AExclude) then Continue;
      Buttons := TList<HWND>.Create;
      Statics := TList<HWND>.Create;
      TRY
        CollectChildren(W, Buttons, Statics);
        if LooksLikeDialog(W, Buttons.Count) then
          Result.AddElement(BuildDialogNode(W, Buttons, Statics));
      FINALLY
        Buttons.Free;
        Statics.Free;
      END;
    end;
  FINALLY
    Ctx.List.Free;
  END;
END;


{ Button selection ---------------------------------------------------------- }

// Standard dialog control ids (Winapi.Windows): IDOK=1 .. IDCONTINUE=11.
FUNCTION RoleToId(CONST S: String): Integer;
VAR
  L: String;
BEGIN
  L := LowerCase(Trim(S));
  if L = 'ok'       then EXIT(IDOK);
  if L = 'cancel'   then EXIT(IDCANCEL);
  if L = 'abort'    then EXIT(IDABORT);
  if L = 'retry'    then EXIT(IDRETRY);
  if L = 'ignore'   then EXIT(IDIGNORE);
  if L = 'yes'      then EXIT(IDYES);
  if L = 'no'       then EXIT(IDNO);
  if L = 'close'    then EXIT(IDCLOSE);
  if L = 'help'     then EXIT(IDHELP);
  if (L = 'tryagain') or (L = 'try again') then EXIT(IDTRYAGAIN);
  if L = 'continue' then EXIT(IDCONTINUE);
  Result := 0;
END;


// Resolve ASelector against the dialog's buttons. On success ABtn is the matching
// button HWND (0 when matched by id/role but the button is not separately enumerable,
// e.g. a Task Dialog — the caller can still dispatch WM_COMMAND by id) and AId its id.
FUNCTION ResolveButton(CONST AButtons: TList<HWND>; CONST ASelector: String;
  OUT ABtn: HWND; OUT AId: Integer; OUT ACap: String): Boolean;
VAR
  i, NumId, RoleId: Integer;
  Sel, Cap: String;
  B: HWND;
BEGIN
  ABtn := 0; AId := 0; ACap := ''; Result := FALSE;
  Sel := Trim(ASelector);
  if Sel = '' then EXIT;

  { # By numeric id }
  if TryStrToInt(Sel, NumId) then
  begin
    for i := 0 to AButtons.Count - 1 do
      if GetDlgCtrlID(AButtons[i]) = NumId then
      begin
        ABtn := AButtons[i]; AId := NumId; ACap := StripAmp(WindowTextOf(ABtn));
        EXIT(TRUE);
      end;
    AId := NumId; EXIT(TRUE);   // not enumerable as a child Button; dispatch by id
  end;

  { # By caption — exact then substring }
  for i := 0 to AButtons.Count - 1 do
  begin
    B := AButtons[i]; Cap := StripAmp(WindowTextOf(B));
    if SameText(Cap, Sel) then
    begin ABtn := B; AId := GetDlgCtrlID(B); ACap := Cap; EXIT(TRUE); end;
  end;
  for i := 0 to AButtons.Count - 1 do
  begin
    B := AButtons[i]; Cap := StripAmp(WindowTextOf(B));
    if (Cap <> '') and ContainsText(Cap, Sel) then
    begin ABtn := B; AId := GetDlgCtrlID(B); ACap := Cap; EXIT(TRUE); end;
  end;

  { # By role keyword }
  RoleId := RoleToId(Sel);
  if RoleId <> 0 then
  begin
    for i := 0 to AButtons.Count - 1 do
      if GetDlgCtrlID(AButtons[i]) = RoleId then
      begin
        ABtn := AButtons[i]; AId := RoleId; ACap := StripAmp(WindowTextOf(ABtn));
        EXIT(TRUE);
      end;
    AId := RoleId; EXIT(TRUE);   // common button without a separate HWND; dispatch by id
  end;
END;


{ Public: click ------------------------------------------------------------- }

FUNCTION ClickNativeDialogButton(CONST AExclude: ARRAY OF NativeUInt; ATargetDlg: NativeUInt;
  CONST ASelector: String; OUT AClickedId: Integer; OUT AClickedCaption: String;
  OUT AResolvedDlg: NativeUInt; OUT AReason: String): Boolean;
VAR
  Ctx: TTopCtx;
  i: Integer;
  W, Dlg, MatchBtn: HWND;
  Buttons, Statics: TList<HWND>;
  MatchId: Integer;
  MatchCap: String;
  Res: DWORD_PTR;
  WParam: Winapi.Windows.WPARAM;
BEGIN
  Result := FALSE;
  AClickedId := 0; AClickedCaption := ''; AResolvedDlg := 0; AReason := '';

  { # Pick the dialog }
  Dlg := 0;
  Ctx.Pid := GetCurrentProcessId;
  Ctx.List := TList<HWND>.Create;
  TRY
    EnumWindows(@TopEnumProc, LPARAM(@Ctx));   // Z-order: first match is topmost
    for i := 0 to Ctx.List.Count - 1 do
    begin
      W := Ctx.List[i];
      if InExclude(W, AExclude) then Continue;
      Buttons := TList<HWND>.Create;
      Statics := TList<HWND>.Create;
      TRY
        CollectChildren(W, Buttons, Statics);
        if not LooksLikeDialog(W, Buttons.Count) then Continue;
        if (ATargetDlg = 0) or (HWND(ATargetDlg) = W) then
        begin
          Dlg := W;
          Break;
        end;
      FINALLY
        Buttons.Free;
        Statics.Free;
      END;
    end;
  FINALLY
    Ctx.List.Free;
  END;

  if Dlg = 0 then
  begin
    AReason := 'no_dialog';
    EXIT;
  end;
  AResolvedDlg := NativeUInt(Dlg);

  { # Resolve + dispatch the button }
  Buttons := TList<HWND>.Create;
  Statics := TList<HWND>.Create;
  TRY
    CollectChildren(Dlg, Buttons, Statics);
    if not ResolveButton(Buttons, ASelector, MatchBtn, MatchId, MatchCap) then
    begin
      AReason := 'button_not_found';
      EXIT;
    end;

    // Same-thread send (the dialog lives on the main thread, where this runs), so the
    // window proc is invoked synchronously: the button's WM_COMMAND reaches the dialog,
    // which calls EndDialog and unwinds its modal loop. SMTO_ABORTIFHUNG guards the rare
    // cross-thread dialog. BM_CLICK when we have the button HWND; WM_COMMAND-by-id when we
    // only resolved a standard id (Task Dialog common button with no enumerable child).
    Res := 0;
    if MatchBtn <> 0 then
      SendMessageTimeout(MatchBtn, BM_CLICK, 0, 0, SMTO_ABORTIFHUNG, 4000, @Res)
    else
    begin
      WParam := Winapi.Windows.WPARAM((MatchId and $FFFF) or (BN_CLICKED shl 16));
      SendMessageTimeout(Dlg, WM_COMMAND, WParam, 0, SMTO_ABORTIFHUNG, 4000, @Res);
    end;

    AClickedId := MatchId;
    AClickedCaption := MatchCap;
    Result := TRUE;
  FINALLY
    Buttons.Free;
    Statics.Free;
  END;
END;

{$ELSE}   // Non-Windows: no Win32 dialogs to reach. Uniform empty/unsupported answers.

FUNCTION NativeDialogsSupported: Boolean;
BEGIN
  Result := FALSE;
END;

FUNCTION EnumerateNativeDialogs(CONST AExclude: ARRAY OF NativeUInt): TJSONArray;
BEGIN
  Result := TJSONArray.Create;
END;

FUNCTION ClickNativeDialogButton(CONST AExclude: ARRAY OF NativeUInt; ATargetDlg: NativeUInt;
  CONST ASelector: String; OUT AClickedId: Integer; OUT AClickedCaption: String;
  OUT AResolvedDlg: NativeUInt; OUT AReason: String): Boolean;
BEGIN
  AClickedId := 0; AClickedCaption := ''; AResolvedDlg := 0;
  AReason := 'unsupported_platform';
  Result := FALSE;
END;

{$ENDIF}


END.
