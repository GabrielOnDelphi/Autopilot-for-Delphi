unit Tests.Bridge.WebBrowser;

{=============================================================================================================
   2026.11.21
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for a TEdgeBrowser on a form (VCL bridge).
   - TCustomEdgeBrowser.Text is a public property whose getter runs 'document.body.innerText' in the page and waits on the main thread until the page answers (c:\Delphi\Delphi 13\source\internet\Vcl.Edge.pas, GetText and ExecuteScript).
   - list_tree must not read it: the node of a browser has no 'text' field.
   - get_text on that one control still reads it.
   - The tests use a stand-in class with the same class name, TCustomEdgeBrowser, whose Text getter counts its calls.
     A real TEdgeBrowser needs the WebView2 runtime and a page, and without a page its Text answers '' at once, so it could not show the read.
     The bridge recognizes the browser by its class name, so the stand-in takes the same route as the real class; Test_IsEdgeBrowserClass_RealVclClass pins that name against Vcl.Edge itself.
=============================================================================================================}

interface

uses
  System.JSON,
  Vcl.Forms,
  DUnitX.TestFramework;

type
  [TestFixture]
  TWebBrowserTests = class
  private
    FPipeName   : String;
    FPipeCounter: Integer;
    FForm       : TForm;
    function CallCommand(const ACmd, AArgsJson: String): TJSONObject;
  public
    [SetupFixture]    procedure SetupFixture;
    [Setup]           procedure Setup;
    [TearDown]        procedure TearDown;
    [TearDownFixture] procedure TearDownFixture;

    [Test] procedure Test_ListTree_EdgeBrowser_DoesNotReadThePageText;
    [Test] procedure Test_ListTree_ClassDerivedFromEdgeBrowser_DoesNotReadThePageText;
    [Test] procedure Test_ListTree_OtherControls_KeepTheirText;
    [Test] procedure Test_GetText_EdgeBrowser_ReadsThePageText;
    [Test] procedure Test_IsEdgeBrowserClass_RealVclClass;
  end;


implementation

uses
  Winapi.Windows,   // GetCurrentProcessId for the pipe name
  System.SysUtils, System.Classes, System.Generics.Collections,
  Vcl.Controls, Vcl.StdCtrls, Vcl.Edge,
  Autopilot.Bridge.Core, Autopilot.Bridge.Vcl,
  Bridge.TestClient, Bridge.Tests;


const
  WebFormName = 'WebBrowserForm';
  PageText    = 'Page text EDGE-7319';

type
  { Stand-in for Vcl.Edge.TCustomEdgeBrowser: the same class name, and a public string Text, as in Vcl.Edge.pas.
    Reads counts how often the bridge called the Text getter. }
  TCustomEdgeBrowser = class(TWinControl)
  private
    function GetText: string;
  public
    Reads: Integer;
    property Text: string read GetText;
  end;

  TFakeEdgeBrowser = class(TCustomEdgeBrowser);

  // One level further down, to show that the bridge walks the whole class chain.
  TFakeEdgeBrowserChild = class(TFakeEdgeBrowser);

  TWebBrowserForm = class(TForm)
  public
    Browser     : TFakeEdgeBrowser;
    ChildBrowser: TFakeEdgeBrowserChild;
    Edit        : TEdit;
    constructor Create(AOwner: TComponent); override;
  end;


function TCustomEdgeBrowser.GetText: string;
begin
  Inc(Reads);
  Result := PageText;
end;


constructor TWebBrowserForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Name    := WebFormName;
  Caption := 'Web browser';
  Browser := TFakeEdgeBrowser.Create(Self);
  Browser.Name   := 'brwPage';
  Browser.Parent := Self;
  ChildBrowser := TFakeEdgeBrowserChild.Create(Self);
  ChildBrowser.Name   := 'brwChild';
  ChildBrowser.Parent := Self;
  Edit := TEdit.Create(Self);
  Edit.Name   := 'edtName';
  Edit.Parent := Self;
  Edit.Text   := 'edit text';
end;


{ Helpers --------------------------------------------------------------- }

// The node of AComponents whose path is APath; fails the test when there is none.
function NodeOfPath(AComponents: TJSONArray; const APath: String): TJSONObject;
var
  i: Integer;
  Node: TJSONObject;
  V: TJSONValue;
begin
  for i := 0 to AComponents.Count - 1 do
    begin
      Node := AComponents.Items[i] as TJSONObject;
      V := Node.GetValue('path');
      if (V is TJSONString) and (TJSONString(V).Value = APath) then EXIT(Node);
    end;
  Assert.Fail('list_tree has no node ' + APath);
  Result := NIL;
end;


// The components array of a successful list_tree answer (owned by ARoot); fails the test otherwise.
function ComponentsOf(ARoot: TJSONObject): TJSONArray;
var
  R: TJSONObject;
begin
  R := GetOkResult(ARoot);
  if R = NIL then
    if ARoot = NIL
    then Assert.Fail('list_tree: no answer')
    else Assert.Fail('list_tree failed: ' + ARoot.ToJSON);
  Result := R.GetValue('components') as TJSONArray;
  Assert.IsNotNull(Result, 'result.components missing');
end;


{ TWebBrowserTests -------------------------------------------------------- }

procedure TWebBrowserTests.SetupFixture;
begin
  FPipeCounter := 0;
  FForm := TWebBrowserForm.Create(NIL);
end;


