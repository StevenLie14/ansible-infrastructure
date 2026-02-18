FROM python:3.12-slim

ARG ANSIBLE_VERSION=2.19.0

RUN pip install --no-cache-dir ansible-core==${ANSIBLE_VERSION}

RUN pip install --no-cache-dir passlib

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-client \
    git \
    && rm -rf /var/lib/apt/lists/*

RUN ansible-galaxy collection install ansible.posix
RUN ansible-galaxy role install robertdebock.harbor
RUN ansible-galaxy collection install community.docker

CMD ["bash"]