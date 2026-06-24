UNIT Autopilot.Bridge.Vcl;

(*=====================================================
   2026.06.24 — added 'dismiss_dialog' command: drives native Win32 dialogs (MessageBox,
                Task Dialog, common dialogs) that have no TComponent and so are invisible
                to list_tree / click. Enumerates this process's top-level dialog windows
                (Win32, via Autopilot.Bridge.NativeDialogs, excluding our own VCL form
                handles) and dispatches a button by role / caption / id. Runs on the main
                thread like every other command — a visible dialog means a pumping modal
                loop, so TThread.Queue still reaches us. Result: {dialogs[], supported,
                platform, clicked?, clickedId?, clickedCaption?, reason?}.
   2026.06.10 — Delphi 11 compatibility: ColorToStringExt / csf* / TryStringToColor
                only exist from Delphi 12 (System.UIConsts). Replaced with local
                equivalents (ColorToWebHex / ColorToDelphiHex / TryStringToColorCompat)
                so one source compiles on Delphi 11..13 with identical behavior.
                Name-table note: the cl-name table is the RTL's own (Vcl.Graphics
                delegates to System.UIConsts on all three versions), so each
                version accepts exactly the names it can emit — D11 ships 200
                cl-names, D13 ships 334 (web-color names are a D12+ addition).
   2026.05.30 — added 'execute_action' command: fires TBasicAction.Execute by path.
                Closes the action-with-no-control gap (e.g. shortcut-only actions
                like actFileExit triggered by Alt+F4). Enabled-guarded — base
                Execute fires OnExecute regardless of Enabled, so the bridge
                checks here. Rejects non-actions with -32005 pointing back to
                click. Behaviour byte-identical with the FMX twin.
                Result: {path, dispatchedVia:'Execute', executed:bool}.
   2026.05.20 — added 'read_property' command: RTTI-based published-property reader.
                Mirrors set_property's path resolution, dotted-name nesting,
                and type-aware string formatting (TColor → 'clName'/'#RRGGBB',
                TAlphaColor → 'claName'/'#AARRGGBB', set → '[a,b]', enum →
                identifier). Returns {value, kind} on success. Does NOT enforce
                Enabled — debugging a disabled control is a legitimate use case.
                Recovery payload on rtti_property_missing lists the READABLE
                surface (superset of writable) so a typo on a read-only property
                like Pages still gets a useful hint.
   2026.05.15 — set_property gained TColor coercion (VCL only — TColor is a VCL
                concept; FMX uses TAlphaColor). tkInteger props typed as TColor
                accept 'clRed' / any cl* identifier, '#RRGGBB' (web RGB), '#RGB'
                short form, '$00BBGGRR' Pascal hex, or a decimal value.
                availableProperties returns kind:'color'; currentValue is rendered
                as 'clName' (when ColorToIdent matches) or '#RRGGBB'.
   2026.05.14 — set_property gained TAlphaColor coercion (parity with FMX bridge):
                tkInteger props typed as TAlphaColor accept '#RRGGBB' (alpha
                assumed FF), '#AARRGGBB', 'claSkyBlue', bare 'SkyBlue', or a
                numeric value. availableProperties returns kind:'alphacolor';
                currentValue is rendered as 'claName' or '#AARRGGBB'.
   2026.05.14 — set_property accepts a one-level dotted propName ('Font.Size',
                'Lines.Text'). When the outer property is tkClass the inner
                object's published property is written instead. Unknown inner
                names return availableProperties enumerated off the INNER class,
                so the AI sees what's writable on the nested object.
   2026.05.14 — set_property gained tkSet (set-of-enum) support: accepts '[a,b]',
                'a,b', '[]', or an ordinal; identifiers are case-insensitive.
                availableProperties entries now carry a 'currentValue' string for
                readable properties — same shape set_property would accept back —
                so the AI sees state + writable surface in one round-trip.
   2026.05.14 — added 'set_property' command: generic RTTI-based published-property setter.
                Supports string / integer / int64 / boolean / other-enum / float. On
                'property missing' the response carries error.data.availableProperties
                so the AI can self-correct (Plans/04 R2).
   2026.05.12 — added 'count' to click for low-overhead repeated clicks; resolves dispatch
                path once outside loop; re-checks Enabled per iteration; reports
                clicksDispatched + optional stoppedReason on partial success.
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────┐
   │  WINDOWS ONLY                │   (stable / shipped branch — VCL is Windows-only)
   └──────────────────────────────┘

   Public surface of the Autopilot bridge (VCL flavor).

   Drop this unit into a target Delphi VCL project. Add AUTOPILOT to the project's
   conditional defines. Call StartBridge once after Application.CreateForm.

   The INTERFACE is always compiled (so `uses Autopilot.Bridge.Vcl;` is always valid).
   The IMPLEMENTATION switches between real bodies and no-ops via the AUTOPILOT define.
   Release builds (without the define) pay zero runtime cost: no thread, no pipe.

   See CLAUDE.md "Architectural decisions already locked".
=====================================================*)

INTERFACE

USES
  System.Classes;

/// Starts the bridge worker thread, opens the named pipe, writes the discovery file.
/// Safe to call multiple times — second+ calls are no-ops.
/// No-op in builds without AUTOPILOT defined.
PROCEDURE StartBridge;

/// Stops the bridge, closes the pipe, deletes the discovery file.
/// The host should call this once the message loop has ended (e.g. right after
/// Application.Run returns). As a safety net, the unit's FINALIZATION calls it if
/// the host forgot — so the worker is never leaked. NOTE: there is no automatic
/// Application.OnDestroy hook; an earlier comment claimed one but none was ever
/// installed (see HANDOVER.md, 2026-06-24).
/// No-op in builds without AUTOPILOT defined.
PROCEDURE StopBridge;

/// TRUE when the bridge is running. Always FALSE when AUTOPILOT is not defined.
FUNCTION  IsBridgeRunning: Boolean;

/// For tests: start on a caller-supplied pipe name instead of the auto-computed one.
/// Used by the DUnitX suite to avoid PID collisions and to find the pipe deterministically.
PROCEDURE StartBridgeOnPipe(CONST APipeName: String);


IMPLEMENTATION

{$IFDEF AUTOPILOT}
USES
  Winapi.Windows,
  System.SysUtils, System.SyncObjs, System.JSON, System.Rtti, System.TypInfo,
  System.NetEncoding, System.UITypes, System.UIConsts,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Graphics, Vcl.Imaging.PngImage,
  Autopilot.Bridge.Core, Autopilot.Bridge.Log, Autopilot.Bridge.NamedPipe, Autopilot.Bridge.NativeDialogs, Autopilot.Bridge.Worker;
{$ELSE}
USES
  System.SysUtils;
{$ENDIF}


{$IFDEF AUTOPILOT}

VAR
  GWorker: TBridgeWorker = NIL;
  GLock  : TCriticalSection = NIL;


{ Component-tree walk and RTTI helpers ---------------------------------- }

TYPE
  TWinControlClass = CLASS(TWinControl);   // breaks protected scope for .Click


// Synthetic ID for an unnamed component: '@TButton#5' where 5 is the component's
// current position in its owner's Components list. The index is computed live
// each time (TComponent.GetComponentIndex calls FOwner.FComponents.IndexOf(Self)
// — see System.Classes.pas:18065) and shifts down by 1 every time an earlier-indexed
// sibling is freed (RemoveComponent compacts the list — System.Classes.pas:17739-42).
// A synthetic ID captured from list_tree at time T is reliable only if no
// earlier-indexed sibling of the target is freed between T and the next call.
// The ClassName check in MatchesLeaf rejects most stale IDs (different class at
// that slot) but cannot rule out a same-class collision. Returns '' if the
// component does have a name.
FUNCTION SyntheticIdFor(AComp: TComponent): String;
BEGIN
  Assert(GetCurrentThreadId = MainThreadID, 'SyntheticIdFor: VCL touched off the main thread');
  if AComp.Name <> '' then EXIT('');
  Result := '@' + AComp.ClassName + '#' + IntToStr(AComp.ComponentIndex);
