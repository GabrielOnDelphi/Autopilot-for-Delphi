UNIT Autopilot.Bridge.Fmx;

(*=====================================================
   2026.06.10 — Phase B: cross-platform. Win32 coupling removed (worker
                extracted to Autopilot.Bridge.Worker; transports behind
                IBridgeTransport). On POSIX/Android StartBridge listens on an
                AF_UNIX abstract socket 'Autopilot.<pid>' instead of a pipe.
   2026.05.30 — added 'execute_action' command: fires TBasicAction.Execute by path.
                Closes the action-with-no-control gap (e.g. shortcut-only actions
                like actFileExit triggered by Alt+F4). Enabled-guarded — base
                Execute fires OnExecute regardless of Enabled, so the bridge
                checks here. Rejects non-actions with -32005 pointing back to
                click. Result: {path, dispatchedVia:'Execute', executed:bool}.
   2026.05.20 — added 'read_property' command: RTTI-based published-property
                reader (parity with VCL twin minus the TColor branch — FMX uses
                TAlphaColor only). Same dotted-name nesting, same string
                formatting as set_property's readback. Does NOT enforce Enabled.
                Recovery payload on rtti_property_missing lists the READABLE
                surface.
   2026.05.14 — set_property gained TAlphaColor coercion: tkInteger props typed
                as TAlphaColor accept '#RRGGBB' (alpha assumed FF), '#AARRGGBB',
                'claSkyBlue', bare 'SkyBlue', or a numeric value. availableProperties
                returns kind:'alphacolor' for those entries; currentValue is
                rendered as 'claName' or '#AARRGGBB'.
   2026.05.14 — set_property accepts one-level dotted propName ('Font.Size'),
                with tkClass outer + simple inner. Parity with VCL twin.
   2026.05.14 — set_property gained tkSet support and availableProperties entries
                now carry 'currentValue' (parity with VCL twin).
   2026.05.14 — added 'set_property' command (parity with VCL bridge). See VCL twin
                for the generic RTTI-based setter contract; FMX shares the same
                type-coercion code.
   2026.05.13
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────┐
   │  CROSS-PLATFORM (FMX)        │   Windows = named pipe; POSIX/Android = abstract socket
   └──────────────────────────────┘
   The FMX dispatcher is framework-agnostic (forms via Screen.Forms[] + RTTI)
   and since Phase B (2026-06-10) carries zero Win32 coupling: the shared
   worker (Autopilot.Bridge.Worker) drives an IBridgeTransport — TPipeTransport
   on Windows, TSocketTransport (AF_UNIX abstract, reached via `adb forward
   tcp:<port> localabstract:Autopilot.<pid>`) on Android. Main-thread asserts
   use TThread.CurrentThread.ThreadID. See " Plans\05_AndroidTransport.md".

   Public surface of the Autopilot bridge (FMX flavor).

   Drop this unit into a target Delphi FMX project. Add AUTOPILOT to the project's
   conditional defines. Call StartBridge once after Application.CreateForm.

   This is the FMX twin of Autopilot.Bridge.Vcl. The Core, NamedPipe, and Log units
   are shared — only the dispatcher (RTTI + Forms types) differs.

   STATUS 2026-05-13: built and link-clean on D13.1 / Windows. End-to-end smoke
   against a real FMX target is pending — see HANDOVER.md.

   Differences from the VCL flavor:
     - Forms enumeration: Screen.FormCount/Screen.Forms[] (same name; FMX.Forms unit).
     - Click dispatch: TButton in FMX has no protected Click trick; we always go via
       the OnClick property read by RTTI. Most clickable FMX controls expose OnClick
       at the same RTTI path as VCL.
     - Screenshot: TForm.MakeScreenshot returns a FMX.Graphics.TBitmap; SaveToStream
       with '.png' as the implicit format via TBitmapCodecManager.
=====================================================*)

INTERFACE

USES
  System.Classes;

PROCEDURE StartBridge;
PROCEDURE StopBridge;
FUNCTION  IsBridgeRunning: Boolean;
PROCEDURE StartBridgeOnPipe(CONST APipeName: String);


IMPLEMENTATION

{$IFDEF AUTOPILOT}
USES
  System.SysUtils, System.SyncObjs, System.JSON, System.Rtti, System.TypInfo,
  System.NetEncoding, System.UITypes, System.UIConsts,
  FMX.Forms, FMX.Types, FMX.StdCtrls, FMX.Controls, FMX.Graphics,
  Autopilot.Bridge.Core, Autopilot.Bridge.Log, Autopilot.Bridge.Worker, Autopilot.Bridge.NativeDialogs,
  {$IFDEF MSWINDOWS}
  Autopilot.Bridge.NamedPipe;
  {$ELSE}
  Posix.Unistd,
  {$IFDEF ANDROID}
  Androidapi.Helpers, Androidapi.JNI.GraphicsContentViewText, Androidapi.JNI.App,
  {$ENDIF}
  Autopilot.Bridge.Socket;
  {$ENDIF}
{$ELSE}
USES
  System.SysUtils;
{$ENDIF}


{$IFDEF AUTOPILOT}

VAR
  GWorker: TBridgeWorker = NIL;
  GLock  : TCriticalSection = NIL;


{ Component-tree walk and RTTI helpers ---------------------------------- }

// Synthetic ID for an unnamed component: '@TButton#5' where 5 is the component's
// CURRENT position in its owner's Components list. The index is computed live and
// shifts down by 1 each time an earlier-indexed sibling is freed (RemoveComponent
// compacts the list). A synthetic ID captured from list_tree is only reliable
// while no earlier-indexed sibling has been destroyed since. Same scheme as the
// VCL bridge — see comment there.
FUNCTION SyntheticIdFor(AComp: TComponent): String;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'SyntheticIdFor: FMX touched off the main thread');
  if AComp.Name <> '' then EXIT('');
  Result := '@' + AComp.ClassName + '#' + IntToStr(AComp.ComponentIndex);
END;


FUNCTION MatchesLeaf(AOwner: TComponent; AComp: TComponent; CONST ALeaf: String): Boolean;
VAR
  HashPos: Integer;
  ClassPart: String;
  IdxStr: String;
  Idx, ParseCode: Integer;
BEGIN
  Result := FALSE;
  if ALeaf = '' then EXIT;
  if ALeaf[1] = '@' then
  begin
    HashPos := Pos('#', ALeaf);
    if HashPos < 3 then EXIT;
    ClassPart := Copy(ALeaf, 2, HashPos - 2);
    IdxStr := Copy(ALeaf, HashPos + 1, MaxInt);
    Val(IdxStr, Idx, ParseCode);
    if ParseCode <> 0 then EXIT;
    if (Idx < 0) or (Idx >= AOwner.ComponentCount) then EXIT;
    if AOwner.Components[Idx] <> AComp then EXIT;
    Result := SameText(AComp.ClassName, ClassPart);
  end
  else
    Result := SameText(AComp.Name, ALeaf);
END;


FUNCTION FindChildOf(AParent: TComponent; CONST ALeaf: String): TComponent;
VAR
  j: Integer;
BEGIN
  Result := NIL;
  for j := 0 to AParent.ComponentCount - 1 do
    if MatchesLeaf(AParent, AParent.Components[j], ALeaf) then
      EXIT(AParent.Components[j]);
END;


// Prefers shallow matches: scans ALL direct children of AParent first, then
// recurses. See the VCL twin for rationale.
FUNCTION FindDescendantOf(AParent: TComponent; CONST ALeaf: String; AVisited: TList): TComponent;
VAR
  j: Integer;
  Child: TComponent;
BEGIN
  Result := NIL;
  for j := 0 to AParent.ComponentCount - 1 do
  begin
    Child := AParent.Components[j];
    if AVisited.IndexOf(Child) >= 0 then Continue;
    AVisited.Add(Child);
    if MatchesLeaf(AParent, Child, ALeaf) then
      EXIT(Child);
  end;
  for j := 0 to AParent.ComponentCount - 1 do
  begin
    Child := AParent.Components[j];
    if Child.ComponentCount > 0 then
    begin
      Result := FindDescendantOf(Child, ALeaf, AVisited);
      if Result <> NIL then EXIT;
    end;
  end;
END;


// See VCL twin for path-format spec, including the 1-part "Form alone" form
// that round-trips with the form node emitted by list_tree.
FUNCTION FindComponentByPath(CONST APath: String): TComponent;
VAR
  i, k: Integer;
  Form: TCommonCustomForm;
  Parts: TArray<String>;
  FormName: String;
  Cur: TComponent;
  Visited: TList;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'FindComponentByPath: FMX touched off the main thread');
  Result := NIL;
  if APath = '' then EXIT;
  Parts := APath.Split(['.']);
  if Length(Parts) < 1 then EXIT;
  FormName := Parts[0];
  for i := 0 to Screen.FormCount - 1 do
  begin
    Form := Screen.Forms[i];
    if (FormName <> '*') and not SameText(Form.Name, FormName) then Continue;
    if Length(Parts) = 1 then
      EXIT(TComponent(Form))
    else if Length(Parts) = 2 then
    begin
      Visited := TList.Create;
      TRY
        Result := FindDescendantOf(Form, Parts[1], Visited);
      FINALLY
        FreeAndNil(Visited);
      END;
      if Result <> NIL then EXIT;
    end
    else
    begin
      Cur := Form;
      for k := 1 to High(Parts) do
      begin
        Cur := FindChildOf(Cur, Parts[k]);
        if Cur = NIL then Break;
      end;
      if Cur <> NIL then EXIT(Cur);
    end;
  end;
