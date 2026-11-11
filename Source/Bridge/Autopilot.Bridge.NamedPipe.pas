unit Autopilot.Bridge.NamedPipe;

{=============================================================================================================
   2026.11.10
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - Windows-only IBridgeTransport implementation using Win32 named pipes with owner-only ACL
   - Manages the discovery file at %TEMP%\Autopilot\active\<PID>.pipe
   - Shutdown wake via CancelIoEx + self-connect, repeated until the worker thread has ended; absorbs all three named-pipe quirks
=============================================================================================================}

interface

uses
  Winapi.Windows,
  System.SysUtils, System.Classes, System.SyncObjs,
  Autopilot.Bridge.Transport;

type
  { Windows named-pipe transport.
    Owns the pipe handle and the discovery file.
    All methods except WakeAndStop run on the bridge worker thread; WakeAndStop runs on the owner thread (TBridgeWorker.Destroy).
    The destructor runs after the worker has been joined, so its backstop cleanup cannot race the worker. }
  TPipeTransport = class(TInterfacedObject, IBridgeTransport)
  strict private
    FPipeName       : String;
    FPipeHandle     : THandle;       // current pipe instance; INVALID_HANDLE_VALUE between client sessions
    FDiscoveryPath  : String;        // %TEMP%\Autopilot\active\<PID>.pipe — empty when not written
    FDiscoveryTried : Boolean;       // the discovery write is attempted ONCE
    FStopping       : Integer;       // 0 = running, 1 = WakeAndStop began. Written by the owner thread, read by the worker thread: TInterlocked
    FHandleLock     : TCriticalSection;  // FPipeHandle changes (worker) vs. CancelIoEx on it (owner): a closed handle value can be reused by another open in this process

    procedure WriteDiscoveryFile;
    procedure DeleteDiscoveryFile;
    function  CreatePipeInstance: THandle;
    function  Stopping: Boolean;
    procedure ClosePipeInstance(ADisconnect: Boolean);
  public
    // APipeName: full `\\.\pipe\...` form.
    constructor Create(const APipeName: String);
    destructor Destroy; override;

    { IBridgeTransport }
    procedure StartListening;
    function  AcceptConnection: Boolean;
    function  ConnectionStream: TStream;
    procedure RecycleConnection;
    procedure WakeAndStop(AWorkerThread: TThread);
    function  EndpointLabel: String;
  end;


{ Returns the canonical pipe name for the current process.
  Form: `\\.\pipe\Autopilot.<ExeBaseName>.<PID>`.
  Dots, not backslashes: a backslash hierarchy is valid Win32 but parses oddly in some tooling. }
function ComputePipeName: String;

{ Returns the discovery folder path.
  Created on demand. }
function DiscoveryFolder: String;


implementation

uses
  System.IOUtils, Winapi.AccCtrl,
  Autopilot.Bridge.Log;


{ Win32 imports not in Winapi.Windows ---------------------------------- }

const
  AdvApi32 = 'advapi32.dll';
  SDDL_REVISION_1 = 1;

function ConvertStringSecurityDescriptorToSecurityDescriptorW(StringSecurityDescriptor: PWideChar; StringSDRevision: DWORD; OUT SecurityDescriptor: PSecurityDescriptor; SecurityDescriptorSize: PCardinal): BOOL; stdcall;
  external AdvApi32 NAME 'ConvertStringSecurityDescriptorToSecurityDescriptorW';

function ConvertSidToStringSidW(Sid: PSID; OUT StringSid: PWideChar): BOOL; stdcall;
  external AdvApi32 NAME 'ConvertSidToStringSidW';


{ Look up the current process token's User SID and return it as an SDDL-friendly string.
  Result is empty on failure; the caller must fall back to a default ACL.
  The Windows StringSid returned by ConvertSidToStringSid is freed via LocalFree. }
function GetCurrentUserSidString: String;
var
  Token: THandle;
  Needed: DWORD;
  Buffer: TBytes;
  TokenUserInfo: PTokenUser;
  StringSid: PWideChar;
begin
  Result := '';
  if not OpenProcessToken(GetCurrentProcess, TOKEN_QUERY, Token) then exit;
  try
    // First call to size the buffer.
    Needed := 0;
    GetTokenInformation(Token, TokenUser, NIL, 0, Needed);
    if Needed = 0 then exit;
    SetLength(Buffer, Needed);
    if not GetTokenInformation(Token, TokenUser, @Buffer[0], Needed, Needed) then exit;
    TokenUserInfo := PTokenUser(@Buffer[0]);
    if not ConvertSidToStringSidW(TokenUserInfo^.User.Sid, StringSid) then exit;
    try
      Result := String(StringSid);
    finally
      LocalFree(HLOCAL(StringSid));
    end;
  finally
    CloseHandle(Token);
  end;
