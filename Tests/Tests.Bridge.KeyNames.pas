unit Tests.Bridge.KeyNames;

{=============================================================================================================
   2026.11.02
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - Table test of the key-name table of send_keys (KeyNameToVk in Autopilot.Bridge.Core.pas, the one copy that the VCL and FMX bridges both call).
     Twice: KeyNameToVk called directly, and through the VCL bridge (send_keys with one key name, then the Key that OnKeyDown received).
   - Every key name that "AI-INSTRUCTIONS - tool reference.md" (section send_keys) documents, as written and in lower case, plus names that must be rejected.
   - No VCL-FMX agreement test: the two bridges had one copy each until 2026-11-03; now there is one copy, in Core.
   - Expected virtual-key codes: Microsoft, "Virtual-Key Codes", https://learn.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes
     Typed by a helper agent from that page only (never from the .pas or the RTL), file "Expected - Virtual-key codes.txt" beside this unit.
   - The edit answers CM_WANTSPECIALKEY, so Enter, Escape, Tab and the arrows reach its OnKeyDown instead of a Default/Cancel button or the focus navigation (TWinControl.CNKeyDown in Vcl.Controls.pas).
=============================================================================================================}

interface

uses
  Vcl.Forms,
  DUnitX.TestFramework;

type
  [TestFixture]
  TKeyNameTests = class
  private
    FPipeName   : String;
    FPipeCounter: Integer;
    FForm       : TForm;    // TKeyNamesForm 'KeyNamesForm'
  public
    [SetupFixture]    procedure SetupFixture;
    [Setup]           procedure Setup;
    [TearDown]        procedure TearDown;
    [TearDownFixture] procedure TearDownFixture;

    [Test] procedure Test_KeyNameToVk_EveryDocumentedNameGivesTheMicrosoftCode;
    [Test] procedure Test_KeyNameToVk_BadNamesGiveZero;
    [Test] procedure Test_KeyNames_EveryDocumentedNameGivesTheMicrosoftCode;
    [Test] procedure Test_KeyNames_BadNamesRejectedAndNothingSent;
  end;


implementation

uses
  Winapi.Windows, Winapi.Messages,
  System.SysUtils, System.Classes, System.JSON,
  Vcl.Controls, Vcl.StdCtrls,
  Autopilot.Bridge.Core, Autopilot.Bridge.Vcl,
  Bridge.TestClient, Bridge.Tests;


type
  TExpectedKey = record
    Name: String;
    Vk  : Word;
  end;

const
  { Typed from Microsoft, "Virtual-Key Codes" (URL in the unit header). Never write a vk* constant of the RTL here. }
  ExpectedKeys: array[0..63] of TExpectedKey = (
    (Name: 'A'; Vk: $41), (Name: 'B'; Vk: $42), (Name: 'C'; Vk: $43), (Name: 'D'; Vk: $44), (Name: 'E'; Vk: $45),
    (Name: 'F'; Vk: $46), (Name: 'G'; Vk: $47), (Name: 'H'; Vk: $48), (Name: 'I'; Vk: $49), (Name: 'J'; Vk: $4A),
    (Name: 'K'; Vk: $4B), (Name: 'L'; Vk: $4C), (Name: 'M'; Vk: $4D), (Name: 'N'; Vk: $4E), (Name: 'O'; Vk: $4F),
    (Name: 'P'; Vk: $50), (Name: 'Q'; Vk: $51), (Name: 'R'; Vk: $52), (Name: 'S'; Vk: $53), (Name: 'T'; Vk: $54),
    (Name: 'U'; Vk: $55), (Name: 'V'; Vk: $56), (Name: 'W'; Vk: $57), (Name: 'X'; Vk: $58), (Name: 'Y'; Vk: $59),
    (Name: 'Z'; Vk: $5A),
    (Name: '0'; Vk: $30), (Name: '1'; Vk: $31), (Name: '2'; Vk: $32), (Name: '3'; Vk: $33), (Name: '4'; Vk: $34),
    (Name: '5'; Vk: $35), (Name: '6'; Vk: $36), (Name: '7'; Vk: $37), (Name: '8'; Vk: $38), (Name: '9'; Vk: $39),
    (Name: 'F1';  Vk: $70), (Name: 'F2';  Vk: $71), (Name: 'F3';  Vk: $72), (Name: 'F4';  Vk: $73),
    (Name: 'F5';  Vk: $74), (Name: 'F6';  Vk: $75), (Name: 'F7';  Vk: $76), (Name: 'F8';  Vk: $77),
    (Name: 'F9';  Vk: $78), (Name: 'F10'; Vk: $79), (Name: 'F11'; Vk: $7A), (Name: 'F12'; Vk: $7B),
    (Name: 'Enter';     Vk: $0D),   // VK_RETURN
    (Name: 'Escape';    Vk: $1B),   // VK_ESCAPE
    (Name: 'Esc';       Vk: $1B),   // VK_ESCAPE
    (Name: 'Tab';       Vk: $09),   // VK_TAB
    (Name: 'Space';     Vk: $20),   // VK_SPACE
    (Name: 'Backspace'; Vk: $08),   // VK_BACK
    (Name: 'Delete';    Vk: $2E),   // VK_DELETE
    (Name: 'Insert';    Vk: $2D),   // VK_INSERT
    (Name: 'Home';      Vk: $24),   // VK_HOME
    (Name: 'End';       Vk: $23),   // VK_END
    (Name: 'PageUp';    Vk: $21),   // VK_PRIOR
    (Name: 'PageDown';  Vk: $22),   // VK_NEXT
    (Name: 'Up';        Vk: $26),   // VK_UP
    (Name: 'Down';      Vk: $28),   // VK_DOWN
    (Name: 'Left';      Vk: $25),   // VK_LEFT
    (Name: 'Right';     Vk: $27));  // VK_RIGHT


