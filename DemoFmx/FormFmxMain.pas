unit FormFmxMain;

{=============================================================================================================
   2026.10.06
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - FMX demo form for the Autopilot bridge.
   - Mirrors the VCL demo layout; adds cbxFlag (TCheckBox.IsChecked) so the set_checked tool has a target to flip.
   - Test fixtures for "_Local info\E2E tests\Test-AllTools.ps1": a button that opens a native message box
     (btnDialog -> lblDialogResult), an action bound to a TButton and a TSpeedButton (actFixture -> lblActionResult),
     a label placed on a panel (pnlFixture.lblInPanel) for the path rule, a TRectangle for a TAlphaColor property,
     and a button whose label changes one second later (btnDelayed -> tmrDelayed -> lblDelayed) for wait_for.
=============================================================================================================}

interface

uses
  System.SysUtils, System.Classes, System.UITypes, System.Actions,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.StdCtrls, FMX.Edit, FMX.Controls.Presentation, FMX.Objects, FMX.ActnList,
  FMX.DialogService;

type
  TfrmFmxMain = class(TForm)
    btnIncrement: TButton;
    lblCounter  : TLabel;
    edtName     : TEdit;
    lblNameEcho : TLabel;
    lblHeader   : TLabel;
    cbxFlag     : TCheckBox;
    lblFlag     : TLabel;
    btnDialog      : TButton;
    lblDialogResult: TLabel;
    pnlFixture     : TPanel;
    lblInPanel     : TLabel;
    btnAction      : TButton;
    sbAction       : TSpeedButton;
    lblActionResult: TLabel;
    rectFixture    : TRectangle;
    btnDelayed     : TButton;
    lblDelayed     : TLabel;
    tmrDelayed     : TTimer;
    actlFixture    : TActionList;
    actFixture     : TAction;
    procedure btnIncrementClick(Sender: TObject);
    procedure edtNameChangeTracking(Sender: TObject);
    procedure cbxFlagChange(Sender: TObject);
    procedure btnDialogClick(Sender: TObject);
    procedure actFixtureExecute(Sender: TObject);
    procedure btnDelayedClick(Sender: TObject);
    procedure tmrDelayedTimer(Sender: TObject);
  private
    FCounter: Integer;
    FActionRuns: Integer;
    FDelayedRuns: Integer;
  end;

var
  frmFmxMain: TfrmFmxMain;


implementation

{$R *.fmx}


procedure TfrmFmxMain.btnIncrementClick(Sender: TObject);
begin
  Inc(FCounter);
  lblCounter.Text := IntToStr(FCounter);
end;


procedure TfrmFmxMain.edtNameChangeTracking(Sender: TObject);
begin
  lblNameEcho.Text := edtName.Text;
end;


procedure TfrmFmxMain.cbxFlagChange(Sender: TObject);
begin
  if cbxFlag.IsChecked
  then lblFlag.Text := 'on'
  else lblFlag.Text := 'off';
end;


// On Windows this is a native message box (FMX.Dialogs.Win calls MessageBoxIndirect): the main thread waits in
// its modal loop until the dialog closes. The component tools cannot see it; dismiss_dialog reaches it through Win32.
procedure TfrmFmxMain.btnDialogClick(Sender: TObject);
begin
  TDialogService.MessageDialog('A native modal dialog is up. The main thread is blocked in its modal loop.',
                               TMsgDlgType.mtWarning, [TMsgDlgBtn.mbYes, TMsgDlgBtn.mbNo, TMsgDlgBtn.mbCancel], TMsgDlgBtn.mbYes, 0,
                               procedure(const AResult: TModalResult)
                               begin
                                 lblDialogResult.Text := 'Dialog closed with ' + IntToStr(AResult);
                               end);
end;


// Sender is the action itself when the run went through TCustomAction.Execute, and the control when its OnClick was called directly.
procedure TfrmFmxMain.actFixtureExecute(Sender: TObject);
begin
  Inc(FActionRuns);
  lblActionResult.Text := 'Action ran ' + IntToStr(FActionRuns) + ' times, sender ' + Sender.ClassName;
end;


procedure TfrmFmxMain.btnDelayedClick(Sender: TObject);
begin
  lblDelayed.Text := 'waiting';
  tmrDelayed.Enabled := TRUE;   // Interval is the default 1000 ms
end;


procedure TfrmFmxMain.tmrDelayedTimer(Sender: TObject);
begin
  tmrDelayed.Enabled := FALSE;
  Inc(FDelayedRuns);
  lblDelayed.Text := 'Delayed done ' + IntToStr(FDelayedRuns);
end;


end.
