@echo off
rem ---------------------------------------------------------------------------
rem  Builds and runs the trilingual UI tests (tools\lang_tests.cpp).
rem  The settings file used by the tests lives in %TEMP%\PrtEasyBAK_lang_tests.
rem ---------------------------------------------------------------------------
setlocal enabledelayedexpansion
set "ROOT=%~dp0.."
set "OUT=%ROOT%\build"
if not exist "%OUT%" mkdir "%OUT%"

if not defined VCVARS64 (
    set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
    if not exist "!VSWHERE!" set "VSWHERE=%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe"
    if not exist "!VSWHERE!" (
        echo [ERROR] vswhere.exe not found. Install Visual Studio Build Tools with C++.
        exit /b 1
    )
    for /f "usebackq tokens=*" %%i in (`"!VSWHERE!" -latest -products * -property installationPath`) do set "VSPATH=%%i"
    if not defined VSPATH (
        echo [ERROR] No Visual Studio installation with C++ build tools was found.
        exit /b 1
    )
    set "VCVARS64=!VSPATH!\VC\Auxiliary\Build\vcvars64.bat"
)

call "%VCVARS64%" >nul
if errorlevel 1 exit /b 1

rem Regenerate the per-call-site case table when Node.js is available.
where node >nul 2>nul && node "%~dp0gen_lang_tests.js"

cd /d "%OUT%" || exit /b 1
echo Compiling language tests...
cl /nologo /utf-8 /std:c++17 /O2 /MT /EHsc /W3 /DUNICODE /D_UNICODE /DNOMINMAX ^
   "%ROOT%\tools\lang_tests.cpp" /Fe"lang_tests.exe" /link /SUBSYSTEM:CONSOLE
if errorlevel 1 exit /b 1

echo.
lang_tests.exe
exit /b %errorlevel%
