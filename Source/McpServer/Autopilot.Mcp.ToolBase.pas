unit Autopilot.Mcp.ToolBase;

{=============================================================================================================
   2026.11.17
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - Shared logic for all Autopilot MCP tools.
   - Resolves the active target pipe from the discovery folder, then runs a single command and returns a string response.
     Each tool is a thin wrapper that builds the request JSON and delegates here.
   - Tools do not open pipes themselves.
   - Runs in Autopilot.Mcp.exe (Windows PC-side MCP server); target may be any platform.
=============================================================================================================}

interface

uses
  Winapi.Windows,
  System.SysUtils, System.JSON,
  Autopilot.Bridge.Core,
  Autopilot.Bridge.Log,
  Autopilot.Mcp.PipeClient,
  Autopilot.Mcp.SocketClient,
  Autopilot.Mcp.TargetMode;


const
  // Added for the adb transport (--target adb:<port>), where a missing `adb forward` is the other cause.
  AdbTargetHint = 'Android target: the app must run in the foreground on the device with the screen on, and ' + '"adb forward tcp:<port> localabstract:Autopilot.<pid>" must have run after the app started ' + '(the pid changes on every start: "adb shell pidof <package>").';


{ The folder that holds the bridge source, searched relative to AExeFolder (the folder of Autopilot.Mcp.exe):
  '..\Bridge' (the EXE in Source\McpServer\, beside Source\Bridge\), then '..\..\Bridge' (the EXE in the build folder Source\McpServer\Win32_<config>\).
  The folder counts only if Autopilot.Bridge.Vcl.pas is in it.
  Returns the full path without a trailing backslash, or '' when it is not on disk. }
function FindBridgeFolder(const AExeFolder: String): String;

{ How to link the bridge into a Delphi app.
  Sent in every attach answer (field "setup") and inside BridgeWiringRecipe - the moments the AI needs it - instead of in the server instructions, which Claude Code loads into every session (Autopilot.Mcp.JsonRpc.ServerInstructions).
  Step 1 names ABridgeFolder when it is not empty, so the AI does not have to work out where the bridge is.
  AGetItEntry (from FindGetItBridgeEntry) wins over ABridgeFolder: the Library Path already reaches every project, so step 1 then asks for no folder, which would be a second copy of the bridge.
  Every variant also says that a project with the DPM package GabrielMoraru.Autopilot needs no folder: the MCP server cannot see the project, so the AI checks the .dproj. }
function BridgeWiringStepsFor(const ABridgeFolder: String; const AGetItEntry: String = ''): String;

