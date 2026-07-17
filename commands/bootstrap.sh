#!/usr/bin/env bash
# rig bootstrap — OS plumbing for a pristine Debian box.
# Convergent: safe to re-run; a second run changes nothing.
set -euo pipefail

log()  { printf 'rig-bootstrap: %s\n' "$*"; }
warn() { printf 'rig-bootstrap: WARNING: %s\n' "$*" >&2; }
die()  { printf 'rig-bootstrap: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
usage: rig bootstrap <control-plane|workload|runner|dev> [--hostname <name>] [--ts-tag <tag>]

  --hostname  system + tailnet hostname (default: the role name)
  --ts-tag    tailnet tag to advertise (default: tag:server;
              role runner defaults to tag:ci and refuses tag:server —
              a CI box executes repo-controlled code, and your server
              tag's grants must never extend to it; role dev defaults to
              tag:local and likewise refuses tag:server — the server tag's
              ACL grants :22, so a mis-tagged Incus host would hand the
              control plane free SSH)

Role dev also installs and initialises Incus (the claudebox host). The HOST
joins the tailnet; the guest claudeboxes deliberately do NOT — an
agent-inhabited box on the tailnet is a foothold into the control plane.

Provide the single-use tailscale pre-auth key via the TS_AUTHKEY env var, or
enter it at the interactive prompt. It is used once and never written to disk.
EOF
}

# --- args (validated before the root check, so errors are testable) ---------
ROLE="${1:-}"
case "$ROLE" in
  control-plane|workload|runner|dev) shift ;;
  -h|--help) usage; exit 0 ;;
  "") usage >&2; die "role required (control-plane|workload|runner|dev)" 2 ;;
  *) die "unknown role: $ROLE (want control-plane|workload|runner|dev)" 2 ;;
esac

TS_HOSTNAME="$ROLE"
if [ "$ROLE" = "runner" ]; then
  TS_TAG="tag:ci"
elif [ "$ROLE" = "dev" ]; then
  # The Incus claudebox host. tag:server's ACL grants it :22, so a dev box
  # carrying it hands the control plane free SSH — so dev advertises tag:local,
  # never tag:server (refused below, not merely defaulted). This already bit us:
  # both M900s came up tag:server and had to be retagged by hand.
  TS_TAG="tag:local"
else
  TS_TAG="tag:server"
fi
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

# A runner executes repo-controlled code; advertising the server tag would
# extend every grant your servers hold to that code. Refused, not warned.
if [ "$ROLE" = "runner" ] && [ "$TS_TAG" = "tag:server" ]; then
  die "role runner must not advertise tag:server" 2
fi
# A dev box is the Incus claudebox host. tag:server's ACL grants it :22, so a
# dev box wearing it hands the control plane free SSH — the exact bug that made
# the M900s retag-by-hand jobs. Correct-tag-only is enforced, not documented.
if [ "$ROLE" = "dev" ] && [ "$TS_TAG" = "tag:server" ]; then
  die "role dev must not advertise tag:server" 2
fi

# --- guards ------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root"
if [ -r /etc/os-release ]; then
  # Sourced in a subshell: os-release defines VERSION, NAME, ID, etc. —
  # sourcing it in the main shell silently clobbers same-named script vars.
  # shellcheck source=/dev/null
  OS_FAMILY="$(. /etc/os-release && printf '%s %s' "${ID:-}" "${ID_LIKE:-}")"
  case "$OS_FAMILY" in
    *debian*) ;;
    *) warn "not a Debian-family system (${OS_FAMILY:-unknown}); proceeding anyway" ;;
  esac
else
  warn "cannot read /etc/os-release; proceeding anyway"
fi

# The pre-auth key is acquired LATER, in the tailscale block — and only if the
# box has not already joined. rig is convergent by contract, so re-running it to
# pick up a fix (e.g. the 2026-07-12 sshd first-wins fix) must not demand a
# credential it will never spend: prompting up front made the repair path cost a
# throwaway Tailscale key, which is exactly the friction that stops people from
# re-running it.

# --- packages ----------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
log "installing base packages"
apt-get update -qq
# openssh-server: a rig box is managed over SSH (Coolify SSHes in as root),
# and the hardening drop-in below targets /etc/ssh/sshd_config.d/ — which
# only exists once the package is installed. Cloud images ship it; pristine
# container/VM images (the Incus rehearsal) do not.
apt-get install -y -qq curl ca-certificates unattended-upgrades openssh-server

