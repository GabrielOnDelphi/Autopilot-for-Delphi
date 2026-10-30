unit Autopilot.Mcp.AdbForward;

{=============================================================================================================
   2026.09.01
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - Thin wrapper around the `adb forward` command: tunnels a host loopback TCP port over USB to a listener on the Android device.
   - TAdbResult record carries success, exit code, and combined stdout+stderr output.
   - Windows-only (PC side). No VCL, no FMX, no LightSaber. Stdlib + Win32 only.
=============================================================================================================}

interface

uses
  Winapi.Windows,
  System.SysUtils, System.Classes;

type
  /// Which device-side endpoint form to forward to.
  TAdbRemoteKind = (rkTcp, rkLocalAbstract);

  /// Outcome of an adb invocation.
  TAdbResult = record
    Success  : Boolean;
    ExitCode : Cardinal;
    Output   : String;    // combined stdout+stderr (for diagnostics / logging)
  end;


/// Locate the adb executable: PATH first, then %ANDROID_HOME%\platform-tools,
/// then %ANDROID_SDK_ROOT%\platform-tools. Returns '' if not found.
function FindAdb: String;

/// Build the REMOTE (device-side) endpoint spec string for `adb forward`.
///   rkTcp           -> 'tcp:<DeviceSpec>'            (DeviceSpec is the port number)
///   rkLocalAbstract -> 'localabstract:<DeviceSpec>'  (DeviceSpec is the abstract name)
function BuildRemoteSpec(AKind: TAdbRemoteKind; const ADeviceSpec: String): String;

/// Run `adb forward tcp:<AHostPort> <ARemoteSpec>`. Re-runnable (idempotent at the
/// adb level — re-forwarding the same host port just rebinds it). Returns the result;
/// does NOT raise on a non-zero adb exit (caller inspects .Success), but DOES raise if
/// adb can't be found or the process can't be launched.
function EnsureForward(AHostPort: Word; const ARemoteSpec: String): TAdbResult;

/// Convenience for the common case: forward a host port to a device TCP port.
function EnsureForwardTcp(AHostPort, ADevicePort: Word): TAdbResult;

/// Tear down a single forward: `adb forward --remove tcp:<AHostPort>`.
function RemoveForward(AHostPort: Word): TAdbResult;


implementation

uses
  System.IOUtils;


function FindAdb: String;

  function TryDir(const ADir: String): Boolean;
  var
    Candidate: String;
  begin
    Result := False;
    if ADir = '' then Exit;
    Candidate := TPath.Combine(TPath.Combine(ADir, 'platform-tools'), 'adb.exe');
    if TFile.Exists(Candidate) then
    begin
      FindAdb := Candidate;
      Result  := True;
    end;
  end;

var
  PathDirs: TArray<String>;
  Dir, Candidate: String;
