unit Autopilot.Bridge.Fmx;

{=============================================================================================================
   2026.10.12
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - Public bridge interface for FMX target projects (cross-platform: Windows pipe + POSIX AF_UNIX socket)
   - StartBridge / StopBridge / IsBridgeRunning; real bodies only when AUTOPILOT is defined
   - FMX dispatcher: same 13 tools as the VCL twin; click dispatches via OnClick RTTI, or via the protected TControl.Click when the control is bound to an action
   - screenshot: a whole form, or one control cropped out of it (path), optionally scaled down (maxWidth)
   - Paths resolve through the Owner tree first, then through the visual parent tree (re-parented controls)
   - TAlphaColor coercion only (no TColor - FMX uses TAlphaColor throughout); keep-screen-on on Android
   - How Autopilot works and how to use it with an AI: the book "Delphi in All Its Glory" Part 5, "AI-Assisted Development for Delphi", chapter "We Need a Hero - Enter Autopilot for Delphi".
     https://gabrielmoraru.com/the-delphi-in-all-its-glory-book-5-ai-assisted-development-for-delphi/
=============================================================================================================}

interface

uses
  System.Classes;

procedure StartBridge;
procedure StopBridge;
function  IsBridgeRunning: Boolean;
procedure StartBridgeOnPipe(const APipeName: String);


implementation

{$IFDEF AUTOPILOT}
uses
  System.SysUtils, System.Types, System.SyncObjs, System.JSON, System.Rtti, System.TypInfo,
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
uses
  System.SysUtils;
{$ENDIF}


{$IFDEF AUTOPILOT}

// Licence reminder in the Messages pane, AUTOPILOT builds only. See the twin comment in Autopilot.Bridge.Vcl.pas for why this is a HINT and who sees it.
{$MESSAGE HINT 'Autopilot for Delphi: every developer needs a seat - free for personal use after registering, paid for commercial use or any use by or for an organization. Already have a seat? Thank you - nothing to do. https://www.GabrielMoraru.com/autopilot'}

var
  GWorker: TBridgeWorker = NIL;
  GLock  : TCriticalSection = NIL;


{ Component-tree walk and RTTI helpers ---------------------------------- }

type
  TFmxControlAccess = class(TControl);   // breaks protected scope for .Click and .ActionLink

  // Tells HandleClick that an event handler freed the control it clicks. The VCL twin explains how.
  TFreeWatch = class(TComponent)
  private
    FWatched: TComponent;
  protected
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  public
    Freed: Boolean;
    constructor Create(AWatched: TComponent); reintroduce;
  end;


constructor TFreeWatch.Create(AWatched: TComponent);
begin
  inherited Create(NIL);
  FWatched := AWatched;
  AWatched.FreeNotification(Self);
end;


procedure TFreeWatch.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited;   // unlinks AComponent; RemoveFreeNotifications loops until this unlink happens
  if (Operation = opRemove) and (AComponent = FWatched) then
    Freed := TRUE;
end;


{ Synthetic ID for an unnamed component: '@TButton#5', where 5 is the component's CURRENT position in its owner's Components list.
  The index shifts down by 1 each time an earlier sibling is freed (RemoveComponent compacts the list), so an ID captured from list_tree is reliable only while no earlier sibling has been destroyed since.
  Same scheme as the VCL bridge. }
function SyntheticIdFor(AComp: TComponent): String;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'SyntheticIdFor: FMX touched off the main thread');
  if AComp.Name <> '' then exit('');
  Result := '@' + AComp.ClassName + '#' + IntToStr(AComp.ComponentIndex);
end;


function MatchesLeaf(AOwner: TComponent; AComp: TComponent; const ALeaf: String): Boolean;
var
  HashPos: Integer;
  ClassPart: String;
  IdxStr: String;
  Idx, ParseCode: Integer;
begin
  Result := FALSE;
  if ALeaf = '' then exit;
  if ALeaf[1] = '@' then
  begin
    HashPos := Pos('#', ALeaf);
    if HashPos < 3 then exit;
    ClassPart := Copy(ALeaf, 2, HashPos - 2);
    IdxStr := Copy(ALeaf, HashPos + 1, MaxInt);
    Val(IdxStr, Idx, ParseCode);
    if ParseCode <> 0 then exit;
    if (Idx < 0) or (Idx >= AOwner.ComponentCount) then exit;
    if AOwner.Components[Idx] <> AComp then exit;
    Result := SameText(AComp.ClassName, ClassPart);
  end
  else
    Result := SameText(AComp.Name, ALeaf);
end;


function FindChildOf(AParent: TComponent; const ALeaf: String): TComponent;
var
  j: Integer;
begin
  Result := NIL;
  for j := 0 to AParent.ComponentCount - 1 do
    if MatchesLeaf(AParent, AParent.Components[j], ALeaf) then
      exit(AParent.Components[j]);
end;


// Prefers shallow matches: scans ALL direct children of AParent first, then recurses (the VCL twin explains why).
function FindDescendantOf(AParent: TComponent; const ALeaf: String; AVisited: TList): TComponent;
var
  j: Integer;
  Child: TComponent;
begin
  Result := NIL;
  for j := 0 to AParent.ComponentCount - 1 do
  begin
    Child := AParent.Components[j];
    if AVisited.IndexOf(Child) >= 0 then Continue;
    AVisited.Add(Child);
    if MatchesLeaf(AParent, Child, ALeaf) then
      exit(Child);
  end;
  for j := 0 to AParent.ComponentCount - 1 do
  begin
    Child := AParent.Components[j];
    if Child.ComponentCount > 0 then
    begin
      Result := FindDescendantOf(Child, ALeaf, AVisited);
      if Result <> NIL then exit;
    end;
  end;
end;


{ Visual-parent fallback ------------------------------------------------- }
{ Same rule as the VCL twin: the owner walk runs first; only when it finds nothing, the path is tried through the visual tree, here TFmxObject.Children.
  Two FMX specifics:
  - A style tree is skipped: StyleObject.Clone(nil) gives it no Owner, and ApplyStyleLookup sets Stored=FALSE.
  - An internal content object (Stored=FALSE but owned, e.g. TTabItemContent, TScrollContent) is looked through: FMX puts the controls placed on a TTabItem or a TScrollBox inside it. }

const
  MaxVisualDepth = 256;   // stops the recursion on a corrupt Parent chain; real forms nest far less

function IsStyleTree(AObj: TFmxObject): Boolean;
begin
  Result := not AObj.Stored and (AObj.Owner = NIL);
end;


{ Leaf match for an object met in the visual tree.
  A synthetic '@Class#N' id is owner-relative, so it is checked against the object's own Owner. }
function MatchesVisualLeaf(AComp: TComponent; const ALeaf: String): Boolean;
begin
  if (ALeaf <> '') and (ALeaf[1] = '@') then
    Result := (AComp.Owner <> NIL) and MatchesLeaf(AComp.Owner, AComp, ALeaf)
  else
    Result := (ALeaf <> '') and SameText(AComp.Name, ALeaf);
end;


procedure AddUnique(AList: TList; AComp: TComponent);
begin
  if AList.IndexOf(AComp) < 0 then
    AList.Add(AComp);
end;


// Adds to AMatches every object in AParent's visual subtree (Children, recursively) that matches ALeaf.
procedure CollectVisualDescendants(AParent: TComponent; const ALeaf: String; AMatches: TList; ADepth: Integer);
var
  j: Integer;
  Child: TFmxObject;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'CollectVisualDescendants: FMX touched off the main thread');
  if not (AParent is TFmxObject) or (ADepth > MaxVisualDepth) then exit;
  for j := 0 to TFmxObject(AParent).ChildrenCount - 1 do
  begin
    Child := TFmxObject(AParent).Children[j];
    if IsStyleTree(Child) then Continue;
    if MatchesVisualLeaf(Child, ALeaf) then
      AddUnique(AMatches, Child);
    CollectVisualDescendants(Child, ALeaf, AMatches, ADepth + 1);
  end;
end;


// Adds to AStep the direct visual children of AParent that match ALeaf, looking through internal content objects.
procedure CollectVisualChildren(AParent: TComponent; const ALeaf: String; AStep: TList; ADepth: Integer);
var
  j: Integer;
  Child: TFmxObject;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'CollectVisualChildren: FMX touched off the main thread');
  if not (AParent is TFmxObject) or (ADepth > MaxVisualDepth) then exit;
  for j := 0 to TFmxObject(AParent).ChildrenCount - 1 do
  begin
    Child := TFmxObject(AParent).Children[j];
    if IsStyleTree(Child) then Continue;
    if MatchesVisualLeaf(Child, ALeaf) then
      AddUnique(AStep, Child);
    if not Child.Stored then
      CollectVisualChildren(Child, ALeaf, AStep, ADepth + 1);
  end;
end;


{ Anchored walk in which a child of ACur is a component ACur owns OR an object placed directly on it.
  Explores every branch, so AMatches ends up holding every component the whole path AParts[AIndex..] leads to. }
procedure CollectAnchoredMatches(ACur: TComponent; const AParts: TArray<String>; AIndex: Integer; AMatches: TList);
var
  Step: TList;
  Owned: TComponent;
  j: Integer;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'CollectAnchoredMatches: FMX touched off the main thread');
  if AIndex > High(AParts) then
  begin
    AddUnique(AMatches, ACur);
    exit;
  end;

  Step := TList.Create;
  try
    Owned := FindChildOf(ACur, AParts[AIndex]);
    if Owned <> NIL then
      Step.Add(Owned);
    CollectVisualChildren(ACur, AParts[AIndex], Step, 0);
    for j := 0 to Step.Count - 1 do
      CollectAnchoredMatches(TComponent(Step[j]), AParts, AIndex + 1, AMatches);
  finally
    FreeAndNil(Step);
  end;
end;


// The VCL twin documents the path format (including the 1-part "Form alone" path that round-trips with the form node emitted by list_tree) and the visual-parent fallback.
function FindComponentByPath(const APath: String; AMatches: TList): TComponent;
var
  i, k: Integer;
  Form: TCommonCustomForm;
  Parts: TArray<String>;
  FormName: String;
  Cur: TComponent;
  Visited: TList;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'FindComponentByPath: FMX touched off the main thread');
  Assert(AMatches <> NIL, 'FindComponentByPath: AMatches is NIL');
  Result := NIL;
  if APath = '' then exit;
  Parts := APath.Split(['.']);
  if Length(Parts) < 1 then exit;
  FormName := Parts[0];
  for i := 0 to Screen.FormCount - 1 do
  begin
    Form := Screen.Forms[i];
    if (FormName <> '*') and not SameText(Form.Name, FormName) then Continue;
    if Length(Parts) = 1 then
      exit(TComponent(Form))
    else if Length(Parts) = 2 then
    begin
      Visited := TList.Create;
      try
        Result := FindDescendantOf(Form, Parts[1], Visited);
      finally
        FreeAndNil(Visited);
      end;
      if Result <> NIL then exit;
    end
    else
    begin
      Cur := Form;
      for k := 1 to High(Parts) do
      begin
        Cur := FindChildOf(Cur, Parts[k]);
        if Cur = NIL then Break;
      end;
      if Cur <> NIL then exit(Cur);
    end;
  end;

  { # Visual-parent fallback }
  if Length(Parts) < 2 then exit;
  for i := 0 to Screen.FormCount - 1 do
  begin
    Form := Screen.Forms[i];
    if (FormName <> '*') and not SameText(Form.Name, FormName) then Continue;
    if Length(Parts) = 2
    then CollectVisualDescendants(Form, Parts[1], AMatches, 0)
    else CollectAnchoredMatches(Form, Parts, 1, AMatches);
  end;
  if AMatches.Count = 1 then
    Result := TComponent(AMatches[0]);
end;


// Mirror of the VCL twin's IsReadableBooleanProp / IsReadableStringProp: list_tree, get_text, set_text and set_checked check the property type BEFORE the read or write, so they raise no exception that a debugger would halt the whole app on (GitHub issue 2; the VCL twin has the full note).
function IsReadableBooleanProp(AProp: TRttiProperty): Boolean;
begin
  Result := (AProp <> NIL) and AProp.IsReadable and (AProp.PropertyType <> NIL)
        and IsBoolType(AProp.PropertyType.Handle);
end;


function IsReadableStringProp(AProp: TRttiProperty): Boolean;
begin
  Result := (AProp <> NIL) and AProp.IsReadable and (AProp.PropertyType <> NIL)
        and (AProp.PropertyType.TypeKind in [tkString, tkLString, tkWString, tkUString, tkChar, tkWChar]);
end;


// Mirror of the VCL twin's TryConvertForWrite: TRUE when TRttiProperty.SetValue accepts AValue for AProp (SetValue converts with TValue.Cast, which raises EInvalidCast exactly where TValue.TryCast answers FALSE).
function TryConvertForWrite(AProp: TRttiProperty; const AValue: TValue; OUT AConverted: TValue): Boolean;
begin
  Result := (AProp <> NIL) and (AProp.PropertyType <> NIL) and AValue.TryCast(AProp.PropertyType.Handle, AConverted);
end;


function TryGetTextProperty(AComp: TComponent; OUT AValue: String): Boolean;
var
  Ctx: TRttiContext;
  RT: TRttiType;
  Prop: TRttiProperty;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'TryGetTextProperty: FMX touched off the main thread');
  Result := FALSE;
  AValue := '';
  Ctx := TRttiContext.Create;
  try
    RT := Ctx.GetType(AComp.ClassType);
    if RT = NIL then exit;
    { As in the VCL bridge: Text first, then Caption. TCommonCustomForm has Caption but no Text, so get_text("MyFmxForm") needs the fallback.
      A Text or Caption that is not a string counts as missing. }
    Prop := RT.GetProperty('Text');
    if not IsReadableStringProp(Prop) then
      Prop := RT.GetProperty('Caption');
    if not IsReadableStringProp(Prop) then exit;
    { Same guard as the VCL bridge: some FMX property getters raise on partially-initialized forms or controls.
      The exception is swallowed and reported as "no text". }
    try
      AValue := Prop.GetValue(AComp).AsString;
      Result := TRUE;
    except
      Result := FALSE;
      AValue := '';
    end;
  finally
    Ctx.Free;
  end;