END;


FUNCTION TryGetTextProperty(AComp: TComponent; OUT AValue: String): Boolean;
VAR
  Ctx: TRttiContext;
  RT: TRttiType;
  Prop: TRttiProperty;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'TryGetTextProperty: FMX touched off the main thread');
  Result := FALSE;
  AValue := '';
  Ctx := TRttiContext.Create;
  TRY
    RT := Ctx.GetType(AComp.ClassType);
    if RT = NIL then EXIT;
    // Mirror VCL: try Text first, then Caption. TCommonCustomForm exposes
    // Caption (not Text), so get_text("MyFmxForm") needs the fallback to work.
    Prop := RT.GetProperty('Text');
    if (Prop = NIL) or not Prop.IsReadable then
      Prop := RT.GetProperty('Caption');
    if (Prop = NIL) or not Prop.IsReadable then EXIT;
    // Mirror the VCL guard: some FMX property getters can throw on
    // partially-initialized forms or controls. Swallow and report "no text".
    TRY
      AValue := Prop.GetValue(AComp).AsString;
      Result := TRUE;
    EXCEPT
      Result := FALSE;
      AValue := '';
    END;
  FINALLY
    Ctx.Free;
  END;
END;


FUNCTION TryGetEnabled(AComp: TComponent; OUT AEnabled: Boolean): Boolean;
VAR
  Ctx: TRttiContext;
  RT: TRttiType;
  Prop: TRttiProperty;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'TryGetEnabled: FMX touched off the main thread');
  Result := FALSE;
  AEnabled := TRUE;
  Ctx := TRttiContext.Create;
  TRY
    RT := Ctx.GetType(AComp.ClassType);
    if RT = NIL then EXIT;
    Prop := RT.GetProperty('Enabled');
    if (Prop = NIL) or not Prop.IsReadable then EXIT;
    // Mirror the VCL guard: a misbehaving FMX getter must not propagate out
    // and leak the in-flight TJSONArray/TJSONObject in HandleListTree.
    TRY
      AEnabled := Prop.GetValue(AComp).AsBoolean;
      Result := TRUE;
    EXCEPT
      Result := FALSE;
      AEnabled := TRUE;
    END;
  FINALLY
    Ctx.Free;
  END;
END;


FUNCTION TryGetVisible(AComp: TComponent; OUT AVisible: Boolean): Boolean;
VAR
  Ctx: TRttiContext;
  RT: TRttiType;
  Prop: TRttiProperty;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'TryGetVisible: FMX touched off the main thread');
  Result := FALSE;
  AVisible := TRUE;
  Ctx := TRttiContext.Create;
  TRY
    RT := Ctx.GetType(AComp.ClassType);
    if RT = NIL then EXIT;
    Prop := RT.GetProperty('Visible');
    if (Prop = NIL) or not Prop.IsReadable then EXIT;
    TRY
      AVisible := Prop.GetValue(AComp).AsBoolean;
      Result := TRUE;
    EXCEPT
      Result := FALSE;
      AVisible := TRUE;
    END;
  FINALLY
    Ctx.Free;
  END;
END;


FUNCTION TrySetTextProperty(AComp: TComponent; CONST AValue: String; OUT AErrCode: Integer): Boolean;
VAR
  Ctx: TRttiContext;
  RT: TRttiType;
  Prop: TRttiProperty;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'TrySetTextProperty: FMX touched off the main thread');
  Result := FALSE;
  AErrCode := ErrRttiPropertyMissing;
  Ctx := TRttiContext.Create;
  TRY
    RT := Ctx.GetType(AComp.ClassType);
    if RT = NIL then EXIT;
    // Mirror VCL: try Text first, then fall back to Caption. TCommonCustomForm
    // has only Caption (no published Text), so set_text on a form needs this.
    Prop := RT.GetProperty('Text');
    if Prop = NIL then
      Prop := RT.GetProperty('Caption');
    if Prop = NIL then EXIT;
    if not Prop.IsWritable then
    begin
      AErrCode := ErrUnsupportedAction;
      EXIT;
    end;
    Prop.SetValue(AComp, AValue);
    Result := TRUE;
  FINALLY
    Ctx.Free;
  END;
END;


// Mirror of the VCL twin's TryReadPropertyAsString — used by ListWritableProperties
// to populate the optional 'currentValue' field on each writable property entry.
// AInstance is TObject (not TComponent) so the helper also works on nested
// TPersistent classes reached via dotted propName.
//
// TAlphaColor is a `type Cardinal` (tkInteger) but we format its value as
// '#AARRGGBB' or the canonical 'claName' so the AI sees colors in a form it
// can feed back to set_property unchanged.
FUNCTION TryReadPropertyAsString(AInstance: TObject; AProp: TRttiProperty; OUT AValue: String): Boolean;
VAR
  V: TValue;
  EnumName: String;
  SetStr: String;
  AlphaStr: String;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'TryReadPropertyAsString: FMX touched off the main thread');
  Result := FALSE;
  AValue := '';
  if not AProp.IsReadable then EXIT;
  TRY
    V := AProp.GetValue(AInstance);
  EXCEPT
    EXIT;
  END;
  case AProp.PropertyType.TypeKind of
    tkString, tkLString, tkWString, tkUString:
    begin
      AValue := V.AsString;
      Result := TRUE;
    end;
    tkInteger:
    begin
      // TAlphaColor short-circuit: emit '#AARRGGBB' (or 'claName' when named)
      // instead of a raw 32-bit integer. AlphaColorToString returns the name
      // for known colors and '#AARRGGBB' for everything else.
      if AProp.PropertyType.Handle = TypeInfo(TAlphaColor) then
      begin
        TRY
          AlphaStr := AlphaColorToString(TAlphaColor(V.AsOrdinal));
          AValue := AlphaStr;
          Result := TRUE;
        EXCEPT
          // Fall back to raw decimal on any UIConsts hiccup — never let a
          // readback fail the whole availableProperties response.
          AValue := IntToStr(V.AsOrdinal);
          Result := TRUE;
        END;
        EXIT;
      end;
      AValue := IntToStr(V.AsInteger);
      Result := TRUE;
    end;
    tkInt64:
    begin
      AValue := IntToStr(V.AsInt64);
      Result := TRUE;
    end;
    tkEnumeration:
      if AProp.PropertyType.Handle = TypeInfo(Boolean) then
      begin
        if V.AsBoolean then AValue := 'true' else AValue := 'false';
        Result := TRUE;
      end
      else
      begin
        EnumName := GetEnumName(AProp.PropertyType.Handle, V.AsOrdinal);
        if EnumName <> '' then
        begin
          AValue := EnumName;
          Result := TRUE;
        end;
      end;
    tkFloat:
    begin
      AValue := FloatToStr(V.AsExtended, FormatSettings.Invariant);
      Result := TRUE;
    end;
    tkSet:
    begin
      SetStr := SetToString(AProp.PropertyType.Handle, Integer(V.GetReferenceToRawData^), TRUE);
      AValue := SetStr;
      Result := TRUE;
    end;
  end;
END;


// AInstance is TObject (not TComponent) so this also enumerates writable
// fields on nested TPersistent classes (e.g. TFont) reached via a dotted
// propName like 'Font.Size'.
FUNCTION ListWritableProperties(AInstance: TObject): TJSONArray;
VAR
  Ctx: TRttiContext;
  RT: TRttiType;
  Prop: TRttiProperty;
  Node: TJSONObject;
  KindName: String;
  CurStr: String;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'ListWritableProperties: FMX touched off the main thread');
  Result := TJSONArray.Create;
  Ctx := TRttiContext.Create;
  TRY
    RT := Ctx.GetType(AInstance.ClassType);
    if RT = NIL then EXIT;
    for Prop in RT.GetProperties do
    begin
      if not Prop.IsWritable then Continue;
      // tkClass is included so the AI sees 'Outer.Inner' nesting is available.
      // TAlphaColor is tkInteger by RTTI but we label it 'alphacolor' so the AI
      // knows to send '#AARRGGBB' / 'claName' rather than a raw integer.
      case Prop.PropertyType.TypeKind of
        tkString, tkLString, tkWString, tkUString: KindName := 'string';
        tkInteger:
          if Prop.PropertyType.Handle = TypeInfo(TAlphaColor) then
            KindName := 'alphacolor'
          else
            KindName := 'integer';
        tkInt64:                                    KindName := 'int64';
        tkEnumeration:
          if Prop.PropertyType.Handle = TypeInfo(Boolean) then
            KindName := 'boolean'
          else
            KindName := 'enum';
        tkSet:                                      KindName := 'set';
        tkFloat:                                    KindName := 'float';
        tkClass:                                    KindName := 'class';
      else
        Continue;
      end;
      Node := TJSONObject.Create;
      Node.AddPair('name', Prop.Name);
      Node.AddPair('kind', KindName);
      if Prop.PropertyType.TypeKind <> tkClass then
        if TryReadPropertyAsString(AInstance, Prop, CurStr) then
          Node.AddPair('currentValue', CurStr);
      Result.AddElement(Node);
    end;
  FINALLY
    Ctx.Free;
  END;
