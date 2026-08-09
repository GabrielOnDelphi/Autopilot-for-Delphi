UNIT Autopilot.Mcp.Tool.SetChecked;

(*=====================================================
   2026.05.13
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────────────┐
   │  WINDOWS  (PC-side MCP server)       │   runs in Autopilot.Mcp.exe; target may be any platform
   └──────────────────────────────────────┘

   MCP tool: set_checked
   Toggles a control's Checked property (TCheckBox, TRadioButton, anything with a
   published Checked property). Refuses if the control is disabled.
=====================================================*)

INTERFACE

USES
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Mcp.ToolBase;

TYPE
  TSetCheckedParams = CLASS
  PRIVATE
    FPath   : String;
    FChecked: Boolean;
    FPid    : Integer;
  PUBLIC
    [SchemaDescription('Path to the control. See list_tree for available paths. ' +
                       'Forms: "Form", "Form.Leaf", "Form.A.B.C". Unnamed components: "@TButton#N".')]
    PROPERTY Path: String READ FPath WRITE FPath;

    [SchemaDescription('TRUE to check, FALSE to uncheck.')]
    PROPERTY Checked: Boolean READ FChecked WRITE FChecked;

    [Optional]
    [SchemaDescription('Optional PID to disambiguate when multiple targets are active.')]
    PROPERTY Pid: Integer READ FPid WRITE FPid;
  END;

  TSetCheckedTool = CLASS(TMCPToolBase<TSetCheckedParams>)
  PROTECTED
    FUNCTION ExecuteWithParams(CONST Params: TSetCheckedParams): String; OVERRIDE;
  PUBLIC
    CONSTRUCTOR Create; OVERRIDE;
  END;


IMPLEMENTATION

USES
  MCPServer.Registration;


CONSTRUCTOR TSetCheckedTool.Create;
BEGIN
  inherited;
  FName := 'set_checked';
  FDescription := 'Set the Checked property of a TCheckBox / TRadioButton / similar.';
END;


FUNCTION TSetCheckedTool.ExecuteWithParams(CONST Params: TSetCheckedParams): String;
VAR
  Args: TJSONObject;
BEGIN
  Args := TJSONObject.Create;
  Args.AddPair('path', Params.Path);
  Args.AddPair('checked', TJSONBool.Create(Params.Checked));
  Result := RunCommandOnTarget(Cardinal(Params.Pid), BuildRequest(1, 'set_checked', Args));
END;


INITIALIZATION
  TMCPRegistry.RegisterTool('set_checked',
    FUNCTION: IMCPTool
    BEGIN
      Result := TSetCheckedTool.Create;
    END
  );


END.
