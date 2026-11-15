unit Autopilot.Bridge.Commands;

{=============================================================================================================
   2026.11.15
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - App commands for the AI: the app registers named commands, and the MCP tool call_method calls them by name, with arguments.
     One call replaces a chain of clicks and dialogs (example: a command LoadSpectrum that opens a file and returns its peak count).
   - Only a registered command can be called; never any other method, never by RTTI name.
   - RTL only (no VCL, no FMX): the VCL and the FMX bridge share this unit.
   - Without the define AUTOPILOT the unit still compiles and RegisterAutopilotCommand does nothing, so a Release build has no commands.

   How to use it, in the app (a form's constructor or OnCreate, or a package's Register).
   FMX: never in the .dpr after Application.CreateForm - before Application.Run that call only queues the form, so the form variable is still NIL there.

     uses Autopilot.Bridge.Commands;

     RegisterAutopilotCommand('LoadSpectrum', 'Opens a spectrum file. args: fileName (string). Returns peaks (number).',
       function(AArgs: TJSONObject): TJSONValue
       begin
         LoadSpectrum(AArgs.GetValue<string>('fileName'));
         Result:= TJSONObject.Create(TJSONPair.Create('peaks', TJSONNumber.Create(PeakCount)));
       end);
=============================================================================================================}

interface

uses
  System.SysUtils, System.Classes, System.JSON,
  Autopilot.Bridge.Core;

type
  { The code behind one command.
    AArgs: the "args" object of the call (an empty object when the caller gave none, never NIL).
      The bridge owns it and frees it after the handler returns: never free it, never keep it.
    Result: a JSON value (an object, an array, a string, a number, true/false or TJSONNull); the bridge sends it to the AI as result.result and then frees it.
      NIL is allowed and is sent as null.
      AArgs itself or a value inside it (AArgs.GetValue('text')) is allowed too: the bridge sends a copy and frees nothing of AArgs.
      Any other value must be NEW: never return a value that something else owns or frees.
      A NEW result that holds AArgs, a value inside it or one of its pairs (Result.AddPair('x', AArgs.GetValue('y'))) is caught too:
      the bridge sends a copy of the whole result, frees the original without those nodes, and logs a warning.
      Putting a copy in yourself costs less and logs nothing: Result.AddPair('x', TJSONValue(AArgs.GetValue('y').Clone)).
    To report a failure, raise: the AI gets -32603 with the exception class and message.
    Runs on the main thread, inside the bridge's main-thread wait (default 5000 ms, the caller's timeoutMs when given), so the handler may touch the VCL or FMX. }
  TAutopilotCommandHandler = reference to function(AArgs: TJSONObject): TJSONValue;

