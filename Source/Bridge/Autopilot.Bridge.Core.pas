UNIT Autopilot.Bridge.Core;

{=====================================================
   2026.05.12
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────┐
   │  SHARED  (all platforms)     │   pipe + socket transports both depend on it
   └──────────────────────────────┘

   Shared protocol types for the Autopilot bridge.

   This unit is stdlib-only. No VCL, no FMX, no LightSaber.
   The bridge worker thread (.NamedPipe) and the dispatcher (.Vcl, .Fmx)
   both depend on this unit but not on each other.

   Locked decisions live in CLAUDE.md "Architectural decisions already locked".
   Wire format: see Plans/01_TargetUnit.md "Wire framing" and "Protocol version handshake".
=====================================================}

INTERFACE

USES
  System.SysUtils, System.Classes, System.JSON;

CONST
  ProtocolVersion = 1;
  BridgeVersion   = '0.1.0';

  // Free for noncommercial use, paid for commercial use (see repo LICENSE +
  // COMMERCIAL-LICENSE.md). The bridge exists only in AUTOPILOT (debug) builds,
  // so this reminder is logged once per startup to the developer's own log file,
  // never shown to an end user.
  CommercialLicenseURL  = 'https://www.GabrielMoraru.com/autopilot';   // overview / buy page — the soft nudge lands here, not the raw checkout (that is in COMMERCIAL-LICENSE.md)
  CommercialLicenseHint = 'Commercial use? License at ' + CommercialLicenseURL;

  // Per-command timeout defaults (ms). The MCP server can override per-call via the
  // optional timeoutMs field in the request. See Plans/01 "Per-command timeout".
  DefaultTimeoutListMs       = 2000;
  DefaultTimeoutClickMs      = 5000;
  DefaultTimeoutScreenshotMs = 30000;

  // JSON-RPC custom error codes. Same numbers used on both sides of the pipe.
  ErrNotFound            = -32001;
  ErrAmbiguousPath       = -32002;
  ErrControlDisabled     = -32003;
  ErrMainThreadBlocked   = -32004;
  ErrUnsupportedAction   = -32005;
  ErrRttiPropertyMissing = -32006;
  ErrProtocolMismatch    = -32097;
  ErrTargetNotResponding = -32098;
  ErrTargetNotRunning    = -32099;
  ErrInvalidRequest      = -32600;
  ErrInternalError       = -32603;

TYPE
  /// Owned-result record returned by the main-thread dispatcher.
  /// Caller frees ResultJson / ErrorMessage strings normally; the JSON is owned.
  TBridgeResponse = RECORD
    Id           : Int64;
    Ok           : Boolean;
    ResultJson   : TJSONObject;   // when Ok=TRUE, the result body. Bridge owns it; serializer frees.
    ErrorCode    : Integer;       // when Ok=FALSE
    ErrorMessage : String;        // when Ok=FALSE
    ErrorData    : TJSONObject;   // optional, when Ok=FALSE — JSON-RPC error.data. Bridge owns; serializer frees.
  END;

  /// Parsed request as the worker thread sees it before handing off to the dispatcher.
  TBridgeRequest = RECORD
    Id        : Int64;
    Cmd       : String;
    Args      : TJSONObject;       // weak reference into the parsed root; do NOT free here
    TimeoutMs : Cardinal;          // 0 = caller didn't specify, use per-command default
  END;

  /// Signature the worker thread calls (already on the main thread) to do the actual work.
  /// Implementations live in Autopilot.Bridge.Vcl (VCL) or Autopilot.Bridge.Fmx (FMX-future).
  TBridgeDispatcher = REFERENCE TO FUNCTION(CONST Req: TBridgeRequest): TBridgeResponse;

  /// Wire framing helpers — 4-byte little-endian length + UTF-8 payload.
  /// Exposed here (rather than buried in NamedPipe) so the test suite can reuse them.
  TBridgeWire = CLASS
  PUBLIC
    /// Read one length-prefixed UTF-8 frame from the stream. Blocks until full frame arrives.
    /// Returns FALSE on EOF/broken pipe (so caller can recycle the connection).
    /// On success, S contains the decoded UTF-8 JSON payload (no trailing newline).
    CLASS FUNCTION TryReadFrame(AStream: TStream; OUT S: String): Boolean; STATIC;

    /// Write one length-prefixed UTF-8 frame to the stream. Raises on I/O failure.
    CLASS PROCEDURE WriteFrame(AStream: TStream; CONST S: String); STATIC;
  END;

  /// Build a hello frame (target-side handshake). Caller owns the returned object.
  FUNCTION BuildHelloJson(CONST AExeName: String; APid: Cardinal): TJSONObject;

  /// Parse a top-level frame into a TBridgeRequest. Caller owns ARoot (must NOT be freed
  /// until the response is built — Req.Args is a weak reference into it).
  /// Returns FALSE if the frame doesn't look like a valid request (id/cmd missing).
  FUNCTION TryParseRequest(ARoot: TJSONObject; OUT Req: TBridgeRequest): Boolean;

  /// Build a response frame as a JSON string ready for WriteFrame.
  /// Consumes Resp.ResultJson (frees it after serialization) so callers don't have to track ownership.
  FUNCTION SerializeResponse(VAR Resp: TBridgeResponse): String;