END;


// AI-friendly TAlphaColor parser. Accepts:
//   '#FF8000'        — 6 hex digits, alpha assumed $FF (fully opaque)
//   '#80FF8000'      — 8 hex digits, full ARGB
//   'claSkyBlue'     — System.UIConsts cla* constant
//   'SkyBlue'        — bare name (UIConsts prepends 'cla' itself)
//   '4283621118'     — decimal
//   '$FF8000FF'      — Pascal-style hex literal
// Returns FALSE without raising on anything else. Uses StringToAlphaColor for
// the heavy lifting; the 6-digit short form is our own convenience layer
// because StringToAlphaColor treats '#FF8000' as alpha=0 (invisible) which is
// almost never what the AI means.
FUNCTION TryParseAlphaColor(CONST AStrValue: String; OUT AColor: TAlphaColor): Boolean;
VAR
  S: String;
BEGIN
  Result := FALSE;
  S := Trim(AStrValue);
  if S = '' then EXIT;
  // 6-digit RGB short form ('#RRGGBB'): expand to 8-digit ARGB with full
  // opacity. StringToAlphaColor would otherwise treat it as alpha=0 (fully
  // transparent), which is almost never what the AI meant.
  if (S.Length = 7) and (S[1] = '#') then
    S := '#FF' + Copy(S, 2, 6);
  TRY
    AColor := StringToAlphaColor(S);
    Result := TRUE;
  EXCEPT
    // StrToInt64 inside StringToAlphaColor raises EConvertError on garbage.
    // Swallow — the caller maps FALSE to a structured unsupported_action error.
    Result := FALSE;
  END;
END;


// Coerce AStrValue to a TValue of the property's declared type, then write it.
// See the VCL twin for the full type-coercion contract — including the one-level
// dotted propName ('Font.Size') support that resolves the outer tkClass then
// recurses onto the inner instance. AInstance is TObject (not TComponent) so
// the recursive call accepts a nested TPersistent.
//
// TAlphaColor (RTTI says tkInteger) is detected by type handle and routed
// through TryParseAlphaColor so the AI can pass '#FF8000' or 'claSkyBlue'
// instead of a raw 32-bit integer.
//
// AFailedInstance: on FALSE return with ErrRttiPropertyMissing, this is set to
// the object the lookup was performed against — used by HandleSetProperty to
// list writables off the inner class when the typo was on the inner name.
//
// AElided: on TRUE return, this is set to TRUE iff the live property value
// already equalled the coerced new value, so the bridge skipped Prop.SetValue
// (no OnChange fires). See the VCL twin for the full contract. FMX has no
// TColor branch — the rest of the type kinds match.
FUNCTION TrySetGenericProperty(AInstance: TObject; CONST APropName, AStrValue: String;
                               OUT AErrCode: Integer; OUT AErrMsg: String;
                               OUT AFailedInstance: TObject;
                               OUT AElided: Boolean): Boolean;
VAR
  Ctx: TRttiContext;
  RT: TRttiType;
  Prop: TRttiProperty;
  IntVal: Integer;
  Int64Val: Int64;
  FloatVal: Double;
  BoolVal: Boolean;
  EnumOrd: Integer;
  Code: Integer;
  Lower: String;
  DotPos: Integer;
  OuterName, InnerName: String;
  Inner: TObject;
  AlphaVal: TAlphaColor;
  CurVal: TValue;
  CanRead: Boolean;
  TmpVal: TValue;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'TrySetGenericProperty: FMX touched off the main thread');
  Result := FALSE;
  AErrCode := ErrRttiPropertyMissing;
  AErrMsg := '';
  AFailedInstance := AInstance;
  AElided := FALSE;

  // Dotted propName: 'Outer.Inner'. See VCL twin for full contract — one level only.
  DotPos := Pos('.', APropName);
  if DotPos > 0 then
  begin
    OuterName := Copy(APropName, 1, DotPos - 1);
    InnerName := Copy(APropName, DotPos + 1, MaxInt);
    if Pos('.', InnerName) > 0 then
    begin
      AErrCode := ErrUnsupportedAction;
      AErrMsg := 'set_property supports at most one level of nesting; got "' + APropName + '"';
      EXIT;
    end;
    if (OuterName = '') or (InnerName = '') then
    begin
      AErrCode := ErrUnsupportedAction;
      AErrMsg := 'invalid dotted propName "' + APropName + '"';
      EXIT;
    end;
    Ctx := TRttiContext.Create;
    TRY
      RT := Ctx.GetType(AInstance.ClassType);
      if RT = NIL then
      begin
        AErrMsg := AInstance.ClassName + ' has no RTTI';
        EXIT;
      end;
      Prop := RT.GetProperty(OuterName);
      if Prop = NIL then
      begin
        AErrMsg := AInstance.ClassName + ' has no published property "' + OuterName + '"';
        EXIT;
      end;
      if Prop.PropertyType.TypeKind <> tkClass then
      begin
        AErrCode := ErrUnsupportedAction;
        AErrMsg := AInstance.ClassName + '.' + OuterName +
                   ' is not a class-typed property (dotted propName requires tkClass outer)';
        EXIT;
      end;
      if not Prop.IsReadable then
      begin
        AErrCode := ErrUnsupportedAction;
        AErrMsg := AInstance.ClassName + '.' + OuterName + ' is not readable';
        EXIT;
      end;
      TRY
        Inner := Prop.GetValue(AInstance).AsObject;
      EXCEPT
        ON E: Exception DO
        BEGIN
          AErrCode := ErrUnsupportedAction;
          AErrMsg := AInstance.ClassName + '.' + OuterName + ' getter raised ' + E.ClassName;
          EXIT;
        END;
      END;
      if Inner = NIL then
      begin
        AErrCode := ErrUnsupportedAction;
        AErrMsg := AInstance.ClassName + '.' + OuterName + ' is nil';
        EXIT;
      end;
    FINALLY
      Ctx.Free;
    END;
    EXIT(TrySetGenericProperty(Inner, InnerName, AStrValue, AErrCode, AErrMsg, AFailedInstance, AElided));
  end;

  Ctx := TRttiContext.Create;
  TRY
    RT := Ctx.GetType(AInstance.ClassType);
    if RT = NIL then
    begin
      AErrMsg := AInstance.ClassName + ' has no RTTI';
      EXIT;
    end;
    Prop := RT.GetProperty(APropName);
    if Prop = NIL then
    begin
      AErrMsg := AInstance.ClassName + ' has no published property "' + APropName + '"';
      EXIT;
    end;
    if not Prop.IsWritable then
    begin
      AErrCode := ErrUnsupportedAction;
      AErrMsg := AInstance.ClassName + '.' + APropName + ' is read-only';
      EXIT;
    end;

    // Read the live value once for elision (see VCL twin's longer note).
    CanRead := FALSE;
    if Prop.IsReadable then
    begin
      TRY
        CurVal := Prop.GetValue(AInstance);
        CanRead := TRUE;
      EXCEPT
        CanRead := FALSE;
      END;
    end;

    case Prop.PropertyType.TypeKind of
      tkString, tkLString, tkWString, tkUString:
      begin
        if CanRead and (CurVal.AsString = AStrValue) then
        begin
          AElided := TRUE;
          EXIT(TRUE);
        end;
        Prop.SetValue(AInstance, AStrValue);
        EXIT(TRUE);
      end;

      tkInteger:
      begin
        // TAlphaColor (System.UITypes.TAlphaColor = type Cardinal). Route
        // through TryParseAlphaColor so the AI can pass '#FF8000' (6-digit
        // RGB, full alpha), '#80FF8000' (8-digit ARGB), 'claSkyBlue', or a
        // raw decimal/$hex integer. Detected by type handle, not class name.
        if Prop.PropertyType.Handle = TypeInfo(TAlphaColor) then
        begin
          if not TryParseAlphaColor(AStrValue, AlphaVal) then
          begin
            AErrCode := ErrUnsupportedAction;
            AErrMsg := APropName + ' expects a TAlphaColor value (e.g. "#FF8000", "#80FF8000", "claSkyBlue", or a numeric color); got "' + AStrValue + '"';
            EXIT;
          end;
          if CanRead and (TAlphaColor(CurVal.AsOrdinal) = AlphaVal) then
          begin
            AElided := TRUE;
            EXIT(TRUE);
          end;
          Prop.SetValue(AInstance, TValue.From<TAlphaColor>(AlphaVal));
          EXIT(TRUE);
        end;
        Val(AStrValue, IntVal, Code);
        if Code <> 0 then
        begin
          AErrCode := ErrUnsupportedAction;
          AErrMsg := APropName + ' expects an integer; got "' + AStrValue + '"';
          EXIT;
        end;
        if CanRead and (CurVal.AsInteger = IntVal) then
        begin
          AElided := TRUE;
          EXIT(TRUE);
        end;
        Prop.SetValue(AInstance, IntVal);
        EXIT(TRUE);
      end;

      tkInt64:
      begin
        Val(AStrValue, Int64Val, Code);
        if Code <> 0 then
        begin
          AErrCode := ErrUnsupportedAction;
          AErrMsg := APropName + ' expects an int64; got "' + AStrValue + '"';
          EXIT;
        end;
        if CanRead and (CurVal.AsInt64 = Int64Val) then
        begin
          AElided := TRUE;
          EXIT(TRUE);
        end;
        Prop.SetValue(AInstance, Int64Val);
        EXIT(TRUE);
      end;

      tkEnumeration:
        if Prop.PropertyType.Handle = TypeInfo(Boolean) then
        begin
          Lower := LowerCase(AStrValue);
          if (Lower = 'true') or (Lower = '1') then
            BoolVal := TRUE
          else if (Lower = 'false') or (Lower = '0') then
            BoolVal := FALSE
          else
          begin
            AErrCode := ErrUnsupportedAction;
            AErrMsg := APropName + ' expects boolean (true/false); got "' + AStrValue + '"';
            EXIT;
          end;
          if CanRead and (CurVal.AsBoolean = BoolVal) then
          begin
            AElided := TRUE;
            EXIT(TRUE);
          end;
          Prop.SetValue(AInstance, BoolVal);
          EXIT(TRUE);
        end
        else
        begin
          EnumOrd := GetEnumValue(Prop.PropertyType.Handle, AStrValue);
          if EnumOrd < 0 then
          begin
            Val(AStrValue, IntVal, Code);
            if Code <> 0 then
            begin
              AErrCode := ErrUnsupportedAction;
              AErrMsg := APropName + ' expects an enum identifier or ordinal; got "' + AStrValue + '"';
              EXIT;
            end;
            EnumOrd := IntVal;
          end;
          if CanRead and (CurVal.AsOrdinal = EnumOrd) then
          begin
            AElided := TRUE;
            EXIT(TRUE);
          end;
          Prop.SetValue(AInstance, TValue.FromOrdinal(Prop.PropertyType.Handle, EnumOrd));
          EXIT(TRUE);
        end;

      tkSet:
      begin
        // Accept '[a,b]', 'a,b', '[]', or a numeric ordinal. See VCL twin.
        // NOTE: TValue.FromOrdinal raises EInvalidCast for tkSet typeinfo.
        // Use TValue.Make with a pointer to the raw ordinal instead.
        Lower := Trim(AStrValue);
        if (Lower <> '') and (Lower[1] <> '[') then
        begin
          Val(Lower, IntVal, Code);
          if Code = 0 then
          begin
            if CanRead and (Integer(CurVal.GetReferenceToRawData^) = IntVal) then
            begin
              AElided := TRUE;
              EXIT(TRUE);
            end;
            TValue.Make(@IntVal, Prop.PropertyType.Handle, TmpVal);
            Prop.SetValue(AInstance, TmpVal);
            EXIT(TRUE);
          end;
          Lower := '[' + Lower + ']';
        end;
        TRY
          IntVal := StringToSet(Prop.PropertyType.Handle, Lower);
        EXCEPT
          ON E: Exception DO
          BEGIN
            AErrCode := ErrUnsupportedAction;
            AErrMsg := APropName + ' expects a set literal like "[biSystemMenu,biMinimize]"; got "' + AStrValue + '"';
            EXIT;
          END;
        END;
        if CanRead and (Integer(CurVal.GetReferenceToRawData^) = IntVal) then
        begin
          AElided := TRUE;
          EXIT(TRUE);
        end;
        TValue.Make(@IntVal, Prop.PropertyType.Handle, TmpVal);
        Prop.SetValue(AInstance, TmpVal);
        EXIT(TRUE);
      end;

      tkFloat:
      begin
        if not TryStrToFloat(AStrValue, FloatVal, FormatSettings.Invariant) then
        begin
          AErrCode := ErrUnsupportedAction;
          AErrMsg := APropName + ' expects a number; got "' + AStrValue + '"';
          EXIT;
        end;
        // Exact-bits equality (no epsilon). Double/Extended round-trip cleanly;
        // Single-typed properties may not elide on resend of non-Single-exact
        // decimals (e.g. 0.1) — harmless (write goes through). See VCL twin for
        // longer note. AsExtended is the canonical tkFloat accessor.
        if CanRead and (CurVal.AsExtended = FloatVal) then
        begin
          AElided := TRUE;
          EXIT(TRUE);
        end;
        Prop.SetValue(AInstance, FloatVal);
        EXIT(TRUE);
      end;
    else
      AErrCode := ErrUnsupportedAction;
      AErrMsg := APropName + ' has unsupported type kind (' + IntToStr(Ord(Prop.PropertyType.TypeKind)) +
                 ' — use a dotted propName like "Outer.Inner" if this is a class-typed property)';
      EXIT;
    end;
  FINALLY
    Ctx.Free;
  END;