# enable periodic unattended upgrades (canonical file; idempotent overwrite)
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# --- sshd hardening (restart only when the drop-in actually changed) ---------
# The name must sort BEFORE cloud-init's drop-in. sshd_config is FIRST-wins
# ("for each keyword, the first obtained value will be used" — sshd_config(5)),
# and Include expands the glob in lexical order. Cloud images ship
# /etc/ssh/sshd_config.d/50-cloud-init.conf carrying `PasswordAuthentication
# yes`, so the old 99-rig.conf was read second and silently lost every keyword
# it set. 00- wins. (Found 2026-07-12: every Hetzner box rig had bootstrapped
# was still serving `passwordauthentication yes`. The Incus rehearsal never
# caught it — a pristine Debian container has no cloud-init drop-in.)
DROPIN=/etc/ssh/sshd_config.d/00-rig.conf
LEGACY_DROPIN=/etc/ssh/sshd_config.d/99-rig.conf
TMP="$(mktemp)"
cat > "$TMP" <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
EOF
if ! cmp -s "$TMP" "$DROPIN" 2>/dev/null || [ -e "$LEGACY_DROPIN" ]; then
  BACKUP=""
  [ -e "$DROPIN" ] && { BACKUP="$(mktemp)"; cp -a "$DROPIN" "$BACKUP"; }
  install -m 0644 "$TMP" "$DROPIN"
  rm -f "$LEGACY_DROPIN"   # sweep the losing file from already-bootstrapped boxes

  # Validate the MERGED config BEFORE bouncing the daemon. On a box whose only
  # door is SSH, `systemctl restart ssh` against a config sshd refuses to parse
  # leaves no listener and no way back in. `sshd -t` parses everything sshd
  # would parse — our drop-in, cloud-init's, and any third-party file — so a
  # broken neighbour is caught here rather than after the door has shut.
  if ! sshd -t 2>/dev/null; then
    if [ -n "$BACKUP" ]; then cp -a "$BACKUP" "$DROPIN"; else rm -f "$DROPIN"; fi
    rm -f "$TMP" "$BACKUP"
    die "sshd rejects the merged config; drop-in rolled back, daemon untouched. Run 'sshd -t' to see which file is bad."
  fi
  rm -f "$BACKUP"

  systemctl restart ssh
  log "sshd hardening drop-in installed"
else
  log "sshd hardening drop-in already in place"
fi
rm -f "$TMP"

# Assert the EFFECTIVE config, not the file's existence — asserting the file is
# what let the first-wins bug ship green. `sshd -T` is what the daemon actually
# resolved, cloud-init and all.
eff="$(sshd -T 2>/dev/null)" || die "sshd -T failed; refusing to claim a hardened box"
echo "$eff" | grep -qx 'passwordauthentication no' \
  || die "sshd still resolves passwordauthentication=yes — a drop-in is beating ${DROPIN}; check ls /etc/ssh/sshd_config.d/"
echo "$eff" | grep -qxE 'permitrootlogin (prohibit-password|without-password)' \
  || die "sshd still permits root password login — check ls /etc/ssh/sshd_config.d/"
log "sshd hardening verified (sshd -T: passwordauthentication no)"

# --- system hostname ----------------------------------------------------------
# Set the SYSTEM hostname too, not just the tailnet one. Until 2026-07-12 rig
# passed --hostname only to `tailscale up`, so a box reached as `coolify-box`
# still greeted the operator with Hetzner's default (`root@internal-tooling`).
# The shell prompt is the operator's only "am I on the right box" signal before
# they run something destructive, and it was lying on every box rig built.
if [ "$(hostname)" != "$TS_HOSTNAME" ]; then
  log "setting system hostname to ${TS_HOSTNAME}"
  hostnamectl set-hostname "$TS_HOSTNAME"
  # keep 127.0.1.1 in step, or sudo/sshd warn about an unresolvable host
  if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t${TS_HOSTNAME}/" /etc/hosts
  else
    printf '127.0.1.1\t%s\n' "$TS_HOSTNAME" >> /etc/hosts
  fi
else
  log "system hostname already ${TS_HOSTNAME}"
fi

# --- tailscale ----------------------------------------------------------------
if ! command -v tailscale >/dev/null 2>&1; then
  log "installing tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh
