# Autopilot for Delphi - troubleshooting

> Part of `AI-INSTRUCTIONS.md` (same folder): what to check when a call fails, the target does not answer, or the MCP tools are not available.

## Quick verification when something looks wrong

Three checks, in order:

1. **Is the target running with the bridge?** In PowerShell:

   ```powershell
   Get-ChildItem "$env:TEMP\Autopilot\active\"
   ```

   Empty: the target is not running, or was built without the `AUTOPILOT` conditional define.

2. **Is the pipe alive?**

   ```powershell
   Get-ChildItem \\.\pipe\ | Where-Object Name -like "Autopilot.*"
   ```

   Empty while the discovery file exists: the bridge crashed, or `StopBridge` was called.

3. **Is the MCP server registered?** Its tools appear in your tool list as `mcp__autopilot__*`.
   If they are missing, the user must register the MCP server with the host again (`claude mcp add autopilot ...` on Claude Code; keep `--crash-report` or `--no-crash-report` at the end if the old registration had it).
   **Registering does NOT help the session you are in:** an MCP host reads its server list at session start, so the tools appear only in the *next* session.
   Check with `claude mcp list` that it shows `✓ Connected`, then start a fresh session, or, to act in the current one, drive the pipe directly (next section).

## Driving the bridge without the MCP tools (raw named pipe)

When the `mcp__autopilot__*` tools are not loaded (the server was registered in this session, the host has not picked it up, or you script from a shell), talk to the bridge directly over its Windows named pipe.
For repeatable tests written in Delphi, write no pipe client: use `TAutopilotApp` (`Source\Client\Autopilot.Client - how to write GUI tests without AI.md`).

**Wire format:** every frame is a **4-byte little-endian length**, followed by that many bytes of **UTF-8 JSON**.

**Connection sequence:**

1. Find the pipe: `\\.\pipe\Autopilot.<ExeBaseName>.<PID>` (enumerate `\\.\pipe\` for `Autopilot.*`, or read the discovery file `%TEMP%\Autopilot\active\<PID>.pipe`, whose content IS the pipe name).
2. Connect: the target sends a `{"hello":{"protocolVersion":1,...}}` frame **first**.
3. Reply with `{"helloAck":{"protocolVersion":1}}` (on a version mismatch the worker drops the session).
4. Send requests `{"id":N,"cmd":"...","args":{...}}`; read one response frame `{"id":N,"ok":true,"result":{...}}` per request.
   `args` holds the tool's arguments under the same camelCase names (`path`, `count`, `text`, `checked`, `propName`, `value`, `form`, ...), without `pid`; `timeoutMs` goes beside `cmd`, not into `args`.
   `attach` and `wait_for` exist only in the MCP server, not in the bridge: poll `get_text` yourself.

**Minimal PowerShell client** (handshake + one command):

```powershell
$full = [System.IO.Directory]::GetFiles("\\.\pipe\") |
        Where-Object { $_ -like "*Autopilot.<ExeBaseName>.*" } | Select-Object -First 1
$name = ($full -split '\\')[-1]   # strip the \\.\pipe\ prefix
$c = New-Object System.IO.Pipes.NamedPipeClientStream(".", $name, "InOut"); $c.Connect(5000)
function RF($s){ $b=[byte[]]::new(4); $g=0; while($g-lt4){$n=$s.Read($b,$g,4-$g); if($n-le0){throw "EOF"}; $g+=$n}
  $len=[BitConverter]::ToUInt32($b,0); if($len-eq0){return ""}; $p=[byte[]]::new($len); $g=0
  while($g-lt$len){$n=$s.Read($p,$g,$len-$g); if($n-le0){throw "EOF"}; $g+=$n}; [Text.Encoding]::UTF8.GetString($p) }
function WF($s,$t){ $p=[Text.Encoding]::UTF8.GetBytes($t); $s.Write([BitConverter]::GetBytes([uint32]$p.Length),0,4)
  if($p.Length){$s.Write($p,0,$p.Length)}; $s.Flush() }
$null = RF $c                                        # read hello
WF $c '{"helloAck":{"protocolVersion":1}}'           # send ack
WF $c '{"id":1,"cmd":"list_tree"}'; RF $c            # one command + its response
```

## When the MCP server crashes

`Autopilot.Mcp.exe` saves a crash report to `%TEMP%\Autopilot\bugreport Autopilot.Mcp.txt` and never sends it; the first lines of the server's log `%TEMP%\Autopilot\Autopilot.Mcp-<pid>.log` say so (a server built without madExcept has no crash reporter, and its log says that instead).
A user who wants the report sent to SciVance Tech, the maker of Autopilot, registers the server with the parameter `--crash-report` (in either order with `--target adb:<port>`): `claude mcp add autopilot -- <path>\Autopilot.Mcp.exe --crash-report`.
The older parameter `--no-crash-report` is still accepted: it keeps the report on the PC, even beside `--crash-report`.
None of these parameters changes the tools or their answers.
