#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

function main() {
    check_env KUBECONFIG TALOSCONFIG SOPS_AGE_KEY_FILE
    check_cli op

    if ! op user get --me &>/dev/null; then
        log error "Failed to authenticate with 1Password CLI"
    fi

    op read --out-file $TALOSCONFIG op://kubernetes/k8s-home-secrets/talosconfig
    op read --out-file $KUBECONFIG op://kubernetes/k8s-home-secrets/kubeconfig
    op read --out-file $SOPS_AGE_KEY_FILE op://kubernetes/k8s-home-secrets/age.key

    log info "Secrets have been imported!"
}

main "$@"