END;


FUNCTION TrySetCheckedProperty(AComp: TComponent; AValue: Boolean; OUT AErrCode: Integer): Boolean;
VAR
  Ctx: TRttiContext;
  RT: TRttiType;
  Prop: TRttiProperty;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'TrySetCheckedProperty: FMX touched off the main thread');
  Result := FALSE;
  AErrCode := ErrRttiPropertyMissing;
  Ctx := TRttiContext.Create;
  TRY
    RT := Ctx.GetType(AComp.ClassType);
    if RT = NIL then EXIT;
    Prop := RT.GetProperty('IsChecked');     // FMX TCheckBox.IsChecked, not Checked
    if Prop = NIL then
      Prop := RT.GetProperty('Checked');
    if Prop = NIL then EXIT;
    if not Prop.IsWritable then
    begin
      AErrCode := ErrUnsupportedAction;
      EXIT;
    end;
    Prop.SetValue(AComp, AValue);
    Result := TRUE;
  FINALLY
    Ctx.Free;
  END;
END;


FUNCTION LeafNameFor(AComp: TComponent): String;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'LeafNameFor: FMX touched off the main thread');
  if AComp.Name = '' then
    Result := SyntheticIdFor(AComp)
  else
    Result := AComp.Name;
END;


FUNCTION BuildComponentNode(CONST AFormName, ANodePath: String; AComp: TComponent): TJSONObject;
VAR
  S: String;
  B: Boolean;
  NodeName: String;
  IsSynthetic: Boolean;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'BuildComponentNode: FMX touched off the main thread');
  IsSynthetic := AComp.Name = '';
  NodeName := LeafNameFor(AComp);
  Result := TJSONObject.Create;
  Result.AddPair('form', AFormName);
  Result.AddPair('name', NodeName);
  Result.AddPair('path', ANodePath);
  Result.AddPair('class', AComp.ClassName);
  if IsSynthetic then
    Result.AddPair('synthetic', TJSONBool.Create(TRUE));
  if TryGetTextProperty(AComp, S) then
    Result.AddPair('text', S);
  if TryGetEnabled(AComp, B) then
    Result.AddPair('enabled', TJSONBool.Create(B));
  if TryGetVisible(AComp, B) then
    Result.AddPair('visible', TJSONBool.Create(B));
END;


{ Command handlers ------------------------------------------------------ }

PROCEDURE WalkComponents(AFormName, AParentPath: String; AParent: TComponent;
                         AItems: TJSONArray; AVisited: TList);
VAR
  j: Integer;
  Child: TComponent;
  ChildPath: String;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'WalkComponents: FMX touched off the main thread');
  for j := 0 to AParent.ComponentCount - 1 do
  begin
    Child := AParent.Components[j];
    if AVisited.IndexOf(Child) >= 0 then Continue;
    AVisited.Add(Child);
    ChildPath := AParentPath + '.' + LeafNameFor(Child);
    AItems.AddElement(BuildComponentNode(AFormName, ChildPath, Child));
    if Child.ComponentCount > 0 then
      WalkComponents(AFormName, ChildPath, Child, AItems, AVisited);
  end;
END;


FUNCTION HandleListTree(CONST AReq: TBridgeRequest): TBridgeResponse;
VAR
  Items: TJSONArray;
  Wrap: TJSONObject;
  Visited: TList;
  i: Integer;
  Form: TCommonCustomForm;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'HandleListTree must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;
  Result.Ok := TRUE;
  Items := TJSONArray.Create;
  TRY
    // Per-form Visited — see VCL twin for rationale.
    for i := 0 to Screen.FormCount - 1 do
    begin
      Form := Screen.Forms[i];
      Visited := TList.Create;
      TRY
        // Emit the form as its own node first. Its Caption read may throw on an
        // unrealized form — TryGetTextProperty swallows that and the node simply
        // lacks a `text` field. Then recurse owned components (including frames).
        Visited.Add(Form);
        Items.AddElement(BuildComponentNode(Form.Name, Form.Name, Form));
        WalkComponents(Form.Name, Form.Name, Form, Items, Visited);
      FINALLY
        FreeAndNil(Visited);
      END;
    end;
    Wrap := TJSONObject.Create;
    Wrap.AddPair('components', Items);
    Items := NIL;
    Result.ResultJson := Wrap;
  EXCEPT
    FreeAndNil(Items);
    raise;
  END;
END;


FUNCTION HandleGetText(CONST AReq: TBridgeRequest): TBridgeResponse;
VAR
  PathVal: TJSONValue;
  Path, Text: String;
  Comp: TComponent;
  Wrap: TJSONObject;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'HandleGetText must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;
  if AReq.Args = NIL then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'get_text requires args.path';
    EXIT;
  end;
  PathVal := AReq.Args.GetValue('path');
  if not (PathVal IS TJSONString) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'get_text requires args.path (string)';
    EXIT;
  end;
  Path := TJSONString(PathVal).Value;
  Comp := FindComponentByPath(Path);
  if Comp = NIL then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrNotFound;
    Result.ErrorMessage := 'no component matches ' + Path;
    EXIT;
  end;
  if not TryGetTextProperty(Comp, Text) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrRttiPropertyMissing;
    Result.ErrorMessage := Comp.ClassName + ' has no readable Text property';
    EXIT;
  end;
  Wrap := TJSONObject.Create;
  Wrap.AddPair('text', Text);
  Result.Ok := TRUE;
  Result.ResultJson := Wrap;
