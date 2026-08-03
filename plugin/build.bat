@echo off
REM ---------------------------------------------------------------------------
REM Build the VRTouchEvents SKSE plugin (Skyrim VR, Release).
REM
REM Edit the two paths below for your own machine, or set them in the
REM environment before running this script.
REM
REM   VS_VCVARS   - your Visual Studio vcvars64.bat (needs the C++ workload)
REM   VCPKG_ROOT  - a vcpkg checkout (the VS-bundled one is fine)
REM
REM You also need CommonLibSSE-NG with VR enabled. Point CMake at it with
REM   -DCOMMONLIB_PATH="C:/path/to/CommonLibVR"
REM or edit the default in CMakeLists.txt. Built against CommonLibVR 4.14.0.
REM
REM Optional: -DMOD_OUTPUT="D:/MO2/mods/VRTouchEvents V3.0/SKSE/Plugins" copies
REM the DLL into your mod folder after every build.
REM
REM WARNING: the copy step fails silently if Skyrim is running (Windows locks
REM the loaded DLL) and its failure message does NOT contain the word "error".
REM Close the game before building, or md5 both paths afterwards.
REM ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0"

if not defined VS_VCVARS  set "VS_VCVARS=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
if not defined VCPKG_ROOT set "VCPKG_ROOT=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\vcpkg"

if not exist "%VS_VCVARS%" (
    echo [!] vcvars64.bat not found at "%VS_VCVARS%"
    echo     Set VS_VCVARS to your Visual Studio install and re-run.
    exit /b 1
)

call "%VS_VCVARS%" >nul

cmake --preset vr
if errorlevel 1 exit /b 1

cmake --build "%~dp0build\vr" --config Release
if errorlevel 1 exit /b 1

echo.
echo Built: build\vr\Release\VRTouchEvents.dll
endlocal
