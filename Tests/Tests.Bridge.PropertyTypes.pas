unit Tests.Bridge.PropertyTypes;

{=============================================================================================================
   2026.10.07
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for list_tree, set_text and set_checked on components whose Visible / Enabled / Text / Caption /
     Checked / ReadOnly / CanModify / AutoEdit have an unexpected type (GitHub issue 2: DevExpress bar items
     declare Visible as the enumeration TdxBarItemVisible).
   - The bridge used to read and write them with TValue conversions that raise EInvalidCast on such a type. Even a
     swallowed raise halts a debugger that stops on language exceptions, and with it the whole app. Each test counts
     the EInvalidCast raises during one bridge command (TRaiseCounter, Tests.RaiseCounter.pas).
   - The data-aware path is reached through RTTI only (DataField -> DataSource -> DataSet), so stand-in classes
     with the same property names exercise it without Data.DB.
   - Win32 only (TRaiseCounter reads the Delphi exception record), like Tests.LeakSuppressor.
=============================================================================================================}

interface

uses
  Vcl.Forms,
  DUnitX.TestFramework;

type
  [TestFixture]
  TPropertyTypeTests = class
  private
    FPipeName   : String;
    FPipeCounter: Integer;
    FForm       : TForm;    // TPropTypesForm; the class is private to the implementation
  public
    [SetupFixture]    procedure SetupFixture;
    [Setup]           procedure Setup;
    [TearDown]        procedure TearDown;
    [TearDownFixture] procedure TearDownFixture;

    [Test] procedure Test_ListTree_OddPropertyTypesRaiseNoException;
    [Test] procedure Test_SetText_IntegerCaptionIsMissing;
    [Test] procedure Test_SetChecked_EnumCheckedIsMissing;
    [Test] procedure Test_SetChecked_DataBoundEnumCheckedIsUnsupported;
    [Test] procedure Test_SetText_DataBoundEnumFlagsAreSkipped;
  end;


implementation

uses
  Winapi.Windows,   // GetCurrentProcessId for the pipe name
  System.SysUtils, System.Classes, System.JSON, System.Generics.Collections,
  Vcl.Controls, Vcl.StdCtrls,
  Autopilot.Bridge.Core, Autopilot.Bridge.Vcl,
  Bridge.TestClient, Bridge.Tests, Tests.RaiseCounter;


type
  TItemVisible = (ivNever, ivInCustomizing, ivAlways, ivNotInCustomizing);   // the values of DevExpress TdxBarItemVisible

  // Visible is an enumeration, as on a DevExpress bar item.
  TEnumVisibleItem = class(TComponent)
  private
    FVisible: TItemVisible;
  published
    property Visible: TItemVisible read FVisible write FVisible default ivAlways;
  end;

  // Enabled is an enumeration and Caption an Integer.
  TOddPropsItem = class(TComponent)
  private
    FEnabled: TItemVisible;
    FCaption: Integer;
  published
    property Enabled: TItemVisible read FEnabled write FEnabled default ivAlways;
    property Caption: Integer read FCaption write FCaption default 0;
  end;

  // Visible is a WordBool: a Boolean family type that list_tree must still read.
  TWordBoolItem = class(TComponent)
  private
    FVisible: WordBool;
  published
    property Visible: WordBool read FVisible write FVisible;
  end;

  // Checked is an enumeration; no data binding.
  TEnumCheckedItem = class(TComponent)
  private
    FChecked: TItemVisible;
  published
    property Checked: TItemVisible read FChecked write FChecked default ivNever;
  end;

  { Stand-ins for TField / TDataSet / TDataSource. The bridge finds them only by property and method name, and every
    flag it reads before an edit (ReadOnly, CanModify, AutoEdit) is an enumeration here, not a Boolean. }
  TFakeDataSetState = (dsBrowse, dsEdit);   // TryDataBoundEdit compares the state by its name

  TFakeField = class(TComponent)
  private
    FCanModify: TItemVisible;
  published
    property CanModify: TItemVisible read FCanModify write FCanModify default ivAlways;
  end;

  TFakeDataSet = class(TComponent)
  private
    FState: TFakeDataSetState;
    FCanModify: TItemVisible;
    FField: TFakeField;
  public
    constructor Create(AOwner: TComponent); override;
    function FindField(const AFieldName: String): TFakeField;   // found by the bridge through RTTI
  published
    property State: TFakeDataSetState read FState write FState default dsBrowse;
    property CanModify: TItemVisible read FCanModify write FCanModify default ivAlways;
  end;

  TFakeDataSource = class(TComponent)
  private
    FDataSet: TFakeDataSet;
    FAutoEdit: TItemVisible;
  public
    procedure Edit;                                             // found by the bridge through RTTI
  published
    property DataSet: TFakeDataSet read FDataSet write FDataSet;
    property AutoEdit: TItemVisible read FAutoEdit write FAutoEdit default ivAlways;
  end;

  // set_text target bound through DataField + DataSource, with an enumeration ReadOnly.
  TFakeDBEdit = class(TComponent)
  private
    FDataField: String;
    FDataSource: TFakeDataSource;
    FReadOnly: TItemVisible;
    FText: String;
  published
    property DataField: String read FDataField write FDataField;
    property DataSource: TFakeDataSource read FDataSource write FDataSource;
    property ReadOnly: TItemVisible read FReadOnly write FReadOnly default ivNever;
    property Text: String read FText write FText;
  end;

  // set_checked target bound the same way, with an enumeration Checked. A TWinControl, because set_checked reads
  // the Checked of a data-bound control only when the control is windowed.
  TFakeDBCheck = class(TWinControl)
  private
    FDataField: String;
    FDataSource: TFakeDataSource;
    FChecked: TItemVisible;
  published
    property DataField: String read FDataField write FDataField;
    property DataSource: TFakeDataSource read FDataSource write FDataSource;
    property Checked: TItemVisible read FChecked write FChecked default ivAlways;
  end;

  TPropTypesForm = class(TForm)
  public
    BtnPlain: TButton;
    constructor Create(AOwner: TComponent); override;
  end;