END;


FUNCTION HandleClick(CONST AReq: TBridgeRequest): TBridgeResponse;
CONST
  MaxClickCount = 1000;
VAR
  PathVal, CountVal: TJSONValue;
  Path: String;
  Comp: TComponent;
  Enabled: Boolean;
  Wrap: TJSONObject;
  Ctx: TRttiContext;
  RT: TRttiType;
  OnClickProp: TRttiProperty;
  Notify: TNotifyEvent;
  RawValue: TValue;
  RequestedCount, ClicksDone: Integer;
  StoppedReason: String;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'HandleClick must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;
  StoppedReason := '';
  ClicksDone := 0;

  if AReq.Args = NIL then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'click requires args.path';
    EXIT;
  end;
  PathVal := AReq.Args.GetValue('path');
  if not (PathVal IS TJSONString) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'click requires args.path (string)';
    EXIT;
  end;
  Path := TJSONString(PathVal).Value;

  RequestedCount := 1;
  CountVal := AReq.Args.GetValue('count');
  if CountVal IS TJSONNumber then
  begin
    // TJSONNumber.AsInt is StrToInt(Value) (System.JSON.pas:2865) — it RAISES EConvertError on a
    // fractional (1.5) or out-of-Int32 count, which would surface as ErrInternalError. TryStrToInt
    // on the raw number text keeps a malformed count in the ErrInvalidRequest lane where it belongs.
    if not TryStrToInt(TJSONNumber(CountVal).Value, RequestedCount) then
    begin
      Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
      Result.ErrorMessage := 'click args.count must be an integer 1..' + IntToStr(MaxClickCount) +
                             ' (got ' + TJSONNumber(CountVal).Value + ')';
      EXIT;
    end;
    if (RequestedCount < 1) or (RequestedCount > MaxClickCount) then
    begin
      Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
      Result.ErrorMessage := 'click args.count must be 1..' + IntToStr(MaxClickCount) +
                             ' (got ' + IntToStr(RequestedCount) + ')';
      EXIT;
    end;
  end;

  Comp := FindComponentByPath(Path);
  if Comp = NIL then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrNotFound;
    Result.ErrorMessage := 'no component matches ' + Path;
    EXIT;
  end;
  if TryGetEnabled(Comp, Enabled) and not Enabled then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrControlDisabled;
    Result.ErrorMessage := Comp.Name + ' is disabled';
    EXIT;
  end;

  // FMX: there's no protected Click trick on a generic TControl base. Most clickable
  // controls expose OnClick (TNotifyEvent) via RTTI. Read and invoke it.
  Ctx := TRttiContext.Create;
  TRY
    RT := Ctx.GetType(Comp.ClassType);
    if RT = NIL then
    begin
      Result.Ok := FALSE; Result.ErrorCode := ErrUnsupportedAction;
      Result.ErrorMessage := Comp.ClassName + ' has no RTTI';
      EXIT;
    end;
    OnClickProp := RT.GetProperty('OnClick');
    if (OnClickProp = NIL) or not OnClickProp.IsReadable then
    begin
      Result.Ok := FALSE; Result.ErrorCode := ErrUnsupportedAction;
      Result.ErrorMessage := Comp.ClassName + ' has no OnClick';
      EXIT;
    end;
    RawValue := OnClickProp.GetValue(Comp);
    if RawValue.IsEmpty or (RawValue.Kind <> tkMethod) then
    begin
      Result.Ok := FALSE; Result.ErrorCode := ErrUnsupportedAction;
      Result.ErrorMessage := Comp.ClassName + '.OnClick is unset';
      EXIT;
    end;
    TMethod(Notify) := PMethod(RawValue.GetReferenceToRawData)^;
    if not Assigned(Notify) then
    begin
      Result.Ok := FALSE; Result.ErrorCode := ErrUnsupportedAction;
      Result.ErrorMessage := Comp.ClassName + '.OnClick is unset';
      EXIT;
    end;
  FINALLY
    Ctx.Free;
  END;

  // Wrap dispatch in try/except so an OnClick that frees the control or raises
  // stops cleanly without AV'ing on the next iteration's TryGetEnabled(stale Comp).
  while ClicksDone < RequestedCount do
  begin
    if TryGetEnabled(Comp, Enabled) and not Enabled then
    begin
      StoppedReason := 'disabled';
      Break;
    end;
    TRY
      Notify(Comp);
      Inc(ClicksDone);
    EXCEPT
      ON E: Exception DO
      BEGIN
        StoppedReason := 'exception:' + E.ClassName;
        BridgeLogWarn('bridge', 'click loop stopped at iter ' + IntToStr(ClicksDone + 1) +
                                ': ' + E.ClassName + ': ' + E.Message);
        Break;
      END;
    END;
  end;

  Wrap := TJSONObject.Create;
  Wrap.AddPair('dispatchedVia', 'onclick');
  Wrap.AddPair('clicksDispatched', TJSONNumber.Create(ClicksDone));
  if StoppedReason <> '' then
    Wrap.AddPair('stoppedReason', StoppedReason);
  Result.Ok := TRUE;
  Result.ResultJson := Wrap;
END;


// execute_action — fires a TBasicAction.Execute directly. Closes the "action with
// no control" gap (keyboard-shortcut-only actions) and the "many controls share
// one action" case where click on the control is indirect. Verified facts:
//   - TBasicAction.Execute (System.Classes.pas:18610) fires OnExecute and
//     returns True iff assigned. It does NOT check Enabled — we must guard here.
//   - TBasicAction lives in System.Classes (already in uses transitively).
FUNCTION HandleExecuteAction(CONST AReq: TBridgeRequest): TBridgeResponse;
VAR
  PathVal: TJSONValue;
  Path: String;
  Comp: TComponent;
  Enabled: Boolean;
  Executed: Boolean;
  Wrap: TJSONObject;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'HandleExecuteAction must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;

  if AReq.Args = NIL then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'execute_action requires args.path';
    EXIT;
  end;
  PathVal := AReq.Args.GetValue('path');
  if not (PathVal IS TJSONString) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'execute_action requires args.path (string)';
    EXIT;
  end;
  Path := TJSONString(PathVal).Value;

  Comp := FindComponentByPath(Path);
  if Comp = NIL then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrNotFound;
    Result.ErrorMessage := 'no component matches ' + Path;
    EXIT;
  end;

  if not (Comp IS TBasicAction) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrUnsupportedAction;
    Result.ErrorMessage := Comp.ClassName + ' is not a TBasicAction - use click for controls';
    EXIT;
  end;

  if TryGetEnabled(Comp, Enabled) and not Enabled then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrControlDisabled;
    Result.ErrorMessage := Comp.Name + ' is disabled';
    EXIT;
  end;

  // OnExecute that closes the app / frees forms is the same hazard as a click
  // that does so. Don't touch Comp after Execute returns.
  TRY
    Executed := TBasicAction(Comp).Execute;
  EXCEPT
    ON E: Exception DO
    BEGIN
      BridgeLogError('bridge', 'execute_action OnExecute raised: ' + E.ClassName + ': ' + E.Message);
      Result.Ok := FALSE; Result.ErrorCode := ErrInternalError;
      Result.ErrorMessage := 'OnExecute raised ' + E.ClassName + ': ' + E.Message;
      EXIT;
    END;
  END;

  Wrap := TJSONObject.Create;
  Wrap.AddPair('path', Path);
  Wrap.AddPair('dispatchedVia', 'Execute');
  Wrap.AddPair('executed', TJSONBool.Create(Executed));
  Result.Ok := TRUE;
  Result.ResultJson := Wrap;
END;


FUNCTION HandleSetText(CONST AReq: TBridgeRequest): TBridgeResponse;
VAR
  PathVal, TextVal: TJSONValue;
  Path, Text: String;
  Comp: TComponent;
  Enabled: Boolean;
  ErrCode: Integer;
  Wrap: TJSONObject;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'HandleSetText must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;
  if AReq.Args = NIL then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'set_text requires args.path and args.text';
    EXIT;
  end;
  PathVal := AReq.Args.GetValue('path');
  TextVal := AReq.Args.GetValue('text');
  if not (PathVal IS TJSONString) or not (TextVal IS TJSONString) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'set_text requires args.path (string) and args.text (string)';
    EXIT;
  end;
  Path := TJSONString(PathVal).Value;
  Text := TJSONString(TextVal).Value;
  Comp := FindComponentByPath(Path);
  if Comp = NIL then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrNotFound;
    Result.ErrorMessage := 'no component matches ' + Path;
    EXIT;
  end;
  if TryGetEnabled(Comp, Enabled) and not Enabled then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrControlDisabled;
    Result.ErrorMessage := Comp.Name + ' is disabled';
    EXIT;
  end;
  if not TrySetTextProperty(Comp, Text, ErrCode) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrCode;
    if ErrCode = ErrUnsupportedAction then
      Result.ErrorMessage := Comp.ClassName + '.Text is read-only'
    else
      Result.ErrorMessage := Comp.ClassName + ' has no writable Text property';
    EXIT;
  end;
  Wrap := TJSONObject.Create;
  Wrap.AddPair('path', Path);
  Result.Ok := TRUE;
  Result.ResultJson := Wrap;
