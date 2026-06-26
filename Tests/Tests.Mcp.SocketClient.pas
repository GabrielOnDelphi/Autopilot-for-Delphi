unit Tests.Mcp.SocketClient;

{=============================================================================================================
   2026.06
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for Autopilot.Mcp.SocketClient: PC-side proof using a synthetic TFakeBridgeListener that runs on a background thread and speaks the wire protocol (hello frame, request/response round-trip).
   - Covers connect+handshake, response field inspection, and connect-refused timeout behaviour.
   - No physical Android device needed. Stdlib + Winsock only.
=============================================================================================================}

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TSocketClientTests = class
  public
    [Test] procedure Test_RoundTrip_EchoesResponse;
    [Test] procedure Test_Response_CarriesResultFields;
    [Test] procedure Test_ConnectRefused_RaisesWithinTimeout;
  end;


implementation

uses
  Winapi.Windows, Winapi.WinSock2,
  System.SysUtils, System.Classes, System.JSON, System.SyncObjs,
  Autopilot.Bridge.Core,
  Autopilot.Mcp.SocketClient;


{ # Synthetic bridge-side listener }

// A one-shot loopback TCP listener that imitates the device bridge for exactly
// one connection: accept → write hello → read one request frame → write the
// response the test gave it → close. Runs on its own thread so the test thread
// can drive CallTargetSocket synchronously. Picks an ephemeral port (bind :0)
// and exposes it via Port once StartListening returns.
type
  TFakeBridgeListener = class(TThread)
  strict private
    FListenSock : TSocket;
    FPort       : Word;
    FResponse   : String;     // canned response JSON written back to the client
    FReady      : TEvent;     // signalled once bound+listening (Port is valid)
    FSawRequest : String;     // the request frame the client sent (for assertions)
  protected
    procedure Execute; override;
  public
    constructor Create(const AResponseJson: String);
    destructor Destroy; override;
    procedure WaitUntilReady;
    property Port: Word read FPort;
    property SawRequest: String read FSawRequest;
  end;


constructor TFakeBridgeListener.Create(const AResponseJson: String);
var
  WsaData: TWSAData;
begin
  // The listener thread calls socket()/bind() directly, so Winsock must be up
  // BEFORE the thread starts — we can't rely on the client's WsaAcquire winning
  // the startup race. WSAStartup is itself ref-counted by Winsock, so this pairs
  // safely with the client's own startup/cleanup. Matched by WSACleanup in Destroy.
  if WSAStartup($0202, WsaData) <> 0 then
    raise Exception.CreateFmt('FakeBridgeListener: WSAStartup failed (code %d)', [WSAGetLastError]);
  FResponse := AResponseJson;
  FReady    := TEvent.Create(nil, True, False, '');   // manual-reset
  FListenSock := INVALID_SOCKET;
  inherited Create(False);   // start immediately
end;


destructor TFakeBridgeListener.Destroy;
begin
  if FListenSock <> INVALID_SOCKET then
  begin
    closesocket(FListenSock);
    FListenSock := INVALID_SOCKET;
  end;
  inherited;     // joins the thread
  FReady.Free;
  WSACleanup;    // pairs with the WSAStartup in Create
end;


procedure TFakeBridgeListener.WaitUntilReady;
begin
  if FReady.WaitFor(5000) <> wrSignaled then
    raise Exception.Create('FakeBridgeListener never became ready');
end;


procedure TFakeBridgeListener.Execute;
var
  Addr     : TSockAddrIn;
  AddrLen  : Integer;
  ConnSock : TSocket;
  Stream   : TSocketStream;
  Hello    : TJSONObject;
  ReqFrame : String;
begin
  FListenSock := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if FListenSock = INVALID_SOCKET then Exit;

  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family      := AF_INET;
  Addr.sin_port        := 0;                       // ephemeral — kernel picks
  Addr.sin_addr.S_addr := htonl(INADDR_LOOPBACK);
  if bind(FListenSock, TSockAddr(Addr), SizeOf(Addr)) = SOCKET_ERROR then Exit;
  if listen(FListenSock, 1) = SOCKET_ERROR then Exit;

  // Read back the chosen port.
  AddrLen := SizeOf(Addr);
  if getsockname(FListenSock, TSockAddr(Addr), AddrLen) = SOCKET_ERROR then Exit;
  FPort := ntohs(Addr.sin_port);

  FReady.SetEvent;   // Port valid — the test may connect now

  ConnSock := accept(FListenSock, nil, nil);
  if ConnSock = INVALID_SOCKET then Exit;
  try
    Stream := TSocketStream.Create(ConnSock);
    try
      // 1. Bridge speaks first: hello frame.
      Hello := BuildHelloJson('Autopilot.FakeBridge.exe', GetCurrentProcessId);
      try
        TBridgeWire.WriteFrame(Stream, Hello.ToJSON);
      finally
        Hello.Free;
      end;

      // 2. Client replies helloAck, then sends its request. We read both frames;
      //    keep the request frame for the test to assert against.
      if not TBridgeWire.TryReadFrame(Stream, ReqFrame) then Exit;   // helloAck
      if not TBridgeWire.TryReadFrame(Stream, FSawRequest) then Exit; // the command

      // 3. Write the canned response.
      TBridgeWire.WriteFrame(Stream, FResponse);
    finally
      Stream.Free;
    end;
  finally
    closesocket(ConnSock);
  end;
end;


{ # Tests }

procedure TSocketClientTests.Test_RoundTrip_EchoesResponse;
var
  Listener : TFakeBridgeListener;
  Req      : TJSONObject;
  Resp     : TJSONObject;
begin
  Listener := TFakeBridgeListener.Create('{"id":1,"ok":true,"result":{"pong":true}}');
  try
    Listener.WaitUntilReady;

    Req := TJSONObject.Create;
    Req.AddPair('id', TJSONNumber.Create(1));
    Req.AddPair('cmd', 'ping');
    try
      Resp := CallTargetSocket(Listener.Port, Req, 3000);
      try
        Assert.IsNotNull(Resp, 'No response object');
        Assert.AreEqual(Int64(1), (Resp.GetValue('id') AS TJSONNumber).AsInt64, 'id mismatch');
        Assert.IsTrue((Resp.GetValue('ok') AS TJSONBool).AsBoolean, 'ok should be true');
      finally
        Resp.Free;
      end;
    finally
      Req.Free;
    end;

    // The client must have sent our exact command through.
    Assert.IsTrue(Listener.SawRequest.Contains('"cmd":"ping"'), 'listener did not see the request: ' + Listener.SawRequest);
  finally
    Listener.Free;
  end;
end;


procedure TSocketClientTests.Test_Response_CarriesResultFields;
var
  Listener : TFakeBridgeListener;
  Req      : TJSONObject;
  Resp     : TJSONObject;
  ResObj   : TJSONObject;
begin
  Listener := TFakeBridgeListener.Create('{"id":7,"ok":true,"result":{"value":"hello","n":42}}');
  try
    Listener.WaitUntilReady;
    Req := TJSONObject.Create;
    Req.AddPair('id', TJSONNumber.Create(7));
    Req.AddPair('cmd', 'read_property');
    try
      Resp := CallTargetSocket(Listener.Port, Req, 3000);
      try
        ResObj := Resp.GetValue('result') AS TJSONObject;
        Assert.IsNotNull(ResObj, 'no result object');
        Assert.AreEqual('hello', (ResObj.GetValue('value') AS TJSONString).Value, 'value field mismatch');
        Assert.AreEqual(Int64(42), (ResObj.GetValue('n') AS TJSONNumber).AsInt64, 'n field mismatch');
      finally
        Resp.Free;
      end;
    finally
      Req.Free;
    end;
  finally
    Listener.Free;
  end;
end;


procedure TSocketClientTests.Test_ConnectRefused_RaisesWithinTimeout;
var
  Req     : TJSONObject;
  Raised  : Boolean;
  T0      : UInt64;
begin
  // Port 1 on loopback has nothing listening → connect must fail, and
  // CallTargetSocket must raise within roughly the timeout, not hang forever.
  Req := TJSONObject.Create;
  Req.AddPair('id', TJSONNumber.Create(1));
  Req.AddPair('cmd', 'ping');
  Raised := False;
  T0 := GetTickCount64;
  try
    try
      CallTargetSocket(1, Req, 500).Free;
    except
      on E: Exception do
        Raised := True;
    end;
  finally
    Req.Free;
  end;
  Assert.IsTrue(Raised, 'expected a transport exception on connect-refused');
  Assert.IsTrue(GetTickCount64 - T0 < 5000, 'connect-refused took too long — timeout not honoured');
end;


initialization
  TDUnitX.RegisterTestFixture(TSocketClientTests);

end.