end;


function TryGetEnabled(AComp: TComponent; OUT AEnabled: Boolean): Boolean;
var
  Ctx: TRttiContext;
  RT: TRttiType;
  Prop: TRttiProperty;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'TryGetEnabled: FMX touched off the main thread');
  Result := FALSE;
  AEnabled := TRUE;
  Ctx := TRttiContext.Create;
  try
    RT := Ctx.GetType(AComp.ClassType);
    if RT = NIL then exit;
    Prop := RT.GetProperty('Enabled');
    if not IsReadableBooleanProp(Prop) then exit;   // a non-Boolean Enabled is reported as unknown
    // Same guard as the VCL bridge: a misbehaving FMX getter must not propagate out and leak the in-flight TJSONArray/TJSONObject in HandleListTree.
    try
      AEnabled := Prop.GetValue(AComp).AsBoolean;
      Result := TRUE;
    except
      Result := FALSE;
      AEnabled := TRUE;
    end;
  finally
    Ctx.Free;
  end;
end;


function TryGetVisible(AComp: TComponent; OUT AVisible: Boolean): Boolean;
var
  Ctx: TRttiContext;
  RT: TRttiType;
  Prop: TRttiProperty;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'TryGetVisible: FMX touched off the main thread');
  Result := FALSE;
  AVisible := TRUE;
  Ctx := TRttiContext.Create;
  try
    RT := Ctx.GetType(AComp.ClassType);
    if RT = NIL then exit;
    Prop := RT.GetProperty('Visible');
    if not IsReadableBooleanProp(Prop) then exit;   // a non-Boolean Visible is reported as unknown
    try
      AVisible := Prop.GetValue(AComp).AsBoolean;
      Result := TRUE;
    except
      Result := FALSE;
      AVisible := TRUE;
    end;
  finally
    Ctx.Free;
  end;
end;


function TrySetTextProperty(AComp: TComponent; const AValue: String; OUT AErrCode: Integer): Boolean;
var
  Ctx: TRttiContext;
  RT: TRttiType;
  Prop: TRttiProperty;
  NewValue, Converted: TValue;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'TrySetTextProperty: FMX touched off the main thread');
  Result := FALSE;
  AErrCode := ErrRttiPropertyMissing;
  Ctx := TRttiContext.Create;
  try
    RT := Ctx.GetType(AComp.ClassType);
    if RT = NIL then exit;
    { As in the VCL bridge: Text first, then Caption. TCommonCustomForm has only Caption (no published Text), so set_text on a form needs the fallback.
      A Text or Caption that cannot hold a string counts as missing. }
    NewValue := AValue;
    Prop := RT.GetProperty('Text');
    if not TryConvertForWrite(Prop, NewValue, Converted) then
      Prop := RT.GetProperty('Caption');
    if not TryConvertForWrite(Prop, NewValue, Converted) then exit;
    if not Prop.IsWritable then
    begin
      AErrCode := ErrUnsupportedAction;
      exit;
    end;
    Prop.SetValue(AComp, Converted);
    Result := TRUE;
  finally
    Ctx.Free;
  end;
end;


// Mirror of the VCL twin's IsBoolFamilyType. TRUE for the ByteBool / WordBool / LongBool
// family, INCLUDING a strong alias (`type TFlag = type WordBool`): an alias gets its own
// typeinfo, so a plain handle comparison misses it and the property stays unwritable.
// BaseType resolves the alias, and it is a plain record field reached through GetTypeData
// (TTypeData.BaseType in System.TypInfo.pas) — present in every Delphi version, not a version-gated RTL
// routine of the ColorToStringExt kind. The RTL discriminates Boolean exactly this way in
// GetPropValue (System.TypInfo.pas). A root enumeration's BaseType points at itself,
// so plain WordBool matches here too (verified by Test_SetProperty_WordBoolWritesAllBitsSet,
// which would fail if it did not), and Boolean answers FALSE (it keeps its own branch).
// Deliberately NOT the RTL's `MinValue < 0` shortcut (GetEnumName in System.TypInfo.pas): a normal
// enumeration may legally carry a negative ordinal — the RTL declares such types itself
// (UCollationResult in System.Internal.ICU.pas) — and that test would misread them as booleans.
// Resolves ONE alias level, same as the RTL's own tests; an alias of an alias is not covered.
function IsBoolFamilyType(ATypeInfo: PTypeInfo): Boolean;
var
  Base: PTypeInfo;
begin
  Result := FALSE;
  if (ATypeInfo = NIL) or (ATypeInfo^.Kind <> tkEnumeration) then exit;
  Base := GetTypeData(ATypeInfo)^.BaseType^;
  Result := (Base = TypeInfo(ByteBool)) or (Base = TypeInfo(WordBool)) or (Base = TypeInfo(LongBool));
end;


// TAlphaColor as the AI reads it: 'claRed' for a named color, '#AARRGGBB' otherwise. Not AlphaColorToString:
// it strips the 'cla' prefix and returns 'Red' (System.UIConsts.pas, AlphaColorToString). AlphaColorToIdent
// returns the full 'claName', or 'x' + 8 hex digits for an unnamed color. TryParseAlphaColor accepts both forms.
function AlphaColorToText(AColor: TAlphaColor): String;
begin
  AlphaColorToIdent(Integer(AColor), Result);
  if (Result <> '') and (Result[1] = 'x') then
    Result := '#' + Copy(Result, 2, MaxInt);
end;


{ Mirror of the VCL twin's TryReadPropertyAsString: ListWritableProperties uses it to fill the optional 'currentValue' field of each writable property entry.
  AInstance is TObject (not TComponent), so the helper also works on nested TPersistent classes reached via a dotted propName.
  TAlphaColor is a `type Cardinal` (tkInteger), but its value is formatted as '#AARRGGBB' or 'claName', so the AI can feed it back to set_property unchanged. }
function TryReadPropertyAsString(AInstance: TObject; AProp: TRttiProperty; OUT AValue: String): Boolean;
var
  V: TValue;
  EnumName: String;
  SetStr: String;
  AlphaStr: String;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'TryReadPropertyAsString: FMX touched off the main thread');
  Result := FALSE;
  AValue := '';
  if not AProp.IsReadable then exit;
  try
    V := AProp.GetValue(AInstance);
  except
    exit;
  end;
  case AProp.PropertyType.TypeKind of
    tkString, tkLString, tkWString, tkUString:
    begin
      AValue := V.AsString;
      Result := TRUE;
    end;
    tkInteger:
    begin
      // TAlphaColor short-circuit: emit '#AARRGGBB' (or 'claName' when named) instead of a raw 32-bit integer.
      if AProp.PropertyType.Handle = TypeInfo(TAlphaColor) then
      begin
        try
          AlphaStr := AlphaColorToText(TAlphaColor(V.AsOrdinal));
          AValue := AlphaStr;
          Result := TRUE;
        except
          // Fall back to raw decimal on any UIConsts failure: a readback must never fail the whole availableProperties response.
          AValue := IntToStr(V.AsOrdinal);
          Result := TRUE;
        end;
        exit;
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
end;


// AInstance is TObject (not TComponent) so this also enumerates writable fields on nested TPersistent classes (e.g. TFont) reached via a dotted propName like 'Font.Size'.
function ListWritableProperties(AInstance: TObject): TJSONArray;
var
  Ctx: TRttiContext;
  RT: TRttiType;
  Prop: TRttiProperty;
  Node: TJSONObject;
  KindName: String;
  CurStr: String;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'ListWritableProperties: FMX touched off the main thread');
  Result := TJSONArray.Create;
  try
    Ctx := TRttiContext.Create;
    try
      RT := Ctx.GetType(AInstance.ClassType);
      if RT = NIL then exit;
      for Prop in RT.GetProperties do
      begin
        if not Prop.IsWritable then Continue;
        { tkClass is included so the AI sees 'Outer.Inner' nesting is available.
          TAlphaColor is tkInteger by RTTI but is labelled 'alphacolor', so the AI knows to send '#AARRGGBB' / 'claName' rather than a raw integer. }
        case Prop.PropertyType.TypeKind of
          tkString, tkLString, tkWString, tkUString: KindName := 'string';
          tkInteger:
            if Prop.PropertyType.Handle = TypeInfo(TAlphaColor) then
              KindName := 'alphacolor'
            else
              KindName := 'integer';
          tkInt64:                                    KindName := 'int64';
          tkEnumeration:
            // The ByteBool/WordBool/LongBool family reads back as 'True'/'False' through GetEnumName (System.TypInfo.pas) and set_property takes it as a boolean, so tag it 'boolean': 'enum' would send the AI hunting for enum identifiers this family does not have.
            if (Prop.PropertyType.Handle = TypeInfo(Boolean))
            or IsBoolFamilyType(Prop.PropertyType.Handle) then
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
        try
          Node.AddPair('name', Prop.Name);
          Node.AddPair('kind', KindName);
          if Prop.PropertyType.TypeKind <> tkClass then
            if TryReadPropertyAsString(AInstance, Prop, CurStr) then
              Node.AddPair('currentValue', CurStr);
          Result.AddElement(Node);   // ownership moves to Result
        except
          FreeAndNil(Node);
          raise;
        end;
      end;
    finally
      Ctx.Free;
    end;
  except
    // OOM-class guard: free the partly-built array (and its nodes) before re-raising; the caller receives only the exception, never the orphaned Result.
    FreeAndNil(Result);
    raise;
  end;
end;


{ AI-friendly TAlphaColor parser. Accepts:
    '#FF8000'        - 6 hex digits, alpha assumed $FF (fully opaque)
    '#80FF8000'      - 8 hex digits, full ARGB
    'claSkyBlue'     - System.UIConsts cla* constant
    'SkyBlue'        - bare name (UIConsts prepends 'cla' itself)
    '4283621118'     - decimal
    '$FF8000FF'      - Pascal-style hex literal
  Returns FALSE without raising on anything else.
  StringToAlphaColor does the parsing; the 6-digit short form is our own layer, because StringToAlphaColor treats '#FF8000' as alpha=0 (invisible), which is almost never what the AI means. }
function TryParseAlphaColor(const AStrValue: String; OUT AColor: TAlphaColor): Boolean;
var
  S: String;
begin
  Result := FALSE;
  S := Trim(AStrValue);
  if S = '' then exit;
  // 6-digit RGB short form ('#RRGGBB'): expand to 8-digit ARGB with full opacity, because StringToAlphaColor would read it as alpha=0 (fully transparent).
  if (S.Length = 7) and (S[1] = '#') then
    S := '#FF' + Copy(S, 2, 6);
  try
    AColor := StringToAlphaColor(S);
    Result := TRUE;
  except
    { StrToInt64 inside StringToAlphaColor raises EConvertError on garbage.
      Swallowed: the caller maps FALSE to a structured unsupported_action error. }
    Result := FALSE;
  end;