{ Registers a command that the MCP tool call_method can call by AName.
  ADescription: one or two sentences for the AI - what the command does, its arguments and its result. call_method without a name lists it.
  Names match case-insensitively; registering a name again replaces its description and handler.
  Call it from the main thread (a FormCreate, the .dpr, a package's Register).
  Does nothing when AUTOPILOT is not defined. }
procedure RegisterAutopilotCommand(const AName, ADescription: String; const AHandler: TAutopilotCommandHandler);

{ Removes the command AName (case-insensitive). An unknown name is ignored.
  Call it from the main thread, for example before the form that the handler uses is freed.
  Does nothing when AUTOPILOT is not defined. }
procedure UnregisterAutopilotCommand(const AName: String);

{ The bridge command call_method. Called by Autopilot.Bridge.Vcl and Autopilot.Bridge.Fmx on the main thread; the app never calls it.
  args.name absent or '': the list of the registered commands, sorted by name, with their descriptions.
  args.name a registered command: runs its handler with args.args.
  Errors: -32600 for a name that is not a string or an args that is not an object, -32001 for an unknown name (the message lists the names), -32603 when the handler raises. }
function HandleCallMethod(const AReq: TBridgeRequest): TBridgeResponse;


implementation

uses
  System.Generics.Collections,   // inlines TJSONObject.Count/Pairs and TJSONArray.Count/Items
  Autopilot.Bridge.Log;

{$IFDEF AUTOPILOT}

type
  TCommandEntry = record
    Name       : String;
    Description: String;
    Handler    : TAutopilotCommandHandler;
  end;

  { The registered commands, sorted by name (CompareText).
    A class var instead of a unit variable, and no finalization section: the array and the handler references in it are released when the unit is finalized. }
  TCommandRegistry = class
  strict private
    class var FEntries: TArray<TCommandEntry>;
  public
    class function  IndexOf(const AName: String): Integer;
    class procedure AddOrReplace(const AEntry: TCommandEntry);
    class procedure Remove(const AName: String);
    class function  Entries: TArray<TCommandEntry>;
  end;


class function TCommandRegistry.IndexOf(const AName: String): Integer;
var
  i: Integer;
begin
  for i := 0 to High(FEntries) do
    if SameText(FEntries[i].Name, AName) then EXIT(i);
  Result := -1;
end;


class procedure TCommandRegistry.AddOrReplace(const AEntry: TCommandEntry);
var
  i, At: Integer;
begin
  i := IndexOf(AEntry.Name);
  if i >= 0 then
    begin
      FEntries[i] := AEntry;
      EXIT;
    end;

  At := Length(FEntries);
  for i := 0 to High(FEntries) do
    if CompareText(AEntry.Name, FEntries[i].Name) < 0 then
      begin
        At := i;
        Break;
      end;
  Insert(AEntry, FEntries, At);
end;


class procedure TCommandRegistry.Remove(const AName: String);
var
  i: Integer;
begin
  i := IndexOf(AName);
  if i >= 0
  then Delete(FEntries, i, 1);
end;


class function TCommandRegistry.Entries: TArray<TCommandEntry>;
begin
  Result := FEntries;
end;


procedure RegisterAutopilotCommand(const AName, ADescription: String; const AHandler: TAutopilotCommandHandler);
var
  Entry: TCommandEntry;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'RegisterAutopilotCommand must be called from the main thread');
  if Trim(AName) = ''
  then raise EArgumentException.Create('RegisterAutopilotCommand: the command name is empty');
  if not Assigned(AHandler)
  then raise EArgumentException.Create('RegisterAutopilotCommand: the handler of "' + AName + '" is NIL');

  Entry.Name        := AName;
  Entry.Description := ADescription;
  Entry.Handler     := AHandler;
  TCommandRegistry.AddOrReplace(Entry);
  BridgeLogInfo('bridge', 'command registered: ' + AName);
end;


procedure UnregisterAutopilotCommand(const AName: String);
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'UnregisterAutopilotCommand must be called from the main thread');
  TCommandRegistry.Remove(AName);
end;


function CommandNamesText(const AEntries: TArray<TCommandEntry>): String;
var
  i: Integer;
begin
  if Length(AEntries) = 0
  then EXIT('(none registered; the app registers them with RegisterAutopilotCommand, unit Autopilot.Bridge.Commands)');
  Result := '';
  for i := 0 to High(AEntries) do
    begin
      if i > 0
      then Result := Result + ', ';
      Result := Result + AEntries[i].Name;
    end;
end;


function BuildCommandList(const AEntries: TArray<TCommandEntry>): TJSONObject;
var
  Arr: TJSONArray;
  Item: TJSONObject;
  i: Integer;
begin
  Result := TJSONObject.Create;
  Arr := TJSONArray.Create;
  Result.AddPair('commands', Arr);   // Result owns Arr from here on
  for i := 0 to High(AEntries) do
    begin
      Item := TJSONObject.Create;
      Arr.AddElement(Item);
      Item.AddPair('name', AEntries[i].Name);
      Item.AddPair('description', AEntries[i].Description);
    end;
end;


{ TRUE when ANode is AContainer itself or any node nested in it (pairs, pair names, pair values, array items, at any depth). Pointer compare only. }
function IsPartOf(ANode: TJSONAncestor; AContainer: TJSONValue): Boolean;
var
  i: Integer;
  Pair: TJSONPair;
