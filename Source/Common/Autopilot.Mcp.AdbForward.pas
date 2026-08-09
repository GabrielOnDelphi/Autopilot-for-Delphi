UNIT Autopilot.Mcp.AdbForward;

(*=====================================================
   2026.06.04
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────────────┐
   │  WINDOWS  (PC-side, adb wrapper)     │   sets up the USB tunnel to an Android target
   └──────────────────────────────────────┘

   Thin wrapper over the Android platform-tools `adb forward` command.

   `adb forward tcp:<hostPort> <deviceEndpoint>` tunnels a HOST loopback port
   over USB to a listener inside the app on the device. The MCP server then
   connects to 127.0.0.1:<hostPort> (via Autopilot.Mcp.SocketClient) and adb
   relays the bytes to the device-side bridge.

   Argument order is LOCAL REMOTE (host first) — verified against
   developer.android.com/tools/adb ("forwards requests on a specific host port
   to a different port on a device", example `adb forward tcp:6100 tcp:7100`).

   DEVICE ENDPOINT FORMS:
     - tcp:<devicePort>         -- the SAFE, fully-documented form. Default here.
     - localabstract:<name>     -- AF_UNIX abstract socket. The plan PREFERS this
                                   (no INTERNET permission, self-cleaning), and the
                                   Chrome DevTools tunnel uses exactly this form
                                   (`adb forward tcp:9222 localabstract:chrome_devtools_remote`).
                                   VERIFIED valid for `forward` (2026-06-04): the
                                   `forward [--no-rebind] LOCAL REMOTE` block of the
                                   platform-tools-37 `adb --help` bundled with D13 lists
                                   both `tcp:<port>` and `localabstract:<name>`. (An earlier
                                   AOSP man-page read wrongly placed it under `reverse` only.)
                                   Still defaults to TCP here because the abstract name needs
                                   the Phase-B device bridge to actually bind it.

   The forward DIES on device disconnect / `adb kill-server`, but SURVIVES the
   app restarting (it binds to the device transport, not the app process). So
   Ensure* is safe + cheap to re-run on every attach.

   PHASE A: this compiles and the adb invocation is real, but it only matters
   once the device-side bridge listens (Phase B) and a phone is attached. No
   automated test here — shelling out to a real adb needs a device. See
   " Plans\05_AndroidTransport.md".

   No VCL, no FMX, no LightSaber. Stdlib + Win32 only.
=====================================================*)

INTERFACE

USES
  Winapi.Windows,
  System.SysUtils, System.Classes;

TYPE
  /// Which device-side endpoint form to forward to.
  TAdbRemoteKind = (rkTcp, rkLocalAbstract);

  /// Outcome of an adb invocation.
  TAdbResult = RECORD
    Success  : Boolean;
    ExitCode : Cardinal;
    Output   : String;    // combined stdout+stderr (for diagnostics / logging)
  END;


/// Locate the adb executable: PATH first, then %ANDROID_HOME%\platform-tools,
/// then %ANDROID_SDK_ROOT%\platform-tools. Returns '' if not found.
FUNCTION FindAdb: String;

/// Build the REMOTE (device-side) endpoint spec string for `adb forward`.
///   rkTcp           -> 'tcp:<DeviceSpec>'            (DeviceSpec is the port number)
///   rkLocalAbstract -> 'localabstract:<DeviceSpec>'  (DeviceSpec is the abstract name)
FUNCTION BuildRemoteSpec(AKind: TAdbRemoteKind; CONST ADeviceSpec: String): String;

/// Run `adb forward tcp:<AHostPort> <ARemoteSpec>`. Re-runnable (idempotent at the
/// adb level — re-forwarding the same host port just rebinds it). Returns the result;
/// does NOT raise on a non-zero adb exit (caller inspects .Success), but DOES raise if
/// adb can't be found or the process can't be launched.
FUNCTION EnsureForward(AHostPort: Word; CONST ARemoteSpec: String): TAdbResult;

/// Convenience for the common case: forward a host port to a device TCP port.
FUNCTION EnsureForwardTcp(AHostPort, ADevicePort: Word): TAdbResult;

/// Tear down a single forward: `adb forward --remove tcp:<AHostPort>`.
FUNCTION RemoveForward(AHostPort: Word): TAdbResult;


IMPLEMENTATION

USES
  System.IOUtils;


FUNCTION FindAdb: String;

  FUNCTION TryDir(CONST ADir: String): Boolean;
  VAR
    Candidate: String;
  BEGIN
    Result := FALSE;
    if ADir = '' then EXIT;
    Candidate := TPath.Combine(TPath.Combine(ADir, 'platform-tools'), 'adb.exe');
    if TFile.Exists(Candidate) then
    begin
      FindAdb := Candidate;
      Result  := TRUE;
    end;
  END;

VAR
  PathDirs: TArray<String>;
  Dir, Candidate: String;
BEGIN
  Result := '';

  { # On PATH }
  PathDirs := GetEnvironmentVariable('PATH').Split([';']);
  for Dir in PathDirs do
  begin
    if Dir.Trim = '' then Continue;
    Candidate := TPath.Combine(Dir.Trim, 'adb.exe');
    if TFile.Exists(Candidate) then EXIT(Candidate);
  end;

  { # SDK env vars }
  if TryDir(GetEnvironmentVariable('ANDROID_HOME')) then EXIT;
  if TryDir(GetEnvironmentVariable('ANDROID_SDK_ROOT')) then EXIT;
END;


FUNCTION BuildRemoteSpec(AKind: TAdbRemoteKind; CONST ADeviceSpec: String): String;
BEGIN
  case AKind of
    rkTcp           : Result := 'tcp:' + ADeviceSpec;
    rkLocalAbstract : Result := 'localabstract:' + ADeviceSpec;
  else
    raise Exception.Create('BuildRemoteSpec: unknown remote kind');
  end;
END;


// Launch a child process with stdout+stderr captured into a single string.
// Blocking — adb forward returns immediately, so no long wait. Raises if the
// process can't be created (adb missing / not executable).
FUNCTION RunCaptured(CONST AExe, ACmdLine: String; OUT AExitCode: Cardinal): String;
VAR
  Sa        : TSecurityAttributes;
  ReadPipe  : THandle;
  WritePipe : THandle;
  Si        : TStartupInfo;
  Pi        : TProcessInformation;
  FullCmd   : String;
  Buf       : array[0..4095] of Byte;
  Chunk     : TBytes;
  BytesRead : DWORD;
  Acc       : TStringBuilder;
BEGIN
  AExitCode := High(Cardinal);

  Sa := Default(TSecurityAttributes);
  Sa.nLength        := SizeOf(Sa);
  Sa.bInheritHandle := TRUE;

  if not CreatePipe(ReadPipe, WritePipe, @Sa, 0) then
    raise Exception.CreateFmt('CreatePipe failed (code %d)', [GetLastError]);
  TRY
    // The read end must NOT be inherited by the child.
    SetHandleInformation(ReadPipe, HANDLE_FLAG_INHERIT, 0);

    Si := Default(TStartupInfo);
    Si.cb         := SizeOf(Si);
    Si.dwFlags    := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
    Si.wShowWindow:= SW_HIDE;
    Si.hStdOutput := WritePipe;
    Si.hStdError  := WritePipe;
    Si.hStdInput  := GetStdHandle(STD_INPUT_HANDLE);

    // CreateProcessW may modify the command-line buffer in place — use a UniqueString.
    FullCmd := '"' + AExe + '" ' + ACmdLine;
    UniqueString(FullCmd);

    Pi := Default(TProcessInformation);
    if not CreateProcessW(NIL, PWideChar(FullCmd), NIL, NIL, TRUE,
                          CREATE_NO_WINDOW, NIL, NIL, Si, Pi) then
      raise Exception.CreateFmt('CreateProcess failed for adb (code %d)', [GetLastError]);

    // Close our copy of the write end so ReadFile sees EOF when the child exits.
    CloseHandle(WritePipe);
    WritePipe := 0;

    Acc := TStringBuilder.Create;
    TRY
      // Decode each chunk into a real TBytes. We must NOT cast @Buf[0] to TBytes:
      // TEncoding.GetString(const Bytes: TBytes; ...) calls Length(Bytes), which on
      // a pointer-cast-to-dynarray reads the 8 bytes BEFORE Buf on the stack as the
      // array length — garbage / EEncodingError. SetLength gives a genuine header.
      while ReadFile(ReadPipe, Buf, SizeOf(Buf), BytesRead, NIL) and (BytesRead > 0) do
      begin
        SetLength(Chunk, BytesRead);
        Move(Buf[0], Chunk[0], BytesRead);
        Acc.Append(TEncoding.ANSI.GetString(Chunk));
      end;
      WaitForSingleObject(Pi.hProcess, INFINITE);
      GetExitCodeProcess(Pi.hProcess, AExitCode);
      Result := Acc.ToString;
    FINALLY
      Acc.Free;
      CloseHandle(Pi.hThread);
      CloseHandle(Pi.hProcess);
    END;
  FINALLY
    if WritePipe <> 0 then CloseHandle(WritePipe);
    CloseHandle(ReadPipe);
  END;
END;


FUNCTION RunAdb(CONST AArgs: String): TAdbResult;
VAR
  Adb: String;
BEGIN
  Adb := FindAdb;
  if Adb = '' then
    raise Exception.Create('adb.exe not found. Put it on PATH or set ANDROID_HOME / ANDROID_SDK_ROOT.');
  Result := Default(TAdbResult);
  Result.Output   := RunCaptured(Adb, AArgs, Result.ExitCode);
  Result.Success  := Result.ExitCode = 0;
END;


FUNCTION EnsureForward(AHostPort: Word; CONST ARemoteSpec: String): TAdbResult;
BEGIN
  Result := RunAdb('forward tcp:' + UIntToStr(AHostPort) + ' ' + ARemoteSpec);
END;


FUNCTION EnsureForwardTcp(AHostPort, ADevicePort: Word): TAdbResult;
BEGIN
  Result := EnsureForward(AHostPort, BuildRemoteSpec(rkTcp, UIntToStr(ADevicePort)));
END;


FUNCTION RemoveForward(AHostPort: Word): TAdbResult;
BEGIN
  Result := RunAdb('forward --remove tcp:' + UIntToStr(AHostPort));
END;


END.