end;


{ Coerces AStrValue to a TValue of the property's declared type, then writes it.
  The VCL twin documents the full type-coercion contract, including the one-level dotted propName ('Font.Size'), which resolves the outer tkClass and then recurses onto the inner instance.
  AInstance is TObject (not TComponent) so the recursive call accepts a nested TPersistent.
  TAlphaColor (RTTI says tkInteger) is detected by type handle and routed through TryParseAlphaColor, so the AI can pass '#FF8000' or 'claSkyBlue' instead of a raw 32-bit integer.
  AFailedInstance: on FALSE with ErrRttiPropertyMissing, the object the lookup ran against; HandleSetProperty lists the writables of that inner class when the typo was on the inner name.
  AElided: on TRUE, set to TRUE when the live property value already equalled the coerced new value, so Prop.SetValue was skipped (no OnChange fires).
  FMX has no TColor branch; the other type kinds match the VCL twin. }
function TrySetGenericProperty(AInstance: TObject; const APropName, AStrValue: String;
                               OUT AErrCode: Integer; OUT AErrMsg: String;
                               OUT AFailedInstance: TObject;
                               OUT AElided: Boolean): Boolean;
var
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
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'TrySetGenericProperty: FMX touched off the main thread');
  Result := FALSE;
  AErrCode := ErrRttiPropertyMissing;
  AErrMsg := '';
  AFailedInstance := AInstance;
  AElided := FALSE;

  // Dotted propName: 'Outer.Inner', one level only (the VCL twin has the full contract).
  DotPos := Pos('.', APropName);
  if DotPos > 0 then
  begin
    OuterName := Copy(APropName, 1, DotPos - 1);
    InnerName := Copy(APropName, DotPos + 1, MaxInt);
    if Pos('.', InnerName) > 0 then
    begin
      AErrCode := ErrUnsupportedAction;
      AErrMsg := 'set_property supports at most one level of nesting; got "' + APropName + '"';
      exit;
    end;
    if (OuterName = '') or (InnerName = '') then
    begin
      AErrCode := ErrUnsupportedAction;
      AErrMsg := 'invalid dotted propName "' + APropName + '"';
      exit;
    end;
    Ctx := TRttiContext.Create;
    try
      RT := Ctx.GetType(AInstance.ClassType);
      if RT = NIL then
      begin
        AErrMsg := AInstance.ClassName + ' has no RTTI';
        exit;
      end;
      Prop := RT.GetProperty(OuterName);
      if Prop = NIL then
      begin
        AErrMsg := AInstance.ClassName + ' has no published property "' + OuterName + '"';
        exit;
      end;
      if Prop.PropertyType.TypeKind <> tkClass then
      begin
        AErrCode := ErrUnsupportedAction;
        AErrMsg := AInstance.ClassName + '.' + OuterName +
                   ' is not a class-typed property (dotted propName requires tkClass outer)';
        exit;
      end;
      if not Prop.IsReadable then
      begin
        AErrCode := ErrUnsupportedAction;
        AErrMsg := AInstance.ClassName + '.' + OuterName + ' is not readable';
        exit;
      end;
      try
        Inner := Prop.GetValue(AInstance).AsObject;
      except
        on E: Exception do
        begin
          AErrCode := ErrUnsupportedAction;
          AErrMsg := AInstance.ClassName + '.' + OuterName + ' getter raised ' + E.ClassName;
          exit;
        end;
      end;
      if Inner = NIL then
      begin
        AErrCode := ErrUnsupportedAction;
        AErrMsg := AInstance.ClassName + '.' + OuterName + ' is nil';
        exit;
      end;
    finally
      Ctx.Free;
    end;
    exit(TrySetGenericProperty(Inner, InnerName, AStrValue, AErrCode, AErrMsg, AFailedInstance, AElided));
  end;

  Ctx := TRttiContext.Create;
  try
    RT := Ctx.GetType(AInstance.ClassType);
    if RT = NIL then
    begin
      AErrMsg := AInstance.ClassName + ' has no RTTI';
      exit;
    end;
    Prop := RT.GetProperty(APropName);
    if Prop = NIL then
    begin
      AErrMsg := AInstance.ClassName + ' has no published property "' + APropName + '"';
      exit;
    end;
    if not Prop.IsWritable then
    begin
      AErrCode := ErrUnsupportedAction;
      AErrMsg := AInstance.ClassName + '.' + APropName + ' is read-only';
      exit;
    end;

    // Read the live value once for elision (see VCL twin's longer note).
    CanRead := FALSE;
    if Prop.IsReadable then
    begin
      try
        CurVal := Prop.GetValue(AInstance);
        CanRead := TRUE;
      except
        CanRead := FALSE;
      end;
    end;

    case Prop.PropertyType.TypeKind of
      tkString, tkLString, tkWString, tkUString:
      begin
        if CanRead and (CurVal.AsString = AStrValue) then
        begin
          AElided := TRUE;
          exit(TRUE);
        end;
        Prop.SetValue(AInstance, AStrValue);
        exit(TRUE);
      end;

      tkInteger:
      begin
        { TAlphaColor (System.UITypes.TAlphaColor = type Cardinal), detected by type handle, not class name.
          TryParseAlphaColor lets the AI pass '#FF8000' (6-digit RGB, full alpha), '#80FF8000' (8-digit ARGB), 'claSkyBlue', or a raw decimal/$hex integer. }
        if Prop.PropertyType.Handle = TypeInfo(TAlphaColor) then
        begin
          if not TryParseAlphaColor(AStrValue, AlphaVal) then
          begin
            AErrCode := ErrUnsupportedAction;
            AErrMsg := APropName + ' expects a TAlphaColor value (e.g. "#FF8000", "#80FF8000", "claSkyBlue", or a numeric color); got "' + AStrValue + '"';
            exit;
          end;
          if CanRead and (TAlphaColor(CurVal.AsOrdinal) = AlphaVal) then
          begin
            AElided := TRUE;
            exit(TRUE);
          end;
          Prop.SetValue(AInstance, TValue.From<TAlphaColor>(AlphaVal));
          exit(TRUE);
        end;
        Val(AStrValue, IntVal, Code);
        if Code <> 0 then
        begin
          AErrCode := ErrUnsupportedAction;
          AErrMsg := APropName + ' expects an integer; got "' + AStrValue + '"';
          exit;
        end;
        if CanRead and (CurVal.AsInteger = IntVal) then
        begin
          AElided := TRUE;
          exit(TRUE);
        end;
        Prop.SetValue(AInstance, IntVal);
        exit(TRUE);
      end;

      tkInt64:
      begin
        Val(AStrValue, Int64Val, Code);
        if Code <> 0 then
        begin
          AErrCode := ErrUnsupportedAction;
          AErrMsg := APropName + ' expects an int64; got "' + AStrValue + '"';
          exit;
        end;
        if CanRead and (CurVal.AsInt64 = Int64Val) then
        begin
          AElided := TRUE;
          exit(TRUE);
        end;
        Prop.SetValue(AInstance, Int64Val);
        exit(TRUE);
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
            exit;
          end;
          if CanRead and (CurVal.AsBoolean = BoolVal) then
          begin
            AElided := TRUE;
            exit(TRUE);
          end;
          Prop.SetValue(AInstance, BoolVal);
          exit(TRUE);
        end
        else if IsBoolFamilyType(Prop.PropertyType.Handle) then
        begin
          // ByteBool/WordBool/LongBool are tkEnumeration, and the generic enum path below
          // cannot write TRUE to them: GetEnumValue answers 'True' with -1, which is also its
          // not-found result, so the EnumOrd<0 fallback runs Val('True'), fails, and reports
          // -32005; any other non-numeric string reaches a bare StrToInt inside GetEnumValue
          // and raises EConvertError (GetEnumValue in System.TypInfo.pas, Delphi 13), escaping as
          // -32603. Reachable on a shipped component: TADOCommand.Prepared is a published
          // WordBool (Data.Win.ADODB.pas). It is also the read/write round trip -
          // read_property renders this family through GetEnumName, which returns
          // BooleanIdents[Value <> 0] = 'True'/'False' (System.TypInfo.pas).
          // Matched by BaseType (see IsBoolFamilyType), which also catches a strong alias
          // such as `type TFlag = type WordBool`, NOT by the RTL's own MinValue < 0 test:
          // a normal enumeration may legally carry a negative ordinal (the RTL declares
          // such types itself - UCollationResult in System.Internal.ICU.pas), and catching those here would
          // turn set_property(<that enum>, '1') into a silent write of -1.
          Lower := LowerCase(AStrValue);
          if (Lower = 'true') or (Lower = '1') or (Lower = '-1') then
            BoolVal := TRUE
          else if (Lower = 'false') or (Lower = '0') then
            BoolVal := FALSE
          else
          begin
            AErrCode := ErrUnsupportedAction;
            AErrMsg := APropName + ' expects boolean (true/false); got "' + AStrValue + '"';
            exit;
          end;
          if CanRead and ((CurVal.AsOrdinal <> 0) = BoolVal) then
          begin
            AElided := TRUE;
            exit(TRUE);
          end;
          // TRUE is all-bits-set (-1) for this family, not 1 - the OLE VARIANT_BOOL convention the COM consumers of these properties compare against.
          if BoolVal
          then Prop.SetValue(AInstance, TValue.FromOrdinal(Prop.PropertyType.Handle, -1))
          else Prop.SetValue(AInstance, TValue.FromOrdinal(Prop.PropertyType.Handle, 0));
          exit(TRUE);
        end
        else
        begin
          { GetEnumValue is not exception-free: for an enumeration whose MinValue is negative it skips the name list and runs a bare StrToInt on the string (System.TypInfo.pas, Delphi 13), which raises EConvertError on any identifier.
            That is treated as "no such identifier" and the ordinal fallback decides, so the coercion lane answers -32005 instead of leaking -32603. }
          try
            EnumOrd := GetEnumValue(Prop.PropertyType.Handle, AStrValue);
          except
            on EConvertError do
              EnumOrd := -1;
          end;
          if EnumOrd < 0 then
          begin
            Val(AStrValue, IntVal, Code);
            if Code <> 0 then
            begin
              AErrCode := ErrUnsupportedAction;
              AErrMsg := APropName + ' expects an enum identifier or ordinal; got "' + AStrValue + '"';
              exit;
            end;
            EnumOrd := IntVal;
          end;
          if CanRead and (CurVal.AsOrdinal = EnumOrd) then
          begin
            AElided := TRUE;
            exit(TRUE);
          end;
          Prop.SetValue(AInstance, TValue.FromOrdinal(Prop.PropertyType.Handle, EnumOrd));
          exit(TRUE);
        end;

      tkSet:
      begin
        { Accepts '[a,b]', 'a,b', '[]', or a numeric ordinal, as the VCL twin does.
          TValue.FromOrdinal raises EInvalidCast for tkSet typeinfo, so TValue.Make with a pointer to the raw ordinal is used instead. }
        Lower := Trim(AStrValue);
        if (Lower <> '') and (Lower[1] <> '[') then
        begin
          Val(Lower, IntVal, Code);
          if Code = 0 then
          begin
            if CanRead and (Integer(CurVal.GetReferenceToRawData^) = IntVal) then
            begin
              AElided := TRUE;
              exit(TRUE);
            end;
            TValue.Make(@IntVal, Prop.PropertyType.Handle, TmpVal);
            Prop.SetValue(AInstance, TmpVal);
            exit(TRUE);
          end;
          Lower := '[' + Lower + ']';
        end;
        try
          IntVal := StringToSet(Prop.PropertyType.Handle, Lower);
        except
          on E: Exception do
          begin
            AErrCode := ErrUnsupportedAction;
            AErrMsg := APropName + ' expects a set literal like "[biSystemMenu,biMinimize]"; got "' + AStrValue + '"';
            exit;
          end;
        end;
        if CanRead and (Integer(CurVal.GetReferenceToRawData^) = IntVal) then
        begin
          AElided := TRUE;
          exit(TRUE);
        end;
        TValue.Make(@IntVal, Prop.PropertyType.Handle, TmpVal);
        Prop.SetValue(AInstance, TmpVal);
        exit(TRUE);
      end;

      tkFloat:
      begin
        if not TryStrToFloat(AStrValue, FloatVal, FormatSettings.Invariant) then
        begin
          AErrCode := ErrUnsupportedAction;
          AErrMsg := APropName + ' expects a number; got "' + AStrValue + '"';
          exit;
        end;
        { Exact-bits equality (no epsilon): Double/Extended round-trip cleanly.
          A Single-typed property may not elide on a resend of a decimal that Single cannot hold exactly (e.g. 0.1); that is harmless, the write goes through.
          AsExtended is the standard tkFloat accessor. }
        if CanRead and (CurVal.AsExtended = FloatVal) then
        begin
          AElided := TRUE;
          exit(TRUE);
        end;
        Prop.SetValue(AInstance, FloatVal);
        exit(TRUE);
      end;
    else
      AErrCode := ErrUnsupportedAction;
      AErrMsg := APropName + ' has unsupported type kind (' + IntToStr(Ord(Prop.PropertyType.TypeKind)) +
                 ' — use a dotted propName like "Outer.Inner" if this is a class-typed property)';
      exit;
    end;
  finally
    Ctx.Free;
  end;
