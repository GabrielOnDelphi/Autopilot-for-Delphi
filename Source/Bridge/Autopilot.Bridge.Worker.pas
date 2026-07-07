unit Autopilot.Bridge.Worker;

{=============================================================================================================
   2026.07.07
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - Shared bridge worker thread (all platforms): accept → handshake → serve requests → recycle
   - Drives one IBridgeTransport (injected); never touches Win32 or POSIX I/O directly
   - Marshals each dispatcher call onto the main thread via TThread.Queue + TEvent timeout
=============================================================================================================}

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.JSON,
  Autopilot.Bridge.Core, Autopilot.Bridge.Transport;

type
  /// One worker thread per bridge instance. Owns the transport (released after the
  /// thread is joined). Cooperates with the dispatcher (which lives in
  /// Autopilot.Bridge.Vcl / .Fmx) via the callback.
  TBridgeWorker = class(TThread)
  strict private
    FTransport : IBridgeTransport;
    FDispatch  : TBridgeDispatcher;
    FExeName   : String;

    procedure HandshakeOrFail;
    function  ServeOneRequest: Boolean;  // returns FALSE on connection failure → caller recycles
  protected
    procedure Execute; override;
  public
    /// ATransport: the listener/connection provider (pipe on Windows, socket on Android).
    /// ADispatch must run a TBridgeRequest on the main thread.
    /// AExeName: short exe filename used in the hello frame.
    constructor Create(const ATransport: IBridgeTransport; const AExeName: String; ADispatch: TBridgeDispatcher);
    destructor Destroy; override;
  end;


implementation

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,     // GetCurrentProcessId for the hello frame
  {$ELSE}
  Posix.Unistd,       // getpid for the hello frame
  {$ENDIF}
  Autopilot.Bridge.Log;


function CurrentPid: Cardinal;
begin
  {$IFDEF MSWINDOWS}
  Result := GetCurrentProcessId;
  {$ELSE}
  Result := Cardinal(getpid);
  {$ENDIF}
end;


{ TBridgeWorker --------------------------------------------------------- }

constructor TBridgeWorker.Create(const ATransport: IBridgeTransport; const AExeName: String; ADispatch: TBridgeDispatcher);
begin
  Assert(Assigned(ADispatch), 'TBridgeWorker: dispatcher cannot be nil');
  Assert(ATransport <> NIL,   'TBridgeWorker: transport cannot be nil');
  FTransport := ATransport;
  FExeName   := AExeName;
  FDispatch  := ADispatch;
  inherited Create(FALSE);    // start immediately; not suspended
  FreeOnTerminate := FALSE;   // owner controls lifetime
end;


destructor TBridgeWorker.Destroy;
begin
  Terminate;

  // Wake the worker out of a blocked AcceptConnection. The transport owns the
  // mechanism (pipe: CancelSynchronousIo on the worker thread + self-connect;
  // socket: one byte to the self-pipe) and marks itself stopping so a phantom
  // wake-connection is swallowed inside AcceptConnection, never served.
  if FTransport <> NIL then
    FTransport.WakeAndStop(Self);

  // WaitFor inside `inherited` runs FIRST. The worker is guaranteed to have exited
  // its loop before the transport reference drops. The transport's destructor holds
  // the backstop cleanup (closing a handle/fd the worker's own exit path left open
  // after an unhandled exception) — releasing it BEFORE the join would race the
  // worker and was the suspected cause of the HANDOVER §3 EInOutError leak.
  inherited;
  FTransport := NIL;
end;


