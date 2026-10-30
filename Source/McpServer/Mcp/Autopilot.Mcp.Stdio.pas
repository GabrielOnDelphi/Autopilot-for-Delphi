unit Autopilot.Mcp.Stdio;

{=============================================================================================================
   2026.09
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

   Stdin / stdout carry UTF-8 per the MCP spec. For redirected stdio (the real case — Claude
   Code pipes it), Delphi opens Input/Output with CodePage = DefaultSystemCodePage (ANSI), NOT
   UTF-8: System.pas TextOpen only uses the console codepage for a true console handle. So at
   startup we force both text files to CP_UTF8 (SetTextCodePage) — Readln then decodes, and
   Writeln encodes, as UTF-8. The wire is ASCII both ways in practice (Claude Code escapes
   non-ASCII as \uXXXX in requests; our System.JSON escapes every char > 127 the same way in
   responses), so this is spec-correctness for any client, not a fix for a visible bug.
=============================================================================================================}

interface


/// Run the stdio loop. Returns when stdin closes (EOF). Single-threaded.
procedure RunStdioServer;


implementation

uses
  System.SysUtils, System.JSON, Winapi.Windows,
  Autopilot.Bridge.Log,
  Autopilot.Mcp.JsonRpc;


/// Force stdin and stdout to UTF-8. For piped stdio Delphi would otherwise decode/encode via
/// DefaultSystemCodePage (ANSI); SetTextCodePage overrides the text-file codepage so Readln and
/// Writeln use UTF-8. SetConsoleOutputCP additionally covers the rare real-console case. Safe to
/// set before the first read: _ReadByte opens Input via its Mode check, and TextOpen preserves a
/// non-zero CodePage. _ReadLString reads a whole line of bytes before converting, so a multi-byte
/// UTF-8 sequence never splits across the read buffer. Best-effort; a failed SetConsoleOutputCP is logged.
procedure EnableUtf8Io;
begin
  if not SetConsoleOutputCP(CP_UTF8) then
    BridgeLogWarn('mcp', 'SetConsoleOutputCP(CP_UTF8) failed; LastError=' + IntToStr(GetLastError));
  SetTextCodePage(Output, CP_UTF8);
  SetTextCodePage(Input, CP_UTF8);
end;


procedure RunStdioServer;
var
  Line, Response: String;
  JErr: TJSONString;
begin
  EnableUtf8Io;
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
    // Two encodings to handle: (a) one Unicode char $FEFF — the normal case now
    // that EnableUtf8Io forces CP_UTF8, since the BOM bytes decode as UTF-8; (b)
    // three separate bytes $EF $BB $BF, the belt-and-braces fallback if the line
    // ever arrived decoded byte-per-char (ANSI). Both head the line.
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
        // Escape the message via TJSONString so backslashes, newlines and quotes
        // in E.Message stay valid JSON. Quote-only escaping emitted broken JSON for
        // Windows paths ("C:\x") and multi-line messages, which the client cannot parse.
        JErr := TJSONString.Create(E.Message);
        try
          Response := '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":' + JErr.ToJSON + '}}';
        finally
          JErr.Free;
        end;
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