const
  BoundFieldName = 'Name';


{ TFakeDataSet }

constructor TFakeDataSet.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FField := TFakeField.Create(Self);
  FField.Name      := 'fld' + BoundFieldName;
  FField.CanModify := ivAlways;
end;


function TFakeDataSet.FindField(const AFieldName: String): TFakeField;
begin
  if SameText(AFieldName, BoundFieldName)
  then Result := FField
  else Result := NIL;
end;


{ TFakeDataSource }

procedure TFakeDataSource.Edit;
begin
  Assert.IsNotNull(FDataSet, 'TFakeDataSource.Edit: no DataSet');
  FDataSet.State := dsEdit;
end;


{ TPropTypesForm }

constructor TPropTypesForm.Create(AOwner: TComponent);
var
  i: Integer;
  Item: TEnumVisibleItem;
  OddItem: TOddPropsItem;
  WordItem: TWordBoolItem;
  CheckedItem: TEnumCheckedItem;
  DataSet: TFakeDataSet;
  DataSource: TFakeDataSource;
  DBEdit: TFakeDBEdit;
  DBCheck: TFakeDBCheck;
begin
  inherited CreateNew(AOwner);
  Name    := 'PropTypesForm';
  Caption := 'Property types';

  for i := 1 to 3 do
  begin
    Item := TEnumVisibleItem.Create(Self);
    Item.Name    := 'biItem' + IntToStr(i);
    Item.Visible := ivAlways;
  end;

  OddItem := TOddPropsItem.Create(Self);
  OddItem.Name    := 'oddProps';
  OddItem.Enabled := ivAlways;
  OddItem.Caption := 42;

  WordItem := TWordBoolItem.Create(Self);
  WordItem.Name    := 'wordBoolItem';
  WordItem.Visible := TRUE;

  CheckedItem := TEnumCheckedItem.Create(Self);
  CheckedItem.Name    := 'enumChecked';
  CheckedItem.Checked := ivNever;

  { # Data-aware stand-ins }
  DataSet := TFakeDataSet.Create(Self);
  DataSet.Name      := 'dbDataSet';
  DataSet.State     := dsBrowse;
  DataSet.CanModify := ivAlways;

  DataSource := TFakeDataSource.Create(Self);
  DataSource.Name     := 'dbSource';
  DataSource.DataSet  := DataSet;
  DataSource.AutoEdit := ivAlways;

  DBEdit := TFakeDBEdit.Create(Self);
  DBEdit.Name       := 'dbEdit';
  DBEdit.DataField  := BoundFieldName;
  DBEdit.DataSource := DataSource;
  DBEdit.ReadOnly   := ivNever;
  DBEdit.Text       := 'old';

  DBCheck := TFakeDBCheck.Create(Self);
  DBCheck.Name       := 'dbCheck';
  DBCheck.Parent     := Self;
  DBCheck.DataField  := BoundFieldName;
  DBCheck.DataSource := DataSource;
  DBCheck.Checked    := ivAlways;

  BtnPlain := TButton.Create(Self);
  BtnPlain.Name    := 'btnPlain';
  BtnPlain.Caption := 'Plain';
  BtnPlain.Parent  := Self;
end;


{ Helpers --------------------------------------------------------------- }

// The list_tree node whose 'path' is APath, or NIL.
function FindNode(AComponents: TJSONArray; const APath: String): TJSONObject;
var
  i: Integer;
  Node: TJSONObject;
  V: TJSONValue;
begin
  Result := NIL;
  for i := 0 to AComponents.Count - 1 do
  begin
    Node := AComponents.Items[i] as TJSONObject;
    V := Node.GetValue('path');
    if (V is TJSONString) and (TJSONString(V).Value = APath) then
      exit(Node);
  end;
end;


// The Boolean field AName of ANode: 'missing' when absent, else 'true' / 'false'.
function BoolFieldText(ANode: TJSONObject; const AName: String): String;
var
  V: TJSONValue;
begin
  V := ANode.GetValue(AName);
  if V = NIL then exit('missing');
  if V is TJSONBool
  then Result := LowerCase(BoolToStr(TJSONBool(V).AsBoolean, TRUE))
  else Result := 'not a Boolean: ' + V.ToJSON;
end;


// Sends one command over APipeName and counts the EInvalidCast raises of the whole process while the bridge runs it.
// Takes ownership of AArgs. The caller frees the result; NIL when the connection failed.
function CallCountingCasts(const APipeName, ACmd: String; AArgs: TJSONObject; OUT ACastCount: Integer): TJSONObject;
var
  Root, Args: TJSONObject;
  PipeName, Cmd: String;
begin
  PipeName := APipeName;
  Cmd      := ACmd;
  Args     := AArgs;
  Root     := NIL;
  try
    TRaiseCounter.Install(EInvalidCast);
    try
      RunOnWorkerAndPump(
        procedure
        var Client: TBridgeTestClient;
        begin
          Client := TBridgeTestClient.Create;
          try
            if Client.ConnectAndHandshake(PipeName, 2000) then
            begin
              Root := Client.Call(1, Cmd, Args);
              Args := NIL;   // Call owns it now
            end;
          finally
            FreeAndNil(Client);
          end;
        end, 5000);
      ACastCount := TRaiseCounter.Count;
    finally
      TRaiseCounter.Uninstall;
    end;
  finally
    FreeAndNil(Args);   // only when Call never took it
  end;
  Result := Root;
end;


{ TPropertyTypeTests ------------------------------------------------------ }

procedure TPropertyTypeTests.SetupFixture;
begin
  FPipeCounter := 0;
  FForm := TPropTypesForm.Create(NIL);
end;


procedure TPropertyTypeTests.Setup;
begin
  Inc(FPipeCounter);
  FPipeName := '\\.\pipe\AutopilotTestPT.' + IntToStr(GetCurrentProcessId) + '.' + IntToStr(FPipeCounter);
  StartBridgeOnPipe(FPipeName);
end;


procedure TPropertyTypeTests.TearDown;
begin
  StopBridge;
end;


procedure TPropertyTypeTests.TearDownFixture;
begin
  FreeAndNil(FForm);
end;


// GitHub issue 2. The node shape did not change (a property of an unexpected type was left out before too);
// what the fix removed is the EInvalidCast raised and swallowed for each of the five odd properties.
procedure TPropertyTypeTests.Test_ListTree_OddPropertyTypesRaiseNoException;
var
  Root, R: TJSONObject;
  Components: TJSONArray;
  Node: TJSONObject;
  PipeName: String;
  ProbeCount, ListTreeCount: Integer;
begin
  PipeName := FPipeName;
  Root := NIL;
  TRaiseCounter.Install(EInvalidCast);
  try
    // The probe must see a raise that is caught, or a zero below would prove nothing.
    try
      raise EInvalidCast.Create('probe');
    except
      on EInvalidCast do ;   // the probe raise; only the counter matters
    end;
    ProbeCount := TRaiseCounter.Count;

    TRaiseCounter.Reset;
    RunOnWorkerAndPump(
      procedure
      var Client: TBridgeTestClient;
      begin
        Client := TBridgeTestClient.Create;
        try
          if not Client.ConnectAndHandshake(PipeName, 2000) then
            Assert.Fail('connect to ' + PipeName + ' failed');
          Root := Client.Call(1, 'list_tree', NIL);
        finally
          FreeAndNil(Client);
        end;
      end, 5000);
    ListTreeCount := TRaiseCounter.Count;
  finally
    TRaiseCounter.Uninstall;
  end;

  try
    Assert.AreEqual(1, ProbeCount, 'the vectored handler must count a caught EInvalidCast');

    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'list_tree must succeed');
    Components := R.GetValue('components') as TJSONArray;
    Assert.IsNotNull(Components, 'list_tree must return components');

    Assert.AreEqual(0, ListTreeCount, 'list_tree must raise no EInvalidCast on a non-Boolean Visible/Enabled or a non-string Caption');

    Node := FindNode(Components, 'PropTypesForm.biItem1');
    Assert.IsNotNull(Node, 'biItem1 must be listed');
    Assert.AreEqual('missing', BoolFieldText(Node, 'visible'), 'an enumeration Visible must be left out (unknown)');

    Node := FindNode(Components, 'PropTypesForm.oddProps');
    Assert.IsNotNull(Node, 'oddProps must be listed');
    Assert.AreEqual('missing', BoolFieldText(Node, 'enabled'), 'an enumeration Enabled must be left out (unknown)');
    Assert.IsNull(Node.GetValue('text'), 'an Integer Caption must not become text');

    Node := FindNode(Components, 'PropTypesForm.wordBoolItem');
    Assert.IsNotNull(Node, 'wordBoolItem must be listed');
    Assert.AreEqual('true', BoolFieldText(Node, 'visible'), 'a WordBool Visible must still be read');

    Node := FindNode(Components, 'PropTypesForm.btnPlain');
    Assert.IsNotNull(Node, 'btnPlain must be listed');
    Assert.AreEqual('true', BoolFieldText(Node, 'enabled'), 'a Boolean Enabled must still be read');
    Assert.AreEqual('true', BoolFieldText(Node, 'visible'), 'a Boolean Visible must still be read');
    Assert.IsNotNull(Node.GetValue('text'), 'a string Caption must still be read');
    Assert.AreEqual('Plain', (Node.GetValue('text') as TJSONString).Value, 'wrong text for btnPlain');
  finally
    FreeAndNil(Root);
  end;
