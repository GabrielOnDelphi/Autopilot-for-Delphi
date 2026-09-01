unit Autopilot.Bridge.Log;

{=============================================================================================================
   2026.09
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - Append-only file logger for the Autopilot bridge and MCP server (all platforms)
   - Windows: Win32 atomic-append via FILE_APPEND_DATA; Android/POSIX: TFileStream + seek-to-end
   - Log file: %TEMP%\Autopilot\<ExeBase>-<PID>.log (Windows) or GetCachePath\Autopilot\... (Android)
=============================================================================================================}

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs;

type
  TBridgeLogLevel = (llDebug, llInfo, llWarn, llError);

/// Append a log line. Lazy-initializes the file on first call. Safe to call from any thread.
procedure BridgeLog(ALevel: TBridgeLogLevel; const ATag, AMessage: String);

/// Convenience wrappers — same semantics as BridgeLog with the level baked in.
procedure BridgeLogInfo (const ATag, AMessage: String); inline;
procedure BridgeLogWarn (const ATag, AMessage: String); inline;
procedure BridgeLogError(const ATag, AMessage: String); inline;

/// Returns the resolved log path (or '' if not yet written to).
function BridgeLogPath: String;

/// Tear down the lock and close any handles. Idempotent.
/// Called from finalization; safe to call manually too.
procedure BridgeLogShutdown;


implementation

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ELSE}
  Posix.Unistd,
  {$ENDIF}
  System.IOUtils;


var
  GLogLock : TCriticalSection = NIL;
  GLogPath : String = '';
  GLogReady: Boolean = FALSE;


function LevelToStr(ALevel: TBridgeLogLevel): String;
begin
  case ALevel of
    llDebug: Result := 'DEBUG';
    llInfo : Result := 'INFO ';
    llWarn : Result := 'WARN ';
    llError: Result := 'ERROR';
  else
    Result := '?????';
  end;
end;


procedure EnsureLogLockNoBlock;
begin
  // Lazy lock creation. We deliberately avoid initialization sections (project rule).
  // First-call race is theoretically possible but practically nil: the bridge calls
  // BridgeLog from main-thread StartBridge before any worker threads exist, so the
  // lock is created before any concurrent caller.
  if GLogLock = NIL then
    GLogLock := TCriticalSection.Create;
end;


procedure EnsurePath;
var
  Folder, ExeBase: String;
begin
  if GLogReady then exit;
  {$IFDEF MSWINDOWS}
  Folder  := TPath.Combine(TPath.GetTempPath, 'Autopilot');
  {$ELSE}
  // Android (verified 2026-06-12, System.IOUtils source + on-device): TPath.GetTempPath returns getExternalFilesDir()+'/tmp' — the TMPDIR lookup is Linux-only code — so the pre-fix log landed on external storage (files/tmp/Autopilot/), not in the internal cache the pull commands point at.
  // TPath.GetCachePath = getCacheDir(): internal app cache, always present, matches `run-as <pkg> cat cache/Autopilot/<file>.log`.
  Folder  := TPath.Combine(TPath.GetCachePath, 'Autopilot');
  {$ENDIF}
  if not TDirectory.Exists(Folder) then
    TDirectory.CreateDirectory(Folder);
  ExeBase := TPath.GetFileNameWithoutExtension(ParamStr(0));
  {$IFDEF MSWINDOWS}
  GLogPath := TPath.Combine(Folder, ExeBase + '-' + IntToStr(GetCurrentProcessId) + '.log');
  {$ELSE}
  GLogPath := TPath.Combine(Folder, ExeBase + '-' + IntToStr(getpid) + '.log');
  {$ENDIF}
  GLogReady := TRUE;
end;


{$IFDEF MSWINDOWS}
procedure AppendRaw(const ALine: String);
var
  Bytes: TBytes;
  H: THandle;
  Written: DWORD;
begin
  // CreateFile with FILE_APPEND_DATA + OPEN_ALWAYS gives us atomic appends without
  // racing on file position between threads (we already hold the lock, but this also
  // guards against other processes appending to the same file in degenerate cases).
  Bytes := TEncoding.UTF8.GetBytes(ALine + #13#10);
  H := CreateFileW(PWideChar(GLogPath), FILE_APPEND_DATA,
                   FILE_SHARE_READ or FILE_SHARE_WRITE, NIL,
                   OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if H = INVALID_HANDLE_VALUE then exit;
  try
    WriteFile(H, Bytes[0], Length(Bytes), Written, NIL);
  finally
    CloseHandle(H);
  end;
end;
{$ELSE}
procedure AppendRaw(const ALine: String);
var
  Bytes: TBytes;
  FS: TFileStream;
begin
  // Seek-to-end under GLogLock (the caller holds it). The Win32 path's
  // cross-process atomic append has no equivalent need here — on Android one
  // app owns its private cache dir, so in-process serialization is enough.
  // A raise lands in BridgeLog's outer handler (logger must not crash the host).
  Bytes := TEncoding.UTF8.GetBytes(ALine + #13#10);
  if TFile.Exists(GLogPath) then
    FS := TFileStream.Create(GLogPath, fmOpenWrite or fmShareDenyNone)
  else
    FS := TFileStream.Create(GLogPath, fmCreate or fmShareDenyNone);
  try
    FS.Seek(0, soEnd);
    if Length(Bytes) > 0 then
      FS.WriteBuffer(Bytes[0], Length(Bytes));
  finally
    FreeAndNil(FS);
  end;
end;
{$ENDIF}


procedure BridgeLog(ALevel: TBridgeLogLevel; const ATag, AMessage: String);
var
  Stamp, Line: String;
begin
  try
    EnsureLogLockNoBlock;
    GLogLock.Enter;
    try
      EnsurePath;
      // ISO-8601 with milliseconds. FormatDateTime uses local time, which is what
      // a developer reading the log wants.
      Stamp := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz', Now);
      Line  := Stamp + ' ' + LevelToStr(ALevel) + ' [' + ATag + '] ' + AMessage;
      AppendRaw(Line);
    finally
      GLogLock.Leave;
    end;
  except
    // Logger must not crash the host. A failure here means stderr is the best fallback.
    on E: Exception do
      try
        WriteLn(ErrOutput, 'BridgeLog suppressed: ' + E.ClassName + ': ' + E.Message);
      except
        // No stderr either (detached console). Truly nothing we can do.
      end;
  end;
end;


procedure BridgeLogInfo (const ATag, AMessage: String);
begin
  BridgeLog(llInfo, ATag, AMessage);
end;

procedure BridgeLogWarn (const ATag, AMessage: String);
begin
  BridgeLog(llWarn, ATag, AMessage);
end;

procedure BridgeLogError(const ATag, AMessage: String);
begin
  BridgeLog(llError, ATag, AMessage);
end;


function BridgeLogPath: String;
begin
  Result := GLogPath;
end;


procedure BridgeLogShutdown;
begin
  if GLogLock <> NIL then
    FreeAndNil(GLogLock);
  GLogReady := FALSE;
  GLogPath  := '';
end;


// Finalization at the bottom of the unit (footgun #2 — never inside an IFDEF).
initialization

finalization
  BridgeLogShutdown;


end.
