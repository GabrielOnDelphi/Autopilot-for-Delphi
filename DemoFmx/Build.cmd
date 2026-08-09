REM TEMPLATE: Update DelphiProjectName variable below with actual .dproj path

@echo off
setlocal enabledelayedexpansion
prompt $p
cls

echo Hint: Build without TESTINSIGHT to enable console output

REM NOTE TO CLAUDE! When compiling, respect the DCU output folder in the DPROJ file (usually Win32_Debug)
REM NOTE TO CLAUDE! Documentation for MsBuild for Delphi: https://docwiki.embarcadero.com/RADStudio/Athens/en/Building_a_Project_Using_an_MSBuild_Command
REM NOTE TO CLAUDE! Invoke from PowerShell tool: cmd /c Build.cmd
REM NOTE TO CLAUDE! Invoke from Bash tool:       cmd //c Build.cmd   (double slash escapes MSYS path mangling)
REM NOTE TO CLAUDE! Do NOT translate this script into bash or PowerShell. Keep it as .cmd.

call "c:\Delphi\Delphi 13\bin\rsvars.bat"

set "MSBuild=c:\Windows\Microsoft.NET\Framework64\v4.0.30319\MSBuild.exe"

REM Log goes to global Temp folder (not project dir). Use a project-unique filename to avoid collisions.
set "LogFile=c:\AI\Claude Code\Temp\Autopilot_DemoFmx_build.log"

REM Single project. For multi-package builds, copy the `c:\AI\Claude Code\TEMPLATE FOLDER\BuildPackage.cmd` template.
set "DelphiProjectName=c:\Projects\Projects AI\Autopilot for Delphi\DemoFmx\Autopilot.DemoFmx.dproj"

if not exist "!DelphiProjectName!" (
    echo.
    echo ERROR: Project file not found: !DelphiProjectName!
    echo.
    echo Fix: Edit this script and set DelphiProjectName variable to your actual .dproj file path
    echo Example: set "DelphiProjectName=C:\Projects\MyApp\MyApp.dproj"
    echo.
    exit /b 1
)

echo Build started %time% > !LogFile!
echo.
echo Compiling !DelphiProjectName! ...
echo === !DelphiProjectName! === >> !LogFile!

"!MSBuild!" "!DelphiProjectName!" /t:Clean;Build /p:platform=Win32 /p:Config=Debug >> !LogFile! 2>&1

if errorlevel 1 (
    echo Exit code: !errorlevel! >> !LogFile!
    echo.
    echo BUILD FAILED
    echo See !LogFile! for details
    exit /b 1
)

echo Build finished %time% >> !LogFile!
echo Exit code: 0 >> !LogFile!

echo.
echo BUILD OK