procedure TWebBrowserTests.Setup;
begin
  Inc(FPipeCounter);
  FPipeName := '\\.\pipe\AutopilotTestWebBrowser.' + IntToStr(GetCurrentProcessId) + '.' + IntToStr(FPipeCounter);
  StartBridgeOnPipe(FPipeName);
  TWebBrowserForm(FForm).Browser.Reads      := 0;
  TWebBrowserForm(FForm).ChildBrowser.Reads := 0;
end;


procedure TWebBrowserTests.TearDown;
begin
  StopBridge;
end;


procedure TWebBrowserTests.TearDownFixture;
begin
  FreeAndNil(FForm);
end;


{ Sends ACmd with the arguments AArgsJson ('' = no arguments) and returns the whole answer (the caller frees it). }
function TWebBrowserTests.CallCommand(const ACmd, AArgsJson: String): TJSONObject;
var
  Root: TJSONObject;
  PipeName, Cmd, ArgsJson: String;
begin
  PipeName := FPipeName;
  Cmd      := ACmd;
  ArgsJson := AArgsJson;
  Root := NIL;
  RunOnWorkerAndPump(
    procedure
    var
      Client: TBridgeTestClient;
      Args: TJSONObject;
    begin
      if ArgsJson = ''
      then Args := NIL
      else Args := TJSONObject.ParseJSONValue(ArgsJson) as TJSONObject;   // Call owns Args from here
      Client := TBridgeTestClient.Create;
      try
        if not Client.ConnectAndHandshake(PipeName, 2000) then
          begin
            FreeAndNil(Args);
            Assert.Fail('connect to ' + PipeName + ' failed');
          end;
        Root := Client.Call(1, Cmd, Args);
      finally
        FreeAndNil(Client);
      end;
    end, 5000);
  Result := Root;
end;


procedure TWebBrowserTests.Test_ListTree_EdgeBrowser_DoesNotReadThePageText;
var
  Root: TJSONObject;
  Node: TJSONObject;
begin
  Root := CallCommand('list_tree', '{"form":"' + WebFormName + '"}');
  try
    Node := NodeOfPath(ComponentsOf(Root), WebFormName + '.brwPage');
    Assert.AreEqual('TFakeEdgeBrowser', Node.GetValue<String>('class'), 'class of the browser node');
    Assert.IsNull(Node.GetValue('text'), 'the browser node must have no text field: ' + Node.ToJSON);
    Assert.AreEqual(0, TWebBrowserForm(FForm).Browser.Reads, 'list_tree called the Text getter of the browser');
  finally
    FreeAndNil(Root);
  end;
end;


procedure TWebBrowserTests.Test_ListTree_ClassDerivedFromEdgeBrowser_DoesNotReadThePageText;
var
  Root: TJSONObject;
  Node: TJSONObject;
begin
  Root := CallCommand('list_tree', '{"form":"' + WebFormName + '"}');
  try
    Node := NodeOfPath(ComponentsOf(Root), WebFormName + '.brwChild');
    Assert.IsNull(Node.GetValue('text'), 'the derived browser node must have no text field: ' + Node.ToJSON);
    Assert.AreEqual(0, TWebBrowserForm(FForm).ChildBrowser.Reads, 'list_tree called the Text getter of the derived browser');
  finally
    FreeAndNil(Root);
  end;
end;


procedure TWebBrowserTests.Test_ListTree_OtherControls_KeepTheirText;
var
  Root: TJSONObject;
  Node: TJSONObject;
begin
  Root := CallCommand('list_tree', '{"form":"' + WebFormName + '"}');
  try
    Node := NodeOfPath(ComponentsOf(Root), WebFormName + '.edtName');
    Assert.AreEqual('edit text', Node.GetValue<String>('text'), 'text of the edit node');
    Node := NodeOfPath(ComponentsOf(Root), WebFormName);
    Assert.AreEqual('Web browser', Node.GetValue<String>('text'), 'text of the form node');
  finally
    FreeAndNil(Root);
  end;
end;


procedure TWebBrowserTests.Test_GetText_EdgeBrowser_ReadsThePageText;
var
  Root, R: TJSONObject;
begin
  Root := CallCommand('get_text', '{"path":"' + WebFormName + '.brwPage"}');
  try
    R := GetOkResult(Root);
    if R = NIL then
      if Root = NIL
      then Assert.Fail('get_text: no answer')
      else Assert.Fail('get_text failed: ' + Root.ToJSON);
    Assert.AreEqual(PageText, R.GetValue<String>('text'), 'get_text of the browser');
    Assert.AreEqual(1, TWebBrowserForm(FForm).Browser.Reads, 'get_text must call the Text getter once');
  finally
    FreeAndNil(Root);
  end;
end;


procedure TWebBrowserTests.Test_IsEdgeBrowserClass_RealVclClass;
begin
  Assert.IsTrue(IsEdgeBrowserClass(Vcl.Edge.TEdgeBrowser), 'Vcl.Edge.TEdgeBrowser');
  Assert.IsTrue(IsEdgeBrowserClass(Vcl.Edge.TCustomEdgeBrowser), 'Vcl.Edge.TCustomEdgeBrowser');
  Assert.IsTrue(IsEdgeBrowserClass(TFakeEdgeBrowserChild), 'a class two levels below the stand-in');
  Assert.IsFalse(IsEdgeBrowserClass(TEdit), 'TEdit');
  Assert.IsFalse(IsEdgeBrowserClass(TWinControl), 'TWinControl');
  Assert.IsFalse(IsEdgeBrowserClass(NIL), 'NIL');
end;


initialization
  TDUnitX.RegisterTestFixture(TWebBrowserTests);

end.
