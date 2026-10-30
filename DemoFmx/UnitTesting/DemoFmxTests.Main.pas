unit DemoFmxTests.Main;

{=============================================================================================================
   2026.10.13
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - Repeatable GUI tests of the FMX demo app on Windows (DemoFmx\Autopilot.DemoFmx.exe), with no AI: each test
     drives the running app through TAutopilotApp (Autopilot.Client) and checks what the app shows
   - The same eight tests as the VCL demo tests (DemoVCL\UnitTesting\), with the FMX names and texts. One test
     works differently: the modal dialog (ModalDialogIsDismissed)
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
  TDemoFmxTests = class
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
  Autopilot.Bridge.Core;   // the error codes: ErrNotFound, ErrMainThreadBlocked


{ The demo app: the EXE that the environment variable AUTOPILOT_DEMOFMX_EXE names, or else Autopilot.DemoFmx.exe in
  the folder above this test EXE (DemoFmx\, where Autopilot.DemoFmx.dproj writes its Win32 EXE).
  An environment variable, not a command-line switch: DUnitX stops with an error at a switch it does not know. }
function DemoExePath: String;
begin
  Result := GetEnvironmentVariable('AUTOPILOT_DEMOFMX_EXE');
  if Result = '' then
    Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\Autopilot.DemoFmx.exe');
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


{ TDemoFmxTests }

procedure TDemoFmxTests.StartApp;
begin
  { Start is the last statement here: DUnitX runs no [TearDownFixture] after a [SetupFixture] that raised.
    The app starts minimized. It ends together with this test EXE, even when the run is killed. }
  App := TAutopilotApp.Start(DemoExePath);
end;


procedure TDemoFmxTests.CloseApp;
begin
  try
    App.Close;   // WM_CLOSE, as when a user closes the app; raises, and so fails the fixture, when the app does not end
  finally
    FreeAndNil(App);
  end;
end;


procedure TDemoFmxTests.NameIsEchoed;
begin
  App.SetText('frmFmxMain.edtName', 'Gabriel');
  Assert.AreEqual('Gabriel', App.GetText('frmFmxMain.lblNameEcho'));   // edtName.OnChangeTracking copies the text into lblNameEcho
end;


procedure TDemoFmxTests.IncrementCountsUp;
var
  Before: Integer;
begin
  Before := StrToInt(App.GetText('frmFmxMain.lblCounter'));
  App.Click('frmFmxMain.btnIncrement');
  Assert.AreEqual(IntToStr(Before + 1), App.GetText('frmFmxMain.lblCounter'));
end;


procedure TDemoFmxTests.CheckBoxShowsItsState;
begin
  App.SetChecked('frmFmxMain.cbxFlag', TRUE);
  Assert.AreEqual('on', App.GetText('frmFmxMain.lblFlag'));    // cbxFlag.OnChange writes 'on' / 'off'
  App.SetChecked('frmFmxMain.cbxFlag', FALSE);
  Assert.AreEqual('off', App.GetText('frmFmxMain.lblFlag'));
end;


{ sbAction is a TSpeedButton whose Action is actFixture. The bridge clicks an action-bound FMX control through
  TControl.Click, so the action runs as for a mouse click (Sender is the action). }
procedure TDemoFmxTests.SpeedButtonRunsItsAction;
var
  Runs: Integer;
begin
  Runs := RunCountIn(App.GetText('frmFmxMain.lblActionResult'));
  App.Click('frmFmxMain.sbAction');
  Assert.AreEqual('Action ran ' + IntToStr(Runs + 1) + ' times, sender TAction', App.GetText('frmFmxMain.lblActionResult'));
end;


procedure TDemoFmxTests.DelayedTextArrives;
var
  Expected: String;
begin
  Expected := 'Delayed done ' + IntToStr(RunCountIn(App.GetText('frmFmxMain.lblDelayed')) + 1);
  App.Click('frmFmxMain.btnDelayed');                     // starts a timer that writes lblDelayed one second later
  App.WaitForText('frmFmxMain.lblDelayed', Expected);     // FALSE after 5 s; the assert below then shows what the label reads
  Assert.AreEqual(Expected, App.GetText('frmFmxMain.lblDelayed'));
end;


{ btnDialog shows a native message box (TDialogService.MessageDialog: Yes / No / Cancel), and its OnClick waits in
  the box's modal loop until the box closes. FMX has no ClickAsync (the FMX bridge answers -32005 for it), so the
  test clicks with a short timeout: the bridge gives up waiting after 500 ms and answers -32004, while the box stays
  open. Then it presses Cancel, and the box's result handler writes lblDialogResult. }
procedure TDemoFmxTests.ModalDialogIsDismissed;
const
  ClosedWithCancel = 'Dialog closed with 2';   // mrCancel = 2
var
  Code: Integer;
begin
  Code := 0;
  try
    App.Click('frmFmxMain.btnDialog', 1, 500);
  except
    on E: EAutopilotError do
      Code := E.Code;   // kept for the assert below; any other exception fails the test
  end;
  Assert.AreEqual(ErrMainThreadBlocked, Code, 'the click on btnDialog did not wait in the modal box');   // -32004
  Assert.IsTrue(App.DismissDialog('cancel'), 'the dialog of btnDialog did not close');
  App.WaitForText('frmFmxMain.lblDialogResult', ClosedWithCancel);
  Assert.AreEqual(ClosedWithCancel, App.GetText('frmFmxMain.lblDialogResult'));
end;


procedure TDemoFmxTests.WrongPathRaisesNotFound;
var
  Code: Integer;
begin
  Code := 0;
  try
    App.GetText('frmFmxMain.lblNoSuchLabel');
  except
    on E: EAutopilotError do
      Code := E.Code;   // kept for the assert below; any other exception fails the test
  end;
  Assert.AreEqual(ErrNotFound, Code);   // -32001: no control has this path
end;


procedure TDemoFmxTests.ScreenshotIsPng;
var
  FileName: String;
begin
  FileName := TPath.Combine(TPath.GetTempPath, 'Autopilot.DemoFmxTests - frmFmxMain.png');
  DeleteFile(FileName);   // a file left by an earlier run must not pass this test
  App.Screenshot('frmFmxMain', FileName);
  Assert.AreEqual('89504E470D0A1A0A', FileStartHex(FileName, 8));   // the PNG signature
end;


initialization
  TDUnitX.RegisterTestFixture(TDemoFmxTests);

end.
