unit Autopilot.Mcp.Tool.CallMethod;

{=============================================================================================================
   2026.11.14
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - MCP tool: call_method
   - Calls an app command that the target registered with RegisterAutopilotCommand (unit Autopilot.Bridge.Commands).
     Without name: the list of the registered commands with their descriptions.
   - Only a registered command can be called: the bridge looks the name up in its registry, never by RTTI.
   - Built on the non-generic TMCPToolBase: the argument args is a JSON object, which the params-class serializer cannot carry.
     So the schema is built by hand here, and the arguments are checked here with the serializer's rules:
     keys match case-insensitively with '_' ignored, an unknown key or a value of the wrong type raises EArgumentException (the AI gets isError with the message).
   - timeoutMs goes to the bridge (its main-thread wait) and to the pipe; without it the bridge uses its click default, 5000 ms.
   - Runs in Autopilot.Mcp.exe (Windows PC-side MCP server); target may be any platform.
=============================================================================================================}

interface

uses
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base;

type
  TCallMethodTool = class(TMCPToolBase)
  protected
    function BuildSchema: TJSONObject; override;
  public
    constructor Create;
    function Execute(const AArguments: TJSONObject): String; override;
  end;


implementation

uses
  MCPServer.Registration,
  Autopilot.Bridge.Core,
  Autopilot.Mcp.ToolBase;

const
  ParamName    = 'name';
  ParamArgs    = 'args';
  ParamTimeout = 'timeoutms';
  ParamPid     = 'pid';
  ValidParams  = ParamName + ', ' + ParamArgs + ', ' + ParamTimeout + ', ' + ParamPid;

  { 10 minutes: a command may do real work (load a file, run a build), but a typo such as 5000000 must not hang the call for an hour. }
  MaxTimeoutMs = 600000;


constructor TCallMethodTool.Create;
begin
  inherited Create;
  FName := 'call_method';
  FDescription := 'Call a command that the app registered for the AI. Without name: the list of the commands ' + 'with their descriptions - call it first. With name: runs the command on the main thread with args ' + 'and returns its value at result.result. Unknown name: -32001 with the names. The command raised: -32603 ' + 'with the exception class and message. A bridge without call_method answers -32005.';
end;


function NewProp(const AType, ADescription: String): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', AType);
  Result.AddPair('description', ADescription);
end;


function TCallMethodTool.BuildSchema: TJSONObject;
var
  Props: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  Props := TJSONObject.Create;
  Result.AddPair('properties', Props);   // Result owns Props from here on
  Props.AddPair(ParamName,    NewProp('string',  'The command name (case-insensitive). Omit it to list the commands.'));
  Props.AddPair(ParamArgs,    NewProp('object',  'The arguments of the command, as its description gives them.'));
  Props.AddPair(ParamTimeout, NewProp('integer', 'Main-thread wait in ms (default 5000, max 600000). Give more for a slow command.'));
  Props.AddPair(ParamPid,     NewProp('integer', 'Target PID. Needed only when several targets run.'));
end;


