unit Tests.Bridge.Screenshot;

{=============================================================================================================
   2026.10.12
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for the VCL bridge's screenshot command: the old form capture, the crop to one control
     (args.path), the scale-down to a maximum width (args.maxWidth) and their error cases.
   - One synthetic form built in code (ShotForm), never shown: the bridge captures it with GetFormImage,
     which paints a hidden form too. Panels have fixed colours, so a pixel of the PNG proves which control
     the image shows.
   - Every test talks to the bridge over a real pipe, through TBridgeTestClient.
=============================================================================================================}

interface

uses
  Vcl.Forms,
  DUnitX.TestFramework;

type
  [TestFixture]
  TScreenshotTests = class
  private
    FPipeName   : String;
    FPipeCounter: Integer;
    FForm       : TForm;    // TShotForm; the class is private to the implementation
  public
    [SetupFixture]    procedure SetupFixture;
    [Setup]           procedure Setup;
    [TearDown]        procedure TearDown;
    [TearDownFixture] procedure TearDownFixture;

    [Test] procedure Test_Screenshot_FormOnlyGivesTheOldImage;
    [Test] procedure Test_Screenshot_PathCropsToTheControl;
    [Test] procedure Test_Screenshot_PathIgnoresTheFormArgument;
    [Test] procedure Test_Screenshot_PathPartlyOutsideTheFormIsClipped;
    [Test] procedure Test_Screenshot_MaxWidthScalesDownProportionally;
    [Test] procedure Test_Screenshot_MaxWidthScalesWithASmoothFilter;
    [Test] procedure Test_Screenshot_MaxWidthNotSmallerLeavesTheImageUnchanged;
    [Test] procedure Test_Screenshot_BadPathReturnsNotFound;
    [Test] procedure Test_Screenshot_BadMaxWidthReturnsInvalidRequest;
    [Test] procedure Test_Screenshot_HiddenControlReturnsUnsupported;
    [Test] procedure Test_Screenshot_ZeroSizeControlReturnsUnsupported;
    [Test] procedure Test_Screenshot_NonVisualComponentReturnsUnsupported;
  end;


implementation

uses
  Winapi.Windows,
  System.SysUtils, System.Classes, System.JSON, System.NetEncoding,
  Vcl.Graphics, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Imaging.PngImage,
  Autopilot.Bridge.Core, Autopilot.Bridge.Vcl,
  Bridge.TestClient, Bridge.Tests;


type
  TShotForm = class(TForm)
  public
    PnlRed     : TPanel;      // red, holds the blue PnlBlue
    PnlBlue    : TPanel;
    PnlEdge    : TPanel;      // lime, sticks out over the right and bottom edges of the client area
    PbStripes  : TPaintBox;   // 1-pixel columns, black and white in turn
    PnlHidden  : TPanel;      // Visible = FALSE
    BtnInHidden: TButton;     // visible itself, but on PnlHidden
    PnlZero    : TPanel;      // Width = 0
    CmpData    : TComponent;  // not a control
    constructor Create(AOwner: TComponent); override;
    procedure PbStripesPaint(Sender: TObject);
  end;


// A plain coloured panel: no bevel, no caption, no theme or parent background over its Color.
function MakePanel(AOwner: TComponent; AParent: TWinControl; const AName: String; AColor: TColor; ALeft, ATop, AWidth, AHeight: Integer): TPanel;
begin
  Result := TPanel.Create(AOwner);
  Result.Name             := AName;
  Result.Caption          := '';
  Result.ShowCaption      := FALSE;
  Result.BevelOuter       := bvNone;
  Result.ParentBackground := FALSE;
  Result.StyleElements    := [];
  Result.Color            := AColor;
  Result.SetBounds(ALeft, ATop, AWidth, AHeight);
  Result.Parent           := AParent;
end;