END;


FUNCTION HandleSetChecked(CONST AReq: TBridgeRequest): TBridgeResponse;
VAR
  PathVal, CheckedVal: TJSONValue;
  Path: String;
  Checked: Boolean;
  Comp: TComponent;
  Enabled: Boolean;
  ErrCode: Integer;
  Wrap: TJSONObject;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'HandleSetChecked must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;
  if AReq.Args = NIL then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'set_checked requires args.path and args.checked';
    EXIT;
  end;
  PathVal := AReq.Args.GetValue('path');
  CheckedVal := AReq.Args.GetValue('checked');
  if not (PathVal IS TJSONString) or not (CheckedVal IS TJSONBool) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'set_checked requires args.path (string) and args.checked (boolean)';
    EXIT;
  end;
  Path := TJSONString(PathVal).Value;
  Checked := TJSONBool(CheckedVal).AsBoolean;
  Comp := FindComponentByPath(Path);
  if Comp = NIL then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrNotFound;
    Result.ErrorMessage := 'no component matches ' + Path;
    EXIT;
  end;
  if TryGetEnabled(Comp, Enabled) and not Enabled then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrControlDisabled;
    Result.ErrorMessage := Comp.Name + ' is disabled';
    EXIT;
  end;
  if not TrySetCheckedProperty(Comp, Checked, ErrCode) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrCode;
    Result.ErrorMessage := Comp.ClassName + ' has no IsChecked/Checked property';
    EXIT;
  end;
  Wrap := TJSONObject.Create;
  Wrap.AddPair('path', Path);
  Wrap.AddPair('checked', TJSONBool.Create(Checked));
  Result.Ok := TRUE;
  Result.ResultJson := Wrap;
END;


FUNCTION HandleSetProperty(CONST AReq: TBridgeRequest): TBridgeResponse;
VAR
  PathVal, NameVal, ValueVal: TJSONValue;
  Path, PropName, StrValue: String;
  Comp: TComponent;
  Enabled: Boolean;
  ErrCode: Integer;
  ErrMsg: String;
  Wrap: TJSONObject;
  FailedInstance: TObject;
  Elided: Boolean;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'HandleSetProperty must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;

  if AReq.Args = NIL then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'set_property requires args.path, args.propName, args.value';
    EXIT;
  end;
  PathVal  := AReq.Args.GetValue('path');
  NameVal  := AReq.Args.GetValue('propName');
  ValueVal := AReq.Args.GetValue('value');
  if not (PathVal IS TJSONString) or not (NameVal IS TJSONString) or not (ValueVal IS TJSONString) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'set_property requires args.path, args.propName, args.value (all strings)';
    EXIT;
  end;
  Path     := TJSONString(PathVal).Value;
  PropName := TJSONString(NameVal).Value;
  StrValue := TJSONString(ValueVal).Value;

  Comp := FindComponentByPath(Path);
  if Comp = NIL then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrNotFound;
    Result.ErrorMessage := 'no component matches ' + Path;
    EXIT;
  end;
  if TryGetEnabled(Comp, Enabled) and not Enabled then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrControlDisabled;
    Result.ErrorMessage := Comp.Name + ' is disabled';
    EXIT;
  end;

  if not TrySetGenericProperty(Comp, PropName, StrValue, ErrCode, ErrMsg, FailedInstance, Elided) then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrCode;
    Result.ErrorMessage := ErrMsg;
    // For a dotted propName whose INNER name was the typo, FailedInstance is the
    // inner TPersistent — listing its writables gives the AI the right surface.
    if ErrCode = ErrRttiPropertyMissing then
    begin
      Result.ErrorData := TJSONObject.Create;
      if FailedInstance = NIL then FailedInstance := Comp;
      Result.ErrorData.AddPair('availableProperties', ListWritableProperties(FailedInstance));
    end;
    EXIT;
  end;

  Wrap := TJSONObject.Create;
  Wrap.AddPair('path', Path);
  Wrap.AddPair('propName', PropName);
  Wrap.AddPair('value', StrValue);
  // Write-side elision: TRUE when the live value already equalled the coerced
  // new value and the bridge skipped Prop.SetValue (so OnChange did not fire).
  Wrap.AddPair('elided', TJSONBool.Create(Elided));
  Result.Ok := TRUE;
  Result.ResultJson := Wrap;
END;


FUNCTION FindFormByName(CONST AFormName: String): TCommonCustomForm;
VAR
  i: Integer;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'FindFormByName: FMX touched off the main thread');
  Result := NIL;
  if AFormName = '' then
  begin
    if Application.MainForm <> NIL then
      Result := Application.MainForm
    else if Screen.FormCount > 0 then
      Result := Screen.Forms[0];
    EXIT;
  end;
  for i := 0 to Screen.FormCount - 1 do
    if SameText(Screen.Forms[i].Name, AFormName) then
      EXIT(Screen.Forms[i]);
END;


FUNCTION HandleScreenshot(CONST AReq: TBridgeRequest): TBridgeResponse;
VAR
  FormVal: TJSONValue;
  FormName: String;
  Form: TCommonCustomForm;
  Bmp: FMX.Graphics.TBitmap;
  Stream: TMemoryStream;
  Base64: String;
  Wrap: TJSONObject;
  W, H: Integer;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'HandleScreenshot must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;
  FormName := '';
  if AReq.Args <> NIL then
  begin
    FormVal := AReq.Args.GetValue('form');
    if FormVal IS TJSONString then
      FormName := TJSONString(FormVal).Value;
  end;
  Form := FindFormByName(FormName);
  // PaintTo is declared on TCustomForm (FMX.Forms.pas:1145). Accept any
  // TCustomForm descendant — not just TForm — so TCustomPopupForm etc. work.
  if (Form = NIL) or not (Form IS TCustomForm) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrNotFound;
    if FormName = '' then
      Result.ErrorMessage := 'no main FMX form available'
    else
      Result.ErrorMessage := 'no FMX form named ' + FormName;
    EXIT;
  end;
  // FMX has no TForm.MakeScreenshot (that's on TControl). Use PaintTo against
  // a bitmap canvas instead. ClientWidth/Height are in dp, which is what the
  // form paints in; one pixel per dp is fine for our diagnostic use case.
  W := Round(TCustomForm(Form).ClientWidth);
  H := Round(TCustomForm(Form).ClientHeight);
  if (W <= 0) or (H <= 0) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrUnsupportedAction;
    Result.ErrorMessage := 'form has zero client size';
    EXIT;
  end;
  Bmp := FMX.Graphics.TBitmap.Create(W, H);
  TRY
    // BeginScene can return FALSE if the bitmap context isn't ready
    // (DoBeginScene failure on the active FMX graphics backend). Without a
    // guard, SaveToStream would silently emit a base64 PNG of an
    // uninitialized canvas with Ok=TRUE — wrong answer, no error.
    if not Bmp.Canvas.BeginScene then
    begin
      Result.Ok := FALSE; Result.ErrorCode := ErrUnsupportedAction;
      Result.ErrorMessage := 'Canvas.BeginScene returned FALSE; cannot render form';
      EXIT;
    end;
    TRY
      Bmp.Canvas.Clear(0);
      TCustomForm(Form).PaintTo(Bmp.Canvas);
    FINALLY
      Bmp.Canvas.EndScene;
    END;
    Stream := TMemoryStream.Create;
    TRY
      Bmp.SaveToStream(Stream);  // FMX picks codec by file ext / default = PNG.
      Stream.Position := 0;
      Base64 := TNetEncoding.Base64.EncodeBytesToString(Stream.Memory, Stream.Size);
    FINALLY
      FreeAndNil(Stream);
    END;
  FINALLY
    FreeAndNil(Bmp);
  END;
  Wrap := TJSONObject.Create;
  Wrap.AddPair('form', Form.Name);
  Wrap.AddPair('encoding', 'base64');
  Wrap.AddPair('format', 'png');
  Wrap.AddPair('image', Base64);
  Result.Ok := TRUE;
  Result.ResultJson := Wrap;
END;


// READABLE-property enumerator for FMX — parallel to ListWritableProperties but
// gated on IsReadable. Used by HandleReadProperty's typo recovery. Same kind
// vocabulary as the VCL twin (minus the TColor branch — FMX has no TColor).
FUNCTION ListReadableProperties(AInstance: TObject): TJSONArray;
VAR
  Ctx: TRttiContext;
  RT: TRttiType;
  Prop: TRttiProperty;
  Node: TJSONObject;
  KindName: String;
  CurStr: String;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'ListReadableProperties: FMX touched off the main thread');
  Result := TJSONArray.Create;
  Ctx := TRttiContext.Create;
  TRY
    RT := Ctx.GetType(AInstance.ClassType);
    if RT = NIL then EXIT;
    for Prop in RT.GetProperties do
    begin
      if not Prop.IsReadable then Continue;
      case Prop.PropertyType.TypeKind of
        tkString, tkLString, tkWString, tkUString: KindName := 'string';
        tkInteger:
          if Prop.PropertyType.Handle = TypeInfo(TAlphaColor) then
            KindName := 'alphacolor'
          else
            KindName := 'integer';
        tkInt64:                                    KindName := 'int64';
        tkEnumeration:
          if Prop.PropertyType.Handle = TypeInfo(Boolean) then
            KindName := 'boolean'
          else
            KindName := 'enum';
        tkSet:                                      KindName := 'set';
        tkFloat:                                    KindName := 'float';
        tkClass:                                    KindName := 'class';
      else
        Continue;
      end;
      Node := TJSONObject.Create;
      Node.AddPair('name', Prop.Name);
      Node.AddPair('kind', KindName);
      if Prop.PropertyType.TypeKind <> tkClass then
        if TryReadPropertyAsString(AInstance, Prop, CurStr) then
          Node.AddPair('currentValue', CurStr);
      Result.AddElement(Node);
    end;
  FINALLY
    Ctx.Free;
  END;