begin
  if (ANode = NIL) or (AContainer = NIL) then EXIT(FALSE);
  if ANode = AContainer then EXIT(TRUE);
  if AContainer is TJSONObject then
    for i := 0 to TJSONObject(AContainer).Count - 1 do
      begin
        Pair := TJSONObject(AContainer).Pairs[i];
        if (ANode = Pair) or (ANode = Pair.JsonString) or IsPartOf(ANode, Pair.JsonValue) then EXIT(TRUE);
      end
  else
    if AContainer is TJSONArray then
      for i := 0 to TJSONArray(AContainer).Count - 1 do
        if IsPartOf(ANode, TJSONArray(AContainer).Items[i]) then EXIT(TRUE);
  Result := FALSE;
end;


procedure addUnique(ANode: TJSONAncestor; var AList: TArray<TJSONAncestor>);
var
  Known: TJSONAncestor;
begin
  for Known in AList do
    if Known = ANode then EXIT;
  AList := AList + [ANode];
end;


{ Walks the new value AValue and adds to AShared each node that is also a node of AArgs (a pair, a pair name, a pair value, an array item).
  It does not walk into a shared node: everything under it belongs to AArgs too. }
procedure collectShared(AValue: TJSONValue; AArgs: TJSONObject; var AShared: TArray<TJSONAncestor>);
var
  i: Integer;
  Pair: TJSONPair;
  Item: TJSONValue;
begin
  if AValue is TJSONObject then
    for i := 0 to TJSONObject(AValue).Count - 1 do
      begin
        Pair := TJSONObject(AValue).Pairs[i];
        if IsPartOf(Pair, AArgs)
        then addUnique(Pair, AShared)
        else
          begin
            if IsPartOf(Pair.JsonString, AArgs)
            then addUnique(Pair.JsonString, AShared);
            if IsPartOf(Pair.JsonValue, AArgs)
            then addUnique(Pair.JsonValue, AShared)
            else collectShared(Pair.JsonValue, AArgs, AShared);
          end;
      end
  else
    if AValue is TJSONArray then
      for i := 0 to TJSONArray(AValue).Count - 1 do
        begin
          Item := TJSONArray(AValue).Items[i];
          if IsPartOf(Item, AArgs)
          then addUnique(Item, AShared)
          else collectShared(Item, AArgs, AShared);
        end;
end;


{ AValue is a new value that may hold nodes of AArgs (Result.AddPair('x', AArgs.GetValue('y'))): AArgs and AValue would then both free them.
  When it holds any, AValue becomes a deep copy, and the original is freed with the shared nodes marked not owned, so they stay with AArgs alone.
  A value that holds nothing of AArgs is left as it is.
  Call it while AArgs is still alive. }
procedure separateFromArgs(var AValue: TJSONValue; AArgs: TJSONObject);
var
  Shared: TArray<TJSONAncestor>;
  WasOwned: TArray<Boolean>;
  Copied: TJSONValue;
  i: Integer;
begin
  Shared := NIL;
  collectShared(AValue, AArgs, Shared);
  if Length(Shared) = 0 then EXIT;

  BridgeLogWarn('bridge', 'call_method: the result holds ' + IntToStr(Length(Shared)) + ' node(s) of its own args; sending a copy');
  Copied := TJSONValue(AValue.Clone);   // Clone creates every node again, so the copy owns all of them
  SetLength(WasOwned, Length(Shared));
  for i := 0 to High(Shared) do
    begin
      WasOwned[i] := Shared[i].Owned;
      Shared[i].Owned := FALSE;   // the containers of AValue skip a node that is not owned (TJSONObject/TJSONArray/TJSONPair.Destroy)
    end;
  try
    FreeAndNil(AValue);
  finally
    for i := 0 to High(Shared) do
      Shared[i].Owned := WasOwned[i];
  end;
  AValue := Copied;
end;


function HandleCallMethod(const AReq: TBridgeRequest): TBridgeResponse;
var
  NameVal, ArgsVal, Value: TJSONValue;
  Name: String;
  Entries: TArray<TCommandEntry>;
  Entry: TCommandEntry;
  i: Integer;
  CallArgs: TJSONObject;
  OwnArgs: Boolean;
  Wrap: TJSONObject;
