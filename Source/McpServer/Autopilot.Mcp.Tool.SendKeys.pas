unit Autopilot.Mcp.Tool.SendKeys;

{=============================================================================================================
   2026.10.12
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - MCP tool: send_keys
   - Presses keys and shortcuts, or types text, inside the target app: OnKeyDown/OnKeyPress/OnKeyUp, KeyPreview, action ShortCuts, Default/Cancel buttons.
     No global input injection, no window activation.
   - Optional path (the control gets the focus inside the app first; omitted = the focused control), keys (chords like "Ctrl+S Enter"), text (typed one character at a time; sent before keys), pid.
   - Runs in Autopilot.Mcp.exe (Windows PC-side MCP server); target may be any platform.
=============================================================================================================}

interface

uses
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Mcp.ToolBase;

type
  TSendKeysParams = class
  private
    FPath: String;
    FKeys: String;
    FText: String;
    FPid : Integer;
  public
    [Optional]
    [SchemaDescription('Control that gets the focus and the keys. Omit: the focused control of the active form.')]
    property Path: String read FPath write FPath;

    [Optional]
    [SchemaDescription('Chords separated by spaces: "Ctrl+S", "Enter", "Ctrl+A Delete". Modifiers Ctrl Shift Alt; ' + 'keys A-Z 0-9 F1-F12 Enter Esc Tab Space Backspace Delete Insert Home End PageUp PageDown Up Down Left Right.')]
    property Keys: String read FKeys write FKeys;

    [Optional]
    [SchemaDescription('Text typed one character at a time, before keys.')]
    property Text: String read FText write FText;

    [Optional]
    [SchemaDescription('Target PID. Needed only when several targets run.')]
    property Pid: Integer read FPid write FPid;
  end;

  TSendKeysTool = class(TMCPToolBase<TSendKeysParams>)
  protected
    function ExecuteWithParams(const Params: TSendKeysParams): String; override;
  public
    constructor Create; override;
  end;


implementation

uses
  Autopilot.Bridge.Core,
  MCPServer.Registration;


constructor TSendKeysTool.Create;
begin
  inherited;
  FName := 'send_keys';
  FDescription := 'Press keys or type text inside the app, firing OnKeyDown/OnKeyPress, shortcuts and ' + 'Default/Cancel buttons. Use it to test keyboard behaviour; use set_text to just set a value. ' + 'A key that opens a modal dialog gives -32004: then call dismiss_dialog.';
end;


function TSendKeysTool.ExecuteWithParams(const Params: TSendKeysParams): String;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  if Params.Path <> ''
  then Args.AddPair('path', Params.Path);
  if Params.Keys <> ''
  then Args.AddPair('keys', Params.Keys);
  if Params.Text <> ''
  then Args.AddPair('text', Params.Text);
  // The bridge's per-command default is 2000 ms for a command it does not list; key handlers run user code like a click, so ask for the click budget.
  Result := RunCommandOnTarget(Cardinal(Params.Pid), BuildRequest(1, 'send_keys', Args, DefaultTimeoutClickMs), DefaultTimeoutClickMs);
end;


initialization
  TMCPRegistry.RegisterTool('send_keys',
    function: IMCPTool
    begin
      Result := TSendKeysTool.Create;
    end
  );


end.
