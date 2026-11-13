unit Tests.Bridge.DBGrid;

{=============================================================================================================
   2026.11.13
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for get_text on a VCL DB grid (GitHub issue 5): a TDBGrid has no Text/Caption, so get_text answers
     the column titles and the records in the grid's buffer, plus rows and currentRow.
   - The bridge reaches the grid purely through RTTI (it links neither Data.DB nor Vcl.DBGrids), so these tests use
     the real classes: a TDBGrid over a TClientDataSet. MidasLib links the dataset engine into the exe, so the run
     needs no midas.dll.
   - What they pin down: the text format, that a read moves no cursor and leaves an edit alone, that the data link
     is taken from the field TCustomDBGrid itself declares, and that no EInvalidCast is raised on the way.
   - Win32 only (TRaiseCounter reads the Delphi exception record), like Tests.Bridge.PropertyTypes.
=============================================================================================================}

interface

uses
  Vcl.Forms,
  DUnitX.TestFramework;

type
  [TestFixture]
  TDBGridTests = class
  private
    FPipeName   : String;
    FPipeCounter: Integer;
    FForm       : TForm;    // TDBGridForm; the class is private to the implementation
  public
    [SetupFixture]    procedure SetupFixture;
    [Setup]           procedure Setup;
    [TearDown]        procedure TearDown;
    [TearDownFixture] procedure TearDownFixture;

    [Test] procedure Test_GetText_TitlesAndRows;
    [Test] procedure Test_GetText_CurrentRowFollowsTheCursor;
    [Test] procedure Test_GetText_MovesNoCursorAndKeepsAnEdit;
    [Test] procedure Test_GetText_ClosedDataSetGivesTitlesOnly;
    [Test] procedure Test_GetText_MoreRecordsThanRows;
    [Test] procedure Test_GetText_DescendantWithItsOwnFDataLink;
    [Test] procedure Test_GetText_RaisingOnGetTextCostsOneCell;
    [Test] procedure Test_ListTree_GridNodeHasNoText;
  end;


implementation

uses
  Winapi.Windows,   // GetCurrentProcessId for the pipe name
  System.SysUtils, System.Classes, System.JSON, System.Generics.Collections,
  Vcl.Controls, Vcl.Grids, Vcl.DBGrids,
  Data.DB, Datasnap.DBClient, MidasLib,
  Autopilot.Bridge.Core, Autopilot.Bridge.Vcl,
  Bridge.TestClient, Bridge.Tests, Tests.RaiseCounter;