begin
  Assert(TThread.CurrentThread.ThreadID = MainThreadID, 'HandleCallMethod must run on the main thread');
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;

  { # Arguments }
  Name := '';
  ArgsVal := NIL;
  if AReq.Args <> NIL then
    begin
      NameVal := AReq.Args.GetValue('name');
      if NameVal <> NIL then
        begin
          if not (NameVal is TJSONString) or (NameVal is TJSONNumber) then   // up to Delphi 12 TJSONNumber descends from TJSONString
            begin
              Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
              Result.ErrorMessage := 'call_method args.name must be a string (got ' + NameVal.ToJSON + ')';
              EXIT;
            end;
          Name := TJSONString(NameVal).Value;
        end;

      ArgsVal := AReq.Args.GetValue('args');
      if (ArgsVal is TJSONNull)
      then ArgsVal := NIL;
      if (ArgsVal <> NIL) and not (ArgsVal is TJSONObject) then
        begin
          Result.Ok := FALSE; Result.ErrorCode := ErrInvalidRequest;
          Result.ErrorMessage := 'call_method args.args must be an object (got ' + ArgsVal.ToJSON + ')';
          EXIT;
        end;
    end;

  Entries := TCommandRegistry.Entries;

  { # No name: the list }
  if Name = '' then
    begin
      Result.Ok := TRUE;
      Result.ResultJson := BuildCommandList(Entries);
      EXIT;
    end;

  i := TCommandRegistry.IndexOf(Name);
  if i < 0 then
    begin
      Result.Ok := FALSE; Result.ErrorCode := ErrNotFound;
      Result.ErrorMessage := 'call_method: no command named "' + Name + '". Commands: ' + CommandNamesText(Entries);
      EXIT;
    end;
  Entry := Entries[i];   // a copy: the handler stays alive even if it unregisters itself

  { # Run the handler }
  if ArgsVal <> NIL
  then
    begin
      CallArgs := TJSONObject(ArgsVal);   // owned by the request
      OwnArgs  := FALSE;
    end
  else
    begin
      CallArgs := TJSONObject.Create;
      OwnArgs  := TRUE;
    end;
  try
    try
      Value := Entry.Handler(CallArgs);
    except
      on E: Exception do
        begin
          BridgeLogError('bridge', 'call_method ' + Entry.Name + ' raised: ' + E.ClassName + ': ' + E.Message);
          Result.Ok := FALSE; Result.ErrorCode := ErrInternalError;
          Result.ErrorMessage := 'call_method ' + Entry.Name + ' raised ' + E.ClassName + ': ' + E.Message;
          EXIT;
        end;
    end;
    { AArgs owns itself and every node inside it (TJSONObject.GetValue returns the pair's own value).
      Freeing such a node with the answer would free it twice: send a copy instead.
      Either the value is a part of AArgs (copy it, free nothing), or it is new and may hold parts of AArgs (separateFromArgs). }
    if Value <> NIL then
      if IsPartOf(Value, CallArgs)
      then Value := TJSONValue(Value.Clone)
      else separateFromArgs(Value, CallArgs);
  finally
    if OwnArgs
    then FreeAndNil(CallArgs);
  end;

  if Value = NIL
  then Value := TJSONNull.Create;
  Wrap := TJSONObject.Create;
  Wrap.AddPair('name', Entry.Name);
  Wrap.AddPair('result', Value);
  Result.Ok := TRUE;
  Result.ResultJson := Wrap;
end;


{$ELSE}   // AUTOPILOT not defined: the interface compiles, nothing is registered.

procedure RegisterAutopilotCommand(const AName, ADescription: String; const AHandler: TAutopilotCommandHandler);
begin
end;


procedure UnregisterAutopilotCommand(const AName: String);
begin
end;


function HandleCallMethod(const AReq: TBridgeRequest): TBridgeResponse;
begin
  Result := Default(TBridgeResponse);
  Result.Id := AReq.Id;
  Result.Ok := FALSE;
  Result.ErrorCode := ErrUnsupportedAction;
  Result.ErrorMessage := 'call_method: this build has no Autopilot bridge (AUTOPILOT is not defined)';
end;

{$ENDIF}


end.