end;


// set_text on a component whose only Caption is an Integer: answered as for a component without Text/Caption.
procedure TPropertyTypeTests.Test_SetText_IntegerCaptionIsMissing;
var
  Args, Root: TJSONObject;
  Casts: Integer;
  OddItem: TOddPropsItem;
begin
  OddItem := FForm.FindComponent('oddProps') as TOddPropsItem;
  Assert.IsNotNull(OddItem, 'oddProps must exist');
  OddItem.Caption := 42;

  Args := TJSONObject.Create;
  Args.AddPair('path', 'PropTypesForm.oddProps');
  Args.AddPair('text', 'x');
  Root := CallCountingCasts(FPipeName, 'set_text', Args, Casts);
  try
    Assert.IsNotNull(Root, 'set_text must answer');
    Assert.AreEqual(0, Casts, 'set_text must raise no EInvalidCast on an Integer Caption');
    Assert.AreEqual(ErrRttiPropertyMissing, GetErrorCode(Root), 'an Integer Caption must count as a missing Text/Caption');
    Assert.AreEqual(42, OddItem.Caption, 'the Integer Caption must not change');
  finally
    FreeAndNil(Root);
  end;
end;


// set_checked on a component whose Checked is an enumeration: answered as for a component without Checked.
procedure TPropertyTypeTests.Test_SetChecked_EnumCheckedIsMissing;
var
  Args, Root: TJSONObject;
  Casts: Integer;
  CheckedItem: TEnumCheckedItem;
