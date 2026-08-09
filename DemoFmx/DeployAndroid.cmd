REM Android packaging (Make + Deploy) for Autopilot.DemoFmx. This is NOT a compile-only build.
REM
REM Why this is separate from Build.cmd and the delphi-compiler agent:
REM   delphi-compiler.exe rejects Android64, and the agent's Android path compiles only
REM   (it produces libAutopilot.DemoFmx.so, never the .apk). The .apk needs MSBuild's
REM   Deploy target. This .cmd is the single blessed entry point for that one MSBuild step;
REM   adb install / launch / forward are done separately (no MSBuild, already AI-ownable).
REM
REM PREREQUISITE: Autopilot.DemoFmx.deployproj must sit next to the .dproj.
REM   Emitted only by an actual Deploy from the IDE — select Android64 + Debug, then
REM   Project ^> Deploy (or F9 on the connected device). NOT Project ^> Deployment + Save:
REM   that only writes the <Deployment> section into the .dproj. The .deployproj is the
REM   separate MSBuild-consumed export. Reused headlessly thereafter.

@echo off
setlocal enabledelayedexpansion
prompt $p
cls

REM NOTE TO CLAUDE! Invoke from PowerShell tool: cmd /c DeployAndroid.cmd
REM NOTE TO CLAUDE! Invoke from Bash tool:       cmd //c DeployAndroid.cmd   (double slash escapes MSYS path mangling)
REM NOTE TO CLAUDE! Do NOT translate this script into bash or PowerShell. Keep it as .cmd.

call "c:\Delphi\Delphi 13\bin\rsvars.bat"

set "MSBuild=c:\Windows\Microsoft.NET\Framework64\v4.0.30319\MSBuild.exe"
set "LogFile=c:\AI\Claude Code\Temp\Autopilot_DemoFmx_AndroidDeploy.log"
set "ProjectDir=c:\Projects\Projects AI\Autopilot for Delphi\DemoFmx"
set "DelphiProjectName=!ProjectDir!\Autopilot.DemoFmx.dproj"
set "DeployProj=!ProjectDir!\Autopilot.DemoFmx.deployproj"

if not exist "!DelphiProjectName!" (
    echo.
    echo ERROR: Project file not found: !DelphiProjectName!
    exit /b 1
)

if not exist "!DeployProj!" (
    echo.
    echo ERROR: Deployment file not found: !DeployProj!
    echo.
    echo Generate it once from the IDE: open the project, select Android64 + Debug,
    echo then Project ^> Deployment. Keep the emitted .deployproj and the updated .dproj.
    echo.
    exit /b 1
)

echo Deploy started %time% > !LogFile!
echo.
echo Packaging !DelphiProjectName! for Android64 ...
echo === !DelphiProjectName! (Android64 Make;Deploy) === >> !LogFile!

"!MSBuild!" "!DelphiProjectName!" /t:Make;Deploy /p:platform=Android64 /p:Config=Debug >> !LogFile! 2>&1

if errorlevel 1 (
    echo Exit code: !errorlevel! >> !LogFile!
    echo.
    echo DEPLOY FAILED
    echo See !LogFile! for details
    exit /b 1
)

echo Deploy finished %time% >> !LogFile!
echo Exit code: 0 >> !LogFile!

echo.
echo DEPLOY OK
echo.
echo APK(s) produced (newest is the one to "adb install -r"):
REM The .apk lands in the deploy-staging folder <ProjectName>\bin, NOT the Android64_Debug object-output folder (that holds only .dcu/.o).
if exist "!ProjectDir!\Autopilot.DemoFmx\bin" (
    for %%F in ("!ProjectDir!\Autopilot.DemoFmx\bin\*.apk") do echo   %%F
)
