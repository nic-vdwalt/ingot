@echo off
setlocal

set "EXAMPLE_ROOT=%~dp0"
for %%I in ("%EXAMPLE_ROOT%..\..") do set "REPO_ROOT=%%~fI"
set "BUILD_DIR=%EXAMPLE_ROOT%build"
set "HOST=%EXAMPLE_ROOT%ingot_hot_reload.exe"
set "GAME_RUNNING=false"

for /f "tokens=1" %%P in ('tasklist /nh /fi "imagename eq ingot_hot_reload.exe"') do (
	if /i "%%P"=="ingot_hot_reload.exe" set "GAME_RUNNING=true"
)

if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"
echo Building game.dll
odin build "%EXAMPLE_ROOT%game" "-collection:ingot=%REPO_ROOT%" -build-mode:dll ^
	"-out:%BUILD_DIR%\game_tmp.dll" -debug -vet -strict-style -vet-shadowing
if errorlevel 1 exit /b 1
move /y "%BUILD_DIR%\game_tmp.dll" "%BUILD_DIR%\game.dll" >nul
if errorlevel 1 exit /b 1

if "%GAME_RUNNING%"=="true" (
	echo Hot reloading...
	exit /b 0
)

echo Building ingot_hot_reload.exe
odin build "%EXAMPLE_ROOT%host" "-collection:ingot=%REPO_ROOT%" "-out:%HOST%" ^
	-debug -vet -strict-style -vet-shadowing
if errorlevel 1 exit /b 1

if /i "%~1"=="run" (
	echo Running ingot_hot_reload.exe
	start "" "%HOST%"
)
