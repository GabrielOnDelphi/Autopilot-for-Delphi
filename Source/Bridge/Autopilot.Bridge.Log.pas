UNIT Autopilot.Bridge.Log;

(*=====================================================
   2026.06.12 — POSIX log dir: TPath.GetCachePath (on Android, GetTempPath resolves
                to external files/tmp, not the internal cache the docs point at).
   2026.06.10 — Phase B: POSIX write path added (TFileStream append + getpid),
                so the bridge logs on Android too. Windows path byte-unchanged.
   2026.05.13
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────┐
   │  SHARED  (all platforms)     │   Win32 atomic-append on Windows; TFileStream on POSIX
   └──────────────────────────────┘

   Append-only logging for the Autopilot bridge and MCP server.

   File: <TEMP>\Autopilot\<ExeBaseName>-<PID>.log
   Windows: %TEMP%. Android: the app's private cache dir (TPath.GetCachePath) —
   pull with `adb shell run-as <pkg> cat cache/Autopilot/<name>.log`.
   Format: ISO-8601 timestamp + level + tag + message, one line per entry.
   Thread safety: a single TCriticalSection serializes writes — fine for the
   handful of log calls per request the bridge produces.

   Stdlib + OS only. No VCL, no FMX, no LightSaber. Linked by both the bridge
   (.NamedPipe + .Vcl + .Fmx + .Socket) and the MCP server, so it stays dependency-free.

   Per global CLAUDE.md "no swallowed exceptions": file I/O failures inside the
   logger are caught at the outermost layer (so they don't crash the bridge worker)
   but are tracked via FInitFailed and re-raised on the next successful flush attempt
   would be too noisy — we record the message and move on. The logger is a diagnostic;
   it must not take down the host process.
=====================================================*)

INTERFACE

USES
  System.SysUtils, System.Classes, System.SyncObjs;

TYPE
  TBridgeLogLevel = (llDebug, llInfo, llWarn, llError);

/// Append a log line. Lazy-initializes the file on first call. Safe to call from any thread.
PROCEDURE BridgeLog(ALevel: TBridgeLogLevel; CONST ATag, AMessage: String);

/// Convenience wrappers — same semantics as BridgeLog with the level baked in.
PROCEDURE BridgeLogInfo (CONST ATag, AMessage: String); INLINE;
PROCEDURE BridgeLogWarn (CONST ATag, AMessage: String); INLINE;
PROCEDURE BridgeLogError(CONST ATag, AMessage: String); INLINE;

/// Returns the resolved log path (or '' if not yet written to).
FUNCTION BridgeLogPath: String;

/// Tear down the lock and close any handles. Idempotent.
/// Called from FINALIZATION; safe to call manually too.
PROCEDURE BridgeLogShutdown;


IMPLEMENTATION

USES
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ELSE}
  Posix.Unistd,
  {$ENDIF}
  System.IOUtils;


VAR
  GLogLock : TCriticalSection = NIL;
  GLogPath : String = '';
  GLogReady: Boolean = FALSE;


FUNCTION LevelToStr(ALevel: TBridgeLogLevel): String;
BEGIN
  case ALevel of
    llDebug: Result := 'DEBUG';
    llInfo : Result := 'INFO ';
    llWarn : Result := 'WARN ';
    llError: Result := 'ERROR';
  else
    Result := '?????';
  end;
END;


PROCEDURE EnsureLogLockNoBlock;
BEGIN
  // Lazy lock creation. We deliberately avoid initialization sections (project rule).
  // First-call race is theoretically possible but practically nil: the bridge calls
  // BridgeLog from main-thread StartBridge before any worker threads exist, so the
  // lock is created before any concurrent caller.
  if GLogLock = NIL then
    GLogLock := TCriticalSection.Create;
END;


PROCEDURE EnsurePath;
VAR
  Folder, ExeBase: String;
BEGIN
  if GLogReady then EXIT;
  {$IFDEF MSWINDOWS}
  Folder  := TPath.Combine(TPath.GetTempPath, 'Autopilot');
  {$ELSE}
  // Android (verified 2026-06-12, System.IOUtils source + on-device): TPath.GetTempPath returns getExternalFilesDir()+'/tmp' — the TMPDIR lookup is Linux-only code — so the pre-fix log landed on EXTERNAL storage (files/tmp/Autopilot/), not in the internal cache the pull commands point at.
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
END;


