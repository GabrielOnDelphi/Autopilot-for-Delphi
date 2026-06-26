unit Autopilot.Mcp.Stdio;

{=============================================================================================================
   2026.06
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   The MCP server's stdio main loop. Reads one JSON-RPC line at a time from stdin, dispatches it,
   writes the response (if any) to stdout. Logs every request and response to
   %TEMP%\Autopilot\<exe>-<pid>.log via Bridge.Log.

   Per the MCP spec:
     - stdin / stdout carry JSON-RPC messages, one per line, no embedded newlines, UTF-8.
     - stderr is for human-readable logs and MUST NOT be parsed by the client.
     - Shutdown is signalled by the parent closing our stdin (we see EOF on Input).
       No explicit Ctrl-C handling needed.

   We set the console output codepage to UTF-8 once at startup as a defensive measure —
   Writeln(Output, ...) then emits raw UTF-8 bytes regardless of the user's chcp. JSON itself
   is ASCII-safe so this matters only when a tool's response contains non-ASCII (e.g. a
   control's Caption with accented chars).
=============================================================================================================}

interface


/// Run the stdio loop. Returns when stdin closes (EOF). Single-threaded.
procedure RunStdioServer;


implementation

uses
  System.SysUtils, Winapi.Windows,
  Autopilot.Bridge.Log,
  Autopilot.Mcp.JsonRpc;


/// Switch the console output to UTF-8 so accented characters in tool responses
/// land on the wire correctly. Best-effort; we log a warning if it fails but
/// don't abort — JSON-RPC traffic from Claude Code is ASCII-safe in practice.
procedure EnableUtf8Output;
begin
  if not SetConsoleOutputCP(CP_UTF8) then
    BridgeLogWarn('mcp', 'SetConsoleOutputCP(CP_UTF8) failed; LastError=' + IntToStr(GetLastError));
end;


procedure RunStdioServer;
var
  Line, Response: String;
begin
  EnableUtf8Output;
  BridgeLogInfo('mcp', 'stdio loop entered');

  while not Eof(Input) do
  begin
    try
      Readln(Input, Line);
    except
      on E: Exception do
      begin
        // A broken pipe on stdin shows up here. Treat as EOF.
        BridgeLogWarn('mcp', 'stdin readln failed: ' + E.ClassName + ': ' + E.Message);
        Break;
      end;
    end;

    // Strip a UTF-8 BOM if one snuck in. Claude Code never sends one, but
    // PowerShell's pipe-to-native typically prepends EF BB BF, and we don't
    // want it to wreck ParseJSONValue with a -32700.
    //
    // Two encodings to handle: (a) one Unicode char $FEFF if the runtime
    // decoded the bytes as UTF-8 already; (b) three separate bytes
    // $EF $BB $BF if the runtime saw raw bytes (default Readln on Windows
    // does this — the console codepage decides). Both head the line.
    if (Length(Line) >= 1) and (Line[1] = #$FEFF) then
      Delete(Line, 1, 1)
    else if (Length(Line) >= 3) and (Line[1] = #$EF) and (Line[2] = #$BB) and (Line[3] = #$BF) then
      Delete(Line, 1, 3);

    if Line.Trim = '' then Continue;
    BridgeLogInfo('mcp', 'recv: ' + Line);

    try
      Response := DispatchLine(Line);
    except
      on E: Exception do
      begin
        // Dispatcher should swallow its own errors and return an error envelope.
        // If we land here, something escaped — keep the loop alive, log and
        // emit a generic envelope so the client doesn't hang.
        BridgeLogError('mcp', 'dispatch escaped: ' + E.ClassName + ': ' + E.Message);
        Response := '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"' +
                    StringReplace(E.Message, '"', '\"', [rfReplaceAll]) + '"}}';
      end;
    end;

    if Response = '' then Continue;  // notification — no reply

    try
      Writeln(Output, Response);
      Flush(Output);
      BridgeLogInfo('mcp', 'send: ' + Response);
    except
      on E: Exception do
      begin
        // Writing failed — the client closed stdout. Game over.
        BridgeLogError('mcp', 'stdout writeln failed: ' + E.ClassName + ': ' + E.Message);
        Break;
      end;
    end;
  end;

  BridgeLogInfo('mcp', 'stdio loop exited (EOF on stdin)');
end;


end.
