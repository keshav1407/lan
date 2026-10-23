@echo off
setlocal EnableDelayedExpansion
title LAN Dynamic Wallpaper - Web Display ^& Controller Server

:: Locate project directory
set "APP_DIR=%~dp0"
cd /d "!APP_DIR!"

cls
echo ==============================================================================
echo  LAN DYNAMIC WALLPAPER - WEB SERVER (DISPLAY ^& CONTROLLER)
echo ==============================================================================
echo.

:: Verify Node.js is installed
where node >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Node.js is not found in your PATH.
    echo Please install Node.js (version 18 or newer) from https://nodejs.org/
    echo.
    pause
    exit /b 1
)

:: Ensure dependencies are installed
if not exist "!APP_DIR!\node_modules" (
    echo [INFO] Installing required dependencies...
    call npm install
    if %ERRORLEVEL% neq 0 (
        echo [ERROR] npm install failed.
        pause
        exit /b %ERRORLEVEL%
    )
)

:: Idempotently ensure Windows Firewall allows TCP port 3000
net session >nul 2>&1
if %ERRORLEVEL% equ 0 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
      "$rule = Get-NetFirewallRule -DisplayName 'LAN-Dynamic-Wallpaper-Web-3000' -ErrorAction SilentlyContinue; " ^
      "if (-not $rule) { New-NetFirewallRule -DisplayName 'LAN-Dynamic-Wallpaper-Web-3000' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3000 -Profile 'Private,Domain' -ErrorAction SilentlyContinue | Out-Null }"
)

echo [INFO] Starting Web Server on Port 3000...
echo.

call npm start

if %ERRORLEVEL% neq 0 (
    echo.
    echo [ERROR] Web Server exited with code %ERRORLEVEL%.
    pause
)
exit /b %ERRORLEVEL%