end;


function TrySetCheckedProperty(AComp: TComponent; AValue: Boolean; OUT AErrCode: Integer): Boolean;
var
  Ctx: TRttiContext;
  RT: TRttiType;
  Prop: TRttiProperty;
  NewValue, Converted: TValue;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'TrySetCheckedProperty: FMX touched off the main thread');
  Result := FALSE;
  AErrCode := ErrRttiPropertyMissing;
  Ctx := TRttiContext.Create;
  try
    RT := Ctx.GetType(AComp.ClassType);
    if RT = NIL then exit;
    // An IsChecked or Checked that is not a Boolean counts as missing.
    NewValue := AValue;
    Prop := RT.GetProperty('IsChecked');     // FMX TCheckBox.IsChecked, not Checked
    if not TryConvertForWrite(Prop, NewValue, Converted) then
      Prop := RT.GetProperty('Checked');
    if not TryConvertForWrite(Prop, NewValue, Converted) then exit;
    if not Prop.IsWritable then
    begin
      AErrCode := ErrUnsupportedAction;
      exit;
    end;
    Prop.SetValue(AComp, Converted);
    Result := TRUE;
  finally
    Ctx.Free;
  end;
end;


function LeafNameFor(AComp: TComponent): String;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'LeafNameFor: FMX touched off the main thread');
  if AComp.Name = '' then
    Result := SyntheticIdFor(AComp)
  else
    Result := AComp.Name;
end;


// The path list_tree gives AComp - see the VCL twin. '' when its owner chain reaches no form.
function OwnerPathFor(AComp: TComponent): String;
var
  Cur: TComponent;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'OwnerPathFor: FMX touched off the main thread');
  if AComp is TCommonCustomForm then exit(AComp.Name);
  Result := LeafNameFor(AComp);
  Cur := AComp.Owner;
  while Cur <> NIL do
  begin
    if Cur is TCommonCustomForm then exit(Cur.Name + '.' + Result);
    Result := LeafNameFor(Cur) + '.' + Result;
    Cur := Cur.Owner;
  end;
  Result := '';
end;


// How the AI can name AComp: its owner path, or its bare name/class when no form owns it.
function ReferenceFor(AComp: TComponent): String;
begin
  Result := OwnerPathFor(AComp);
  if Result = '' then
    if AComp.Name <> ''
    then Result := AComp.Name
    else Result := AComp.ClassName;
end;


// See the VCL twin: -32001 not_found, or -32002 ambiguous_path when the visual-parent fallback matched 2+ objects.
function ResolvePathOrFail(const APath: String; var AResp: TBridgeResponse): TComponent;
var
  Matches: TList;
  i: Integer;
  Candidates: String;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'ResolvePathOrFail: FMX touched off the main thread');
  Matches := TList.Create;
  try
    Result := FindComponentByPath(APath, Matches);
    if Result <> NIL then exit;

    AResp.Ok := FALSE;
    if Matches.Count < 2 then
    begin
      AResp.ErrorCode := ErrNotFound;
      AResp.ErrorMessage := 'no component matches ' + APath;
      exit;
    end;

    Candidates := '';
    for i := 0 to Matches.Count - 1 do
    begin
      if Candidates <> '' then
        Candidates := Candidates + ', ';
      Candidates := Candidates + ReferenceFor(TComponent(Matches[i]));
    end;
    AResp.ErrorCode := ErrAmbiguousPath;
    AResp.ErrorMessage := APath + ' is ambiguous: ' + IntToStr(Matches.Count) +
                          ' controls shown there match it (' + Candidates + '). Use one of these paths instead.';
  finally
    FreeAndNil(Matches);
  end;
end;


function IsInOwnerTree(AComp, ARoot: TComponent): Boolean;
var
  Cur: TComponent;
begin
  Cur := AComp;
  while Cur <> NIL do
  begin
    if Cur = ARoot then exit(TRUE);
    Cur := Cur.Owner;
  end;
  Result := FALSE;
end;


{ list_tree 'parent' field, for a re-parented object only (see the VCL twin).
  An internal content object (TTabItemContent) is reported as the control that holds it (the TTabItem), the name the AI can use in a path.
  A parent with no owner path (an object inside a style tree) gets no field: the AI could not use it. }
procedure AddReparentedField(ANode: TJSONObject; AComp, AListedUnder: TComponent);
var
  VisualParent: TFmxObject;
  ParentPath: String;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'AddReparentedField: FMX touched off the main thread');
  if not (AComp is TFmxObject) then exit;
  VisualParent := TFmxObject(AComp).Parent;
  if VisualParent = NIL then exit;
  if (AListedUnder <> NIL) and IsInOwnerTree(VisualParent, AListedUnder) then exit;
  while not VisualParent.Stored and (VisualParent.Parent <> NIL) do
    VisualParent := VisualParent.Parent;
  ParentPath := OwnerPathFor(VisualParent);
  if ParentPath <> '' then
    ANode.AddPair('parent', ParentPath);
end;


function BuildComponentNode(const AFormName, ANodePath: String; AComp: TComponent): TJSONObject;
var
  S: String;
  B: Boolean;
  NodeName: String;
  IsSynthetic: Boolean;
begin
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
end;


{ Command handlers ------------------------------------------------------ }

procedure WalkComponents(AFormName, AParentPath: String; AParent: TComponent;
                         AItems: TJSONArray; AVisited: TList);
var
  j: Integer;
  Child: TComponent;
  ChildPath: String;
  Node: TJSONObject;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'WalkComponents: FMX touched off the main thread');
  for j := 0 to AParent.ComponentCount - 1 do
  begin
    Child := AParent.Components[j];
    if AVisited.IndexOf(Child) >= 0 then Continue;
    AVisited.Add(Child);
    ChildPath := AParentPath + '.' + LeafNameFor(Child);
    Node := BuildComponentNode(AFormName, ChildPath, Child);
    AItems.AddElement(Node);   // AItems owns Node from here, so a raise below cannot leak it
    AddReparentedField(Node, Child, AParent);
    if Child.ComponentCount > 0 then
      WalkComponents(AFormName, ChildPath, Child, AItems, AVisited);
  end;
end;


function HandleListTree(const AReq: TBridgeRequest): TBridgeResponse;
var
  Items: TJSONArray;
  Wrap, FormNode: TJSONObject;
  Visited: TList;
  i: Integer;
  Form: TCommonCustomForm;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'HandleListTree must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;
  Result.Ok := TRUE;
  Items := TJSONArray.Create;
  try
    // Per-form Visited (the VCL twin explains why).
    for i := 0 to Screen.FormCount - 1 do
    begin
      Form := Screen.Forms[i];
      Visited := TList.Create;
      try
        { Emit the form as its own node first, then recurse owned components (including frames).
          Its Caption read may raise on an unrealized form; TryGetTextProperty swallows that and the node simply lacks a `text` field. }
        Visited.Add(Form);
        FormNode := BuildComponentNode(Form.Name, Form.Name, Form);
        Items.AddElement(FormNode);
        AddReparentedField(FormNode, Form, NIL);
        WalkComponents(Form.Name, Form.Name, Form, Items, Visited);
      finally
        FreeAndNil(Visited);
      end;
    end;
    Wrap := TJSONObject.Create;
    Wrap.AddPair('components', Items);
    Items := NIL;
    Result.ResultJson := Wrap;
  except
    FreeAndNil(Items);
    raise;
  end;
end;


function HandleGetText(const AReq: TBridgeRequest): TBridgeResponse;
var
  PathVal: TJSONValue;
  Path, Text: String;
  Comp: TComponent;
  Wrap: TJSONObject;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'HandleGetText must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;
  if AReq.Args = NIL then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'get_text requires args.path';
    exit;
  end;
  PathVal := AReq.Args.GetValue('path');
  if not (PathVal is TJSONString) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'get_text requires args.path (string)';
    exit;
  end;
  Path := TJSONString(PathVal).Value;
  Comp := ResolvePathOrFail(Path, Result);
  if Comp = NIL then exit;
  if not TryGetTextProperty(Comp, Text) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrRttiPropertyMissing;
    Result.ErrorMessage := Comp.ClassName + ' has no readable Text/Caption property';
    exit;
  end;
  Wrap := TJSONObject.Create;
  Wrap.AddPair('text', Text);
  Result.Ok := TRUE;
  Result.ResultJson := Wrap;
end;


function HandleClick(const AReq: TBridgeRequest): TBridgeResponse;
const
  MaxClickCount = 1000;
