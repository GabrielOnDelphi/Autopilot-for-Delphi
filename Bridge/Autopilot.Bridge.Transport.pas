unit Autopilot.Bridge.Transport;

{=============================================================================================================
   2026.09
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - IBridgeTransport: transport abstraction seam for the shared bridge worker
   - Concrete implementations: TPipeTransport (Windows named pipe) and TSocketTransport (POSIX AF_UNIX)
   - Stdlib-only: no Win32, no POSIX, no VCL, no FMX — the seam itself is platform-agnostic
=============================================================================================================}

interface

uses
  System.Classes;

type
  /// One transport endpoint. Owns the listener and the current connection.
  /// All methods except WakeAndStop are called from the worker thread only.
  /// WakeAndStop is called from the owner thread (the worker's destructor).
  IBridgeTransport = interface
    ['{B6F1A0C2-3D74-4E58-9A1B-7C2E5F0D8A41}']

    /// Create/bind the listener. Raises if the endpoint is already taken
    /// (pipe: FILE_FLAG_FIRST_PIPE_INSTANCE; socket: EADDRINUSE) or on any
    /// other failure — the worker logs, sleeps and retries.
    /// Pipe: creates ONE pipe instance per client session (called each loop).
    /// Socket: creates the listening socket once; later calls are no-ops.
    procedure StartListening;

    /// Block until a client connects. TRUE = a client is connected and ready to
    /// serve. FALSE = woken for shutdown or a transient accept failure — the
    /// transport has already cleaned up its connection state either way, and
    /// the worker decides exit-vs-retry off its own Terminated flag.
    function  AcceptConnection: Boolean;

    /// A NEW TStream view over the live connection. The CALLER frees the stream
    /// after use (one per handshake / per request — cheap). The transport OWNS
    /// the underlying handle/fd; the stream must not close it.
    function  ConnectionStream: TStream;

    /// Tear down the current connection (DisconnectNamedPipe+CloseHandle /
    /// close(connfd)). Pipe: closes the whole instance — the next
    /// StartListening creates a fresh one. Socket: keeps the listener alive.
    /// Idempotent.
    procedure RecycleConnection;

    /// Unblock a thread parked in AcceptConnection and mark the transport
    /// stopping. AWorkerThread is the worker TThread — the pipe transport needs
    /// its Handle for CancelSynchronousIo; the socket transport ignores it
    /// (self-pipe byte). Must be idempotent and callable from the owner thread
    /// while the worker is anywhere in its loop. Does not close the listener
    /// fds/handles — that happens in the transport's destructor, which runs
    /// after the worker has been joined (avoids close-vs-accept races).
    procedure WakeAndStop(AWorkerThread: TThread);

    /// Label for logging and (Windows) the discovery file.
    /// Pipe: the full `\\.\pipe\...` name. Socket: the abstract name 'Autopilot.<pid>'.
    function  EndpointLabel: String;
  end;


implementation

end.
