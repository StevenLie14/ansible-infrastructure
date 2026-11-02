@echo off

REM Usage: run_forgejo_mirror.bat [repo-name]
REM   no arg   -> all repos in the org
REM   repo arg -> only that repo

set CONTAINER_NAME=ansible
set INVENTORY=inventory/hosts
set PLAYBOOK=playbook.yml
set TAGS=forgejo-mirror

set EXTRA=
if not "%~1"=="" set EXTRA=-e target_repo=%~1

docker exec -it ansible sh -c "ansible-playbook -i %INVENTORY% %PLAYBOOK% --tags %TAGS% %EXTRA%"
