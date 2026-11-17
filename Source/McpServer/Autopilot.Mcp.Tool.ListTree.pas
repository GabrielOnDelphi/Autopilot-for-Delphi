unit Autopilot.Mcp.Tool.ListTree;

{=============================================================================================================
   2026.11.17
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - MCP tool: list_tree
   - Enumerates every form + component in the target app.
     Returns the bridge's raw JSON response as a string so the AI sees the full payload.
   - Optional form (one form's nodes) and formsOnly (only the form nodes): the bridge filters, so a large tree (the Delphi IDE) never crosses the pipe.
     A bridge older than these arguments ignores them and returns the whole tree.
   - Optional x, y (with form): only the control at that pixel. An older bridge ignores them; its answer has no field x, and then the tool answers isError.
   - Runs in Autopilot.Mcp.exe (Windows PC-side MCP server); target may be any platform.
=============================================================================================================}

interface

uses
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Mcp.ToolBase;

type
  TListTreeParams = class
  private
    FPid      : Integer;
    FForm     : String;
    FFormsOnly: Boolean;
    FPath     : String;
    FX        : Integer;
    FY        : Integer;
  public
    procedure AfterConstruction; override;

    [Optional]
    [SchemaDescription('Target PID. Needed only when several targets run.')]
    property Pid: Integer read FPid write FPid;

    [Optional]
    [SchemaDescription('Only the nodes of this form (case-insensitive). An unknown name answers -32001 with the form names.')]
    property Form: String read FForm write FForm;

    [Optional]
    [SchemaDescription('true = only the form nodes: learn the form names cheaply first.')]
    property FormsOnly: Boolean read FFormsOnly write FFormsOnly;

    [Optional]
    [SchemaDescription('Only this control and what lies under it (owned by it, or shown inside it). Same path forms as the other tools; paths in the answer stay as in the full tree.')]
    property Path: String read FPath write FPath;

    [Optional]
    [SchemaDescription('With y and form: only the control at this pixel of the form''s screenshot (unscaled, uncropped; ' + 'client coordinates, 0 = left edge). Climbs to the nearest control list_tree lists.')]
    property X: Integer read FX write FX;

    [Optional]
    [SchemaDescription('With x and form: the pixel row (0 = top of the client area).')]
    property Y: Integer read FY write FY;
  end;

  TListTreeTool = class(TMCPToolBase<TListTreeParams>)
  protected
    function ExecuteWithParams(const Params: TListTreeParams): String; override;
  public
    constructor Create; override;
  end;


implementation

uses
  MCPServer.Registration;


const
  CoordAbsent = Low(Integer);   // x or y not given: the request carries neither, byte-identical to before


procedure TListTreeParams.AfterConstruction;
begin
  inherited;
  FX := CoordAbsent;   // 0 is a valid coordinate, so absent needs its own value
  FY := CoordAbsent;
end;


{ TRUE when AAnswer is a successful bridge answer whose result has no field x: an older bridge, which ignored x and y and listed the whole form. }
function AnswerIgnoredThePoint(const AAnswer: String): Boolean;
var
  Root: TJSONValue;
  Res: TJSONValue;
begin
  Root := TJSONObject.ParseJSONValue(AAnswer);
  try
    if not (Root is TJSONObject) then EXIT(FALSE);
    if not TJSONObject(Root).GetValue<Boolean>('ok', FALSE) then EXIT(FALSE);
    Res := TJSONObject(Root).GetValue('result');
    Result := (Res is TJSONObject) and (TJSONObject(Res).GetValue('x') = NIL);
  finally
    FreeAndNil(Root);
  end;
end;


constructor TListTreeTool.Create;
begin
  inherited;
  FName := 'list_tree';
  FReadOnlyHint := TRUE;   // changes nothing in the target app
  FDescription := 'List every form and component in the target app, as a flat array at result.components ' + '(form, name, path, class; optional text, hint, enabled, visible, synthetic). ' + 'Path forms for the other tools: "Form" (the form), "Form.Leaf" (breadth-first search of ' + 'what Form owns, shallowest match wins), "Form.A.B.C" (each segment owned by the previous). ' + 'A path the owner tree cannot resolve is tried again through the visual parents. ' + 'Unnamed components appear as "@TButton#N" (N = current index in the owner; it shifts when ' + 'an earlier sibling is freed); use anchored paths for them. ' + 'Large app: formsOnly first, then form, then path for one panel or frame. ' + 'form + x + y: only the control at that screenshot pixel.';
end;


function TListTreeTool.ExecuteWithParams(const Params: TListTreeParams): String;
var
  Args: TJSONObject;
  HasPoint: Boolean;
begin
  if (Params.X = CoordAbsent) <> (Params.Y = CoordAbsent)
  then raise EArgumentException.Create('x and y must be given together (and with form)');
  HasPoint := Params.X <> CoordAbsent;

  // Forwarded only when given, so a call without them is the request every older server sent: an empty args object.
  Args := NIL;
  if (Params.Form <> '') or Params.FormsOnly or (Params.Path <> '') or HasPoint then
    begin
      Args := TJSONObject.Create;
      if Params.Form <> ''
      then Args.AddPair('form', Params.Form);
      if Params.FormsOnly
      then Args.AddPair('formsOnly', TJSONBool.Create(TRUE));
      if Params.Path <> ''
      then Args.AddPair('path', Params.Path);
      if HasPoint then
        begin
          Args.AddPair('x', TJSONNumber.Create(Params.X));
          Args.AddPair('y', TJSONNumber.Create(Params.Y));
        end;
    end;
  Result := RunCommandOnTarget(Cardinal(Params.Pid), BuildRequest(1, 'list_tree', Args));

  if HasPoint and AnswerIgnoredThePoint(Result)
  then raise Exception.Create('x, y: the Autopilot bridge in the target app is older than this MCP server and ignores x and y, '
                            + 'so its answer is the whole form, not the control at the point. Update the bridge units of the app to the version of this MCP server and rebuild it.');
end;


initialization
  TMCPRegistry.RegisterTool('list_tree',
    function: IMCPTool
    begin
      Result := TListTreeTool.Create;
    end);


end.
