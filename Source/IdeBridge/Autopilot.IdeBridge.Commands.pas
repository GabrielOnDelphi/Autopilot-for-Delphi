UNIT Autopilot.IdeBridge.Commands;

{=============================================================================================================
   2026.11.14
   GabrielMoraru.com/autopilot
--------------------------------------------------------------------------------------------------------------
   The app commands of the IDE bridge: what the Open Tools API (unit ToolsAPI) offers, called through the MCP tool call_method.
     ide.activeProject  - the active project: file name, configuration, platform, framework
     ide.openProject    - opens a project (args: fileName) in a new project group
     ide.build          - makes or builds the active project (args: mode = make or build) and returns succeeded
     ide.messageGroups  - the names of the Messages view's groups
   OTA cannot read the text of the Messages view: IOTAMessageServices (ToolsAPI.pas) only adds, clears and navigates messages
   and lists the groups. So ide.build returns only the success flag of IOTAProjectBuilder.BuildProject, never the error lines or counts.

   RegisterIdeCommands is called by Register (Autopilot.IdeBridge.Register).
   The finalization removes the commands: it runs when the IDE unloads the package (or closes), on the main thread.
   The handlers are code of this package, so they must never outlive it in the registry.
=============================================================================================================}

INTERFACE

procedure RegisterIdeCommands;
procedure UnregisterIdeCommands;

IMPLEMENTATION

USES
  System.SysUtils, System.JSON,
  ToolsAPI,
  Autopilot.Bridge.Commands;

CONST
  CmdActiveProject = 'ide.activeProject';
  CmdOpenProject   = 'ide.openProject';
  CmdBuild         = 'ide.build';
  CmdMessageGroups = 'ide.messageGroups';


procedure needIdeServices;
begin
  if BorlandIDEServices = NIL
  then raise EInvalidOpException.Create('The IDE services (BorlandIDEServices) are not available');
end;


{ fileName, configuration, platform and frameworkType of AProject; fileName null when no project is open. }
function projectInfo(const AProject: IOTAProject): TJSONObject;
begin
  Result := TJSONObject.Create;
  if AProject = NIL then
    begin
      Result.AddPair('fileName', TJSONNull.Create);
      EXIT;
    end;
  Result.AddPair('fileName',      AProject.FileName);
  Result.AddPair('configuration', AProject.CurrentConfiguration);
  Result.AddPair('platform',      AProject.CurrentPlatform);
  Result.AddPair('frameworkType', AProject.FrameworkType);
end;


function stringArg(AArgs: TJSONObject; const AName, ACommand: String; ARequired: Boolean): String;
var
  V: TJSONValue;
begin
  V := AArgs.GetValue(AName);
  if (V = NIL) or (V is TJSONNull) then
    begin
      if ARequired
      then raise EArgumentException.Create(ACommand + ' needs args.' + AName + ' (a string)');
      EXIT('');
    end;
  if not (V is TJSONString) or (V is TJSONNumber)   // up to Delphi 12 TJSONNumber descends from TJSONString
  then raise EArgumentException.Create(ACommand + ' args.' + AName + ' must be a string');
  Result := TJSONString(V).Value;
end;


procedure RegisterIdeCommands;
begin
  RegisterAutopilotCommand(CmdActiveProject,
    'The active project of the IDE. No args. Returns fileName (null when no project is open), configuration, platform, frameworkType.',
    function(AArgs: TJSONObject): TJSONValue
    begin
      needIdeServices;
      Result := projectInfo(GetActiveProject);
    end);

  RegisterAutopilotCommand(CmdOpenProject,
    'Opens a project or project group in a new project group (the IDE may ask to save the current one). ' +
    'args: fileName (string, full path). Returns opened (Boolean) and the new active project.',
    function(AArgs: TJSONObject): TJSONValue
    var
      FileName: String;
      Opened: Boolean;
      Answer: TJSONObject;
    begin
      needIdeServices;
      FileName := stringArg(AArgs, 'fileName', CmdOpenProject, TRUE);
      if not FileExists(FileName)
      then raise EFileNotFoundException.Create(CmdOpenProject + ': file not found: ' + FileName);
      Opened := (BorlandIDEServices as IOTAActionServices).OpenProject(FileName, TRUE);
      Answer := TJSONObject.Create;
      Answer.AddPair('opened', TJSONBool.Create(Opened));
      Answer.AddPair('activeProject', projectInfo(GetActiveProject));
      Result := Answer;
    end);

  RegisterAutopilotCommand(CmdBuild,
    'Compiles the active project with its current configuration and platform. args: mode (string, make or build; default make). ' +
    'Returns succeeded (Boolean), mode and the project. A build takes long: give call_method a timeoutMs such as 120000. ' +
    'When the IDE shows the Compiling dialog and the build fails, the dialog stays open and the call answers -32004: ' +
    'read ProgressForm.Action, ErrorCount, WarningCount and HintCount with get_text, then click ProgressForm.CancelButton with mode=message.',
    function(AArgs: TJSONObject): TJSONValue
    var
      ModeName: String;
      Mode: TOTACompileMode;
      Project: IOTAProject;
      Succeeded: Boolean;
      Answer: TJSONObject;
    begin
      needIdeServices;
      ModeName := LowerCase(stringArg(AArgs, 'mode', CmdBuild, FALSE));
      if (ModeName = '') or (ModeName = 'make')
      then
        begin
          ModeName := 'make';
          Mode := cmOTAMake;
        end
      else
        if ModeName = 'build'
        then Mode := cmOTABuild
        else raise EArgumentException.Create(CmdBuild + ' args.mode must be make or build (got ' + ModeName + ')');

      Project := GetActiveProject;
      if Project = NIL
      then raise EInvalidOpException.Create(CmdBuild + ': no project is open');

      { Wait = FALSE: the progress dialog does not wait for OK after a successful build (ToolsAPI.pas, IOTAProjectBuilder40.BuildProject). }
      Succeeded := Project.ProjectBuilder.BuildProject(Mode, FALSE, TRUE);
      Answer := TJSONObject.Create;
      Answer.AddPair('succeeded', TJSONBool.Create(Succeeded));
      Answer.AddPair('mode', ModeName);
      Answer.AddPair('project', projectInfo(Project));
      Result := Answer;
    end);

  RegisterAutopilotCommand(CmdMessageGroups,
    'The names of the message groups in the Messages view (Build, Output, ...). No args. Returns groups (array of strings). OTA cannot read the messages themselves.',
    function(AArgs: TJSONObject): TJSONValue
    var
      Services: IOTAMessageServices;
      Groups: TJSONArray;
      Answer: TJSONObject;
      i: Integer;
    begin
      needIdeServices;
      Services := BorlandIDEServices as IOTAMessageServices;
      Answer := TJSONObject.Create;
      Groups := TJSONArray.Create;
      Answer.AddPair('groups', Groups);   // Answer owns Groups from here on
      for i := 0 to Services.GetMessageGroupCount - 1 do
        Groups.Add(Services.GetMessageGroup(i).GetGroupName);
      Result := Answer;
    end);
end;


procedure UnregisterIdeCommands;
begin
  UnregisterAutopilotCommand(CmdActiveProject);
  UnregisterAutopilotCommand(CmdOpenProject);
  UnregisterAutopilotCommand(CmdBuild);
  UnregisterAutopilotCommand(CmdMessageGroups);
end;


INITIALIZATION
  // empty: a FINALIZATION section needs an INITIALIZATION section

FINALIZATION
  UnregisterIdeCommands;

END.