type
  { A descendant that declares an FDataLink of its own, holding no TDataLink.
    TRttiType.GetField on the instance's type would find this one first. }
  TShadowLinkGrid = class(TDBGrid)
  private
    FDataLink: TObject;
  public
    constructor Create(AOwner: TComponent); override;
    property ShadowLink: TObject read FDataLink;
  end;

  TDBGridForm = class(TForm)
  private
    procedure DataAfterScroll(DataSet: TDataSet);
    procedure NameGetTextRaises(Sender: TField; var Text: String; DisplayText: Boolean);
  public
    Data: TClientDataSet;
    Source: TDataSource;
    Grid: TDBGrid;
    ShadowGrid: TShadowLinkGrid;
    ScrollCount: Integer;
    constructor Create(AOwner: TComponent); override;
    procedure Fill(ACount: Integer);
  end;


const
  GridPath       = 'DBGridForm.grdData';
  ShadowGridPath = 'DBGridForm.grdShadow';
  RaiseOnRecord  = 2;   // NameGetTextRaises raises for the record with this ID


{ TShadowLinkGrid }

constructor TShadowLinkGrid.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FDataLink := Self;   // an object that is no TDataLink
end;


{ TDBGridForm }

constructor TDBGridForm.Create(AOwner: TComponent);

  procedure AddColumns(AGrid: TDBGrid);
  var
    Col: TColumn;
  begin
    Col := AGrid.Columns.Add;
    Col.FieldName     := 'ID';
    Col.Title.Caption := 'Number';
    Col := AGrid.Columns.Add;
    Col.FieldName     := 'Name';
    Col.Title.Caption := 'Name';
    Col := AGrid.Columns.Add;
    Col.FieldName     := 'Note';
    Col.Title.Caption := 'Hidden note';
    Col.Visible       := FALSE;
  end;

begin
  inherited CreateNew(AOwner);
  Name    := 'DBGridForm';
  Caption := 'DB grid';
  SetBounds(0, 0, 500, 500);

  Data := TClientDataSet.Create(Self);
  Data.Name := 'cdsData';
  Data.FieldDefs.Add('ID',   ftInteger);
  Data.FieldDefs.Add('Name', ftString, 50);
  Data.FieldDefs.Add('Note', ftString, 20);
  Data.CreateDataSet;
  Data.AfterScroll := DataAfterScroll;

  Source := TDataSource.Create(Self);
  Source.Name    := 'dsData';
  Source.DataSet := Data;

  Grid := TDBGrid.Create(Self);
  Grid.Name   := 'grdData';
  Grid.Parent := Self;
  Grid.SetBounds(0, 0, 400, 200);
  AddColumns(Grid);
  Grid.DataSource := Source;
  Grid.HandleNeeded;   // the grid sizes its record buffer from its row count

  ShadowGrid := TShadowLinkGrid.Create(Self);
  ShadowGrid.Name   := 'grdShadow';
  ShadowGrid.Parent := Self;
  ShadowGrid.SetBounds(0, 210, 400, 200);
  AddColumns(ShadowGrid);
  ShadowGrid.DataSource := Source;
  ShadowGrid.HandleNeeded;
end;


procedure TDBGridForm.DataAfterScroll(DataSet: TDataSet);
begin
  Inc(ScrollCount);
end;


procedure TDBGridForm.NameGetTextRaises(Sender: TField; var Text: String; DisplayText: Boolean);
begin
  if Sender.DataSet.FieldByName('ID').AsInteger = RaiseOnRecord
  then raise EProgrammerNotFound.Create('OnGetText failed');
  Text := Sender.AsString;
end;


// Refills the dataset with ACount records (ID 1..ACount) and puts the cursor on the first one.
procedure TDBGridForm.Fill(ACount: Integer);
var
  i: Integer;
begin
  if not Data.Active
  then Data.Open;
  Data.Cancel;
  Data.FieldByName('Name').OnGetText := NIL;
  Data.EmptyDataSet;
  for i := 1 to ACount do
    Data.AppendRecord([i, 'Name ' + IntToStr(i), 'note ' + IntToStr(i)]);
  Data.First;
  ScrollCount := 0;
end;


{ Helpers --------------------------------------------------------------- }

// Sends ACmd (with args.path = APath when APath is not empty) and counts the EInvalidCast raises of the whole process while the bridge runs it.
// The caller frees the result; NIL when the connection failed.
function CallCountingCasts(const APipeName, ACmd, APath: String; OUT ACastCount: Integer): TJSONObject;
var
  Root: TJSONObject;
  PipeName, Cmd, Path: String;
begin
  PipeName := APipeName;
  Cmd      := ACmd;
  Path     := APath;
  Root     := NIL;
  TRaiseCounter.Install(EInvalidCast);
  try
    RunOnWorkerAndPump(
      procedure
      var
        Client: TBridgeTestClient;
        Args: TJSONObject;
      begin
        Client := TBridgeTestClient.Create;
        try
          if Client.ConnectAndHandshake(PipeName, 2000) then
          begin
            Args := NIL;
            if Path <> '' then
            begin
              Args := TJSONObject.Create;
              Args.AddPair('path', Path);
            end;
            Root := Client.Call(1, Cmd, Args);   // Call owns Args
          end;
        finally
          FreeAndNil(Client);
        end;
      end, 5000);
    ACastCount := TRaiseCounter.Count;
  finally
    TRaiseCounter.Uninstall;
  end;
  Result := Root;
end;


// get_text on APath: the text, rows and currentRow of an ok answer. FALSE (AErrCode set) for an error answer.
function GetGridText(const APipeName, APath: String; OUT AText: String; OUT ARows, ACurrentRow, AErrCode, ACastCount: Integer): Boolean;
var
  Root, R: TJSONObject;
  V: TJSONValue;
begin
  AText := '';
  ARows := -99;
  ACurrentRow := -99;
  AErrCode := 0;
  Root := CallCountingCasts(APipeName, 'get_text', APath, ACastCount);
  try
    Assert.IsNotNull(Root, 'no answer from the bridge');
    R := GetOkResult(Root);
    Result := R <> NIL;
    if not Result then
    begin
      AErrCode := GetErrorCode(Root);
      exit;
    end;
    V := R.GetValue('text');
    Assert.IsTrue(V is TJSONString, 'result.text is not a string');
    AText := TJSONString(V).Value;
    V := R.GetValue('rows');
    if V is TJSONNumber
    then ARows := TJSONNumber(V).AsInt;
    V := R.GetValue('currentRow');
    if V is TJSONNumber
    then ACurrentRow := TJSONNumber(V).AsInt;
  finally
    Root.Free;
  end;
end;


{ TDBGridTests ------------------------------------------------------------ }

procedure TDBGridTests.SetupFixture;
begin
  FPipeCounter := 0;
  FForm := TDBGridForm.Create(NIL);
end;


procedure TDBGridTests.Setup;
begin
  Inc(FPipeCounter);
  FPipeName := '\\.\pipe\AutopilotTestDG.' + IntToStr(GetCurrentProcessId) + '.' + IntToStr(FPipeCounter);
  TDBGridForm(FForm).Fill(3);
  StartBridgeOnPipe(FPipeName);
end;


procedure TDBGridTests.TearDown;
begin
  StopBridge;
end;


procedure TDBGridTests.TearDownFixture;
begin
  FreeAndNil(FForm);
end;


// Titles first, the hidden column left out, a Tab and a line break inside a cell read as a space.
procedure TDBGridTests.Test_GetText_TitlesAndRows;
var
  Form: TDBGridForm;
  Text: String;
  Rows, CurrentRow, ErrCode, Casts: Integer;
begin
  Form := TDBGridForm(FForm);
  Form.Data.Next;
  Form.Data.Edit;
  Form.Data.FieldByName('Name').AsString := 'two'#9'tabs'#13#10'lines';
  Form.Data.Post;
  Form.Data.First;

  Assert.IsTrue(GetGridText(FPipeName, GridPath, Text, Rows, CurrentRow, ErrCode, Casts), 'get_text on a TDBGrid failed: ' + IntToStr(ErrCode));
  Assert.AreEqual('Number'#9'Name'#10 +
                  '1'#9'Name 1'#10 +
                  '2'#9'two tabs lines'#10 +
                  '3'#9'Name 3', Text, 'grid text');
  Assert.AreEqual(3, Rows, 'rows');
  Assert.AreEqual(0, CurrentRow, 'currentRow');
  Assert.AreEqual(0, Casts, 'EInvalidCast raised while the grid was read');
end;


procedure TDBGridTests.Test_GetText_CurrentRowFollowsTheCursor;
var
  Form: TDBGridForm;
  Text: String;
  Rows, CurrentRow, ErrCode, Casts: Integer;
begin
  Form := TDBGridForm(FForm);
  Form.Data.Last;
  Assert.IsTrue(GetGridText(FPipeName, GridPath, Text, Rows, CurrentRow, ErrCode, Casts), 'get_text failed: ' + IntToStr(ErrCode));
  Assert.AreEqual(3, Rows, 'rows');
  Assert.AreEqual(2, CurrentRow, 'currentRow with the cursor on the last record');
end;


// A read must not scroll, post or cancel: the record under edit keeps its unposted value and the dataset stays in dsEdit.
procedure TDBGridTests.Test_GetText_MovesNoCursorAndKeepsAnEdit;
var
  Form: TDBGridForm;
  Text: String;
  Rows, CurrentRow, ErrCode, Casts: Integer;
begin
  Form := TDBGridForm(FForm);
  Form.Data.Next;
  Form.Data.Edit;
  Form.Data.FieldByName('Name').AsString := 'unposted';
  Form.ScrollCount := 0;

  Assert.IsTrue(GetGridText(FPipeName, GridPath, Text, Rows, CurrentRow, ErrCode, Casts), 'get_text failed: ' + IntToStr(ErrCode));
  Assert.AreEqual(1, CurrentRow, 'currentRow');
  Assert.AreEqual('Number'#9'Name'#10'1'#9'Name 1'#10'2'#9'unposted'#10'3'#9'Name 3', Text, 'the row under edit shows what the grid shows');

  Assert.AreEqual(0, Form.ScrollCount, 'AfterScroll fired during the read');
  Assert.IsTrue(Form.Data.State = dsEdit, 'the dataset left dsEdit');
  Assert.AreEqual(2, Form.Data.FieldByName('ID').AsInteger, 'the cursor moved');
  Assert.AreEqual('unposted', Form.Data.FieldByName('Name').AsString, 'the unposted value was lost');
  Form.Data.Cancel;
end;


procedure TDBGridTests.Test_GetText_ClosedDataSetGivesTitlesOnly;
var
  Form: TDBGridForm;
  Text: String;
  Rows, CurrentRow, ErrCode, Casts: Integer;
begin
  Form := TDBGridForm(FForm);
  Form.Data.Close;
  Assert.IsTrue(GetGridText(FPipeName, GridPath, Text, Rows, CurrentRow, ErrCode, Casts), 'get_text failed: ' + IntToStr(ErrCode));
  Assert.AreEqual('Number'#9'Name', Text, 'grid text');
  Assert.AreEqual(0, Rows, 'rows');
  Assert.AreEqual(-1, CurrentRow, 'currentRow');
  Assert.AreEqual(0, Casts, 'EInvalidCast raised while the grid was read');
end;


// Only the records in the grid's buffer are read: nothing is fetched or scrolled to reach the rest.
procedure TDBGridTests.Test_GetText_MoreRecordsThanRows;
const
  RecordCount = 200;
var
  Form: TDBGridForm;
  Text: String;
  Lines: TArray<String>;
  Rows, CurrentRow, ErrCode, Casts: Integer;
begin
  Form := TDBGridForm(FForm);
  Form.Fill(RecordCount);
  Assert.IsTrue(GetGridText(FPipeName, GridPath, Text, Rows, CurrentRow, ErrCode, Casts), 'get_text failed: ' + IntToStr(ErrCode));
  Assert.IsTrue((Rows > 1) and (Rows < RecordCount), 'rows should be the visible row count, got ' + IntToStr(Rows));
  Lines := Text.Split([#10]);
  Assert.AreEqual(Rows + 1, Integer(Length(Lines)), 'one line per row plus the titles');
  Assert.AreEqual('1'#9'Name 1', Lines[1], 'first row');
  Assert.AreEqual(IntToStr(Rows) + #9'Name ' + IntToStr(Rows), Lines[Rows], 'last row');
  Assert.AreEqual(0, Form.ScrollCount, 'AfterScroll fired during the read');
  Assert.AreEqual(1, Form.Data.FieldByName('ID').AsInteger, 'the cursor moved');
end;


// The link comes from the field TCustomDBGrid declares, not from a same-named field of a descendant.
procedure TDBGridTests.Test_GetText_DescendantWithItsOwnFDataLink;
var
  Form: TDBGridForm;
  Text: String;
  Rows, CurrentRow, ErrCode, Casts: Integer;
begin
  Form := TDBGridForm(FForm);
  Assert.IsTrue(Form.ShadowGrid.ShadowLink = Form.ShadowGrid, 'fixture: the descendant field is not set');
  Assert.IsTrue(GetGridText(FPipeName, ShadowGridPath, Text, Rows, CurrentRow, ErrCode, Casts), 'get_text on the descendant grid failed: ' + IntToStr(ErrCode));
  Assert.AreEqual(3, Rows, 'rows');
  Assert.AreEqual('Number'#9'Name'#10'1'#9'Name 1'#10'2'#9'Name 2'#10'3'#9'Name 3', Text, 'grid text');
end;


// OnGetText is app code. A handler that raises empties its own cell; the rest of the grid is still read and the cursor is restored.
procedure TDBGridTests.Test_GetText_RaisingOnGetTextCostsOneCell;
var
  Form: TDBGridForm;
  Text: String;
  Rows, CurrentRow, ErrCode, Casts: Integer;
begin
  Form := TDBGridForm(FForm);
  Form.Data.FieldByName('Name').OnGetText := Form.NameGetTextRaises;
  Form.Data.Last;
  Assert.IsTrue(GetGridText(FPipeName, GridPath, Text, Rows, CurrentRow, ErrCode, Casts), 'get_text failed: ' + IntToStr(ErrCode));
  Assert.AreEqual('Number'#9'Name'#10'1'#9'Name 1'#10'2'#9#10'3'#9'Name 3', Text, 'grid text');
  Assert.AreEqual(2, CurrentRow, 'currentRow');
  Assert.AreEqual(3, Form.Data.FieldByName('ID').AsInteger, 'the cursor was not restored');
end;


// list_tree must not carry the content of every grid.
procedure TDBGridTests.Test_ListTree_GridNodeHasNoText;
var
  Root, R, Node: TJSONObject;
  Components: TJSONArray;
  V: TJSONValue;
  i, Casts: Integer;
  Found: Boolean;
begin
  Found := FALSE;
  Root := CallCountingCasts(FPipeName, 'list_tree', '', Casts);
  try
    Assert.IsNotNull(Root, 'no answer from the bridge');
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'list_tree should return ok');
    Components := R.GetValue('components') as TJSONArray;
    for i := 0 to Components.Count - 1 do
    begin
      Node := Components.Items[i] as TJSONObject;
      V := Node.GetValue('path');
      if (V is TJSONString) and (TJSONString(V).Value = GridPath) then
      begin
        Found := TRUE;
        Assert.IsNull(Node.GetValue('text'), 'the grid node carries a text field');
      end;
    end;
  finally
    Root.Free;
  end;
  Assert.IsTrue(Found, 'list_tree did not return ' + GridPath);
end;


initialization
  TDUnitX.RegisterTestFixture(TDBGridTests);

end.