END;


// Match a leaf segment (real Name or synthetic '@ClassName#Index') against a component
// owned by AOwner. The index in a synthetic ID is OWNER-relative — '@TButton#0' against
// Form means Form.Components[0], against Frame means Frame.Components[0]. Those are
// different components. The 2-part flat path 'Form.@TButton#0' is therefore ambiguous
// when multiple containers under Form each have a TButton at index 0: it will match
// the shallowest (the form's direct child, per FindDescendantOf's BFS preference).
// Callers wanting unambiguous resolution of a synthetic ID should use the anchored
// form 'Form.Container.@TButton#0'.
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
    // Synthetic: '@ClassName#Index'. Anchor on the owner's slot at that index, then
    // verify the class to detect a stale ID after the form was reshaped.
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


// Find a direct child of AParent matching ALeaf. Does not recurse.
FUNCTION FindChildOf(AParent: TComponent; CONST ALeaf: String): TComponent;
VAR
  j: Integer;
BEGIN
  Result := NIL;
  for j := 0 to AParent.ComponentCount - 1 do
    if MatchesLeaf(AParent, AParent.Components[j], ALeaf) then
      EXIT(AParent.Components[j]);
END;


// Recurse from AParent looking for any descendant matching ALeaf. Avoids cycles
// via AVisited. Prefers shallow matches: scans ALL direct children before
// recursing into any of them. This makes 2-part flat paths predictable when a
// name exists at both a direct-child level and inside a nested container —
// the shallower one wins, matching human expectation and the pre-Phase-3
// "direct child only" behavior.
FUNCTION FindDescendantOf(AParent: TComponent; CONST ALeaf: String; AVisited: TList): TComponent;
VAR
  j: Integer;
  Child: TComponent;
BEGIN
  Result := NIL;
  // Pass 1: all direct children of AParent. Also seeds Visited so pass 2
  // doesn't reprocess the same nodes.
  for j := 0 to AParent.ComponentCount - 1 do
  begin
    Child := AParent.Components[j];
    if AVisited.IndexOf(Child) >= 0 then Continue;
    AVisited.Add(Child);
    if MatchesLeaf(AParent, Child, ALeaf) then
      EXIT(Child);
  end;
  // Pass 2: recurse into containers, in declaration order.
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


// Map a path to a TComponent. Returns NIL if no match.
//   "Form"             — the named form itself (round-trips with list_tree's
//                        emitted path for form nodes).
//   "Form.Leaf"        — Leaf can be anywhere under Form (incl. inside frames).
//   "*.Leaf"           — Leaf can be under any form.
//   "Form.A.B.C"       — anchored walk: A is direct child of Form, B is direct
//                        child of A, C is direct child of B.
// Unnamed components are addressable via '@ClassName#Index' — see SyntheticIdFor.
FUNCTION FindComponentByPath(CONST APath: String): TComponent;
VAR
  i, k: Integer;
  Form: TCustomForm;
  Parts: TArray<String>;
  FormName: String;
  Cur: TComponent;
  Visited: TList;
BEGIN
  Assert(GetCurrentThreadId = MainThreadID, 'FindComponentByPath: VCL touched off the main thread');
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
    begin
      // Path is just the form name — return the form itself. Wildcard '*' alone
      // matches the first form, which is intentional (no good alternative).
      EXIT(Form);
    end
    else if Length(Parts) = 2 then
    begin
      // Flat search: leaf can be anywhere under the form, including inside frames.
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
      // Anchored walk: each segment must be a direct child of the previous.
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


// Attempt to read a published Text/Caption-style property via RTTI.
FUNCTION TryGetTextProperty(AComp: TComponent; OUT AValue: String): Boolean;
VAR
  Ctx: TRttiContext;
  RT: TRttiType;
  Prop: TRttiProperty;
BEGIN
  Assert(GetCurrentThreadId = MainThreadID, 'TryGetTextProperty: VCL touched off the main thread');
  Result := FALSE;
  AValue := '';
  Ctx := TRttiContext.Create;
  TRY
    RT := Ctx.GetType(AComp.ClassType);
    if RT = NIL then EXIT;
    // VCL: Text first, then Caption.
    Prop := RT.GetProperty('Text');
    if (Prop = NIL) or not Prop.IsReadable then
      Prop := RT.GetProperty('Caption');
    if (Prop = NIL) or not Prop.IsReadable then EXIT;
    // The Caption getter on TForm can trigger handle realization in some scenarios
    // and AV on an unrealized form. Swallow any read-side exception and report
    // "no readable text" rather than crashing the dispatcher.
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
  Assert(GetCurrentThreadId = MainThreadID, 'TryGetEnabled: VCL touched off the main thread');
  Result := FALSE;
  AEnabled := TRUE;
  Ctx := TRttiContext.Create;
  TRY
    RT := Ctx.GetType(AComp.ClassType);
    if RT = NIL then EXIT;
    Prop := RT.GetProperty('Enabled');
    if (Prop = NIL) or not Prop.IsReadable then EXIT;
    // Same guard pattern as TryGetTextProperty: a misbehaving published getter
    // must not propagate out and leak the in-flight TJSONArray/TJSONObject in
    // HandleListTree. Swallow and report "no readable Enabled".
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
  Assert(GetCurrentThreadId = MainThreadID, 'TryGetVisible: VCL touched off the main thread');
  Result := FALSE;
  AVisible := TRUE;
  Ctx := TRttiContext.Create;
  TRY
    RT := Ctx.GetType(AComp.ClassType);
    if RT = NIL then EXIT;
    Prop := RT.GetProperty('Visible');
    if (Prop = NIL) or not Prop.IsReadable then EXIT;
    // Same guard as TryGetEnabled. Prevents leaks in HandleListTree.
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


// Set a published string-style property via RTTI. Tries Text first then Caption.
// Returns FALSE if no writable matching property exists; AErrCode tells the caller
// whether the property is genuinely missing or simply read-only.
FUNCTION TrySetTextProperty(AComp: TComponent; CONST AValue: String; OUT AErrCode: Integer): Boolean;
VAR
  Ctx: TRttiContext;
  RT: TRttiType;
  Prop: TRttiProperty;
BEGIN
  Assert(GetCurrentThreadId = MainThreadID, 'TrySetTextProperty: VCL touched off the main thread');
  Result := FALSE;
  AErrCode := ErrRttiPropertyMissing;
  Ctx := TRttiContext.Create;
  TRY
    RT := Ctx.GetType(AComp.ClassType);
    if RT = NIL then EXIT;
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


{ Delphi 11 color compatibility: ColorToStringExt, the csf* formats and TryStringToColor only exist from Delphi 12 (System.UIConsts). The three helpers below re-implement exactly the behavior the bridge used from them, so one source serves Delphi 11..13 identically. }

// '#RRGGBB' web hex for a TColor whose top byte is zero. Same byte reorder as
// System.UIConsts.ColorToStringExt(csfWebHex): TColor stores BGR, web order is
// RGB. Only valid for top-byte-zero values — IntToHex(_, 6) emits more than
// 6 digits otherwise; the call site guards that.
FUNCTION ColorToWebHex(AColor: TColor): String;
VAR
  Hex: String;
