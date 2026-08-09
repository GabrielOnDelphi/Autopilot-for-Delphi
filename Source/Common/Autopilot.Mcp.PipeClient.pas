UNIT Autopilot.Mcp.PipeClient;

(*=====================================================
   2026.05.12
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────────────┐
   │  WINDOWS  (PC-side, named-pipe client) │   reaches a Windows target over the local pipe
   └──────────────────────────────────────┘

   Pipe client for the MCP-server side of the bridge.

   Each MCP tool call runs through here:
     - Scan %TEMP%\Autopilot\active\*.pipe → resolve target pipe name
     - CreateFileW → open pipe
     - Bridge writes hello frame → we write helloAck
     - Send request frame, read response frame
     - Close pipe (single round-trip per call; bridge handles reconnect)

   No VCL, no FMX, no LightSaber. Stdlib + Win32 only.
=====================================================*)

INTERFACE

USES
  Winapi.Windows,
  System.SysUtils, System.Classes, System.JSON,
  Autopilot.Bridge.Core;

TYPE
  /// Result of a target lookup.
  TTargetEntry = RECORD
    Pid       : Cardinal;
    PipeName  : String;
    Exe       : String;       // filled by GetExeFromPid; empty if not yet looked up
  END;

  TTargetList = TArray<TTargetEntry>;


/// Enumerate the discovery folder. Stale entries (target process is gone) are filtered out.
FUNCTION ListTargets: TTargetList;

/// Convenience: read the discovery folder path.
FUNCTION DiscoveryFolderPath: String;

/// Run one round-trip: open pipe, handshake, send one command frame, read one response, close.
/// Returns the parsed response object (caller frees) or raises on transport failure.
FUNCTION CallTarget(CONST APipeName: String; ARequestJson: TJSONObject; ATimeoutMs: Cardinal = 5000): TJSONObject;


IMPLEMENTATION

USES
  System.IOUtils, System.Generics.Collections;


FUNCTION DiscoveryFolderPath: String;
BEGIN
  Result := TPath.Combine(TPath.GetTempPath, 'Autopilot\active');
END;


CONST
  PROCESS_QUERY_LIMITED_INFORMATION_ = $1000;   // not in Winapi.Windows on D13


FUNCTION IsPidAlive(APid: Cardinal): Boolean;
VAR
  H: THandle;
  ExitCode: DWORD;
BEGIN
  if APid = 0 then EXIT(FALSE);
  H := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION_, FALSE, APid);
  if H = 0 then EXIT(FALSE);
  TRY
    Result := GetExitCodeProcess(H, ExitCode) and (ExitCode = STILL_ACTIVE);
  FINALLY
    CloseHandle(H);
  END;
END;


FUNCTION ListTargets: TTargetList;
VAR
  Folder: String;
  Files: TArray<String>;
  i: Integer;
  Entry: TTargetEntry;
  PidStr, Line: String;
  PidVal: Cardinal;
  Acc: TList<TTargetEntry>;
BEGIN
  Acc := TList<TTargetEntry>.Create;
  TRY
    Folder := DiscoveryFolderPath;
    if not TDirectory.Exists(Folder) then
    begin
      Result := NIL;
      EXIT;
    end;
    Files := TDirectory.GetFiles(Folder, '*.pipe');
    for i := 0 to High(Files) do
    begin
      PidStr := TPath.GetFileNameWithoutExtension(Files[i]);
      if not TryStrToUInt(PidStr, PidVal) then Continue;
      if not IsPidAlive(PidVal) then
      begin
        // Stale entry — process is gone. Sweep the file so the next caller doesn't see it.
        TRY
          TFile.Delete(Files[i]);
        EXCEPT
          // Best effort. Another process may be racing us.
        END;
        Continue;
      end;
      Line := '';
      TRY
        Line := TFile.ReadAllText(Files[i], TEncoding.UTF8).Trim;
      EXCEPT
        // Same file write/read race — skip this entry, next scan will pick it up.
        Continue;
      END;
      if Line = '' then Continue;
      Entry := Default(TTargetEntry);
      Entry.Pid      := PidVal;
      Entry.PipeName := Line;
      Acc.Add(Entry);
    end;
    Result := Acc.ToArray;
  FINALLY
    Acc.Free;
  END;
END;


PROCEDURE WriteHelloAck(AStream: TStream);
VAR
  Ack: TJSONObject;
  Inner: TJSONObject;
BEGIN
  Inner := TJSONObject.Create;
  Ack := TJSONObject.Create;
  TRY
    Inner.AddPair('protocolVersion', TJSONNumber.Create(ProtocolVersion));
    Ack.AddPair('helloAck', Inner);
    Inner := NIL;
    TBridgeWire.WriteFrame(AStream, Ack.ToJSON);
  FINALLY
    Inner.Free;
    Ack.Free;
  END;
END;


FUNCTION OpenPipeWithTimeout(CONST APipeName: String; ATimeoutMs: Cardinal): THandle;
VAR
  Deadline: UInt64;
BEGIN
  Deadline := GetTickCount64 + ATimeoutMs;
  REPEAT
    Result := CreateFileW(PWideChar(APipeName), GENERIC_READ or GENERIC_WRITE,
                          0, NIL, OPEN_EXISTING, 0, 0);
    if Result <> INVALID_HANDLE_VALUE then EXIT;
    if GetLastError <> ERROR_FILE_NOT_FOUND then EXIT;   // permanent failure
    Sleep(25);
  UNTIL GetTickCount64 >= Deadline;
END;


FUNCTION CallTarget(CONST APipeName: String; ARequestJson: TJSONObject; ATimeoutMs: Cardinal): TJSONObject;
VAR
  Pipe: THandle;
  Stream: THandleStream;
  HelloRaw, Frame: String;
  Parsed: TJSONValue;
BEGIN
  Pipe := OpenPipeWithTimeout(APipeName, ATimeoutMs);
  if Pipe = INVALID_HANDLE_VALUE then
    raise Exception.CreateFmt('CallTarget: could not open pipe "%s" (code %d)',
                              [APipeName, GetLastError]);
  TRY
    Stream := THandleStream.Create(Pipe);
    TRY
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
    FINALLY
      Stream.Free;
    END;
  FINALLY
    CloseHandle(Pipe);
  END;
END;


END.
