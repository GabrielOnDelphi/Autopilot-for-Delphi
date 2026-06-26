unit Autopilot.Mcp.TargetMode;

{=============================================================================================================
   2026.06
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - Holds the MCP server's target transport mode, parsed once from the command line at startup.
   - Default (no flag) = tmPipe — the existing Windows named-pipe path, unchanged.
   - '--target adb:<hostPort>' = tmAdbSocket — connect to 127.0.0.1:<hostPort>, which 'adb forward' has
     tunnelled to the device-side bridge.
   - Read by Autopilot.Mcp.ToolBase when routing each command.
   - Stdlib only.
=============================================================================================================}

interface

type
  TTargetMode = (tmPipe, tmAdbSocket);

/// Parse the process command line for `--target adb:<port>`. Call once at startup.
/// Absent or unrecognised → leaves the default (tmPipe). Returns TRUE if a valid
/// `--target adb:<port>` was found and applied.
function ParseTargetModeFromCmdLine: Boolean;

/// The resolved mode. tmPipe until ParseTargetModeFromCmdLine sets otherwise.
function CurrentTargetMode: TTargetMode;

/// The host loopback port for tmAdbSocket (meaningful only when mode = tmAdbSocket).
function AdbHostPort: Word;


implementation

uses
  System.SysUtils;

var
  GMode     : TTargetMode = tmPipe;
  GHostPort : Word        = 0;


function CurrentTargetMode: TTargetMode;
begin
  Result := GMode;
end;


function AdbHostPort: Word;
begin
  Result := GHostPort;
end;


// Accepts the spelling `--target adb:<port>` either as two arguments
// (`--target` `adb:5037`) or one (`--target=adb:5037`). Only the adb form is
// recognised today; an unrecognised --target value leaves the pipe default.
function ParseTargetModeFromCmdLine: Boolean;

  // Apply an "adb:<port>" value. Returns TRUE if the port parsed in range.
  function ApplyAdbValue(const AValue: String): Boolean;
  var
    PortStr : String;
    PortVal : Integer;
  begin
    Result := FALSE;
    if not AValue.StartsWith('adb:', TRUE) then EXIT;
    PortStr := AValue.Substring(4).Trim;
    if not TryStrToInt(PortStr, PortVal) then EXIT;
    if (PortVal <= 0) or (PortVal > 65535) then EXIT;
    GMode     := tmAdbSocket;
    GHostPort := Word(PortVal);
    Result    := TRUE;
  end;

var
  i   : Integer;
  Arg : String;
begin
  Result := FALSE;
  i := 1;
  while i <= ParamCount do
    begin
      Arg := ParamStr(i);
      if SameText(Arg, '--target') and (i < ParamCount)
      then EXIT(ApplyAdbValue(ParamStr(i + 1)))
      else
        if Arg.StartsWith('--target=', TRUE)
        then EXIT(ApplyAdbValue(Arg.Substring(Length('--target='))));
      Inc(i);
    end;
end;

end.


