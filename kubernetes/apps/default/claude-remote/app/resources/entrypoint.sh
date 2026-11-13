#!/usr/bin/env bash
# Runs as root: install OS packages, create the claude user, then hand off to start.sh
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  bash-completion ca-certificates curl dnsutils git gnupg iputils-ping jq less libatomic1 \
  openssh-client procps python3 ripgrep tmux unzip vim-tiny xz-utils >/dev/null

id claude >/dev/null 2>&1 || useradd -u 1000 -U -d /home/claude -s /bin/bash claude
chown claude:claude /home/claude
# The /tmp emptyDir comes up world-writable without the sticky bit, and Claude Code then
# refuses to create its cross-session messaging socket there
chmod +t /tmp

exec runuser -u claude -- /scripts/start.sh
