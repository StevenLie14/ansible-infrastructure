# DevOps — Ansible Infrastructure Automation

This repository provides an **Ansible control container** (built from the included `Dockerfile`) and playbooks/roles to automate provisioning and configuration of a self-hosted DevOps infrastructure.

---

## What This Does

The playbook (`playbook.yml`) manages the following via tags:

| Tag | Description |
|---|---|
| `runner` | Register a **GitHub Actions self-hosted runner** on a remote host |
| `secret` | Inject **GitHub repository-level secrets** |
| `docker` | Install and configure **Docker** on the remote host |
| `certbot` | Install **Certbot** and the Nginx plugin for TLS certificate management |
| `harbor` | Deploy **Harbor** private container registry |
| `forgejo` | Deploy **Forgejo** (self-hosted Git service) via Docker Compose |
| `forgejo-secret` | Inject **Forgejo repository-level secrets** |
| `forgejo-runner` | Register a **Forgejo Actions runner** on a remote host |
| `forgejo-mirror` | Configure **repository mirroring** in Forgejo |
| `nginx` | Deploy an **Nginx reverse proxy** with automatic SSL via Certbot |

---

## Overview

* Since **Windows cannot run Ansible natively**, this repository uses **Docker Compose** to start a container with Ansible pre-installed.
* The control container is built with `Dockerfile` (Ubuntu + Python + `ansible-core` + collections).
* The repository is mounted at `/workdir` inside the container.
* All sensitive values are read from a `.env` file and passed to Ansible via environment lookups.

---

## Prerequisites

* Docker and Docker Compose installed on the host machine (Linux, macOS, or Windows).
* A remote Linux server accessible via SSH.
* A [**GitHub PAT**](https://github.com/settings/personal-access-tokens) with permissions to register self-hosted runners and manage secrets (for GitHub roles).
* A Forgejo admin token (for Forgejo roles).

---

## Environment Variables

Copy `.env.example` to `.env` and fill in the required values.

### GitHub / Runner

| Variable | Description |
|---|---|
| `ANSIBLE_HOST` | Target host IP or hostname |
| `ANSIBLE_USER` / `ANSIBLE_PASS` | SSH credentials for the target host |
| `ANSIBLE_HOST_KEY_CHECKING` | Set to `False` to disable SSH host key checking |
| `GITHUB_PAT` | GitHub personal access token for runner registration |
| `GITHUB_REPO_URL` | Repository URL where the runner will be registered |
| `RUNNER_USER` | Linux account to create for the GitHub runner |

### Harbor

| Variable | Description |
|---|---|
| `HARBOR_ADMIN_PASSWORD` | Initial Harbor admin password |
| `HARBOR_HTTP_PORT` | HTTP port for Harbor (default `80`) |
| `HARBOR_HTTPS_PORT` | HTTPS port for Harbor (default `443`) |
| `REGISTRY_URL` | Harbor URL (without `https://`) |
| `REGISTRY_USERNAME` | Registry username |
| `REGISTRY_PASSWORD` | Registry password |

### HashiCorp Vault (optional)

| Variable | Description |
|---|---|
| `VAULT_URL` | Vault server URL |
| `VAULT_USERNAME` | Vault username |
| `VAULT_PASSWORD` | Vault password |
| `VAULT_PATH` | Path in Vault where secrets are stored |

### Nginx / Certbot

| Variable | Description |
|---|---|
| `CERTBOT_ADMIN_EMAIL` | Email for Let's Encrypt certificate registration |

---

## Adding Custom Secrets

### GitHub Secrets

Add the variable in `.env`:

```env
MY_SECRET_KEY=my_secret_value
```

Then map it in `inventory/host_vars/github-actions-secret.yml`:

```yaml
secrets:
  - name: "MY_SECRET_KEY"
    value: "{{ lookup('env', 'MY_SECRET_KEY') }}"
```

### Forgejo Secrets

Same pattern — add to `.env` and map in `inventory/host_vars/forgejo-actions-secret.yml`.

⚠️ **After changing `.env` values**, rebuild the container to apply them:

```bash
docker-compose up -d --build
```

---

## Setup and Run

1. Copy and configure `.env`:

   ```bash
   cp .env.example .env
   ```

2. Build and start the Ansible control container:

   ```bash
   docker-compose up -d --build
   ```

3. Run playbooks inside the container:

   ```bash
   # GitHub Actions runner
   ansible-playbook -i inventory/hosts/hosts.yml playbook.yml --tags runner

   # GitHub repository secrets
   ansible-playbook -i inventory/hosts/hosts.yml playbook.yml --tags secret

   # Install Docker
   ansible-playbook -i inventory/hosts/hosts.yml playbook.yml --tags docker

   # Install Certbot + Nginx
   ansible-playbook -i inventory/hosts/hosts.yml playbook.yml --tags certbot

   # Deploy Harbor
   ansible-playbook -i inventory/hosts/hosts.yml playbook.yml --tags harbor

   # Deploy Forgejo
   ansible-playbook -i inventory/hosts/hosts.yml playbook.yml --tags forgejo

   # Forgejo secrets
   ansible-playbook -i inventory/hosts/hosts.yml playbook.yml --tags forgejo-secret

   # Forgejo Actions runner
   ansible-playbook -i inventory/hosts/hosts.yml playbook.yml --tags forgejo-runner

   # Forgejo mirror
   ansible-playbook -i inventory/hosts/hosts.yml playbook.yml --tags forgejo-mirror

   # Nginx reverse proxy + SSL
   ansible-playbook -i inventory/hosts/hosts.yml playbook.yml --tags nginx
   ```

---

## Inventory and Variables

* **Inventory file**: `inventory/hosts/hosts.yml` — uses environment lookups for sensitive values.
* **Host-specific variables** under `inventory/host_vars/`:
  * `github-actions-runner.yml` — runner repo URL and related settings
  * `github-actions-secret.yml` — GitHub secrets to inject
  * `harbor.yml` — Harbor deployment config
  * `forgejo.yml` — Forgejo deployment config
  * `forgejo-actions-secret.yml` — Forgejo secrets to inject
  * `forgejo-actions-runner.yml` — Forgejo runner config
  * `forgejo-mirror.yml` — Mirror source/target config
  * `nginx.yml` — Domain name, ports, and certbot email

---

## Notes on Harbor Admin Account

* `HARBOR_ADMIN_PASSWORD` is only valid for the **first login**.
* After first login: create a new user, assign it as administrator, and stop using the `admin` account.

### Recovery (if admin account is lost)

SSH into the server and reset via the database:

```bash
cd /home/harbor
docker exec -it harbor-db psql -U postgres
\c registry
update harbor_user set salt='', password='' where user_id = 1;
```

Then restart Harbor:

```bash
docker-compose down -v
docker-compose up -d
```