constructor TShotForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Name    := 'ShotForm';
  Caption := 'Screenshot fixture';
  Scaled  := FALSE;
  Color   := clWhite;
  ClientWidth  := 300;
  ClientHeight := 200;

  PnlRed  := MakePanel(Self, Self,   'pnlRed',  clRed,  30, 20, 100, 60);
  PnlBlue := MakePanel(Self, PnlRed, 'pnlBlue', clBlue, 10, 10,  20, 20);
  PnlEdge := MakePanel(Self, Self,   'pnlEdge', clLime, ClientWidth - 40, ClientHeight - 50, 100, 100);

  PbStripes := TPaintBox.Create(Self);
  PbStripes.Name := 'pbStripes';
  PbStripes.SetBounds(30, 120, 40, 20);
  PbStripes.OnPaint := PbStripesPaint;
  PbStripes.Parent := Self;

  PnlHidden := MakePanel(Self, Self, 'pnlHidden', clYellow, 160, 20, 50, 50);
  PnlHidden.Visible := FALSE;
  BtnInHidden := TButton.Create(Self);
  BtnInHidden.Name := 'btnInHidden';
  BtnInHidden.SetBounds(5, 5, 30, 20);
  BtnInHidden.Parent := PnlHidden;

  PnlZero := MakePanel(Self, Self, 'pnlZero', clFuchsia, 160, 120, 0, 30);

  CmpData := TComponent.Create(Self);
  CmpData.Name := 'cmpData';
end;


procedure TShotForm.PbStripesPaint(Sender: TObject);
var
  X: Integer;
begin
  for X := 0 to PbStripes.Width - 1 do
  begin
    if Odd(X)
    then PbStripes.Canvas.Brush.Color := clWhite
    else PbStripes.Canvas.Brush.Color := clBlack;
    PbStripes.Canvas.FillRect(Rect(X, 0, X + 1, PbStripes.Height));
  end;
end;


{ Helpers --------------------------------------------------------------- }

// One screenshot round trip on a worker thread while this thread pumps the bridge's queue. The caller frees the result (NIL when no frame came back).
function Shoot(const APipeName: String; AArgs: TJSONObject): TJSONObject;
var
  Root: TJSONObject;
  PipeName: String;
  Args: TJSONObject;
begin
  Root     := NIL;
  PipeName := APipeName;
  Args     := AArgs;
  RunOnWorkerAndPump(
    procedure
    var Client: TBridgeTestClient;
    begin
      Client := TBridgeTestClient.Create;
      try
        if not Client.ConnectAndHandshake(PipeName, 2000) then
        begin
          FreeAndNil(Args);   // Call owns Args only once it runs
          Assert.Fail('connect to ' + PipeName + ' failed');
        end;
        Root := Client.Call(1, 'screenshot', Args);
      finally
        FreeAndNil(Client);
      end;
    end, 10000);
  Result := Root;
end;


function ShotArgs(const AForm, APath: String): TJSONObject;
begin
  Result := TJSONObject.Create;
  if AForm <> '' then Result.AddPair('form', AForm);
  if APath <> '' then Result.AddPair('path', APath);
end;


function ShotArgsMax(const AForm, APath: String; AMaxWidth: Integer): TJSONObject;
begin
  Result := ShotArgs(AForm, APath);
  Result.AddPair('maxWidth', TJSONNumber.Create(AMaxWidth));
end;


function ErrorMessageOf(ARoot: TJSONObject): String;
var
  V: TJSONValue;
begin
  Result := '';
  if ARoot = NIL then EXIT('(no response)');
  V := ARoot.GetValue('error');
  if V is TJSONObject then
  begin
    V := TJSONObject(V).GetValue('message');
    if V is TJSONString then
      Result := TJSONString(V).Value;
  end;
end;


function StringField(AObj: TJSONObject; const AName: String): String;
var
  V: TJSONValue;
begin
  Result := '';
  if AObj = NIL then EXIT;
  V := AObj.GetValue(AName);
  if V is TJSONString then
    Result := TJSONString(V).Value;
end;


// -1 when the field is missing or not a number.
function IntField(AObj: TJSONObject; const AName: String): Integer;
var
  V: TJSONValue;
begin
  Result := -1;
  if AObj = NIL then EXIT;
  V := AObj.GetValue(AName);
  if V is TJSONNumber then
    Result := TJSONNumber(V).AsInt;
end;


// Fails the test when the field is missing or not a Boolean.
function BoolField(AObj: TJSONObject; const AName: String): Boolean;
var
  V: TJSONValue;
begin
  V := AObj.GetValue(AName);
  Assert.IsTrue(V is TJSONBool, 'result.' + AName + ' missing or not a Boolean: ' + AObj.ToJSON);
  Result := TJSONBool(V).AsBoolean;
end;


// The PNG in result.image. The caller frees it.
function ImageOf(AResult: TJSONObject): TPngImage;
var
  B64: String;
  Stream: TBytesStream;