END;


// Resolve (possibly one-level dotted) propName on AInstance and read it. FMX
// twin of the VCL TryReadGenericProperty. No TColor branch — FMX uses
// TAlphaColor exclusively.
FUNCTION TryReadGenericProperty(AInstance: TObject; CONST APropName: String;
                                OUT AValue, AKind: String;
                                OUT AErrCode: Integer; OUT AErrMsg: String;
                                OUT AFailedInstance: TObject): Boolean;
VAR
  Ctx: TRttiContext;
  RT: TRttiType;
  Prop: TRttiProperty;
  Inner: TObject;
  DotPos: Integer;
  OuterName, InnerName: String;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'TryReadGenericProperty: FMX touched off the main thread');
  Result := FALSE;
  AValue := '';
  AKind := '';
  AErrCode := ErrRttiPropertyMissing;
  AErrMsg := '';
  AFailedInstance := AInstance;

  DotPos := Pos('.', APropName);
  if DotPos > 0 then
  begin
    OuterName := Copy(APropName, 1, DotPos - 1);
    InnerName := Copy(APropName, DotPos + 1, MaxInt);
    if Pos('.', InnerName) > 0 then
    begin
      AErrCode := ErrUnsupportedAction;
      AErrMsg := 'read_property supports at most one level of nesting; got "' + APropName + '"';
      EXIT;
    end;
    if (OuterName = '') or (InnerName = '') then
    begin
      AErrCode := ErrUnsupportedAction;
      AErrMsg := 'invalid dotted propName "' + APropName + '"';
      EXIT;
    end;
    Ctx := TRttiContext.Create;
    TRY
      RT := Ctx.GetType(AInstance.ClassType);
      if RT = NIL then
      begin
        AErrMsg := AInstance.ClassName + ' has no RTTI';
        EXIT;
      end;
      Prop := RT.GetProperty(OuterName);
      if Prop = NIL then
      begin
        AErrMsg := AInstance.ClassName + ' has no published property "' + OuterName + '"';
        EXIT;
      end;
      if Prop.PropertyType.TypeKind <> tkClass then
      begin
        AErrCode := ErrUnsupportedAction;
        AErrMsg := AInstance.ClassName + '.' + OuterName +
                   ' is not a class-typed property (dotted propName requires tkClass outer)';
        EXIT;
      end;
      if not Prop.IsReadable then
      begin
        AErrCode := ErrUnsupportedAction;
        AErrMsg := AInstance.ClassName + '.' + OuterName + ' is not readable';
        EXIT;
      end;
      TRY
        Inner := Prop.GetValue(AInstance).AsObject;
      EXCEPT
        ON E: Exception DO
        BEGIN
          AErrCode := ErrUnsupportedAction;
          AErrMsg := AInstance.ClassName + '.' + OuterName + ' getter raised ' + E.ClassName;
          EXIT;
        END;
      END;
      if Inner = NIL then
      begin
        AErrCode := ErrUnsupportedAction;
        AErrMsg := AInstance.ClassName + '.' + OuterName + ' is nil';
        EXIT;
      end;
    FINALLY
      Ctx.Free;
    END;
    EXIT(TryReadGenericProperty(Inner, InnerName, AValue, AKind, AErrCode, AErrMsg, AFailedInstance));
  end;

  Ctx := TRttiContext.Create;
  TRY
    RT := Ctx.GetType(AInstance.ClassType);
    if RT = NIL then
    begin
      AErrMsg := AInstance.ClassName + ' has no RTTI';
      EXIT;
    end;
    Prop := RT.GetProperty(APropName);
    if Prop = NIL then
    begin
      AErrMsg := AInstance.ClassName + ' has no published property "' + APropName + '"';
      EXIT;
    end;
    if not Prop.IsReadable then
    begin
      AErrCode := ErrUnsupportedAction;
      AErrMsg := AInstance.ClassName + '.' + APropName + ' is write-only';
      EXIT;
    end;
    case Prop.PropertyType.TypeKind of
      tkString, tkLString, tkWString, tkUString: AKind := 'string';
      tkInteger:
        if Prop.PropertyType.Handle = TypeInfo(TAlphaColor) then
          AKind := 'alphacolor'
        else
          AKind := 'integer';
      tkInt64:                                    AKind := 'int64';
      tkEnumeration:
        if Prop.PropertyType.Handle = TypeInfo(Boolean) then
          AKind := 'boolean'
        else
          AKind := 'enum';
      tkSet:                                      AKind := 'set';
      tkFloat:                                    AKind := 'float';
      tkClass:
      begin
        AErrCode := ErrUnsupportedAction;
        AErrMsg := AInstance.ClassName + '.' + APropName +
                   ' is a class-typed property — use dotted propName (e.g. "' + APropName + '.Inner") to read a leaf';
        EXIT;
      end;
    else
      AErrCode := ErrUnsupportedAction;
      AErrMsg := AInstance.ClassName + '.' + APropName + ' has unsupported type kind';
      EXIT;
    end;
    if not TryReadPropertyAsString(AInstance, Prop, AValue) then
    begin
      AErrCode := ErrUnsupportedAction;
      AErrMsg := AInstance.ClassName + '.' + APropName + ' getter raised or returned no value';
      EXIT;
    end;
    Result := TRUE;
  FINALLY
    Ctx.Free;
  END;
END;


FUNCTION HandleReadProperty(CONST AReq: TBridgeRequest): TBridgeResponse;
VAR
  PathVal, NameVal: TJSONValue;
  Path, PropName: String;
  Comp: TComponent;
  ErrCode: Integer;
  ErrMsg, Value, Kind: String;
  Wrap: TJSONObject;
  FailedInstance: TObject;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'HandleReadProperty must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;

  if AReq.Args = NIL then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'read_property requires args.path and args.propName';
    EXIT;
  end;
  PathVal := AReq.Args.GetValue('path');
  NameVal := AReq.Args.GetValue('propName');
  if not (PathVal IS TJSONString) or not (NameVal IS TJSONString) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'read_property requires args.path and args.propName (strings)';
    EXIT;
  end;
  Path := TJSONString(PathVal).Value;
  PropName := TJSONString(NameVal).Value;

  Comp := FindComponentByPath(Path);
  if Comp = NIL then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrNotFound;
    Result.ErrorMessage := 'no component matches ' + Path;
    EXIT;
  end;
  // No Enabled check — reading a disabled control is exactly what a debug session needs.

  if not TryReadGenericProperty(Comp, PropName, Value, Kind, ErrCode, ErrMsg, FailedInstance) then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrCode;
    Result.ErrorMessage := ErrMsg;
    if ErrCode = ErrRttiPropertyMissing then
    begin
      Result.ErrorData := TJSONObject.Create;
      if FailedInstance = NIL then FailedInstance := Comp;
      Result.ErrorData.AddPair('availableProperties', ListReadableProperties(FailedInstance));
    end;
    EXIT;
  end;

  Wrap := TJSONObject.Create;
  Wrap.AddPair('path', Path);
  Wrap.AddPair('propName', PropName);
  Wrap.AddPair('value', Value);
  Wrap.AddPair('kind', Kind);
  Result.Ok := TRUE;
  Result.ResultJson := Wrap;
END;


// Android keep-screen-on. Sets/clears FLAG_KEEP_SCREEN_ON on the activity window;
// while it is set and the app is foreground the screen never turns off, so the
// OxygenOS/AOSP cached-apps freezer (which fires on the LcdOff scene) never stalls
// the socket accept. Must run on the UI (main) thread — Dispatch and
// StartBridgeInternal both call it there. No-op on every non-Android platform: the
// screen-off process freeze is Android power management; a Windows target is never
// frozen by the OS while an automation client drives it.
PROCEDURE ApplyKeepScreenOn(AEnable: Boolean);
BEGIN
  {$IFDEF ANDROID}
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'ApplyKeepScreenOn: JNI window flag touched off the main thread');
  if AEnable
  then TAndroidHelper.Activity.getWindow.addFlags(TJWindowManager_LayoutParams.JavaClass.FLAG_KEEP_SCREEN_ON)
  else TAndroidHelper.Activity.getWindow.clearFlags(TJWindowManager_LayoutParams.JavaClass.FLAG_KEEP_SCREEN_ON);
  {$ENDIF}
END;


