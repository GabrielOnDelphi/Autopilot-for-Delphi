unit Autopilot.Mcp.Tool.ListTree;

{=============================================================================================================
   2026.06
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
    [SchemaDescription('Optional PID to disambiguate when multiple targets are active.')]
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
    'Enumerate every form and component in the running target Delphi app. ' +
    'Returns a flat array at result.components; each node has form, name, path, class, ' +
    'plus optional text, enabled, visible, and synthetic. ' +
    'Walks containers recursively (frames, panels with owned children), so deep ' +
    'forms can yield many nodes. Path forms accepted by click/get_text/set_text/set_checked/wait_for: ' +
    '"Form" (the form itself), "Form.Leaf" (BFS shallow-wins recursive search), ' +
    '"Form.A.B.C" (anchored — each segment is a direct child of the previous). ' +
    'Unnamed components show up as "@TButton#N" (N = ComponentIndex in owner); ' +
    'prefer anchored paths for synthetic IDs since the index is owner-relative.';
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
    end
  );


end.