begin
  B64 := StringField(AResult, 'image');
  Assert.IsTrue(B64 <> '', 'result.image missing');
  B64 := StringReplace(StringReplace(B64, #13, '', [rfReplaceAll]), #10, '', [rfReplaceAll]);
  Stream := TBytesStream.Create(TNetEncoding.Base64.DecodeStringToBytes(B64));
  try
    Result := TPngImage.Create;
    try
      Result.LoadFromStream(Stream);
    except
      FreeAndNil(Result);
      raise;
    end;
  finally
    FreeAndNil(Stream);
  end;
end;


// The capture as the bridge made it before path and maxWidth existed: GetFormImage, PNG, base64.
function OldFormImageBase64(AForm: TForm): String;
var
  Bmp: TBitmap;
  Png: TPngImage;
  Stream: TMemoryStream;
begin
  Bmp := AForm.GetFormImage;
  try
    Png := TPngImage.Create;
    try
      Png.Assign(Bmp);
      Stream := TMemoryStream.Create;
      try
        Png.SaveToStream(Stream);
        Result := TNetEncoding.Base64.EncodeBytesToString(Stream.Memory, Stream.Size);
      finally
        FreeAndNil(Stream);
      end;
    finally
      FreeAndNil(Png);
    end;
  finally
    FreeAndNil(Bmp);
  end;
end;


function ColorText(AColor: TColor): String;
begin
  Result := 'R' + IntToStr(GetRValue(AColor)) + ' G' + IntToStr(GetGValue(AColor)) + ' B' + IntToStr(GetBValue(AColor));
end;


procedure AssertPixel(APng: TPngImage; X, Y: Integer; AExpected: TColor; const AWhat: String);
begin
  Assert.AreEqual(ColorText(ColorToRGB(AExpected)), ColorText(APng.Pixels[X, Y]), AWhat + ' at (' + IntToStr(X) + ',' + IntToStr(Y) + ')');
end;


{ TScreenshotTests ------------------------------------------------------- }

procedure TScreenshotTests.SetupFixture;
begin
  FPipeCounter := 0;
  FForm := TShotForm.Create(NIL);
end;


procedure TScreenshotTests.Setup;
begin
  Inc(FPipeCounter);
  FPipeName := '\\.\pipe\AutopilotTestShot.' + IntToStr(GetCurrentProcessId) + '.' + IntToStr(FPipeCounter);
  StartBridgeOnPipe(FPipeName);
end;


procedure TScreenshotTests.TearDown;
begin
  StopBridge;
end;


procedure TScreenshotTests.TearDownFixture;
begin
  FreeAndNil(FForm);
end;


// The call every old MCP server sends: only the form. The PNG must be the one the old bridge made, byte for byte.
procedure TScreenshotTests.Test_Screenshot_FormOnlyGivesTheOldImage;
var
  Root, R: TJSONObject;
  Png: TPngImage;
  Shot: TShotForm;
begin
  Shot := TShotForm(FForm);
  Root := Shoot(FPipeName, ShotArgs('ShotForm', ''));
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'screenshot of the form must succeed: ' + ErrorMessageOf(Root));
    Assert.AreEqual('ShotForm', StringField(R, 'form'), 'form');
    Assert.AreEqual(Shot.ClientWidth,  IntField(R, 'width'),  'width must be the client width');
    Assert.AreEqual(Shot.ClientHeight, IntField(R, 'height'), 'height must be the client height');
    Assert.IsFalse(BoolField(R, 'scaled'), 'a capture without maxWidth is never scaled');
    Assert.IsNull(R.GetValue('path'), 'no path was asked, so the answer must not carry one');
    Assert.AreEqual(OldFormImageBase64(Shot), StringField(R, 'image'), 'the PNG must be the old GetFormImage capture, byte for byte');

    Png := ImageOf(R);
    try
      Assert.AreEqual(Shot.ClientWidth,  Png.Width,  'PNG width');
      Assert.AreEqual(Shot.ClientHeight, Png.Height, 'PNG height');
      AssertPixel(Png, 5, 5, clWhite, 'the form background');
      AssertPixel(Png, Shot.PnlRed.Left + Shot.PnlRed.Width div 2, Shot.PnlRed.Top + Shot.PnlRed.Height - 3, clRed, 'pnlRed on the form');
    finally
      FreeAndNil(Png);
    end;
  finally
    FreeAndNil(Root);
  end;
end;


// Only the control's rectangle, children included: the image is pnlRed's size, red to its corners, with pnlBlue at its own offset.
procedure TScreenshotTests.Test_Screenshot_PathCropsToTheControl;
var
  Root, R: TJSONObject;
  Png: TPngImage;
  Shot: TShotForm;
  W, H: Integer;
begin
  Shot := TShotForm(FForm);
  W := Shot.PnlRed.Width;
  H := Shot.PnlRed.Height;
  Root := Shoot(FPipeName, ShotArgs('', 'ShotForm.pnlRed'));
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'screenshot of a control must succeed: ' + ErrorMessageOf(Root));
    Assert.AreEqual('ShotForm', StringField(R, 'form'), 'form must name the form that shows the control');
    Assert.AreEqual('ShotForm.pnlRed', StringField(R, 'path'), 'path must echo the control path');
    Assert.AreEqual(W, IntField(R, 'width'),  'width must be the control width');
    Assert.AreEqual(H, IntField(R, 'height'), 'height must be the control height');
    Assert.IsFalse(BoolField(R, 'scaled'), 'a crop without maxWidth is not scaled');

    Png := ImageOf(R);
    try
      Assert.AreEqual(W, Png.Width,  'PNG width');
      Assert.AreEqual(H, Png.Height, 'PNG height');
      AssertPixel(Png, 0, 0, clRed, 'top-left corner of pnlRed');
      AssertPixel(Png, W - 1, H - 1, clRed, 'bottom-right corner of pnlRed');
      AssertPixel(Png, Shot.PnlBlue.Left + Shot.PnlBlue.Width div 2, Shot.PnlBlue.Top + Shot.PnlBlue.Height div 2, clBlue, 'the child pnlBlue');
    finally
      FreeAndNil(Png);
    end;
  finally
    FreeAndNil(Root);
  end;
