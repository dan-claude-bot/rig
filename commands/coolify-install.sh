#!/usr/bin/env bash
# rig coolify install — pinned Coolify install; AUTOUPDATE=false so the
# platform never self-updates underneath its operators. Upgrades are an
# explicit act.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/users-config.sh
. "$HERE/lib/users-config.sh"   # read_role_marker — the traits line bootstrap wrote

log()  { printf 'rig-coolify: %s\n' "$*"; }
warn() { printf 'rig-coolify: WARNING: %s\n' "$*" >&2; }
die()  { printf 'rig-coolify: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

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

# --- role-marker sanity (issue #25) ------------------------------------------
# Coolify belongs on the control-plane box and nowhere else — but the marker is
# ADVISORY, never a gate. It may legitimately be absent (a box bootstrapped
# before rig wrote markers, or a hand-built one), and rig refuses to guess from
# silence. When the marker EXISTS and names another role, the likeliest story
# is an operator in the wrong SSH session about to put a control plane on a
# workload box — so say it loudly. But WARN, never die: the operator may also
# be deliberately repurposing the box, and an advisory file must never outrank
# the human running the command (contrast close-root, where the marker IS the
# gate — shutting the root door blind is irreversible in a way an extra
# Coolify is not). Placed BEFORE the root check for the same reason arg errors
# are: the harness proves it non-root, and reading a 0644 file needs no
# privilege. RIG_ROLE_MARKER overrides the path so tests point it at fixtures
# (repo precedent: users-apply, users-close-root).
MARKER_LINE="$(read_role_marker "${RIG_ROLE_MARKER:-/etc/rig/role}")"
case "$MARKER_LINE" in
  ""|"role=control-plane"|"role=control-plane "*) ;;
  *) warn "this box's role marker says '${MARKER_LINE}' — not a control-plane box. Coolify belongs on role control-plane; if this is the wrong box, stop here and re-check your SSH session. Repurposing it on purpose? Re-run 'rig bootstrap control-plane' first so the marker tells the truth." ;;
esac

[ "$(id -u)" -eq 0 ] || die "must run as root"

export AUTOUPDATE=false
log "installing coolify ${VERSION} (AUTOUPDATE=false)"
curl -fsSL https://cdn.coollabs.io/coolify/install.sh -o /tmp/coolify-install.sh
bash /tmp/coolify-install.sh "$VERSION"
log "coolify ${VERSION} installed with AUTOUPDATE=false"
log "next: rig coolify backup install  (nightly control-plane dump — do this before the box holds anything)"
log "then: your bootstrap runbook (admin user, API token, GitHub App, S3 destination)"