begin
  Result := '';

  { # On PATH }
  PathDirs := GetEnvironmentVariable('PATH').Split([';']);
  for Dir in PathDirs do
  begin
    if Dir.Trim = '' then Continue;
    Candidate := TPath.Combine(Dir.Trim, 'adb.exe');
    if TFile.Exists(Candidate) then Exit(Candidate);
  end;

  { # SDK env vars }
  if TryDir(GetEnvironmentVariable('ANDROID_HOME')) then Exit;
  if TryDir(GetEnvironmentVariable('ANDROID_SDK_ROOT')) then Exit;
end;


function BuildRemoteSpec(AKind: TAdbRemoteKind; const ADeviceSpec: String): String;
begin
  case AKind of
    rkTcp           : Result := 'tcp:' + ADeviceSpec;
    rkLocalAbstract : Result := 'localabstract:' + ADeviceSpec;
  else
    raise Exception.Create('BuildRemoteSpec: unknown remote kind');
  end;
end;


// Launch a child process with stdout+stderr captured into a single string.
// Blocking — adb forward returns immediately, so no long wait. Raises if the
// process can't be created (adb missing / not executable).
function RunCaptured(const AExe, ACmdLine: String; out AExitCode: Cardinal): String;
var
  Sa        : TSecurityAttributes;
  ReadPipe  : THandle;
  WritePipe : THandle;
  NulIn     : THandle;
  Si        : TStartupInfo;
  Pi        : TProcessInformation;
  FullCmd   : String;
  Buf       : array[0..4095] of Byte;
  Chunk     : TBytes;
  BytesRead : DWORD;
  Avail     : DWORD;
  DrainDeadline : UInt64;
  Acc       : TStringBuilder;
begin
  AExitCode := High(Cardinal);

  Sa := Default(TSecurityAttributes);
  Sa.nLength        := SizeOf(Sa);
  Sa.bInheritHandle := True;

  NulIn := INVALID_HANDLE_VALUE;
  if not CreatePipe(ReadPipe, WritePipe, @Sa, 0) then
    raise Exception.CreateFmt('CreatePipe failed (code %d)', [GetLastError]);
  try
    // The read end must NOT be inherited by the child.
    SetHandleInformation(ReadPipe, HANDLE_FLAG_INHERIT, 0);

    // The child must NOT inherit our real stdin either: that handle IS the MCP
    // JSON-RPC channel from the AI host, and the long-lived adb SERVER a cold adb
    // run forks would keep holding it (and could read from it, stealing protocol
    // bytes). Hand the child an inheritable NUL handle instead.
    NulIn := CreateFileW('NUL', GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE,
                         @Sa, OPEN_EXISTING, 0, 0);
    if NulIn = INVALID_HANDLE_VALUE then
      raise Exception.CreateFmt('CreateFile(NUL) failed (code %d)', [GetLastError]);

    Si := Default(TStartupInfo);
    Si.cb         := SizeOf(Si);
    Si.dwFlags    := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
    Si.wShowWindow:= SW_HIDE;
    Si.hStdOutput := WritePipe;
    Si.hStdError  := WritePipe;
    Si.hStdInput  := NulIn;

    // CreateProcessW may modify the command-line buffer in place — use a UniqueString.
    FullCmd := '"' + AExe + '" ' + ACmdLine;
    UniqueString(FullCmd);

    Pi := Default(TProcessInformation);
    if not CreateProcessW(nil, PWideChar(FullCmd), nil, nil, True,
                          CREATE_NO_WINDOW, nil, nil, Si, Pi) then
      raise Exception.CreateFmt('CreateProcess failed for adb (code %d)', [GetLastError]);
    try
      // Close our copy of the write end. We must NOT then read to EOF: a cold `adb`
      // invocation forks a long-lived adb SERVER that inherits this (inheritable)
      // write end, so EOF never arrives and a blocking read-to-EOF would hang the
      // single-threaded MCP server forever (documented adb-on-Windows behaviour —
      // robotframework/robotframework#2085). Instead wait for the adb CLIENT to exit
      // (capped, so a wedged adb can't hang us either), then drain the buffered
      // output without blocking via PeekNamedPipe. `adb forward`/`--remove` print at
      // most a short line, far under the pipe buffer, so the client never blocks on a
      // full pipe before exiting.
      CloseHandle(WritePipe);
      WritePipe := 0;

      Acc := TStringBuilder.Create;
      try
        WaitForSingleObject(Pi.hProcess, 30000);   // ms: a cold adb-server start can take seconds; this only bounds a wedged adb
        GetExitCodeProcess(Pi.hProcess, AExitCode);

        // Non-blocking drain of buffered output. We must NOT cast @Buf[0] to TBytes:
        // TEncoding.GetString(const Bytes: TBytes; ...) calls Length(Bytes), which on
        // a pointer-cast-to-dynarray reads the 8 bytes BEFORE Buf on the stack as the
        // array length — garbage / EEncodingError. SetLength gives a genuine header.
        // The deadline caps the loop in case the inherited server fd ever gets chatty.
        DrainDeadline := GetTickCount64 + 2000;
        while (GetTickCount64 < DrainDeadline)
              and PeekNamedPipe(ReadPipe, nil, 0, nil, @Avail, nil) and (Avail > 0) do
        begin
          if Avail > DWORD(SizeOf(Buf)) then Avail := SizeOf(Buf);
          if not (ReadFile(ReadPipe, Buf, Avail, BytesRead, nil) and (BytesRead > 0)) then Break;
          SetLength(Chunk, BytesRead);
          Move(Buf[0], Chunk[0], BytesRead);
          Acc.Append(TEncoding.ANSI.GetString(Chunk));
        end;
        Result := Acc.ToString;
      finally
        Acc.Free;
      end;
    finally
      CloseHandle(Pi.hThread);
      CloseHandle(Pi.hProcess);
    end;
  finally
    if NulIn <> INVALID_HANDLE_VALUE then CloseHandle(NulIn);
    if WritePipe <> 0 then CloseHandle(WritePipe);
    CloseHandle(ReadPipe);
  end;
end;


function RunAdb(const AArgs: String): TAdbResult;
var
  Adb: String;
begin
  Adb := FindAdb;
  if Adb = '' then
    raise Exception.Create('adb.exe not found. Put it on PATH or set ANDROID_HOME / ANDROID_SDK_ROOT.');
  Result := Default(TAdbResult);
  Result.Output   := RunCaptured(Adb, AArgs, Result.ExitCode);
  Result.Success  := Result.ExitCode = 0;
end;


function EnsureForward(AHostPort: Word; const ARemoteSpec: String): TAdbResult;
begin
  Result := RunAdb('forward tcp:' + UIntToStr(AHostPort) + ' ' + ARemoteSpec);
end;


function EnsureForwardTcp(AHostPort, ADevicePort: Word): TAdbResult;
begin
  Result := EnsureForward(AHostPort, BuildRemoteSpec(rkTcp, UIntToStr(ADevicePort)));
end;


function RemoveForward(AHostPort: Word): TAdbResult;
begin
  Result := RunAdb('forward --remove tcp:' + UIntToStr(AHostPort));
end;


end.