type
  // Heap-allocated, reference-counted slot shared between the worker and the queued dispatcher.
  // ServeOneRequest creates one slot per request. Each side holds one ref; whoever drops the
  // last ref frees the slot and the embedded Done event, so the worker can return from the
  // request without waiting for the late-firing queued procedure to settle.
  // Ownership transfer of the response payload is atomic (TInterlocked.CompareExchange on State).
  // Fixes Plans/04 R1: previously a stack-captured Resp could be written by the late-firing
  // queued proc after the worker had already moved on, leaking the produced ResultJson.
  TDispatchSlot = class
  strict private
    FRefCount: Integer;
    FState   : Integer;   // 0=pending, 1=dispatched (queued proc wrote Resp), 2=timeout (worker wrote Resp)
  public
    Resp: TBridgeResponse;
    Done: TEvent;
    // Deep copy of the request's Args, owned by the slot. The queued dispatcher reads
    // THIS (not the worker's parsed Root) so the timeout path can FreeAndNil(Root) without
    // dangling the Args the late-firing proc still dereferences. Freed in Destroy when the
    // last ref drops — outlives both the worker's return and a late proc run.
    ArgsClone: TJSONObject;
    constructor Create;
    destructor Destroy; override;
    procedure AddRef;
    procedure Release;
    // Returns TRUE if this caller wins the claim (no one else has claimed yet).
    // ANewState must be 1 (dispatched) or 2 (timeout).
    function TryClaim(ANewState: Integer): Boolean;
    property State: Integer READ FState;
  end;


constructor TDispatchSlot.Create;
begin
  inherited;
  FRefCount := 1;
  FState    := 0;
  Resp      := Default(TBridgeResponse);
  ArgsClone := NIL;
  Done      := TEvent.Create(NIL, TRUE, FALSE, '');
end;


destructor TDispatchSlot.Destroy;
begin
  FreeAndNil(Done);
  // Whoever drops the last ref frees any ResultJson the loser produced.
  // SerializeResponse on the winner clears ResultJson before this point.
  if Resp.ResultJson <> NIL then
    FreeAndNil(Resp.ResultJson);
  // Free the owned Args copy (no-op if the request had no args).
  if ArgsClone <> NIL then
    FreeAndNil(ArgsClone);
  inherited;
end;


procedure TDispatchSlot.AddRef;
begin
  TInterlocked.Increment(FRefCount);
end;


procedure TDispatchSlot.Release;
begin
  if TInterlocked.Decrement(FRefCount) = 0 then
    Free;
end;


function TDispatchSlot.TryClaim(ANewState: Integer): Boolean;
begin
  Result := TInterlocked.CompareExchange(FState, ANewState, 0) = 0;
end;


procedure TBridgeWorker.HandshakeOrFail;
var
  HelloRoot : TJSONObject;
  HelloText : String;
  Stream    : TStream;
  Ack       : String;
  AckRoot   : TJSONValue;
  AckPV     : TJSONValue;
begin
  HelloRoot := BuildHelloJson(FExeName, CurrentPid);
  try
    HelloText := HelloRoot.ToJSON;
  finally
    FreeAndNil(HelloRoot);
  end;

  // The transport OWNS the connection — the stream is a view over it and does
  // not close the underlying handle/fd. We own the stream object.
  Stream := FTransport.ConnectionStream;
  try
    TBridgeWire.WriteFrame(Stream, HelloText);

    if not TBridgeWire.TryReadFrame(Stream, Ack) then
      raise EReadError.Create('Bridge: handshake read failed');

    AckRoot := TJSONObject.ParseJSONValue(Ack);
    try
      if not (AckRoot is TJSONObject) then
        raise EParserError.Create('Bridge: handshake reply not an object');
      AckPV := TJSONObject(AckRoot).GetValue('helloAck');
      if not (AckPV is TJSONObject) then
        raise EParserError.Create('Bridge: handshake reply missing helloAck');
      AckPV := TJSONObject(AckPV).GetValue('protocolVersion');
      if not (AckPV is TJSONNumber) then
        raise EParserError.Create('Bridge: handshake reply missing protocolVersion');
      if TJSONNumber(AckPV).AsInt <> ProtocolVersion then
        raise EParserError.Create('Bridge: protocol mismatch (server wants ' +
                                  IntToStr(TJSONNumber(AckPV).AsInt) +
                                  ', we speak ' + IntToStr(ProtocolVersion) + ')');
    finally
      FreeAndNil(AckRoot);
    end;
  finally
    FreeAndNil(Stream);
  end;