{ The same rule as the serializer's NormalizeKey: lower case, '_' ignored. }
function NormalizeKey(const AName: String): String;
begin
  Result := LowerCase(AName).Replace('_', '', [rfReplaceAll]);
end;


procedure RaiseWrongValue(const AParam, AExpected: String; AValue: TJSONValue);
begin
  raise EArgumentException.Create('Parameter "' + AParam + '": expected ' + AExpected + ', got ' + Copy(AValue.ToJSON, 1, 80) + '.');
end;


{ A number, or a text that holds one (the serializer accepts both for an Integer parameter). }
function ReadInteger(const AParam: String; AValue: TJSONValue): Int64;
begin
  if not (AValue is TJSONNumber) and not (AValue is TJSONString)
  then RaiseWrongValue(AParam, 'an integer', AValue);
  if not TryStrToInt64(AValue.Value, Result)
  then RaiseWrongValue(AParam, 'an integer', AValue);
end;


function TCallMethodTool.Execute(const AArguments: TJSONObject): String;
var
  Pair: TJSONPair;
  Key: String;
  V, Parsed: TJSONValue;
  Name: String;
  HasName: Boolean;
  CallArgs: TJSONObject;
  Timeout, Pid: Int64;
  BridgeArgs: TJSONObject;
  PipeTimeout: Cardinal;
begin
  HasName  := FALSE;
  Name     := '';
  CallArgs := NIL;   // owned here until it moves into BridgeArgs
  Timeout  := 0;
  Pid      := 0;
  try
    { # Read and check the arguments }
    if AArguments <> NIL then
      for Pair in AArguments do
        begin
          Key := NormalizeKey(Pair.JsonString.Value);
          V   := Pair.JsonValue;
          if (Key <> ParamName) and (Key <> ParamArgs) and (Key <> ParamTimeout) and (Key <> ParamPid)
          then raise EArgumentException.Create('Unknown parameter "' + Pair.JsonString.Value + '". Valid parameters: ' + ValidParams + '.');
          if V is TJSONNull then Continue;   // null = absent

          if Key = ParamName then
            begin
              if not (V is TJSONString) or (V is TJSONNumber)   // up to Delphi 12 TJSONNumber descends from TJSONString
              then RaiseWrongValue(ParamName, 'a string', V);
              Name    := TJSONString(V).Value;
              HasName := Name <> '';
            end
          else
            if Key = ParamArgs then
              begin
                FreeAndNil(CallArgs);   // a duplicate key: the last one wins
                if V is TJSONObject
                then CallArgs := TJSONObject(V.Clone)
                else
                  if (V is TJSONString) and not (V is TJSONNumber) then
                    begin
                      { Some AI clients send a nested object as its JSON text. }
                      Parsed := TJSONObject.ParseJSONValue(TJSONString(V).Value);
                      if not (Parsed is TJSONObject) then
                        begin
                          FreeAndNil(Parsed);
                          RaiseWrongValue(ParamArgs, 'a JSON object', V);
                        end;
                      CallArgs := TJSONObject(Parsed);
                    end
                  else RaiseWrongValue(ParamArgs, 'a JSON object', V);
              end
            else
              if Key = ParamTimeout then
                begin
                  Timeout := ReadInteger(ParamTimeout, V);
                  if (Timeout < 0) or (Timeout > MaxTimeoutMs)
                  then RaiseWrongValue(ParamTimeout, 'a number of ms from 0 to ' + IntToStr(MaxTimeoutMs), V);
                end
              else
                begin
                  Pid := ReadInteger(ParamPid, V);
                  if (Pid < 0) or (Pid > High(Cardinal))
                  then RaiseWrongValue(ParamPid, 'a process id', V);
                end;
        end;

    if not HasName and (CallArgs <> NIL)
    then raise EArgumentException.Create('Parameter "args" needs "name": without a name call_method only lists the commands.');

    { # Send }
    BridgeArgs := TJSONObject.Create;
    if HasName
    then BridgeArgs.AddPair(ParamName, Name);
    if CallArgs <> NIL then
      begin
        BridgeArgs.AddPair(ParamArgs, CallArgs);   // BridgeArgs owns it from here on
        CallArgs := NIL;
      end;

    if Timeout > 0
    then PipeTimeout := Cardinal(Timeout)
    else PipeTimeout := DefaultTimeoutClickMs;
    { BuildRequest takes BridgeArgs; RunCommandOnTarget frees the request. }
    Result := RunCommandOnTarget(Cardinal(Pid), BuildRequest(1, 'call_method', BridgeArgs, Cardinal(Timeout)), PipeTimeout);
  finally
    FreeAndNil(CallArgs);
  end;
end;


initialization
  TMCPRegistry.RegisterTool('call_method',
    function: IMCPTool
    begin
      Result := TCallMethodTool.Create;
    end
  );


end.
