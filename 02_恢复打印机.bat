@echo off
rem ===========================================================================
rem  Program B : restore entry           (run on the NEW / personal PC)
rem  File name : 02 restore BAT  (this file)
rem
rem  This file lives INSIDE the Printer_Backup folder produced by program A.
rem  Just double-click it - no backup program needed, no driver download, and no
rem  need to type any driver file location.
rem
rem  What it does:
rem    - finds the backup data in its own folder automatically
rem    - verifies file integrity (SHA256 manifest) and system compatibility
rem    - installs the driver packages and registers the printers after you confirm
rem    - recreates the printer names / ports from the original configuration
rem    - prompts you to plug in USB printers, and checks network ports/connection
rem    - offers to print a test page after the printer is created
rem    - never overwrites existing printers, never changes the default printer,
rem      never deletes other drivers and never reboots the PC
rem
rem  This BAT is strictly ASCII (no Chinese) on purpose: cmd.exe decodes batch
rem  files with the OEM codepage, so non-ASCII bytes inside rem/echo lines can
rem  break parsing. All Chinese UI text lives in Printer_Migration.ps1, which is
rem  read by PowerShell as UTF-8 with BOM.
rem ===========================================================================
setlocal enableextensions
title Printer Restore - Program B - new PC
cd /d "%~dp0"

rem ---------------------------------------------------------------------------
rem Keep Windows PowerShell 5.1 module resolution clean (see program A for why).
rem ---------------------------------------------------------------------------
set "PSModulePath=%USERPROFILE%\Documents\WindowsPowerShell\Modules;%ProgramFiles%\WindowsPowerShell\Modules;%SystemRoot%\system32\WindowsPowerShell\v1.0\Modules"

set "CORE=%~dp0Printer_Migration.ps1"
set "DATA=%~dp0Printers.json"
set "PSExe=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSExe%" set "PSExe=powershell.exe"

if not exist "%CORE%" (
    echo.
    echo [ERROR] Printer_Migration.ps1 was not found in this folder.
    echo         This folder looks incomplete. Please re-copy the WHOLE
    echo         Printer_Backup folder produced by program A on the old PC.
    echo         Expected: "%CORE%"
    echo.
    pause
    exit /b 1
)

if not exist "%DATA%" (
    echo.
    echo [WARNING] Printers.json was not found in this folder.
    echo           Please copy the WHOLE Printer_Backup folder ^(not only some files^).
    echo           The program will still start and try to locate the backup data.
    echo.
)

rem ---------------------------------------------------------------------------
rem Execution policy handling (no bypass) - identical policy to program A.
rem ---------------------------------------------------------------------------
set "EP="
set "EPFILE=%TEMP%\Printer_Migration_ep.txt"
if exist "%EPFILE%" del "%EPFILE%" >nul 2>&1
"%PSExe%" -NoProfile -Command "Get-ExecutionPolicy" > "%EPFILE%" 2>nul
if exist "%EPFILE%" set /p EP=<"%EPFILE%"
if exist "%EPFILE%" del "%EPFILE%" >nul 2>&1
if not defined EP set "EP=Unknown"

set "EPFLAG="
if /i "%EP%"=="Restricted" set "EPFLAG=-ExecutionPolicy RemoteSigned"
if /i "%EP%"=="Undefined"  set "EPFLAG=-ExecutionPolicy RemoteSigned"
if /i "%EP%"=="Unknown"    set "EPFLAG=-ExecutionPolicy RemoteSigned"

if defined EPFLAG (
    echo.
    echo [INFO] PowerShell execution policy in effect: "%EP%" ^(Windows default^).
    echo [INFO] Using -ExecutionPolicy RemoteSigned for THIS process only, so that a
    echo [INFO] local unsigned script can run. Downloaded/blocked scripts stay
    echo [INFO] blocked, and any Group Policy setting still takes precedence.
    echo.
)

"%PSExe%" -NoProfile %EPFLAG% -File "%CORE%" -Action Restore %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo [INFO] The program exited with code %RC%.
    echo.
    echo [INFO] If PowerShell said that running scripts is disabled on this system,
    echo        this PC's execution policy is blocking .ps1 files. The tool does NOT
    echo        bypass it. Options:
    echo          1^) Ask IT / the owner of this PC to allow this folder, or sign the script; or
    echo          2^) Allow script files for YOUR user account only:
    echo                 powershell -NoProfile -Command "Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
    echo        Then double-click this BAT again.
    echo.
    echo [INFO] If the files came from a USB drive or a download and show as blocked,
    echo        right-click Printer_Migration.ps1 - Properties - Unblock.
    echo.
    pause
)

endlocal & exit /b %RC%