BEGIN
  Hex := IntToHex(Integer(AColor), 6);                                  // 'BBGGRR'
  Result := '#' + Copy(Hex, 5, 2) + Copy(Hex, 3, 2) + Copy(Hex, 1, 2); // '#RRGGBB'
END;


// '$xxxxxxxx' Pascal hex, 8 digits — same shape as ColorToStringExt(csfDelphiHex).
FUNCTION ColorToDelphiHex(AColor: TColor): String;
BEGIN
  Result := HexDisplayPrefix + IntToHex(Integer(AColor), 8);
END;


// System.UIConsts.TryStringToColor re-implemented: cl-name via IdentToColor,
// then '#RRGGBB' / '#RGB' web hex, then Val ('$hex' or decimal — Val wraps
// '$8000000F'-style 32-bit hex into the negative range, so ColorToDelphiHex
// output round-trips). IdentToColor resolves through the RTL's own name table,
// so each Delphi version accepts exactly the names it can emit.
FUNCTION TryStringToColorCompat(CONST S: String; VAR AColor: TColor): Boolean;
VAR
  Hex6: String;
  RgbVal: Integer;
  ErrPos: Integer;
BEGIN
  if IdentToColor(S, Integer(AColor)) then EXIT(TRUE);
  case Length(S) of
    7: if S[1] = '#' then Hex6 := Copy(S, 2, 6);
    4: if S[1] = '#' then Hex6 := S[2] + S[2] + S[3] + S[3] + S[4] + S[4];
  end;
  if Hex6 <> '' then
  begin
    if not TryStrToInt('$' + Hex6, RgbVal) then EXIT(FALSE);
    // RgbVal holds $00RRGGBB; TColor stores $00BBGGRR
    AColor := TColor(((RgbVal and $FF0000) shr 16) or (RgbVal and $00FF00) or ((RgbVal and $0000FF) shl 16));
    EXIT(TRUE);
  end;
  if (S <> '') and (S[1] = '#') then EXIT(FALSE);   // '#' with a wrong digit count
  Val(S, AColor, ErrPos);
  Result := ErrPos = 0;
END;


// Read AProp's current value off AInstance and format it as a string set_property
// would accept back. Returns FALSE on an unreadable property or a getter that
// throws. Mirrors the kinds ListWritableProperties surfaces. AInstance is TObject
// (not TComponent) so the helper also works on nested TPersistent classes
// reached via dotted propName.
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
  Assert(GetCurrentThreadId = MainThreadID, 'TryReadPropertyAsString: VCL touched off the main thread');
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
          AValue := IntToStr(V.AsOrdinal);
          Result := TRUE;
        END;
        EXIT;
      end;
      // TColor: emit 'clName' for named system/standard colors, '#RRGGBB' otherwise.
      // System colors (clBtnFace = $8000000F etc.) ALWAYS match ColorToIdent —
      // they're in the registered Colors[] table — so the web-hex fallback is
      // only reached for "plain" 24-bit BGR values where the top byte is $00.
      // For top-byte-set values that miss the ident table (rare custom values),
      // we fall back to '$00BBGGRR' Pascal-hex form, which TryParseColor accepts
      // back via TryStringToColorCompat's Val branch. Reason: web hex only has
      // 6 digits, which would silently truncate 8-digit values like $8000000F
      // into a wrong 6-digit '#0F0000' string.
      if AProp.PropertyType.Handle = TypeInfo(TColor) then
      begin
        TRY
          // ColorToIdent sets AValue to e.g. 'clRed' when the integer matches
          // a registered TColor identifier (which includes all system colors
          // in the $8000000x range, so the high-bit branch below is rare).
          if not ColorToIdent(V.AsOrdinal, AValue) then
          begin
            if (V.AsOrdinal and $FF000000) = 0 then
              AValue := ColorToWebHex(TColor(V.AsOrdinal))
            else
              // Web hex's 6 digits would silently truncate 8-digit values like
              // $8000000F into a wrong 6-digit '#0F0000' string. Use Pascal-hex
              // form for those; TryParseColor accepts both shapes back.
              AValue := ColorToDelphiHex(TColor(V.AsOrdinal));
          end;
          Result := TRUE;
        EXCEPT
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
      // SetToString emits e.g. '[biSystemMenu,biMinimize]'. Round-trips with
      // StringToSet — exactly what TrySetGenericProperty's tkSet path accepts.
      SetStr := SetToString(AProp.PropertyType.Handle, Integer(V.GetReferenceToRawData^), TRUE);
      AValue := SetStr;
      Result := TRUE;
    end;
  end;
END;


// Build a JSON array of writable property names available on AInstance, with
// their RTTI type kind annotated so the AI can pick a compatible value next
// time. Each entry also carries an optional 'currentValue' string (when
// readable) — same shape set_property would accept back, so one round-trip
// sees both what can be set and what is set. Used by HandleSetProperty when
// the requested PropName is unknown.
//
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
  Assert(GetCurrentThreadId = MainThreadID, 'ListWritableProperties: VCL touched off the main thread');
  Result := TJSONArray.Create;
  Ctx := TRttiContext.Create;
  TRY
    RT := Ctx.GetType(AInstance.ClassType);
    if RT = NIL then EXIT;
    for Prop in RT.GetProperties do
    begin
      if not Prop.IsWritable then Continue;
      // Only list types set_property can write today: string / int / int64 / enum / set / float / class.
      // Surfacing methods, interfaces, variants etc. just sets the AI up to fail again.
      // tkClass is included so the AI sees that 'Outer.Inner' nesting is available.
      // TAlphaColor is tkInteger by RTTI but we label it 'alphacolor' so the AI
      // knows to send '#AARRGGBB' / 'claName' rather than a raw integer.
      case Prop.PropertyType.TypeKind of
        tkString, tkLString, tkWString, tkUString: KindName := 'string';
        tkInteger:
          if Prop.PropertyType.Handle = TypeInfo(TAlphaColor) then
            KindName := 'alphacolor'
          else if Prop.PropertyType.Handle = TypeInfo(TColor) then
            KindName := 'color'
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
      // For tkClass the 'currentValue' string would be a meaningless object pointer.
      // Skip it for that kind — TryReadPropertyAsString already returns FALSE for
      // tkClass, which omits the field, but be explicit.
      if Prop.PropertyType.TypeKind <> tkClass then
        if TryReadPropertyAsString(AInstance, Prop, CurStr) then
          Node.AddPair('currentValue', CurStr);
      Result.AddElement(Node);
    end;
  FINALLY
    Ctx.Free;
  END;
END;


// AI-friendly TColor parser (VCL only — FMX uses TAlphaColor). Accepts:
//   'clRed' / 'clBtnFace' / 'cl*'  — System.UIConsts named TColor constants (case-insensitive)
//   '#FF0080'                       — 6 hex digits, web RGB order. StringToColor reads
//                                     R/G/B bytes into the low 3 bytes of TColor (which is
//                                     BGR-stored), so the result matches what the AI meant.
//   '$00800080'                     — Pascal-style hex literal ($00BBGGRR)
//   '8388736'                       — decimal
//   '#F08'                          — 3-digit short form (expands to '#FF0088')
// Returns FALSE without raising on anything else. TryStringToColorCompat already
// does the work — we just wrap the exception path.
FUNCTION TryParseColor(CONST AStrValue: String; OUT AColor: TColor): Boolean;
VAR
  S: String;
