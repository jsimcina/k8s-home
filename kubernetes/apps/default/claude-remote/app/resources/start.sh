#!/usr/bin/env bash
# Runs as claude (uid 1000). $HOME is the PVC, so tools, the login and the repo survive restarts.
set -uo pipefail

export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
export GITHUB_TOKEN="$GH_TOKEN"
REPO="$HOME/k8s-home"
DOCS="$HOME/home-docs" # private network/device docs

# CLIs via mise; mise and claude self-update in place
[ -x "$HOME/.local/bin/mise" ] || curl -fsSL https://mise.run | sh
# node runs plugin hooks and memini's MCP header helper; uv runs the unifi-network plugin
mise use -g --quiet kubectl flux2 talos gh helm kustomize yq just sops age node@lts uv
[ -x "$HOME/.local/bin/claude" ] || curl -fsSL https://claude.ai/install.sh | bash

# Git over HTTPS with the PAT
gh auth setup-git
git config --global user.name jsimcina
git config --global user.email jsimcina@gmail.com
[ -d "$REPO/.git" ] || git clone -q https://github.com/jsimcina/k8s-home "$REPO"
git -C "$REPO" pull -q --ff-only || true
[ -d "$DOCS/.git" ] || git clone -q https://github.com/jsimcina/home-docs "$DOCS"
git -C "$DOCS" pull -q --ff-only || true
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
# Shells from `kubectl exec` (login or not) get the same PATH and tools
# shellcheck disable=SC2016 # written literally for interactive shells
grep -q 'mise activate' "$HOME/.bashrc" 2>/dev/null || printf '%s\n' \
  'export PATH="$HOME/.local/bin:$PATH"' 'eval "$(~/.local/bin/mise activate bash)"' >>"$HOME/.bashrc"
[ -f "$HOME/.bash_profile" ] || echo '. ~/.bashrc' >"$HOME/.bash_profile"

# MCP servers and plugins (re-applied each start so token rotations take effect)
claude mcp remove --scope user unifi >/dev/null 2>&1 || true
claude mcp add --scope user --transport http unifi "$UNIFI_MCP_URL" \
  --header "Authorization: Bearer $UNIFI_MCP_TOKEN" >/dev/null
claude mcp remove --scope user unifi-2 >/dev/null 2>&1 || true
claude mcp add --scope user --transport http unifi-2 "$UNIFI2_MCP_URL" \
  --header "Authorization: Bearer $UNIFI2_MCP_TOKEN" >/dev/null
# Plugin MCP header helpers don't inherit *_API_KEY env vars, so memini reads its key from this file
mkdir -p "$HOME/.config/memini"
(umask 077 && jq -n --arg u "$MEMINI_BASE_URL" --arg k "$MEMINI_API_KEY" --arg t "$(date -u +%FT%TZ)" \
  '{version: 1, credentials: {($u): {api_key: $k, updated_at: $t}}}' >"$HOME/.config/memini/credentials")
claude plugin marketplace add eleboucher/memini >/dev/null 2>&1 || true
claude plugin marketplace add sirkirby/unifi-mcp >/dev/null 2>&1 || true
claude plugin install memini@memini >/dev/null 2>&1 || true
claude plugin install unifi-network@unifi-plugins >/dev/null 2>&1 || true
# Pre-approve memini's tools so agents don't prompt for every memory read or write; deleting a
# memory (memory_forget) still asks
settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
[ -f "$settings" ] || echo '{}' >"$settings"
jq '.permissions.allow = ((.permissions.allow // []) + [
  "mcp__plugin_memini_memini__memory_briefing", "mcp__plugin_memini_memini__memory_recall",
  "mcp__plugin_memini_memini__memory_get", "mcp__plugin_memini_memini__memory_list",
  "mcp__plugin_memini_memini__memory_history", "mcp__plugin_memini_memini__memory_remember",
  "mcp__plugin_memini_memini__memory_update"
] | unique)' "$settings" >"$settings.tmp" && mv "$settings.tmp" "$settings"
# Same gates as the in-cluster unifi-mcp, at the plugin's coarser granularity; every mutation previews first
jq -n --arg h "$UNIFI_CONTROLLER_HOST" --arg u "$UNIFI_CONTROLLER_USERNAME" '{
  host: $h, username: $u, password_file: "/secrets/unifi-password", api_key_file: "/secrets/unifi-api-key",
  site: "default", verify_ssl: "false", permission_mode: "confirm",
  policy_create: "false", policy_update: "true", policy_delete: "true"
}' | claude plugin configure unifi-network@unifi-plugins --values-stdin >/dev/null 2>&1 || true

echo "ready; attach with: kubectl -n default exec -it deploy/claude-remote -- runuser -u claude -- tmux attach -t rc"

# Keep one Remote Control server per repo running in tmux (it needs a TTY for
# first-run prompts). Until `claude auth login` has been done once, just wait.
rc() { # tmux session, server name, directory
  tmux has-session -t "$1" 2>/dev/null && return
  tmux new-session -d -s "$1" -c "$3" \
    "claude remote-control --name $2 --spawn worktree; echo 'remote-control exited'; sleep 10"
}
while true; do
  if [ -f "$HOME/.claude/.credentials.json" ]; then
    rc rc k8s-home "$REPO"
    [ -d "$DOCS/.git" ] && rc rc-docs home-docs "$DOCS"
  fi
  sleep 30
done
