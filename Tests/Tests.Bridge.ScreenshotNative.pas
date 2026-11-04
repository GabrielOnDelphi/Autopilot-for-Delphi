unit Tests.Bridge.ScreenshotNative;

{=============================================================================================================
   2026.11.04
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX test: does the bridge's screenshot draw every VCL control that wraps a native Windows control?
   - The bridge paints a form into a memory bitmap (GetFormImage -> TWinControl.PaintTo, Vcl.Controls.pas), which sends each child WM_PAINT with its own DC.
     A native control that ignores that DC would leave its area blank; the bridge repaints TLinkLabel and TComboBoxEx with WM_PRINT for that reason.
   - One control of each class the VCL creates with CreateSubClass (Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls), each with visible content, plus a TLinkLabel inside a TPanel.
     TAnimate is left out: it needs an AVI resource.
   - Reference: PrintWindow with PW_RENDERFULLCONTENT on the shown form, the pixels Windows itself renders for the window.
     Called from the form's own thread, PrintWindow draws nothing (Footguns.md, section "Tests"); from a worker thread, while this thread pumps, it works.
   - The form is shown with Visible := TRUE: ShowWindow alone shows only the form's own window, not the child windows.
     So the form takes the foreground for a moment, and a key typed during the run lands in it.
   - Each control is cropped from both captures and compared pixel by pixel.
     The classes in KnownDifferences may differ from the reference; no control may come out blank.
     A control that fails is judged once more, against a new reference; only a second failure fails the test.
     Both crops of every control and a report go to %TEMP%\Autopilot\ScreenshotNative\.
=============================================================================================================}

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TScreenshotNativeTests = class
  private
    FPipeName: String;
  public
    [Setup]    procedure Setup;
    [TearDown] procedure TearDown;

    [Test] procedure Test_Screenshot_NativeControlsLookAsOnScreen;
    [Test] procedure Test_Screenshot_MinimizedFormDrawsLinkLabelAndComboBoxEx;
    [Test] procedure Test_Screenshot_RepaintedControlStaysInsideItsParent;
  end;


implementation

uses
  Winapi.Windows, Winapi.WinSpool,
  System.Types, System.SysUtils, System.Classes, System.IOUtils, System.JSON,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Themes, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls, Vcl.Menus, Vcl.Imaging.PngImage,
  Autopilot.Bridge.Vcl,
  Bridge.TestClient, Bridge.Tests, Tests.Bridge.Screenshot;

const
  // #define PW_RENDERFULLCONTENT 0x00000002, under _WIN32_WINNT >= 0x0603 (Windows 8.1), read in the MinGW copy of winuser.h, not in the Microsoft SDK. Winapi.WinSpool declares PrintWindow but not this flag.
  PW_RENDERFULLCONTENT = $00000002;

  // Two pixels "match" when their R, G and B differ by at most this much in total: text drawn on a memory DC can be anti-aliased differently from text on screen.
  PixelTolerance = 48;

  // A crop that matches the reference in fewer pixels than this is reported.
  MinMatchPercent = 90;

  // Ink = the pixels that differ from the crop's top-left pixel by more than PixelTolerance.
  // A crop with less ink than this, in percent of its area, is blank: one stray pixel must not count as a drawn control.
  MinInkPercent = 1;

  GapPx = 10;

  { The classes whose bridge crop may differ from the reference without failing the test, as measured on Windows 11 with themes on.
    They must still not come out blank.
      THotKey      known gap: without a VCL style no paint message draws its text (WM_PAINT, WM_PRINT, WM_PRINTCLIENT); the AI reads it with get_text
      TEdit        cosmetic: its border
      TListBox     cosmetic: the selection highlight is missing
      TCoolBar     cosmetic: its background
      TProgressBar cosmetic: its glow animates between the two captures, so the match changes from run to run }
  KnownDifferences: array[0..4] of String = ('THotKey', 'TEdit', 'TListBox', 'TCoolBar', 'TProgressBar');

type
  TNativeShotForm = class(TForm)
  private
    FX, FY, FRowHeight: Integer;
    procedure Place(AControl: TWinControl; const AName: String; AWidth, AHeight: Integer; AIsProbe: Boolean = TRUE);
  public
    Probes: array of TWinControl;
    constructor Create(AOwner: TComponent); override;
  end;

  { The two repainted classes, for the minimized and the clip test.
    lnkClipped sticks out of pnlClip on the right, as a control partly scrolled out of a TScrollBox does. }
  TLinkShotForm = class(TForm)
  public
    LnkOnForm: TLinkLabel;
    PnlHolder: TPanel;
    LnkInPanel: TLinkLabel;
    CbxOnForm: TComboBoxEx;
    PnlClip: TPanel;
    LnkClipped: TLinkLabel;
    constructor Create(AOwner: TComponent); override;
  end;


{ TNativeShotForm }

