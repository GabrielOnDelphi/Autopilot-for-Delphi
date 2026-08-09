UNIT Tests.Mcp.SocketClient;

(*=====================================================
   2026.06.04
   DUnitX tests for the MCP-side adb socket client (Autopilot.Mcp.SocketClient).

   This is the PC-side Phase-A proof: it stands up a SYNTHETIC loopback TCP
   listener that speaks the same wire protocol the Android bridge will (writes a
   hello frame on accept, reads the request frame, writes a canned response),
   then drives CallTargetSocket against it. No phone, no Phase-B Socket.pas body
   — it verifies that the PC-side framing / handshake / round-trip is correct
   TODAY, over a real socket.

   The listener reuses TSocketStream (a plain TStream over a socket fd) to frame
   its side with TBridgeWire. That is fine: we are testing the client's connect +
   handshake + round-trip, and the listener is just a protocol-correct peer.

   Stdlib + Winsock only.
=====================================================*)

INTERFACE

USES
  DUnitX.TestFramework;

TYPE
  [TestFixture]
  TSocketClientTests = CLASS
  PUBLIC
    [Test] PROCEDURE Test_RoundTrip_EchoesResponse;
    [Test] PROCEDURE Test_Response_CarriesResultFields;
    [Test] PROCEDURE Test_ConnectRefused_RaisesWithinTimeout;
  END;


IMPLEMENTATION

USES
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
TYPE
  TFakeBridgeListener = CLASS(TThread)
  STRICT PRIVATE
    FListenSock : TSocket;
    FPort       : Word;
    FResponse   : String;     // canned response JSON written back to the client
    FReady      : TEvent;     // signalled once bound+listening (Port is valid)
    FSawRequest : String;     // the request frame the client sent (for assertions)
  PROTECTED
    PROCEDURE Execute; OVERRIDE;
  PUBLIC
    CONSTRUCTOR Create(CONST AResponseJson: String);
    DESTRUCTOR Destroy; OVERRIDE;
    PROCEDURE WaitUntilReady;
    PROPERTY Port: Word READ FPort;
    PROPERTY SawRequest: String READ FSawRequest;
  END;


CONSTRUCTOR TFakeBridgeListener.Create(CONST AResponseJson: String);
VAR
  WsaData: TWSAData;
BEGIN
  // The listener thread calls socket()/bind() directly, so Winsock must be up
  // BEFORE the thread starts — we can't rely on the client's WsaAcquire winning
  // the startup race. WSAStartup is itself ref-counted by Winsock, so this pairs
  // safely with the client's own startup/cleanup. Matched by WSACleanup in Destroy.
  if WSAStartup($0202, WsaData) <> 0 then
    raise Exception.CreateFmt('FakeBridgeListener: WSAStartup failed (code %d)', [WSAGetLastError]);
  FResponse := AResponseJson;
  FReady    := TEvent.Create(NIL, TRUE, FALSE, '');   // manual-reset
  FListenSock := INVALID_SOCKET;
  inherited Create(FALSE);   // start immediately
END;


DESTRUCTOR TFakeBridgeListener.Destroy;
BEGIN
  if FListenSock <> INVALID_SOCKET then
  begin
    closesocket(FListenSock);
    FListenSock := INVALID_SOCKET;
  end;
  inherited;     // joins the thread
  FReady.Free;
  WSACleanup;    // pairs with the WSAStartup in Create
END;


PROCEDURE TFakeBridgeListener.WaitUntilReady;
BEGIN
  if FReady.WaitFor(5000) <> wrSignaled then
    raise Exception.Create('FakeBridgeListener never became ready');
END;


PROCEDURE TFakeBridgeListener.Execute;
VAR
  Addr     : TSockAddrIn;
  AddrLen  : Integer;
  ConnSock : TSocket;
  Stream   : TSocketStream;
  Hello    : TJSONObject;
  ReqFrame : String;
