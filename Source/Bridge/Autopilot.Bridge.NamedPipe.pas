UNIT Autopilot.Bridge.NamedPipe;

{=====================================================
   2026.06.10
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────┐
   │  WINDOWS ONLY                │   (stable / shipped branch)
   └──────────────────────────────┘
   The Win32 named-pipe transport — the first IBridgeTransport.
   The shared session loop lives in Autopilot.Bridge.Worker (extracted
   2026-06-10, Phase B of " Plans\05_AndroidTransport.md"); this unit now
   owns ONLY the Windows-specific pieces:

     - The Win32 named pipe (created with owner-only ACL)
     - The discovery file at %TEMP%\Autopilot\active\<PID>.pipe
     - The shutdown wake (CancelSynchronousIo + self-connect)

   Three pipe quirks are absorbed HERE so the shared worker never sees them
   (contracts documented in Autopilot.Bridge.Transport):
     1. ConnectNamedPipe returning FALSE + ERROR_PIPE_CONNECTED = success.
     2. FILE_FLAG_FIRST_PIPE_INSTANCE: StartListening raises if another
        instance of the same exe already owns the pipe name.
     3. The wake self-connect produces a phantom client: AcceptConnection
        swallows it (FStopping set by WakeAndStop) and returns FALSE.

   Stdlib + Win32 only. No VCL. No FMX. No LightSaber.
=====================================================}

INTERFACE

USES
  Winapi.Windows,
  System.SysUtils, System.Classes,
  Autopilot.Bridge.Transport;

TYPE
  /// Windows named-pipe transport. Owns the pipe handle and the discovery file.
  /// All methods except WakeAndStop run on the bridge worker thread; WakeAndStop
  /// runs on the owner thread (TBridgeWorker.Destroy). The destructor runs after
  /// the worker has been joined, so its backstop cleanup cannot race the worker.
  TPipeTransport = CLASS(TInterfacedObject, IBridgeTransport)
  STRICT PRIVATE
    FPipeName       : String;
    FPipeHandle     : THandle;       // current pipe instance; INVALID_HANDLE_VALUE between client sessions
    FDiscoveryPath  : String;        // %TEMP%\Autopilot\active\<PID>.pipe — empty when not written
    FDiscoveryTried : Boolean;       // the discovery write is attempted ONCE, like the old worker prologue
    FStopping       : Boolean;       // set by WakeAndStop; AcceptConnection swallows the wake phantom off it

    PROCEDURE WriteDiscoveryFile;
    PROCEDURE DeleteDiscoveryFile;
    FUNCTION  CreatePipeInstance: THandle;
  PUBLIC
    /// APipeName: full `\\.\pipe\...` form.
    CONSTRUCTOR Create(CONST APipeName: String);
    DESTRUCTOR Destroy; OVERRIDE;

    { IBridgeTransport }
    PROCEDURE StartListening;
    FUNCTION  AcceptConnection: Boolean;
    FUNCTION  ConnectionStream: TStream;
    PROCEDURE RecycleConnection;
    PROCEDURE WakeAndStop(AWorkerThread: TThread);
    FUNCTION  EndpointLabel: String;
  END;


/// Returns the canonical pipe name for the current process.
/// Form: `\\.\pipe\Autopilot.<ExeBaseName>.<PID>`. Dots not backslashes — Plans/04 D3.
FUNCTION ComputePipeName: String;

/// Returns the discovery folder path. Created on demand.
FUNCTION DiscoveryFolder: String;


IMPLEMENTATION

USES
  System.IOUtils, Winapi.AccCtrl,
  Autopilot.Bridge.Log;


{ Win32 imports not in Winapi.Windows ---------------------------------- }

CONST
  AdvApi32 = 'advapi32.dll';
  SDDL_REVISION_1 = 1;

FUNCTION ConvertStringSecurityDescriptorToSecurityDescriptorW(
  StringSecurityDescriptor: PWideChar;
  StringSDRevision: DWORD;
  OUT SecurityDescriptor: PSecurityDescriptor;
  SecurityDescriptorSize: PCardinal): BOOL; STDCALL;
  EXTERNAL AdvApi32 NAME 'ConvertStringSecurityDescriptorToSecurityDescriptorW';

FUNCTION ConvertSidToStringSidW(Sid: PSID; OUT StringSid: PWideChar): BOOL; STDCALL;
  EXTERNAL AdvApi32 NAME 'ConvertSidToStringSidW';


