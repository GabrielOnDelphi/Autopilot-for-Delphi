unit Autopilot.Mcp.UsageCounter;

{=============================================================================================================
   2026.11.02
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - Counts MCP-server launches and keeps one one-shot flag in %APPDATA%\Autopilot\usage.ini: a tip line in the log, once, after a few launches (TrackUsage)
   - Never a dialog and never a browser launch: the MCP server is headless (stdout is the JSON-RPC channel) and the operator is often away during an unattended AI run.
   - Stdlib only (System.IniFiles), so the MCP server stays dependency-clean.
=============================================================================================================}

interface

{ Increment the launch count and, the first time it passes TipAfterUses, log the tip once.
  Call once per MCP-server startup.
  Never raises: a usage counter must not take down the server. }
procedure TrackUsage;


implementation

uses
  System.SysUtils, System.IOUtils, System.IniFiles,
  Autopilot.Bridge.Log;

const
  TipAfterUses = 5;   // log on the 6th launch (count > 5)

  TipURL  = 'https://gabrielmoraru.com/the-delphi-in-all-its-glory-book-5-ai-assisted-development-for-delphi/';
  TipText = 'Enjoying Autopilot? The full AI-with-Delphi workflow is Book 5 of "Delphi in All Its Glory": ' + TipURL;


function UsageIniPath: String;
var
  Folder: String;
begin
  Folder := TPath.Combine(TPath.GetHomePath, 'Autopilot');   // %APPDATA%\Autopilot
  if not TDirectory.Exists(Folder)
  then TDirectory.CreateDirectory(Folder);
  Result := TPath.Combine(Folder, 'usage.ini');
end;


procedure TrackUsage;
var
  Ini  : TMemIniFile;
  Count: Integer;
begin
  try
    Ini := TMemIniFile.Create(UsageIniPath);
    try
      Count := Ini.ReadInteger('Usage', 'Count', 0) + 1;
      Ini.WriteInteger('Usage', 'Count', Count);

      if (Count > TipAfterUses) and (not Ini.ReadBool('Usage', 'TipShown', FALSE)) then
        begin
          BridgeLogInfo('tip', TipText);
          Ini.WriteBool('Usage', 'TipShown', TRUE);
        end;

      Ini.UpdateFile;
    finally
      FreeAndNil(Ini);
    end;
  except
    { Same contract as the logger (Autopilot.Bridge.Log): a usage counter must never crash the host.
      Log and carry on instead of reraising. }
    on E: Exception do
      BridgeLogWarn('tip', 'usage counter skipped: ' + E.ClassName + ': ' + E.Message);
  end;
end;


end.
