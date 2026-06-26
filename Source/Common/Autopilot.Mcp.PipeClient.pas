unit Autopilot.Mcp.PipeClient;

{=============================================================================================================
   2026.06
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - Named-pipe client for the MCP-server side of the bridge (Windows, PC side).
   - Each MCP tool call: scan %TEMP%\Autopilot\active\*.pipe, open pipe, hello/helloAck handshake, one request/response round-trip, close.
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
function CallTarget(const APipeName: String; ARequestJson: TJSONObject; ATimeoutMs: Cardinal = 5000): TJSONObject;


implementation

uses
  System.IOUtils, System.Generics.Collections,
  Autopilot.Bridge.Log;


function DiscoveryFolderPath: String;
begin
  Result := TPath.Combine(TPath.GetTempPath, 'Autopilot\active');
end;


const
  PROCESS_QUERY_LIMITED_INFORMATION_ = $1000;   // not in Winapi.Windows on D13


function IsPidAlive(APid: Cardinal): Boolean;
var
  H: THandle;
  ExitCode: DWORD;
begin
  if APid = 0 then Exit(False);
  H := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION_, False, APid);
  if H = 0 then Exit(False);
  try
    Result := GetExitCodeProcess(H, ExitCode) and (ExitCode = STILL_ACTIVE);
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


function OpenPipeWithTimeout(const APipeName: String; ATimeoutMs: Cardinal): THandle;
var
  Deadline: UInt64;
  LErr: DWORD;
begin
  Deadline := GetTickCount64 + ATimeoutMs;
  repeat
    Result := CreateFileW(PWideChar(APipeName), GENERIC_READ or GENERIC_WRITE,
                          0, nil, OPEN_EXISTING, 0, 0);
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
  Stream: THandleStream;
  HelloRaw, Frame: String;
  Parsed: TJSONValue;
begin
  Pipe := OpenPipeWithTimeout(APipeName, ATimeoutMs);
  if Pipe = INVALID_HANDLE_VALUE then
    raise Exception.CreateFmt('CallTarget: could not open pipe "%s" (code %d)',
                              [APipeName, GetLastError]);
  try
    Stream := THandleStream.Create(Pipe);
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