// Flow layout: left to right, then a new row. Every control lies wholly inside the client area, so the bridge's crop is never clipped.
procedure TNativeShotForm.Place(AControl: TWinControl; const AName: String; AWidth, AHeight: Integer; AIsProbe: Boolean = TRUE);
begin
  if FX + AWidth > ClientWidth - GapPx then
  begin
    FX := GapPx;
    Inc(FY, FRowHeight + GapPx);
    FRowHeight := 0;
  end;
  AControl.Name := AName;
  AControl.SetBounds(FX, FY, AWidth, AHeight);
  AControl.Parent := Self;
  Inc(FX, AWidth + GapPx);
  if AHeight > FRowHeight then
    FRowHeight := AHeight;
  if AIsProbe then
  begin
    SetLength(Probes, Length(Probes) + 1);
    Probes[High(Probes)] := AControl;
  end;
end;


constructor TNativeShotForm.Create(AOwner: TComponent);
var
  Edit: TEdit;
  Memo: TMemo;
  Combo: TComboBox;
  Button: TButton;
  Check: TCheckBox;
  Radio: TRadioButton;
  List: TListBox;
  Scroll: TScrollBar;
  StaticText: TStaticText;
  Link, LinkInPanel: TLinkLabel;
  Panel: TPanel;
  Tabs: TTabControl;
  Pages: TPageControl;
  Sheet: TTabSheet;
  Status: TStatusBar;
  Header: THeaderControl;
  Tree: TTreeView;
  Node: TTreeNode;
  Track: TTrackBar;
  Progress: TProgressBar;
  Rich: TRichEdit;
  UpDown: TUpDown;
  HotKey: THotKey;
  ListView: TListView;
  Item: TListItem;
  ToolBar: TToolBar;
  ToolButton: TToolButton;
  CoolBar: TCoolBar;
  Band: TCoolBand;
  Calendar: TMonthCalendar;
  DatePicker: TDateTimePicker;
  Pager: TPageScroller;
  PagerButton: TButton;
  ComboEx: TComboBoxEx;
