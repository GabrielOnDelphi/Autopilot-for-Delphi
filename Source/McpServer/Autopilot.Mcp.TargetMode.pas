UNIT Autopilot.Mcp.TargetMode;

(*=====================================================
   2026.06.04
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────────────┐
   │  WINDOWS  (PC-side MCP server)       │   selects pipe (Windows target) vs adb socket (Android target)
   └──────────────────────────────────────┘

   Holds the MCP server's target transport mode, parsed ONCE from the command
   line at startup (Autopilot.Mcp.dpr) and read by Autopilot.Mcp.ToolBase when
   it routes each command.

   Default (no flag) = tmPipe — the existing Windows named-pipe path, unchanged.
   `--target adb:<hostPort>`  = tmAdbSocket — connect to 127.0.0.1:<hostPort>,
   which `adb forward` has tunnelled to the device-side bridge.

   Why a flag and not auto-discovery: there is no on-device discovery file (the
   Android sandbox has no shared %TEMP%), so the AI host must tell us the host
   port explicitly. See " Plans\05_AndroidTransport.md" → "MCP-server side".

   Stdlib only.
=====================================================*)

INTERFACE

TYPE
  TTargetMode = (tmPipe, tmAdbSocket);

/// Parse the process command line for `--target adb:<port>`. Call once at startup.
/// Absent or unrecognised → leaves the default (tmPipe). Returns TRUE if a valid
/// `--target adb:<port>` was found and applied.
FUNCTION ParseTargetModeFromCmdLine: Boolean;

/// The resolved mode. tmPipe until ParseTargetModeFromCmdLine sets otherwise.
FUNCTION CurrentTargetMode: TTargetMode;

/// The host loopback port for tmAdbSocket (meaningful only when mode = tmAdbSocket).
FUNCTION AdbHostPort: Word;


IMPLEMENTATION

USES
  System.SysUtils;

VAR
  GMode     : TTargetMode = tmPipe;
  GHostPort : Word        = 0;


FUNCTION CurrentTargetMode: TTargetMode;
BEGIN
  Result := GMode;
END;


FUNCTION AdbHostPort: Word;
BEGIN
  Result := GHostPort;
END;


// Accepts the spelling `--target adb:<port>` either as two arguments
// (`--target` `adb:5037`) or one (`--target=adb:5037`). Only the adb form is
// recognised today; an unrecognised --target value leaves the pipe default.
FUNCTION ParseTargetModeFromCmdLine: Boolean;

  // Apply an "adb:<port>" value. Returns TRUE if the port parsed in range.
  FUNCTION ApplyAdbValue(CONST AValue: String): Boolean;
  VAR
    PortStr : String;
    PortVal : Integer;
  BEGIN
    Result := FALSE;
    if not AValue.StartsWith('adb:', TRUE) then EXIT;
    PortStr := AValue.Substring(4).Trim;
    if not TryStrToInt(PortStr, PortVal) then EXIT;
    if (PortVal <= 0) or (PortVal > 65535) then EXIT;
    GMode     := tmAdbSocket;
    GHostPort := Word(PortVal);
    Result    := TRUE;
  END;

VAR
  i   : Integer;
  Arg : String;
BEGIN
  Result := FALSE;
  i := 1;
  while i <= ParamCount do
  begin
    Arg := ParamStr(i);
    if SameText(Arg, '--target') and (i < ParamCount) then
    begin
      Result := ApplyAdbValue(ParamStr(i + 1));
      EXIT;
    end
    else if Arg.StartsWith('--target=', TRUE) then
    begin
      Result := ApplyAdbValue(Arg.Substring(Length('--target=')));
      EXIT;
    end;
    Inc(i);
  end;
END;


END.
