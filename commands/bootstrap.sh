#!/usr/bin/env bash
# rig bootstrap — OS plumbing for a pristine Debian box.
# Convergent: safe to re-run; a second run changes nothing.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/runner-config.sh
. "$HERE/lib/runner-config.sh"   # json_field / json_string_array read the netmap

log()  { printf 'rig-bootstrap: %s\n' "$*"; }
warn() { printf 'rig-bootstrap: WARNING: %s\n' "$*" >&2; }
die()  { printf 'rig-bootstrap: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
usage: rig bootstrap <control-plane|workload|runner> [--hostname <name>]

  --hostname  system + tailnet hostname (default: the role name)

The tailnet tag is NOT a rig argument. A pre-auth key is minted WITH its tags,
so the key is the single source of truth: rig no longer requests a tag it might
disagree with. After the box joins, rig reads the tag control actually GRANTED
(tailscale status .Self.Tags) and asserts on THAT — an untagged key is refused
outright, and a runner may not carry tag:server. Mint a correctly-tagged key.

Provide the single-use tailscale pre-auth key via the TS_AUTHKEY env var, or
enter it at the interactive prompt. It is used once and never written to disk.
EOF
}

# --- args (validated before the root check, so errors are testable) ---------
ROLE="${1:-}"
case "$ROLE" in
  control-plane|workload|runner) shift ;;
  -h|--help) usage; exit 0 ;;
  "") usage >&2; die "role required (control-plane|workload|runner)" 2 ;;
  *) die "unknown role: $ROLE (want control-plane|workload|runner)" 2 ;;
esac

TS_HOSTNAME="$ROLE"
while [ $# -gt 0 ]; do
  case "$1" in
    --hostname)
      [ $# -ge 2 ] || die "--hostname needs a value" 2
      TS_HOSTNAME="$2"; shift 2 ;;
    --ts-tag)
      # --ts-tag is GONE, but this is a deliberate death with a message, not an
      # "unknown flag": the flag shipped for a month and scripts still pass it,
      # so it must explain where the tag went rather than look like a typo. The
      # tag is now the key's to state and rig's to verify after join (issue #16 —
      # the tag was said twice and rig never checked the two agreed). Consume a
      # following value if present so `--ts-tag tag:server` dies on the flag and
      # its argument never lands in the *) arm as a mystery unknown flag.
      [ $# -ge 2 ] && shift
      die "--ts-tag is removed: the tailnet tag comes from the pre-auth key now, not rig. Mint a key with the tag you want; rig verifies the granted tag after join." 2 ;;
    *) die "unknown flag: $1" 2 ;;
  esac
done

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
# verify_effective_tag — assert the tag control actually GRANTED this node, never
# the one rig requested. This is the sshd `sshd -T` lesson wearing a tailnet hat:
# rig used to advertise a tag and trust it took, exactly as it once trusted that
# a drop-in FILE existing meant sshd had read it. Both M900s joined carrying
# tag:server and had to be retagged by hand; nothing in rig noticed because
# nothing ever read the effective tag back.
#
# `.Self.Tags` from `tailscale status --json` is the netmap's ground truth.
# `tailscale debug prefs` would LIE here — it prints AdvertiseTags, i.e. what was
# REQUESTED — which is precisely the second source of truth issue #16 deletes.
# Tags ride in with the netmap, not synchronously out of `up`, so a single read
# right after join can legitimately come back empty; poll until tags appear OR
# the backend reaches Running (past which an empty Tags is real, not just early).
verify_effective_tag() {
  local deadline=$((SECONDS + 30)) tags="" state="" json
  json="$(mktemp)"
  while :; do
    if tailscale status --json > "$json" 2>/dev/null; then
      tags="$(json_string_array "$json" Tags)"
      state="$(json_field "$json" BackendState)"
      if [ -n "$tags" ] || [ "$state" = "Running" ]; then break; fi
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then break; fi
    sleep 2
  done
  rm -f "$json"

  # UNTAGGED is the real hazard and it is silent: with no tags the node joined
  # owned by the KEY CREATOR's user identity — it inherits that human's ACL
  # grants, expires with the key, and vanishes if the account is deleted.
  # Dropping --advertise-tags removed the accidental net that used to tag such a
  # node anyway, so rig must now catch this out loud. A wrong tag cannot be fixed
  # in place (`tailscale set` has no tag flag; re-tagging needs a fresh key via
  # `up --force-reauth`), so back the node out rather than leave a half-joined,
  # user-owned device squatting a hostname.
  if [ -z "$tags" ]; then
    tailscale logout >/dev/null 2>&1 \
      || warn "tailscale logout failed — this node is joined UNTAGGED and user-owned; remove it from the tailnet by hand"
    die "joined with NO tag: the pre-auth key was untagged, so this node is owned by the key creator's user identity, not a tag. Backed it out. Fix: mint a TAGGED pre-auth key and re-run."
  fi

  # Role policy now rides the EFFECTIVE tag — strictly stronger than the old
  # request-time check, which only guarded the tag rig HOPED for. This guards the
  # tag the key ACTUALLY granted to repo-controlled code: a runner carrying
  # tag:server would extend every grant your servers hold to CI code. Refused,
  # never warned. rig can DETECT this but cannot FIX it, so name the repair.
  if [ "$ROLE" = "runner" ] && printf '%s\n' "$tags" | grep -qx 'tag:server'; then
    die "role runner joined with tag:server (effective tags: $(printf '%s' "$tags" | tr '\n' ' ')). The key you used grants tag:server to repo-controlled code; that must never happen. Re-run bootstrap with a key minted for a CI tag (e.g. tag:ci)."
  fi

  log "verified effective tailnet tag(s): $(printf '%s' "$tags" | tr '\n' ' ')"
}

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
  # Verify the tag on the already-joined path too, not only on first join: this
  # catches a box bootstrapped BEFORE rig looked at tags, or one retagged behind
  # rig's back, on the very next ordinary re-run. Skipping `tailscale up` here is
  # deliberate and stays — re-running an identical tagged-authkey `up` errors —
  # but skipping the CHECK was how the M900s stayed mis-tagged unnoticed.
  verify_effective_tag
else
  # env override, else prompt; never touches disk
  if [ -z "${TS_AUTHKEY:-}" ]; then
    read -rsp "tailscale pre-auth key (single-use, tagged, <=1h expiry): " TS_AUTHKEY
    echo
  fi
  [ -n "${TS_AUTHKEY:-}" ] || die "empty pre-auth key"
  # No --advertise-tags: the key's own tags apply (documented default for a
  # tagged key), and rig verifies them below instead of stating a second tag it
  # cannot reconcile with the key's. A tagged key needs no flag; an untagged one
  # cannot be rescued by one (verify_effective_tag refuses it and logs out).
  log "joining tailnet as ${TS_HOSTNAME} (tag comes from the pre-auth key)"
  tailscale up --authkey="$TS_AUTHKEY" --hostname="$TS_HOSTNAME"
  verify_effective_tag
fi

log "done — role ${ROLE}, hostname ${TS_HOSTNAME}"
if [ "$ROLE" = "control-plane" ]; then
  log "next: rig coolify install --version <pin>"
elif [ "$ROLE" = "runner" ]; then
  log "next: rig runner install --repo <owner/repo> --version <pin>"
fi
