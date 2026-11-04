object frmMain: TfrmMain
  Left = 0
  Top = 0
  Caption = 'Mini Calc'
  ClientHeight = 210
  ClientWidth = 380
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
    Width = 230
    Height = 15
    Caption = 'Mini Calc - Autopilot demo target.'
  end
  object lblA: TLabel
    Left = 16
    Top = 52
    Width = 11
    Height = 15
    Caption = 'A:'
  end
  object lblB: TLabel
    Left = 120
    Top = 52
    Width = 11
    Height = 15
    Caption = 'B:'
  end
  object lblResultCap: TLabel
    Left = 16
    Top = 150
    Width = 42
    Height = 15
    Caption = 'Result:'
  end
  object lblResult: TLabel
    Left = 70
    Top = 142
    Width = 14
    Height = 28
    Caption = '-'
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -21
    Font.Name = 'Segoe UI'
    Font.Style = [fsBold]
    ParentFont = False
  end
  object edtA: TEdit
    Left = 40
    Top = 48
    Width = 57
    Height = 23
    TabOrder = 0
    Text = '2'
  end
  object edtB: TEdit
    Left = 144
    Top = 48
    Width = 57
    Height = 23
    TabOrder = 1
    Text = '2'
  end
  object btnAdd: TButton
    Left = 16
    Top = 92
    Width = 105
    Height = 33
    Caption = 'Add'
    TabOrder = 2
    OnClick = btnAddClick
  end
  object btnSubtract: TButton
    Left = 136
    Top = 92
    Width = 105
    Height = 33
    Caption = 'Subtract'
    TabOrder = 3
    OnClick = btnSubtractClick
  end
  object btnMultiply: TButton
    Left = 256
    Top = 92
    Width = 105
    Height = 33
    Caption = 'Multiply'
    TabOrder = 4
    OnClick = btnMultiplyClick
  end
end