fi
if tailscale status >/dev/null 2>&1; then
  log "tailnet already joined; skipping tailscale up (no pre-auth key needed)"
  # ...but skipping `tailscale up` also skipped --hostname, so the TAILNET name
  # never converged: a box that joined under the wrong name (e.g. --hostname
  # omitted, so it defaulted to the ROLE) stayed misnamed forever, and re-running
  # rig — the documented repair — could not fix it. rig is convergent by
  # contract; this was the one field that wasn't. `tailscale set` converges it
  # without a re-auth or a pre-auth key.
  #
  # Safe by construction here: Tailscale ACLs cannot bind a rule's dst to a
  # hostname (it must be a tag, an IP, or a `hosts` alias — which is exactly why
  # acl.hujson pins coolify-box to an IP), so a rename cannot silently void a
  # grant. It also will NOT clobber a deliberate rename: a machine renamed in the
  # admin console keeps that name, and the device hostname no longer overrides it.
  current_ts_name="$(tailscale status --peers=false 2>/dev/null | awk 'NR==1 {print $2}')"
  if [ -n "$current_ts_name" ] && [ "$current_ts_name" != "$TS_HOSTNAME" ]; then
    log "tailnet hostname is '${current_ts_name}', want '${TS_HOSTNAME}' — converging"
    tailscale set --hostname="$TS_HOSTNAME" \
      || warn "tailscale set --hostname failed; rename '${current_ts_name}' -> '${TS_HOSTNAME}' in the admin console"
  else
    log "tailnet hostname already ${TS_HOSTNAME}"
  fi
else
  # env override, else prompt; never touches disk
  if [ -z "${TS_AUTHKEY:-}" ]; then
    read -rsp "tailscale pre-auth key (single-use, tagged, <=1h expiry): " TS_AUTHKEY
    echo
  fi
  [ -n "${TS_AUTHKEY:-}" ] || die "empty pre-auth key"
  log "joining tailnet as ${TS_HOSTNAME} (${TS_TAG})"
  tailscale up --authkey="$TS_AUTHKEY" --hostname="$TS_HOSTNAME" --advertise-tags="$TS_TAG"
fi

# --- incus (dev role only) ----------------------------------------------------
# The Incus claudebox host is the one machine class rig didn't make — it was
# hand-built, so "every box is rig-made, reproducibly" had a hole exactly where
# an agent runs. This block closes it: install Incus, initialise it once.
#
# NOTE — the guest claudeboxes deliberately do NOT join the tailnet. Only the
# HOST joined above; an agent-inhabited box with its own tailnet node is a
# foothold into the control plane, so operator SSH into a claudebox goes through
# the host (ProxyJump), never a tunnel of its own. rig joins the host and stops.
# There is intentionally no code here to enrol the guests: if bootstrap dev ever
# grows a "join the guests too" convenience, that convenience is the bug.
#
# No credentials, either: claudeboxes are creds-free by design and the operator
# adds their own interactively. rig installs, templates and holds nothing secret.
if [ "$ROLE" = "dev" ]; then
  if ! command -v incus >/dev/null 2>&1; then
    log "installing incus"
    # Debian 13 packages incus directly; keep the noninteractive frontend the
    # base package block set, so a prompt never wedges an unattended bootstrap.
    apt-get install -y -qq incus
  else
    log "incus already installed"
  fi

  # Initialise ONCE. `incus admin init --auto` is NOT idempotent — a second run
  # errors out ("storage pool already exists"), which would break convergence.
  # Detect a prior init by the artefacts --auto leaves behind — a storage pool
  # AND a root disk on the default profile — and skip re-init when both exist,
  # so a second `bootstrap dev` is a true no-op.
  if incus storage list -f csv 2>/dev/null | grep -q . \
     && incus profile device show default 2>/dev/null | grep -q 'type: disk'; then
    log "incus already initialised; skipping incus admin init"
  else
    log "initialising incus (default storage pool, default profile, managed bridge)"
    incus admin init --auto
  fi

  # Assert the EFFECTIVE state, not `init`'s exit code — the repo's "assert what
  # resolved, not the action" rule (the same discipline that caught the sshd
  # first-wins bug). A green `init` that left no root disk or no managed network
  # is a host that cannot launch a claudebox; die here rather than at first use.
  incus profile device show default 2>/dev/null | grep -q 'type: disk' \
    || die "incus init did not leave a root disk on the default profile — check 'incus profile show default'"
  incus network list -f csv 2>/dev/null | grep -q '^incusbr0,' \
    || die "incus init did not create the managed bridge incusbr0 — check 'incus network list'"
  log "incus initialised and verified (default profile has a root disk; incusbr0 present)"
fi

log "done — role ${ROLE}, hostname ${TS_HOSTNAME}"
if [ "$ROLE" = "control-plane" ]; then
  log "next: rig coolify install --version <pin>"
elif [ "$ROLE" = "runner" ]; then
  log "next: rig runner install --repo <owner/repo> --version <pin>"
elif [ "$ROLE" = "dev" ]; then
  log "next: launch claudeboxes on this host (guests stay off the tailnet; reach them via ProxyJump through this host)"
fi
