#!/usr/bin/env bash
# rig runner status — what is this box's runner registered to?
# Read-only: reports what is already on the box. No credential, no network call.
set -euo pipefail

log() { printf 'rig-runner: %s\n' "$*"; }
die() { printf 'rig-runner: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
usage: rig runner status [--user <name>]

  --user <name>   unprivileged service user (default: github-runner)

Prints the repository this box's runner is registered to, its runner name,
the labels rig recorded when it registered, the install directory, and the
systemd unit and its state.

Reads only the runner's own on-disk config — no GitHub token, no network
call. Exits 1 when no runner is installed.
EOF
}

# --- args (validated before the root check, so errors are testable) ---------
RUNNER_USER="github-runner"
while [ $# -gt 0 ]; do
  case "$1" in
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

id -u "$RUNNER_USER" >/dev/null 2>&1 \
  || die "no runner installed (no ${RUNNER_USER} user on this box)"
USER_HOME="$(getent passwd "$RUNNER_USER" | cut -d: -f6)"
RUNNER_DIR="$USER_HOME/actions-runner"
[ -e "$RUNNER_DIR/.runner" ] \
  || die "no runner registered in ${RUNNER_DIR}"

# --- read the runner's own config -------------------------------------------
# .runner is JSON. Kept dependency-free on purpose: a rig-bootstrapped box has
# no jq, and installing one to read five fields would be a poor trade.
json_field() {
  grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" \
    | head -n1 | sed 's/.*:[[:space:]]*"//; s/"$//'
}

REPO_URL="$(json_field "$RUNNER_DIR/.runner" gitHubUrl)"
RUNNER_NAME="$(json_field "$RUNNER_DIR/.runner" agentName)"

# GitHub owns the labels; the runner does not persist them locally. rig records
# what it registered with, so a box installed before this existed reports the
# honest answer rather than a guess.
if [ -r "$RUNNER_DIR/.rig-labels" ]; then
  LABELS="$(cat "$RUNNER_DIR/.rig-labels")"
else
  LABELS="(not recorded on this box — GitHub holds them; see the repo's Settings > Actions > Runners)"
fi

if [ -r "$RUNNER_DIR/.service" ]; then
  UNIT="$(cat "$RUNNER_DIR/.service")"
  STATE="$(systemctl is-active "$UNIT" 2>/dev/null || true)"
  SERVICE="${UNIT} (${STATE:-unknown})"
else
  SERVICE="(not installed as a service)"
fi

log "repo:    ${REPO_URL:-unknown}"
log "name:    ${RUNNER_NAME:-unknown}"
log "labels:  ${LABELS}"
log "dir:     ${RUNNER_DIR}"
log "service: ${SERVICE}"
