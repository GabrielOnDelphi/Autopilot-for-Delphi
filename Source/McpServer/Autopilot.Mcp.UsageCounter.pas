unit Autopilot.Mcp.UsageCounter;

{=============================================================================================================
   2026.06
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - Cross-session nudges, both one-shot, both flagged in %APPDATA%\Autopilot\usage.ini:
       1. the licence notice, on the very first tool call ever (ClaimLicenseNotice)
       2. a Book 5 cross-promotion once the user has run Autopilot more than five times
   - Deliberately NOT a dialog and NOT a browser launch: the MCP server is headless (stdout is the
     JSON-RPC channel) and the operator is often away during an unattended AI run.
   - Stdlib only (System.IniFiles), so the MCP server stays dependency-clean.
=============================================================================================================}

interface

/// Increment the cross-session launch count and, the first time it passes the
/// threshold, log the Book 5 link once. Call once per MCP-server startup.
/// Never raises: a promo counter must not take down the server.
procedure TrackUsageAndMaybePromoteBook;

/// TRUE exactly once per installation — the first call that finds the flag unset
/// sets it and returns TRUE; every later call returns FALSE. The caller then attaches
/// Autopilot.Bridge.Core.LicenseNoticeText to a tool response, which is the only place
/// the driving AI reliably reads (the startup log line is written where nobody looks).
/// Never raises: on any INI failure it returns FALSE, so a broken counter costs a
/// reminder rather than a tool call.
function ClaimLicenseNotice: Boolean;


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


function ClaimLicenseNotice: Boolean;
var
  Ini: TMemIniFile;
begin
  Result := FALSE;
  try
    Ini := TMemIniFile.Create(UsageIniPath);
    try
      if Ini.ReadBool('Usage', 'LicenseNoticeShown', FALSE) then EXIT(FALSE);

      Ini.WriteBool('Usage', 'LicenseNoticeShown', TRUE);
      Ini.UpdateFile;                       // persist BEFORE claiming, so a crash cannot repeat the notice
      Result := TRUE;
    finally
      FreeAndNil(Ini);
    end;
  except
    // Same contract as TrackUsageAndMaybePromoteBook: a cosmetic nudge must never
    // break a tool call. Staying FALSE simply drops the reminder.
    on E: Exception do
      BridgeLogWarn('license', 'notice skipped: ' + E.ClassName + ': ' + E.Message);
  end;
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
