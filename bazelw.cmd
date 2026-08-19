@echo off
setlocal enabledelayedexpansion

set "VERSION=1.27.0"

if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" ( set "PLATFORM=windows-arm64" ) else (
  if /i "%PROCESSOR_ARCHITEW6432%"=="ARM64" ( set "PLATFORM=windows-arm64" ) else ( set "PLATFORM=windows-amd64" )
)

set "SCRIPT_ROOT=%~dp0"
set "EXECUTABLE=%SCRIPT_ROOT%build\bazelisk-%VERSION%-%PLATFORM%.exe"

if not exist "%EXECUTABLE%" (
  echo Installing bazelisk... 1>&2
  if not exist "%SCRIPT_ROOT%build" mkdir "%SCRIPT_ROOT%build"
  curl --fail -L --retry 5 --retry-connrefused --silent --output "%EXECUTABLE%" ^
    "https://github.com/bazelbuild/bazelisk/releases/download/v%VERSION%/bazelisk-%PLATFORM%.exe"
  if errorlevel 1 (
    echo error: failed to download bazelisk 1>&2
    if exist "%EXECUTABLE%" del /q "%EXECUTABLE%"
    exit /b 1
  )
)

set "BAZEL=%EXECUTABLE%"
"%EXECUTABLE%" %*
exit /b %ERRORLEVEL%
