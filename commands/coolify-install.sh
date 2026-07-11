#!/usr/bin/env bash
# rig coolify install — pinned Coolify install; AUTOUPDATE=false so the
# platform never self-updates underneath its operators. Upgrades are an
# explicit act.
set -euo pipefail

log() { printf 'rig-coolify: %s\n' "$*"; }
die() { printf 'rig-coolify: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
usage: rig coolify install --version <pin>

Installs Coolify at exactly <pin> (e.g. 4.1.2) with AUTOUPDATE=false.
Control-plane box only. The version pin is required — you state the floor
your tooling is verified against; there is no default.
EOF
}

VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      [ $# -ge 2 ] || die "--version needs a value" 2
      VERSION="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown flag: $1" 2 ;;
  esac
done
if [ -z "$VERSION" ]; then
  usage >&2
  die "--version <pin> is required" 2
fi

[ "$(id -u)" -eq 0 ] || die "must run as root"

export AUTOUPDATE=false
log "installing coolify ${VERSION} (AUTOUPDATE=false)"
curl -fsSL https://cdn.coollabs.io/coolify/install.sh -o /tmp/coolify-install.sh
bash /tmp/coolify-install.sh "$VERSION"
log "coolify ${VERSION} installed with AUTOUPDATE=false"
log "next: your bootstrap runbook (admin user, API token, GitHub App, S3 destination)"
