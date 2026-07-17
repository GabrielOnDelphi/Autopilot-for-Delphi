unit Tests.Mcp.SocketClient;

{=============================================================================================================
   2026.07.07
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for Autopilot.Mcp.SocketClient: PC-side proof using a synthetic TFakeBridgeListener that runs on a background thread and speaks the wire protocol (hello frame, request/response round-trip).
   - Covers connect+handshake, response field inspection, connect-refused timeout behaviour, and the S2 wedge
     scenario (target accepts + handshakes then never answers -> ETargetNotResponding via SO_RCVTIMEO).
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
    [Test] procedure Test_WedgedTarget_RaisesNotResponding;
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
// response the test gave it → close. In wedge mode it instead answers NOTHING
// after reading the request and holds the connection open (the frozen target of
// review item S2). Runs on its own thread so the test thread can drive
// CallTargetSocket synchronously. Picks an ephemeral port (bind :0) and exposes
// it via Port once StartListening returns.
type
  TFakeBridgeListener = class(TThread)
  strict private
    FListenSock : TSocket;
    FPort       : Word;
    FResponse   : String;     // canned response JSON written back to the client
    FWedge      : Boolean;    // TRUE = never respond; hold the connection until released
    FReady      : TEvent;     // signalled once bound+listening (Port is valid)
    FRelease    : TEvent;     // signalled by Destroy to let a wedged Execute finish
    FSawRequest : String;     // the request frame the client sent (for assertions)
  protected
    procedure Execute; override;
  public
    constructor Create(const AResponseJson: String; AWedgeAfterRequest: Boolean = False);
    destructor Destroy; override;
    procedure WaitUntilReady;
    property Port: Word read FPort;
    property SawRequest: String read FSawRequest;
  end;


constructor TFakeBridgeListener.Create(const AResponseJson: String; AWedgeAfterRequest: Boolean = False);
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
  FWedge    := AWedgeAfterRequest;
  FReady    := TEvent.Create(nil, True, False, '');   // manual-reset
  FRelease  := TEvent.Create(nil, True, False, '');
  FListenSock := INVALID_SOCKET;
  inherited Create(False);   // start immediately
end;


destructor TFakeBridgeListener.Destroy;
begin
  FRelease.SetEvent;   // let a wedged Execute proceed to its cleanup
  if FListenSock <> INVALID_SOCKET then
  begin
    closesocket(FListenSock);
    FListenSock := INVALID_SOCKET;
  end;
  inherited;     // joins the thread
  FReady.Free;
  FRelease.Free;
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

      // 3. Write the canned response — or wedge like a frozen target (S2).
      if FWedge then
        FRelease.WaitFor(30000)
      else
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


procedure TSocketClientTests.Test_WedgedTarget_RaisesNotResponding;
var
  Listener   : TFakeBridgeListener;
  Req        : TJSONObject;
  Resp       : TJSONObject;
  T0, Elapsed: UInt64;
  RaisedRight: Boolean;
begin
  // Review item S2, socket transport: the target ACCEPTS the connection and completes
  // the handshake, then never answers the command (frozen app / dead adb forward).
  // CallTargetSocket must raise ETargetNotResponding at ~(timeout + IoDeadlineGraceMs)
  // via SO_RCVTIMEO — not block the single-threaded MCP server forever.
  Listener := TFakeBridgeListener.Create('', True);   // wedge after reading the request
  try
    Listener.WaitUntilReady;

    Req := TJSONObject.Create;
    Req.AddPair('id', TJSONNumber.Create(1));
    Req.AddPair('cmd', 'get_text');
    RaisedRight := False;
    T0 := GetTickCount64;
    try
      try
        Resp := CallTargetSocket(Listener.Port, Req, 500);
        FreeAndNil(Resp);   // must not be reached
      except
        on E: ETargetNotResponding do
          RaisedRight := True;
        // Any OTHER exception escapes on purpose — the test then errors with the real message.
      end;
    finally
      FreeAndNil(Req);
    end;
    Elapsed := GetTickCount64 - T0;

    Assert.IsTrue(RaisedRight, 'expected ETargetNotResponding from the wedged target');
    Assert.IsTrue(Elapsed >= 2000, 'deadline fired too early (' + IntToStr(Elapsed) + ' ms) — grace not applied?');
    Assert.IsTrue(Elapsed < 10000, 'deadline fired too late (' + IntToStr(Elapsed) + ' ms) — SO_RCVTIMEO not applied?');
  finally
    Listener.Free;
  end;
end;


initialization
  TDUnitX.RegisterTestFixture(TSocketClientTests);

end.