begin
  inherited CreateNew(AOwner);
  Name     := 'NativeShotForm';
  Caption  := 'Screenshot fixture, native controls';
  Scaled   := FALSE;
  Position := poDesigned;
  ClientWidth  := 1000;
  ClientHeight := 620;
  FX := GapPx;
  FY := GapPx;
  FRowHeight := 0;

  { # Vcl.StdCtrls }
  Edit := TEdit.Create(Self);
  Place(Edit, 'edtNative', 150, 24);
  Edit.Text := 'Edit text';

  Memo := TMemo.Create(Self);
  Place(Memo, 'memNative', 150, 60);
  Memo.Lines.Text := 'Memo line one' + sLineBreak + 'Memo line two';

  Combo := TComboBox.Create(Self);
  Place(Combo, 'cmbNative', 150, 24);
  Combo.Items.Add('Combo item');
  Combo.ItemIndex := 0;

  Button := TButton.Create(Self);
  Place(Button, 'btnNative', 100, 28);
  Button.Caption := 'Button';

  Check := TCheckBox.Create(Self);
  Place(Check, 'chkNative', 120, 20);
  Check.Caption := 'Check box';
  Check.Checked := TRUE;

  Radio := TRadioButton.Create(Self);
  Place(Radio, 'radNative', 120, 20);
  Radio.Caption := 'Radio button';
  Radio.Checked := TRUE;

  List := TListBox.Create(Self);
  Place(List, 'lstNative', 120, 60);
  List.Items.Add('List item 1');
  List.Items.Add('List item 2');
  List.ItemIndex := 0;

  Scroll := TScrollBar.Create(Self);
  Place(Scroll, 'sbNative', 150, 18);
  Scroll.Position := 30;

  StaticText := TStaticText.Create(Self);
  Place(StaticText, 'stNative', 120, 20);
  StaticText.Caption := 'Static text';

  { # Vcl.ExtCtrls }
  Link := TLinkLabel.Create(Self);
  Place(Link, 'lnkNative', 160, 20);
  Link.Caption := 'Visit <a>gabrielmoraru.com</a>';

  // The nested case: the bridge must find a link label whose parent is not the form, and paint it at the right place
  Panel := TPanel.Create(Self);
  Place(Panel, 'pnlNative', 180, 40, FALSE);
  Panel.ShowCaption := FALSE;
  LinkInPanel := TLinkLabel.Create(Self);
  LinkInPanel.Name := 'lnkInPanel';
  LinkInPanel.SetBounds(10, 10, 160, 20);
  LinkInPanel.Parent := Panel;
  LinkInPanel.Caption := 'Visit <a>gabrielmoraru.com</a>';
  SetLength(Probes, Length(Probes) + 1);
  Probes[High(Probes)] := LinkInPanel;

  { # Vcl.ComCtrls }
  Tabs := TTabControl.Create(Self);
  Place(Tabs, 'tabNative', 160, 60);
  Tabs.Tabs.Add('Tab one');
  Tabs.Tabs.Add('Tab two');

  Pages := TPageControl.Create(Self);
  Place(Pages, 'pgNative', 160, 60);
  Sheet := TTabSheet.Create(Self);
  Sheet.PageControl := Pages;
  Sheet.Caption := 'Sheet one';
  Sheet := TTabSheet.Create(Self);
  Sheet.PageControl := Pages;
  Sheet.Caption := 'Sheet two';

  Status := TStatusBar.Create(Self);
  Status.Align := alNone;
  Place(Status, 'stbNative', 200, 22);
  Status.SimplePanel := TRUE;
  Status.SimpleText := 'Status bar text';

  Header := THeaderControl.Create(Self);
  Header.Align := alNone;
  Place(Header, 'hdrNative', 200, 22);
  Header.Sections.Add.Text := 'Header one';
  Header.Sections[0].Width := 100;
  Header.Sections.Add.Text := 'Header two';
  Header.Sections[1].Width := 100;

  Tree := TTreeView.Create(Self);
  Place(Tree, 'tvNative', 140, 80);
  Node := Tree.Items.Add(NIL, 'Tree root');
  Tree.Items.AddChild(Node, 'Tree child');
  Tree.FullExpand;

  Track := TTrackBar.Create(Self);
  Place(Track, 'trkNative', 150, 40);
  Track.Position := 3;

  Progress := TProgressBar.Create(Self);
  Place(Progress, 'prgNative', 150, 20);
  Progress.Position := 60;

  Rich := TRichEdit.Create(Self);
  Place(Rich, 'reNative', 150, 60);
  Rich.Lines.Text := 'Rich edit text';

  UpDown := TUpDown.Create(Self);
  Place(UpDown, 'udNative', 20, 40);

  HotKey := THotKey.Create(Self);
  Place(HotKey, 'hkNative', 120, 24);
  HotKey.HotKey := ShortCut(Ord('A'), [ssCtrl]);

  ListView := TListView.Create(Self);
  Place(ListView, 'lvNative', 200, 80);
  ListView.ViewStyle := vsReport;
  ListView.Columns.Add.Caption := 'Column one';
  ListView.Columns[0].Width := 90;
  ListView.Columns.Add.Caption := 'Column two';
  ListView.Columns[1].Width := 90;
  Item := ListView.Items.Add;
  Item.Caption := 'Row one';
  Item.SubItems.Add('Cell');

  ToolBar := TToolBar.Create(Self);
  ToolBar.Align := alNone;
  Place(ToolBar, 'tbNative', 200, 30);
  ToolBar.ShowCaptions := TRUE;
  ToolButton := TToolButton.Create(Self);
  ToolButton.Caption := 'Tool button';
  ToolButton.Parent := ToolBar;

  CoolBar := TCoolBar.Create(Self);
  CoolBar.Align := alNone;
  Place(CoolBar, 'cbNative', 200, 30);
  Band := CoolBar.Bands.Add;
  Band.Text := 'Cool band';
  Band.MinHeight := 24;

  Calendar := TMonthCalendar.Create(Self);
  Place(Calendar, 'mcNative', 230, 170);
  Calendar.Date := EncodeDate(2026, 11, 3);

  DatePicker := TDateTimePicker.Create(Self);
  Place(DatePicker, 'dtpNative', 150, 24);
  DatePicker.Date := EncodeDate(2026, 11, 3);

  // The pager shows only its scroll arrows; the button inside is a VCL control that PaintTo paints by itself.
  Pager := TPageScroller.Create(Self);
  Place(Pager, 'psNative', 150, 30);
  PagerButton := TButton.Create(Self);
  PagerButton.Name := 'btnInPager';
  PagerButton.Caption := 'Button inside a page scroller';
  PagerButton.SetBounds(0, 0, 300, 30);
  PagerButton.Parent := Pager;
  Pager.Control := PagerButton;

  ComboEx := TComboBoxEx.Create(Self);
  Place(ComboEx, 'cbxNative', 150, 24);
  ComboEx.ItemsEx.AddItem('ComboEx item', -1, -1, -1, 0, NIL);
  ComboEx.ItemIndex := 0;
end;


{ TLinkShotForm }

constructor TLinkShotForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Name     := 'LinkShotForm';
  Caption  := 'Screenshot fixture, repainted controls';
  Scaled   := FALSE;
  Position := poDesigned;
  ClientWidth  := 400;
  ClientHeight := 200;

  LnkOnForm := TLinkLabel.Create(Self);
  LnkOnForm.Name := 'lnkOnForm';
  LnkOnForm.SetBounds(10, 10, 260, 20);
  LnkOnForm.Parent := Self;
  LnkOnForm.Caption := 'Visit <a>gabrielmoraru.com</a>';

  PnlHolder := TPanel.Create(Self);
  PnlHolder.Name := 'pnlHolder';
  PnlHolder.SetBounds(10, 40, 300, 40);
  PnlHolder.Parent := Self;
  PnlHolder.ShowCaption := FALSE;
  LnkInPanel := TLinkLabel.Create(Self);
  LnkInPanel.Name := 'lnkInPanel';
  LnkInPanel.SetBounds(10, 10, 260, 20);
  LnkInPanel.Parent := PnlHolder;
  LnkInPanel.Caption := 'Visit <a>gabrielmoraru.com</a>';

  CbxOnForm := TComboBoxEx.Create(Self);
  CbxOnForm.Name := 'cbxOnForm';
  CbxOnForm.SetBounds(10, 90, 150, 24);
  CbxOnForm.Parent := Self;
  CbxOnForm.ItemsEx.AddItem('ComboEx item', -1, -1, -1, 0, NIL);
  CbxOnForm.ItemIndex := 0;

  PnlClip := TPanel.Create(Self);
  PnlClip.Name := 'pnlClip';
  PnlClip.SetBounds(10, 130, 100, 30);
  PnlClip.Parent := Self;
  PnlClip.ShowCaption := FALSE;
  PnlClip.BevelOuter := bvNone;
  LnkClipped := TLinkLabel.Create(Self);
  LnkClipped.Name := 'lnkClipped';
  LnkClipped.AutoSize := FALSE;            // AutoSize would shrink it to its text
  LnkClipped.SetBounds(40, 5, 260, 20);   // right edge at 300 in the panel, which is 100 wide
  LnkClipped.Parent := PnlClip;
  LnkClipped.Caption := 'Visit <a>gabrielmoraru.com</a> for the book';   // the text runs well past the panel's right edge
end;


{ Helpers --------------------------------------------------------------- }

// Dispatches this thread's messages for AMs milliseconds, so the shown form and its children paint.
procedure PumpMessagesFor(AMs: Cardinal);
var
  Deadline: UInt64;
  Msg: TMsg;
begin
  Deadline := GetTickCount64 + AMs;
  while GetTickCount64 < Deadline do
  begin
    while PeekMessage(Msg, 0, 0, 0, PM_REMOVE) do
    begin
      TranslateMessage(Msg);
      DispatchMessage(Msg);
    end;
    CheckSynchronize;
    Sleep(10);
  end;
end;


// Shows AForm at the top-left of the work area and lets every child paint.
procedure ShowAndPaint(AForm: TForm);
var
  WorkArea: TRect;
begin
  WorkArea := Screen.WorkAreaRect;
  AForm.Left := WorkArea.Left;
  AForm.Top  := WorkArea.Top;
  AForm.Visible := TRUE;   // ShowWindow alone shows only the form's own window: the VCL shows the child windows when Showing becomes TRUE
  RedrawWindow(AForm.Handle, NIL, 0, RDW_ERASE or RDW_INVALIDATE or RDW_ALLCHILDREN or RDW_UPDATENOW);
  PumpMessagesFor(500);
end;


// The client area of AForm as Windows renders it (PrintWindow, PW_RENDERFULLCONTENT). The caller frees the result.
function ClientImageFromWindows(AForm: TForm): TBitmap;
var
  WinRect: TRect;
  Origin: TPoint;
  Full: TBitmap;
  Wnd: HWND;
  DC: HDC;
  Ok: Boolean;
  ErrCode: DWORD;
begin
  Assert.IsTrue(IsWindowVisible(AForm.Handle), 'fixture: the form window must be visible, or Windows has no pixels of it');
  Assert.IsTrue(GetWindowRect(AForm.Handle, WinRect), 'GetWindowRect failed: ' + SysErrorMessage(GetLastError));
  Full := TBitmap.Create;
  try
    Full.PixelFormat := pf32bit;
    Full.SetSize(WinRect.Width, WinRect.Height);
    Wnd := AForm.Handle;
    DC  := Full.Canvas.Handle;
    Ok  := FALSE;
    ErrCode := 0;
    Full.Canvas.Lock;   // keeps DC alive while the worker thread draws into it
    try
      // Called from another thread: the form's own thread must keep pumping while Windows renders it
      RunOnWorkerAndPump(
        procedure
        begin
          Ok := PrintWindow(Wnd, DC, PW_RENDERFULLCONTENT);
          if not Ok then
            ErrCode := GetLastError;
        end, 10000);
    finally
      Full.Canvas.Unlock;
    end;
    Assert.IsTrue(Ok, 'PrintWindow failed, GetLastError = ' + IntToStr(ErrCode));
    Origin := AForm.ClientToScreen(Point(0, 0));
    Result := TBitmap.Create;
    Result.PixelFormat := pf24bit;
    Result.SetSize(AForm.ClientWidth, AForm.ClientHeight);
    BitBlt(Result.Canvas.Handle, 0, 0, Result.Width, Result.Height, Full.Canvas.Handle, Origin.X - WinRect.Left, Origin.Y - WinRect.Top, SRCCOPY);
  finally
    FreeAndNil(Full);
  end;
end;


{ The window rectangle of AControl in AForm's client coordinates, from the screen positions Windows reports, also for a control inside a panel.
  Deliberately not the bridge's own calculation (BoundsRect mapped through the parents), so a wrong offset in the bridge shows as a mismatch. }
function FormRectOf(AForm: TForm; AControl: TWinControl): TRect;
var
  Origin: TPoint;
begin
  Assert.IsTrue(GetWindowRect(AControl.Handle, Result), 'GetWindowRect failed: ' + SysErrorMessage(GetLastError));
  Origin := AForm.ClientOrigin;
  Result.Offset(-Origin.X, -Origin.Y);
end;


// The name of AControl in the report and in the PNG file names: its class, plus the parent's class when the parent is not the form.
function ProbeTitle(AControl: TWinControl): String;
begin
  Result := AControl.ClassName;
  if not (AControl.Parent is TCustomForm) then
    Result := Result + ' in ' + AControl.Parent.ClassName;
end;


function IsKnownDifference(const AClassName: String): Boolean;
var
  Known: String;
begin
  for Known in KnownDifferences do
    if Known = AClassName then
      EXIT(TRUE);
  Result := FALSE;
end;


// ARect of ASource as a new 24-bit bitmap. The caller frees the result.
function CropOf(ASource: TBitmap; const ARect: TRect): TBitmap;
begin
  Result := TBitmap.Create;
  Result.PixelFormat := pf24bit;
  Result.SetSize(ARect.Width, ARect.Height);
  BitBlt(Result.Canvas.Handle, 0, 0, ARect.Width, ARect.Height, ASource.Canvas.Handle, ARect.Left, ARect.Top, SRCCOPY);
end;


// The PNG as a 24-bit bitmap, so both crops are read the same way. The caller frees the result.
function BitmapOf(APng: TPngImage): TBitmap;
begin
  Result := TBitmap.Create;
  Result.PixelFormat := pf24bit;
  Result.SetSize(APng.Width, APng.Height);
  Result.Canvas.Draw(0, 0, APng);
end;


function ColorDistance(A, B: TColor): Integer;
begin
  Result := Abs(GetRValue(A) - GetRValue(B)) + Abs(GetGValue(A) - GetGValue(B)) + Abs(GetBValue(A) - GetBValue(B));
end;


// The ink of ABmp in percent of its area (see MinInkPercent).
function InkPercent(ABmp: TBitmap): Integer;
var
  X, Y, Ink: Integer;
  Back: TColor;
begin
  Back := ABmp.Canvas.Pixels[0, 0];
  Ink := 0;
  for Y := 0 to ABmp.Height - 1 do
    for X := 0 to ABmp.Width - 1 do
      if ColorDistance(ABmp.Canvas.Pixels[X, Y], Back) > PixelTolerance then
        Inc(Ink);
  Result := (Ink * 100) div (ABmp.Width * ABmp.Height);
end;


// The share of pixels, in percent, that are the same in both bitmaps within PixelTolerance. Both must have the same size.
function MatchPercent(A, B: TBitmap): Integer;
var
  X, Y, Same: Integer;
begin
  Same := 0;
  for Y := 0 to A.Height - 1 do
    for X := 0 to A.Width - 1 do
      if ColorDistance(A.Canvas.Pixels[X, Y], B.Canvas.Pixels[X, Y]) <= PixelTolerance then
        Inc(Same);
  Result := (Same * 100) div (A.Width * A.Height);
end;


procedure SaveAsPng(ABmp: TBitmap; const AFileName: String);
var
  Png: TPngImage;
begin
  Png := TPngImage.Create;
  try
    Png.Assign(ABmp);
    Png.SaveToFile(AFileName);
  finally
    FreeAndNil(Png);
  end;
end;


function OutDir: String;
begin
  Result := TPath.Combine(TPath.GetTempPath, 'Autopilot\ScreenshotNative');
  ForceDirectories(Result);
end;


// The bridge's screenshot of APath (a control path, or '' with AFormName for the whole form) as a 24-bit bitmap. The caller frees the result.
function BridgeShot(const APipeName, AFormName, APath: String): TBitmap;
var
  Root, R: TJSONObject;
  Png: TPngImage;
begin
  Root := Shoot(APipeName, ShotArgs(AFormName, APath));
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'screenshot of ' + AFormName + APath + ' must succeed: ' + ErrorMessageOf(Root));
    Png := ImageOf(R);
    try
      Result := BitmapOf(Png);
    finally
      FreeAndNil(Png);
    end;
  finally
    FreeAndNil(Root);
  end;
end;


{ TScreenshotNativeTests ------------------------------------------------ }

procedure TScreenshotNativeTests.Setup;
begin
  FPipeName := '\\.\pipe\AutopilotTestShotNative.' + IntToStr(GetCurrentProcessId);
  StartBridgeOnPipe(FPipeName);
end;


procedure TScreenshotNativeTests.TearDown;
begin
  StopBridge;
end;


{ Where the mouse cursor is, for the report: a control under the cursor may draw a hover look on screen.
  Names the probe under it, if any. }
function CursorReport(AForm: TNativeShotForm): String;
var
  Cursor: TPoint;
  Control: TWinControl;
begin
  if not GetCursorPos(Cursor) then
    EXIT('Cursor: GetCursorPos failed: ' + SysErrorMessage(GetLastError));
  Cursor := AForm.ScreenToClient(Cursor);
  Result := 'Cursor: ' + IntToStr(Cursor.X) + ',' + IntToStr(Cursor.Y) + ' relative to the form''s client area';
  if not AForm.ClientRect.Contains(Cursor) then
    EXIT(Result + ' (outside the form)');
  for Control in AForm.Probes do
    if FormRectOf(AForm, Control).Contains(Cursor) then
      EXIT(Result + ' (over ' + ProbeTitle(Control) + ')');
  Result := Result + ' (over the form, on no probe)';
end;


{ Compares one probe: the bridge's crop of AControl against its crop of ARefClient, the reference Windows rendered.
  Returns the verdict: 'ok', 'known difference', or one of the failures 'BLANK', 'DIFFERENT', 'REFERENCE BLANK'.
  'REFERENCE BLANK' = Windows itself had not drawn the control, so the reference proves nothing.
  Adds one line to AReport and saves both crops with ASuffix in their file names. }
function JudgeProbe(const APipeName: String; AForm: TNativeShotForm; AControl: TWinControl; ARefClient: TBitmap; const ASuffix: String; var AReport: String): String;
var
  Title: String;
  RefCrop, ShotCrop: TBitmap;
  Match, ShotInk, RefInk: Integer;
begin
  Title := ProbeTitle(AControl);
  ShotCrop := BridgeShot(APipeName, '', 'NativeShotForm.' + AControl.Name);
  RefCrop := NIL;
  try
    RefCrop := CropOf(ARefClient, FormRectOf(AForm, AControl));
    Assert.AreEqual(RefCrop.Width,  ShotCrop.Width,  Title + ': crop width');
    Assert.AreEqual(RefCrop.Height, ShotCrop.Height, Title + ': crop height');

    RefInk  := InkPercent(RefCrop);
    ShotInk := InkPercent(ShotCrop);
    Match   := MatchPercent(ShotCrop, RefCrop);

    if RefInk < MinInkPercent
    then Result := 'REFERENCE BLANK'
    else
      if ShotInk < MinInkPercent
      then Result := 'BLANK'
      else
        if Match < MinMatchPercent
        then
          if IsKnownDifference(AControl.ClassName)
          then Result := 'known difference'
          else Result := 'DIFFERENT'
        else Result := 'ok';

    AReport := AReport + Title + ASuffix + #9 + Result + #9 + 'match ' + IntToStr(Match) + '%' + #9 +
               'ink bridge ' + IntToStr(ShotInk) + '% / Windows ' + IntToStr(RefInk) + '%' + sLineBreak;
    SaveAsPng(ShotCrop, TPath.Combine(OutDir, Title + ASuffix + ' - bridge.png'));
    SaveAsPng(RefCrop,  TPath.Combine(OutDir, Title + ASuffix + ' - Windows.png'));
  finally
    FreeAndNil(RefCrop);
    FreeAndNil(ShotCrop);
  end;
end;


function IsFailure(const AVerdict: String): Boolean;
begin
  Result := (AVerdict = 'BLANK') or (AVerdict = 'DIFFERENT') or (AVerdict = 'REFERENCE BLANK');
end;


{ Every native control must look in the bridge's screenshot as Windows renders it.
  A class in KnownDifferences may differ, but no control may come out blank.
  A control that fails is judged a second time against a new reference and a new bridge crop: in the full suite the first reference was once taken before a child had painted.
  It fails only when the second judgement fails too, so a real bridge defect, which fails every time, still fails the test.
  Fails once, naming every control that breaks the rule; the report and both crops of every control are in OutDir. }
procedure TScreenshotNativeTests.Test_Screenshot_NativeControlsLookAsOnScreen;
var
  F: TNativeShotForm;
  Report, Failed, FixtureFailed, Verdict: String;
  RefClient: TBitmap;
  Control: TWinControl;
  Retry: array of TWinControl;
begin
  Assert.IsTrue(StyleServices.Available, 'Tests.exe has no runtime-themes manifest: the VCL then creates TLinkLabel as a STATIC (TCustomLinkLabel.CreateParams, Vcl.ExtCtrls.pas) and the common controls are version 5, not what a customer''s app runs');
  Report := '';
  Failed := '';
  FixtureFailed := '';
  Retry := NIL;

  F := TNativeShotForm.Create(NIL);
  try
    ShowAndPaint(F);
    Report := CursorReport(F) + sLineBreak;

    { # Attempt 1: every control }
    RefClient := ClientImageFromWindows(F);
    try
      Assert.AreEqual(F.ClientWidth,  RefClient.Width,  'fixture: reference width');
      Assert.AreEqual(F.ClientHeight, RefClient.Height, 'fixture: reference height');
      SaveAsPng(RefClient, TPath.Combine(OutDir, '_Form - Windows.png'));
      for Control in F.Probes do
        if IsFailure(JudgeProbe(FPipeName, F, Control, RefClient, '', Report)) then
        begin
          SetLength(Retry, Length(Retry) + 1);
          Retry[High(Retry)] := Control;
        end;
    finally
      FreeAndNil(RefClient);
    end;

    { # Attempt 2: only the controls that failed, against a new reference }
    if Length(Retry) > 0 then
    begin
      Report := Report + sLineBreak + 'Attempt 2, for the ' + IntToStr(Length(Retry)) + ' controls that failed above' + sLineBreak;
      RedrawWindow(F.Handle, NIL, 0, RDW_ERASE or RDW_INVALIDATE or RDW_ALLCHILDREN or RDW_UPDATENOW);
      PumpMessagesFor(500);
      Report := Report + CursorReport(F) + sLineBreak;
      RefClient := ClientImageFromWindows(F);
      try
        SaveAsPng(RefClient, TPath.Combine(OutDir, '_Form - attempt 2 - Windows.png'));
        for Control in Retry do
        begin
          Verdict := JudgeProbe(FPipeName, F, Control, RefClient, ' - attempt 2', Report);
          if Verdict = 'REFERENCE BLANK'
          then FixtureFailed := FixtureFailed + ' ' + ProbeTitle(Control)
          else
            if IsFailure(Verdict) then
              Failed := Failed + ' ' + ProbeTitle(Control) + ' (' + Verdict + ')';
        end;
      finally
        FreeAndNil(RefClient);
      end;
    end;
  finally
    FreeAndNil(F);
  end;

  TFile.WriteAllText(TPath.Combine(OutDir, 'Report.txt'), Report);
  Assert.IsTrue(Failed = '', 'controls the screenshot does not draw as Windows renders them, in both attempts:' + Failed + '. Report and crops: ' + OutDir);
  Assert.IsTrue(FixtureFailed = '', 'fixture: Windows rendered these controls blank in both attempts, so the reference proves nothing:' + FixtureFailed + '. Report and crops: ' + OutDir);
end;


{ One attempt of Test_Screenshot_MinimizedFormDrawsLinkLabelAndComboBoxEx, on a new form.
  Returns '' when every control passes, else what failed. Saves the crops with ASuffix in their file names. }
function MinimizedAttempt(const APipeName, ASuffix: String): String;
var
  F: TLinkShotForm;
  RefClient, ShotCrop: TBitmap;
  Links: array[0..1] of TLinkLabel;
  RefCrops: array[0..1] of TBitmap;
  Title: String;
  i, Match, Ink, RefInk: Integer;
begin
  Result := '';
  RefCrops[0] := NIL;
  RefCrops[1] := NIL;
  F := TLinkShotForm.Create(NIL);
  try
    ShowAndPaint(F);
    Links[0] := F.LnkOnForm;
    Links[1] := F.LnkInPanel;

    // The reference crops are cut while the form is shown: a minimized window has no client area on screen
    RefClient := ClientImageFromWindows(F);
    try
      for i := 0 to High(Links) do
        RefCrops[i] := CropOf(RefClient, FormRectOf(F, Links[i]));
    finally
      FreeAndNil(RefClient);
    end;

    F.WindowState := wsMinimized;
    PumpMessagesFor(500);
    Assert.IsTrue(IsIconic(F.Handle), 'fixture: the form must be minimized');

    for i := 0 to High(Links) do
    begin
      Title := 'Minimized - ' + ProbeTitle(Links[i]);
      ShotCrop := BridgeShot(APipeName, '', 'LinkShotForm.' + Links[i].Name);
      try
        SaveAsPng(ShotCrop,    TPath.Combine(OutDir, Title + ASuffix + ' - bridge.png'));
        SaveAsPng(RefCrops[i], TPath.Combine(OutDir, Title + ASuffix + ' - Windows.png'));
        Assert.AreEqual(RefCrops[i].Width,  ShotCrop.Width,  Title + ': crop width');
        Assert.AreEqual(RefCrops[i].Height, ShotCrop.Height, Title + ': crop height');
        RefInk := InkPercent(RefCrops[i]);
        Ink    := InkPercent(ShotCrop);
        Match  := MatchPercent(ShotCrop, RefCrops[i]);
        if RefInk < MinInkPercent
        then Result := Result + ' fixture: Windows rendered ' + ProbeTitle(Links[i]) + ' blank, so the reference proves nothing.'
        else
          if (Ink < MinInkPercent) or (Match < MinMatchPercent) then
            Result := Result + ' ' + Title + ' must look as on screen: ink bridge ' + IntToStr(Ink) + '% / Windows ' + IntToStr(RefInk) + '%, match ' + IntToStr(Match) + '%.';
      finally
        FreeAndNil(ShotCrop);
      end;
    end;

    ShotCrop := BridgeShot(APipeName, '', 'LinkShotForm.cbxOnForm');
    try
      SaveAsPng(ShotCrop, TPath.Combine(OutDir, 'Minimized - TComboBoxEx' + ASuffix + ' - bridge.png'));
      Ink := InkPercent(ShotCrop);
      if Ink < MinInkPercent then
        Result := Result + ' the TComboBoxEx on the minimized form must not be blank: ink ' + IntToStr(Ink) + '%.';
    finally
      FreeAndNil(ShotCrop);
    end;
  finally
    FreeAndNil(RefCrops[0]);
    FreeAndNil(RefCrops[1]);
    FreeAndNil(F);
  end;
end;


{ On a minimized form the bridge captures through GetMinimizedFormImage; the repaint must land at the same place there.
  The link labels must match the reference taken while the form was shown.
  TComboBoxEx must only be drawn: minimized, WM_PRINT draws it without the selection highlight, so its match with the shown reference is low by nature.
  A failed attempt is repeated once on a new form, as in Test_Screenshot_NativeControlsLookAsOnScreen; only a second failure fails the test. }
procedure TScreenshotNativeTests.Test_Screenshot_MinimizedFormDrawsLinkLabelAndComboBoxEx;
var
  Failed1, Failed2: String;
begin
  Assert.IsTrue(StyleServices.Available, 'Tests.exe has no runtime-themes manifest (Footguns.md, section "Tests")');
  Failed1 := MinimizedAttempt(FPipeName, '');
  if Failed1 = ''
  then Failed2 := ''
  else Failed2 := MinimizedAttempt(FPipeName, ' - attempt 2');
  Assert.IsTrue(Failed2 = '', 'failed in both attempts. Attempt 1:' + Failed1 + ' Attempt 2:' + Failed2 + ' Crops: ' + OutDir);
end;


{ lnkClipped sticks out of pnlClip on the right. On screen Windows clips it to the panel, so the form right of the panel stays empty.
  The repaint must be clipped the same way: the strip right of the panel, as high as the link label, must have no ink in the bridge's image.
  The part inside the panel must be drawn, so the strip is not empty only because nothing was repainted. }
procedure TScreenshotNativeTests.Test_Screenshot_RepaintedControlStaysInsideItsParent;
var
  F: TLinkShotForm;
  Shot, Inside, Outside: TBitmap;
  LinkR, PanelR: TRect;
  InkIn, InkOut: Integer;
begin
  Assert.IsTrue(StyleServices.Available, 'Tests.exe has no runtime-themes manifest (Footguns.md, section "Tests")');
  F := TLinkShotForm.Create(NIL);
  try
    ShowAndPaint(F);
    LinkR  := FormRectOf(F, F.LnkClipped);
    PanelR := FormRectOf(F, F.PnlClip);
    Assert.IsTrue(LinkR.Right > PanelR.Right + 100, 'fixture: lnkClipped must stick out of pnlClip on the right');
    Assert.IsTrue(LinkR.Right < F.ClientWidth, 'fixture: the strip right of pnlClip must lie inside the form');

    Shot := BridgeShot(FPipeName, 'LinkShotForm', '');
    Inside  := NIL;
    Outside := NIL;
    try
      SaveAsPng(Shot, TPath.Combine(OutDir, 'Clip - _Form - bridge.png'));
      Assert.AreEqual(F.ClientWidth, Shot.Width, 'the image must be the client width');
      Inside  := CropOf(Shot, Rect(LinkR.Left, LinkR.Top, PanelR.Right, LinkR.Bottom));
      Outside := CropOf(Shot, Rect(PanelR.Right, LinkR.Top, LinkR.Right, LinkR.Bottom));
      InkIn  := InkPercent(Inside);
      InkOut := InkPercent(Outside);
      Assert.IsTrue(InkIn >= MinInkPercent, 'the part of lnkClipped inside pnlClip must be drawn: ink ' + IntToStr(InkIn) + '%. Image: ' + OutDir);
      Assert.IsTrue(InkOut < MinInkPercent, 'lnkClipped must not paint outside pnlClip: ink ' + IntToStr(InkOut) + '% right of the panel. Image: ' + OutDir);
    finally
      FreeAndNil(Outside);
      FreeAndNil(Inside);
      FreeAndNil(Shot);
    end;
  finally
    FreeAndNil(F);
  end;
end;


initialization
  TDUnitX.RegisterTestFixture(TScreenshotNativeTests);

end.
