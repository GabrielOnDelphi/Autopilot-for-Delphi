unit Autopilot.Mcp.Tool.ListTree;

{=============================================================================================================
   2026.09
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - MCP tool: list_tree
   - Enumerates every form + component in the target app. Returns the bridge's raw JSON response as a string
     so the AI sees the full payload.
   - Runs in Autopilot.Mcp.exe (Windows PC-side MCP server); target may be any platform.
=============================================================================================================}

interface

uses
  System.SysUtils,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Mcp.ToolBase;

type
  TListTreeParams = class
  private
    FPid: Integer;
  public
    [Optional]
    [SchemaDescription('Target PID. Needed only when several targets run.')]
    property Pid: Integer read FPid write FPid;
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
  FDescription :=
    'List every form and component in the target app, as a flat array at result.components ' +
    '(form, name, path, class; optional text, enabled, visible, synthetic). ' +
    'Path forms for the other tools: "Form" (the form), "Form.Leaf" (breadth-first search of ' +
    'what Form owns, shallowest match wins), "Form.A.B.C" (each segment owned by the previous). ' +
    'A path the owner tree cannot resolve is tried again through the visual parents. ' +
    'Unnamed components appear as "@TButton#N" (N = current index in the owner; it shifts when ' +
    'an earlier sibling is freed); use anchored paths for them.';
end;


function TListTreeTool.ExecuteWithParams(const Params: TListTreeParams): String;
begin
  Result := RunCommandOnTarget(Cardinal(Params.Pid),
                               BuildRequest(1, 'list_tree', nil));
end;


initialization
  TMCPRegistry.RegisterTool('list_tree',
    function: IMCPTool
    begin
      Result := TListTreeTool.Create;
    end);


end.
