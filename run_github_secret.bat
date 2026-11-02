@echo off
setlocal

REM Usage: run_github_secret.bat [--key NAME --secret VALUE] [--multiple] [--org NAME]
REM   no args      -> set every secret from host_vars on the repo in GITHUB_REPO_URL
REM   --key/--secret -> set only that one secret
REM   --multiple   -> apply to every non-archived repo owned by the account
REM   --org NAME   -> use that organization as the owner instead of GITHUB_REPO_URL

set CONTAINER_NAME=ansible
set INVENTORY=inventory/hosts
set PLAYBOOK=playbook.yml
set TAGS=secret

set KEY=
set SECRET=
set ALL=
set ORG=

:parse
if "%~1"=="" goto after_parse
if /i "%~1"=="--key" (
    set "KEY=%~2"
    shift
    shift
    goto parse
)
if /i "%~1"=="--secret" (
    set "SECRET=%~2"
    shift
    shift
    goto parse
)
if /i "%~1"=="--org" (
    set "ORG=%~2"
    shift
    shift
    goto parse
)
if /i "%~1"=="--multiple" (
    set "ALL=1"
    shift
    goto parse
)
echo Unknown argument: %~1
echo Usage: run_github_secret.bat [--key NAME --secret VALUE] [--multiple] [--org NAME]
exit /b 1

:after_parse
if not "%KEY%"=="" if "%SECRET%"=="" (
    echo --key requires --secret
    exit /b 1
)
if not "%SECRET%"=="" if "%KEY%"=="" (
    echo --secret requires --key
    exit /b 1
)

set EXTRA=
if not "%KEY%"=="" set EXTRA=-e target_secret_key=%KEY% -e target_secret_value=%SECRET%
if not "%ALL%"=="" set EXTRA=%EXTRA% -e target_all_repos=true
if not "%ORG%"=="" set EXTRA=%EXTRA% -e target_owner=%ORG%

docker exec -it %CONTAINER_NAME% sh -c "ansible-playbook -i %INVENTORY% %PLAYBOOK% --tags %TAGS% %EXTRA%"

endlocal
