@echo off
setlocal EnableDelayedExpansion
title LAN Dynamic Wallpaper - Host PC ^& Slideshow Controller

:: 1. Locate project root (supports running from any extracted directory structure)
set "APP_DIR=%~dp0"
if exist "%~dp0Host\Host.ps1" (
    set "APP_DIR=%~dp0"
) else if exist "%~dp0lan-main\Host\Host.ps1" (
    set "APP_DIR=%~dp0lan-main"
) else if exist "%~dp0LAN-Dynamic-Wallpaper\Host\Host.ps1" (
    set "APP_DIR=%~dp0LAN-Dynamic-Wallpaper"
) else (
    for /d %%D in ("%~dp0*") do (
        if exist "%%D\Host\Host.ps1" set "APP_DIR=%%D"
    )
)
cd /d "!APP_DIR!"

cls
echo ==============================================================================
echo  LAN DYNAMIC WALLPAPER SLIDESHOW - HOST MANAGER (Windows 11 / 10)
echo ==============================================================================
echo  [MODE] Standard User Mode (No Administrator Elevation Required)
echo  [LAN]  Starting Host Server and LAN Discovery on all network interfaces...
echo ==============================================================================
echo.

:: 2. Automatically ensure Wallpapers drop folder exists and open in Windows Explorer
if not exist "!APP_DIR!\Wallpapers" mkdir "!APP_DIR!\Wallpapers"
start "" explorer.exe "!APP_DIR!\Wallpapers"

:: 3. Launch Host Server in interactive console (Zero-Admin, pure socket mode)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "!APP_DIR!\Host\Host.ps1"

if %ERRORLEVEL% neq 0 (
    echo.
    echo [ERROR] Host process exited with error code %ERRORLEVEL%.
    pause
)
exit /b %ERRORLEVEL%
