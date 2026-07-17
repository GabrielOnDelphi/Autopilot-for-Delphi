unit Autopilot.Mcp.PipeClient;

{=============================================================================================================
   2026.07.07
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - Named-pipe client for the MCP-server side of the bridge (Windows, PC side).
   - Each MCP tool call: scan %TEMP%\Autopilot\active\*.pipe, open pipe, hello/helloAck handshake, one request/response round-trip, close.
   - Every read/write after connect runs under an I/O deadline (overlapped I/O + CancelIoEx): a target that
     accepts the connection but stops servicing the wire (frozen on an IDE breakpoint) raises
     ETargetNotResponding instead of blocking the single-threaded MCP server forever.
   - No VCL, no FMX, no LightSaber. Stdlib + Win32 only (plus Autopilot.Bridge.Log, itself stdlib+Win32, for best-effort discovery-scan warnings).
=============================================================================================================}

interface

uses
  Winapi.Windows,
  System.SysUtils, System.Classes, System.JSON,
  Autopilot.Bridge.Core;

type
  /// Result of a target lookup.
  TTargetEntry = record
    Pid       : Cardinal;
    PipeName  : String;
    Exe       : String;       // filled by GetExeFromPid; empty if not yet looked up
  end;

  TTargetList = TArray<TTargetEntry>;


/// Enumerate the discovery folder. Stale entries (target process is gone) are filtered out.
function ListTargets: TTargetList;

/// Convenience: read the discovery folder path.
function DiscoveryFolderPath: String;

/// Run one round-trip: open pipe, handshake, send one command frame, read one response, close.
/// Returns the parsed response object (caller frees) or raises on transport failure.
/// ATimeoutMs budgets the connect phase; every read/write after connect runs under a deadline of
/// ATimeoutMs + IoDeadlineGraceMs and raises ETargetNotResponding when it expires (frozen target).
function CallTarget(const APipeName: String; ARequestJson: TJSONObject; ATimeoutMs: Cardinal = 5000): TJSONObject;


implementation

uses
  System.IOUtils, System.Generics.Collections,
  Autopilot.Bridge.Log;


function DiscoveryFolderPath: String;
begin
  Result := TPath.Combine(TPath.GetTempPath, 'Autopilot\active');
end;


function IsPidAlive(APid: Cardinal): Boolean;
var
  H: THandle;
begin
  if APid = 0 then Exit(False);
  H := OpenProcess(SYNCHRONIZE, False, APid);
  if H = 0 then Exit(False);
  try
    // A zero-timeout wait is the unambiguous liveness probe: WAIT_TIMEOUT = still
    // running. The old GetExitCodeProcess check compared against STILL_ACTIVE (259),
    // so a process that had EXITED with code 259 read as alive forever. `<>
    // WAIT_OBJECT_0` (not `= WAIT_TIMEOUT`) so an unexpected WAIT_FAILED errs on
    // "alive" — falsely dead would delete a live target's discovery file.
    Result := WaitForSingleObject(H, 0) <> WAIT_OBJECT_0;
  finally
    CloseHandle(H);
  end;
end;


function ListTargets: TTargetList;
var
  Folder: String;
  Files: TArray<String>;
  i: Integer;
  Entry: TTargetEntry;
  PidStr, Line: String;
  PidVal: Cardinal;
  Acc: TList<TTargetEntry>;
begin
  Acc := TList<TTargetEntry>.Create;
  try
    Folder := DiscoveryFolderPath;
    if not TDirectory.Exists(Folder) then
    begin
      Result := nil;
      Exit;
    end;
    Files := TDirectory.GetFiles(Folder, '*.pipe');
    for i := 0 to High(Files) do
    begin
      PidStr := TPath.GetFileNameWithoutExtension(Files[i]);
      if not TryStrToUInt(PidStr, PidVal) then Continue;
      if not IsPidAlive(PidVal) then
      begin
        // Stale entry — process is gone. Sweep the file so the next caller doesn't see it.
        try
          TFile.Delete(Files[i]);
        except
          // Best effort. Another process may be racing us. Log, don't crash the scan.
          on E: Exception do
            BridgeLogWarn('discovery', 'stale-file delete race on ' + Files[i] + ': ' + E.Message);
        end;
        Continue;
      end;
      Line := '';
      try
        Line := TFile.ReadAllText(Files[i], TEncoding.UTF8).Trim;
      except
        // Same file write/read race — skip this entry, next scan will pick it up.
        on E: Exception do
        begin
          BridgeLogWarn('discovery', 'file read race on ' + Files[i] + ': ' + E.Message);
          Continue;
        end;
      end;
      if Line = '' then Continue;
      Entry := Default(TTargetEntry);
      Entry.Pid      := PidVal;
      Entry.PipeName := Line;
      Acc.Add(Entry);
    end;
    Result := Acc.ToArray;
  finally
    Acc.Free;
  end;
