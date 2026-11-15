unit Autopilot.Mcp.Tool.ListTree;

{=============================================================================================================
   2026.11.14
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - MCP tool: list_tree
   - Enumerates every form + component in the target app.
     Returns the bridge's raw JSON response as a string so the AI sees the full payload.
   - Optional form (one form's nodes) and formsOnly (only the form nodes): the bridge filters, so a large tree (the Delphi IDE) never crosses the pipe.
     A bridge older than these arguments ignores them and returns the whole tree.
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
  public
    [Optional]
    [SchemaDescription('Target PID. Needed only when several targets run.')]
    property Pid: Integer read FPid write FPid;

    [Optional]
    [SchemaDescription('Only the nodes of this form (case-insensitive). An unknown name answers -32001 with the form names.')]
    property Form: String read FForm write FForm;

    [Optional]
    [SchemaDescription('true = only the form nodes: learn the form names cheaply first.')]
    property FormsOnly: Boolean read FFormsOnly write FFormsOnly;
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


constructor TListTreeTool.Create;
begin
  inherited;
  FName := 'list_tree';
  FDescription := 'List every form and component in the target app, as a flat array at result.components ' + '(form, name, path, class; optional text, hint, enabled, visible, synthetic). ' + 'Path forms for the other tools: "Form" (the form), "Form.Leaf" (breadth-first search of ' + 'what Form owns, shallowest match wins), "Form.A.B.C" (each segment owned by the previous). ' + 'A path the owner tree cannot resolve is tried again through the visual parents. ' + 'Unnamed components appear as "@TButton#N" (N = current index in the owner; it shifts when ' + 'an earlier sibling is freed); use anchored paths for them. ' + 'Large app: formsOnly first, then form.';
end;


function TListTreeTool.ExecuteWithParams(const Params: TListTreeParams): String;
var
  Args: TJSONObject;
begin
  // Forwarded only when given, so a call without them is the request every older server sent: an empty args object.
  Args := NIL;
  if (Params.Form <> '') or Params.FormsOnly then
    begin
      Args := TJSONObject.Create;
      if Params.Form <> ''
      then Args.AddPair('form', Params.Form);
      if Params.FormsOnly
      then Args.AddPair('formsOnly', TJSONBool.Create(TRUE));
    end;
  Result := RunCommandOnTarget(Cardinal(Params.Pid), BuildRequest(1, 'list_tree', Args));
end;


initialization
  TMCPRegistry.RegisterTool('list_tree',
    function: IMCPTool
    begin
      Result := TListTreeTool.Create;
    end);


end.