begin
  CheckedItem := FForm.FindComponent('enumChecked') as TEnumCheckedItem;
  Assert.IsNotNull(CheckedItem, 'enumChecked must exist');
  CheckedItem.Checked := ivNever;

  Args := TJSONObject.Create;
  Args.AddPair('path', 'PropTypesForm.enumChecked');
  Args.AddPair('checked', TJSONBool.Create(TRUE));
  Root := CallCountingCasts(FPipeName, 'set_checked', Args, Casts);
  try
    Assert.IsNotNull(Root, 'set_checked must answer');
    Assert.AreEqual(0, Casts, 'set_checked must raise no EInvalidCast on a non-Boolean Checked');
    Assert.AreEqual(ErrRttiPropertyMissing, GetErrorCode(Root), 'a non-Boolean Checked must count as a missing Checked');
    Assert.AreEqual(Ord(ivNever), Ord(CheckedItem.Checked), 'the enumeration Checked must not change');
  finally
    FreeAndNil(Root);
  end;
end;


// set_checked on a data-bound windowed control whose Checked is an enumeration: answered as for a data-bound control
// without Checked (-32005).
procedure TPropertyTypeTests.Test_SetChecked_DataBoundEnumCheckedIsUnsupported;
var
  Args, Root: TJSONObject;
  Casts: Integer;
  DBCheck: TFakeDBCheck;
