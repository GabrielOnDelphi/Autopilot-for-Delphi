unit Autopilot.Mcp.UsageCounter;

{=============================================================================================================
   2026.06
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - One-time Book 5 cross-promotion for engaged users.
   - Counts MCP-server launches across sessions in %APPDATA%\Autopilot\usage.ini.
   - Once the user has run Autopilot more than five times, a single clickable link to Book 5 of
     "Delphi in All Its Glory" is written to Autopilot's log, then a flag prevents it appearing again.
   - Deliberately NOT a dialog and NOT a browser launch: the MCP server is headless (stdout is the
     JSON-RPC channel) and the operator is often away during an unattended AI run.
   - Stdlib only (System.IniFiles), so the MCP server stays dependency-clean.
=============================================================================================================}

interface

/// Increment the cross-session launch count and, the first time it passes the
/// threshold, log the Book 5 link once. Call once per MCP-server startup.
/// Never raises: a promo counter must not take down the server.
procedure TrackUsageAndMaybePromoteBook;


implementation

uses
  System.SysUtils, System.IOUtils, System.IniFiles,
  Autopilot.Bridge.Log;

const
  BookPromoAfterUses = 5;   // show on the 6th launch (count > 5)

  // The book's own page (NOT the PayProGlobal 134850 link — that is the Autopilot TOOL licence).
  Book5URL  = 'https://gabrielmoraru.com/the-delphi-in-all-its-glory-book-5-ai-assisted-development-for-delphi/';
  Book5Hint = 'Enjoying Autopilot? The full AI-with-Delphi workflow is Book 5 of "Delphi in All Its Glory": ' + Book5URL;


function UsageIniPath: String;
var
  Folder: String;
begin
  Folder := TPath.Combine(TPath.GetHomePath, 'Autopilot');   // %APPDATA%\Autopilot
  if not TDirectory.Exists(Folder)
  then TDirectory.CreateDirectory(Folder);
  Result := TPath.Combine(Folder, 'usage.ini');
end;


procedure TrackUsageAndMaybePromoteBook;
var
  Ini  : TMemIniFile;
  Count: Integer;
begin
  try
    Ini := TMemIniFile.Create(UsageIniPath);
    try
      Count := Ini.ReadInteger('Usage', 'Count', 0) + 1;
      Ini.WriteInteger('Usage', 'Count', Count);

      if (Count > BookPromoAfterUses) and (not Ini.ReadBool('Usage', 'BookPromoShown', FALSE))
      then begin
        BridgeLogInfo('book', Book5Hint);
        Ini.WriteBool('Usage', 'BookPromoShown', TRUE);
      end;

      Ini.UpdateFile;
    finally
      FreeAndNil(Ini);
    end;
  except
    // Same contract as the logger (Autopilot.Bridge.Log): a cosmetic add-on must
    // never crash the host. Log and carry on instead of reraising.
    on E: Exception do
      BridgeLogWarn('book', 'usage counter skipped: ' + E.ClassName + ': ' + E.Message);
  end;
end;


end.
