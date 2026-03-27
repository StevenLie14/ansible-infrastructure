@echo off

set CONTAINER_NAME=ansible
set INVENTORY=inventory/hosts
set PLAYBOOK=playbook.yml
set NGINX_TAGS=nginx

docker exec -it ansible sh -c "ansible-playbook -i "%INVENTORY%" "%PLAYBOOK%" --tags %NGINX_TAGS% "


