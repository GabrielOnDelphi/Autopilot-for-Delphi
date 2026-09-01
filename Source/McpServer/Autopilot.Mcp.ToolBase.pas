unit Autopilot.Mcp.ToolBase;

{=============================================================================================================
   2026.09.01
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - Shared logic for all Autopilot MCP tools.
   - Resolves the active target pipe from the discovery folder, then runs a single command and returns a
     string response. Each tool is a thin wrapper that builds the request JSON and delegates here.
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
  Autopilot.Mcp.TargetMode,
  Autopilot.Mcp.UsageCounter;


/// Resolve the target pipe. If APid > 0, pick that PID; otherwise expect exactly one active target.
/// Raises if zero or ambiguous.
function ResolveTargetPipe(APid: Cardinal; out APipeName: String): Boolean;

/// Build a request envelope: {id, cmd, args, timeoutMs?}.
/// AArgs is consumed (we hand it to the JSON tree; caller no longer owns it).
/// Pass ATimeoutMs > 0 to add a top-level timeoutMs field — the bridge worker will use it
/// as its main-thread wait timeout instead of the per-command default.
function BuildRequest(AId: Int64; const ACmd: String; AArgs: TJSONObject; ATimeoutMs: Cardinal = 0): TJSONObject;

/// Run a request through the resolved target, return the response as a compact JSON string.
/// Frees the response object internally so callers don't deal with ownership.
/// On nil request raises; on transport failure raises; on bridge-level errors,
/// returns the {ok:false,error:{...}} JSON as a string (the caller can parse if needed).
/// Exception: an I/O-deadline expiry (target accepted the connection but stopped responding —
/// ETargetNotResponding from either transport client) is NOT re-raised; it comes back as the
/// documented {ok:false,error:{code:-32098,message:...}} envelope, same shape as a bridge error.
/// ATimeoutMs governs the pipe-side wait; should be >= any timeoutMs embedded in ARequest
/// so the pipe doesn't time out before the bridge does.
function RunCommandOnTarget(APid: Cardinal; ARequest: TJSONObject; ATimeoutMs: Cardinal = 0): String;


implementation


function ResolveTargetPipe(APid: Cardinal; out APipeName: String): Boolean;
var
  Targets: TTargetList;
  i: Integer;
begin
  APipeName := '';
  Targets := ListTargets;
  if APid <> 0
  then begin
    for i := 0 to High(Targets) do
      if Targets[i].Pid = APid
      then begin
        APipeName := Targets[i].PipeName;
        EXIT(TRUE);
      end;
    raise Exception.CreateFmt('No bridge for pid %d. Is the target app running with AUTOPILOT on?', [APid]);
  end;
  if Length(Targets) = 0
  then raise Exception.Create('No active Autopilot target found. Start a target app linked to Autopilot.Bridge.Vcl.');
  if Length(Targets) > 1
  then raise Exception.CreateFmt('%d targets active; call attach(pid) first to pick one.', [Length(Targets)]);
  APipeName := Targets[0].PipeName;
  Result := TRUE;
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


// The ErrTargetNotResponding envelope, byte-compatible with SerializeResponse's error
// shape, so tools (and the AI) see the same {ok:false,error:{code,message}} contract
// whether the error came from the bridge or from the MCP-side I/O deadline.
function BuildNotRespondingEnvelope(ARequest: TJSONObject; const AMessage: String): String;
var
  Root, ErrObj: TJSONObject;
  IdVal: Int64;
begin
  if not TryJsonInt64(ARequest.GetValue('id'), IdVal) then IdVal := 0;
  Root := TJSONObject.Create;
  try
    Root.AddPair('id', TJSONNumber.Create(IdVal));
    Root.AddPair('ok', TJSONBool.Create(False));
    ErrObj := TJSONObject.Create;
    Root.AddPair('error', ErrObj);   // attach before filling so Root owns it from here on
    ErrObj.AddPair('code', TJSONNumber.Create(ErrTargetNotResponding));
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
  if ARequest = nil then
    raise Exception.Create('RunCommandOnTarget: ARequest is nil');
  CmdName := '?';
  CmdValue := ARequest.GetValue('cmd');
  if CmdValue is TJSONString
  then CmdName := TJSONString(CmdValue).Value;
  try
    if ATimeoutMs > 0
    then PipeTimeout := ATimeoutMs
    else PipeTimeout := DefaultTimeoutClickMs;

    // Transport selection. Default (tmPipe) is the original Windows path, byte
    // for byte. tmAdbSocket (set by `--target adb:<port>`) reaches an Android
    // target over the adb-forwarded loopback port — no pipe, no discovery file.
    if CurrentTargetMode = tmAdbSocket
    then begin
      BridgeLogInfo('mcp', 'in  cmd=' + CmdName + ' adb-socket port=' + IntToStr(AdbHostPort) +
                            ' timeoutMs=' + IntToStr(PipeTimeout));
      T0 := GetTickCount64;
      try
        Resp := CallTargetSocket(AdbHostPort, ARequest, PipeTimeout);
      except
        on E: ETargetNotResponding do
        begin
          BridgeLogError('mcp', 'cmd=' + CmdName + ' target-not-responding (adb-socket): ' + E.Message);
          Exit(BuildNotRespondingEnvelope(ARequest, E.Message));   // outer finally still frees ARequest
        end;
        on E: Exception do
        begin
          BridgeLogError('mcp', 'cmd=' + CmdName + ' transport-fail (adb-socket): ' + E.ClassName + ': ' + E.Message);
          raise;
        end;
      end;
    end
    else begin
      ResolveTargetPipe(APid, PipeName);
      BridgeLogInfo('mcp', 'in  cmd=' + CmdName + ' pid=' + IntToStr(APid) +
                            ' timeoutMs=' + IntToStr(PipeTimeout));
      T0 := GetTickCount64;
      try
        Resp := CallTarget(PipeName, ARequest, PipeTimeout);
      except
        on E: ETargetNotResponding do
        begin
          BridgeLogError('mcp', 'cmd=' + CmdName + ' target-not-responding: ' + E.Message);
          Exit(BuildNotRespondingEnvelope(ARequest, E.Message));   // outer finally still frees ARequest
        end;
        on E: Exception do
        begin
          BridgeLogError('mcp', 'cmd=' + CmdName + ' transport-fail: ' + E.ClassName + ': ' + E.Message);
          raise;
        end;
      end;
    end;
    try
      // The very first successful tool call on this machine carries the licence reminder.
      // It rides an extra top-level field rather than the log file the old nudge used, because
      // a tool response is the one place the driving AI is guaranteed to read. Every documented
      // field is untouched and JSON parsers ignore unknown keys, so the envelope contract holds.
      // Success path only: a target that never answered has no response to attach it to, and
      // ClaimLicenseNotice would then have burnt the one-shot flag on nobody.
      if ClaimLicenseNotice
      then Resp.AddPair('licenseNotice', LicenseNoticeText);

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
