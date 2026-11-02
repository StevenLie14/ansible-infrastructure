@echo off

set CONTAINER_NAME=ansible

docker exec -it ansible sh -c "bash scripts/gen-deploy-keys.sh"
