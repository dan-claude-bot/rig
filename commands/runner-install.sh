#!/usr/bin/env bash
# rig runner install — GitHub Actions self-hosted runner as a systemd service
# under an unprivileged user. Outbound-only (long-poll to GitHub), no Docker.
# Convergent: safe to re-run; an already-registered runner is left alone.
set -euo pipefail

log()  { printf 'rig-runner: %s\n' "$*"; }
warn() { printf 'rig-runner: WARNING: %s\n' "$*" >&2; }
die()  { printf 'rig-runner: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
usage: rig runner install --repo <owner/repo> [options]

  --repo <owner/repo>   GitHub repository the runner registers to (required)
  --version <pin>       actions/runner release to install, e.g. 2.335.1
                        (default: the latest release, resolved at install
                        time — safe here because the runner self-updates
                        regardless; pin it when you need a deterministic,
                        auditable install)
  --name <name>         runner name (default: this host's hostname)
  --labels <csv>        runner labels; replaces the default (default: ci-runner)
  --user <name>         unprivileged service user (default: github-runner;
                        created if absent; never root)

Installs GitHub's official actions/runner as a systemd service under an
unprivileged user. The runner is an agent, not a server: it long-polls
GitHub outbound and needs ZERO inbound ports. No Docker is installed and
the runner user gets no supplementary groups.

Provide the short-lived registration token via the RUNNER_TOKEN env var or
the interactive prompt (get one from the repo's Settings > Actions >
Runners > "New self-hosted runner", or:
  gh api -X POST repos/<owner/repo>/actions/runners/registration-token).
It is consumed at registration and never written to disk by rig.
EOF
}

# --- args (validated before the root check, so errors are testable) ---------
REPO=""
VERSION=""
RUNNER_NAME="$(hostname)"
LABELS="ci-runner"
RUNNER_USER="github-runner"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || die "--repo needs a value" 2
      REPO="$2"; shift 2 ;;
    --version)
      [ $# -ge 2 ] || die "--version needs a value" 2
      VERSION="$2"; shift 2 ;;
    --name)
      [ $# -ge 2 ] || die "--name needs a value" 2
      RUNNER_NAME="$2"; shift 2 ;;
    --labels)
      [ $# -ge 2 ] || die "--labels needs a value" 2
      LABELS="$2"; shift 2 ;;
    --user)
      [ $# -ge 2 ] || die "--user needs a value" 2
      RUNNER_USER="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown flag: $1" 2 ;;
  esac
done

# --- validation ----------------------------------------------------------
[ -n "$REPO" ] || die "--repo <owner/repo> is required" 2
if ! printf '%s' "$REPO" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
  die "--repo must be owner/repo" 2
fi
VERSION="${VERSION#v}"
[ "$RUNNER_USER" != "root" ] || die "runner user must not be root" 2

# --- guards ----------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root"
if [ -r /etc/os-release ]; then
  # Sourced in a subshell: os-release defines VERSION (e.g. "13 (trixie)"),
  # which would clobber this script's $VERSION.
  # shellcheck source=/dev/null
  OS_FAMILY="$(. /etc/os-release && printf '%s %s' "${ID:-}" "${ID_LIKE:-}")"
  case "$OS_FAMILY" in
    *debian*) ;;
    *) warn "not a Debian-family system (${OS_FAMILY:-unknown}); proceeding anyway" ;;
  esac
else
  warn "cannot read /etc/os-release; proceeding anyway"
fi
command -v curl >/dev/null || die "curl is required (run rig bootstrap first)"

# --- registration token — only when registration is actually pending -------
# Pending unless the runner user already exists AND $RUNNER_DIR/.runner
# exists (user absent => nothing can be registered => pending).
REG_PENDING=1
if id -u "$RUNNER_USER" >/dev/null 2>&1; then
  USER_HOME="$(getent passwd "$RUNNER_USER" | cut -d: -f6)"
  RUNNER_DIR="$USER_HOME/actions-runner"
  if [ -e "$RUNNER_DIR/.runner" ]; then
    REG_PENDING=0
  fi
