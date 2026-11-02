@echo off

REM Usage: use_env.bat private|slc
REM   Copies .env.<profile> to .env and recreates the ansible container so it
REM   picks up the new values.

if "%~1"=="" goto usage
if not exist ".env.%~1" (
    echo .env.%~1 not found
    goto usage
)

copy /Y ".env.%~1" ".env" >nul
echo Active profile: %~1
docker compose up -d
exit /b 0

:usage
echo Usage: use_env.bat private^|slc
exit /b 1