end;


function DiscoveryFolder: String;
begin
  Result := TPath.Combine(TPath.GetTempPath, 'Autopilot\active');
  if not TDirectory.Exists(Result)
  then TDirectory.CreateDirectory(Result);
end;


function ComputePipeName: String;
var
  ExePath, Base: String;
begin
  ExePath := ParamStr(0);
  Base    := TPath.GetFileNameWithoutExtension(ExePath);
  Result  := '\\.\pipe\Autopilot.' + Base + '.' + IntToStr(GetCurrentProcessId);
end;


{ TPipeTransport --------------------------------------------------------- }

constructor TPipeTransport.Create(const APipeName: String);
begin
  inherited Create;
  FPipeName   := APipeName;
  FPipeHandle := INVALID_HANDLE_VALUE;
  FHandleLock := TCriticalSection.Create;
end;


destructor TPipeTransport.Destroy;
begin
  { Backstop only: the worker's exit paths close the handle themselves (via AcceptConnection's failure branch or RecycleConnection).
    This fires when the worker died from an unhandled exception that bypassed its own close path.
    The worker releases the transport AFTER `inherited` (WaitFor) in its own destructor, so this cannot race the worker thread. }
  ClosePipeInstance(TRUE);
  DeleteDiscoveryFile;
  FreeAndNil(FHandleLock);
  inherited;
end;


function TPipeTransport.Stopping: Boolean;
begin
  Result := TInterlocked.CompareExchange(FStopping, 0, 0) <> 0;
end;


{ Closes the current pipe instance.
  Under FHandleLock, so WakeAndStop never cancels I/O on a handle value that was closed and reused meanwhile. }
procedure TPipeTransport.ClosePipeInstance(ADisconnect: Boolean);
begin
  FHandleLock.Enter;
  try
    if FPipeHandle <> INVALID_HANDLE_VALUE then
      begin
        if ADisconnect
        then DisconnectNamedPipe(FPipeHandle);
        CloseHandle(FPipeHandle);
        FPipeHandle := INVALID_HANDLE_VALUE;
      end;
  finally
    FHandleLock.Leave;
  end;
end;


procedure TPipeTransport.WriteDiscoveryFile;
var
  Folder, Pid, TempPath: String;
  MoveErr: DWORD;
begin
  Folder := DiscoveryFolder;
  Pid := IntToStr(GetCurrentProcessId);
  FDiscoveryPath := TPath.Combine(Folder, Pid + '.pipe');
  { Write atomically: write to a sibling temp file, then MoveFileExW with MOVEFILE_REPLACE_EXISTING.
    NTFS guarantees the rename is observed atomically by other processes.
    Without this, the MCP server can read a zero-byte file in the open-truncate-write window of WriteAllText. }
  TempPath := FDiscoveryPath + '.tmp';
  TFile.WriteAllText(TempPath, FPipeName, TEncoding.UTF8);
  if not MoveFileExW(PWideChar(TempPath), PWideChar(FDiscoveryPath), MOVEFILE_REPLACE_EXISTING) then
    begin
      { Capture the rename failure code BEFORE the fallback TFile calls - those make their own Win32 calls (DeleteFile / CreateFile) that overwrite GetLastError, so reading it after them would log a misleading (usually 0) code. }
      MoveErr := GetLastError;
      // Fall back to a direct write so the bridge stays discoverable even if rename fails.
      TFile.Delete(TempPath);
      TFile.WriteAllText(FDiscoveryPath, FPipeName, TEncoding.UTF8);
      BridgeLogWarn('bridge', 'discovery file atomic rename failed (' + IntToStr(MoveErr) + '); fell back to direct write');
    end;
end;


procedure TPipeTransport.DeleteDiscoveryFile;
begin
  if (FDiscoveryPath <> '') and TFile.Exists(FDiscoveryPath) then
    try
      TFile.Delete(FDiscoveryPath);
    except
      { Don't propagate - called from WakeAndStop/destructor paths that must not raise.
        The MCP server will treat the stale file as a dead target on its next connect attempt. }
      on E: Exception do
        BridgeLogWarn('bridge', 'DeleteDiscoveryFile failed: ' + E.ClassName + ': ' + E.Message);
    end;
  FDiscoveryPath := '';
end;