// dismiss_dialog — reach native Win32 dialogs (MessageBox / Task Dialog / common dialogs)
// the component-tree tools cannot see. Real on FMX-Windows (the shared helper drives the
// Win32 windows); on Android the helper returns supported:false (Android dialogs are ART
// windows, out of Win32 reach). FMX forms are NOT native Win32 dialogs — FMX renders its
// controls itself, so a form HWND has no child 'Button' windows and is not class '#32770',
// and never matches the dialog filter — so no exclude list is needed here.
FUNCTION HandleDismissDialog(CONST AReq: TBridgeRequest): TBridgeResponse;
VAR
  ButtonVal, HwndVal: TJSONValue;
  Selector, PlatformName: String;
  HasButton, Clicked: Boolean;
  TargetDlg, ResolvedDlg: NativeUInt;
  Exclude: TArray<NativeUInt>;
  Wrap: TJSONObject;
  ClickedId: Integer;
  ClickedCap, Reason: String;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'HandleDismissDialog must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;

  Selector := '';
  HasButton := FALSE;
  TargetDlg := 0;
  if AReq.Args <> NIL then
  begin
    ButtonVal := AReq.Args.GetValue('button');
    if ButtonVal IS TJSONString then
    begin
      Selector := TJSONString(ButtonVal).Value;
      HasButton := Trim(Selector) <> '';
    end;
    HwndVal := AReq.Args.GetValue('hwnd');
    if HwndVal IS TJSONNumber then
      TargetDlg := NativeUInt(TJSONNumber(HwndVal).AsInt64);
  end;

  Exclude := NIL;   // FMX forms never match the dialog filter (see header)

  {$IFDEF MSWINDOWS} PlatformName := 'windows';
  {$ELSE}{$IFDEF ANDROID} PlatformName := 'android';
  {$ELSE} PlatformName := 'posix'; {$ENDIF}{$ENDIF}

  Wrap := TJSONObject.Create;
  TRY
    Wrap.AddPair('dialogs', EnumerateNativeDialogs(Exclude));   // empty off Windows
    Wrap.AddPair('supported', TJSONBool.Create(NativeDialogsSupported));
    Wrap.AddPair('platform', PlatformName);
    if HasButton then
    begin
      Clicked := ClickNativeDialogButton(Exclude, TargetDlg, Selector, ClickedId, ClickedCap, ResolvedDlg, Reason);
      Wrap.AddPair('clicked', TJSONBool.Create(Clicked));
      if Clicked then
      begin
        Wrap.AddPair('clickedId', TJSONNumber.Create(ClickedId));
        Wrap.AddPair('clickedCaption', ClickedCap);
        Wrap.AddPair('dialogHwnd', TJSONNumber.Create(Int64(ResolvedDlg)));
        Wrap.AddPair('via', 'WM_COMMAND');
      end
      else
        Wrap.AddPair('reason', Reason);
    end;
    Result.Ok := TRUE;
    Result.ResultJson := Wrap;
    Wrap := NIL;
  FINALLY
    if Wrap <> NIL then FreeAndNil(Wrap);
  END;
END;


// set_keep_awake — toggles the device "keep screen on" state (see ApplyKeepScreenOn).
// Android: applies the window flag, reports applied:true. Off Android: accepted but a
// no-op (applied:false), so the shared MCP tool behaves uniformly against a VCL/Windows
// target. The bridge enables this by default on Android at StartBridge.
FUNCTION HandleSetKeepAwake(CONST AReq: TBridgeRequest): TBridgeResponse;
VAR
  EnabledVal: TJSONValue;
  Enable: Boolean;
  PlatformName: String;
  Applied: Boolean;
  Wrap: TJSONObject;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'HandleSetKeepAwake must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;
  if AReq.Args = NIL then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'set_keep_awake requires args.enabled';
    EXIT;
  end;
  EnabledVal := AReq.Args.GetValue('enabled');
  if not (EnabledVal IS TJSONBool) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'set_keep_awake requires args.enabled (boolean)';
    EXIT;
  end;
  Enable := TJSONBool(EnabledVal).AsBoolean;

  ApplyKeepScreenOn(Enable);     // no-op off Android

  {$IFDEF ANDROID}
  PlatformName := 'android';
  Applied := TRUE;
  {$ELSE}
  PlatformName := {$IFDEF MSWINDOWS} 'windows' {$ELSE} 'posix' {$ENDIF};
  Applied := FALSE;
  {$ENDIF}

  Wrap := TJSONObject.Create;
  Wrap.AddPair('enabled', TJSONBool.Create(Enable));
  Wrap.AddPair('platform', PlatformName);
  Wrap.AddPair('applied', TJSONBool.Create(Applied));
  Result.Ok := TRUE;
  Result.ResultJson := Wrap;
END;


FUNCTION Dispatch(CONST AReq: TBridgeRequest): TBridgeResponse;
BEGIN
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'Dispatch must run on the main thread');
  if SameText(AReq.Cmd, 'list_tree') then
    Result := HandleListTree(AReq)
  else if SameText(AReq.Cmd, 'click') then
    Result := HandleClick(AReq)
  else if SameText(AReq.Cmd, 'get_text') then
    Result := HandleGetText(AReq)
  else if SameText(AReq.Cmd, 'set_text') then
    Result := HandleSetText(AReq)
  else if SameText(AReq.Cmd, 'set_checked') then
    Result := HandleSetChecked(AReq)
  else if SameText(AReq.Cmd, 'set_property') then
    Result := HandleSetProperty(AReq)
  else if SameText(AReq.Cmd, 'read_property') then
    Result := HandleReadProperty(AReq)
  else if SameText(AReq.Cmd, 'screenshot') then
    Result := HandleScreenshot(AReq)
  else if SameText(AReq.Cmd, 'execute_action') then
    Result := HandleExecuteAction(AReq)
  else if SameText(AReq.Cmd, 'set_keep_awake') then
    Result := HandleSetKeepAwake(AReq)
  else if SameText(AReq.Cmd, 'dismiss_dialog') then
    Result := HandleDismissDialog(AReq)
  else
  begin
    Result := Default(TBridgeResponse);
    Result.Id := AReq.Id;
    Result.Ok := FALSE;
    Result.ErrorCode := ErrUnsupportedAction;
    Result.ErrorMessage := 'unknown cmd: ' + AReq.Cmd;
  end;
END;


PROCEDURE EnsureLock;
BEGIN
  if GLock = NIL then
    GLock := TCriticalSection.Create;
END;


// AEndpoint: Windows = the full pipe name; POSIX = the abstract-socket name.
PROCEDURE StartBridgeInternal(CONST AEndpoint: String);
VAR
  ExeName: String;
BEGIN
  EnsureLock;
  GLock.Enter;
  TRY
    if GWorker <> NIL then EXIT;
    ExeName := ExtractFileName(ParamStr(0));
    BridgeLogInfo('bridge', 'StartBridge (FMX) exe=' + ExeName + ' endpoint=' + AEndpoint);
    BridgeLogInfo('license', CommercialLicenseHint);
    {$IFDEF MSWINDOWS}
    GWorker := TBridgeWorker.Create(TPipeTransport.Create(AEndpoint), ExeName, Dispatch);
    {$ELSE}
    GWorker := TBridgeWorker.Create(TSocketTransport.Create(AEndpoint), ExeName, Dispatch);
    {$ENDIF}
    {$IFDEF ANDROID}
    // Keep the screen on by default while the bridge runs: a backgrounded / screen-off
    // app is frozen by Android power management, which stalls the socket accept (see
    // ApplyKeepScreenOn). set_keep_awake(false) releases it. AUTOPILOT builds only.
    ApplyKeepScreenOn(TRUE);
    BridgeLogInfo('bridge', 'keep-screen-on enabled (Android default)');
    {$ENDIF}
  FINALLY
    GLock.Leave;
  END;
END;


PROCEDURE StartBridge;
BEGIN
  {$IFDEF MSWINDOWS}
  StartBridgeInternal(ComputePipeName);
  {$ELSE}
  // Per-process abstract name; the kernel removes it when the socket closes.
  // The PC side reaches it via: adb forward tcp:<hostPort> localabstract:Autopilot.<pid>
  StartBridgeInternal('Autopilot.' + IntToStr(getpid));
  {$ENDIF}
END;


PROCEDURE StartBridgeOnPipe(CONST APipeName: String);
BEGIN
  StartBridgeInternal(APipeName);
END;


PROCEDURE StopBridge;
BEGIN
  if GLock = NIL then EXIT;
  GLock.Enter;
  TRY
    if GWorker = NIL then EXIT;
    BridgeLogInfo('bridge', 'StopBridge (FMX)');
    GWorker.Terminate;
    FreeAndNil(GWorker);
  FINALLY
    GLock.Leave;
  END;
END;


FUNCTION IsBridgeRunning: Boolean;
BEGIN
  Result := GWorker <> NIL;
END;


{$ELSE}

PROCEDURE StartBridge;        BEGIN END;
PROCEDURE StartBridgeOnPipe(CONST APipeName: String); BEGIN END;
PROCEDURE StopBridge;         BEGIN END;
FUNCTION  IsBridgeRunning: Boolean; BEGIN Result := FALSE; END;

{$ENDIF}


INITIALIZATION

FINALIZATION
{$IFDEF AUTOPILOT}
  if GWorker <> NIL then
    StopBridge;
  if GLock <> NIL then
    FreeAndNil(GLock);
{$ENDIF}


END.
