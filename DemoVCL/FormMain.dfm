object frmMain: TfrmMain
  Left = 0
  Top = 0
  Caption = 'Autopilot Demo'
  ClientHeight = 240
  ClientWidth = 420
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Position = poScreenCenter
  TextHeight = 15
  object lblHeader: TLabel
    Left = 16
    Top = 12
    Width = 388
    Height = 15
    Caption = 'Autopilot demo - target app for end-to-end testing.'
  end
  object lblCounter: TLabel
    Left = 264
    Top = 56
    Width = 8
    Height = 15
    Caption = '0'
  end
  object lblNameEcho: TLabel
    Left = 264
    Top = 120
    Width = 6
    Height = 15
    Caption = ' '
  end
  object btnIncrement: TButton
    Left = 16
    Top = 48
    Width = 161
    Height = 33
    Caption = 'Increment'
    TabOrder = 0
    OnClick = btnIncrementClick
  end
  object edtName: TEdit
    Left = 16
    Top = 116
    Width = 233
    Height = 23
    TabOrder = 1
    Text = ''
    OnChange = edtNameChange
  end
  object btnDialog: TButton
    Left = 16
    Top = 160
    Width = 161
    Height = 33
    Caption = 'Show Native Dialog'
    TabOrder = 2
    OnClick = btnDialogClick
  end
end
