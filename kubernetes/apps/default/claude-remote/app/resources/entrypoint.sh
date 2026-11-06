#!/usr/bin/env bash
# Runs as root: install OS packages, create the claude user, then hand off to start.sh
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  bash-completion ca-certificates curl dnsutils git gnupg iputils-ping jq less \
  openssh-client procps python3 ripgrep tmux unzip vim-tiny xz-utils >/dev/null

id claude >/dev/null 2>&1 || useradd -u 1000 -U -d /home/claude -s /bin/bash claude
chown claude:claude /home/claude

exec runuser -u claude -- /scripts/start.sh