begin
  DBCheck := FForm.FindComponent('dbCheck') as TFakeDBCheck;
  Assert.IsNotNull(DBCheck, 'dbCheck must exist');
  DBCheck.Checked := ivAlways;

  Args := TJSONObject.Create;
  Args.AddPair('path', 'PropTypesForm.dbCheck');
  Args.AddPair('checked', TJSONBool.Create(TRUE));
  Root := CallCountingCasts(FPipeName, 'set_checked', Args, Casts);
  try
    Assert.IsNotNull(Root, 'set_checked must answer');
    Assert.AreEqual(0, Casts, 'set_checked must raise no EInvalidCast on a non-Boolean Checked of a data-bound control');
    Assert.AreEqual(ErrUnsupportedAction, GetErrorCode(Root), 'a data-bound control with a non-Boolean Checked must be answered like one without Checked');
    Assert.AreEqual(Ord(ivAlways), Ord(DBCheck.Checked), 'the enumeration Checked must not change');
  finally
    FreeAndNil(Root);
  end;
end;


// set_text on a data-bound component whose ReadOnly, field CanModify, dataset CanModify and DataSource AutoEdit are
// all enumerations: each check is skipped as if the property were missing, so the edit and the write go through.
procedure TPropertyTypeTests.Test_SetText_DataBoundEnumFlagsAreSkipped;
var
  Args, Root, R: TJSONObject;
  Casts: Integer;
  DBEdit: TFakeDBEdit;
  DataSet: TFakeDataSet;
  V: TJSONValue;
begin
  DBEdit  := FForm.FindComponent('dbEdit') as TFakeDBEdit;
  DataSet := FForm.FindComponent('dbDataSet') as TFakeDataSet;
  Assert.IsNotNull(DBEdit, 'dbEdit must exist');
  Assert.IsNotNull(DataSet, 'dbDataSet must exist');
  DBEdit.Text   := 'old';
  DataSet.State := dsBrowse;

  Args := TJSONObject.Create;
  Args.AddPair('path', 'PropTypesForm.dbEdit');
  Args.AddPair('text', 'typed');
  Root := CallCountingCasts(FPipeName, 'set_text', Args, Casts);
  try
    Assert.IsNotNull(Root, 'set_text must answer');
    Assert.AreEqual(0, Casts, 'set_text must raise no EInvalidCast on a non-Boolean ReadOnly, CanModify or AutoEdit');
    R := GetOkResult(Root);
    Assert.IsNotNull(R, 'set_text must succeed: a non-Boolean ReadOnly, CanModify or AutoEdit counts as missing');
    V := R.GetValue('dataBound');
    Assert.IsTrue((V is TJSONBool) and TJSONBool(V).AsBoolean, 'set_text must report dataBound = true');
    Assert.AreEqual(Ord(dsEdit), Ord(DataSet.State), 'the bridge must have called DataSource.Edit');
    Assert.AreEqual('typed', DBEdit.Text, 'the text must be written');
  finally
    FreeAndNil(Root);
  end;
end;


initialization
  TDUnitX.RegisterTestFixture(TPropertyTypeTests);

end.
