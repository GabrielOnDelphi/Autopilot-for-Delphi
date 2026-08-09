UNIT FormFmxMain;

(*=====================================================
   2026.05.14
   GabrielMoraru.com / SciVance Tech

   Demo form for the Autopilot bridge (FMX flavor).
   Mirrors the VCL demo's form layout: btnIncrement, lblCounter, edtName,
   lblNameEcho. Adds cbxFlag (FMX TCheckBox uses IsChecked) so set_checked
   has something to flip.
=====================================================*)

INTERFACE

USES
  System.SysUtils, System.Classes,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.StdCtrls, FMX.Edit, FMX.Controls.Presentation;

TYPE
  TfrmFmxMain = CLASS(TForm)
    btnIncrement: TButton;
    lblCounter  : TLabel;
    edtName     : TEdit;
    lblNameEcho : TLabel;
    lblHeader   : TLabel;
    cbxFlag     : TCheckBox;
    lblFlag     : TLabel;
    PROCEDURE btnIncrementClick(Sender: TObject);
    PROCEDURE edtNameChangeTracking(Sender: TObject);
    PROCEDURE cbxFlagChange(Sender: TObject);
  PRIVATE
    FCounter: Integer;
  END;

VAR
  frmFmxMain: TfrmFmxMain;


IMPLEMENTATION

{$R *.fmx}


PROCEDURE TfrmFmxMain.btnIncrementClick(Sender: TObject);
BEGIN
  Inc(FCounter);
  lblCounter.Text := IntToStr(FCounter);
END;


PROCEDURE TfrmFmxMain.edtNameChangeTracking(Sender: TObject);
BEGIN
  lblNameEcho.Text := edtName.Text;
END;


PROCEDURE TfrmFmxMain.cbxFlagChange(Sender: TObject);
BEGIN
  if cbxFlag.IsChecked then
    lblFlag.Text := 'on'
  else
    lblFlag.Text := 'off';
END;


END.