BEGIN
  Result := FALSE;
  S := Trim(AStrValue);
  if S = '' then EXIT;
  TRY
    Result := TryStringToColorCompat(S, AColor);
  EXCEPT
    // Defensive: TryStringToColorCompat shouldn't raise, but Val inside it could
    // on garbage input. Map any escape to FALSE — caller turns this into unsupported_action.
    Result := FALSE;
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
// AErrCode/AErrMsg communicate the failure mode. Supported types match
// ListWritableProperties' filter: string, integer, int64, boolean, other enum,
// set-of-enum, float.
//
// On tkEnumeration we accept BOTH the enum identifier ('poDesigned') AND its ordinal
// ('1'). Boolean is handled specially since RTTI exposes it as tkEnumeration with
// TypeInfo=Boolean. On tkSet we accept a bracket literal ('[a,b]'), a bare list
// ('a,b'), the empty set ('[]'), or a numeric ordinal. Returns FALSE without
// raising — bridge worker translates the out parameters into a structured error response.
//
// Dotted propName ('Font.Size', 'Lines.Text'): when the outer property is tkClass
// and APropName contains exactly one dot, we recurse onto the inner object with
// the inner property name. Only one level of nesting is supported. The inner
// object must be non-nil and an actual instance — failure modes are surfaced
// as unsupported_action / rtti_property_missing the same way as the flat path.
//
// TAlphaColor (RTTI says tkInteger) is detected by type handle and routed
// through TryParseAlphaColor so the AI can pass '#FF8000' or 'claSkyBlue'
// instead of a raw 32-bit integer.
//
// AInstance is TObject (not TComponent) — the recursive call passes the inner
// TPersistent (e.g. TFont, TStrings) which is not a TComponent.
//
// AFailedInstance: on FALSE return with ErrRttiPropertyMissing, this is set to
// the object the lookup was performed against — the OUTER component on a flat
// failure, or the INNER class instance when a dotted propName's inner was the
// typo. HandleSetProperty uses this to populate availableProperties with the
// correct class's writable surface.
//
// AElided: on TRUE return, this is set to TRUE iff the live property value
// already equalled the coerced new value, so the bridge skipped Prop.SetValue
// (no OnChange fires). Comparison is type-aware: string identity, integer/int64
// equality (TAlphaColor/TColor as 32-bit equality), boolean equality, enum
// ordinal equality, set ordinal equality, float exact-bits equality (no epsilon
// — the AI sent a string, we coerce both sides through the same parser, so
// repeat-writes of the same string round-trip exactly). For unreadable
// properties (writable but no getter, rare) we cannot compare — fall through
// to the write, AElided stays FALSE. On FALSE return, AElided is FALSE.

// Standard VCL has a small set of "Parent<X>: Boolean" properties whose
// default-TRUE state means "this control inherits <X> from its parent". The
// VCL itself auto-flips Parent<X>:=FALSE inside SetColor/FontChanged/etc.
// when a *value-changing* write happens (Vcl.Controls.pas:6937 for
// FontChanged, :7026 for SetColor). The bridge pre-flips here for two
// reasons: (a) consistency — every successful set_property leaves the
// control owning the property, never inheriting it, regardless of elision;
// (b) the elision path: when the live value already equals the requested
// value the bridge skips SetValue, so the VCL never gets a chance to do the
// auto-flip itself — without this helper, an elided Color resend on a
// freshly-created control would leave ParentColor=TRUE, making the "elided
// → no change" response a half-truth (Parent inheritance is still active).
// Silent: no extra field in the response. List sourced from
// c:\Delphi\Delphi 13\source\vcl (Vcl.Controls.pas / Vcl.Forms.pas /
// Vcl.ComCtrls.pas), 2026-05-20.
PROCEDURE TurnOffParentInheritFor(AInstance: TObject; CONST ATargetPropName: String);
CONST
  PAIRS: ARRAY[0..6] OF RECORD Target, Parent: String END = (
    (Target: 'Font';            Parent: 'ParentFont'),
    (Target: 'Color';           Parent: 'ParentColor'),
    (Target: 'BiDiMode';        Parent: 'ParentBiDiMode'),
    (Target: 'ShowHint';        Parent: 'ParentShowHint'),
    (Target: 'DoubleBuffered';  Parent: 'ParentDoubleBuffered'),
    (Target: 'CustomHint';      Parent: 'ParentCustomHint'),
    (Target: 'Ctl3D';           Parent: 'ParentCtl3D')
  );
VAR
  Ctx: TRttiContext;
  RT: TRttiType;
  ParentProp: TRttiProperty;
  Cur: TValue;
  i: Integer;
  ParentName: String;
BEGIN
  Assert(GetCurrentThreadId = MainThreadID, 'TurnOffParentInheritFor: VCL touched off the main thread');
  ParentName := '';
  for i := Low(PAIRS) to High(PAIRS) do
    if SameText(PAIRS[i].Target, ATargetPropName) then
    begin
      ParentName := PAIRS[i].Parent;
      BREAK;
    end;
  if ParentName = '' then EXIT;

  Ctx := TRttiContext.Create;
  TRY
    RT := Ctx.GetType(AInstance.ClassType);
    if RT = NIL then EXIT;
    ParentProp := RT.GetProperty(ParentName);
    if (ParentProp = NIL) or not ParentProp.IsWritable or not ParentProp.IsReadable then EXIT;
    if ParentProp.PropertyType.Handle <> TypeInfo(Boolean) then EXIT;
    TRY
      Cur := ParentProp.GetValue(AInstance);
    EXCEPT
      EXIT;
    END;
    if not Cur.AsBoolean then EXIT;
    TRY
      ParentProp.SetValue(AInstance, FALSE);
    EXCEPT
      // Defensive: if a custom setter raises, swallow it — the user's actual
      // write may still succeed, and we don't want this opportunistic helper
      // to convert a successful set_property into an error.
    END;
  FINALLY
    Ctx.Free;
  END;
END;


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
  AlphaVal: TAlphaColor;
  ColorVal: TColor;
  EnumOrd: Integer;
  Code: Integer;
  Lower: String;
  DotPos: Integer;
  OuterName, InnerName: String;
  Inner: TObject;
  CurVal: TValue;
  CanRead: Boolean;
  TmpVal: TValue;