var
  PathVal, CountVal, ModeVal: TJSONValue;
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
  StoppedReason, Mode, DispatchedVia: String;
  UseControlClick: Boolean;
  Watch: TFreeWatch;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'HandleClick must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;
  StoppedReason := '';
  ClicksDone := 0;
  Notify := NIL;

  if AReq.Args = NIL then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'click requires args.path';
    exit;
  end;
  PathVal := AReq.Args.GetValue('path');
  if not (PathVal is TJSONString) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'click requires args.path (string)';
    exit;
  end;
  Path := TJSONString(PathVal).Value;

  RequestedCount := 1;
  CountVal := AReq.Args.GetValue('count');
  if CountVal is TJSONNumber then
  begin
    { TJSONNumber.AsInt is StrToInt(Value) (TJSONNumber.GetAsInt in System.JSON.pas): it RAISES EConvertError on a fractional (1.5) or out-of-Int32 count, which would surface as ErrInternalError.
      TryStrToInt on the raw number text keeps a malformed count in the ErrInvalidRequest lane where it belongs. }
    if not TryStrToInt(TJSONNumber(CountVal).Value, RequestedCount) then
    begin
      Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
      Result.ErrorMessage := 'click args.count must be an integer 1..' + IntToStr(MaxClickCount) +
                             ' (got ' + TJSONNumber(CountVal).Value + ')';
      exit;
    end;
    if (RequestedCount < 1) or (RequestedCount > MaxClickCount) then
    begin
      Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
      Result.ErrorMessage := 'click args.count must be 1..' + IntToStr(MaxClickCount) +
                             ' (got ' + IntToStr(RequestedCount) + ')';
      exit;
    end;
  end;

  { mode=message is VCL-on-Windows only: it posts BM_CLICK to the control's HWND, and an FMX control has no per-control window handle to post to (FMX paints its own controls).
    Rejected explicitly, because silently falling back to the synchronous OnClick path would defeat the caller's no-block intent.
    Validated strictly, like the VCL twin. }
  ModeVal := AReq.Args.GetValue('mode');
  if ModeVal <> NIL then
  begin
    if not (ModeVal is TJSONString) then
    begin
      Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
      Result.ErrorMessage := 'click args.mode must be a string ("auto" or "message")';
      exit;
    end;
    Mode := LowerCase(Trim(TJSONString(ModeVal).Value));
    if Mode = 'message' then
    begin
      Result.Ok := FALSE; Result.ErrorCode := ErrUnsupportedAction;
      Result.ErrorMessage := 'click mode=message is VCL-on-Windows only (FMX controls have no window ' +
                             'handle); omit mode to use the OnClick dispatch';
      exit;
    end;
    if (Mode <> '') and (Mode <> 'auto') then
    begin
      Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
      Result.ErrorMessage := 'click args.mode must be "auto" or "message" (got "' +
                             TJSONString(ModeVal).Value + '")';
      exit;
    end;
  end;

  Comp := ResolvePathOrFail(Path, Result);
  if Comp = NIL then exit;
  if TryGetEnabled(Comp, Enabled) and not Enabled then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrControlDisabled;
    Result.ErrorMessage := Comp.Name + ' is disabled';
    exit;
  end;

  { A control bound to an action: TControl.Click (FMX.Controls.pas) runs ActionLink.Execute, i.e. TCustomAction.Execute, with the action as Sender.
    Calling the OnClick that TControl.ActionChange copied from OnExecute skips that, and an action without OnExecute leaves OnClick NIL, so the click would fail. }
  UseControlClick := (Comp is TControl) and (TFmxControlAccess(Comp).ActionLink <> NIL);
  if UseControlClick then
    DispatchedVia := 'click'
  else
  begin
    { FMX has no other protected Click trick on a generic TControl base.
      Most clickable controls expose OnClick (TNotifyEvent) via RTTI; it is read and invoked. }
    DispatchedVia := 'onclick';
    Ctx := TRttiContext.Create;
    try
      RT := Ctx.GetType(Comp.ClassType);
      if RT = NIL then
      begin
        Result.Ok := FALSE; Result.ErrorCode := ErrUnsupportedAction;
        Result.ErrorMessage := Comp.ClassName + ' has no RTTI';
        exit;
      end;
      OnClickProp := RT.GetProperty('OnClick');
      if (OnClickProp = NIL) or not OnClickProp.IsReadable then
      begin
        Result.Ok := FALSE; Result.ErrorCode := ErrUnsupportedAction;
        Result.ErrorMessage := Comp.ClassName + ' has no OnClick';
        exit;
      end;
      RawValue := OnClickProp.GetValue(Comp);
      if RawValue.IsEmpty or (RawValue.Kind <> tkMethod) then
      begin
        Result.Ok := FALSE; Result.ErrorCode := ErrUnsupportedAction;
        Result.ErrorMessage := Comp.ClassName + '.OnClick is unset';
        exit;
      end;
      TMethod(Notify) := PMethod(RawValue.GetReferenceToRawData)^;
      if not Assigned(Notify) then
      begin
        Result.Ok := FALSE; Result.ErrorCode := ErrUnsupportedAction;
        Result.ErrorMessage := Comp.ClassName + '.OnClick is unset';
        exit;
      end;
    finally
      Ctx.Free;
    end;
  end;

  { An OnClick may free the control, or the form that owns it: Watch learns of the free, and the loop stops with stoppedReason='freed' before Comp is read again (the VCL twin explains more).
    On an action-bound control the FMX RTL itself still reads the freed control once: TControl.Click reads Action in its finally (FMX.Controls.pas).
    The try..except stops the loop when an OnClick raises. }
  Watch := TFreeWatch.Create(Comp);
  try
    while ClicksDone < RequestedCount do
    begin
      if Watch.Freed then
      begin
        StoppedReason := 'freed';
        Break;
      end;
      if TryGetEnabled(Comp, Enabled) and not Enabled then
      begin
        StoppedReason := 'disabled';
        Break;
      end;
      try
        if UseControlClick
        then TFmxControlAccess(Comp).Click
        else Notify(Comp);
        Inc(ClicksDone);
      except
        on E: Exception do
        begin
          StoppedReason := 'exception:' + E.ClassName;
          BridgeLogWarn('bridge', 'click loop stopped at iter ' + IntToStr(ClicksDone + 1) +
                                  ': ' + E.ClassName + ': ' + E.Message);
          Break;
        end;
      end;
    end;
  finally
    FreeAndNil(Watch);   // its destructor unlinks it from Comp when Comp is still alive
  end;

  Wrap := TJSONObject.Create;
  Wrap.AddPair('dispatchedVia', DispatchedVia);
  Wrap.AddPair('clicksDispatched', TJSONNumber.Create(ClicksDone));
  if StoppedReason <> '' then
    Wrap.AddPair('stoppedReason', StoppedReason);
  Result.Ok := TRUE;
  Result.ResultJson := Wrap;
end;


{ execute_action: fires TBasicAction.Execute directly.
  Covers an action with no control (keyboard-shortcut-only actions) and many controls sharing one action, where a click on the control is indirect.
  TBasicAction.Execute (System.Classes.pas) fires OnExecute and returns True when it is assigned; it does not check Enabled, so this handler must check it. }
function HandleExecuteAction(const AReq: TBridgeRequest): TBridgeResponse;
var
  PathVal: TJSONValue;
  Path: String;
  Comp: TComponent;
  Enabled: Boolean;
  Executed: Boolean;
  Wrap: TJSONObject;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'HandleExecuteAction must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;

  if AReq.Args = NIL then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'execute_action requires args.path';
    exit;
  end;
  PathVal := AReq.Args.GetValue('path');
  if not (PathVal is TJSONString) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'execute_action requires args.path (string)';
    exit;
  end;
  Path := TJSONString(PathVal).Value;

  Comp := ResolvePathOrFail(Path, Result);
  if Comp = NIL then exit;

  if not (Comp is TBasicAction) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrUnsupportedAction;
    Result.ErrorMessage := Comp.ClassName + ' is not a TBasicAction - use click for controls';
    exit;
  end;

  if TryGetEnabled(Comp, Enabled) and not Enabled then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrControlDisabled;
    Result.ErrorMessage := Comp.Name + ' is disabled';
    exit;
  end;

  // OnExecute that closes the app / frees forms is the same hazard as a click
  // that does so. Don't touch Comp after Execute returns.
  try
    Executed := TBasicAction(Comp).Execute;
  except
    on E: Exception do
    begin
      BridgeLogError('bridge', 'execute_action OnExecute raised: ' + E.ClassName + ': ' + E.Message);
      Result.Ok := FALSE; Result.ErrorCode := ErrInternalError;
      Result.ErrorMessage := 'OnExecute raised ' + E.ClassName + ': ' + E.Message;
      exit;
    end;
  end;

  Wrap := TJSONObject.Create;
  Wrap.AddPair('path', Path);
  Wrap.AddPair('dispatchedVia', 'Execute');
  Wrap.AddPair('executed', TJSONBool.Create(Executed));
  Result.Ok := TRUE;
  Result.ResultJson := Wrap;
end;


function HandleSetText(const AReq: TBridgeRequest): TBridgeResponse;
var
  PathVal, TextVal: TJSONValue;
  Path, Text: String;
  Comp: TComponent;
  Enabled: Boolean;
  ErrCode: Integer;
  Wrap: TJSONObject;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'HandleSetText must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;
  if AReq.Args = NIL then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'set_text requires args.path and args.text';
    exit;
  end;
  PathVal := AReq.Args.GetValue('path');
  TextVal := AReq.Args.GetValue('text');
  if not (PathVal is TJSONString) or not (TextVal is TJSONString) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'set_text requires args.path (string) and args.text (string)';
    exit;
  end;
  Path := TJSONString(PathVal).Value;
  Text := TJSONString(TextVal).Value;
  Comp := ResolvePathOrFail(Path, Result);
  if Comp = NIL then exit;
  if TryGetEnabled(Comp, Enabled) and not Enabled then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrControlDisabled;
    Result.ErrorMessage := Comp.Name + ' is disabled';
    exit;
  end;
  if not TrySetTextProperty(Comp, Text, ErrCode) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrCode;
    if ErrCode = ErrUnsupportedAction then
      Result.ErrorMessage := Comp.ClassName + '.Text/Caption is read-only'
    else
      Result.ErrorMessage := Comp.ClassName + ' has no writable Text/Caption property';
    exit;
  end;
  Wrap := TJSONObject.Create;
  Wrap.AddPair('path', Path);
  Result.Ok := TRUE;
  Result.ResultJson := Wrap;
end;


function HandleSetChecked(const AReq: TBridgeRequest): TBridgeResponse;
var
  PathVal, CheckedVal: TJSONValue;
  Path: String;
  Checked: Boolean;
  Comp: TComponent;
  Enabled: Boolean;
  ErrCode: Integer;
  Wrap: TJSONObject;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'HandleSetChecked must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;
  if AReq.Args = NIL then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'set_checked requires args.path and args.checked';
    exit;
  end;
  PathVal := AReq.Args.GetValue('path');
  CheckedVal := AReq.Args.GetValue('checked');
  if not (PathVal is TJSONString) or not (CheckedVal is TJSONBool) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'set_checked requires args.path (string) and args.checked (boolean)';
    exit;
  end;
  Path := TJSONString(PathVal).Value;
  Checked := TJSONBool(CheckedVal).AsBoolean;
  Comp := ResolvePathOrFail(Path, Result);
  if Comp = NIL then exit;
  if TryGetEnabled(Comp, Enabled) and not Enabled then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrControlDisabled;
    Result.ErrorMessage := Comp.Name + ' is disabled';
    exit;
  end;
  if not TrySetCheckedProperty(Comp, Checked, ErrCode) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrCode;
    if ErrCode = ErrUnsupportedAction then
      Result.ErrorMessage := Comp.ClassName + '.IsChecked/Checked is read-only'
    else
      Result.ErrorMessage := Comp.ClassName + ' has no IsChecked/Checked property';
    exit;
  end;
  Wrap := TJSONObject.Create;
  Wrap.AddPair('path', Path);
  Wrap.AddPair('checked', TJSONBool.Create(Checked));
  Result.Ok := TRUE;
  Result.ResultJson := Wrap;
end;


function HandleSetProperty(const AReq: TBridgeRequest): TBridgeResponse;
var
  PathVal, NameVal, ValueVal: TJSONValue;
  Path, PropName, StrValue: String;
  Comp: TComponent;
  Enabled: Boolean;
  ErrCode: Integer;
  ErrMsg: String;
  Wrap: TJSONObject;
  FailedInstance: TObject;
  Elided: Boolean;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'HandleSetProperty must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;

  if AReq.Args = NIL then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'set_property requires args.path, args.propName, args.value';
    exit;
  end;
  PathVal  := AReq.Args.GetValue('path');
  NameVal  := AReq.Args.GetValue('propName');
  ValueVal := AReq.Args.GetValue('value');
  if not (PathVal is TJSONString) or not (NameVal is TJSONString) or not (ValueVal is TJSONString) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'set_property requires args.path, args.propName, args.value (all strings)';
    exit;
  end;
  Path     := TJSONString(PathVal).Value;
  PropName := TJSONString(NameVal).Value;
  StrValue := TJSONString(ValueVal).Value;

  Comp := ResolvePathOrFail(Path, Result);
  if Comp = NIL then exit;
  // A disabled control refuses every property (-32003) except 'Enabled' itself (exact name, any case, no dotted
  // path; TRUE and FALSE). Without that exception a control disabled through set_property could never be enabled
  // again by any tool (Gabriel, 2026-10-07). click, set_text and set_checked keep their own disabled check.
  if TryGetEnabled(Comp, Enabled) and not Enabled and not SameText(PropName, 'Enabled') then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrControlDisabled;
    Result.ErrorMessage := Comp.Name + ' is disabled';
    exit;
  end;

  if not TrySetGenericProperty(Comp, PropName, StrValue, ErrCode, ErrMsg, FailedInstance, Elided) then
  begin
    Result.Ok := FALSE;
    Result.ErrorCode := ErrCode;
    Result.ErrorMessage := ErrMsg;
    // For a dotted propName whose INNER name was the typo, FailedInstance is the inner TPersistent: listing its writables gives the AI the right surface.
    if ErrCode = ErrRttiPropertyMissing then
    begin
      Result.ErrorData := TJSONObject.Create;
      if FailedInstance = NIL then FailedInstance := Comp;
      try
        Result.ErrorData.AddPair('availableProperties', ListWritableProperties(FailedInstance));
      except
        // OOM-class guard: a raise out of the lister must not orphan the just-built ErrorData; the worker's except block sees only the exception, never this record.
        FreeAndNil(Result.ErrorData);
        raise;
      end;
    end;
    exit;
  end;

  Wrap := TJSONObject.Create;
  Wrap.AddPair('path', Path);
  Wrap.AddPair('propName', PropName);
  Wrap.AddPair('value', StrValue);
  // Write-side elision: TRUE when the live value already equalled the coerced new value and the bridge skipped Prop.SetValue (so OnChange did not fire).
  Wrap.AddPair('elided', TJSONBool.Create(Elided));
  Result.Ok := TRUE;
  Result.ResultJson := Wrap;
end;


function FindFormByName(const AFormName: String): TCommonCustomForm;
var
  i: Integer;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'FindFormByName: FMX touched off the main thread');
  Result := NIL;
  if AFormName = '' then
  begin
    if Application.MainForm <> NIL then
      Result := Application.MainForm
    else if Screen.FormCount > 0 then
      Result := Screen.Forms[0];
    exit;
  end;
  for i := 0 to Screen.FormCount - 1 do
    if SameText(Screen.Forms[i].Name, AFormName) then
      exit(Screen.Forms[i]);
end;