end;


// The path names its form; a form argument next to it is ignored, even one that does not exist.
procedure TScreenshotTests.Test_Screenshot_PathIgnoresTheFormArgument;
var
  Root, R: TJSONObject;
begin
  Root := Shoot(FPipeName, ShotArgs('NoSuchForm', 'ShotForm.pnlRed'));
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'with a path the form argument must be ignored: ' + ErrorMessageOf(Root));
    Assert.AreEqual(TShotForm(FForm).PnlRed.Width, IntField(R, 'width'), 'the image must be the control, not a form');
  finally
    FreeAndNil(Root);
  end;
end;


// pnlEdge is 100 x 100 but only its top-left part lies inside the client area.
procedure TScreenshotTests.Test_Screenshot_PathPartlyOutsideTheFormIsClipped;
var
  Root, R: TJSONObject;
  Png: TPngImage;
  Shot: TShotForm;
  W, H: Integer;
begin
  Shot := TShotForm(FForm);
  W := Shot.ClientWidth  - Shot.PnlEdge.Left;
  H := Shot.ClientHeight - Shot.PnlEdge.Top;
  Assert.IsTrue((W < Shot.PnlEdge.Width) and (H < Shot.PnlEdge.Height), 'fixture: pnlEdge must stick out of the client area');
  Root := Shoot(FPipeName, ShotArgs('', 'ShotForm.pnlEdge'));
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'screenshot of a partly visible control must succeed: ' + ErrorMessageOf(Root));
    Assert.AreEqual(W, IntField(R, 'width'),  'width must be clipped to the client area');
    Assert.AreEqual(H, IntField(R, 'height'), 'height must be clipped to the client area');
    Png := ImageOf(R);
    try
      AssertPixel(Png, 0, 0, clLime, 'top-left corner of pnlEdge');
      AssertPixel(Png, W - 1, H - 1, clLime, 'the last visible pixel of pnlEdge');
    finally
      FreeAndNil(Png);
    end;
  finally
    FreeAndNil(Root);
  end;
end;


procedure TScreenshotTests.Test_Screenshot_MaxWidthScalesDownProportionally;
var
  Root, R: TJSONObject;
  Png: TPngImage;
  Shot: TShotForm;
