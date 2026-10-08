@echo off
rem ===========================================================================
rem  Program A : backup entry            (run on the OLD / company PC)
rem  File name : 01 backup BAT  (this file)
rem
rem  What it does:
rem    - lists the printers installed on this PC
rem    - lets you pick which ones to back up
rem    - exports their driver packages with pnputil
rem    - verifies driver identity, file integrity (SHA256) and signature
rem    - creates a self-contained Printer_Backup folder that already contains
rem      the restore entry BAT and Printer_Migration.ps1
rem
rem  Then: copy the whole Printer_Backup folder to a USB drive, and on the new
rem  PC double-click the restore entry BAT inside that folder.
rem
rem  This BAT is strictly ASCII (no Chinese) on purpose: cmd.exe decodes batch
rem  files with the OEM codepage, so non-ASCII bytes inside rem/echo lines can
rem  break parsing. All Chinese UI text lives in Printer_Migration.ps1, which is
rem  read by PowerShell as UTF-8 with BOM.
rem ===========================================================================
setlocal enableextensions
title Printer Backup - Program A - old PC
cd /d "%~dp0"

rem ---------------------------------------------------------------------------
rem Keep Windows PowerShell 5.1 module resolution clean. If PowerShell 7 module
rem paths are present in PSModulePath, Windows PowerShell 5.1 may try to load
rem the PowerShell 7 copies of its own built-in modules and fail.
rem Scoped to this process only (setlocal).
rem ---------------------------------------------------------------------------
set "PSModulePath=%USERPROFILE%\Documents\WindowsPowerShell\Modules;%ProgramFiles%\WindowsPowerShell\Modules;%SystemRoot%\system32\WindowsPowerShell\v1.0\Modules"

set "CORE=%~dp0Printer_Migration.ps1"
set "PSExe=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSExe%" set "PSExe=powershell.exe"

if not exist "%CORE%" (
    echo.
    echo [ERROR] Printer_Migration.ps1 was not found next to this file.
    echo         Keep these three files in the SAME folder:
    echo             file 1 = the 01 backup BAT  ^[this file^]
    echo             file 2 = the 02 restore BAT
    echo             file 3 = Printer_Migration.ps1
    echo         Expected: "%CORE%"
    echo.
    pause
    exit /b 1
)

rem ---------------------------------------------------------------------------
rem Execution policy handling (no bypass).
rem Windows client default is "Restricted", which blocks every .ps1 file, so the
rem tool could not start at all. We therefore:
rem   * first read the policy that is ACTUALLY in effect on this PC;
rem   * only if it is the Windows default (Restricted/Undefined) do we add
rem     "-ExecutionPolicy RemoteSigned" for THIS process only, which still
rem     refuses downloaded/blocked scripts;
rem   * if the policy is set by Group Policy (company PC), Windows ignores the
rem     parameter, so the company setting always wins. We never use Bypass and
rem     never modify any policy ourselves.
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

"%PSExe%" -NoProfile %EPFLAG% -File "%CORE%" -Action Backup %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo [INFO] The program exited with code %RC%.
    echo.
    echo [INFO] If PowerShell said that running scripts is disabled on this system,
    echo        this PC's execution policy is blocking .ps1 files. The tool does NOT
    echo        bypass it. Options:
    echo          1^) Ask IT to allow this folder, or to sign the script; or
    echo          2^) Allow script files for YOUR user account only ^(may be blocked
    echo             by Group Policy^):
    echo                 powershell -NoProfile -Command "Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
    echo        Then double-click this BAT again.
    echo.
    echo [INFO] If the file was copied from a network share and shows as blocked,
    echo        right-click Printer_Migration.ps1 - Properties - Unblock.
    echo.
    pause
)

endlocal & exit /b %RC%