{ The entry of ALibraryPath (a ';'-separated Delphi Library Path) that a GetIt install of the bridge added:
  the first entry that contains 'CatalogRepository' (GetIt's install folder, $(BDSCatalogRepository)) and ends in Source\Bridge, with or without a trailing backslash.
  Returns the entry as written (macros not expanded), or '' when there is none. }
function FindGetItBridgeEntry(const ALibraryPath: String): String;

// BridgeWiringStepsFor the bridge folder found next to this EXE.
function BridgeWiringSteps: String;

// The text of the -32099 target_not_running error, after the line that says what was not found.
function BridgeWiringRecipe: String;

{ Resolve the target pipe.
  If APid > 0, pick that PID; otherwise expect exactly one active target.
  Raises ETargetNotRunning if no target (or none with APid) runs; a plain Exception if several run, whose text is SeveralTargetsMessage. }
function ResolveTargetPipe(APid: Cardinal; out APipeName: String): Boolean;

{ The text of the error when several targets run and no pid was given: one line per target with its pid, EXE name and window captions (FillTargetNames), so the AI can pass the right pid at once. }
function SeveralTargetsMessage(const ATargets: TTargetList): String;

{ Build a request envelope: (id, cmd, args, timeoutMs?).
  AArgs is consumed (we hand it to the JSON tree; caller no longer owns it).
  Pass ATimeoutMs > 0 to add a top-level timeoutMs field — the bridge worker will use it as its main-thread wait timeout instead of the per-command default. }
function BuildRequest(AId: Int64; const ACmd: String; AArgs: TJSONObject; ATimeoutMs: Cardinal = 0): TJSONObject;

{ Run a request through the resolved target, return the response as a compact JSON string.
  Frees the response object internally so callers don't deal with ownership.
  On nil request raises; on transport failure raises; on bridge-level errors, returns the (ok:false,error:(...)) JSON as a string (the caller can parse if needed).
  Exception: an I/O-deadline expiry (target accepted the connection but stopped responding — ETargetNotResponding from either transport client) is NOT re-raised; it comes back as the documented (ok:false,error:(code:-32098,message:...)) envelope, same shape as a bridge error.
  The same holds for ETargetNotRunning (no target at all): it comes back as the -32099 envelope, whose message carries BridgeWiringRecipe.
  ATimeoutMs governs the pipe-side wait; should be >= any timeoutMs embedded in ARequest so the pipe doesn't time out before the bridge does. }
function RunCommandOnTarget(APid: Cardinal; ARequest: TJSONObject; ATimeoutMs: Cardinal = 0): String;


implementation

uses
  System.Classes, System.Win.Registry;

const
  BridgeProbeUnit = 'Autopilot.Bridge.Vcl.pas';
  // In search order: the EXE in Source\McpServer\ (the ZIP packages), then the EXE in the build folder Source\McpServer\Win32_<config>\ (a build of the cloned repository).
  BridgeRelativeFolders: array[0..1] of String = ('..\Bridge', '..\..\Bridge');


function FindBridgeFolder(const AExeFolder: String): String;
var
  Candidate, Relative: String;
begin
  Result := '';
  if AExeFolder = '' then EXIT;
  for Relative in BridgeRelativeFolders do
    begin
      Candidate := ExpandFileName(IncludeTrailingPathDelimiter(AExeFolder) + Relative);
      if FileExists(IncludeTrailingPathDelimiter(Candidate) + BridgeProbeUnit)
      then EXIT(ExcludeTrailingPathDelimiter(Candidate));
    end;
end;


function FindGetItBridgeEntry(const ALibraryPath: String): String;
var
  Entry, Trimmed: String;
begin
  for Entry in ALibraryPath.Split([';']) do
    begin
      Trimmed := ExcludeTrailingPathDelimiter(Trim(Entry));
      if  (Pos('CATALOGREPOSITORY', UpperCase(Trimmed)) > 0)
      and SameText(Copy(Trimmed, Length(Trimmed) - Length('\Source\Bridge') + 1, MaxInt), '\Source\Bridge')
      then EXIT(Trim(Entry));
    end;
  Result := '';
end;


{ The GetIt entry of the bridge in the Win32 Library Path of any Delphi version on this PC, or ''.
  Reads HKCU\Software\Embarcadero\BDS\<version>\Library\Win32, value 'Search Path' (where GetIt's AddOptionPath writes). }
function FindGetItBridgeEntryInRegistry: String;
const
  BdsKey = 'Software\Embarcadero\BDS';
var
  Reg: TRegistry;
  Versions: TStringList;
  Version: String;
begin
  Result := '';
  Reg := TRegistry.Create(KEY_READ);
  Versions := TStringList.Create;
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if not Reg.OpenKeyReadOnly(BdsKey) then EXIT;
    Reg.GetKeyNames(Versions);
    Reg.CloseKey;
    for Version in Versions do
      if Reg.OpenKeyReadOnly(BdsKey + '\' + Version + '\Library\Win32') then
        try
          if Reg.ValueExists('Search Path') then
            begin
              Result := FindGetItBridgeEntry(Reg.ReadString('Search Path'));
              if Result <> '' then EXIT;
            end;
        finally
          Reg.CloseKey;
        end;
  finally
    FreeAndNil(Versions);
    FreeAndNil(Reg);
  end;
end;


function BridgeWiringStepsFor(const ABridgeFolder: String; const AGetItEntry: String): String;
const
  UsesClause = 'add Autopilot.Bridge.Vcl (VCL apps) or Autopilot.Bridge.Fmx (FMX apps) to the .dpr uses clause.';
var
  Where: String;
begin
  if AGetItEntry <> ''
  then Where := 'The bridge is already on the IDE Library Path through GetIt (entry ' + AGetItEntry + '), so every project finds it: ' + 'add no folder to the project search path, only '
  else
  if ABridgeFolder <> ''
  then Where := 'Put the folder ' + ABridgeFolder + ' (the Autopilot bridge source) on the project unit search path, and '
  else Where := 'Put the folder that holds ' + BridgeProbeUnit + ' (the Source\Bridge folder of the Autopilot package; ' + 'the bridge source is public on GitHub: https://github.com/GabrielOnDelphi/Autopilot-for-Delphi) on the project unit search path, and ';
  Result := 'To link the bridge into a Delphi app:' + sLineBreak + '  1. ' + Where + UsesClause + sLineBreak
          + '     DPM: if the .dproj already names the package GabrielMoraru.Autopilot, the bridge is on its search path through $(DPMSearch): ' + 'add no folder, only the uses clause.' + sLineBreak + '  2. Call StartBridge in the .dpr, after the main form is created and before Application.Run.' + sLineBreak + '  3. Add AUTOPILOT to the conditional defines of the DEBUG build configuration only. Without that ' + 'define StartBridge compiles to an empty procedure, so a Release build carries no automation at all.' + sLineBreak + '  4. Rebuild and run the app.';
end;


function BridgeWiringSteps: String;
begin
  Result := BridgeWiringStepsFor(FindBridgeFolder(ExtractFilePath(ParamStr(0))), FindGetItBridgeEntryInRegistry);
end;


function BridgeWiringRecipe: String;
begin
  Result := 'Either the target app is not running (start it, then retry), or it was built without the ' + 'Autopilot bridge. Do not retry before one of the two causes is fixed.' + sLineBreak + BridgeWiringSteps;
end;


function ResolveTargetPipe(APid: Cardinal; out APipeName: String): Boolean;
var
  Targets: TTargetList;
  i: Integer;
begin
  APipeName := '';
  Targets := ListTargets;
  if APid <> 0 then
    begin
      for i := 0 to High(Targets) do
        if Targets[i].Pid = APid then
          begin
            APipeName := Targets[i].PipeName;
            EXIT(TRUE);
          end;
      raise ETargetNotRunning.Create('No Autopilot target with pid ' + UIntToStr(APid) + ' is running.');
    end;
  if Length(Targets) = 0
  then raise ETargetNotRunning.Create('No Autopilot target is running.');
  if Length(Targets) > 1 then
    begin
      FillTargetNames(Targets);
      raise Exception.Create(SeveralTargetsMessage(Targets));
    end;
  APipeName := Targets[0].PipeName;
  Result := TRUE;
end;


function SeveralTargetsMessage(const ATargets: TTargetList): String;
var
  i, c: Integer;
  Line: String;
begin
  Result := IntToStr(Length(ATargets)) + ' Autopilot targets are running. Call this tool again with "pid" set to the one you want:';
  for i := 0 to High(ATargets) do
    begin
      Line := 'pid ' + UIntToStr(ATargets[i].Pid) + ': ';
      if ATargets[i].Exe = ''
      then Line := Line + 'EXE name unknown'
      else Line := Line + ATargets[i].Exe;
      if Length(ATargets[i].Captions) = 0
      then Line := Line + ', no visible window'
      else
        begin
          Line := Line + ', windows';
          for c := 0 to High(ATargets[i].Captions) do
            begin
              if c > 0
              then Line := Line + ',';
              Line := Line + ' "' + ATargets[i].Captions[c] + '"';
            end;
        end;
      Result := Result + sLineBreak + Line;
    end;
end;


function BuildRequest(AId: Int64; const ACmd: String; AArgs: TJSONObject; ATimeoutMs: Cardinal = 0): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(AId));
  Result.AddPair('cmd', ACmd);
  if AArgs <> nil
  then Result.AddPair('args', AArgs)
  else Result.AddPair('args', TJSONObject.Create);
  if ATimeoutMs > 0
  then Result.AddPair('timeoutMs', TJSONNumber.Create(ATimeoutMs));
end;


// An MCP-side error envelope, byte-compatible with SerializeResponse's error shape, so tools (and the AI) see the same {ok:false,error:{code,message}} contract whether the error came from the bridge or from the MCP side (-32098 I/O deadline, -32099 no target).
function BuildErrorEnvelope(ARequest: TJSONObject; ACode: Integer; const AMessage: String): String;
var
  Root, ErrObj: TJSONObject;
  IdVal: Int64;
begin
  if not TryJsonInt64(ARequest.GetValue('id'), IdVal)
  then IdVal := 0;
  Root := TJSONObject.Create;
  try
    Root.AddPair('id', TJSONNumber.Create(IdVal));
    Root.AddPair('ok', TJSONBool.Create(False));
    ErrObj := TJSONObject.Create;
    Root.AddPair('error', ErrObj);   // attach before filling so Root owns it from here on
    ErrObj.AddPair('code', TJSONNumber.Create(ACode));
    ErrObj.AddPair('message', AMessage);
    Result := Root.ToJSON;
  finally
    FreeAndNil(Root);
  end;
end;


function RunCommandOnTarget(APid: Cardinal; ARequest: TJSONObject; ATimeoutMs: Cardinal = 0): String;
var
  PipeName, CmdName: String;
  Resp: TJSONObject;
  PipeTimeout: Cardinal;
  CmdValue: TJSONValue;
  T0: UInt64;
begin
  if ARequest = nil
  then raise Exception.Create('RunCommandOnTarget: ARequest is nil');
  CmdName := '?';
  CmdValue := ARequest.GetValue('cmd');
  if CmdValue is TJSONString
  then CmdName := TJSONString(CmdValue).Value;
  try
    if ATimeoutMs > 0
    then PipeTimeout := ATimeoutMs
    else PipeTimeout := DefaultTimeoutClickMs;

    { Transport selection.
      Default (tmPipe) is the original Windows path, byte for byte.
      tmAdbSocket (set by `--target adb:<port>`) reaches an Android target over the adb-forwarded loopback port — no pipe, no discovery file. }
    if CurrentTargetMode = tmAdbSocket
    then
      begin
        BridgeLogInfo('mcp', 'in  cmd=' + CmdName + ' adb-socket port=' + IntToStr(AdbHostPort) + ' timeoutMs=' + IntToStr(PipeTimeout));
        T0 := GetTickCount64;
        try
          Resp := CallTargetSocket(AdbHostPort, ARequest, PipeTimeout);
        except
          on E: ETargetNotRunning do
            begin
              BridgeLogWarn('mcp', 'cmd=' + CmdName + ' target-not-running (adb-socket): ' + E.Message);
              Exit(BuildErrorEnvelope(ARequest, ErrTargetNotRunning, E.Message + sLineBreak + AdbTargetHint + sLineBreak + BridgeWiringRecipe));
            end;
          on E: ETargetNotResponding do
            begin
              BridgeLogError('mcp', 'cmd=' + CmdName + ' target-not-responding (adb-socket): ' + E.Message);
              Exit(BuildErrorEnvelope(ARequest, ErrTargetNotResponding, E.Message));   // outer finally still frees ARequest
            end;
          on E: Exception do
            begin
              BridgeLogError('mcp', 'cmd=' + CmdName + ' transport-fail (adb-socket): ' + E.ClassName + ': ' + E.Message);
              raise;
            end;
        end;
      end
    else
      begin
        try
          ResolveTargetPipe(APid, PipeName);
        except
          on E: ETargetNotRunning do
            begin
              BridgeLogWarn('mcp', 'cmd=' + CmdName + ' target-not-running: ' + E.Message);
              Exit(BuildErrorEnvelope(ARequest, ErrTargetNotRunning, E.Message + sLineBreak + BridgeWiringRecipe));
            end;
        end;
        BridgeLogInfo('mcp', 'in  cmd=' + CmdName + ' pid=' + IntToStr(APid) + ' timeoutMs=' + IntToStr(PipeTimeout));
        T0 := GetTickCount64;
        try
          Resp := CallTarget(PipeName, ARequest, PipeTimeout);
        except
          on E: ETargetNotResponding do
            begin
              BridgeLogError('mcp', 'cmd=' + CmdName + ' target-not-responding: ' + E.Message);
              Exit(BuildErrorEnvelope(ARequest, ErrTargetNotResponding, E.Message));   // outer finally still frees ARequest
            end;
          on E: Exception do
            begin
              BridgeLogError('mcp', 'cmd=' + CmdName + ' transport-fail: ' + E.ClassName + ': ' + E.Message);
              raise;
            end;
        end;
      end;
    try
      Result := Resp.ToJSON;
      BridgeLogInfo('mcp', 'out cmd=' + CmdName + ' elapsedMs=' + IntToStr(GetTickCount64 - T0));
    finally
      FreeAndNil(Resp);
    end;
  finally
    FreeAndNil(ARequest);
  end;
end;


end.