begin
  Shot := TShotForm(FForm);
  Assert.AreEqual(100, Shot.PnlRed.Width,  'fixture: pnlRed width');
  Assert.AreEqual(60,  Shot.PnlRed.Height, 'fixture: pnlRed height');

  // A control: 100 x 60 down to 50 wide = 50 x 30.
  Root := Shoot(FPipeName, ShotArgsMax('', 'ShotForm.pnlRed', 50));
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'screenshot with maxWidth must succeed: ' + ErrorMessageOf(Root));
    Assert.AreEqual(50, IntField(R, 'width'),  'width must be exactly maxWidth');
    Assert.AreEqual(30, IntField(R, 'height'), 'height must keep the aspect ratio');
    Assert.IsTrue(BoolField(R, 'scaled'), 'scaled must be TRUE');
    Png := ImageOf(R);
    try
      Assert.AreEqual(50, Png.Width,  'PNG width');
      Assert.AreEqual(30, Png.Height, 'PNG height');
      AssertPixel(Png, 45, 25, clRed, 'pnlRed, away from pnlBlue');
    finally
      FreeAndNil(Png);
    end;
  finally
    FreeAndNil(Root);
  end;

  // The whole form: 300 x 200 down to 150 wide = 150 x 100.
  Assert.AreEqual(300, Shot.ClientWidth,  'fixture: client width');
  Assert.AreEqual(200, Shot.ClientHeight, 'fixture: client height');
  Root := Shoot(FPipeName, ShotArgsMax('ShotForm', '', 150));
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'form screenshot with maxWidth must succeed: ' + ErrorMessageOf(Root));
    Assert.AreEqual(150, IntField(R, 'width'),  'form width must be exactly maxWidth');
    Assert.AreEqual(100, IntField(R, 'height'), 'form height must keep the aspect ratio');
    Assert.IsTrue(BoolField(R, 'scaled'), 'scaled must be TRUE for the form');
  finally
    FreeAndNil(Root);
  end;
end;


// 1-pixel black and white columns halved in width: a smoothing filter mixes each pair to grey; nearest-neighbour keeps pure black or white.
procedure TScreenshotTests.Test_Screenshot_MaxWidthScalesWithASmoothFilter;
var
  Root, R: TJSONObject;
  Png: TPngImage;
  C: TColor;
  X: Integer;
begin
  Root := Shoot(FPipeName, ShotArgsMax('', 'ShotForm.pbStripes', TShotForm(FForm).PbStripes.Width div 2));
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'screenshot of the stripes must succeed: ' + ErrorMessageOf(Root));
    Assert.IsTrue(BoolField(R, 'scaled'), 'the stripes must be scaled');
    Png := ImageOf(R);
    try
      for X := 2 to Png.Width - 3 do
      begin
        C := Png.Pixels[X, Png.Height div 2];
        Assert.IsTrue((GetRValue(C) in [64..192]) and (GetGValue(C) in [64..192]) and (GetBValue(C) in [64..192]),
                      'pixel ' + IntToStr(X) + ' must be grey (64..192), got ' + ColorText(C) + ': the scale-down is not smooth');
      end;
    finally
      FreeAndNil(Png);
    end;
  finally
    FreeAndNil(Root);
  end;
end;


// maxWidth equal to or wider than the image: the image is never scaled up, and it stays byte for byte the same.
procedure TScreenshotTests.Test_Screenshot_MaxWidthNotSmallerLeavesTheImageUnchanged;
var
  Root, R: TJSONObject;
  Plain: String;
  W, H: Integer;
begin
  W := TShotForm(FForm).PnlRed.Width;
  H := TShotForm(FForm).PnlRed.Height;
  Root := Shoot(FPipeName, ShotArgs('', 'ShotForm.pnlRed'));
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'plain crop must succeed: ' + ErrorMessageOf(Root));
    Plain := StringField(R, 'image');
  finally
    FreeAndNil(Root);
  end;
  Assert.IsTrue(Plain <> '', 'plain crop: image missing');

  Root := Shoot(FPipeName, ShotArgsMax('', 'ShotForm.pnlRed', W));
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'maxWidth = width must succeed: ' + ErrorMessageOf(Root));
    Assert.AreEqual(W, IntField(R, 'width'),  'maxWidth = width: width');
    Assert.AreEqual(H, IntField(R, 'height'), 'maxWidth = width: height');
    Assert.IsFalse(BoolField(R, 'scaled'), 'maxWidth = width: not scaled');
    Assert.AreEqual(Plain, StringField(R, 'image'), 'maxWidth = width: the image must not change');
  finally
    FreeAndNil(Root);
  end;

  Root := Shoot(FPipeName, ShotArgsMax('', 'ShotForm.pnlRed', 5000));
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'a wide maxWidth must succeed: ' + ErrorMessageOf(Root));
    Assert.AreEqual(W, IntField(R, 'width'),  'wide maxWidth: never scaled up');
    Assert.AreEqual(H, IntField(R, 'height'), 'wide maxWidth: height');
    Assert.IsFalse(BoolField(R, 'scaled'), 'wide maxWidth: not scaled');
    Assert.AreEqual(Plain, StringField(R, 'image'), 'wide maxWidth: the image must not change');
  finally
    FreeAndNil(Root);
  end;

  Root := Shoot(FPipeName, ShotArgsMax('', 'ShotForm.pnlRed', 0));
  try
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'maxWidth 0 must succeed: ' + ErrorMessageOf(Root));
    Assert.IsFalse(BoolField(R, 'scaled'), 'maxWidth 0 means no scaling');
    Assert.AreEqual(Plain, StringField(R, 'image'), 'maxWidth 0: the image must not change');
  finally
    FreeAndNil(Root);
  end;
