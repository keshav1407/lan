@echo off
setlocal EnableDelayedExpansion
title LAN Dynamic Wallpaper - Client Slideshow Agent

:: 1. Locate project root (supports running from any extracted directory structure)
set "APP_DIR=%~dp0"
if exist "%~dp0Client\Client.ps1" (
    set "APP_DIR=%~dp0"
) else if exist "%~dp0lan-main\Client\Client.ps1" (
    set "APP_DIR=%~dp0lan-main"
) else if exist "%~dp0LAN-Dynamic-Wallpaper\Client\Client.ps1" (
    set "APP_DIR=%~dp0LAN-Dynamic-Wallpaper"
) else (
    for /d %%D in ("%~dp0*") do (
        if exist "%%D\Client\Client.ps1" set "APP_DIR=%%D"
    )
)
cd /d "!APP_DIR!"

cls
echo ==============================================================================
echo  LAN DYNAMIC WALLPAPER SLIDESHOW - CLIENT WORKSTATION (Windows 11 / 10)
echo ==============================================================================
echo.

:: 2. Launch Client Slideshow Agent (optionally pass Host IP as 1st argument)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "!APP_DIR!\Client\Client.ps1" -HostAddress "%~1"

if %ERRORLEVEL% neq 0 (
    echo.
    echo [ERROR] Client agent exited with error code %ERRORLEVEL%.
    pause
)
exit /b %ERRORLEVEL%