end;


procedure WriteHelloAck(AStream: TStream);
var
  Ack: TJSONObject;
  Inner: TJSONObject;
begin
  Inner := TJSONObject.Create;
  Ack := TJSONObject.Create;
  try
    Inner.AddPair('protocolVersion', TJSONNumber.Create(ProtocolVersion));
    Ack.AddPair('helloAck', Inner);
    Inner := nil;
    TBridgeWire.WriteFrame(AStream, Ack.ToJSON);
  finally
    Inner.Free;
    Ack.Free;
  end;
end;


type
  // THandleStream cannot serve an overlapped pipe handle (its ReadFile passes no
  // OVERLAPPED, which is invalid on a FILE_FLAG_OVERLAPPED handle). This stream does
  // the same job with a per-operation deadline: each Read/Write is an overlapped I/O
  // plus an event wait; on deadline expiry the operation is cancelled (CancelIoEx)
  // and ETargetNotResponding raised, so a frozen target (breakpoint, hang) can no
  // longer block the single-threaded MCP server forever. Does NOT own the pipe
  // handle — CallTarget closes it, mirroring the THandleStream contract it replaces.
  TDeadlinePipeStream = class(TStream)
  strict private
    FPipe     : THandle;
    FEvent    : THandle;     // manual-reset; reused across operations (one op at a time)
    FTimeoutMs: Cardinal;
    function RunOverlapped(AIsRead: Boolean; var Buffer; Count: Longint): Longint;
  public
    constructor Create(APipe: THandle; ATimeoutMs: Cardinal);
    destructor Destroy; override;
    function Read (var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;


constructor TDeadlinePipeStream.Create(APipe: THandle; ATimeoutMs: Cardinal);
begin
  inherited Create;
  FPipe      := APipe;
  FTimeoutMs := ATimeoutMs;
  FEvent := CreateEventW(nil, True, False, nil);
  if FEvent = 0 then RaiseLastOSError;
end;


destructor TDeadlinePipeStream.Destroy;
begin
  if FEvent <> 0 then CloseHandle(FEvent);
  inherited;
end;


function TDeadlinePipeStream.RunOverlapped(AIsRead: Boolean; var Buffer; Count: Longint): Longint;
var
  Ov     : TOverlapped;
  Started: Boolean;
  Dummy  : DWORD;      // ReadFile/WriteFile demand a var here even for overlapped calls; value is meaningless, the real count comes from GetOverlappedResult
  N      : DWORD;
  Err    : DWORD;
  OpWord : String;
begin
  if Count <= 0 then Exit(0);

  Ov := Default(TOverlapped);
  ResetEvent(FEvent);
  Ov.hEvent := FEvent;

  if AIsRead
  then Started := ReadFile (FPipe, Buffer, Count, Dummy, @Ov)
  else Started := WriteFile(FPipe, Buffer, Count, Dummy, @Ov);

  if not Started then
  begin
    Err := GetLastError;
    if Err <> ERROR_IO_PENDING then
    begin
      // Immediate failure. A closed peer reads as EOF (0) so TBridgeWire.TryReadFrame
      // takes its normal FALSE path; anything else is a genuine OS error.
      if AIsRead and ((Err = ERROR_BROKEN_PIPE) or (Err = ERROR_PIPE_NOT_CONNECTED))
      then Exit(0)
      else RaiseLastOSError(Err);
    end;

    if WaitForSingleObject(FEvent, FTimeoutMs) <> WAIT_OBJECT_0 then
      // Deadline hit: cancel the pending operation. ERROR_NOT_FOUND (it completed in
      // the race window) is fine — GetOverlappedResult below resolves either way.
      CancelIoEx(FPipe, @Ov);
  end;

  // Single collection point for every path (synchronous completion, signaled wait,
  // post-cancel). bWait=TRUE also guarantees the kernel is DONE with Ov and Buffer
  // before they leave scope — mandatory after CancelIoEx.
  if not GetOverlappedResult(FPipe, Ov, N, True) then
  begin
    Err := GetLastError;
    if Err = ERROR_OPERATION_ABORTED then
    begin
      if AIsRead then OpWord := 'reply' else OpWord := 'accept data';
      raise ETargetNotResponding.CreateFmt(
        'target accepted the pipe connection but did not %s within %u ms — frozen on a breakpoint or hung?',
        [OpWord, FTimeoutMs]);
    end;
    if AIsRead and ((Err = ERROR_BROKEN_PIPE) or (Err = ERROR_PIPE_NOT_CONNECTED)) then
      Exit(0);
    RaiseLastOSError(Err);
  end;
  Result := Longint(N);
end;


function TDeadlinePipeStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := RunOverlapped(True, Buffer, Count);
end;


function TDeadlinePipeStream.Write(const Buffer; Count: Longint): Longint;
begin
  // Overlapped WriteFile does not modify the buffer; the var-cast only satisfies
  // RunOverlapped's shared signature.
  Result := RunOverlapped(False, PByte(@Buffer)^, Count);
end;


function TDeadlinePipeStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  // A pipe is not seekable. TBridgeWire never seeks; satisfy the abstract method.
  raise Exception.Create('TDeadlinePipeStream is not seekable');
end;


function OpenPipeWithTimeout(const APipeName: String; ATimeoutMs: Cardinal): THandle;
var
  Deadline: UInt64;
  LErr: DWORD;
begin
  Deadline := GetTickCount64 + ATimeoutMs;
  repeat
    // FILE_FLAG_OVERLAPPED: overlapped-ness is a per-HANDLE choice — the bridge's
    // server end stays synchronous, unaffected. Required by TDeadlinePipeStream.
    Result := CreateFileW(PWideChar(APipeName), GENERIC_READ or GENERIC_WRITE,
                          0, nil, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, 0);
    if Result <> INVALID_HANDLE_VALUE then Exit;
    // ERROR_FILE_NOT_FOUND: listener not up yet (cold start) -> wait + retry.
    // ERROR_PIPE_BUSY: pipe exists but its only instance is momentarily taken
    // (bridge between DisconnectNamedPipe and the next ConnectNamedPipe) -> retry.
    // Anything else (e.g. ACCESS_DENIED from an ACL mismatch) is permanent.
    LErr := GetLastError;
    if (LErr <> ERROR_FILE_NOT_FOUND) and (LErr <> ERROR_PIPE_BUSY) then Exit;
    Sleep(25);
  until GetTickCount64 >= Deadline;
end;


function CallTarget(const APipeName: String; ARequestJson: TJSONObject; ATimeoutMs: Cardinal): TJSONObject;
var
  Pipe: THandle;
  Stream: TDeadlinePipeStream;
  HelloRaw, Frame: String;
  Parsed: TJSONValue;
begin
  Pipe := OpenPipeWithTimeout(APipeName, ATimeoutMs);
  if Pipe = INVALID_HANDLE_VALUE then
    raise Exception.CreateFmt('CallTarget: could not open pipe "%s" (code %d)',
                              [APipeName, GetLastError]);
  try
    Stream := TDeadlinePipeStream.Create(Pipe, ATimeoutMs + IoDeadlineGraceMs);
    try
      // Bridge writes hello first. We don't verify contents here — the bridge owns the wire format.
      if not TBridgeWire.TryReadFrame(Stream, HelloRaw) then
        raise Exception.Create('CallTarget: bridge did not send hello');

      WriteHelloAck(Stream);

      // Send our request, read response.
      TBridgeWire.WriteFrame(Stream, ARequestJson.ToJSON);
      if not TBridgeWire.TryReadFrame(Stream, Frame) then
        raise Exception.Create('CallTarget: no response from bridge');

      Parsed := TJSONObject.ParseJSONValue(Frame);
      if Parsed IS TJSONObject then
        Result := TJSONObject(Parsed)
      else
      begin
        Parsed.Free;
        raise Exception.Create('CallTarget: response is not a JSON object');
      end;
    finally
      Stream.Free;
    end;
  finally
    CloseHandle(Pipe);
  end;
end;


end.