type
  { An edit that wants every special key, so CNKeyDown never turns Enter/Escape/Tab/arrows into a dialog key. }
  TKeyEdit = class(TEdit)
  private
    procedure CMWantSpecialKey(var Msg: TCMWantSpecialKey); message CM_WANTSPECIALKEY;
  end;

  { Shown but never activated and never raised: off-screen, WS_EX_NOACTIVATE, no SetZOrder (as in Tests.Bridge.SendKeys). }
  TKeyNamesForm = class(TForm)
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure SetZOrder(TopMost: Boolean); override;
  public
    EdtKey      : TKeyEdit;
    FirstKey    : Word;
    KeyDownCount: Integer;
    constructor Create(AOwner: TComponent); override;
    procedure EdtKeyKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure ResetCounters;
  end;


procedure TKeyEdit.CMWantSpecialKey(var Msg: TCMWantSpecialKey);
begin
  Msg.Result := 1;
end;


procedure TKeyNamesForm.CreateParams(var Params: TCreateParams);
begin
  inherited;
  Params.ExStyle := Params.ExStyle or WS_EX_NOACTIVATE or WS_EX_TOOLWINDOW;
end;


procedure TKeyNamesForm.SetZOrder(TopMost: Boolean);
begin
  // Never raise the window: TCustomForm.Show ends in BringToFront.
end;


constructor TKeyNamesForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Name    := 'KeyNamesForm';
  Caption := 'Key names';

  EdtKey := TKeyEdit.Create(Self);
  EdtKey.Name      := 'edtKey';
  EdtKey.Parent    := Self;
  EdtKey.Text      := '';
  EdtKey.OnKeyDown := EdtKeyKeyDown;

  Position := poDesigned;
  SetBounds(-20000, -20000, 300, 200);
  Visible := TRUE;
end;


procedure TKeyNamesForm.EdtKeyKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if KeyDownCount = 0 then
    FirstKey := Key;
  Inc(KeyDownCount);
end;


procedure TKeyNamesForm.ResetCounters;
begin
  FirstKey     := 0;
  KeyDownCount := 0;
  EdtKey.Text  := '';
end;


{ Helpers --------------------------------------------------------------- }

// One send_keys round trip on a worker thread while this thread pumps the bridge's queue. The caller frees the result.
function SendKeys(const APipeName, AKeys: String): TJSONObject;
var
  Root: TJSONObject;
  PipeName, Keys: String;
begin
  Root     := NIL;
  PipeName := APipeName;
  Keys     := AKeys;
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args  : TJSONObject;
    begin
      Args := TJSONObject.Create;
      Args.AddPair('path', 'KeyNamesForm.edtKey');
      Args.AddPair('keys', Keys);
      Client := TBridgeTestClient.Create;
      try
        if not Client.ConnectAndHandshake(PipeName, 2000) then
        begin
          FreeAndNil(Args);
          Assert.Fail('connect to ' + PipeName + ' failed');
        end;
        Root := Client.Call(1, 'send_keys', Args);
      finally
        FreeAndNil(Client);
      end;
    end, 5000);
  Result := Root;
end;


function ErrorMessageOf(ARoot: TJSONObject): String;
var
  V: TJSONValue;
begin
  Result := '';
  if ARoot = NIL then exit('(no response)');
  V := ARoot.GetValue('error');
  if V is TJSONObject then
  begin
    V := TJSONObject(V).GetValue('message');
    if V is TJSONString then
      Result := TJSONString(V).Value;
  end;
end;


{ TKeyNameTests --------------------------------------------------------- }

procedure TKeyNameTests.SetupFixture;
begin
  FPipeCounter := 0;
  FForm := TKeyNamesForm.Create(NIL);
end;


procedure TKeyNameTests.Setup;
begin
  Inc(FPipeCounter);
  FPipeName := '\\.\pipe\AutopilotTestKN.' + IntToStr(GetCurrentProcessId) + '.' + IntToStr(FPipeCounter);
  TKeyNamesForm(FForm).ResetCounters;
  StartBridgeOnPipe(FPipeName);