BEGIN
  Assert(GetCurrentThreadId = MainThreadID, 'TrySetGenericProperty: VCL touched off the main thread');
  Result := FALSE;
  AErrCode := ErrRttiPropertyMissing;
  AErrMsg := '';
  AFailedInstance := AInstance;
  AElided := FALSE;

  // Dotted propName: 'Outer.Inner'. Resolve the outer here, then recurse onto
  // the inner instance. We only support one level — a propName with 2+ dots
  // is rejected with unsupported_action (avoid surprising the AI by silently
  // doing arbitrarily-deep walks).
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
        // Outer name unknown — caller will attach availableProperties off AInstance,
        // so the AI sees the OUTER class's surface (which is correct: that's where
        // the typo is).
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
    // ParentFont/ParentColor/etc. live on the OUTER instance (AInstance), not
    // on the inner — flip them here, before we recurse into the inner where
    // they're invisible. Look up by OuterName ('Font' triggers ParentFont).
    TurnOffParentInheritFor(AInstance, OuterName);
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

    // Direct write to a Parent-governed property (Color, BiDiMode, ShowHint,
    // DoubleBuffered, CustomHint, Ctl3D). Font as a whole isn't writable here
    // (it's tkClass, dotted writes go through the recursive branch above) but
    // listing 'Font' in the pair table costs nothing. Flip BEFORE the
    // elision read so the resulting Parent<X>=FALSE state holds even on a
    // no-op resend — see header comment on TurnOffParentInheritFor.
    TurnOffParentInheritFor(AInstance, APropName);

    // Read the live value once, up front, so each branch can elide when the
    // coerced new value equals it. Some properties are writable but raise on
    // read (rare — defensive setters). On read failure CanRead stays FALSE and
    // the write goes through unconditionally (i.e. elision is a TRUE-positive
    // optimization; never a FALSE-positive that drops a needed write).
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
        // TColor (System.UITypes.TColor = type LongInt, VCL convention). Route
        // through TryParseColor so the AI can pass 'clRed', 'clBtnFace', '#FF0080',
        // '$00800080', or a decimal. Detected by type handle, not class name.
        if Prop.PropertyType.Handle = TypeInfo(TColor) then
        begin
          if not TryParseColor(AStrValue, ColorVal) then
          begin
            AErrCode := ErrUnsupportedAction;
            AErrMsg := APropName + ' expects a TColor value (e.g. "clRed", "clBtnFace", "#FF0080", or a numeric color); got "' + AStrValue + '"';
            EXIT;
          end;
          if CanRead and (TColor(CurVal.AsOrdinal) = ColorVal) then
          begin
            AElided := TRUE;
            EXIT(TRUE);
          end;
          Prop.SetValue(AInstance, TValue.From<TColor>(ColorVal));
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
          // Try identifier first (e.g. 'poDesigned'); fall back to ordinal.
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
        // Accept '[a,b]' (canonical form emitted by SetToString), 'a,b' (bare list),
        // '[]' (empty set), or a numeric ordinal. StringToSet wants the bracket
        // form, so wrap a bare list before passing. Identifiers are
        // case-insensitive — match Delphi's own behavior for enum identifiers.
        // NOTE: TValue.FromOrdinal raises EInvalidCast for tkSet typeinfo (see
        // System.Rtti.pas, FromOrdinal restricts to [tkInteger,tkChar,tkWChar,
        // tkEnumeration,tkInt64]). Use TValue.Make with a pointer to the ordinal
        // sized to the set's storage width.
        Lower := Trim(AStrValue);
        if (Lower <> '') and (Lower[1] <> '[') then
        begin
          // Plain ordinal? Use it directly without StringToSet.
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
          // Bare identifier list — wrap it for StringToSet.
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
        // Sets are stored as ordinal bitfields. Compare via the raw ordinal so
        // [fcRed,fcBlue] = [fcBlue,fcRed] elides correctly (StringToSet normalizes).
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
        // Exact-bits equality (no epsilon). For tkFloat properties typed as
        // Double or Extended a resend of the same string round-trips and elides;
        // for Single-typed properties decimals that aren't exactly representable
        // in Single (e.g. 0.1) will NOT elide on resend because the stored
        // Single, widened back to Extended for comparison, differs from the
        // parsed Double. That's harmless — the write goes through. An epsilon
        // would be worse: it would silently swallow small intentional nudges.
        // AsExtended is the canonical accessor for all tkFloat including
        // TDateTime; works regardless of underlying Single/Double/Extended.
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


// Set the published Checked property of a TCheckBox / TRadioButton / similar.
FUNCTION TrySetCheckedProperty(AComp: TComponent; AValue: Boolean; OUT AErrCode: Integer): Boolean;
VAR
  Ctx: TRttiContext;
  RT: TRttiType;
  Prop: TRttiProperty;
BEGIN
  Assert(GetCurrentThreadId = MainThreadID, 'TrySetCheckedProperty: VCL touched off the main thread');
  Result := FALSE;
  AErrCode := ErrRttiPropertyMissing;
  Ctx := TRttiContext.Create;
  TRY
    RT := Ctx.GetType(AComp.ClassType);
    if RT = NIL then EXIT;
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


// Leaf name for a path segment: real Name when present, else synthetic '@TButton#N'.
FUNCTION LeafNameFor(AComp: TComponent): String;
BEGIN
  Assert(GetCurrentThreadId = MainThreadID, 'LeafNameFor: VCL touched off the main thread');
  if AComp.Name = '' then
    Result := SyntheticIdFor(AComp)
  else
    Result := AComp.Name;
END;


// Build a JSON node for one component. Unnamed components are emitted with a
// synthetic name '@ClassName#Index' (also usable as a path leaf) plus a
// 'synthetic: true' flag so callers can distinguish. 'path' is the full dotted
// path the AI can paste back into click/get_text/set_text args.
FUNCTION BuildComponentNode(CONST AFormName, ANodePath: String; AComp: TComponent): TJSONObject;
VAR
  S: String;
  B: Boolean;
  NodeName: String;
  IsSynthetic: Boolean;
BEGIN
  Assert(GetCurrentThreadId = MainThreadID, 'BuildComponentNode: VCL touched off the main thread');
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


{ Command handlers — invoked on the main thread ------------------------ }

// Recurse a component tree, emitting one JSON node per component. AParentPath is the
// dotted path of AParent (the container). AVisited prevents cycles (defensive — a
// TComponent.FOwner chain should never cycle, but we walk arbitrary containers).
PROCEDURE WalkComponents(AFormName, AParentPath: String; AParent: TComponent;
                         AItems: TJSONArray; AVisited: TList);
VAR
  j: Integer;
  Child: TComponent;
  ChildPath: String;
BEGIN
  Assert(GetCurrentThreadId = MainThreadID, 'WalkComponents: VCL touched off the main thread');
  for j := 0 to AParent.ComponentCount - 1 do
  begin
    Child := AParent.Components[j];
    if AVisited.IndexOf(Child) >= 0 then Continue;
    AVisited.Add(Child);
    ChildPath := AParentPath + '.' + LeafNameFor(Child);
    AItems.AddElement(BuildComponentNode(AFormName, ChildPath, Child));
    // Recurse into containers (frames, panels with owned children, nested data modules).
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
  Form: TCustomForm;
