#!/usr/bin/env bash
# Runs as root under tini: install OS packages, run setup.sh as paseo, then start the daemon
# through the image's own entrypoint (which drops to paseo with gosu)
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  bash-completion ca-certificates curl dnsutils git gnupg iputils-ping jq less libatomic1 \
  openssh-client procps python3 ripgrep tmux unzip vim-tiny xz-utils >/dev/null

chown paseo:paseo /home/paseo
# Tool installs are best effort: the daemon still starts if a download fails
gosu paseo /scripts/setup.sh || echo "[paseo] setup.sh failed; starting the daemon anyway" >&2

# Agents inherit the daemon's PATH, so put the PVC's claude and mise tools on it
export PATH="/home/paseo/.local/bin:/home/paseo/.local/share/mise/shims:$PATH"
exec /usr/local/bin/paseo-docker-entrypoint
