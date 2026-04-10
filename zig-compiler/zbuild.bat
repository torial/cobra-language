@echo off
:: zbuild.bat — build zebra and install, killing any locked instance first.
:: Usage: zbuild [test]

setlocal enabledelayedexpansion

set OUTDIR=%~dp0zig-out\bin
set CACHEDIR=%~dp0.zig-cache\o

:: Kill any running zebra.exe
taskkill /F /IM zebra.exe >nul 2>&1

if "%1"=="test" (
    zig build test
    exit /b %ERRORLEVEL%
)

:: Build (compile step will succeed even if install fails)
zig build 2>&1

:: Find newest zebra.exe in cache using a temp file
set NEWEST=
for /f "delims=" %%F in ('dir /b /s /o:-d "%CACHEDIR%\zebra.exe" 2^>nul') do (
    if "!NEWEST!"=="" set NEWEST=%%F
)

if "%NEWEST%"=="" (
    echo zbuild: no compiled binary found in cache >&2
    exit /b 1
)

:: Kill again in case something grabbed it
taskkill /F /IM zebra.exe >nul 2>&1

if not exist "%OUTDIR%" mkdir "%OUTDIR%"
copy /Y "%NEWEST%" "%OUTDIR%\zebra.exe" >nul
echo Installed: %OUTDIR%\zebra.exe