IMPLEMENTATION

USES
  System.NetEncoding;

{ TBridgeWire ------------------------------------------------------------- }

// Read exactly ACount bytes from the stream. Loops on short reads, which are
// legal on a byte-mode named pipe even with PIPE_WAIT: ReadFile returns as
// soon as the writer's WriteFile completes, even if fewer bytes than requested
// arrived. Returns FALSE on first zero-byte read (EOF / broken pipe).
FUNCTION ReadFully(AStream: TStream; VAR Buf; ACount: Integer): Boolean;
VAR
  Total, Got: Integer;
  P: PByte;
BEGIN
  P := PByte(@Buf);
  Total := 0;
  WHILE Total < ACount DO
  BEGIN
    Got := AStream.Read(P[Total], ACount - Total);
    if Got <= 0 then EXIT(FALSE);
    Inc(Total, Got);
  END;
  Result := TRUE;
END;


CLASS FUNCTION TBridgeWire.TryReadFrame(AStream: TStream; OUT S: String): Boolean;
VAR
  Len: UInt32;
  Buf: TBytes;
BEGIN
  Result := FALSE;
  S := '';
  // First 4 bytes: little-endian length. Use ReadFully to handle short reads,
  // which a byte-mode pipe is allowed to produce. Clean FALSE on EOF.
  if not ReadFully(AStream, Len, SizeOf(Len)) then EXIT;

  // Sanity cap: refuse frames >64 MiB. Anything bigger is almost certainly a protocol bug,
  // not a real payload. Adjust upward only when Phase-2 screenshots actually need it.
  if Len > 64 * 1024 * 1024 then
    raise EReadError.Create('Bridge: refused absurd frame length ' + IntToStr(Len));

  if Len = 0 then
  begin
    Result := TRUE;
    EXIT;
  end;

  SetLength(Buf, Len);
  if not ReadFully(AStream, Buf[0], Integer(Len)) then EXIT;

  S := TEncoding.UTF8.GetString(Buf);
  Result := TRUE;
END;


CLASS PROCEDURE TBridgeWire.WriteFrame(AStream: TStream; CONST S: String);
VAR
  Buf: TBytes;
  Len: UInt32;
BEGIN
  Buf := TEncoding.UTF8.GetBytes(S);
  Len := Length(Buf);
  AStream.WriteBuffer(Len, SizeOf(Len));
  if Len > 0 then
    AStream.WriteBuffer(Buf[0], Len);
END;