fi
if [ "$REG_PENDING" -eq 1 ]; then
  RUNNER_TOKEN="${RUNNER_TOKEN:-}"
  if [ -z "$RUNNER_TOKEN" ]; then
    read -rsp "runner registration token (short-lived): " RUNNER_TOKEN
    echo
  fi
  [ -n "$RUNNER_TOKEN" ] || die "empty registration token"
fi

# --- user --------------------------------------------------------------------
if ! id -u "$RUNNER_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$RUNNER_USER"
  log "created user ${RUNNER_USER}"
else
  log "user exists"
fi
USER_HOME="$(getent passwd "$RUNNER_USER" | cut -d: -f6)"
RUNNER_DIR="$USER_HOME/actions-runner"

# --- download + unpack ------------------------------------------------------
if [ -e "$RUNNER_DIR/bin/Runner.Listener" ]; then
  log "runner binary already present; skipping download (self-update owns upgrades)"
else
  case "$(uname -m)" in
    x86_64) ARCH="x64" ;;
    aarch64) ARCH="arm64" ;;
    *) die "unsupported arch: $(uname -m)" ;;
  esac
  if [ -z "$VERSION" ]; then
    # No pin given: resolve the latest release by following the redirect on
    # the /releases/latest page — no API call, no rate limit, no JSON to
    # parse on a dependency-free box.
    LATEST_URL="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
      https://github.com/actions/runner/releases/latest)" \
      || die "could not resolve the latest actions/runner release"
    VERSION="${LATEST_URL##*/}"
    VERSION="${VERSION#v}"
    case "$VERSION" in
      ""|*[!0-9.]*) die "could not parse a version from ${LATEST_URL}" ;;
    esac
    log "resolved latest actions/runner: ${VERSION}"
  fi
  URL="https://github.com/actions/runner/releases/download/v${VERSION}/actions-runner-linux-${ARCH}-${VERSION}.tar.gz"
  WORKDIR="$(mktemp -d)"
  cleanup() { rm -rf "$WORKDIR"; }
  trap cleanup EXIT
  log "downloading actions/runner ${VERSION} (${ARCH})"
  curl -fsSL "$URL" -o "$WORKDIR/runner.tar.gz"
  mkdir -p "$RUNNER_DIR"
  tar xzf "$WORKDIR/runner.tar.gz" -C "$RUNNER_DIR"
  chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR"
  log "installing runner native dependencies"
  "$RUNNER_DIR"/bin/installdependencies.sh
fi

# --- configure ---------------------------------------------------------------
if [ -e "$RUNNER_DIR/.runner" ]; then
  log "already registered; skipping configure"
else
  log "registering runner ${RUNNER_NAME} against ${REPO}"
  (cd "$RUNNER_DIR" && runuser -u "$RUNNER_USER" -- env HOME="$USER_HOME" \
    ./config.sh --url "https://github.com/${REPO}" --token "$RUNNER_TOKEN" \
    --name "$RUNNER_NAME" --labels "$LABELS" --unattended --replace)
  # GitHub owns the labels and the runner does not persist them locally, so
  # `runner status` and `runner repoint` would have nothing to read. Record
  # what we registered with — box-local metadata, never a credential.
  printf '%s\n' "$LABELS" > "$RUNNER_DIR/.rig-labels"
  chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR/.rig-labels"
fi

# --- service -------------------------------------------------------------
if [ ! -e "$RUNNER_DIR/.service" ]; then
  (cd "$RUNNER_DIR" && ./svc.sh install "$RUNNER_USER")
fi
(cd "$RUNNER_DIR" && ./svc.sh start)

log "runner ${RUNNER_NAME} (labels: ${LABELS}) installed and running"
log "verify it shows Idle under the repo's Settings > Actions > Runners"
log "the deny-all provider firewall stays the operator's job outside rig — this box needs no inbound ports for the runner"