// Look up the current process token's User SID and return it as an SDDL-friendly string.
// Result is empty on failure; the caller must fall back to a default ACL.
// The Windows StringSid returned by ConvertSidToStringSid is freed via LocalFree.
FUNCTION GetCurrentUserSidString: String;
VAR
  Token: THandle;
  Needed: DWORD;
  Buffer: TBytes;
  TokenUserInfo: PTokenUser;
  StringSid: PWideChar;
BEGIN
  Result := '';
  if not OpenProcessToken(GetCurrentProcess, TOKEN_QUERY, Token) then EXIT;
  TRY
    // First call to size the buffer.
    Needed := 0;
    GetTokenInformation(Token, TokenUser, NIL, 0, Needed);
    if Needed = 0 then EXIT;
    SetLength(Buffer, Needed);
    if not GetTokenInformation(Token, TokenUser, @Buffer[0], Needed, Needed) then EXIT;
    TokenUserInfo := PTokenUser(@Buffer[0]);
    if not ConvertSidToStringSidW(TokenUserInfo^.User.Sid, StringSid) then EXIT;
    TRY
      Result := String(StringSid);
    FINALLY
      LocalFree(HLOCAL(StringSid));
    END;
  FINALLY
    CloseHandle(Token);
  END;
END;


FUNCTION DiscoveryFolder: String;
BEGIN
  Result := TPath.Combine(TPath.GetTempPath, 'Autopilot\active');
  if not TDirectory.Exists(Result) then
    TDirectory.CreateDirectory(Result);
END;


FUNCTION ComputePipeName: String;
VAR
  ExePath, Base: String;
BEGIN
  ExePath := ParamStr(0);
  Base    := TPath.GetFileNameWithoutExtension(ExePath);
  Result  := '\\.\pipe\Autopilot.' + Base + '.' + IntToStr(GetCurrentProcessId);
END;


{ TPipeTransport --------------------------------------------------------- }

CONSTRUCTOR TPipeTransport.Create(CONST APipeName: String);
BEGIN
  inherited Create;
  FPipeName   := APipeName;
  FPipeHandle := INVALID_HANDLE_VALUE;
END;


DESTRUCTOR TPipeTransport.Destroy;
BEGIN
  // Backstop only: the worker's exit paths close the handle themselves (via
  // AcceptConnection's failure branch or RecycleConnection). This fires when the
  // worker died from an unhandled exception that bypassed its own close path.
  // The worker releases the transport AFTER `inherited` (WaitFor) in its own
  // destructor, so this cannot race the worker thread.
  if FPipeHandle <> INVALID_HANDLE_VALUE then
  begin
    DisconnectNamedPipe(FPipeHandle);
    CloseHandle(FPipeHandle);
    FPipeHandle := INVALID_HANDLE_VALUE;
  end;
  DeleteDiscoveryFile;
  inherited;
END;


PROCEDURE TPipeTransport.WriteDiscoveryFile;
VAR
  Folder, Pid, TempPath: String;
  MoveErr: DWORD;
BEGIN
  Folder := DiscoveryFolder;
  Pid := IntToStr(GetCurrentProcessId);
  FDiscoveryPath := TPath.Combine(Folder, Pid + '.pipe');
  // Write atomically: write to a sibling temp file, then MoveFileExW with
  // MOVEFILE_REPLACE_EXISTING. NTFS guarantees the rename is observed
  // atomically by other processes. Without this, the MCP server can read
  // a zero-byte file in the open-truncate-write window of WriteAllText.
  TempPath := FDiscoveryPath + '.tmp';
  TFile.WriteAllText(TempPath, FPipeName, TEncoding.UTF8);
  if not MoveFileExW(PWideChar(TempPath), PWideChar(FDiscoveryPath), MOVEFILE_REPLACE_EXISTING) then
  begin
    // Capture the rename failure code BEFORE the fallback TFile calls — those make
    // their own Win32 calls (DeleteFile / CreateFile) that overwrite GetLastError,
    // so reading it after them would log a misleading (usually 0) code.
    MoveErr := GetLastError;
    // Fall back to a direct write so the bridge stays discoverable even if rename fails.
    TFile.Delete(TempPath);
    TFile.WriteAllText(FDiscoveryPath, FPipeName, TEncoding.UTF8);
    BridgeLogWarn('bridge', 'discovery file atomic rename failed (' + IntToStr(MoveErr) +
                            '); fell back to direct write');
  end;