{ Module-level helpers ---------------------------------------------------- }

FUNCTION BuildHelloJson(CONST AExeName: String; APid: Cardinal): TJSONObject;
VAR
  Hello: TJSONObject;
BEGIN
  Hello := TJSONObject.Create;
  Hello.AddPair('protocolVersion', TJSONNumber.Create(ProtocolVersion));
  Hello.AddPair('bridgeVersion',   BridgeVersion);
  Hello.AddPair('pid',             TJSONNumber.Create(APid));
  Hello.AddPair('exe',             AExeName);
  Result := TJSONObject.Create;
  Result.AddPair('hello', Hello);
END;


FUNCTION TryParseRequest(ARoot: TJSONObject; OUT Req: TBridgeRequest): Boolean;
VAR
  IdNum: TJSONNumber;
  CmdStr: TJSONString;
  ArgsVal: TJSONValue;
  TimeoutVal: TJSONValue;
  Int64Val: Int64;
BEGIN
  Result := FALSE;
  Req := Default(TBridgeRequest);

  IdNum := ARoot.GetValue('id') AS TJSONNumber;
  if IdNum = NIL then EXIT;
  Req.Id := IdNum.AsInt64;

  CmdStr := ARoot.GetValue('cmd') AS TJSONString;
  if CmdStr = NIL then EXIT;
  Req.Cmd := CmdStr.Value;

  ArgsVal := ARoot.GetValue('args');
  if ArgsVal IS TJSONObject then
    Req.Args := TJSONObject(ArgsVal)
  else
    Req.Args := NIL;   // some commands take no args

  // timeoutMs is optional. We accept any non-negative integer up to High(Cardinal);
  // anything out of range, negative, or unparseable becomes 0 (= "use defaults") so
  // a single malformed value can never tear down the pipe session.
  TimeoutVal := ARoot.GetValue('timeoutMs');
  Req.TimeoutMs := 0;
  if TimeoutVal IS TJSONNumber then
    TRY
      Int64Val := TJSONNumber(TimeoutVal).AsInt64;
      if (Int64Val >= 0) and (Int64Val <= Int64(High(Cardinal))) then
        Req.TimeoutMs := Cardinal(Int64Val);
    EXCEPT
      // StrToInt64 raises EConvertError on overflow / garbage. Swallow.
      Req.TimeoutMs := 0;
    END;

  Result := TRUE;
END;


FUNCTION SerializeResponse(VAR Resp: TBridgeResponse): String;
VAR
  Root, ErrObj: TJSONObject;
BEGIN
  Root := TJSONObject.Create;
  TRY
    Root.AddPair('id', TJSONNumber.Create(Resp.Id));
    Root.AddPair('ok', TJSONBool.Create(Resp.Ok));
    if Resp.Ok then
    begin
      if Resp.ResultJson <> NIL then
      begin
        Root.AddPair('result', Resp.ResultJson);
        Resp.ResultJson := NIL;  // ownership transferred to Root
      end
      else
        Root.AddPair('result', TJSONObject.Create);  // empty {} for actions with no payload
    end
    else
    begin
      ErrObj := TJSONObject.Create;
      ErrObj.AddPair('code', TJSONNumber.Create(Resp.ErrorCode));
      ErrObj.AddPair('message', Resp.ErrorMessage);
      if Resp.ErrorData <> NIL then
      begin
        ErrObj.AddPair('data', Resp.ErrorData);
        Resp.ErrorData := NIL;  // ownership transferred to ErrObj
      end;
      Root.AddPair('error', ErrObj);
      // If caller built a ResultJson by mistake, don't leak it.
      if Resp.ResultJson <> NIL then
        FreeAndNil(Resp.ResultJson);
    end;
    Result := Root.ToJSON;
  FINALLY
    FreeAndNil(Root);  // also frees ResultJson (now owned) and ErrObj
  END;
END;


END.
