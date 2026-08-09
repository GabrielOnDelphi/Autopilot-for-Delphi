UNIT Autopilot.Bridge.Worker;

{=====================================================
   2026.06.10
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────┐
   │  SHARED  (all platforms)     │   stdlib-only; the transport is injected
   └──────────────────────────────┘

   The shared bridge worker, extracted from Autopilot.Bridge.NamedPipe (2026-06-10,
   Phase B of " Plans\05_AndroidTransport.md"). Owns one IBridgeTransport and runs
   the session loop over it: accept -> handshake -> serve requests -> recycle.
   The transport supplies the listener, the wake mechanism and a TStream per
   connection; this unit never touches Win32 or POSIX I/O directly.

   Win32 -> RTL swaps made during the extraction (behaviour-identical):
     Interlocked* (Winapi)  -> TInterlocked.*    (System.SyncObjs)
     GetTickCount64 (Winapi)-> TThread.GetTickCount64 (System.Classes)
     Sleep (Winapi)         -> TThread.Sleep
     GetCurrentProcessId    -> CurrentPid (IFDEF'd: Win32 / getpid)

   The dispatcher (which DOES touch VCL/FMX) is injected as a callback —
   the worker calls it via TThread.Queue so it runs on the main thread.

   Each command round-trip:
     1. Read length-prefixed frame
     2. Parse JSON request
     3. Marshal dispatcher call onto main thread via TThread.Queue
        + wait on TEvent with per-command timeout
     4. Write length-prefixed response frame
     5. On a broken connection: RecycleConnection -> loop back to AcceptConnection

   See Plans/01_TargetUnit.md "Threading model" and "Connection recovery".
=====================================================}

INTERFACE

USES
  System.SysUtils, System.Classes, System.SyncObjs, System.JSON,
  Autopilot.Bridge.Core, Autopilot.Bridge.Transport;

TYPE
  /// One worker thread per bridge instance. Owns the transport (released after the
  /// thread is joined). Cooperates with the dispatcher (which lives in
  /// Autopilot.Bridge.Vcl / .Fmx) via the callback.
  TBridgeWorker = CLASS(TThread)
  STRICT PRIVATE
    FTransport : IBridgeTransport;
    FDispatch  : TBridgeDispatcher;
    FExeName   : String;

    PROCEDURE HandshakeOrFail;
    FUNCTION  ServeOneRequest: Boolean;  // returns FALSE on connection failure → caller recycles
  PROTECTED
    PROCEDURE Execute; OVERRIDE;
  PUBLIC
    /// ATransport: the listener/connection provider (pipe on Windows, socket on Android).
    /// ADispatch must run a TBridgeRequest on the main thread.
    /// AExeName: short exe filename used in the hello frame.
    CONSTRUCTOR Create(CONST ATransport: IBridgeTransport; CONST AExeName: String; ADispatch: TBridgeDispatcher);
    DESTRUCTOR Destroy; OVERRIDE;
  END;


IMPLEMENTATION

USES
  {$IFDEF MSWINDOWS}
  Winapi.Windows,     // GetCurrentProcessId for the hello frame
  {$ELSE}
  Posix.Unistd,       // getpid for the hello frame
  {$ENDIF}
  Autopilot.Bridge.Log;


FUNCTION CurrentPid: Cardinal;
BEGIN
  {$IFDEF MSWINDOWS}
  Result := GetCurrentProcessId;
  {$ELSE}
  Result := Cardinal(getpid);
  {$ENDIF}
END;


{ TBridgeWorker --------------------------------------------------------- }

CONSTRUCTOR TBridgeWorker.Create(CONST ATransport: IBridgeTransport; CONST AExeName: String; ADispatch: TBridgeDispatcher);
BEGIN
  Assert(Assigned(ADispatch), 'TBridgeWorker: dispatcher cannot be nil');
  Assert(ATransport <> NIL,   'TBridgeWorker: transport cannot be nil');
  FTransport := ATransport;
  FExeName   := AExeName;
  FDispatch  := ADispatch;
  inherited Create(FALSE);    // start immediately; not suspended
  FreeOnTerminate := FALSE;   // owner controls lifetime
END;


DESTRUCTOR TBridgeWorker.Destroy;
BEGIN
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
END;


TYPE
  // Heap-allocated, reference-counted slot shared between the worker and the queued dispatcher.
  // ServeOneRequest creates one slot per request. Each side holds one ref; whoever drops the
  // last ref frees the slot AND the embedded Done event, so the worker can return from the
  // request without waiting for the late-firing queued procedure to settle.
  // Ownership transfer of the response payload is atomic (TInterlocked.CompareExchange on State).
  // Fixes Plans/04 R1: previously a stack-captured Resp could be written by the late-firing
  // queued proc after the worker had already moved on, leaking the produced ResultJson.
  TDispatchSlot = CLASS
  STRICT PRIVATE
    FRefCount: Integer;
    FState   : Integer;   // 0=pending, 1=dispatched (queued proc wrote Resp), 2=timeout (worker wrote Resp)
  PUBLIC
    Resp: TBridgeResponse;
    Done: TEvent;
    // Deep copy of the request's Args, owned by the slot. The queued dispatcher reads
    // THIS (not the worker's parsed Root) so the timeout path can FreeAndNil(Root) without
    // dangling the Args the late-firing proc still dereferences. Freed in Destroy when the
    // last ref drops — outlives both the worker's return AND a late proc run.
    ArgsClone: TJSONObject;
    CONSTRUCTOR Create;
    DESTRUCTOR Destroy; OVERRIDE;
    PROCEDURE AddRef;
    PROCEDURE Release;
    // Returns TRUE if this caller wins the claim (no one else has claimed yet).
    // ANewState must be 1 (dispatched) or 2 (timeout).
    FUNCTION TryClaim(ANewState: Integer): Boolean;
    PROPERTY State: Integer READ FState;
  END;


CONSTRUCTOR TDispatchSlot.Create;
BEGIN
  inherited;
  FRefCount := 1;
  FState    := 0;
  Resp      := Default(TBridgeResponse);
  ArgsClone := NIL;
  Done      := TEvent.Create(NIL, TRUE, FALSE, '');
END;


DESTRUCTOR TDispatchSlot.Destroy;
BEGIN
  FreeAndNil(Done);
  // Whoever drops the last ref frees any ResultJson the loser produced.
  // SerializeResponse on the winner clears ResultJson before this point.
  if Resp.ResultJson <> NIL then
    FreeAndNil(Resp.ResultJson);
  // Free the owned Args copy (no-op if the request had no args).
  if ArgsClone <> NIL then
    FreeAndNil(ArgsClone);
  inherited;
END;


PROCEDURE TDispatchSlot.AddRef;
BEGIN
  TInterlocked.Increment(FRefCount);
END;


PROCEDURE TDispatchSlot.Release;
BEGIN
  if TInterlocked.Decrement(FRefCount) = 0 then
    Free;
END;


FUNCTION TDispatchSlot.TryClaim(ANewState: Integer): Boolean;
BEGIN
  Result := TInterlocked.CompareExchange(FState, ANewState, 0) = 0;
END;


PROCEDURE TBridgeWorker.HandshakeOrFail;
VAR
  HelloRoot : TJSONObject;
  HelloText : String;
  Stream    : TStream;
  Ack       : String;
  AckRoot   : TJSONValue;
  AckPV     : TJSONValue;
BEGIN
  HelloRoot := BuildHelloJson(FExeName, CurrentPid);
  TRY
    HelloText := HelloRoot.ToJSON;
  FINALLY
    FreeAndNil(HelloRoot);
  END;

  // The transport OWNS the connection — the stream is a view over it and does
  // not close the underlying handle/fd. We own the stream object.
  Stream := FTransport.ConnectionStream;
  TRY
    TBridgeWire.WriteFrame(Stream, HelloText);

    if not TBridgeWire.TryReadFrame(Stream, Ack) then
      raise EReadError.Create('Bridge: handshake read failed');

    AckRoot := TJSONObject.ParseJSONValue(Ack);
    TRY
      if not (AckRoot IS TJSONObject) then
        raise EParserError.Create('Bridge: handshake reply not an object');
      AckPV := TJSONObject(AckRoot).GetValue('helloAck');
      if not (AckPV IS TJSONObject) then
        raise EParserError.Create('Bridge: handshake reply missing helloAck');
      AckPV := TJSONObject(AckPV).GetValue('protocolVersion');
      if not (AckPV IS TJSONNumber) then
        raise EParserError.Create('Bridge: handshake reply missing protocolVersion');
      if TJSONNumber(AckPV).AsInt <> ProtocolVersion then
        raise EParserError.Create('Bridge: protocol mismatch (server wants ' +
                                  IntToStr(TJSONNumber(AckPV).AsInt) +
                                  ', we speak ' + IntToStr(ProtocolVersion) + ')');
    FINALLY
      FreeAndNil(AckRoot);
    END;
  FINALLY
    FreeAndNil(Stream);
  END;
END;


FUNCTION TBridgeWorker.ServeOneRequest: Boolean;
VAR
  Stream  : TStream;
  FrameIn : String;
  Root    : TJSONValue;
  Req     : TBridgeRequest;
  Resp    : TBridgeResponse;
  Timeout : Cardinal;
  CapturedReq: TBridgeRequest;
  Slot    : TDispatchSlot;
  T0      : UInt64;
BEGIN
  Result := FALSE;
  Stream := FTransport.ConnectionStream;
  TRY
    if not TBridgeWire.TryReadFrame(Stream, FrameIn) then EXIT;  // connection closed / EOF

    Root := TJSONObject.ParseJSONValue(FrameIn);
    if not (Root IS TJSONObject) then
    begin
      Resp := Default(TBridgeResponse);
      Resp.Id := 0;
      Resp.Ok := FALSE;
      Resp.ErrorCode := ErrInvalidRequest;
      Resp.ErrorMessage := 'request is not a JSON object';
      TBridgeWire.WriteFrame(Stream, SerializeResponse(Resp));
      FreeAndNil(Root);
      Result := TRUE;   // wire is fine, just a bad frame; keep serving
      EXIT;
    end;
    TRY
      if not TryParseRequest(TJSONObject(Root), Req) then
      begin
        Resp := Default(TBridgeResponse);
        Resp.Ok := FALSE;
        Resp.ErrorCode := ErrInvalidRequest;
        Resp.ErrorMessage := 'request missing id or cmd';
        TBridgeWire.WriteFrame(Stream, SerializeResponse(Resp));
        Result := TRUE;
        EXIT;
      end;

      // Resolve timeout: caller-supplied > per-command default
      if Req.TimeoutMs > 0 then
        Timeout := Req.TimeoutMs
      else if (Req.Cmd = 'click') or (Req.Cmd = 'set_text') or (Req.Cmd = 'set_checked') or (Req.Cmd = 'execute_action') then
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
      TRY
        Slot.Resp.Id := Req.Id;
        // Deep-copy Args into the slot BEFORE queuing. The queued dispatcher reads the
        // clone, not the worker's Root: on the timeout path the worker frees Root (line
        // FreeAndNil(Root) below) and moves on while the late-firing proc may still run —
        // dereferencing the original Args then would be a use-after-free. Clone (if it
        // raises) does so before AddRef, so the FINALLY's single Release still frees the slot.
        if Req.Args <> NIL then
          Slot.ArgsClone := TJSONObject(Req.Args.Clone);

        CapturedReq := Req;
        CapturedReq.Args := Slot.ArgsClone;   // weak ref into the slot-owned copy (NIL when no args)
        Slot.AddRef;                     // refcount = 2 (queued proc will drop its ref when done)

        TThread.Queue(NIL,
          PROCEDURE
          VAR
            LocalResp: TBridgeResponse;
          BEGIN
            TRY
              TRY
                LocalResp := FDispatch(CapturedReq);
              EXCEPT
                ON E: Exception DO
                BEGIN
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
                END;
              END;
              if Slot.TryClaim(1) then
              begin
                // Winner: hand the produced response to the slot.
                Slot.Resp := LocalResp;
                LocalResp.ResultJson := NIL;     // ownership moved
                Slot.Done.SetEvent;
              end
              else
              begin
                // Loser: worker already timed out. Free anything we produced.
                if LocalResp.ResultJson <> NIL then
                  FreeAndNil(LocalResp.ResultJson);
              end;
            FINALLY
              Slot.Release;     // queued proc drops its ref
            END;
          END);

        if Slot.Done.WaitFor(Timeout) = wrSignaled then
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
          // Race: queued proc claimed during WaitFor expiry. Take its result.
          Resp := Slot.Resp;
          Slot.Resp.ResultJson := NIL;
        end;
      FINALLY
        Slot.Release;     // worker drops its ref. Slot survives if queued proc still holds one.
      END;

      if Resp.Ok then
        BridgeLogInfo('bridge', 'out id=' + IntToStr(Resp.Id) + ' cmd=' + Req.Cmd + ' ok' +
                                ' elapsedMs=' + IntToStr(TThread.GetTickCount64 - T0))
      else
        BridgeLogWarn('bridge', 'out id=' + IntToStr(Resp.Id) + ' cmd=' + Req.Cmd +
                                ' err=' + IntToStr(Resp.ErrorCode) + ' "' + Resp.ErrorMessage + '"' +
                                ' elapsedMs=' + IntToStr(TThread.GetTickCount64 - T0));
      TBridgeWire.WriteFrame(Stream, SerializeResponse(Resp));
      Result := TRUE;
    FINALLY
      FreeAndNil(Root);
    END;
  FINALLY
    FreeAndNil(Stream);
  END;
END;


PROCEDURE TBridgeWorker.Execute;
BEGIN
  NameThreadForDebugging('Autopilot.Bridge.Worker');
  BridgeLogInfo('bridge', 'worker started, endpoint=' + FTransport.EndpointLabel);
  TRY
    WHILE not Terminated DO
    BEGIN
      // (Re-)arm the listener. Pipe: a fresh instance per client session.
      // Socket: created once, no-op afterwards.
      TRY
        FTransport.StartListening;
      EXCEPT
        ON E: Exception DO
        BEGIN
          BridgeLogError('bridge', 'StartListening failed: ' + E.ClassName + ': ' + E.Message);
          // Can't arm the listener. Sleep briefly and try again so we don't busy-loop on a
          // transient error. If the error is persistent (someone else owns the endpoint),
          // it'll keep failing — which is fine, the worker just stays idle until terminated.
          if Terminated then EXIT;
          TThread.Sleep(500);
          Continue;
        END;
      END;

      // FALSE = woken for shutdown, or a transient accept failure the transport
      // already cleaned up after. Terminated distinguishes the two.
      if not FTransport.AcceptConnection then
      begin
        if Terminated then EXIT;
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
        EXIT;
      end;

      BridgeLogInfo('bridge', 'client connected');
      TRY
        HandshakeOrFail;
        // Serve requests until the connection breaks.
        WHILE (not Terminated) and ServeOneRequest DO
          ; // loop
      EXCEPT
        ON E: Exception DO
          BridgeLogWarn('bridge', 'session ended with ' + E.ClassName + ': ' + E.Message);
      END;
      BridgeLogInfo('bridge', 'client disconnected');

      FTransport.RecycleConnection;
    END;
  FINALLY
    BridgeLogInfo('bridge', 'worker exit');
  END;
END;


END.
