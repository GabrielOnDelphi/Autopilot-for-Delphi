unit FormMain;

{=============================================================================================================
   2026.09
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - VCL demo form for the Autopilot bridge.
   - One form with four controls (btnIncrement, lblCounter, edtName, lblNameEcho) to exercise list_tree, click, and get_text end-to-end.
=============================================================================================================}

interface

uses
  Winapi.Windows, Winapi.Messages,
  System.SysUtils, System.Variants, System.Classes,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls;

type
  TfrmMain = class(TForm)
    btnIncrement: TButton;
    lblCounter  : TLabel;
    edtName     : TEdit;
    lblNameEcho : TLabel;
    lblHeader   : TLabel;
    btnDialog   : TButton;
    procedure btnIncrementClick(Sender: TObject);
    procedure edtNameChange(Sender: TObject);
    procedure btnDialogClick(Sender: TObject);
  private
    FCounter: Integer;
  end;

var
  frmMain: TfrmMain;


implementation

{$R *.dfm}


procedure TfrmMain.btnIncrementClick(Sender: TObject);
begin
  Inc(FCounter);
  lblCounter.Caption := IntToStr(FCounter);
end;


procedure TfrmMain.edtNameChange(Sender: TObject);
begin
  lblNameEcho.Caption := edtName.Text;
end;


// Raises a native Win32 modal dialog: the main thread now spins in MessageBox's own modal
// loop, so this OnClick never returns until the dialog closes. The component tools cannot
// see this dialog (it has no TComponent) — dismiss_dialog reaches it through Win32.
procedure TfrmMain.btnDialogClick(Sender: TObject);
begin
  Application.MessageBox('A native modal dialog is up. The main thread is blocked in its modal loop.',
                        'Native Dialog', MB_YESNOCANCEL or MB_ICONWARNING);
end;


end.
