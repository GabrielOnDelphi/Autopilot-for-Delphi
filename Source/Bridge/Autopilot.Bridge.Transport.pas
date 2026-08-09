UNIT Autopilot.Bridge.Transport;

{=====================================================
   2026.06.10
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────┐
   │  SHARED  (all platforms)     │   stdlib-only interface; no Win32, no POSIX
   └──────────────────────────────┘

   Transport abstraction for the Autopilot bridge worker.

   The shared worker (Autopilot.Bridge.Worker) drives one IBridgeTransport.
   Concrete transports:
     - Windows: Autopilot.Bridge.NamedPipe (CreateNamedPipe + owner ACL + CSI/self-connect wake)
     - Android: Autopilot.Bridge.Socket (AF_UNIX abstract socket + self-pipe wake)

   Stdlib-only. No Win32, no POSIX, no VCL, no FMX.

   Design note: the seam is "give me a TStream for the live connection", NOT
   per-method read/write. That keeps the ServeOneRequest/HandshakeOrFail bodies
   shape-identical to the pre-split pipe worker — they already did
   `Stream := <x>.Create(<conn>)` then TBridgeWire.*(Stream, ...). The framing
   (TBridgeWire in .Core) is transport-agnostic: it takes a TStream and
   ReadFully loops on short reads, which TCP/AF_UNIX produce just as a
   byte-mode pipe does.

   Three named-pipe quirks are ABSORBED by the pipe transport, not leaked here
   (see " Plans\05_AndroidTransport.md" "The interface boundary"):
     1. ERROR_PIPE_CONNECTED race      -> pipe's AcceptConnection maps it to TRUE.
     2. FILE_FLAG_FIRST_PIPE_INSTANCE  -> pipe's StartListening raises if the
                                          endpoint is taken (socket: bind gives
                                          EADDRINUSE — same contract for free).
     3. Phantom self-connect on wake   -> pipe's AcceptConnection swallows it and
                                          returns FALSE (it sets an internal
                                          stopping flag in WakeAndStop). The
                                          worker still re-checks Terminated once
                                          after a TRUE — belt-and-braces for a
                                          REAL client landing between Terminate
                                          and WakeAndStop.
=====================================================}

INTERFACE

USES
  System.Classes;

TYPE
  /// One transport endpoint. Owns the listener and the current connection.
  /// All methods except WakeAndStop are called from the worker thread only.
  /// WakeAndStop is called from the owner thread (the worker's destructor).
  IBridgeTransport = INTERFACE
    ['{B6F1A0C2-3D74-4E58-9A1B-7C2E5F0D8A41}']

    /// Create/bind the listener. Raises if the endpoint is already taken
    /// (pipe: FILE_FLAG_FIRST_PIPE_INSTANCE; socket: EADDRINUSE) or on any
    /// other failure — the worker logs, sleeps and retries.
    /// Pipe: creates ONE pipe instance per client session (called each loop).
    /// Socket: creates the listening socket once; later calls are no-ops.
    PROCEDURE StartListening;

    /// Block until a client connects. TRUE = a client is connected and ready to
    /// serve. FALSE = woken for shutdown OR a transient accept failure — the
    /// transport has already cleaned up its connection state either way, and
    /// the worker decides exit-vs-retry off its own Terminated flag.
    FUNCTION  AcceptConnection: Boolean;

    /// A NEW TStream view over the live connection. The CALLER frees the stream
    /// after use (one per handshake / per request — cheap). The transport OWNS
    /// the underlying handle/fd; the stream must NOT close it.
    FUNCTION  ConnectionStream: TStream;

    /// Tear down the current connection (DisconnectNamedPipe+CloseHandle /
    /// close(connfd)). Pipe: closes the whole instance — the next
    /// StartListening creates a fresh one. Socket: keeps the listener alive.
    /// Idempotent.
    PROCEDURE RecycleConnection;

    /// Unblock a thread parked in AcceptConnection and mark the transport
    /// stopping. AWorkerThread is the worker TThread — the pipe transport needs
    /// its Handle for CancelSynchronousIo; the socket transport ignores it
    /// (self-pipe byte). Must be idempotent and callable from the owner thread
    /// while the worker is anywhere in its loop. Does NOT close the listener
    /// fds/handles — that happens in the transport's destructor, which runs
    /// after the worker has been joined (avoids close-vs-accept races).
    PROCEDURE WakeAndStop(AWorkerThread: TThread);

    /// Label for logging and (Windows) the discovery file.
    /// Pipe: the full `\\.\pipe\...` name. Socket: the abstract name 'Autopilot.<pid>'.
    FUNCTION  EndpointLabel: String;
  END;


IMPLEMENTATION

END.