function TPipeTransport.CreatePipeInstance: THandle;
var
  UserSid, Sddl: String;
  SD: PSecurityDescriptor;
  SA: TSecurityAttributes;
  SAPtr: PSecurityAttributes;
  LastErr: DWORD;
begin
  { Owner-only ACL: only the current user can connect.
    The MCP server must run as the same OS user as the target.
    Do not use the well-known SID `OW` ("Owner Rights") instead: it fails silently, because no owner is set in the descriptor.
    Pulling the user's actual SID out of the process token and embedding it in the SDDL string works. }
  SD     := NIL;
  SAPtr  := NIL;
  UserSid := GetCurrentUserSidString;
  if UserSid <> ''
  then
    begin
      Sddl := 'D:(A;;GA;;;' + UserSid + ')';
      if ConvertStringSecurityDescriptorToSecurityDescriptorW(PWideChar(Sddl), SDDL_REVISION_1, SD, NIL)
      then
        begin
          FillChar(SA, SizeOf(SA), 0);
          SA.nLength              := SizeOf(SA);
          SA.lpSecurityDescriptor := SD;
          SA.bInheritHandle       := FALSE;
          SAPtr := @SA;
        end
      else
        // Fall back to default ACL but record why. The bridge stays usable; admins can audit.
        BridgeLogWarn('bridge', 'owner-only SD conversion failed (' + IntToStr(GetLastError) + '); falling back to default ACL');
    end
  else
    BridgeLogWarn('bridge', 'could not resolve current user SID; falling back to default ACL');

  try
    Result := CreateNamedPipeW(
                PWideChar(FPipeName),
                PIPE_ACCESS_DUPLEX or FILE_FLAG_FIRST_PIPE_INSTANCE,
                PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT,
                1,                  // max instances: one client at a time
                64 * 1024,          // out buffer hint
                64 * 1024,          // in buffer hint
                0,                  // default timeout
                SAPtr);
    if Result = INVALID_HANDLE_VALUE then
      begin
        LastErr := GetLastError;
        raise EOSError.Create('CreateNamedPipeW failed: ' + IntToStr(LastErr) + ' (' + SysErrorMessage(LastErr) + ')');
      end;
    if SAPtr <> NIL
    then BridgeLogInfo('bridge', 'pipe ready, ACL restricted to user SID ' + UserSid)
    else BridgeLogInfo('bridge', 'pipe ready (default ACL)');
  finally
    if SD <> NIL
    then LocalFree(HLOCAL(SD));
  end;
end;


procedure TPipeTransport.StartListening;
var
  NewHandle: THandle;
begin
  { The stop landed while the worker was between two pipe instances: create no new one, and write no discovery file that WakeAndStop has already deleted.
    AcceptConnection then reports "no connection". }
  if Stopping then exit;

  { Discovery file is best-effort, attempted ONCE (written even if pipe creation later fails).
    If TFile.WriteAllText raises (disk full, permission denied, virus scanner locking the dir), the bridge can still serve clients that already know the pipe name via attach(pid). }
  if not FDiscoveryTried then
    begin
      FDiscoveryTried := TRUE;
      try
        WriteDiscoveryFile;
      except
        on E: Exception do
          BridgeLogError('bridge', 'WriteDiscoveryFile failed: ' + E.ClassName + ': ' + E.Message + ' — bridge will not auto-discover; attach(pid) still works');
      end;
    end;

  { (Re-)create a pipe instance for each client session.
    FILE_FLAG_FIRST_PIPE_INSTANCE on the first call rejects an existing same-named pipe, which is what we want - if another instance of this exe is up, we want to know. }
  NewHandle := CreatePipeInstance;
  FHandleLock.Enter;
  try
    FPipeHandle := NewHandle;
  finally
    FHandleLock.Leave;
  end;
end;


function TPipeTransport.AcceptConnection: Boolean;
var
  Connected: BOOL;
begin
  { The stop landed before this call: no client will ever come for this instance. }
  if Stopping or (FPipeHandle = INVALID_HANDLE_VALUE) then
    begin
      ClosePipeInstance(FALSE);
      exit(FALSE);
    end;

  Connected := ConnectNamedPipe(FPipeHandle, NIL);
  { ConnectNamedPipe returns FALSE with ERROR_PIPE_CONNECTED if a client connected between CreateNamedPipe and ConnectNamedPipe.
    That's actually success.
    Returns FALSE with ERROR_OPERATION_ABORTED if WakeAndStop cancelled it with CancelIoEx. }
  if (not Connected) and (GetLastError <> ERROR_PIPE_CONNECTED) then
    begin
      ClosePipeInstance(FALSE);
      exit(FALSE);
    end;

  { WakeAndStop self-connects via CreateFileW to unblock us - that produces a successful "connection" that must not be handshaken with: serving it on this thread while the main thread concurrently frees handles races the RTL's exception machinery (an access violation in @HandleAnyException).
    Swallow it. }
  if Stopping then
    begin
      ClosePipeInstance(TRUE);
      exit(FALSE);
    end;

  Result := TRUE;
end;


function TPipeTransport.ConnectionStream: TStream;
begin
  // THandleStream does not close the handle; the transport still owns it.
  Result := THandleStream.Create(FPipeHandle);
end;


procedure TPipeTransport.RecycleConnection;
begin
  ClosePipeInstance(TRUE);
end;


procedure TPipeTransport.WakeAndStop(AWorkerThread: TThread);
const
  WakeIntervalMs = 10;
  WarnAfterMs    = 10000;
var
  WorkerHandle, WakeClient: THandle;
  OnMainThread, Warned: Boolean;
  StartTick: UInt64;
  WaitResult: DWORD;
  Msg: TMsg;
begin
  { The stop flag goes FIRST: from here on StartListening creates no new pipe instance, and AcceptConnection treats every connection as the wake phantom. }
  TInterlocked.Exchange(FStopping, 1);

  if AWorkerThread = NIL
  then WorkerHandle := 0
  else WorkerHandle := AWorkerThread.Handle;

  { Wake the worker again and again, until its thread has ended.
    One wake is not enough: the worker can be between two steps, where the wake finds no I/O to cancel and no pipe instance to connect to, and start a blocking call right after it.
    Each pass does two things:
      (1) CancelIoEx on the current pipe instance cancels the ConnectNamedPipe, ReadFile or WriteFile the worker is blocked in (pinned by Test_PipeWorker_StopWhileAClientIsSilent_EndsTheWorker).
          CancelIoEx takes the handle, not the thread, and does not wait for the cancelled call to end.
      (2) A self-connect via CreateFileW satisfies a ConnectNamedPipe. AcceptConnection swallows that phantom connection. }
  OnMainThread := GetCurrentThreadId = MainThreadID;
  Warned       := FALSE;
  StartTick    := GetTickCount64;
  repeat
    FHandleLock.Enter;
    try
      if FPipeHandle <> INVALID_HANDLE_VALUE
      then CancelIoEx(FPipeHandle, NIL);
    finally
      FHandleLock.Leave;
    end;

    WakeClient := CreateFileW(PWideChar(FPipeName), GENERIC_READ or GENERIC_WRITE, 0, NIL, OPEN_EXISTING, 0, 0);
    if WakeClient <> INVALID_HANDLE_VALUE
    then CloseHandle(WakeClient);

    if WorkerHandle = 0 then Break;

    { On the main thread, wait the way TThread.WaitFor does: let a SendMessage from the worker through, and run what the worker queued while it still runs.
      Without this a dispatch the worker waits for would run only after its timeout. }
    if OnMainThread
    then
      begin
        WaitResult := MsgWaitForMultipleObjects(1, WorkerHandle, FALSE, WakeIntervalMs, QS_SENDMESSAGE);
        if WaitResult = WAIT_OBJECT_0 + 1
        then PeekMessage(Msg, 0, 0, 0, PM_NOREMOVE);
        if (WaitResult <> WAIT_OBJECT_0) and (WaitResult <> WAIT_FAILED)
        then CheckSynchronize;
      end
    else
      WaitResult := WaitForSingleObject(WorkerHandle, WakeIntervalMs);

    { The join that follows (TThread.WaitFor) raises for a handle it cannot wait on. }
    if WaitResult = WAIT_FAILED then
      begin
        BridgeLogWarn('bridge', 'WakeAndStop cannot wait on the worker thread (' + IntToStr(GetLastError) + ')');
        Break;
      end;

    if (not Warned) and (GetTickCount64 - StartTick > WarnAfterMs) then
      begin
        Warned := TRUE;
        BridgeLogWarn('bridge', 'worker thread has not ended ' + IntToStr(WarnAfterMs div 1000) + ' s after the stop; still waking it');
      end;
  until WaitResult = WAIT_OBJECT_0;

  { After the worker has ended: it writes the discovery file in StartListening, so deleting it earlier could race that write. }
  DeleteDiscoveryFile;
end;


function TPipeTransport.EndpointLabel: String;
begin
  Result := FPipeName;
end;


end.