BEGIN
  FListenSock := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if FListenSock = INVALID_SOCKET then EXIT;

  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family      := AF_INET;
  Addr.sin_port        := 0;                       // ephemeral — kernel picks
  Addr.sin_addr.S_addr := htonl(INADDR_LOOPBACK);
  if bind(FListenSock, TSockAddr(Addr), SizeOf(Addr)) = SOCKET_ERROR then EXIT;
  if listen(FListenSock, 1) = SOCKET_ERROR then EXIT;

  // Read back the chosen port.
  AddrLen := SizeOf(Addr);
  if getsockname(FListenSock, TSockAddr(Addr), AddrLen) = SOCKET_ERROR then EXIT;
  FPort := ntohs(Addr.sin_port);

  FReady.SetEvent;   // Port valid — the test may connect now

  ConnSock := accept(FListenSock, NIL, NIL);
  if ConnSock = INVALID_SOCKET then EXIT;
  TRY
    Stream := TSocketStream.Create(ConnSock);
    TRY
      // 1. Bridge speaks first: hello frame.
      Hello := BuildHelloJson('Autopilot.FakeBridge.exe', GetCurrentProcessId);
      TRY
        TBridgeWire.WriteFrame(Stream, Hello.ToJSON);
      FINALLY
        Hello.Free;
      END;

      // 2. Client replies helloAck, then sends its request. We read both frames;
      //    keep the request frame for the test to assert against.
      if not TBridgeWire.TryReadFrame(Stream, ReqFrame) then EXIT;   // helloAck
      if not TBridgeWire.TryReadFrame(Stream, FSawRequest) then EXIT; // the command

      // 3. Write the canned response.
      TBridgeWire.WriteFrame(Stream, FResponse);
    FINALLY
      Stream.Free;
    END;
  FINALLY
    closesocket(ConnSock);
  END;
END;


{ # Tests }

PROCEDURE TSocketClientTests.Test_RoundTrip_EchoesResponse;
VAR
  Listener : TFakeBridgeListener;
  Req      : TJSONObject;
  Resp     : TJSONObject;
BEGIN
  Listener := TFakeBridgeListener.Create('{"id":1,"ok":true,"result":{"pong":true}}');
  TRY
    Listener.WaitUntilReady;

    Req := TJSONObject.Create;
    Req.AddPair('id', TJSONNumber.Create(1));
    Req.AddPair('cmd', 'ping');
    TRY
      Resp := CallTargetSocket(Listener.Port, Req, 3000);
      TRY
        Assert.IsNotNull(Resp, 'No response object');
        Assert.AreEqual(Int64(1), (Resp.GetValue('id') AS TJSONNumber).AsInt64, 'id mismatch');
        Assert.IsTrue((Resp.GetValue('ok') AS TJSONBool).AsBoolean, 'ok should be true');
      FINALLY
        Resp.Free;
      END;
    FINALLY
      Req.Free;
    END;

    // The client must have sent our exact command through.
    Assert.IsTrue(Listener.SawRequest.Contains('"cmd":"ping"'), 'listener did not see the request: ' + Listener.SawRequest);
  FINALLY
    Listener.Free;
  END;
END;


PROCEDURE TSocketClientTests.Test_Response_CarriesResultFields;
VAR
  Listener : TFakeBridgeListener;
  Req      : TJSONObject;
  Resp     : TJSONObject;
  ResObj   : TJSONObject;
BEGIN
  Listener := TFakeBridgeListener.Create('{"id":7,"ok":true,"result":{"value":"hello","n":42}}');
  TRY
    Listener.WaitUntilReady;
    Req := TJSONObject.Create;
    Req.AddPair('id', TJSONNumber.Create(7));
    Req.AddPair('cmd', 'read_property');
    TRY
      Resp := CallTargetSocket(Listener.Port, Req, 3000);
      TRY
        ResObj := Resp.GetValue('result') AS TJSONObject;
        Assert.IsNotNull(ResObj, 'no result object');
        Assert.AreEqual('hello', (ResObj.GetValue('value') AS TJSONString).Value, 'value field mismatch');
        Assert.AreEqual(Int64(42), (ResObj.GetValue('n') AS TJSONNumber).AsInt64, 'n field mismatch');
      FINALLY
        Resp.Free;
      END;
    FINALLY
      Req.Free;
    END;
  FINALLY
    Listener.Free;
  END;
END;


PROCEDURE TSocketClientTests.Test_ConnectRefused_RaisesWithinTimeout;
VAR
  Req     : TJSONObject;
  Raised  : Boolean;
  T0      : UInt64;
BEGIN
  // Port 1 on loopback has nothing listening → connect must fail, and
  // CallTargetSocket must raise within roughly the timeout, not hang forever.
  Req := TJSONObject.Create;
  Req.AddPair('id', TJSONNumber.Create(1));
  Req.AddPair('cmd', 'ping');
  Raised := FALSE;
  T0 := GetTickCount64;
  TRY
    TRY
      CallTargetSocket(1, Req, 500).Free;
    EXCEPT
      ON E: Exception DO
        Raised := TRUE;
    END;
  FINALLY
    Req.Free;
  END;
  Assert.IsTrue(Raised, 'expected a transport exception on connect-refused');
  Assert.IsTrue(GetTickCount64 - T0 < 5000, 'connect-refused took too long — timeout not honoured');
END;


INITIALIZATION
  TDUnitX.RegisterTestFixture(TSocketClientTests);

END.
