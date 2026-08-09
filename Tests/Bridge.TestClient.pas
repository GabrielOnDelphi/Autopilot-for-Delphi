UNIT Bridge.TestClient;

{=====================================================
   Minimal named-pipe client + helpers used by the DUnitX suite.
   Stdlib + Win32 only — does NOT use the bridge units directly so the test
   really exercises the wire protocol, not internal calls.
=====================================================}

INTERFACE

USES
  Winapi.Windows,
  System.SysUtils, System.Classes, System.JSON,
  Autopilot.Bridge.Core;

TYPE
  TBridgeTestClient = CLASS
  STRICT PRIVATE
    FPipe   : THandle;
    FStream : THandleStream;
  PUBLIC
    /// Try to open the pipe until ATimeoutMs elapses. Returns FALSE on timeout.
    /// Also performs the hello/helloAck handshake.
    FUNCTION  ConnectAndHandshake(CONST APipeName: String; ATimeoutMs: Cardinal): Boolean;

    /// Sends one request frame, reads one response frame, parses it.
    /// Returned root object is OWNED by caller and must be Freed.
    FUNCTION  Call(AId: Int64; CONST ACmd: String; AArgs: TJSONObject;
                   ATimeoutMs: Cardinal = 0): TJSONObject;

    DESTRUCTOR Destroy; OVERRIDE;
  END;

/// Helper: get the "result" sub-object of a successful response (or NIL).
/// Does NOT take ownership; the parent root still owns it.
FUNCTION GetOkResult(ARoot: TJSONObject): TJSONObject;

/// Helper: extract error code from a failed response. Returns 0 if ARoot is OK or malformed.
FUNCTION GetErrorCode(ARoot: TJSONObject): Integer;

/// Helper: extract the optional 'data' sub-object from a failed response. Returns NIL
/// when the response is OK, malformed, or has no error.data. Does NOT take ownership.
FUNCTION GetErrorData(ARoot: TJSONObject): TJSONObject;


IMPLEMENTATION

FUNCTION TBridgeTestClient.ConnectAndHandshake(CONST APipeName: String; ATimeoutMs: Cardinal): Boolean;
VAR
  Deadline: UInt64;
  HelloFrame: String;
  HelloRoot: TJSONValue;
  AckObj: TJSONObject;
  ResponseAck: TJSONObject;
BEGIN
  Result := FALSE;
  Deadline := GetTickCount64 + ATimeoutMs;

  FPipe := INVALID_HANDLE_VALUE;
  WHILE GetTickCount64 < Deadline DO
  BEGIN
    FPipe := CreateFileW(PWideChar(APipeName), GENERIC_READ or GENERIC_WRITE,
                         0, NIL, OPEN_EXISTING, 0, 0);
    if FPipe <> INVALID_HANDLE_VALUE then Break;
    if GetLastError <> ERROR_FILE_NOT_FOUND then Break;
    Sleep(25);
  END;
  if FPipe = INVALID_HANDLE_VALUE then EXIT;

  FStream := THandleStream.Create(FPipe);

  // Read bridge's hello.
  if not TBridgeWire.TryReadFrame(FStream, HelloFrame) then EXIT;
  HelloRoot := TJSONObject.ParseJSONValue(HelloFrame);
  TRY
    if not (HelloRoot IS TJSONObject) then EXIT;
    // Don't bother verifying contents in detail — the dedicated test does that.
  FINALLY
    HelloRoot.Free;
  END;

  // Send helloAck.
  AckObj := TJSONObject.Create;
  ResponseAck := TJSONObject.Create;
  TRY
    AckObj.AddPair('protocolVersion', TJSONNumber.Create(ProtocolVersion));
    ResponseAck.AddPair('helloAck', AckObj);
    AckObj := NIL;
    TBridgeWire.WriteFrame(FStream, ResponseAck.ToJSON);
  FINALLY
    AckObj.Free;
    ResponseAck.Free;
  END;

  Result := TRUE;
END;


FUNCTION TBridgeTestClient.Call(AId: Int64; CONST ACmd: String; AArgs: TJSONObject;
                                ATimeoutMs: Cardinal): TJSONObject;
VAR
  Req: TJSONObject;
  Frame: String;
  Parsed: TJSONValue;
BEGIN
  Result := NIL;
  Req := TJSONObject.Create;
  TRY
    Req.AddPair('id', TJSONNumber.Create(AId));
    Req.AddPair('cmd', ACmd);
    if AArgs <> NIL then
      Req.AddPair('args', AArgs)
    else
      Req.AddPair('args', TJSONObject.Create);
    if ATimeoutMs > 0 then
      Req.AddPair('timeoutMs', TJSONNumber.Create(ATimeoutMs));
    TBridgeWire.WriteFrame(FStream, Req.ToJSON);
  FINALLY
    Req.Free;
  END;

  if not TBridgeWire.TryReadFrame(FStream, Frame) then EXIT;
  Parsed := TJSONObject.ParseJSONValue(Frame);
  if Parsed IS TJSONObject then
    Result := TJSONObject(Parsed)
  else
    Parsed.Free;
END;


DESTRUCTOR TBridgeTestClient.Destroy;
BEGIN
  FreeAndNil(FStream);
  if FPipe <> INVALID_HANDLE_VALUE then
    CloseHandle(FPipe);
  inherited;
END;


FUNCTION GetOkResult(ARoot: TJSONObject): TJSONObject;
VAR
  V: TJSONValue;
BEGIN
  Result := NIL;
  if ARoot = NIL then EXIT;
  V := ARoot.GetValue('ok');
  if not (V IS TJSONBool) or not TJSONBool(V).AsBoolean then EXIT;
  V := ARoot.GetValue('result');
  if V IS TJSONObject then
    Result := TJSONObject(V);
END;


FUNCTION GetErrorCode(ARoot: TJSONObject): Integer;
VAR
  V: TJSONValue;
  Err: TJSONObject;
BEGIN
  Result := 0;
  if ARoot = NIL then EXIT;
  V := ARoot.GetValue('ok');
  if (V IS TJSONBool) and TJSONBool(V).AsBoolean then EXIT;
  V := ARoot.GetValue('error');
  if not (V IS TJSONObject) then EXIT;
  Err := TJSONObject(V);
  V := Err.GetValue('code');
  if V IS TJSONNumber then
    Result := TJSONNumber(V).AsInt;
END;


FUNCTION GetErrorData(ARoot: TJSONObject): TJSONObject;
VAR
  V: TJSONValue;
  Err: TJSONObject;
BEGIN
  Result := NIL;
  if ARoot = NIL then EXIT;
  V := ARoot.GetValue('ok');
  if (V IS TJSONBool) and TJSONBool(V).AsBoolean then EXIT;
  V := ARoot.GetValue('error');
  if not (V IS TJSONObject) then EXIT;
  Err := TJSONObject(V);
  V := Err.GetValue('data');
  if V IS TJSONObject then
    Result := TJSONObject(V);
END;


END.
