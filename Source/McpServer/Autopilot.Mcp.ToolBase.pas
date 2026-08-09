UNIT Autopilot.Mcp.ToolBase;

(*=====================================================
   2026.05.12
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────────────┐
   │  WINDOWS  (PC-side MCP server)       │   runs in Autopilot.Mcp.exe; target may be any platform
   └──────────────────────────────────────┘

   Shared logic for Autopilot MCP tools.

   Resolves the active target pipe from the discovery folder,
   then runs a single command and returns a string response.

   Each tool is a thin wrapper that builds the request JSON and
   delegates to RunCommandOnTarget. Tools don't open pipes themselves.
=====================================================*)

INTERFACE

USES
  Winapi.Windows,
  System.SysUtils, System.JSON,
  Autopilot.Bridge.Core,
  Autopilot.Bridge.Log,
  Autopilot.Mcp.PipeClient,
  Autopilot.Mcp.SocketClient,
  Autopilot.Mcp.TargetMode;


/// Resolve the target pipe. If APid > 0, pick that PID; otherwise expect exactly one active target.
/// Raises if zero or ambiguous.
FUNCTION ResolveTargetPipe(APid: Cardinal; OUT APipeName: String): Boolean;

/// Build a request envelope: {id, cmd, args, timeoutMs?}.
/// AArgs is consumed (we hand it to the JSON tree; caller no longer owns it).
/// Pass ATimeoutMs > 0 to add a top-level timeoutMs field — the bridge worker will use it
/// as its main-thread wait timeout instead of the per-command default.
FUNCTION BuildRequest(AId: Int64; CONST ACmd: String; AArgs: TJSONObject; ATimeoutMs: Cardinal = 0): TJSONObject;

/// Run a request through the resolved target, return the response as a compact JSON string.
/// Frees the response object internally so callers don't deal with ownership.
/// On NIL request raises; on transport failure raises; on bridge-level errors,
/// returns the {ok:false,error:{...}} JSON as a string (the caller can parse if needed).
/// ATimeoutMs governs the pipe-side wait; should be >= any timeoutMs embedded in ARequest
/// so the pipe doesn't time out before the bridge does.
FUNCTION RunCommandOnTarget(APid: Cardinal; ARequest: TJSONObject; ATimeoutMs: Cardinal = 0): String;


IMPLEMENTATION


FUNCTION ResolveTargetPipe(APid: Cardinal; OUT APipeName: String): Boolean;
VAR
  Targets: TTargetList;
  i: Integer;
BEGIN
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
    raise Exception.CreateFmt('No bridge for pid %d. Is the target app running with AUTOPILOT on?', [APid]);
  end;
  if Length(Targets) = 0 then
    raise Exception.Create('No active Autopilot target found. Start a target app linked to Autopilot.Bridge.Vcl.');
  if Length(Targets) > 1 then
    raise Exception.CreateFmt('%d targets active; call attach(pid) first to pick one.', [Length(Targets)]);
  APipeName := Targets[0].PipeName;
  Result := TRUE;
END;


FUNCTION BuildRequest(AId: Int64; CONST ACmd: String; AArgs: TJSONObject; ATimeoutMs: Cardinal = 0): TJSONObject;
BEGIN
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(AId));
  Result.AddPair('cmd', ACmd);
  if AArgs <> NIL then
    Result.AddPair('args', AArgs)
  else
    Result.AddPair('args', TJSONObject.Create);
  if ATimeoutMs > 0 then
    Result.AddPair('timeoutMs', TJSONNumber.Create(ATimeoutMs));
END;


FUNCTION RunCommandOnTarget(APid: Cardinal; ARequest: TJSONObject; ATimeoutMs: Cardinal = 0): String;
VAR
  PipeName, CmdName: String;
  Resp: TJSONObject;
  PipeTimeout: Cardinal;
  CmdValue: TJSONValue;
  T0: UInt64;
BEGIN
  if ARequest = NIL then
    raise Exception.Create('RunCommandOnTarget: ARequest is nil');
  CmdName := '?';
  CmdValue := ARequest.GetValue('cmd');
  if CmdValue IS TJSONString then
    CmdName := TJSONString(CmdValue).Value;
  TRY
    if ATimeoutMs > 0 then
      PipeTimeout := ATimeoutMs
    else
      PipeTimeout := DefaultTimeoutClickMs;

    // Transport selection. Default (tmPipe) is the original Windows path, byte
    // for byte. tmAdbSocket (set by `--target adb:<port>`) reaches an Android
    // target over the adb-forwarded loopback port — no pipe, no discovery file.
    if CurrentTargetMode = tmAdbSocket then
    begin
      BridgeLogInfo('mcp', 'in  cmd=' + CmdName + ' adb-socket port=' + IntToStr(AdbHostPort) +
                            ' timeoutMs=' + IntToStr(PipeTimeout));
      T0 := GetTickCount64;
      TRY
        Resp := CallTargetSocket(AdbHostPort, ARequest, PipeTimeout);
      EXCEPT
        ON E: Exception DO
        BEGIN
          BridgeLogError('mcp', 'cmd=' + CmdName + ' transport-fail (adb-socket): ' + E.ClassName + ': ' + E.Message);
          raise;
        END;
      END;
    end
    else
    begin
      ResolveTargetPipe(APid, PipeName);
      BridgeLogInfo('mcp', 'in  cmd=' + CmdName + ' pid=' + IntToStr(APid) +
                            ' timeoutMs=' + IntToStr(PipeTimeout));
      T0 := GetTickCount64;
      TRY
        Resp := CallTarget(PipeName, ARequest, PipeTimeout);
      EXCEPT
        ON E: Exception DO
        BEGIN
          BridgeLogError('mcp', 'cmd=' + CmdName + ' transport-fail: ' + E.ClassName + ': ' + E.Message);
          raise;
        END;
      END;
    end;
    TRY
      Result := Resp.ToJSON;
      BridgeLogInfo('mcp', 'out cmd=' + CmdName + ' elapsedMs=' + IntToStr(GetTickCount64 - T0));
    FINALLY
      Resp.Free;
    END;
  FINALLY
    ARequest.Free;
  END;
END;


END.
