@echo off
rem ---------------------------------------------------------------------------
rem  Build PrtEasyBAK.exe with the project's native toolchain (MSVC / Win32 API).
rem
rem  Key flags:
rem    /utf-8      source files are UTF-8; keeps every Chinese literal intact
rem    /std:c++17  std::filesystem
rem    /MT         static CRT -> one portable EXE, no VC++ redistributable needed
rem    /DNOMINMAX  keep std::max / std::min usable alongside <windows.h>
rem    /SUBSYSTEM:WINDOWS  GUI application (entry point is wWinMain)
rem
rem  Output: build\PrtEasyBAK.exe
rem ---------------------------------------------------------------------------
setlocal enabledelayedexpansion
set "ROOT=%~dp0"
set "OUT=%ROOT%build"
if not exist "%OUT%" mkdir "%OUT%"

if not defined VCVARS64 (
    set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
    if not exist "!VSWHERE!" set "VSWHERE=%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe"
    if not exist "!VSWHERE!" (
        echo [ERROR] vswhere.exe not found.
        echo         Install Visual Studio 2019/2022 Build Tools with "Desktop development with C++".
        exit /b 1
    )
    for /f "usebackq tokens=*" %%i in (`"!VSWHERE!" -latest -products * -property installationPath`) do set "VSPATH=%%i"
    if not defined VSPATH (
        echo [ERROR] No Visual Studio installation with C++ build tools was found.
        exit /b 1
    )
    set "VCVARS64=!VSPATH!\VC\Auxiliary\Build\vcvars64.bat"
)

if not exist "%VCVARS64%" (
    echo [ERROR] vcvars64.bat not found: %VCVARS64%
    exit /b 1
)

echo Using toolchain: %VCVARS64%
call "%VCVARS64%" >nul
if errorlevel 1 exit /b 1

cd /d "%OUT%" || exit /b 1

echo [1/3] Compiling resources...
rc /nologo /fo "PrtEasyBAK.res" "%ROOT%PrtEasyBAK.rc"
if errorlevel 1 exit /b 1

echo [2/3] Compiling PrtEasyBAK.cpp...
cl /nologo /utf-8 /std:c++17 /O2 /MT /EHsc /W3 /DUNICODE /D_UNICODE /DNOMINMAX ^
   "%ROOT%PrtEasyBAK.cpp" "PrtEasyBAK.res" ^
   /Fe"PrtEasyBAK.exe" /link /SUBSYSTEM:WINDOWS
if errorlevel 1 exit /b 1

echo [3/3] Done. Verifying output...
if not exist "PrtEasyBAK.exe" (
    echo [ERROR] PrtEasyBAK.exe was not produced.
    exit /b 1
)
for %%f in ("PrtEasyBAK.exe") do echo       Size: %%~zf bytes
certutil -hashfile "PrtEasyBAK.exe" SHA256 | findstr /r /v "hash CertUtil"

echo.
echo Build succeeded: %OUT%\PrtEasyBAK.exe
exit /b 0
