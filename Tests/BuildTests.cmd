@echo off
setlocal enabledelayedexpansion
prompt $p
cls

REM NOTE TO CLAUDE! Do not kill the program! Beep me instead!
REM NOTE TO CLAUDE! When compiling put the dcus in Win32_Debug folder

call "c:\Delphi\Delphi 13\bin\rsvars.bat"

set "MSBuild=c:\Windows\Microsoft.NET\Framework64\v4.0.30319\MSBuild.exe"
set "Project1=%~dp0Tests.dproj"
set "LogFile=c:\AI\Claude Code\Temp\Autopilot_Tests_build.log"

if not exist "!Project1!" (
    echo ERROR: Project file not found: !Project1!
    exit /b 1
)

echo Build started %time% > !LogFile!
echo Compiling !Project1! ...
echo === !Project1! === >> !LogFile!

"!MSBuild!" "!Project1!" /t:Clean;Build /p:platform=Win32 /p:Config=Debug >> !LogFile! 2>&1

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
