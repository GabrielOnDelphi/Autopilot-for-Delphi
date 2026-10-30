unit DemoTests.Main;

{=============================================================================================================
   2026.10.13
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - Repeatable GUI tests of the VCL demo app (DemoVCL\Autopilot.Demo.exe), with no AI: each test drives the
     running app through TAutopilotApp (Autopilot.Client) and checks what the app shows
   - One app for the whole fixture: [SetupFixture] starts it, [TearDownFixture] closes it
   - Three labels of the demo count up (lblCounter, lblActionResult, lblDelayed). A test reads such a label first
     and expects the next value, so the tests pass in any order, and also one at a time (--run)
   - Where the tests look for the app: DemoExePath
=============================================================================================================}

interface

uses
  DUnitX.TestFramework,
  Autopilot.Client;

type
  [TestFixture]
  TDemoTests = class
  private
    App: TAutopilotApp;
  public
    [SetupFixture]
    procedure StartApp;
    [TearDownFixture]
    procedure CloseApp;

    [Test] procedure NameIsEchoed;
    [Test] procedure IncrementCountsUp;
    [Test] procedure CheckBoxShowsItsState;
    [Test] procedure SpeedButtonRunsItsAction;
    [Test] procedure DelayedTextArrives;
    [Test] procedure ModalDialogIsDismissed;
    [Test] procedure WrongPathRaisesNotFound;
    [Test] procedure ScreenshotIsPng;
  end;


implementation

uses
  System.SysUtils, System.IOUtils, System.Math,
  Autopilot.Bridge.Core;   // the error codes: ErrNotFound


{ The demo app: the EXE that the environment variable AUTOPILOT_DEMO_EXE names, or else Autopilot.Demo.exe in the
  folder above this test EXE (DemoVCL\, where Autopilot.Demo.dproj writes it).
  An environment variable, not a command-line switch: DUnitX stops with an error at a switch it does not know. }
function DemoExePath: String;
begin
  Result := GetEnvironmentVariable('AUTOPILOT_DEMO_EXE');
  if Result = '' then
    Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\Autopilot.Demo.exe');
end;


{ The run count that a counting label of the demo shows: 0 for '-' (never ran), 3 for '3', for
  'Action ran 3 times, sender TAction' and for 'Delayed done 3' }
function RunCountIn(const LabelText: String): Integer;
var
  Digits: String;
  C: Char;
begin
  Digits := '';
  for C in LabelText do
    if CharInSet(C, ['0'..'9']) then
      Digits := Digits + C;
  if Digits = ''
  then Result := 0
  else Result := StrToInt(Digits);
end;


// The first Count bytes of a file as hex digits, e.g. '89504E47'
function FileStartHex(const FileName: String; Count: Integer): String;
var
  Bytes: TBytes;
  i: Integer;
begin
  Bytes := TFile.ReadAllBytes(FileName);
  Result := '';
  for i := 0 to Min(Count, Length(Bytes)) - 1 do
    Result := Result + IntToHex(Bytes[i], 2);
end;


{ TDemoTests }

procedure TDemoTests.StartApp;
begin
  { Start is the last statement here: DUnitX runs no [TearDownFixture] after a [SetupFixture] that raised.
    The app starts minimized, but it may stay the foreground window during the run, so keys a person types
    meanwhile can reach it. It ends together with this test EXE, even when the run is killed. }
  App := TAutopilotApp.Start(DemoExePath);
end;


procedure TDemoTests.CloseApp;
begin
  try
    App.Close;   // WM_CLOSE, as when a user closes the app; raises, and so fails the fixture, when the app does not end
  finally
    FreeAndNil(App);
  end;
end;


procedure TDemoTests.NameIsEchoed;
begin
  App.SetText('frmMain.edtName', 'Gabriel');
  Assert.AreEqual('Gabriel', App.GetText('frmMain.lblNameEcho'));   // edtName.OnChange copies the text into lblNameEcho
end;


procedure TDemoTests.IncrementCountsUp;
var
  Before: Integer;
begin
  Before := StrToInt(App.GetText('frmMain.lblCounter'));
  App.Click('frmMain.btnIncrement');
  Assert.AreEqual(IntToStr(Before + 1), App.GetText('frmMain.lblCounter'));
end;


procedure TDemoTests.CheckBoxShowsItsState;
begin
  App.SetChecked('frmMain.chkFixture', TRUE);
  Assert.AreEqual('checked', App.GetText('frmMain.lblCheckState'));
  App.SetChecked('frmMain.chkFixture', FALSE);
  Assert.AreEqual('unchecked', App.GetText('frmMain.lblCheckState'));
end;


{ sbAction is a TSpeedButton: a graphic control, with no window handle of its own. Its Action is actFixture, so the
  bridge clicks it through TControl.Click and the action runs as for a mouse click (Sender is the action). }
procedure TDemoTests.SpeedButtonRunsItsAction;
var
  Runs: Integer;
begin
  Runs := RunCountIn(App.GetText('frmMain.lblActionResult'));
  App.Click('frmMain.sbAction');
  Assert.AreEqual('Action ran ' + IntToStr(Runs + 1) + ' times, sender TAction', App.GetText('frmMain.lblActionResult'));
end;


procedure TDemoTests.DelayedTextArrives;
var
  Expected: String;
begin
  Expected := 'Delayed done ' + IntToStr(RunCountIn(App.GetText('frmMain.lblDelayed')) + 1);
  App.Click('frmMain.btnDelayed');                     // starts a timer that writes lblDelayed one second later
  App.WaitForText('frmMain.lblDelayed', Expected);     // FALSE after 5 s; the assert below then shows what the label reads
  Assert.AreEqual(Expected, App.GetText('frmMain.lblDelayed'));
end;


{ btnDialog shows a native MessageBox (Yes / No / Cancel), and its OnClick waits in the box's modal loop until the
  box closes. So the test clicks with ClickAsync, which returns before the click runs, then presses Cancel. }
procedure TDemoTests.ModalDialogIsDismissed;
begin
  App.ClickAsync('frmMain.btnDialog');
  Assert.IsTrue(App.DismissDialog('cancel'), 'the dialog of btnDialog did not close');
end;


procedure TDemoTests.WrongPathRaisesNotFound;
var
  Code: Integer;
begin
  Code := 0;
  try
    App.GetText('frmMain.lblNoSuchLabel');
  except
    on E: EAutopilotError do
      Code := E.Code;   // kept for the assert below; any other exception fails the test
  end;
  Assert.AreEqual(ErrNotFound, Code);   // -32001: no control has this path
end;


procedure TDemoTests.ScreenshotIsPng;
var
  FileName: String;
begin
  FileName := TPath.Combine(TPath.GetTempPath, 'Autopilot.DemoTests - frmMain.png');
  DeleteFile(FileName);   // a file left by an earlier run must not pass this test
  App.Screenshot('frmMain', FileName);
  Assert.AreEqual('89504E470D0A1A0A', FileStartHex(FileName, 8));   // the PNG signature
end;


initialization
  TDUnitX.RegisterTestFixture(TDemoTests);

end.