END;


PROCEDURE TPipeTransport.DeleteDiscoveryFile;
BEGIN
  if (FDiscoveryPath <> '') and TFile.Exists(FDiscoveryPath) then
    TRY
      TFile.Delete(FDiscoveryPath);
    EXCEPT
      // Don't propagate — called from WakeAndStop/destructor paths that must not raise.
      // The MCP server will treat the stale file as a dead target on its next connect attempt.
    END;
  FDiscoveryPath := '';
END;


FUNCTION TPipeTransport.CreatePipeInstance: THandle;
VAR
  UserSid, Sddl: String;
  SD: PSecurityDescriptor;
  SA: TSecurityAttributes;
  SAPtr: PSecurityAttributes;
  LastErr: DWORD;
BEGIN
  // Owner-only ACL: only the current user can connect. The MCP server must run as the
  // same OS user as the target (documented constraint, Plans/04 R7).
  //
  // The earlier attempt with the well-known SID `OW` ("Owner Rights") silently failed
  // because we weren't setting an owner in the descriptor. Pulling the user's actual SID
  // out of the process token and embedding it in the SDDL string works.
  SD     := NIL;
  SAPtr  := NIL;
  UserSid := GetCurrentUserSidString;
  if UserSid <> '' then
  begin
    Sddl := 'D:(A;;GA;;;' + UserSid + ')';
    if ConvertStringSecurityDescriptorToSecurityDescriptorW(PWideChar(Sddl), SDDL_REVISION_1, SD, NIL) then
    begin
      FillChar(SA, SizeOf(SA), 0);
      SA.nLength              := SizeOf(SA);
      SA.lpSecurityDescriptor := SD;
      SA.bInheritHandle       := FALSE;
      SAPtr := @SA;
    end
    else
      // Fall back to default ACL but record why. The bridge stays usable; admins can audit.
      BridgeLogWarn('bridge', 'owner-only SD conversion failed (' + IntToStr(GetLastError) +
                              '); falling back to default ACL');
  end
  else
    BridgeLogWarn('bridge', 'could not resolve current user SID; falling back to default ACL');

  TRY
    Result := CreateNamedPipeW(
                PWideChar(FPipeName),
                PIPE_ACCESS_DUPLEX or FILE_FLAG_FIRST_PIPE_INSTANCE,
                PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT,
                1,                  // max instances — single-client per Plans/01
                64 * 1024,          // out buffer hint
                64 * 1024,          // in buffer hint
                0,                  // default timeout
                SAPtr);
    if Result = INVALID_HANDLE_VALUE then
    begin
      LastErr := GetLastError;
      raise EOSError.Create('CreateNamedPipeW failed: ' + IntToStr(LastErr) + ' (' + SysErrorMessage(LastErr) + ')');
    end;
    if SAPtr <> NIL then
      BridgeLogInfo('bridge', 'pipe ready, ACL restricted to user SID ' + UserSid)
    else
      BridgeLogInfo('bridge', 'pipe ready (default ACL)');
  FINALLY
    if SD <> NIL then
      LocalFree(HLOCAL(SD));
  END;
END;


PROCEDURE TPipeTransport.StartListening;
BEGIN
  // Discovery file is best-effort, attempted ONCE (same as the pre-split worker
  // prologue — written even if pipe creation later fails). If TFile.WriteAllText
  // raises (disk full, permission denied, virus scanner locking the dir), the
  // bridge can still serve clients that already know the pipe name via attach(pid).
  if not FDiscoveryTried then
  begin
    FDiscoveryTried := TRUE;
    TRY
      WriteDiscoveryFile;
    EXCEPT
      ON E: Exception DO
        BridgeLogError('bridge',
          'WriteDiscoveryFile failed: ' + E.ClassName + ': ' + E.Message +
          ' — bridge will not auto-discover; attach(pid) still works');
    END;
  end;

  // (Re-)create a pipe instance for each client session.
  // FILE_FLAG_FIRST_PIPE_INSTANCE on the first call rejects an existing same-named pipe,
  // which is what we want — if another instance of this exe is up, we want to know.
  FPipeHandle := CreatePipeInstance;