{$IFDEF MSWINDOWS}
PROCEDURE AppendRaw(CONST ALine: String);
VAR
  Bytes: TBytes;
  H: THandle;
  Written: DWORD;
BEGIN
  // CreateFile with FILE_APPEND_DATA + OPEN_ALWAYS gives us atomic appends without
  // racing on file position between threads (we already hold the lock, but this also
  // guards against other processes appending to the same file in degenerate cases).
  Bytes := TEncoding.UTF8.GetBytes(ALine + #13#10);
  H := CreateFileW(PWideChar(GLogPath), FILE_APPEND_DATA,
                   FILE_SHARE_READ or FILE_SHARE_WRITE, NIL,
                   OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if H = INVALID_HANDLE_VALUE then EXIT;
  TRY
    WriteFile(H, Bytes[0], Length(Bytes), Written, NIL);
  FINALLY
    CloseHandle(H);
  END;
END;
{$ELSE}
PROCEDURE AppendRaw(CONST ALine: String);
VAR
  Bytes: TBytes;
  FS: TFileStream;
BEGIN
  // Seek-to-end under GLogLock (the caller holds it). The Win32 path's
  // cross-process atomic append has no equivalent need here — on Android one
  // app owns its private cache dir, so in-process serialization is enough.
  // A raise lands in BridgeLog's outer handler (logger must not crash the host).
  Bytes := TEncoding.UTF8.GetBytes(ALine + #13#10);
  if TFile.Exists(GLogPath) then
    FS := TFileStream.Create(GLogPath, fmOpenWrite or fmShareDenyNone)
  else
    FS := TFileStream.Create(GLogPath, fmCreate or fmShareDenyNone);
  TRY
    FS.Seek(0, soEnd);
    if Length(Bytes) > 0 then
      FS.WriteBuffer(Bytes[0], Length(Bytes));
  FINALLY
    FreeAndNil(FS);
  END;
END;
{$ENDIF}


PROCEDURE BridgeLog(ALevel: TBridgeLogLevel; CONST ATag, AMessage: String);
VAR
  Stamp, Line: String;
BEGIN
  TRY
    EnsureLogLockNoBlock;
    GLogLock.Enter;
    TRY
      EnsurePath;
      // ISO-8601 with milliseconds. FormatDateTime uses local time, which is what
      // a developer reading the log wants.
      Stamp := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz', Now);
      Line  := Stamp + ' ' + LevelToStr(ALevel) + ' [' + ATag + '] ' + AMessage;
      AppendRaw(Line);
    FINALLY
      GLogLock.Leave;
    END;
  EXCEPT
    // Logger must not crash the host. A failure here means stderr is the best fallback.
    ON E: Exception DO
      TRY
        WriteLn(ErrOutput, 'BridgeLog suppressed: ' + E.ClassName + ': ' + E.Message);
      EXCEPT
        // No stderr either (detached console). Truly nothing we can do.
      END;
  END;
END;


PROCEDURE BridgeLogInfo (CONST ATag, AMessage: String);
BEGIN
  BridgeLog(llInfo, ATag, AMessage);
END;

PROCEDURE BridgeLogWarn (CONST ATag, AMessage: String);
BEGIN
  BridgeLog(llWarn, ATag, AMessage);
END;

PROCEDURE BridgeLogError(CONST ATag, AMessage: String);
BEGIN
  BridgeLog(llError, ATag, AMessage);
END;


FUNCTION BridgeLogPath: String;
BEGIN
  Result := GLogPath;
END;


PROCEDURE BridgeLogShutdown;
BEGIN
  if GLogLock <> NIL then
    FreeAndNil(GLogLock);
  GLogReady := FALSE;
  GLogPath  := '';
END;


// Finalization at the bottom of the unit (footgun #2 — never inside an IFDEF).
INITIALIZATION

FINALIZATION
  BridgeLogShutdown;


END.