{ The rectangle that screenshot args.path captures, in the same units as HandleScreenshot's form bitmap (one pixel per dp).
  AForm: the form that shows AComp (its Root) - for a re-parented control, that is not the form that owns it.
  ARect: AComp's AbsoluteRect (form client coordinates), clipped to every parent control that clips its children and to the client area.
  FALSE, with AError set, when AComp cannot be captured: not a control, not on a TCustomForm, Visible = FALSE on it or on a parent control, zero size, or no part of it inside the client area. }
function TryGetCaptureRect(AComp: TComponent; OUT AForm: TCustomForm; OUT ARect: TRect; OUT AError: String): Boolean;
var
  Ctrl, P: TControl;
  R: TRectF;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'TryGetCaptureRect: FMX touched off the main thread');
  Result := FALSE;
  AForm  := NIL;
  ARect  := Default(TRect);
  AError := '';

  if AComp is TCommonCustomForm then
  begin
    if not (AComp is TCustomForm) then
    begin
      AError := ReferenceFor(AComp) + ' (' + AComp.ClassName + ') cannot be painted to a bitmap';
      EXIT;
    end;
    AForm := TCustomForm(AComp);
    ARect := Rect(0, 0, Round(AForm.ClientWidth), Round(AForm.ClientHeight));
  end
  else
  begin
    if not (AComp is TControl) then
    begin
      AError := ReferenceFor(AComp) + ' (' + AComp.ClassName + ') is not a visual control';
      EXIT;
    end;
    Ctrl := TControl(AComp);
    if (Ctrl.Root = NIL) or not (Ctrl.Root.GetObject is TCustomForm) then
    begin
      AError := ReferenceFor(Ctrl) + ' is not placed on a form';
      EXIT;
    end;
    AForm := TCustomForm(Ctrl.Root.GetObject);

    P := Ctrl;
    while P <> NIL do
    begin
      if not P.Visible then
      begin
        AError := ReferenceFor(Ctrl) + ' is not showing: Visible is FALSE on ' + ReferenceFor(P);
        EXIT;
      end;
      P := P.ParentControl;
    end;
    if (Ctrl.Width <= 0) or (Ctrl.Height <= 0) then
    begin
      AError := ReferenceFor(Ctrl) + ' has zero size';
      EXIT;
    end;

    R := Ctrl.AbsoluteRect;
    R.NormalizeRect;                                     // a rotated or mirrored control can give swapped corners
    P := Ctrl.ParentControl;
    while P <> NIL do
    begin
      if P.ClipChildren then
        R.Intersect(P.AbsoluteRect);
      P := P.ParentControl;
    end;
    R.Intersect(RectF(0, 0, Round(AForm.ClientWidth), Round(AForm.ClientHeight)));
    ARect := Rect(Round(R.Left), Round(R.Top), Round(R.Right), Round(R.Bottom));
  end;

  if ARect.IsEmpty then
  begin
    AError := ReferenceFor(AComp) + ' has no part inside the client area of ' + AForm.Name;
    EXIT;
  end;
  Result := TRUE;
end;


{ A new bitmap of ASource drawn at AWidth x AHeight with DrawBitmap's HighSpeed = FALSE (linear interpolation on the Direct2D canvas, FMX.Canvas.D2D.pas), so small text stays readable.
  FALSE (AScaled = NIL) when the canvas cannot begin a scene. The caller frees AScaled. }
function TryScaleBitmap(ASource: FMX.Graphics.TBitmap; AWidth, AHeight: Integer; OUT AScaled: FMX.Graphics.TBitmap): Boolean;
begin
  AScaled := FMX.Graphics.TBitmap.Create(AWidth, AHeight);
  try
    if not AScaled.Canvas.BeginScene then
    begin
      FreeAndNil(AScaled);
      EXIT(FALSE);
    end;
    try
      AScaled.Canvas.Clear(0);
      AScaled.Canvas.DrawBitmap(ASource, RectF(0, 0, ASource.Width, ASource.Height), RectF(0, 0, AWidth, AHeight), 1, FALSE);
    finally
      AScaled.Canvas.EndScene;
    end;
  except
    FreeAndNil(AScaled);
    raise;
  end;
  Result := TRUE;
end;