end;


procedure TKeyNameTests.TearDown;
begin
  StopBridge;
end;


procedure TKeyNameTests.TearDownFixture;
begin
  FreeAndNil(FForm);
end;


{ KeyNameToVk of Autopilot.Bridge.Core, called directly: every documented name, as written and in lower case. }
procedure TKeyNameTests.Test_KeyNameToVk_EveryDocumentedNameGivesTheMicrosoftCode;
var
  Entry: TExpectedKey;
  KeyName: String;
  Pass: Integer;
  Got: Word;
  Wrong: String;
  Checked: Integer;
begin
  Wrong   := '';
  Checked := 0;
  for Entry in ExpectedKeys do
    for Pass := 0 to 1 do
    begin
      if Pass = 0
      then KeyName := Entry.Name
      else KeyName := LowerCase(Entry.Name);
      Got := KeyNameToVk(KeyName);
      if Got <> Entry.Vk then
        Wrong := Wrong + Format('"%s" = $%.2x, Microsoft $%.2x; ', [KeyName, Got, Entry.Vk]);
      Inc(Checked);
    end;
  Assert.AreEqual(128, Checked, 'every documented key name, twice');
  Assert.AreEqual('', Wrong, 'key names whose virtual-key code differs from Microsoft''s table');
end;


{ KeyNameToVk answers 0 (unknown) for an unknown name, an empty name, the edges of the F-key range, two letters and a modifier name. }
procedure TKeyNameTests.Test_KeyNameToVk_BadNamesGiveZero;
const
  BadNames: array[0..5] of String = ('Bogus', '', 'F0', 'F13', 'AB', 'Ctrl');
var
  Bad: String;
  Wrong: String;
begin
  Wrong := '';
  for Bad in BadNames do
    if KeyNameToVk(Bad) <> 0 then
      Wrong := Wrong + Format('"%s" = $%.2x; ', [Bad, KeyNameToVk(Bad)]);
  Assert.AreEqual('', Wrong, 'bad key names must give 0');
end;


procedure TKeyNameTests.Test_KeyNames_EveryDocumentedNameGivesTheMicrosoftCode;
var
  F: TKeyNamesForm;
  Entry: TExpectedKey;
  KeyName: String;
  Pass: Integer;
  Root: TJSONObject;
  Wrong: String;
  Checked: Integer;
begin
  F := TKeyNamesForm(FForm);
  Wrong   := '';
  Checked := 0;
  for Entry in ExpectedKeys do
    for Pass := 0 to 1 do   // as documented, then in lower case (the names are case-insensitive)
    begin
      if Pass = 0
      then KeyName := Entry.Name
      else KeyName := LowerCase(Entry.Name);
      F.ResetCounters;
      Root := SendKeys(FPipeName, KeyName);
      try
        if GetOkResult(Root) = NIL
        then Wrong := Wrong + Format('"%s" rejected (%s); ', [KeyName, ErrorMessageOf(Root)])
        else
          if F.KeyDownCount <> 1
          then Wrong := Wrong + Format('"%s" gave %d OnKeyDown; ', [KeyName, F.KeyDownCount])
          else
            if F.FirstKey <> Entry.Vk
            then Wrong := Wrong + Format('"%s" = $%.2x, Microsoft $%.2x; ', [KeyName, F.FirstKey, Entry.Vk]);
      finally
        FreeAndNil(Root);
      end;
      Inc(Checked);
    end;
  Assert.AreEqual(128, Checked, 'every documented key name, twice');
  Assert.AreEqual('', Wrong, 'key names whose virtual-key code differs from Microsoft''s table');
end;


{ An unknown name, an empty key name ("Ctrl+" has nothing after the '+'), and the edges of the F-key range. Each answers -32600 naming the bad token, and no key is sent. }
procedure TKeyNameTests.Test_KeyNames_BadNamesRejectedAndNothingSent;
const
  BadNames: array[0..4] of String = ('Bogus', 'Ctrl+', 'F0', 'F13', 'AB');
var
  F: TKeyNamesForm;
  Bad: String;
  Root: TJSONObject;
  Wrong: String;
begin
  F := TKeyNamesForm(FForm);
  Wrong := '';
  for Bad in BadNames do
  begin
    F.ResetCounters;
    Root := SendKeys(FPipeName, Bad);
    try
      if GetErrorCode(Root) <> -32600   // invalid_request, AI-INSTRUCTIONS - tool reference.md, send_keys
      then Wrong := Wrong + Format('"%s" answered code %d (%s); ', [Bad, GetErrorCode(Root), ErrorMessageOf(Root)]);
    finally
      FreeAndNil(Root);
    end;
    if F.KeyDownCount <> 0 then
      Wrong := Wrong + Format('"%s" sent %d keys; ', [Bad, F.KeyDownCount]);
  end;
  Assert.AreEqual('', Wrong, 'bad key names');
end;


initialization
  TDUnitX.RegisterTestFixture(TKeyNameTests);

end.
