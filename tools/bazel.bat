@echo off
setlocal enabledelayedexpansion

if "%BAZEL_REAL%"=="" (
  echo error: bazel should be run through the .\bazelw.cmd script at the root of the repo 1>&2
  exit /b 1
)

set "SCRIPT_ROOT=%~dp0"
set "REPO_ROOT=%SCRIPT_ROOT%.."
set "BAZELRC_ROOT=%REPO_ROOT%\build"

REM Match against the whole command line rather than iterating tokens: cmd's
REM `for` treats "=" as a delimiter, which splits --config=build-mojo in two.
set "IS_BUILD_TEST_OR_RUN=false"
set "HAS_MOJO_CONFIG=false"

if "%~1"=="build" set "IS_BUILD_TEST_OR_RUN=true"
if "%~1"=="test" set "IS_BUILD_TEST_OR_RUN=true"
if "%~1"=="run" set "IS_BUILD_TEST_OR_RUN=true"

echo %*| findstr /C:"--config=build-mojo" >nul 2>&1
if not errorlevel 1 set "HAS_MOJO_CONFIG=true"
echo %*| findstr /C:"--config=prebuilt-mojo" >nul 2>&1
if not errorlevel 1 set "HAS_MOJO_CONFIG=true"

if exist "%REPO_ROOT%\local.bazelrc" (
  findstr /R /C:"config=prebuilt-mojo" /C:"config=build-mojo" "%REPO_ROOT%\local.bazelrc" >nul 2>&1
  if not errorlevel 1 set "HAS_MOJO_CONFIG=true"
)

if "%IS_BUILD_TEST_OR_RUN%"=="true" if "%HAS_MOJO_CONFIG%"=="false" (
  echo Please add `--config=build-mojo` to your command line.
  echo.
  echo On Windows, `--config=prebuilt-mojo` cannot work: it downloads a prebuilt
  echo Mojo toolchain, and no Windows build of that toolchain is published.
  echo Building the compiler from source is the only option on this platform.
  echo.
  echo You can add `build --config=build-mojo` to a `local.bazelrc` file to have
  echo it apply to all Bazel calls.
  exit /b 1
)

if not exist "%BAZELRC_ROOT%\logs" mkdir "%BAZELRC_ROOT%\logs"

if not exist "%BAZELRC_ROOT%\local-resources.bazelrc" (
  type nul > "%BAZELRC_ROOT%\local-resources.bazelrc"
)

set "WHO=%USERNAME%"
if not "%GITHUB_ACTOR%"=="" set "WHO=%GITHUB_ACTOR%"

> "%BAZELRC_ROOT%\wrapper.bazelrc" (
  echo # Generated from tools/bazel.cmd, do not edit.
  echo build --build_metadata=USER=%WHO%
  if "%GITHUB_REPOSITORY%"=="" echo build --config=disk-cache
  echo import %%workspace%%/build/local-resources.bazelrc
)

if exist "%BAZELRC_ROOT%\logs\execution.log" (
  move /y "%BAZELRC_ROOT%\logs\execution.log" "%BAZELRC_ROOT%\logs\execution-previous.log" >nul
)

"%BAZEL_REAL%" %*
exit /b %ERRORLEVEL%