end;


function TBridgeWorker.ServeOneRequest: Boolean;
var
  Stream  : TStream;
  FrameIn : String;
  Root    : TJSONValue;
  Req     : TBridgeRequest;
  Resp    : TBridgeResponse;
  Timeout : Cardinal;
  CapturedReq: TBridgeRequest;
  Slot    : TDispatchSlot;
  T0      : UInt64;
  WaitRes : TWaitResult;
  ElapsedMs: UInt64;
begin
  Result := FALSE;
  Stream := FTransport.ConnectionStream;
  try
    if not TBridgeWire.TryReadFrame(Stream, FrameIn) then exit;  // connection closed / EOF

    Root := TJSONObject.ParseJSONValue(FrameIn);
    if not (Root is TJSONObject) then
    begin
      // Free the non-object parse (e.g. a bare array/number) BEFORE the write:
      // WriteFrame raises on a broken pipe and would otherwise leak it.
      FreeAndNil(Root);
      Resp := Default(TBridgeResponse);
      Resp.Id := 0;
      Resp.Ok := FALSE;
      Resp.ErrorCode := ErrInvalidRequest;
      Resp.ErrorMessage := 'request is not a JSON object';
      TBridgeWire.WriteFrame(Stream, SerializeResponse(Resp));
      Result := TRUE;   // wire is fine, just a bad frame; keep serving
      exit;
    end;
    try
      if not TryParseRequest(TJSONObject(Root), Req) then
      begin
        Resp := Default(TBridgeResponse);
        Resp.Ok := FALSE;
        Resp.ErrorCode := ErrInvalidRequest;
        Resp.ErrorMessage := 'request missing id or cmd';
        TBridgeWire.WriteFrame(Stream, SerializeResponse(Resp));
        Result := TRUE;
        exit;
      end;

      // Resolve timeout: caller-supplied > per-command default.
      // The 5000 ms bucket is every command that runs USER code on the main thread
      // (Plans/04: "5000 ms (click/set)"): click/set_text/set_checked/set_property fire
      // setters + OnChange/OnClick handlers; execute_action fires OnExecute;
      // dismiss_dialog's SendMessageTimeout alone can block up to 4000 ms on a
      // cross-thread dialog — all of them overran the 2000 ms list/get default.
      if Req.TimeoutMs > 0 then
        Timeout := Req.TimeoutMs
      else if (Req.Cmd = 'click') or (Req.Cmd = 'set_text') or (Req.Cmd = 'set_checked')
           or (Req.Cmd = 'set_property') or (Req.Cmd = 'execute_action') or (Req.Cmd = 'dismiss_dialog') then
        Timeout := DefaultTimeoutClickMs
      else if Req.Cmd = 'screenshot' then
        Timeout := DefaultTimeoutScreenshotMs
      else
        Timeout := DefaultTimeoutListMs;

      BridgeLogInfo('bridge', 'in  id=' + IntToStr(Req.Id) + ' cmd=' + Req.Cmd +
                              ' timeoutMs=' + IntToStr(Timeout));
      T0 := TThread.GetTickCount64;

      // Marshal dispatcher to main thread via a heap-allocated slot shared with the queued proc.
      // Each side holds one reference; both refs must drop for the slot (and its Done event) to
      // free. This fixes Plans/04 R1: previously a stack-captured Resp could be written by the
      // late-firing queued proc after the worker had moved on, leaking the produced ResultJson.
      // It also fixes the related Done-event lifetime bug: if the worker timed out and freed
      // Done while the queued proc was mid-SetEvent, that was a use-after-free.
      Slot := TDispatchSlot.Create;     // refcount = 1 (worker)
      try
        Slot.Resp.Id := Req.Id;
        // Deep-copy Args into the slot BEFORE queuing. The queued dispatcher reads the
        // clone, not the worker's Root: on the timeout path the worker frees Root (line
        // FreeAndNil(Root) below) and moves on while the late-firing proc may still run —
        // dereferencing the original Args then would be a use-after-free. Clone (if it
        // raises) does so before AddRef, so the finally's single Release still frees the slot.
        if Req.Args <> NIL then
          Slot.ArgsClone := TJSONObject(Req.Args.Clone);

        CapturedReq := Req;
        CapturedReq.Args := Slot.ArgsClone;   // weak ref into the slot-owned copy (NIL when no args)
        Slot.AddRef;                     // refcount = 2 (queued proc will drop its ref when done)

        TThread.Queue(NIL,
          procedure
          var
            LocalResp: TBridgeResponse;
          begin
            try
              try
                LocalResp := FDispatch(CapturedReq);
              except
                on E: Exception do
                begin
                  // Log on the target side too — the client gets the error in its frame, but
                  // without this, the bridge's own log file shows no trace of what failed.
                  BridgeLogError('bridge', 'dispatcher raised: id=' + IntToStr(CapturedReq.Id) +
                                           ' cmd=' + CapturedReq.Cmd +
                                           ' ' + E.ClassName + ': ' + E.Message);
                  LocalResp := Default(TBridgeResponse);
                  LocalResp.Id := CapturedReq.Id;
                  LocalResp.Ok := FALSE;
                  LocalResp.ErrorCode := ErrInternalError;
                  LocalResp.ErrorMessage := E.ClassName + ': ' + E.Message;
                end;
              end;
              if Slot.TryClaim(1) then
              begin
                // Winner: hand the produced response to the slot.
                Slot.Resp := LocalResp;
                LocalResp.ResultJson := NIL;     // ownership moved
                Slot.Done.SetEvent;
              end
              else
              begin
                // Loser: worker already timed out. Free anything we produced. Both owned
                // members must go: success responses carry ResultJson, but set_property /
                // read_property error responses (ErrRttiPropertyMissing) carry an ErrorData
                // object (availableProperties). The worker's own timeout response is what
                // reaches SerializeResponse, so this LocalResp is never serialized — freeing
                // only ResultJson leaked that ErrorData on a dispatch-timeout race.
                if LocalResp.ResultJson <> NIL then
                  FreeAndNil(LocalResp.ResultJson);
                if LocalResp.ErrorData <> NIL then
                  FreeAndNil(LocalResp.ErrorData);
              end;
            finally
              Slot.Release;     // queued proc drops its ref
            end;
          end);

        // EINTR-safe timed wait. On Android a stray signal interrupts sem_timedwait and
        // TEvent.WaitFor maps every non-ETIMEDOUT failure — EINTR included — to wrError,
        // with no retry (System.SyncObjs.pas:1004-1013); treating wrError as a timeout
        // here produced a spurious -32004 long before the deadline. Re-wait for the time
        // still remaining, deadline anchored at T0 so retries never extend the budget.
        // On Windows the non-alertable wait on a valid event never returns wrError, so
        // the loop body never runs.
        WaitRes := Slot.Done.WaitFor(Timeout);
        while WaitRes = wrError do
        begin
          ElapsedMs := TThread.GetTickCount64 - T0;
          if ElapsedMs >= Timeout then
          begin
            WaitRes := wrTimeout;
            Break;
          end;
          WaitRes := Slot.Done.WaitFor(Timeout - Cardinal(ElapsedMs));
        end;

        if WaitRes = wrSignaled then
        begin
          // Queued proc finished and won the claim. Slot.Resp is the dispatch result.
          Resp := Slot.Resp;
          Slot.Resp.ResultJson := NIL;     // ownership moved out of slot
        end
        else if Slot.TryClaim(2) then
        begin
          // Worker won the claim with a timeout error. Queued proc, if it eventually fires,
          // will see state<>0, lose the claim, and free what it produced.
          Resp := Default(TBridgeResponse);
          Resp.Id := Req.Id;
          Resp.Ok := FALSE;
          Resp.ErrorCode := ErrMainThreadBlocked;
          Resp.ErrorMessage := 'main thread did not respond within ' + IntToStr(Timeout) + ' ms';
        end
        else
        begin
          // Race: queued proc claimed between our WaitFor expiry and TryClaim(2). The
          // winner writes Slot.Resp only AFTER its claim and sets Done right after the
          // write — so wait for Done before reading, or this branch can copy a
          // half-written record (a garbage ok=false/code=0 response goes out and the
          // winner's ResultJson/ErrorData leak). The wait is bounded: the winner is two
          // straight-line assignments away from SetEvent and nothing in between can raise.
          // Loop: on Android a signal can interrupt sem_wait (EINTR) and TEvent.WaitFor
          // returns wrError without re-arming — the event is refcount-held, so re-wait.
          // On Windows the non-alertable wait on a valid event only returns wrSignaled.
          while Slot.Done.WaitFor(INFINITE) <> wrSignaled do
            ; // re-arm
          Resp := Slot.Resp;
          Slot.Resp.ResultJson := NIL;
        end;
      finally
        Slot.Release;     // worker drops its ref. Slot survives if queued proc still holds one.
      end;

      if Resp.Ok then
        BridgeLogInfo('bridge', 'out id=' + IntToStr(Resp.Id) + ' cmd=' + Req.Cmd + ' ok' +
                                ' elapsedMs=' + IntToStr(TThread.GetTickCount64 - T0))
      else
        BridgeLogWarn('bridge', 'out id=' + IntToStr(Resp.Id) + ' cmd=' + Req.Cmd +
                                ' err=' + IntToStr(Resp.ErrorCode) + ' "' + Resp.ErrorMessage + '"' +
                                ' elapsedMs=' + IntToStr(TThread.GetTickCount64 - T0));
      TBridgeWire.WriteFrame(Stream, SerializeResponse(Resp));
      Result := TRUE;
    finally
      FreeAndNil(Root);
    end;
  finally
    FreeAndNil(Stream);
  end;
