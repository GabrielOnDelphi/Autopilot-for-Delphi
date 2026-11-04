unit Tests.ErrorCodes;

{=============================================================================================================
   2026.11.02
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - Pins the 11 JSON-RPC error-code constants of Autopilot.Bridge.Core to the numbers the documentation gives the AI clients.
   - An AI client reads the codes only through AI-INSTRUCTIONS.md and "AI-INSTRUCTIONS - tool reference.md": a constant that changes in the source but not in those files makes every AI client misread the error, with no message.
   - Expected numbers: typed by a helper agent from the documents only (never from the .pas), file "Expected - Error codes.txt" beside this unit.
     Outside source: AI-INSTRUCTIONS.md, table "Error envelope", and "AI-INSTRUCTIONS - tool reference.md", sections click (-32600) and execute_action (-32603);
     -32097 is not in AI-INSTRUCTIONS.md, so its source is "Source\Client\Autopilot.Client - how to write GUI tests without AI.md" line 39.
   - After this pin, other tests may use the constants (conclusions file, Rule 2).
=============================================================================================================}

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TErrorCodeTests = class
  public
    [Test] procedure Test_ErrorCodes_MatchTheDocumentedNumbers;
    [Test] procedure Test_ErrorCodes_AreAllDifferent;  end;


implementation

uses
  System.SysUtils,
  Autopilot.Bridge.Core;

type
  TCodeEntry = record
    Name    : String;    // the constant in Autopilot.Bridge.Core
    DocName : String;    // the name the document gives it
    Actual  : Integer;   // the constant's value
    Expected: Integer;   // the literal number from the document
  end;


{ Expected: literals typed from the documents (see the unit header); never write a constant of Autopilot.Bridge.Core into the Expected column. }
function CodeTable: TArray<TCodeEntry>;

  function E(const AName, ADocName: String; AActual, AExpected: Integer): TCodeEntry;
  begin
    Result.Name     := AName;
    Result.DocName  := ADocName;
    Result.Actual   := AActual;
    Result.Expected := AExpected;
  end;

begin
  Result := [
    E('ErrNotFound',            'not_found',             ErrNotFound,            -32001),   // AI-INSTRUCTIONS.md, Error envelope
    E('ErrAmbiguousPath',       'ambiguous_path',        ErrAmbiguousPath,       -32002),   // AI-INSTRUCTIONS.md, Error envelope
    E('ErrControlDisabled',     'control_disabled',      ErrControlDisabled,     -32003),   // AI-INSTRUCTIONS.md, Error envelope
    E('ErrMainThreadBlocked',   'main_thread_blocked',   ErrMainThreadBlocked,   -32004),   // AI-INSTRUCTIONS.md, Error envelope
    E('ErrUnsupportedAction',   'unsupported_action',    ErrUnsupportedAction,   -32005),   // AI-INSTRUCTIONS.md, Error envelope
    E('ErrRttiPropertyMissing', 'rtti_property_missing', ErrRttiPropertyMissing, -32006),   // AI-INSTRUCTIONS.md, Error envelope
    E('ErrProtocolMismatch',    'protocol version',      ErrProtocolMismatch,    -32097),   // Autopilot.Client - how to write GUI tests without AI.md:39
    E('ErrTargetNotResponding', 'target_not_responding', ErrTargetNotResponding, -32098),   // AI-INSTRUCTIONS.md, Error envelope
    E('ErrTargetNotRunning',    'target_not_running',    ErrTargetNotRunning,    -32099),   // AI-INSTRUCTIONS.md, Error envelope
    E('ErrInvalidRequest',      'invalid_request',       ErrInvalidRequest,      -32600),   // AI-INSTRUCTIONS - tool reference.md, click
    E('ErrInternalError',       'internal_error',        ErrInternalError,       -32603)];  // AI-INSTRUCTIONS - tool reference.md, execute_action
end;


procedure TErrorCodeTests.Test_ErrorCodes_MatchTheDocumentedNumbers;
var
  Entry: TCodeEntry;
  Wrong: String;
begin
  Assert.AreEqual(11, Length(CodeTable), 'the table must hold the 11 constants of Autopilot.Bridge.Core');
  Wrong := '';
  for Entry in CodeTable do
    if Entry.Actual <> Entry.Expected then
      Wrong := Wrong + Format('%s (%s) = %d, documented %d; ', [Entry.Name, Entry.DocName, Entry.Actual, Entry.Expected]);
  Assert.AreEqual('', Wrong, 'error codes that differ from the documentation');
end;


procedure TErrorCodeTests.Test_ErrorCodes_AreAllDifferent;
var
  Table: TArray<TCodeEntry>;
  i, j: Integer;
  Same: String;
begin
  Table := CodeTable;
  Same := '';
  for i := 0 to High(Table) - 1 do
    for j := i + 1 to High(Table) do
      if Table[i].Actual = Table[j].Actual then
        Same := Same + Table[i].Name + ' = ' + Table[j].Name + '; ';
  Assert.AreEqual('', Same, 'two error codes share one number');
end;


initialization
  TDUnitX.RegisterTestFixture(TErrorCodeTests);

end.
