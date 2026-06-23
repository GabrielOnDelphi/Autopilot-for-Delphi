UNIT Autopilot.Mcp.UsageCounter;

(*=====================================================
   2026.06.23
   GabrielMoraru.com / SciVance Tech

   One-time Book 5 cross-promotion for engaged users.

   Counts MCP-server launches across sessions in %APPDATA%\Autopilot\usage.ini.
   Once the user has run Autopilot MORE THAN five times, a single clickable link
   to Book 5 of "Delphi in All Its Glory" is written to Autopilot's own log, then
   a flag is set so it never appears again.

   Deliberately NOT a dialog and NOT a browser launch: the MCP server is headless
   (stdout is the JSON-RPC channel) and the operator is often away during an
   unattended AI run. A clickable URL in the log gives one-click ergonomics in any
   terminal / IDE console without stealing focus or breaking the automation.
   Design rationale + the rejected auto-open-browser variant: HANDOVER 2026-06-23.

   Stdlib only (System.IniFiles), so the MCP server stays dependency-clean.
=====================================================*)

INTERFACE

/// Increment the cross-session launch count and, the first time it passes the
/// threshold, log the Book 5 link once. Call once per MCP-server startup.
/// Never raises: a promo counter must not take down the server.
PROCEDURE TrackUsageAndMaybePromoteBook;


IMPLEMENTATION

USES
  System.SysUtils, System.IOUtils, System.IniFiles,
  Autopilot.Bridge.Log;

CONST
  BookPromoAfterUses = 5;   // show on the 6th launch (count > 5)

  Book5URL  = 'https://store.payproglobal.com/checkout?products[1][id]=134850';
  Book5Hint = 'Enjoying Autopilot? The full AI-with-Delphi workflow is Book 5 of "Delphi in All Its Glory": ' + Book5URL;


FUNCTION UsageIniPath: String;
VAR
  Folder: String;
BEGIN
  Folder := TPath.Combine(TPath.GetHomePath, 'Autopilot');   // %APPDATA%\Autopilot
  if not TDirectory.Exists(Folder) then
    TDirectory.CreateDirectory(Folder);
  Result := TPath.Combine(Folder, 'usage.ini');
END;


PROCEDURE TrackUsageAndMaybePromoteBook;
VAR
  Ini  : TMemIniFile;
  Count: Integer;
BEGIN
  TRY
    Ini := TMemIniFile.Create(UsageIniPath);
    TRY
      Count := Ini.ReadInteger('Usage', 'Count', 0) + 1;
      Ini.WriteInteger('Usage', 'Count', Count);

      if (Count > BookPromoAfterUses) and (not Ini.ReadBool('Usage', 'BookPromoShown', FALSE)) then
      begin
        BridgeLogInfo('book', Book5Hint);
        Ini.WriteBool('Usage', 'BookPromoShown', TRUE);
      end;

      Ini.UpdateFile;
    FINALLY
      FreeAndNil(Ini);
    END;
  EXCEPT
    // Same contract as the logger (Autopilot.Bridge.Log): a cosmetic add-on must
    // never crash the host. Log and carry on instead of reraising.
    ON E: Exception DO
      BridgeLogWarn('book', 'usage counter skipped: ' + E.ClassName + ': ' + E.Message);
  END;
END;


END.
