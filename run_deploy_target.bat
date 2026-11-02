@echo off

REM Usage: run_deploy_target.bat [host]
REM   no arg   -> every host in deploy_targets
REM   host arg -> only that host (docker-apps, galaxion, syahdan)

set CONTAINER_NAME=ansible
set INVENTORY=inventory/hosts
set PLAYBOOK=playbook.yml
set TAGS=deploy-target

set EXTRA=
if not "%~1"=="" set EXTRA=--limit %~1

docker exec -it ansible sh -c "ansible-playbook -i %INVENTORY% %PLAYBOOK% --tags %TAGS% %EXTRA%"
