#!/usr/bin/env bash
# rig bootstrap — OS plumbing for a pristine Debian box.
# Convergent: safe to re-run; a second run changes nothing.
set -euo pipefail

log()  { printf 'rig-bootstrap: %s\n' "$*"; }
warn() { printf 'rig-bootstrap: WARNING: %s\n' "$*" >&2; }
die()  { printf 'rig-bootstrap: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
usage: rig bootstrap <control-plane|workload> [--hostname <name>] [--ts-tag <tag>]

  --hostname  tailnet hostname (default: the role name)
  --ts-tag    tailnet tag to advertise (default: tag:server)

Provide the single-use tailscale pre-auth key via the TS_AUTHKEY env var, or
enter it at the interactive prompt. It is used once and never written to disk.
EOF
}

# --- args (validated before the root check, so errors are testable) ---------
ROLE="${1:-}"
case "$ROLE" in
  control-plane|workload) shift ;;
  -h|--help) usage; exit 0 ;;
  "") usage >&2; die "role required (control-plane|workload)" 2 ;;
  *) die "unknown role: $ROLE (want control-plane|workload)" 2 ;;
esac

TS_HOSTNAME="$ROLE"
TS_TAG="tag:server"
while [ $# -gt 0 ]; do
  case "$1" in
    --hostname)
      [ $# -ge 2 ] || die "--hostname needs a value" 2
      TS_HOSTNAME="$2"; shift 2 ;;
    --ts-tag)
      [ $# -ge 2 ] || die "--ts-tag needs a value" 2
      TS_TAG="$2"; shift 2 ;;
    *) die "unknown flag: $1" 2 ;;
  esac
done

# --- guards ------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root"
if [ -r /etc/os-release ]; then
  # shellcheck source=/dev/null
  . /etc/os-release
  case "${ID:-} ${ID_LIKE:-}" in
    *debian*) ;;
    *) warn "not a Debian-family system (ID=${ID:-unknown}); proceeding anyway" ;;
  esac
else
  warn "cannot read /etc/os-release; proceeding anyway"
fi

# --- pre-auth key (env override, else prompt; never touches disk) ------------
if [ -z "${TS_AUTHKEY:-}" ]; then
  read -rsp "tailscale pre-auth key (single-use, tagged, <=1h expiry): " TS_AUTHKEY
  echo
fi
[ -n "$TS_AUTHKEY" ] || die "empty pre-auth key"

# --- packages ----------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
log "installing base packages"
apt-get update -qq
apt-get install -y -qq curl ca-certificates unattended-upgrades

# enable periodic unattended upgrades (canonical file; idempotent overwrite)
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# --- sshd hardening (restart only when the drop-in actually changed) ---------
DROPIN=/etc/ssh/sshd_config.d/99-rig.conf
TMP="$(mktemp)"
cat > "$TMP" <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
EOF
if ! cmp -s "$TMP" "$DROPIN" 2>/dev/null; then
  install -m 0644 "$TMP" "$DROPIN"
  systemctl restart ssh
  log "sshd hardening drop-in installed"
else
  log "sshd hardening drop-in already in place"
fi
rm -f "$TMP"

# --- tailscale ----------------------------------------------------------------
if ! command -v tailscale >/dev/null 2>&1; then
  log "installing tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh
fi
if tailscale status >/dev/null 2>&1; then
  log "tailnet already joined; skipping tailscale up"
else
  log "joining tailnet as ${TS_HOSTNAME} (${TS_TAG})"
  tailscale up --authkey="$TS_AUTHKEY" --hostname="$TS_HOSTNAME" --advertise-tags="$TS_TAG"
fi

log "done — role ${ROLE}, hostname ${TS_HOSTNAME}"
if [ "$ROLE" = "control-plane" ]; then
  log "next: rig coolify install --version <pin>"
fi