BEGIN
  Assert(GetCurrentThreadId = MainThreadID, 'HandleListTree must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;
  Result.Ok := TRUE;

  Items := TJSONArray.Create;
  TRY
    // Each form gets its own Visited set so a component reachable from two forms
    // doesn't get truncated from the second tree. The cycle guard is per-form too —
    // the only legitimate "cycle" is within a single ownership graph.
    for i := 0 to Screen.FormCount - 1 do
    begin
      Form := Screen.Forms[i];
      Visited := TList.Create;
      TRY
        // Emit the form as its own node first. Its Caption read may AV on an
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
    Items := NIL;             // ownership moved to Wrap
    Result.ResultJson := Wrap;
  EXCEPT
    // Defensive: if any helper raised (e.g. an exotic published getter), free Items
    // on the way out. The worker's outer try/except still converts this to an error
    // response over the wire.
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
  Assert(GetCurrentThreadId = MainThreadID, 'HandleGetText must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;

  if AReq.Args = NIL then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'get_text requires args.path';
    EXIT;
  end;
  PathVal := AReq.Args.GetValue('path');
  if not (PathVal IS TJSONString) then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'get_text requires args.path (string)';
    EXIT;
  end;
  Path := TJSONString(PathVal).Value;

  Comp := FindComponentByPath(Path);
  if Comp = NIL then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrNotFound;
    Result.ErrorMessage := 'no component matches ' + Path;
    EXIT;
  end;

  if not TryGetTextProperty(Comp, Text) then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrRttiPropertyMissing;
    Result.ErrorMessage := Comp.ClassName + ' has no readable Text/Caption property';
    EXIT;
  end;

  Wrap := TJSONObject.Create;
  Wrap.AddPair('text', Text);
  Result.Ok := TRUE;
  Result.ResultJson := Wrap;
END;


// Click dispatch — see CLAUDE.md "Click dispatch" and Plans/01 OnClick section.
FUNCTION HandleClick(CONST AReq: TBridgeRequest): TBridgeResponse;
CONST
  MaxClickCount = 1000;   // sane cap; protects the main thread from being pinned by a runaway count.
VAR
  PathVal, CountVal: TJSONValue;
  Path: String;
  Comp: TComponent;
  Enabled: Boolean;
  Wrap: TJSONObject;
  DispatchedVia, StoppedReason: String;
  Ctx: TRttiContext;
  RT: TRttiType;
  OnClickProp: TRttiProperty;
  Notify: TNotifyEvent;
  HasNotify: Boolean;
  RawValue: TValue;
  RequestedCount, ClicksDone: Integer;

  // Resolves the dispatch path once. Returns FALSE if the control supports no known click path.
  // On success sets DispatchedVia ('click' or 'onclick') and, for the 'onclick' path, Notify.
  FUNCTION ResolveDispatchPath: Boolean;
  BEGIN
    HasNotify := FALSE;
    // Preference order — see CLAUDE.md and Vcl.UIACtrlProvider.pas:299:
    //   1. TButton.Click (public, fires WM_COMMAND semantics)
    //   2. TWinControlClass(Ctrl).Click — protected-Click trick
    //   3. OnClick(Self) via RTTI
    if Comp IS TButton then
    begin
      DispatchedVia := 'click';
      EXIT(TRUE);
    end;
    if Comp IS TWinControl then
    begin
      DispatchedVia := 'click';
      EXIT(TRUE);
    end;
    // Resolve OnClick once via RTTI.
    // TValue.AsType<TNotifyEvent> stumbles in some Delphi versions because of
    // generic type inference (TNotifyEvent is a specific method-pointer alias,
    // RTTI gives back a generic "procedure of object"). Use TMethod re-assembly:
    // read the raw method, then build a TMethod and reinterpret as TNotifyEvent.
    Ctx := TRttiContext.Create;
    TRY
      RT := Ctx.GetType(Comp.ClassType);
      if RT = NIL then EXIT(FALSE);
      OnClickProp := RT.GetProperty('OnClick');
      if (OnClickProp = NIL) or not OnClickProp.IsReadable then EXIT(FALSE);
      RawValue := OnClickProp.GetValue(Comp);
      if RawValue.IsEmpty or (RawValue.Kind <> tkMethod) then EXIT(FALSE);
      // TValue wraps a method-pointer as a TMethod record. Both layouts are {Code, Data: Pointer}.
      TMethod(Notify) := PMethod(RawValue.GetReferenceToRawData)^;
      if not Assigned(Notify) then EXIT(FALSE);
      DispatchedVia := 'onclick';
      HasNotify := TRUE;
      Result := TRUE;
    FINALLY
      Ctx.Free;
    END;
  END;

  // Dispatch one click using the resolved path. Assumes ResolveDispatchPath returned TRUE.
  PROCEDURE DispatchOneClick;
  BEGIN
    if Comp IS TButton then
      TButton(Comp).Click
    else if Comp IS TWinControl then
      TWinControlClass(Comp).Click
    else if HasNotify then
      Notify(Comp);
  END;

BEGIN
  Assert(GetCurrentThreadId = MainThreadID, 'HandleClick must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;
  DispatchedVia := '';
  StoppedReason := '';
  ClicksDone := 0;

  if AReq.Args = NIL then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'click requires args.path';
    EXIT;
  end;
  PathVal := AReq.Args.GetValue('path');
  if not (PathVal IS TJSONString) then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'click requires args.path (string)';
    EXIT;
  end;
  Path := TJSONString(PathVal).Value;

  // Optional count: missing -> 1. Must be 1..MaxClickCount. Anything outside is a validation error
  // (an explicit "negative click count" is more likely a caller bug than a benign zero).
  RequestedCount := 1;
  CountVal := AReq.Args.GetValue('count');
  if CountVal IS TJSONNumber then
  begin
    // TJSONNumber.AsInt is StrToInt(Value) (System.JSON.pas:2865) — it RAISES EConvertError on a
    // fractional (1.5) or out-of-Int32 count, which would surface as ErrInternalError. TryStrToInt
    // on the raw number text keeps a malformed count in the ErrInvalidRequest lane where it belongs.
    if not TryStrToInt(TJSONNumber(CountVal).Value, RequestedCount) then
    begin
      Result.Ok := FALSE;
      Result.ErrorCode := ErrInvalidRequest;
      Result.ErrorMessage := 'click args.count must be an integer 1..' + IntToStr(MaxClickCount) +
                             ' (got ' + TJSONNumber(CountVal).Value + ')';
      EXIT;
    end;
    if RequestedCount < 1 then
    begin
      Result.Ok := FALSE;
      Result.ErrorCode := ErrInvalidRequest;
      Result.ErrorMessage := 'click args.count must be >= 1 (got ' + IntToStr(RequestedCount) + ')';
      EXIT;
    end;
    if RequestedCount > MaxClickCount then
    begin
      Result.Ok := FALSE;
      Result.ErrorCode := ErrInvalidRequest;
      Result.ErrorMessage := 'click args.count ' + IntToStr(RequestedCount) +
                             ' exceeds cap ' + IntToStr(MaxClickCount);
      EXIT;
    end;
  end;

  Comp := FindComponentByPath(Path);
  if Comp = NIL then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrNotFound;
    Result.ErrorMessage := 'no component matches ' + Path;
    EXIT;
  end;

  if TryGetEnabled(Comp, Enabled) and not Enabled then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrControlDisabled;
    Result.ErrorMessage := Comp.Name + ' is disabled';
    EXIT;
  end;

  if not ResolveDispatchPath then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrUnsupportedAction;
    Result.ErrorMessage := Comp.ClassName + ' has no Click method and no OnClick handler';
    EXIT;
  end;

  // Re-check Enabled each iteration: a previous OnClick may have disabled the control.
  // We honor the single-click promise (don't act on disabled) on every iteration, then
  // return a partial success with stoppedReason='disabled' so the caller can tell.
  // Wrap the dispatch in try/except so an OnClick that frees the control / form,
  // raises, or otherwise disrupts the loop stops cleanly instead of AV'ing on the
  // next iteration's TryGetEnabled(stale Comp).
  while ClicksDone < RequestedCount do
  begin
    if TryGetEnabled(Comp, Enabled) and not Enabled then
    begin
      StoppedReason := 'disabled';
      Break;
    end;
    TRY
      DispatchOneClick;
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
  Wrap.AddPair('dispatchedVia', DispatchedVia);
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
// Behaviour kept byte-identical with the FMX twin.
FUNCTION HandleExecuteAction(CONST AReq: TBridgeRequest): TBridgeResponse;
VAR
  PathVal: TJSONValue;
  Path: String;
  Comp: TComponent;
  Enabled: Boolean;
  Executed: Boolean;
  Wrap: TJSONObject;
BEGIN
  Assert(GetCurrentThreadId = MainThreadID, 'HandleExecuteAction must run on the main thread');
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
  Assert(GetCurrentThreadId = MainThreadID, 'HandleSetText must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;

  if AReq.Args = NIL then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'set_text requires args.path and args.text';
    EXIT;
  end;
  PathVal := AReq.Args.GetValue('path');
  TextVal := AReq.Args.GetValue('text');
  if not (PathVal IS TJSONString) then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'set_text requires args.path (string)';
    EXIT;
  end;
  if not (TextVal IS TJSONString) then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'set_text requires args.text (string)';
    EXIT;
  end;
  Path := TJSONString(PathVal).Value;
  Text := TJSONString(TextVal).Value;

  Comp := FindComponentByPath(Path);
  if Comp = NIL then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrNotFound;
    Result.ErrorMessage := 'no component matches ' + Path;
    EXIT;
  end;
  if TryGetEnabled(Comp, Enabled) and not Enabled then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrControlDisabled;
    Result.ErrorMessage := Comp.Name + ' is disabled';
    EXIT;
  end;

  if not TrySetTextProperty(Comp, Text, ErrCode) then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrCode;
    if ErrCode = ErrUnsupportedAction then
      Result.ErrorMessage := Comp.ClassName + '.Text/Caption is read-only'
    else
      Result.ErrorMessage := Comp.ClassName + ' has no writable Text/Caption property';
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
  Assert(GetCurrentThreadId = MainThreadID, 'HandleSetChecked must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;

  if AReq.Args = NIL then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'set_checked requires args.path and args.checked';
    EXIT;
  end;
  PathVal := AReq.Args.GetValue('path');
  CheckedVal := AReq.Args.GetValue('checked');
  if not (PathVal IS TJSONString) then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'set_checked requires args.path (string)';
    EXIT;
  end;
  if not (CheckedVal IS TJSONBool) then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'set_checked requires args.checked (boolean)';
    EXIT;
  end;
  Path := TJSONString(PathVal).Value;
  Checked := TJSONBool(CheckedVal).AsBoolean;

  Comp := FindComponentByPath(Path);
  if Comp = NIL then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrNotFound;
    Result.ErrorMessage := 'no component matches ' + Path;
    EXIT;
  end;
  if TryGetEnabled(Comp, Enabled) and not Enabled then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrControlDisabled;
    Result.ErrorMessage := Comp.Name + ' is disabled';
    EXIT;
  end;

  if not TrySetCheckedProperty(Comp, Checked, ErrCode) then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrCode;
    if ErrCode = ErrUnsupportedAction then
      Result.ErrorMessage := Comp.ClassName + '.Checked is read-only'
    else
      Result.ErrorMessage := Comp.ClassName + ' has no Checked property';
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
  Assert(GetCurrentThreadId = MainThreadID, 'HandleSetProperty must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;

  if AReq.Args = NIL then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'set_property requires args.path, args.propName, args.value';
    EXIT;
  end;
  PathVal  := AReq.Args.GetValue('path');
  NameVal  := AReq.Args.GetValue('propName');
  ValueVal := AReq.Args.GetValue('value');
  if not (PathVal IS TJSONString) then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'set_property requires args.path (string)';
    EXIT;
  end;
  if not (NameVal IS TJSONString) then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'set_property requires args.propName (string)';
    EXIT;
  end;
  if not (ValueVal IS TJSONString) then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'set_property requires args.value (string — bridge coerces to property type)';
    EXIT;
  end;
  Path     := TJSONString(PathVal).Value;
  PropName := TJSONString(NameVal).Value;
  StrValue := TJSONString(ValueVal).Value;

  Comp := FindComponentByPath(Path);
  if Comp = NIL then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrNotFound;
    Result.ErrorMessage := 'no component matches ' + Path;
    EXIT;
  end;
  if TryGetEnabled(Comp, Enabled) and not Enabled then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrControlDisabled;
    Result.ErrorMessage := Comp.Name + ' is disabled';
    EXIT;
  end;

  if not TrySetGenericProperty(Comp, PropName, StrValue, ErrCode, ErrMsg, FailedInstance, Elided) then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrCode;
    Result.ErrorMessage := ErrMsg;
    // R2 self-correction: only enumerate available props for the "missing" path.
    // For read-only or type-mismatch failures the prop name was right, so the list
    // would just be noise. Attached to error.data per JSON-RPC convention.
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
  // The AI can use this to know whether a follow-up validation read is still
  // needed, or to detect "I keep sending the same value, must be a logic bug".
  Wrap.AddPair('elided', TJSONBool.Create(Elided));
  Result.Ok := TRUE;
  Result.ResultJson := Wrap;
END;


// Find a form by name (case-insensitive). Returns NIL if no match.
// Empty name = the main form (Application.MainForm) if set, else Screen.Forms[0].
FUNCTION FindFormByName(CONST AFormName: String): TCustomForm;
VAR
  i: Integer;
BEGIN
  Assert(GetCurrentThreadId = MainThreadID, 'FindFormByName: VCL touched off the main thread');
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
  Form: TCustomForm;
  Bmp: TBitmap;
  Png: TPngImage;
  Stream: TMemoryStream;
  Base64: String;
  Wrap: TJSONObject;
BEGIN
  Assert(GetCurrentThreadId = MainThreadID, 'HandleScreenshot must run on the main thread');
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
  if Form = NIL then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrNotFound;
    if FormName = '' then
      Result.ErrorMessage := 'no main form available'
    else
      Result.ErrorMessage := 'no form named ' + FormName;
    EXIT;
  end;

  Bmp := Form.GetFormImage;
  TRY
    Png := TPngImage.Create;
    TRY
      Png.Assign(Bmp);
      Stream := TMemoryStream.Create;
      TRY
        Png.SaveToStream(Stream);
        Stream.Position := 0;
        Base64 := TNetEncoding.Base64.EncodeBytesToString(Stream.Memory, Stream.Size);
      FINALLY
        FreeAndNil(Stream);
      END;
    FINALLY
      FreeAndNil(Png);
    END;
  FINALLY
    FreeAndNil(Bmp);
  END;

  Wrap := TJSONObject.Create;
  Wrap.AddPair('form', Form.Name);
  Wrap.AddPair('width', TJSONNumber.Create(Form.ClientWidth));
  Wrap.AddPair('height', TJSONNumber.Create(Form.ClientHeight));
  Wrap.AddPair('encoding', 'base64');
  Wrap.AddPair('format', 'png');
  Wrap.AddPair('image', Base64);
  Result.Ok := TRUE;
  Result.ResultJson := Wrap;
END;


// Build a JSON array of READABLE property names available on AInstance (parallel
// to ListWritableProperties but with IsReadable filter). Used by HandleReadProperty
// when the requested PropName is unknown so the AI gets a recovery hint covering
// the read surface — which is a strict superset of the write surface for any
// realistic control. Each entry carries kind + currentValue (when the getter
// succeeds), so one round-trip surfaces the entire readable state.
FUNCTION ListReadableProperties(AInstance: TObject): TJSONArray;
VAR
  Ctx: TRttiContext;
  RT: TRttiType;
  Prop: TRttiProperty;
  Node: TJSONObject;
  KindName: String;
  CurStr: String;
BEGIN
  Assert(GetCurrentThreadId = MainThreadID, 'ListReadableProperties: VCL touched off the main thread');
  Result := TJSONArray.Create;
  Ctx := TRttiContext.Create;
  TRY
    RT := Ctx.GetType(AInstance.ClassType);
    if RT = NIL then EXIT;
    for Prop in RT.GetProperties do
    begin
      if not Prop.IsReadable then Continue;
      // Same kind filter as ListWritableProperties — surfacing methods / variants /
      // interfaces sets the AI up to fail again on the retry.
      case Prop.PropertyType.TypeKind of
        tkString, tkLString, tkWString, tkUString: KindName := 'string';
        tkInteger:
          if Prop.PropertyType.Handle = TypeInfo(TAlphaColor) then
            KindName := 'alphacolor'
          else if Prop.PropertyType.Handle = TypeInfo(TColor) then
            KindName := 'color'
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


// Resolve a (possibly dotted, max one level) property name on AInstance and read
// it. Returns FALSE with structured AErrCode/AErrMsg on failure; AFailedInstance
// is set to the object the lookup was performed against on
// ErrRttiPropertyMissing so the caller can attach a correct availableProperties
// payload (matters for dotted names where the inner is the typo). Mirrors the
// dotted-resolve branch of TrySetGenericProperty.
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
  Assert(GetCurrentThreadId = MainThreadID, 'TryReadGenericProperty: VCL touched off the main thread');
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
    // Compute the kind tag (parallel to ListReadableProperties' switch so the
    // AI sees the same vocabulary in availableProperties[].kind and in the
    // successful read's 'kind' field).
    case Prop.PropertyType.TypeKind of
      tkString, tkLString, tkWString, tkUString: AKind := 'string';
      tkInteger:
        if Prop.PropertyType.Handle = TypeInfo(TAlphaColor) then
          AKind := 'alphacolor'
        else if Prop.PropertyType.Handle = TypeInfo(TColor) then
          AKind := 'color'
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
  Assert(GetCurrentThreadId = MainThreadID, 'HandleReadProperty must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;

  if AReq.Args = NIL then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'read_property requires args.path and args.propName';
    EXIT;
  end;
  PathVal := AReq.Args.GetValue('path');
  NameVal := AReq.Args.GetValue('propName');
  if not (PathVal IS TJSONString) then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'read_property requires args.path (string)';
    EXIT;
  end;
  if not (NameVal IS TJSONString) then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'read_property requires args.propName (string)';
    EXIT;
  end;
  Path := TJSONString(PathVal).Value;
  PropName := TJSONString(NameVal).Value;

  Comp := FindComponentByPath(Path);
  if Comp = NIL then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrNotFound;
    Result.ErrorMessage := 'no component matches ' + Path;
    EXIT;
  end;
  // No Enabled check — reading a disabled control is exactly the scenario
  // a debug-channel user needs (e.g. "why is btnSave disabled? what's its Tag?").

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


// Build the exclude list for native-dialog enumeration: every VCL form window plus the
// hidden Application window. These are OUR windows — never OS dialogs — so excluding them
// keeps the enumeration to genuine native dialogs. HandleAllocated guards against forcing
// a handle on a form that isn't realized (an unrealized form is off-screen anyway).
FUNCTION BuildVclDialogExclude: TArray<NativeUInt>;
VAR
  i, n: Integer;
BEGIN
  SetLength(Result, Screen.FormCount + 1);
  n := 0;
  for i := 0 to Screen.FormCount - 1 do
    if Screen.Forms[i].HandleAllocated then
    begin
      Result[n] := NativeUInt(Screen.Forms[i].Handle);
      Inc(n);
    end;
  Result[n] := NativeUInt(Application.Handle);
  Inc(n);
  SetLength(Result, n);
END;


// dismiss_dialog — reach native Win32 dialogs (MessageBox / Task Dialog / common dialogs)
// that the component-tree tools cannot see. With no 'button' arg it just lists the dialogs
// currently up (discovery); with 'button' it dispatches that button to dismiss one.
FUNCTION HandleDismissDialog(CONST AReq: TBridgeRequest): TBridgeResponse;
VAR
  ButtonVal, HwndVal: TJSONValue;
  Selector: String;
  HasButton, Clicked: Boolean;
  TargetDlg, ResolvedDlg: NativeUInt;
  Exclude: TArray<NativeUInt>;
  Wrap: TJSONObject;
  ClickedId: Integer;
  ClickedCap, Reason: String;
BEGIN
  Assert(GetCurrentThreadId = MainThreadID, 'HandleDismissDialog must run on the main thread');
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

  Exclude := BuildVclDialogExclude;
  Wrap := TJSONObject.Create;
  TRY
    Wrap.AddPair('dialogs', EnumerateNativeDialogs(Exclude));   // pre-click snapshot
    Wrap.AddPair('supported', TJSONBool.Create(NativeDialogsSupported));
    Wrap.AddPair('platform', 'windows');
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
    Wrap := NIL;   // ownership moved to Result
  FINALLY
    if Wrap <> NIL then FreeAndNil(Wrap);
  END;
END;


// set_keep_awake — VCL/Windows target: always a no-op. The screen-off app freeze
// that motivates keep-awake is Android power management; a Windows app is never
// frozen by the OS while an automation client drives it. Accepted (not 'unknown
// cmd') so the shared MCP tool behaves uniformly across VCL and FMX targets.
FUNCTION HandleSetKeepAwake(CONST AReq: TBridgeRequest): TBridgeResponse;
VAR
  EnabledVal: TJSONValue;
  Enable: Boolean;
  Wrap: TJSONObject;
BEGIN
  Assert(GetCurrentThreadId = MainThreadID, 'HandleSetKeepAwake must run on the main thread');
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
  Wrap := TJSONObject.Create;
  Wrap.AddPair('enabled', TJSONBool.Create(Enable));
  Wrap.AddPair('platform', 'windows');
  Wrap.AddPair('applied', TJSONBool.Create(FALSE));
  Result.Ok := TRUE;
  Result.ResultJson := Wrap;
END;


FUNCTION Dispatch(CONST AReq: TBridgeRequest): TBridgeResponse;
BEGIN
  Assert(GetCurrentThreadId = MainThreadID, 'Dispatch must run on the main thread');
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
  // Lazy lock creation — avoids using initialization (non-deterministic order).
  // Race only possible during simultaneous first-time entry from multiple threads,
  // which doesn't happen here (StartBridge is called from the main thread at startup).
  if GLock = NIL then
    GLock := TCriticalSection.Create;
END;


PROCEDURE StartBridgeInternal(CONST APipeName: String);
VAR
  ExeName: String;
BEGIN
  EnsureLock;
  GLock.Enter;
  TRY
    if GWorker <> NIL then EXIT;
    ExeName := ExtractFileName(ParamStr(0));
    BridgeLogInfo('bridge', 'StartBridge exe=' + ExeName + ' pipe=' + APipeName);
    BridgeLogInfo('license', CommercialLicenseHint);
    GWorker := TBridgeWorker.Create(TPipeTransport.Create(APipeName), ExeName, Dispatch);
  FINALLY
    GLock.Leave;
  END;
END;


PROCEDURE StartBridge;
BEGIN
  StartBridgeInternal(ComputePipeName);
END;


PROCEDURE StartBridgeOnPipe(CONST APipeName: String);
BEGIN
  StartBridgeInternal(APipeName);
END;


PROCEDURE StopBridge;
BEGIN
  if GLock = NIL then EXIT;   // never started
  GLock.Enter;
  TRY
    if GWorker = NIL then EXIT;
    BridgeLogInfo('bridge', 'StopBridge');
    GWorker.Terminate;
    // The worker is blocked in the transport's AcceptConnection; its destructor
    // calls the transport's WakeAndStop to unblock it. Free triggers the destructor.
    FreeAndNil(GWorker);
  FINALLY
    GLock.Leave;
  END;
  // GLock itself is freed in the unit's FINALIZATION — keeps StopBridge cheap and race-free.
END;


FUNCTION IsBridgeRunning: Boolean;
BEGIN
  Result := GWorker <> NIL;
END;


{$ELSE}   // AUTOPILOT not defined — public surface compiles, bodies are no-ops.

PROCEDURE StartBridge;
BEGIN
END;

PROCEDURE StartBridgeOnPipe(CONST APipeName: String);
BEGIN
END;

PROCEDURE StopBridge;
BEGIN
END;

FUNCTION IsBridgeRunning: Boolean;
BEGIN
  Result := FALSE;
END;

{$ENDIF}


// FINALIZATION is at the bottom (footgun #2 — never inside an IFDEF), the body is guarded instead.
// We free the lazy-created lock here so a clean test run leaks zero objects, AND fall back to
// StopBridge if the host app forgot to call it (Plans/04 R9). The discovery file would otherwise
// linger; the MCP server's stale-pruner cleans it up, but graceful is better than racy.
INITIALIZATION

FINALIZATION
{$IFDEF AUTOPILOT}
  if GWorker <> NIL then
    StopBridge;
  if GLock <> NIL then
    FreeAndNil(GLock);
{$ENDIF}


END.
