#!/usr/bin/env bash
# Runs as claude (uid 1000). $HOME is the PVC, so tools, the login and the repo survive restarts.
set -uo pipefail

export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
export GITHUB_TOKEN="$GH_TOKEN"
REPO="$HOME/k8s-home"

# CLIs via mise; mise and claude self-update in place
[ -x "$HOME/.local/bin/mise" ] || curl -fsSL https://mise.run | sh
mise use -g --quiet kubectl flux2 talos gh helm kustomize yq just sops age
[ -x "$HOME/.local/bin/claude" ] || curl -fsSL https://claude.ai/install.sh | bash

# Git over HTTPS with the PAT
gh auth setup-git
git config --global user.name jsimcina
git config --global user.email jsimcina@gmail.com
[ -d "$REPO/.git" ] || git clone -q https://github.com/jsimcina/k8s-home "$REPO"
git -C "$REPO" pull -q --ff-only || true
mise trust -q "$REPO"

# The repo's mise env points KUBECONFIG/TALOSCONFIG at these gitignored files
cat >"$REPO/kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: home
    cluster:
      server: https://kubernetes.default.svc
      certificate-authority: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
users:
  - name: claude-remote
    user:
      tokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
contexts:
  - name: home
    context: {cluster: home, user: claude-remote}
current-context: home
EOF
install -m 0600 /secrets/talosconfig "$REPO/talosconfig"
# shellcheck disable=SC2016 # written literally for interactive shells
grep -q 'mise activate' "$HOME/.bashrc" 2>/dev/null || echo 'eval "$(~/.local/bin/mise activate bash)"' >>"$HOME/.bashrc"

# MCP servers and plugins (re-applied each start so token rotations take effect)
claude mcp remove --scope user unifi >/dev/null 2>&1 || true
claude mcp add --scope user --transport http unifi "$UNIFI_MCP_URL" \
  --header "Authorization: Bearer $UNIFI_MCP_TOKEN" >/dev/null
claude plugin marketplace add eleboucher/memini >/dev/null 2>&1 || true
claude plugin marketplace add sirkirby/unifi-mcp >/dev/null 2>&1 || true
claude plugin install memini@memini >/dev/null 2>&1 || true
claude plugin install unifi-network@unifi-plugins >/dev/null 2>&1 || true

echo "ready; attach with: kubectl -n default exec -it deploy/claude-remote -- runuser -u claude -- tmux attach -t rc"

# Keep Remote Control running in tmux (it needs a TTY for first-run prompts).
# Until `claude auth login` has been done once, just wait.
while true; do
  if [ -f "$HOME/.claude/.credentials.json" ] && ! tmux has-session -t rc 2>/dev/null; then
    tmux new-session -d -s rc -c "$REPO" \
      "claude remote-control --name k8s-home --spawn worktree; echo 'remote-control exited'; sleep 10"
  fi
  sleep 30
done
