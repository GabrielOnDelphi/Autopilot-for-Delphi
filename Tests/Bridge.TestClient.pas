unit Bridge.TestClient;

{=============================================================================================================
   2026.06
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - Minimal named-pipe test client used by the DUnitX suite — exercises the wire protocol directly, not internal calls.
   - TBridgeTestClient: ConnectAndHandshake, Call (one request/response round-trip). GetOkResult/GetErrorCode/GetErrorData helpers for response inspection.
=============================================================================================================}

interface

uses
  Winapi.Windows,
  System.SysUtils, System.Classes, System.JSON,
  Autopilot.Bridge.Core;

type
  TBridgeTestClient = class
  strict private
    FPipe   : THandle;
    FStream : THandleStream;
  public
    /// Try to open the pipe until ATimeoutMs elapses. Returns False on timeout.
    /// Also performs the hello/helloAck handshake.
    function  ConnectAndHandshake(const APipeName: String; ATimeoutMs: Cardinal): Boolean;

    /// Sends one request frame, reads one response frame, parses it.
    /// Returned root object is OWNED by caller and must be Freed.
    function  Call(AId: Int64; const ACmd: String; AArgs: TJSONObject;
                   ATimeoutMs: Cardinal = 0): TJSONObject;

    destructor Destroy; override;
  end;

/// Helper: get the "result" sub-object of a successful response (or nil).
/// Does NOT take ownership; the parent root still owns it.
function GetOkResult(ARoot: TJSONObject): TJSONObject;

/// Helper: extract error code from a failed response. Returns 0 if ARoot is OK or malformed.
function GetErrorCode(ARoot: TJSONObject): Integer;

/// Helper: extract the optional 'data' sub-object from a failed response. Returns nil
/// when the response is OK, malformed, or has no error.data. Does NOT take ownership.
function GetErrorData(ARoot: TJSONObject): TJSONObject;


implementation

function TBridgeTestClient.ConnectAndHandshake(const APipeName: String; ATimeoutMs: Cardinal): Boolean;
var
  Deadline: UInt64;
  HelloFrame: String;
  HelloRoot: TJSONValue;
  AckObj: TJSONObject;
  ResponseAck: TJSONObject;
begin
  Result := False;
  Deadline := GetTickCount64 + ATimeoutMs;

  FPipe := INVALID_HANDLE_VALUE;
  while GetTickCount64 < Deadline do
  begin
    FPipe := CreateFileW(PWideChar(APipeName), GENERIC_READ or GENERIC_WRITE,
                         0, nil, OPEN_EXISTING, 0, 0);
    if FPipe <> INVALID_HANDLE_VALUE then Break;
    if GetLastError <> ERROR_FILE_NOT_FOUND then Break;
    Sleep(25);
  end;
  if FPipe = INVALID_HANDLE_VALUE then Exit;

  FStream := THandleStream.Create(FPipe);

  // Read bridge's hello.
  if not TBridgeWire.TryReadFrame(FStream, HelloFrame) then Exit;
  HelloRoot := TJSONObject.ParseJSONValue(HelloFrame);
  try
    if not (HelloRoot IS TJSONObject) then Exit;
    // Don't bother verifying contents in detail — the dedicated test does that.
  finally
    HelloRoot.Free;
  end;

  // Send helloAck.
  AckObj := TJSONObject.Create;
  ResponseAck := TJSONObject.Create;
  try
    AckObj.AddPair('protocolVersion', TJSONNumber.Create(ProtocolVersion));
    ResponseAck.AddPair('helloAck', AckObj);
    AckObj := nil;
    TBridgeWire.WriteFrame(FStream, ResponseAck.ToJSON);
  finally
    AckObj.Free;
    ResponseAck.Free;
  end;

  Result := True;
end;


function TBridgeTestClient.Call(AId: Int64; const ACmd: String; AArgs: TJSONObject;
                                ATimeoutMs: Cardinal): TJSONObject;
var
  Req: TJSONObject;
  Frame: String;
  Parsed: TJSONValue;
begin
  Result := nil;
  Req := TJSONObject.Create;
  try
    Req.AddPair('id', TJSONNumber.Create(AId));
    Req.AddPair('cmd', ACmd);
    if AArgs <> nil then
      Req.AddPair('args', AArgs)
    else
      Req.AddPair('args', TJSONObject.Create);
    if ATimeoutMs > 0 then
      Req.AddPair('timeoutMs', TJSONNumber.Create(ATimeoutMs));
    TBridgeWire.WriteFrame(FStream, Req.ToJSON);
  finally
    Req.Free;
  end;

  if not TBridgeWire.TryReadFrame(FStream, Frame) then Exit;
  Parsed := TJSONObject.ParseJSONValue(Frame);
  if Parsed IS TJSONObject then
    Result := TJSONObject(Parsed)
  else
    Parsed.Free;
end;


destructor TBridgeTestClient.Destroy;
begin
  FreeAndNil(FStream);
  if FPipe <> INVALID_HANDLE_VALUE then
    CloseHandle(FPipe);
  inherited;
end;


function GetOkResult(ARoot: TJSONObject): TJSONObject;
var
  V: TJSONValue;
begin
  Result := nil;
  if ARoot = nil then Exit;
  V := ARoot.GetValue('ok');
  if not (V IS TJSONBool) or not TJSONBool(V).AsBoolean then Exit;
  V := ARoot.GetValue('result');
  if V IS TJSONObject then
    Result := TJSONObject(V);
end;


function GetErrorCode(ARoot: TJSONObject): Integer;
var
  V: TJSONValue;
  Err: TJSONObject;
begin
  Result := 0;
  if ARoot = nil then Exit;
  V := ARoot.GetValue('ok');
  if (V IS TJSONBool) and TJSONBool(V).AsBoolean then Exit;
  V := ARoot.GetValue('error');
  if not (V IS TJSONObject) then Exit;
  Err := TJSONObject(V);
  V := Err.GetValue('code');
  if V IS TJSONNumber then
    Result := TJSONNumber(V).AsInt;
end;


function GetErrorData(ARoot: TJSONObject): TJSONObject;
var
  V: TJSONValue;
  Err: TJSONObject;
begin
  Result := nil;
  if ARoot = nil then Exit;
  V := ARoot.GetValue('ok');
  if (V IS TJSONBool) and TJSONBool(V).AsBoolean then Exit;
  V := ARoot.GetValue('error');
  if not (V IS TJSONObject) then Exit;
  Err := TJSONObject(V);
  V := Err.GetValue('data');
  if V IS TJSONObject then
    Result := TJSONObject(V);
end;


end.
