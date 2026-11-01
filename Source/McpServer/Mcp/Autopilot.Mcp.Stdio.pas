unit Autopilot.Mcp.Stdio;

{=============================================================================================================
   2026.11.01
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
   startup we force both text files to CP_UTF8 (SetTextCodePage), and Writeln encodes as UTF-8.
   Each stdin line is read as raw bytes (ReadLineBytes) and decoded strictly (TryDecodeUtf8Line):
   a line that is not valid UTF-8 is answered -32700 Parse error, never processed with replaced
   characters. The wire is ASCII both ways in practice (Claude Code escapes non-ASCII as \uXXXX in
   requests; our System.JSON escapes every char > 127 the same way in responses).
=============================================================================================================}

interface

uses
  System.SysUtils;


/// Read one line of AFile and return its bytes. AFile's code page must be CP_UTF8 (EnableUtf8Io sets it for Input).
function ReadLineBytes(var AFile: TextFile): TBytes;

/// Decode one stdin line from UTF-8. A leading UTF-8 byte order mark is dropped.
/// FALSE when the bytes are not valid UTF-8; ALine is then ''.
function TryDecodeUtf8Line(const ABytes: TBytes; OUT ALine: String): Boolean;

/// The answer to one stdin line given as its raw bytes: the JSON-RPC response line, or '' when nothing is sent
/// back (a notification, a blank line).
function AnswerLine(const ABytes: TBytes): String;

/// Run the stdio loop. Returns when stdin closes (EOF). Single-threaded.
procedure RunStdioServer;


implementation

uses
  System.JSON, Winapi.Windows,
  Autopilot.Bridge.Log,
  Autopilot.Mcp.JsonRpc;


/// Force stdin and stdout to UTF-8. For piped stdio Delphi would otherwise decode/encode via
/// DefaultSystemCodePage (ANSI); SetTextCodePage overrides the text-file codepage, so Writeln encodes
/// UTF-8 and ReadLineBytes (Readln into a UTF8String) copies the bytes of a line unchanged.
/// SetConsoleOutputCP additionally covers the rare real-console case. Safe to set before the first read:
/// _ReadByte opens Input via its Mode check, and TextOpen preserves a non-zero CodePage. _ReadLString reads
/// a whole line of bytes, so a multi-byte UTF-8 sequence never splits across the read buffer.
/// Best-effort; a failed SetConsoleOutputCP is logged.
procedure EnableUtf8Io;
begin
  if not SetConsoleOutputCP(CP_UTF8) then
    BridgeLogWarn('mcp', 'SetConsoleOutputCP(CP_UTF8) failed; LastError=' + IntToStr(GetLastError));
  SetTextCodePage(Output, CP_UTF8);
  SetTextCodePage(Input, CP_UTF8);
end;


/// Readln into a UTF8String: when the file's code page is CP_UTF8 too, System._ReadLString copies the bytes of
/// the line unchanged. Readln into a String would decode them leniently, turning invalid bytes into U+FFFD.
function ReadLineBytes(var AFile: TextFile): TBytes;
var
  Raw: UTF8String;
begin
  Readln(AFile, Raw);
  Result := BytesOf(RawByteString(Raw));
end;


/// Strict: TEncoding.UTF8 is created with MB_ERR_INVALID_CHARS, so GetCharCount answers 0 for invalid bytes.
/// The round trip back to bytes also refuses what the decoder lets through as a replacement character or as a
/// lone surrogate.
function TryDecodeUtf8Line(const ABytes: TBytes; OUT ALine: String): Boolean;
var
  Start, Count, i: Integer;
  Back: TBytes;
begin
  ALine := '';

  // Claude Code never sends a byte order mark, but PowerShell's pipe to a native program typically puts
  // EF BB BF in front of the first line, and ParseJSONValue would refuse the line with -32700.
  Start := 0;
  if (Length(ABytes) >= 3) and (ABytes[0] = $EF) and (ABytes[1] = $BB) and (ABytes[2] = $BF) then
    Start := 3;
  Count := Length(ABytes) - Start;
  if Count = 0 then
    EXIT(TRUE);

  if TEncoding.UTF8.GetCharCount(ABytes, Start, Count) = 0 then
    EXIT(FALSE);
  ALine := TEncoding.UTF8.GetString(ABytes, Start, Count);

  Back   := TEncoding.UTF8.GetBytes(ALine);
  Result := Length(Back) = Count;
  i := 0;
  while Result and (i < Count) do
  begin
    Result := Back[i] = ABytes[Start + i];
    Inc(i);
  end;
  if not Result then
    ALine := '';
end;


function AnswerLine(const ABytes: TBytes): String;
var
  Line: String;
  JErr: TJSONString;
begin
  if not TryDecodeUtf8Line(ABytes, Line) then
  begin
    BridgeLogWarn('mcp', 'recv: a line of ' + IntToStr(Length(ABytes)) + ' bytes is not valid UTF-8; answered -32700');
    EXIT('{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error: the line is not valid UTF-8"}}');
  end;

  if Line.Trim = '' then EXIT('');
  BridgeLogInfo('mcp', 'recv: ' + Line);

  try
    Result := DispatchLine(Line);
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
        Result := '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":' + JErr.ToJSON + '}}';
      finally
        FreeAndNil(JErr);
      end;
    end;
  end;
end;


procedure RunStdioServer;
var
  Bytes   : TBytes;
  Response: String;
begin
  EnableUtf8Io;
  BridgeLogInfo('mcp', 'stdio loop entered');

  while not Eof(Input) do
  begin
    try
      Bytes := ReadLineBytes(Input);
    except
      on E: Exception do
      begin
        // A broken pipe on stdin shows up here. Treat as EOF.
        BridgeLogWarn('mcp', 'stdin readln failed: ' + E.ClassName + ': ' + E.Message);
        Break;
      end;
    end;

    Response := AnswerLine(Bytes);
    if Response = '' then Continue;  // notification or blank line — no reply

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
