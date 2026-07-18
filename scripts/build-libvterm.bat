@echo off
REM Build libvterm for Windows x64 (output: ingot/libvterm/lib/windows_amd64/vterm.lib)

setlocal enabledelayedexpansion

set "INGOT_DIR=%~dp0.."
set "VENDOR_DIR=%INGOT_DIR%\vendor\libvterm"
set "SRC_DIR=%VENDOR_DIR%\src"
set "INC_DIR=%VENDOR_DIR%\include"
set "OUT_DIR=%INGOT_DIR%\libvterm\lib\windows_amd64"
set "OUT_LIB=%OUT_DIR%\vterm.lib"

REM Find Windows SDK version
set "SDK_ROOT=C:\Program Files (x86)\Windows Kits\10"
set "SDK_VER=10.0.26100.0"
if not exist "%SDK_ROOT%\Include\%SDK_VER%" set "SDK_VER=10.0.19041.0"
if not exist "%SDK_ROOT%\Include\%SDK_VER%" set "SDK_VER=10.0.17763.0"

REM Find MSVC installation
set "MSVC_ROOT=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC"
if not exist "%MSVC_ROOT%" set "MSVC_ROOT=C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Tools\MSVC"
if not exist "%MSVC_ROOT%" set "MSVC_ROOT=C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Tools\MSVC"
if not exist "%MSVC_ROOT%" (
    echo ERROR: MSVC not found
    exit /b 1
)

REM Find latest MSVC version
for /f "delims=" %%v in ('dir /b /ad /o-n "%MSVC_ROOT%" 2^>nul') do (
    set "MSVC_VER=%%v"
    goto :found_msvc
)
:found_msvc
if not defined MSVC_VER (
    echo ERROR: MSVC version not found
    exit /b 1
)

set "MSVC_BIN=%MSVC_ROOT%\%MSVC_VER%\bin\Hostx64\x64"
set "MSVC_INC=%MSVC_ROOT%\%MSVC_VER%\include"
set "MSVC_LIBS=%MSVC_ROOT%\%MSVC_VER%\lib\x64"

REM Manually set up paths
set "PATH=%MSVC_BIN%;%PATH%"
set "INCLUDE=%MSVC_INC%;%SDK_ROOT%\Include\%SDK_VER%\ucrt;%SDK_ROOT%\Include\%SDK_VER%\shared;%SDK_ROOT%\Include\%SDK_VER%\um"
set "LIB=%MSVC_LIBS%;%SDK_ROOT%\Lib\%SDK_VER%\ucrt\x64;%SDK_ROOT%\Lib\%SDK_VER%\um\x64"

echo Using MSVC: %MSVC_VER%
echo Using SDK: %SDK_VER%

echo Building libvterm for windows_amd64...
echo   Source:  %SRC_DIR%
echo   Include: %INC_DIR%
echo   Output:  %OUT_LIB%

if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"

REM Compile each C file
set OBJ_FILES=
for %%f in ("%SRC_DIR%\*.c") do (
    echo Compiling %%~nxf...
    "%MSVC_BIN%\cl.exe" /nologo /c /O2 /W3 /I"%INC_DIR%" /I"%SRC_DIR%" "%%f" /Fo"%OUT_DIR%\%%~nf.obj"
    if errorlevel 1 (
        echo ERROR: Failed to compile %%~nxf
        exit /b 1
    )
    set "OBJ_FILES=!OBJ_FILES! "%OUT_DIR%\%%~nf.obj""
)

REM Create static library
echo Linking...
"%MSVC_BIN%\lib.exe" /nologo /OUT:"%OUT_LIB%" %OBJ_FILES%
if errorlevel 1 (
    echo ERROR: Failed to create library
    exit /b 1
)

REM Clean up object files
for %%f in ("%OUT_DIR%\*.obj") do del "%%f"

echo SUCCESS: Created %OUT_LIB%
