unit FormFmxMain;

{=============================================================================================================
   2026.09
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - FMX demo form for the Autopilot bridge.
   - Mirrors the VCL demo layout; adds cbxFlag (TCheckBox.IsChecked) so the set_checked tool has a target to flip.
=============================================================================================================}

interface

uses
  System.SysUtils, System.Classes,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.StdCtrls, FMX.Edit, FMX.Controls.Presentation;

type
  TfrmFmxMain = class(TForm)
    btnIncrement: TButton;
    lblCounter  : TLabel;
    edtName     : TEdit;
    lblNameEcho : TLabel;
    lblHeader   : TLabel;
    cbxFlag     : TCheckBox;
    lblFlag     : TLabel;
    procedure btnIncrementClick(Sender: TObject);
    procedure edtNameChangeTracking(Sender: TObject);
    procedure cbxFlagChange(Sender: TObject);
  private
    FCounter: Integer;
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


end.