end;


procedure TBridgeWorker.Execute;
begin
  NameThreadForDebugging('Autopilot.Bridge.Worker');
  BridgeLogInfo('bridge', 'worker started, endpoint=' + FTransport.EndpointLabel);
  try
    while not Terminated do
    begin
      // (Re-)arm the listener. Pipe: a fresh instance per client session.
      // Socket: created once, no-op afterwards.
      try
        FTransport.StartListening;
      except
        on E: Exception do
        begin
          BridgeLogError('bridge', 'StartListening failed: ' + E.ClassName + ': ' + E.Message);
          // Can't arm the listener. Sleep briefly and try again so we don't busy-loop on a
          // transient error. If the error is persistent (someone else owns the endpoint),
          // it'll keep failing — which is fine, the worker just stays idle until terminated.
          if Terminated then exit;
          TThread.Sleep(500);
          Continue;
        end;
      end;

      // FALSE = woken for shutdown, or a transient accept failure the transport
      // already cleaned up after. Terminated distinguishes the two.
      if not FTransport.AcceptConnection then
      begin
        if Terminated then exit;
        Continue;
      end;

      // Re-check Terminated before doing anything with the new client. The transport
      // swallows its own shutdown phantom (pipe self-connect) inside AcceptConnection,
      // but a REAL client can land in the window between Terminate and WakeAndStop —
      // serving it mid-shutdown races the RTL's exception machinery against the main
      // thread's teardown (was AVing in @HandleAnyException — the Plans/04 pre-existing
      // intermittent). Quietly recycle and exit.
      if Terminated then
      begin
        FTransport.RecycleConnection;
        exit;
      end;

      BridgeLogInfo('bridge', 'client connected');
      try
        HandshakeOrFail;
        // Serve requests until the connection breaks.
        while (not Terminated) and ServeOneRequest do
          ; // loop
      except
        on E: Exception do
          BridgeLogWarn('bridge', 'session ended with ' + E.ClassName + ': ' + E.Message);
      end;
      BridgeLogInfo('bridge', 'client disconnected');

      FTransport.RecycleConnection;
    end;
  finally
    BridgeLogInfo('bridge', 'worker exit');
  end;
end;


end.
