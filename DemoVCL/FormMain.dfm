object frmMain: TfrmMain
  Left = 0
  Top = 0
  Caption = 'Autopilot Demo'
  ClientHeight = 416
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
  object lblActionResult: TLabel
    Left = 16
    Top = 296
    Width = 4
    Height = 15
    Hint = 'Test fixture: actFixture writes its run count and its Sender class here'
    Caption = '-'
  end
  object lblCheckState: TLabel
    Left = 264
    Top = 338
    Width = 4
    Height = 15
    Hint = 'Test fixture: chkFixture writes its state here'
    Caption = '-'
  end
  object sbAction: TSpeedButton
    Left = 190
    Top = 256
    Width = 161
    Height = 33
    Action = actFixture
  end
  object pnlFixture: TPanel
    Left = 16
    Top = 204
    Width = 388
    Height = 41
    Hint = 'Test fixture: a panel with a label placed on it, for the path rule'
    TabOrder = 3
    object lblInPanel: TLabel
      Left = 8
      Top = 12
      Width = 89
      Height = 15
      Hint = 'Test fixture: owned by the form, placed on pnlFixture'
      Caption = 'Inside the panel'
    end
  end
  object btnAction: TButton
    Left = 16
    Top = 256
    Width = 161
    Height = 33
    Action = actFixture
    TabOrder = 4
  end
  object chkFixture: TCheckBox
    Left = 16
    Top = 336
    Width = 233
    Height = 19
    Hint = 'Test fixture: writes checked or unchecked to lblCheckState'
    Caption = 'Fixture check box'
    TabOrder = 5
    OnClick = chkFixtureClick
  end
  object lblDelayed: TLabel
    Left = 264
    Top = 376
    Width = 4
    Height = 15
    Hint = 'Test fixture: tmrDelayed writes here one second after btnDelayed is clicked'
    Caption = '-'
  end
  object btnDelayed: TButton
    Left = 16
    Top = 368
    Width = 161
    Height = 33
    Hint = 'Test fixture: starts tmrDelayed, which changes lblDelayed one second later'
    Caption = 'Delayed text'
    TabOrder = 6
    OnClick = btnDelayedClick
  end
  object tmrDelayed: TTimer
    Enabled = False
    OnTimer = tmrDelayedTimer
    Left = 392
    Top = 340
  end
  object actlFixture: TActionList
    Left = 360
    Top = 340
    object actFixture: TAction
      Caption = 'Run action'
      Hint = 'Test fixture: an action bound to btnAction and sbAction'
      OnExecute = actFixtureExecute
    end
  end
end
