unit Autopilot.Bridge.Core;

{=============================================================================================================
   2026.07.07
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - Shared protocol types and wire-framing helpers for the Autopilot bridge (all platforms)
   - Stdlib-only: no VCL, no FMX, no LightSaber — usable by both the pipe and socket transports
   - Defines TBridgeRequest, TBridgeResponse, TBridgeDispatcher, TBridgeWire, and JSON-RPC error codes
=============================================================================================================}

interface

uses
  System.SysUtils, System.Classes, System.JSON;

const
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

  // Grace added on top of the per-command timeout to form the MCP-side I/O deadline.
  // The bridge worker itself answers ErrMainThreadBlocked at ~timeoutMs, so the MCP
  // client must wait LONGER than that before declaring the target dead — a deadline
  // equal to the command timeout would race the worker's own -32004 response.
  IoDeadlineGraceMs = 2000;

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

type
  /// Raised by the MCP-side transport clients (PipeClient / SocketClient) when the
  /// I/O deadline expires AFTER a connection was established: the target accepted the
  /// connection but stopped servicing the wire (typical case: the whole target is
  /// frozen on an IDE breakpoint, so even its worker thread is suspended).
  /// Autopilot.Mcp.ToolBase catches this and emits the ErrTargetNotResponding envelope.
  ETargetNotResponding = class(Exception);

  /// Owned-result record returned by the main-thread dispatcher.
  /// Caller frees ResultJson / ErrorMessage strings normally; the JSON is owned.
  TBridgeResponse = record
    Id           : Int64;
    Ok           : Boolean;
    ResultJson   : TJSONObject;   // when Ok=TRUE, the result body. Bridge owns it; serializer frees.
    ErrorCode    : Integer;       // when Ok=FALSE
    ErrorMessage : String;        // when Ok=FALSE
    ErrorData    : TJSONObject;   // optional, when Ok=FALSE — JSON-RPC error.data. Bridge owns; serializer frees.
  end;

  /// Parsed request as the worker thread sees it before handing off to the dispatcher.
  TBridgeRequest = record
    Id        : Int64;
    Cmd       : String;
    Args      : TJSONObject;       // weak reference into the parsed root; do not free here
    TimeoutMs : Cardinal;          // 0 = caller didn't specify, use per-command default
  end;

  /// Signature the worker thread calls (already on the main thread) to do the actual work.
  /// Implementations live in Autopilot.Bridge.Vcl (VCL) or Autopilot.Bridge.Fmx (FMX-future).
  TBridgeDispatcher = reference to function(const Req: TBridgeRequest): TBridgeResponse;

  /// Wire framing helpers — 4-byte little-endian length + UTF-8 payload.
  /// Exposed here (rather than buried in NamedPipe) so the test suite can reuse them.
  TBridgeWire = class
  public
    /// Read one length-prefixed UTF-8 frame from the stream. Blocks until full frame arrives.
    /// Returns FALSE on EOF/broken pipe (so caller can recycle the connection).
    /// On success, S contains the decoded UTF-8 JSON payload (no trailing newline).
    class function TryReadFrame(AStream: TStream; OUT S: String): Boolean; static;

    /// Write one length-prefixed UTF-8 frame to the stream. Raises on I/O failure.
    class procedure WriteFrame(AStream: TStream; const S: String); static;
  end;

  /// Build a hello frame (target-side handshake). Caller owns the returned object.
  function BuildHelloJson(const AExeName: String; APid: Cardinal): TJSONObject;

  /// Parse a top-level frame into a TBridgeRequest. Caller owns ARoot (must not be freed
  /// until the response is built — Req.Args is a weak reference into it).
  /// Returns FALSE if the frame doesn't look like a valid request (id/cmd missing).
  function TryParseRequest(ARoot: TJSONObject; OUT Req: TBridgeRequest): Boolean;

  /// Build a response frame as a JSON string ready for WriteFrame.
  /// Consumes Resp.ResultJson (frees it after serialization) so callers don't have to track ownership.
  function SerializeResponse(var Resp: TBridgeResponse): String;

  /// Parse a JSON value as an Int64 WITHOUT raising. TRUE only when AVal is a TJSONNumber whose
  /// text is a valid integer; FALSE for nil / non-number / fractional / out-of-range. Use for
  /// caller-supplied numeric args so a malformed value lands in ErrInvalidRequest instead of
  /// escaping as the EConvertError that TJSONNumber.AsInt64 (= StrToInt64) would raise.
  function TryJsonInt64(AVal: TJSONValue; OUT AOut: Int64): Boolean;


implementation

uses
  System.NetEncoding;

{ TBridgeWire ------------------------------------------------------------- }

// Read exactly ACount bytes from the stream. Loops on short reads, which are
// legal on a byte-mode named pipe even with PIPE_WAIT: ReadFile returns as
// soon as the writer's WriteFile completes, even if fewer bytes than requested
// arrived. Returns FALSE on first zero-byte read (EOF / broken pipe).
function ReadFully(AStream: TStream; var Buf; ACount: Integer): Boolean;
var
  Total, Got: Integer;
  P: PByte;
