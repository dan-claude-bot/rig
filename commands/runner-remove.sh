#!/usr/bin/env bash
# rig runner remove — take the service down and deregister the runner.
# Convergent: a box with nothing installed exits 0.
set -euo pipefail

log()  { printf 'rig-runner: %s\n' "$*"; }
warn() { printf 'rig-runner: WARNING: %s\n' "$*" >&2; }
die()  { printf 'rig-runner: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
usage: rig runner remove [options]

  --local         wipe this box's registration without contacting GitHub
                  (no token needed)
  --user <name>   unprivileged service user (default: github-runner)

Stops and uninstalls the systemd service, then deregisters the runner from
GitHub. The runner binary and its user stay on the box, so a later
`rig runner install` re-registers without downloading anything.

Provide the short-lived REMOVAL token — not a registration token, they are
different endpoints — via the RUNNER_REMOVE_TOKEN env var or the interactive
prompt:
  gh api -X POST repos/<owner/repo>/actions/runners/remove-token
It is consumed at deregistration and never written to disk by rig.

--local is the escape hatch for when the registration is already gone
server-side, or you cannot mint a token: the box is cleaned, but a stale
offline runner is left listed in the repo — delete it by hand from
Settings > Actions > Runners.

Convergent: safe to re-run; a box with no runner installed exits 0.
EOF
}

# --- args (validated before the root check, so errors are testable) ---------
LOCAL=0
RUNNER_USER="github-runner"
while [ $# -gt 0 ]; do
  case "$1" in
    --local) LOCAL=1; shift ;;
    --user)
      [ $# -ge 2 ] || die "--user needs a value" 2
      RUNNER_USER="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown flag: $1" 2 ;;
  esac
done

# --- validation ------------------------------------------------------------
[ "$RUNNER_USER" != "root" ] || die "runner user must not be root" 2

# --- guards ----------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root"

# --- nothing to remove? -----------------------------------------------------
if ! id -u "$RUNNER_USER" >/dev/null 2>&1; then
  log "no ${RUNNER_USER} user on this box; nothing to remove"
  exit 0
fi
USER_HOME="$(getent passwd "$RUNNER_USER" | cut -d: -f6)"
RUNNER_DIR="$USER_HOME/actions-runner"
if [ ! -e "$RUNNER_DIR/.runner" ] && [ ! -e "$RUNNER_DIR/.service" ]; then
  log "no runner registered in ${RUNNER_DIR}; nothing to remove"
  exit 0
fi

# --- removal token — only when a server-side deregistration is pending -------
REMOVE_TOKEN=""
if [ -e "$RUNNER_DIR/.runner" ] && [ "$LOCAL" -eq 0 ]; then
  REMOVE_TOKEN="${RUNNER_REMOVE_TOKEN:-}"
  if [ -z "$REMOVE_TOKEN" ]; then
    read -rsp "runner removal token (short-lived): " REMOVE_TOKEN
    echo
  fi
  [ -n "$REMOVE_TOKEN" ] || die "empty removal token"
fi

# --- service ---------------------------------------------------------------
# This must come first in BOTH paths. config.sh's removal throws "Uninstall
# service first" while the service is configured; and `remove --local` skips
# that check entirely, which would otherwise strand a running service pointed
# at config that no longer exists.
if [ -e "$RUNNER_DIR/.service" ]; then
  log "stopping and uninstalling the service"
  (cd "$RUNNER_DIR" && ./svc.sh stop)
  (cd "$RUNNER_DIR" && ./svc.sh uninstall)
else
  log "no service installed; skipping"
fi

# --- deregister -------------------------------------------------------------
if [ -e "$RUNNER_DIR/.runner" ]; then
  if [ "$LOCAL" -eq 1 ]; then
    log "wiping the local registration only (--local)"
    (cd "$RUNNER_DIR" && runuser -u "$RUNNER_USER" -- env HOME="$USER_HOME" \
      ./config.sh remove --local)
    warn "a stale offline runner is still listed in the repo — delete it from Settings > Actions > Runners"
  else
    log "deregistering from GitHub"
    (cd "$RUNNER_DIR" && runuser -u "$RUNNER_USER" -- env HOME="$USER_HOME" \
      ./config.sh remove --token "$REMOVE_TOKEN")
  fi
  rm -f "$RUNNER_DIR/.rig-labels"
fi

log "runner removed; the binary stays at ${RUNNER_DIR} for a future rig runner install"