{ Optional args: form (ignored when path is given), path (crop to that control), maxWidth (scale down to that width).
  Every image comes from the form's PaintTo, so a crop gains no failure mode the whole-form capture does not have. }
function HandleScreenshot(const AReq: TBridgeRequest): TBridgeResponse;
var
  FormVal: TJSONValue;
  FormName, Path, ErrMsg: String;
  Form: TCommonCustomForm;
  Comp: TComponent;
  PaintForm: TCustomForm;
  CropRect: TRect;
  MaxWidth, NewW, NewH: Integer;
  IsScaled: Boolean;
  Bmp, Tmp: FMX.Graphics.TBitmap;
  Stream: TMemoryStream;
  Base64: String;
  Wrap: TJSONObject;
  W, H: Integer;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'HandleScreenshot must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;
  FormName := '';
  if AReq.Args <> NIL then
  begin
    FormVal := AReq.Args.GetValue('form');
    if FormVal is TJSONString then
      FormName := TJSONString(FormVal).Value;
  end;
  if not TryParseScreenshotArgs(AReq.Args, Path, MaxWidth, ErrMsg) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := ErrMsg;
    exit;
  end;

  { # What to capture }
  CropRect := Default(TRect);
  if Path <> '' then
  begin
    Comp := ResolvePathOrFail(Path, Result);
    if Comp = NIL then exit;
    if not TryGetCaptureRect(Comp, PaintForm, CropRect, ErrMsg) then
    begin
      Result.Ok := FALSE; Result.ErrorCode := ErrUnsupportedAction;
      Result.ErrorMessage := 'cannot capture ' + Path + ': ' + ErrMsg;
      exit;
    end;
    Form := PaintForm;
  end
  else
  begin
    Form := FindFormByName(FormName);
    // PaintTo is declared on TCustomForm (FMX.Forms.pas), so any TCustomForm descendant is accepted, not just TForm: TCustomPopupForm etc. work too.
    if (Form = NIL) or not (Form is TCustomForm) then
    begin
      Result.Ok := FALSE; Result.ErrorCode := ErrNotFound;
      if FormName = '' then
        Result.ErrorMessage := 'no main FMX form available'
      else
        Result.ErrorMessage := 'no FMX form named ' + FormName;
      exit;
    end;
  end;

  { # Capture, crop, scale, encode }
  { FMX has no TForm.MakeScreenshot (that is on TControl), so PaintTo draws onto a bitmap canvas instead.
    ClientWidth/Height are in dp, which is what the form paints in; one pixel per dp is fine for this diagnostic use. }
  W := Round(TCustomForm(Form).ClientWidth);
  H := Round(TCustomForm(Form).ClientHeight);
  if (W <= 0) or (H <= 0) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrUnsupportedAction;
    Result.ErrorMessage := 'form has zero client size';
    exit;
  end;
  Bmp := FMX.Graphics.TBitmap.Create(W, H);
  try
    { BeginScene can return FALSE if the bitmap context is not ready (DoBeginScene failure on the active FMX graphics backend).
      Without this check, SaveToStream would silently emit a base64 PNG of an uninitialized canvas with Ok=TRUE: a wrong answer and no error. }
    if not Bmp.Canvas.BeginScene then
    begin
      Result.Ok := FALSE; Result.ErrorCode := ErrUnsupportedAction;
      Result.ErrorMessage := 'Canvas.BeginScene returned FALSE; cannot render form';
      exit;
    end;
    try
      Bmp.Canvas.Clear(0);
      TCustomForm(Form).PaintTo(Bmp.Canvas);
    finally
      Bmp.Canvas.EndScene;
    end;

    // A path that names the form itself keeps the uncropped bitmap.
    if (Path <> '') and ((CropRect.Left <> 0) or (CropRect.Top <> 0) or (CropRect.Width <> W) or (CropRect.Height <> H)) then
    begin
      Tmp := FMX.Graphics.TBitmap.Create(CropRect.Width, CropRect.Height);
      try
        Tmp.CopyFromBitmap(Bmp, CropRect, 0, 0);
      except
        FreeAndNil(Tmp);
        raise;
      end;
      FreeAndNil(Bmp);
      Bmp := Tmp;
    end;

    IsScaled := ScreenshotScaledSize(Bmp.Width, Bmp.Height, MaxWidth, NewW, NewH);
    if IsScaled then
    begin
      if not TryScaleBitmap(Bmp, NewW, NewH, Tmp) then
      begin
        Result.Ok := FALSE; Result.ErrorCode := ErrUnsupportedAction;
        Result.ErrorMessage := 'Canvas.BeginScene returned FALSE; cannot scale the image';
        exit;
      end;
      FreeAndNil(Bmp);
      Bmp := Tmp;
    end;
    W := Bmp.Width;
    H := Bmp.Height;

    Stream := TMemoryStream.Create;
    try
      Bmp.SaveToStream(Stream);  // FMX picks codec by file ext / default = PNG.
      Stream.Position := 0;
      Base64 := TNetEncoding.Base64.EncodeBytesToString(Stream.Memory, Stream.Size);
    finally
      FreeAndNil(Stream);
    end;
  finally
    FreeAndNil(Bmp);
  end;
  Wrap := TJSONObject.Create;
  Wrap.AddPair('form', Form.Name);
  if Path <> '' then
    Wrap.AddPair('path', Path);
  // Same field set as the VCL twin: the image size, one pixel per dp; without path and maxWidth that is the client size.
  Wrap.AddPair('width', TJSONNumber.Create(W));
  Wrap.AddPair('height', TJSONNumber.Create(H));
  Wrap.AddPair('scaled', TJSONBool.Create(IsScaled));
  Wrap.AddPair('encoding', 'base64');
  Wrap.AddPair('format', 'png');
  Wrap.AddPair('image', Base64);
  Result.Ok := TRUE;
  Result.ResultJson := Wrap;
end;


{ READABLE-property enumerator for FMX, parallel to ListWritableProperties but gated on IsReadable; HandleReadProperty uses it for typo recovery.
  Same kind vocabulary as the VCL twin, minus the TColor branch (FMX has no TColor). }
function ListReadableProperties(AInstance: TObject): TJSONArray;
var
  Ctx: TRttiContext;
  RT: TRttiType;
  Prop: TRttiProperty;
  Node: TJSONObject;
  KindName: String;
  CurStr: String;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'ListReadableProperties: FMX touched off the main thread');
  Result := TJSONArray.Create;
  try
    Ctx := TRttiContext.Create;
    try
      RT := Ctx.GetType(AInstance.ClassType);
      if RT = NIL then exit;
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
            // The ByteBool/WordBool/LongBool family reads back as 'True'/'False' through GetEnumName (System.TypInfo.pas) and set_property takes it as a boolean, so tag it 'boolean': 'enum' would send the AI hunting for enum identifiers this family does not have.
            if (Prop.PropertyType.Handle = TypeInfo(Boolean))
            or IsBoolFamilyType(Prop.PropertyType.Handle) then
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
        try
          Node.AddPair('name', Prop.Name);
          Node.AddPair('kind', KindName);
          if Prop.PropertyType.TypeKind <> tkClass then
            if TryReadPropertyAsString(AInstance, Prop, CurStr) then
              Node.AddPair('currentValue', CurStr);
          Result.AddElement(Node);   // ownership moves to Result
        except
          FreeAndNil(Node);
          raise;
        end;
      end;
    finally
      Ctx.Free;
    end;
  except
    FreeAndNil(Result);   // same OOM-class guard as ListWritableProperties
    raise;
  end;
end;


{ Resolves a (possibly one-level dotted) propName on AInstance and reads it; FMX twin of the VCL TryReadGenericProperty.
  No TColor branch: FMX uses TAlphaColor exclusively. }
function TryReadGenericProperty(AInstance: TObject; const APropName: String;
                                OUT AValue, AKind: String;
                                OUT AErrCode: Integer; OUT AErrMsg: String;
                                OUT AFailedInstance: TObject): Boolean;
var
  Ctx: TRttiContext;
  RT: TRttiType;
  Prop: TRttiProperty;
  Inner: TObject;
  DotPos: Integer;
  OuterName, InnerName: String;
begin
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
      exit;
    end;
    if (OuterName = '') or (InnerName = '') then
    begin
      AErrCode := ErrUnsupportedAction;
      AErrMsg := 'invalid dotted propName "' + APropName + '"';
      exit;
    end;
    Ctx := TRttiContext.Create;
    try
      RT := Ctx.GetType(AInstance.ClassType);
      if RT = NIL then
      begin
        AErrMsg := AInstance.ClassName + ' has no RTTI';
        exit;
      end;
      Prop := RT.GetProperty(OuterName);
      if Prop = NIL then
      begin
        AErrMsg := AInstance.ClassName + ' has no published property "' + OuterName + '"';
        exit;
      end;
      if Prop.PropertyType.TypeKind <> tkClass then
      begin
        AErrCode := ErrUnsupportedAction;
        AErrMsg := AInstance.ClassName + '.' + OuterName +
                   ' is not a class-typed property (dotted propName requires tkClass outer)';
        exit;
      end;
      if not Prop.IsReadable then
      begin
        AErrCode := ErrUnsupportedAction;
        AErrMsg := AInstance.ClassName + '.' + OuterName + ' is not readable';
        exit;
      end;
      try
        Inner := Prop.GetValue(AInstance).AsObject;
      except
        on E: Exception do
        begin
          AErrCode := ErrUnsupportedAction;
          AErrMsg := AInstance.ClassName + '.' + OuterName + ' getter raised ' + E.ClassName;
          exit;
        end;
      end;
      if Inner = NIL then
      begin
        AErrCode := ErrUnsupportedAction;
        AErrMsg := AInstance.ClassName + '.' + OuterName + ' is nil';
        exit;
      end;
    finally
      Ctx.Free;
    end;
    exit(TryReadGenericProperty(Inner, InnerName, AValue, AKind, AErrCode, AErrMsg, AFailedInstance));
  end;

  Ctx := TRttiContext.Create;
  try
    RT := Ctx.GetType(AInstance.ClassType);
    if RT = NIL then
    begin
      AErrMsg := AInstance.ClassName + ' has no RTTI';
      exit;
    end;
    Prop := RT.GetProperty(APropName);
    if Prop = NIL then
    begin
      AErrMsg := AInstance.ClassName + ' has no published property "' + APropName + '"';
      exit;
    end;
    if not Prop.IsReadable then
    begin
      AErrCode := ErrUnsupportedAction;
      AErrMsg := AInstance.ClassName + '.' + APropName + ' is write-only';
      exit;
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
        // Same bool-family rule as ListReadableProperties above — the two must agree,
        // or the AI sees 'boolean' in availableProperties and 'enum' on the read.
        if (Prop.PropertyType.Handle = TypeInfo(Boolean))
        or IsBoolFamilyType(Prop.PropertyType.Handle) then
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
        exit;
      end;
    else
      AErrCode := ErrUnsupportedAction;
      AErrMsg := AInstance.ClassName + '.' + APropName + ' has unsupported type kind';
      exit;
    end;
    if not TryReadPropertyAsString(AInstance, Prop, AValue) then
    begin
      AErrCode := ErrUnsupportedAction;
      AErrMsg := AInstance.ClassName + '.' + APropName + ' getter raised or returned no value';
      exit;
    end;
    Result := TRUE;
  finally
    Ctx.Free;
  end;
end;


function HandleReadProperty(const AReq: TBridgeRequest): TBridgeResponse;
var
  PathVal, NameVal: TJSONValue;
  Path, PropName: String;
  Comp: TComponent;
  ErrCode: Integer;
  ErrMsg, Value, Kind: String;
  Wrap: TJSONObject;
  FailedInstance: TObject;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'HandleReadProperty must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;

  if AReq.Args = NIL then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'read_property requires args.path and args.propName';
    exit;
  end;
  PathVal := AReq.Args.GetValue('path');
  NameVal := AReq.Args.GetValue('propName');
  if not (PathVal is TJSONString) or not (NameVal is TJSONString) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'read_property requires args.path and args.propName (strings)';
    exit;
  end;
  Path := TJSONString(PathVal).Value;
  PropName := TJSONString(NameVal).Value;

  Comp := ResolvePathOrFail(Path, Result);
  if Comp = NIL then exit;
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
      try
        Result.ErrorData.AddPair('availableProperties', ListReadableProperties(FailedInstance));
      except
        FreeAndNil(Result.ErrorData);   // same OOM-class guard as HandleSetProperty
        raise;
      end;
    end;
    exit;
  end;

  Wrap := TJSONObject.Create;
  Wrap.AddPair('path', Path);
  Wrap.AddPair('propName', PropName);
  Wrap.AddPair('value', Value);
  Wrap.AddPair('kind', Kind);
  Result.Ok := TRUE;
  Result.ResultJson := Wrap;
end;


{ Android keep-screen-on: sets or clears FLAG_KEEP_SCREEN_ON on the activity window.
  While it is set and the app is foreground the screen never turns off, so the OxygenOS/AOSP cached-apps freezer (which fires on the LcdOff scene) never stalls the socket accept.
  Must run on the UI (main) thread; Dispatch and StartBridgeInternal both call it there.
  No-op on every non-Android platform: the screen-off process freeze is Android power management, and a Windows target is never frozen by the OS while an automation client drives it. }
procedure ApplyKeepScreenOn(AEnable: Boolean);
begin
  {$IFDEF ANDROID}
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'ApplyKeepScreenOn: JNI window flag touched off the main thread');
  if AEnable
  then TAndroidHelper.Activity.getWindow.addFlags(TJWindowManager_LayoutParams.JavaClass.FLAG_KEEP_SCREEN_ON)
  else TAndroidHelper.Activity.getWindow.clearFlags(TJWindowManager_LayoutParams.JavaClass.FLAG_KEEP_SCREEN_ON);
  {$ENDIF}
end;


{ dismiss_dialog: reaches native Win32 dialogs (MessageBox / Task Dialog / common dialogs) that the component-tree tools cannot see.
  Real on FMX-Windows (the shared helper drives the Win32 windows); on Android the helper returns supported:false (Android dialogs are ART windows, out of Win32 reach).
  No exclude list is needed: FMX renders its controls itself, so an FMX form HWND has no child 'Button' windows, is not class '#32770', and never matches the dialog filter. }
function HandleDismissDialog(const AReq: TBridgeRequest): TBridgeResponse;
var
  ButtonVal, HwndVal: TJSONValue;
  Selector, PlatformName: String;
  HasButton, Clicked: Boolean;
  TargetDlg, ResolvedDlg: NativeUInt;
  Exclude: TArray<NativeUInt>;
  Wrap: TJSONObject;
  ClickedId: Integer;
  ClickedCap, Reason, Via: String;
  HwndInt: Int64;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'HandleDismissDialog must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;

  Selector := '';
  HasButton := FALSE;
  TargetDlg := 0;
  if AReq.Args <> NIL then
  begin
    ButtonVal := AReq.Args.GetValue('button');
    if ButtonVal is TJSONString then
    begin
      Selector := TJSONString(ButtonVal).Value;
      HasButton := Trim(Selector) <> '';
    end;
    HwndVal := AReq.Args.GetValue('hwnd');
    if HwndVal <> NIL then
    begin
      // Reject a present-but-malformed hwnd (fractional / out-of-range / non-number) with ErrInvalidRequest rather than silently falling back to the topmost dialog: a typo'd handle must not dismiss an unintended dialog, and AsInt64 would otherwise raise here.
      if not TryJsonInt64(HwndVal, HwndInt) then
      begin
        Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
        Result.ErrorMessage := 'dismiss_dialog args.hwnd must be an integer window handle';
        exit;
      end;
      TargetDlg := NativeUInt(HwndInt);
    end;
  end;

  Exclude := NIL;   // FMX forms never match the dialog filter (see the comment above HandleDismissDialog)

  {$IFDEF MSWINDOWS} PlatformName := 'windows';
  {$ELSE}{$IFDEF ANDROID} PlatformName := 'android';
  {$ELSE} PlatformName := 'posix'; {$ENDIF}{$ENDIF}

  Wrap := TJSONObject.Create;
  try
    Wrap.AddPair('dialogs', EnumerateNativeDialogs(Exclude));   // empty off Windows
    Wrap.AddPair('supported', TJSONBool.Create(NativeDialogsSupported));
    Wrap.AddPair('platform', PlatformName);
    if HasButton then
    begin
      Clicked := ClickNativeDialogButton(Exclude, TargetDlg, Selector, ClickedId, ClickedCap, ResolvedDlg, Reason, Via);
      Wrap.AddPair('clicked', TJSONBool.Create(Clicked));
      if Clicked then
      begin
        Wrap.AddPair('clickedId', TJSONNumber.Create(ClickedId));
        Wrap.AddPair('clickedCaption', ClickedCap);
        Wrap.AddPair('dialogHwnd', TJSONNumber.Create(Int64(ResolvedDlg)));
        Wrap.AddPair('via', Via);
      end
      else
        Wrap.AddPair('reason', Reason);
    end;
    Result.Ok := TRUE;
    Result.ResultJson := Wrap;
    Wrap := NIL;
  finally
    if Wrap <> NIL then FreeAndNil(Wrap);
  end;
end;


{ set_keep_awake: toggles the device "keep screen on" state (see ApplyKeepScreenOn).
  Android: applies the window flag and reports applied:true.
  Off Android: accepted but a no-op (applied:false), so the shared MCP tool behaves uniformly against a VCL/Windows target.
  The bridge enables keep-screen-on by default on Android at StartBridge. }
function HandleSetKeepAwake(const AReq: TBridgeRequest): TBridgeResponse;
var
  EnabledVal: TJSONValue;
  Enable: Boolean;
  PlatformName: String;
  Applied: Boolean;
  Wrap: TJSONObject;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'HandleSetKeepAwake must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;
  if AReq.Args = NIL then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'set_keep_awake requires args.enabled';
    exit;
  end;
  EnabledVal := AReq.Args.GetValue('enabled');
  if not (EnabledVal is TJSONBool) then
  begin
    Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
    Result.ErrorMessage := 'set_keep_awake requires args.enabled (boolean)';
    exit;
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
end;


{ send_keys ----------------------------------------------------------------------------------------------- }

type
  { One chord of args.keys: optional modifiers and one key. }
  TKeyChord = record
    Key  : Word;
    Ctrl : Boolean;
    Shift: Boolean;
    Alt  : Boolean;
  end;


{ Maps a key name of args.keys (case-insensitive) to its virtual-key code. 0 = unknown name.
  The same table is in Autopilot.Bridge.Vcl.pas; keep the two identical. }
function KeyNameToVk(const AName: String): Word;
var
  N: String;
  FNum: Integer;
begin
  N := UpperCase(AName);
  if (Length(N) = 1) and CharInSet(N[1], ['A'..'Z', '0'..'9']) then
    exit(Ord(N[1]));    // vkA..vkZ and vk0..vk9 equal the ASCII codes (System.UITypes)
  if (Length(N) in [2, 3]) and (N[1] = 'F') and TryStrToInt(Copy(N, 2, 2), FNum) and (FNum >= 1) and (FNum <= 12) then
    exit(vkF1 + FNum - 1);
  if N = 'ENTER'     then exit(vkReturn);
  if (N = 'ESCAPE') or (N = 'ESC') then exit(vkEscape);
  if N = 'TAB'       then exit(vkTab);
  if N = 'SPACE'     then exit(vkSpace);
  if N = 'BACKSPACE' then exit(vkBack);
  if N = 'DELETE'    then exit(vkDelete);
  if N = 'INSERT'    then exit(vkInsert);
  if N = 'HOME'      then exit(vkHome);
  if N = 'END'       then exit(vkEnd);
  if N = 'PAGEUP'    then exit(vkPrior);
  if N = 'PAGEDOWN'  then exit(vkNext);
  if N = 'UP'        then exit(vkUp);
  if N = 'DOWN'      then exit(vkDown);
  if N = 'LEFT'      then exit(vkLeft);
  if N = 'RIGHT'     then exit(vkRight);
  Result := 0;
end;


{ Parses args.keys: chords separated by spaces, a chord = optional modifiers (Ctrl, Shift, Alt) joined by '+', then one key name.
  Parses everything before anything is sent: on the first bad token returns FALSE and AError names it. }
function ParseKeyChords(const AKeys: String; OUT AChords: TArray<TKeyChord>; OUT AError: String): Boolean;
var
  Tokens, Parts: TArray<String>;
  Token, Part: String;
  Chord: TKeyChord;
  i, Count: Integer;

  function SplitOn(const S: String; ASep: Char; AKeepEmpty: Boolean): TArray<String>;
  var
    Start, k: Integer;
  begin
    Result := NIL;
    Start := 1;
    for k := 1 to Length(S) + 1 do
      if (k > Length(S)) or (S[k] = ASep) then
      begin
        if AKeepEmpty or (k > Start) then
        begin
          SetLength(Result, Length(Result) + 1);
          Result[High(Result)] := Copy(S, Start, k - Start);
        end;
        Start := k + 1;
      end;
  end;

begin
  AChords := NIL;
  AError := '';
  Tokens := SplitOn(AKeys, ' ', FALSE);
  Count := 0;
  SetLength(AChords, Length(Tokens));
  for Token in Tokens do
  begin
    Chord := Default(TKeyChord);
    Parts := SplitOn(Token, '+', TRUE);
    for i := 0 to High(Parts) - 1 do
    begin
      Part := UpperCase(Parts[i]);
      if Part = 'CTRL' then Chord.Ctrl := TRUE
      else if Part = 'SHIFT' then Chord.Shift := TRUE
      else if Part = 'ALT' then Chord.Alt := TRUE
      else
      begin
        AError := 'unknown modifier "' + Parts[i] + '" in "' + Token + '" (use Ctrl, Shift, Alt)';
        exit(FALSE);
      end;
    end;
    Chord.Key := KeyNameToVk(Parts[High(Parts)]);
    if Chord.Key = 0 then
    begin
      AError := 'unknown key name "' + Parts[High(Parts)] + '" in "' + Token + '"';
      exit(FALSE);
    end;
    AChords[Count] := Chord;
    Inc(Count);
  end;
  Result := TRUE;
end;


{ Keys go through FMX's own form keyboard routine, TCommonCustomForm.KeyDown / KeyUp (FMX.Forms.pas), the routine the platform layer calls for a real key on Windows and on Android: accelerator keys, dialog keys (Default / Cancel buttons), Tab focus moves, the focused control's KeyDown (OnKeyDown, an edit inserting KeyChar), then the form's OnKeyDown.
  The FMX Windows platform sends the virtual key and the character as two KeyDown calls (key with #0, then 0 with the character); this does the same for a chord whose key types a character. No window is activated. }
procedure SendChordToForm(AForm: TCommonCustomForm; const AChord: TKeyChord);
var
  Shift: TShiftState;
  Key: Word;
  Ch: Char;
begin
  Shift := [];
  if AChord.Ctrl  then Include(Shift, ssCtrl);
  if AChord.Shift then Include(Shift, ssShift);
  if AChord.Alt   then Include(Shift, ssAlt);

  Key := AChord.Key;
  Ch  := #0;
  AForm.KeyDown(Key, Ch, Shift);

  if (Key <> 0) and not AChord.Ctrl and not AChord.Alt then
  begin
    Ch := #0;
    if (AChord.Key >= Ord('A')) and (AChord.Key <= Ord('Z')) then
      if AChord.Shift
      then Ch := Char(AChord.Key)
      else Ch := Char(AChord.Key + 32)
    else if (AChord.Key >= Ord('0')) and (AChord.Key <= Ord('9')) and not AChord.Shift then
      Ch := Char(AChord.Key)
    else if AChord.Key = vkSpace then
      Ch := ' ';
    if Ch <> #0 then
    begin
      Key := 0;
      AForm.KeyDown(Key, Ch, Shift);
    end;
  end;

  Key := AChord.Key;
  Ch  := #0;
  AForm.KeyUp(Key, Ch, Shift);
end;


procedure TypeCharToForm(AForm: TCommonCustomForm; ACh: Char);
var
  Key: Word;
  Ch: Char;
begin
  Key := 0;
  Ch  := ACh;
  AForm.KeyDown(Key, Ch, []);
  Key := 0;
  Ch  := ACh;
  AForm.KeyUp(Key, Ch, []);
end;


function HandleSendKeys(const AReq: TBridgeRequest): TBridgeResponse;
var
  PathVal, KeysVal, TextVal: TJSONValue;
  Path, Keys, Text, ParseError, TargetPath: String;
  Chords: TArray<TKeyChord>;
  Comp: TComponent;
  Form: TCommonCustomForm;
  Enabled: Boolean;
  Watch: TFreeWatch;
  i, Sent: Integer;
  Wrap: TJSONObject;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'HandleSendKeys must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;
  Result.Ok := FALSE;
  Result.ErrorCode := ErrInvalidRequest;

  Path := '';
  Keys := '';
  Text := '';
  if AReq.Args <> NIL then
  begin
    PathVal := AReq.Args.GetValue('path');
    KeysVal := AReq.Args.GetValue('keys');
    TextVal := AReq.Args.GetValue('text');
    if ((PathVal <> NIL) and not (PathVal is TJSONString))
    or ((KeysVal <> NIL) and not (KeysVal is TJSONString))
    or ((TextVal <> NIL) and not (TextVal is TJSONString)) then
    begin
      Result.ErrorMessage := 'send_keys args.path, args.keys and args.text must be strings';
      exit;
    end;
    if PathVal <> NIL then Path := TJSONString(PathVal).Value;
    if KeysVal <> NIL then Keys := TJSONString(KeysVal).Value;
    if TextVal <> NIL then Text := TJSONString(TextVal).Value;
  end;
  if (Trim(Keys) = '') and (Text = '') then
  begin
    Result.ErrorMessage := 'send_keys requires args.keys or args.text';
    exit;
  end;
  if not ParseKeyChords(Keys, Chords, ParseError) then
  begin
    Result.ErrorMessage := 'send_keys: ' + ParseError;
    exit;
  end;

  { # Target }
  if Path <> '' then
  begin
    Comp := ResolvePathOrFail(Path, Result);
    if Comp = NIL then exit;
    if TryGetEnabled(Comp, Enabled) and not Enabled then
    begin
      Result.ErrorCode := ErrControlDisabled;
      Result.ErrorMessage := Comp.Name + ' is disabled';
      exit;
    end;
    if Comp is TCommonCustomForm then
      Form := TCommonCustomForm(Comp)
    else
    begin
      if not (Comp is TControl) or not TControl(Comp).CanFocus or (TControl(Comp).Root = NIL)
      or not (TControl(Comp).Root.GetObject is TCommonCustomForm) then
      begin
        Result.ErrorCode := ErrUnsupportedAction;
        Result.ErrorMessage := Comp.ClassName + ' cannot take the keyboard focus';
        exit;
      end;
      Form := TCommonCustomForm(TControl(Comp).Root.GetObject);
      { Focus inside the form only (TCommonCustomForm.SetFocused): no window is activated. }
      if Form.Focused <> TControl(Comp) as IControl then
        try
          Form.Focused := TControl(Comp);
        except
          on E: EInvalidOperation do
          begin
            Result.ErrorCode := ErrUnsupportedAction;
            Result.ErrorMessage := Comp.Name + ' cannot take the keyboard focus now: ' + E.Message;
            exit;
          end;
        end;
    end;
    TargetPath := ReferenceFor(Comp);
  end
  else
  begin
    Form := Screen.ActiveForm;
    if Form = NIL then
      Form := Application.MainForm;
    if Form = NIL then
    begin
      Result.ErrorCode := ErrNotFound;
      Result.ErrorMessage := 'send_keys: no path given and the app has no active form';
      exit;
    end;
    if (Form.Focused <> NIL) and (Form.Focused.GetObject is TComponent)
    then TargetPath := ReferenceFor(TComponent(Form.Focused.GetObject))
    else TargetPath := ReferenceFor(Form);
  end;

  { # Send: text first, then the chords. A handler may free the form (Escape closing it): Watch stops the rest. }
  Sent := 0;
  Watch := TFreeWatch.Create(Form);
  try
    for i := 1 to Length(Text) do
    begin
      if Watch.Freed then Break;
      TypeCharToForm(Form, Text[i]);
      Inc(Sent);
    end;
    for i := 0 to High(Chords) do
    begin
      if Watch.Freed then Break;
      SendChordToForm(Form, Chords[i]);
      Inc(Sent);
    end;
  finally
    FreeAndNil(Watch);
  end;

  Wrap := TJSONObject.Create;
  Wrap.AddPair('keysSent', TJSONNumber.Create(Sent));
  Wrap.AddPair('target', TargetPath);
  Wrap.AddPair('via', 'formkeydown');
  Result.ErrorCode := 0;
  Result.Ok := TRUE;
  Result.ResultJson := Wrap;
end;


function Dispatch(const AReq: TBridgeRequest): TBridgeResponse;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'Dispatch must run on the main thread');
  { Refuse to touch FMX once the bridge is gone.
    A TThread.Queue entry posted with a NIL thread survives the worker's destruction (RemoveQueuedEvents(Self) in TThread.Destroy skips FThread=NIL entries, System.Classes.pas), so a request that timed out can still fire its queued proc after StopBridge, which at app shutdown means walking the form list while the forms are being torn down.
    FreeAndNil clears GWorker BEFORE running the destructor, and both StopBridge and this proc run on the main thread, so the test is race-free.
    It does NOT interfere with the documented short-timeoutMs recipe (fire a click, take -32004, then dismiss_dialog): the bridge is still running there, so the queued click fires as before. }
  if GWorker = NIL then
  begin
    Result := Default(TBridgeResponse);
    Result.Id := AReq.Id;
    Result.Ok := FALSE;
    Result.ErrorCode := ErrInternalError;
    Result.ErrorMessage := 'bridge stopped';
    exit;
  end;
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
  else if SameText(AReq.Cmd, 'send_keys') then
    Result := HandleSendKeys(AReq)
  else
  begin
    Result := Default(TBridgeResponse);
    Result.Id := AReq.Id;
    Result.Ok := FALSE;
    Result.ErrorCode := ErrUnsupportedAction;
    Result.ErrorMessage := 'unknown cmd: ' + AReq.Cmd;
  end;
end;


procedure EnsureLock;
begin
  if GLock = NIL then
    GLock := TCriticalSection.Create;
end;


// AEndpoint: Windows = the full pipe name; POSIX = the abstract-socket name.
procedure StartBridgeInternal(const AEndpoint: String);
var
  ExeName: String;
begin
  EnsureLock;
  GLock.Enter;
  try
    if GWorker <> NIL then exit;
    ExeName := ExtractFileName(ParamStr(0));
    BridgeLogInfo('bridge', 'StartBridge (FMX) exe=' + ExeName + ' endpoint=' + AEndpoint);
    BridgeLogInfo('license', CommercialLicenseHint);
    {$IFDEF MSWINDOWS}
    GWorker := TBridgeWorker.Create(TPipeTransport.Create(AEndpoint), ExeName, Dispatch);
    {$ELSE}
    GWorker := TBridgeWorker.Create(TSocketTransport.Create(AEndpoint), ExeName, Dispatch);
    {$ENDIF}
    {$IFDEF ANDROID}
    { Keep the screen on by default while the bridge runs: a backgrounded / screen-off app is frozen by Android power management, which stalls the socket accept (see ApplyKeepScreenOn).
      set_keep_awake(false) releases it.
      AUTOPILOT builds only. }
    ApplyKeepScreenOn(TRUE);
    BridgeLogInfo('bridge', 'keep-screen-on enabled (Android default)');
    {$ENDIF}
  finally
    GLock.Leave;
  end;
end;


procedure StartBridge;
begin
  {$IFDEF MSWINDOWS}
  StartBridgeInternal(ComputePipeName);
  {$ELSE}
  { Per-process abstract name; the kernel removes it when the socket closes.
    The PC side reaches it via: adb forward tcp:<hostPort> localabstract:Autopilot.<pid> }
  StartBridgeInternal('Autopilot.' + IntToStr(getpid));
  {$ENDIF}
end;


procedure StartBridgeOnPipe(const APipeName: String);
begin
  StartBridgeInternal(APipeName);
end;


procedure StopBridge;
begin
  if GLock = NIL then exit;
  GLock.Enter;
  try
    if GWorker = NIL then exit;
    BridgeLogInfo('bridge', 'StopBridge (FMX)');
    GWorker.Terminate;
    FreeAndNil(GWorker);
  finally
    GLock.Leave;
  end;
end;


function IsBridgeRunning: Boolean;
begin
  Result := GWorker <> NIL;
end;


{$ELSE}

procedure StartBridge;        begin end;
procedure StartBridgeOnPipe(const APipeName: String); begin end;
procedure StopBridge;         begin end;
function  IsBridgeRunning: Boolean; begin Result := FALSE; end;

{$ENDIF}


initialization

finalization
{$IFDEF AUTOPILOT}
  if GWorker <> NIL then
    StopBridge;
  if GLock <> NIL then
    FreeAndNil(GLock);
{$ENDIF}


end.