end;


procedure TScreenshotTests.Test_Screenshot_BadPathReturnsNotFound;
var
  Root: TJSONObject;
begin
  Root := Shoot(FPipeName, ShotArgs('', 'ShotForm.noSuchControl'));
  try
    Assert.AreEqual(ErrNotFound, GetErrorCode(Root), 'a path that matches nothing must be -32001: ' + ErrorMessageOf(Root));
  finally
    FreeAndNil(Root);
  end;
end;


procedure TScreenshotTests.Test_Screenshot_BadMaxWidthReturnsInvalidRequest;
var
  Root, Args: TJSONObject;
begin
  Root := Shoot(FPipeName, ShotArgsMax('ShotForm', '', -1));
  try
    Assert.AreEqual(ErrInvalidRequest, GetErrorCode(Root), 'a negative maxWidth must be -32600: ' + ErrorMessageOf(Root));
  finally
    FreeAndNil(Root);
  end;

  Args := ShotArgs('ShotForm', '');
  Args.AddPair('maxWidth', TJSONNumber.Create(12.5));
  Root := Shoot(FPipeName, Args);
  try
    Assert.AreEqual(ErrInvalidRequest, GetErrorCode(Root), 'a fractional maxWidth must be -32600: ' + ErrorMessageOf(Root));
  finally
    FreeAndNil(Root);
  end;

  Args := ShotArgs('ShotForm', '');
  Args.AddPair('maxWidth', 'wide');
  Root := Shoot(FPipeName, Args);
  try
    Assert.AreEqual(ErrInvalidRequest, GetErrorCode(Root), 'a maxWidth that is not a number must be -32600: ' + ErrorMessageOf(Root));
  finally
    FreeAndNil(Root);
  end;
end;


// PaintTo skips a control that is not visible, so its pixels are not in the form image: the crop must refuse it.
procedure TScreenshotTests.Test_Screenshot_HiddenControlReturnsUnsupported;
var
  Root: TJSONObject;
begin
  Root := Shoot(FPipeName, ShotArgs('', 'ShotForm.pnlHidden'));
  try
    Assert.AreEqual(ErrUnsupportedAction, GetErrorCode(Root), 'a hidden control must be -32005: ' + ErrorMessageOf(Root));
  finally
    FreeAndNil(Root);
  end;

  Root := Shoot(FPipeName, ShotArgs('', 'ShotForm.btnInHidden'));
  try
    Assert.AreEqual(ErrUnsupportedAction, GetErrorCode(Root), 'a control on a hidden panel must be -32005: ' + ErrorMessageOf(Root));
  finally
    FreeAndNil(Root);
  end;
end;


procedure TScreenshotTests.Test_Screenshot_ZeroSizeControlReturnsUnsupported;
var
  Root: TJSONObject;
begin
  Assert.AreEqual(0, TShotForm(FForm).PnlZero.Width, 'fixture: pnlZero width');
  Root := Shoot(FPipeName, ShotArgs('', 'ShotForm.pnlZero'));
  try
    Assert.AreEqual(ErrUnsupportedAction, GetErrorCode(Root), 'a control of zero width must be -32005: ' + ErrorMessageOf(Root));
  finally
    FreeAndNil(Root);
  end;
end;


procedure TScreenshotTests.Test_Screenshot_NonVisualComponentReturnsUnsupported;
var
  Root: TJSONObject;
begin
  Root := Shoot(FPipeName, ShotArgs('', 'ShotForm.cmpData'));
  try
    Assert.AreEqual(ErrUnsupportedAction, GetErrorCode(Root), 'a component that is not a control must be -32005: ' + ErrorMessageOf(Root));
  finally
    FreeAndNil(Root);
  end;
end;


initialization
  TDUnitX.RegisterTestFixture(TScreenshotTests);

end.