begin
  P := PByte(@Buf);
  Total := 0;
  while Total < ACount do
  begin
    Got := AStream.Read(P[Total], ACount - Total);
    if Got <= 0 then exit(FALSE);
    Inc(Total, Got);
  end;
  Result := TRUE;
end;


class function TBridgeWire.TryReadFrame(AStream: TStream; OUT S: String): Boolean;
var
  Len: UInt32;
  Buf: TBytes;
begin
  Result := FALSE;
  S := '';
  // First 4 bytes: little-endian length. Use ReadFully to handle short reads,
  // which a byte-mode pipe is allowed to produce. Clean FALSE on EOF.
  if not ReadFully(AStream, Len, SizeOf(Len)) then exit;

  // Sanity cap: refuse frames >64 MiB. Anything bigger is almost certainly a protocol bug,
  // not a real payload. Adjust upward only when Phase-2 screenshots actually need it.
  if Len > 64 * 1024 * 1024 then
    raise EReadError.Create('Bridge: refused absurd frame length ' + IntToStr(Len));

  if Len = 0 then
  begin
    Result := TRUE;
    exit;
  end;

  SetLength(Buf, Len);
  if not ReadFully(AStream, Buf[0], Integer(Len)) then exit;

  S := TEncoding.UTF8.GetString(Buf);
  Result := TRUE;
end;


class procedure TBridgeWire.WriteFrame(AStream: TStream; const S: String);
var
  Buf: TBytes;
  Len: UInt32;
begin
  Buf := TEncoding.UTF8.GetBytes(S);
  Len := Length(Buf);
  AStream.WriteBuffer(Len, SizeOf(Len));
  if Len > 0 then
    AStream.WriteBuffer(Buf[0], Len);
end;


{ Module-level helpers ---------------------------------------------------- }

function BuildHelloJson(const AExeName: String; APid: Cardinal): TJSONObject;
var
  Hello: TJSONObject;
begin
  Hello := TJSONObject.Create;
  Hello.AddPair('protocolVersion', TJSONNumber.Create(ProtocolVersion));
  Hello.AddPair('bridgeVersion',   BridgeVersion);
  Hello.AddPair('pid',             TJSONNumber.Create(APid));
  Hello.AddPair('exe',             AExeName);
  Result := TJSONObject.Create;
  Result.AddPair('hello', Hello);
end;


function TryJsonInt64(AVal: TJSONValue; OUT AOut: Int64): Boolean;
begin
  AOut := 0;
  Result := (AVal is TJSONNumber) and TryStrToInt64(TJSONNumber(AVal).Value, AOut);
end;


function TryParseRequest(ARoot: TJSONObject; OUT Req: TBridgeRequest): Boolean;
var
  CmdVal: TJSONValue;
  ArgsVal: TJSONValue;
  Int64Val: Int64;
begin
  Result := FALSE;
  Req := Default(TBridgeRequest);

  // id must be a clean integer. TryJsonInt64 (not AsInt64) so a missing / non-number /
  // fractional id fails the parse here instead of raising EConvertError up the worker loop.
  if not TryJsonInt64(ARoot.GetValue('id'), Req.Id) then exit;

  // cmd must be a string. Use an `is` test, not `as TJSONString`: a present-but-non-string
  // cmd (e.g. {"cmd":5}) would make `as` raise EInvalidCast, which escapes the worker's
  // ServeOneRequest (no except there, only a finally) and tears down the whole client
  // session instead of returning a clean ErrInvalidRequest for that one frame. `is` returns
  // FALSE for both nil (missing) and a non-string, matching this function's documented
  // "id/cmd missing -> FALSE" contract — and matching how id/timeoutMs are parsed below.
  CmdVal := ARoot.GetValue('cmd');
  if not (CmdVal is TJSONString) then exit;
  Req.Cmd := TJSONString(CmdVal).Value;

  ArgsVal := ARoot.GetValue('args');
  if ArgsVal is TJSONObject then
    Req.Args := TJSONObject(ArgsVal)
  else
    Req.Args := NIL;   // some commands take no args

  // timeoutMs is optional. We accept any non-negative integer up to High(Cardinal); anything
  // out of range, negative, or unparseable degrades to 0 (= "use defaults") so a single
  // malformed value can never tear down the pipe session. TryJsonInt64 returns FALSE (leaving
  // TimeoutMs at 0) rather than raising on a fractional / garbage value — no swallowed exception.
  Req.TimeoutMs := 0;
  if TryJsonInt64(ARoot.GetValue('timeoutMs'), Int64Val)
     and (Int64Val >= 0) and (Int64Val <= Int64(High(Cardinal))) then
    Req.TimeoutMs := Cardinal(Int64Val);

  Result := TRUE;
end;


function SerializeResponse(var Resp: TBridgeResponse): String;
var
  Root, ErrObj: TJSONObject;
begin
  Root := TJSONObject.Create;
  try
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
  finally
    FreeAndNil(Root);  // also frees ResultJson (now owned) and ErrObj
  end;
end;


end.
