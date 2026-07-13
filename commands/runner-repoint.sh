#!/usr/bin/env bash
# rig runner repoint — move an installed runner from one repository to another.
# Deregister, then re-register against the new repo, reusing the binary that is
# already on the box.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

log()  { printf 'rig-runner: %s\n' "$*"; }
warn() { printf 'rig-runner: WARNING: %s\n' "$*" >&2; }
die()  { printf 'rig-runner: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
usage: rig runner repoint --repo <owner/repo> [options]

  --repo <owner/repo>   the repository to move the runner TO (required)
  --name <name>         runner name (default: keep the name it has now)
  --labels <csv>        runner labels (default: the labels rig recorded at
                        install; else ci-runner)
  --user <name>         unprivileged service user (default: github-runner)
  --local               skip the server-side deregistration of the OLD repo
                        (no removal token needed) — leaves a stale offline
                        runner listed there, to delete by hand

Deregisters the runner from the repository it is on now and registers it
against --repo. The runner binary, its user, and its systemd service are
reused, so nothing is downloaded.

Two short-lived tokens, each minted from its OWN repository:

  RUNNER_REMOVE_TOKEN   removal token, from the CURRENT repo (not needed
                        with --local)
      gh api -X POST repos/<current>/actions/runners/remove-token
  RUNNER_TOKEN          registration token, from the repo in --repo
      gh api -X POST repos/<new>/actions/runners/registration-token

Either may be typed at the prompt instead. Both are collected BEFORE the
runner is touched — a token you turn out not to have should fail while the
runner is still registered, not halfway through the move. Neither is written
to disk by rig.

LABELS ARE NOT RECOVERABLE FROM THE BOX: GitHub holds them and the runner
does not persist them. rig records what it registered with, but a runner
installed before rig did that has nothing to read — repoint then falls back
to the ci-runner default and says so. Check your workflows' runs-on.

Convergent: repointing to the repo it is already on changes nothing, exits 0,
and never asks for a token.
EOF
}

# --- args (validated before the root check, so errors are testable) ---------
REPO=""
RUNNER_NAME=""
LABELS=""
RUNNER_USER="github-runner"
LOCAL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || die "--repo needs a value" 2
      REPO="$2"; shift 2 ;;
    --name)
      [ $# -ge 2 ] || die "--name needs a value" 2
      RUNNER_NAME="$2"; shift 2 ;;
    --labels)
      [ $# -ge 2 ] || die "--labels needs a value" 2
      LABELS="$2"; shift 2 ;;
    --user)
      [ $# -ge 2 ] || die "--user needs a value" 2
      RUNNER_USER="$2"; shift 2 ;;
    --local) LOCAL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown flag: $1" 2 ;;
  esac
done

# --- validation ------------------------------------------------------------
[ -n "$REPO" ] || die "--repo <owner/repo> is required" 2
if ! printf '%s' "$REPO" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
  die "--repo must be owner/repo" 2
fi
[ "$RUNNER_USER" != "root" ] || die "runner user must not be root" 2

# --- guards ----------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root"

id -u "$RUNNER_USER" >/dev/null 2>&1 \
  || die "no runner installed (no ${RUNNER_USER} user) — use: rig runner install"
USER_HOME="$(getent passwd "$RUNNER_USER" | cut -d: -f6)"
RUNNER_DIR="$USER_HOME/actions-runner"
[ -e "$RUNNER_DIR/.runner" ] \
  || die "no runner registered in ${RUNNER_DIR} — use: rig runner install"

# --- what is it registered to now? ------------------------------------------
json_field() {
  grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" \
    | head -n1 | sed 's/.*:[[:space:]]*"//; s/"$//'
}
CURRENT_URL="$(json_field "$RUNNER_DIR/.runner" gitHubUrl)"
TARGET_URL="https://github.com/${REPO}"

if [ "$CURRENT_URL" = "$TARGET_URL" ]; then
  log "already registered to ${REPO}; nothing to do"
  exit 0
fi

# Keep the runner's identity across the move unless told otherwise.
if [ -z "$RUNNER_NAME" ]; then
  RUNNER_NAME="$(json_field "$RUNNER_DIR/.runner" agentName)"
  [ -n "$RUNNER_NAME" ] || die "could not read the current runner name from ${RUNNER_DIR}/.runner"
fi
if [ -z "$LABELS" ]; then
  if [ -r "$RUNNER_DIR/.rig-labels" ]; then
    LABELS="$(cat "$RUNNER_DIR/.rig-labels")"
  else
    LABELS="ci-runner"
    warn "this box has no rig label record (installed before rig kept one)"
    warn "re-registering with the default labels: ${LABELS}"
    warn "if your workflows' runs-on expects anything else, ctrl-c and pass --labels"
  fi
fi

log "moving runner ${RUNNER_NAME} from ${CURRENT_URL} to ${TARGET_URL}"
log "labels: ${LABELS}"

# --- tokens, both up front --------------------------------------------------
# Collected before anything is torn down: a missing or expired token must fail
# while the runner is still registered and working.
if [ "$LOCAL" -eq 0 ]; then
  RUNNER_REMOVE_TOKEN="${RUNNER_REMOVE_TOKEN:-}"
  if [ -z "$RUNNER_REMOVE_TOKEN" ]; then
    read -rsp "removal token for ${CURRENT_URL} (short-lived): " RUNNER_REMOVE_TOKEN
    echo
  fi
  [ -n "$RUNNER_REMOVE_TOKEN" ] || die "empty removal token"
  export RUNNER_REMOVE_TOKEN
fi

RUNNER_TOKEN="${RUNNER_TOKEN:-}"
if [ -z "$RUNNER_TOKEN" ]; then
  read -rsp "registration token for ${TARGET_URL} (short-lived): " RUNNER_TOKEN
  echo
fi
[ -n "$RUNNER_TOKEN" ] || die "empty registration token"
export RUNNER_TOKEN

# --- move -------------------------------------------------------------------
REMOVE_ARGS=(--user "$RUNNER_USER")
[ "$LOCAL" -eq 1 ] && REMOVE_ARGS+=(--local)
"$HERE/runner-remove.sh" "${REMOVE_ARGS[@]}"

if ! "$HERE/runner-install.sh" \
  --repo "$REPO" --name "$RUNNER_NAME" --labels "$LABELS" --user "$RUNNER_USER"
then
  warn "the runner is now deregistered from ${CURRENT_URL} and NOT registered anywhere"
  die "re-registration failed — fix the cause, then run: rig runner install --repo ${REPO} --name ${RUNNER_NAME} --labels ${LABELS} --user ${RUNNER_USER}"
fi

log "repointed to ${TARGET_URL}"
log "verify it shows Idle under that repo's Settings > Actions > Runners, and gone from the old one"