END;


FUNCTION TPipeTransport.AcceptConnection: Boolean;
VAR
  Connected: BOOL;
BEGIN
  Connected := ConnectNamedPipe(FPipeHandle, NIL);
  // ConnectNamedPipe returns FALSE with ERROR_PIPE_CONNECTED if a client connected
  // between CreateNamedPipe and ConnectNamedPipe. That's actually success (quirk #1).
  // Returns FALSE with ERROR_OPERATION_ABORTED if WakeAndStop called CancelSynchronousIo.
  if (not Connected) and (GetLastError <> ERROR_PIPE_CONNECTED) then
  begin
    CloseHandle(FPipeHandle);
    FPipeHandle := INVALID_HANDLE_VALUE;
    EXIT(FALSE);
  end;

  // Quirk #3: WakeAndStop self-connects via CreateFileW to unblock us — that produces
  // a successful "connection" that must NOT be handshaken with (raising EReadError on
  // this thread while the main thread concurrently frees handles races the RTL's
  // exception machinery — was AVing in @HandleAnyException, Plans/04). Swallow it.
  if FStopping then
  begin
    DisconnectNamedPipe(FPipeHandle);
    CloseHandle(FPipeHandle);
    FPipeHandle := INVALID_HANDLE_VALUE;
    EXIT(FALSE);
  end;

  Result := TRUE;
END;


FUNCTION TPipeTransport.ConnectionStream: TStream;
BEGIN
  // THandleStream does NOT close the handle; the transport still owns it.
  Result := THandleStream.Create(FPipeHandle);
END;


PROCEDURE TPipeTransport.RecycleConnection;
BEGIN
  if FPipeHandle <> INVALID_HANDLE_VALUE then
  begin
    DisconnectNamedPipe(FPipeHandle);
    CloseHandle(FPipeHandle);
    FPipeHandle := INVALID_HANDLE_VALUE;
  end;
END;


PROCEDURE TPipeTransport.WakeAndStop(AWorkerThread: TThread);
VAR
  WakeClient: THandle;
  Attempts: Integer;
  Err: DWORD;
BEGIN
  // Order matters: FStopping FIRST, so the self-connect below is recognized as a
  // phantom inside AcceptConnection regardless of which wake mechanism lands.
  FStopping := TRUE;

  // Wake the worker. Two cooperating mechanisms cover the small race window where the worker
  // is between CreatePipeInstance and ConnectNamedPipe (CSI is a no-op there) and the larger
  // window where it's blocked inside ConnectNamedPipe:
  //   (1) CSI cancels in-flight sync I/O.
  //   (2) Self-connect via CreateFileW satisfies ConnectNamedPipe.
  if (AWorkerThread <> NIL) and (AWorkerThread.Handle <> 0) then
    CancelSynchronousIo(AWorkerThread.Handle);

  // Retry briefly. The pipe is in one of three states:
  //   (a) Worker already exited via CSI — pipe gone (ERROR_FILE_NOT_FOUND), no wake needed.
  //   (b) Worker is past CreatePipeInstance but not yet inside ConnectNamedPipe — pipe exists
  //       but transiently busy (ERROR_PIPE_BUSY).
  //   (c) Worker is between iterations and CreatePipeInstance hasn't run yet for this loop —
  //       pipe gone briefly (ERROR_FILE_NOT_FOUND), comes back within tens of ms.
  // We can't distinguish (a) from (c) without coordination, so retry briefly on FILE_NOT_FOUND
  // too. If the worker is genuinely gone, the owner's WaitFor returns immediately anyway.
  for Attempts := 1 to 20 do
  begin
    WakeClient := CreateFileW(PWideChar(FPipeName), GENERIC_READ or GENERIC_WRITE,
                              0, NIL, OPEN_EXISTING, 0, 0);
    if WakeClient <> INVALID_HANDLE_VALUE then
    begin
      CloseHandle(WakeClient);
      Break;
    end;
    Err := GetLastError;
    if (Err <> ERROR_PIPE_BUSY)
       and (Err <> ERROR_ACCESS_DENIED)
       and (Err <> ERROR_FILE_NOT_FOUND) then Break;
    Sleep(5);
  end;

  DeleteDiscoveryFile;
END;


FUNCTION TPipeTransport.EndpointLabel: String;
BEGIN
  Result := FPipeName;
END;


END.
