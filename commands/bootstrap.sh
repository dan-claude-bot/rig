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
usage: rig bootstrap <control-plane|workload|runner|staging|dev|workstation|custom>
                     [--hostname <name>] [--class <human|server>]
                     [--host <yes|no>] [--join <authkey|login>]

  --hostname  system + tailnet hostname (default: the role name; custom has
              no default and requires it)
  --class     who lives here — human|server. Decides root SSH's fate after
              `rig users apply`: human closes it, server keeps it as the
              control plane's automation door.
  --host      does this box host VMs (box/Incus) — yes|no
  --join      how it enters the tailnet — authkey|login

Roles are presets over the three traits; any flag overrides its trait.
custom presets nothing and requires --hostname plus all three traits.

  role            class   host  join
  control-plane   server  no    authkey
  workload        server  no    authkey
  runner          server  no    authkey
  staging         server  yes   authkey
  dev             human   yes   authkey
  workstation     human   yes   login

The tailnet tag is NOT a rig argument. A pre-auth key is minted WITH its tags,
so the key is the single source of truth: rig no longer requests a tag it might
disagree with. After the box joins, rig reads the tag control actually GRANTED
(tailscale status .Self.Tags) and asserts on THAT — an untagged key is refused
outright, and only control-plane and workload may carry tag:server (they are
the only shapes the control plane manages). Mint a correctly-tagged key.

join=authkey: provide the single-use tailscale pre-auth key via the TS_AUTHKEY
env var, or enter it at the interactive prompt. Used once, never written to disk.

join=login: no pre-auth key — `tailscale up` prints a login URL and the human
at the keyboard is the credential, so the node comes up user-owned and
UNTAGGED (a tag here is refused and backed out). A set TS_AUTHKEY is a usage
error: unset it, or pass --join authkey.
EOF
}

# --- args (validated before the root check, so errors are testable) ---------
ROLE="${1:-}"
case "$ROLE" in
  control-plane|workload|runner|staging|dev|workstation|custom) shift ;;
  -h|--help) usage; exit 0 ;;
  "") usage >&2; die "role required (control-plane|workload|runner|staging|dev|workstation|custom)" 2 ;;
  *) die "unknown role: $ROLE (want control-plane|workload|runner|staging|dev|workstation|custom)" 2 ;;
esac

# Role→traits map — the single place a role's shape is declared (issue #26).
# Roles are presets, nothing more: every behavior below keys off the traits,
# so a flag override changes behavior without a new role, and custom exists
# for the shape nobody foresaw — it declares nothing and must state all three.
CLASS="" HOST="" JOIN=""
case "$ROLE" in
  control-plane) CLASS=server HOST=no  JOIN=authkey ;;
  workload)      CLASS=server HOST=no  JOIN=authkey ;;
  runner)        CLASS=server HOST=no  JOIN=authkey ;;
  staging)       CLASS=server HOST=yes JOIN=authkey ;;
  dev)           CLASS=human  HOST=yes JOIN=authkey ;;
  workstation)   CLASS=human  HOST=yes JOIN=login   ;;
  custom)        ;;
esac

# custom has no hostname default: a made-up name on a made-up shape helps nobody.
TS_HOSTNAME="$ROLE"
[ "$ROLE" = "custom" ] && TS_HOSTNAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --hostname)
      [ $# -ge 2 ] || die "--hostname needs a value" 2
      TS_HOSTNAME="$2"; shift 2 ;;
    --class)
      [ $# -ge 2 ] || die "--class needs a value" 2
      case "$2" in
        human|server) CLASS="$2" ;;
        *) die "bad --class: $2 (want human|server)" 2 ;;
      esac
      shift 2 ;;
    --host)
      [ $# -ge 2 ] || die "--host needs a value" 2
      case "$2" in
        yes|no) HOST="$2" ;;
        *) die "bad --host: $2 (want yes|no)" 2 ;;
      esac
      shift 2 ;;
    --join)
      [ $# -ge 2 ] || die "--join needs a value" 2
      case "$2" in
        authkey|login) JOIN="$2" ;;
        *) die "bad --join: $2 (want authkey|login)" 2 ;;
      esac
      shift 2 ;;
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

# custom must state its whole shape — collect every gap and report them at once,
# so the operator fixes the command line in one round trip, not four.
if [ "$ROLE" = "custom" ]; then
  MISSING=""
  [ -n "$TS_HOSTNAME" ] || MISSING="$MISSING --hostname"
  [ -n "$CLASS" ]       || MISSING="$MISSING --class"
  [ -n "$HOST" ]        || MISSING="$MISSING --host"
  [ -n "$JOIN" ]        || MISSING="$MISSING --join"
  [ -z "$MISSING" ] || die "role custom has no presets; missing:$MISSING" 2
fi

# A set TS_AUTHKEY on a login join is a usage error, caught before the root
# check: the operator plainly expected the key to be spent, and silently
# ignoring a credential is how the wrong join path ships unnoticed.
if [ "$JOIN" = "login" ] && [ -n "${TS_AUTHKEY:-}" ]; then
  die "join=login is interactive: unset TS_AUTHKEY or pass --join authkey" 2
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
# A host=yes box exists to run VMs, so no /dev/kvm deserves a loud note — but
# only a note: the shape is rehearsed in containers, where /dev/kvm is
# legitimately absent, and rig cannot tell a rehearsal from a misconfigured box.
if [ "$HOST" = "yes" ] && [ ! -e /dev/kvm ]; then
  warn "/dev/kvm is absent — a host=yes box is expected to run VMs. Harmless in a container rehearsal; on real hardware, enable virtualization (VT-x/AMD-V) in firmware."
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
# `no` is accepted because it is the post-`rig users close-root` state —
# strictly harder than the prohibit-password this script installs. Bootstrap
# must never read a closed door as a broken one, and it cannot reopen one
# either: by first-wins its own drop-in loses to 00-rig-users.conf.
echo "$eff" | grep -qxE 'permitrootlogin (no|prohibit-password|without-password)' \
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

  # tag:server policy is DERIVED, not a trait: it means "the control plane
  # manages this box", and only control-plane and workload are shapes the
  # control plane manages. Everything else refuses it on the EFFECTIVE tag —
  # strictly stronger than the old request-time check, which only guarded the
  # tag rig HOPED for. The fleet has been bitten both ways: a runner carrying
  # tag:server extends every server grant to repo-controlled code, and a
  # staging host carrying it extends them to a box the control plane does not
  # even know. Refused, never warned; rig can DETECT this but cannot FIX it,
  # so each refusal names its repair.
  if printf '%s\n' "$tags" | grep -qx 'tag:server'; then
    case "$ROLE" in
      control-plane|workload) ;;
      runner)
        die "role runner joined with tag:server (effective tags: $(printf '%s' "$tags" | tr '\n' ' ')). The key you used grants tag:server to repo-controlled code; that must never happen. Re-run bootstrap with a key minted for a CI tag (e.g. tag:ci)." ;;
      staging)
        die "role staging joined with tag:server (effective tags: $(printf '%s' "$tags" | tr '\n' ' ')). A staging host is never managed by the control plane — its guest VMs are. Re-run bootstrap with a key minted for tag:local." ;;
      *)
        die "role $ROLE joined with tag:server (effective tags: $(printf '%s' "$tags" | tr '\n' ' ')). Only control-plane and workload are managed by the control plane; tag:server on this box extends every server grant to it. Re-run bootstrap with a key minted for a non-server tag (e.g. tag:local)." ;;
    esac
  fi

  log "verified effective tailnet tag(s): $(printf '%s' "$tags" | tr '\n' ' ')"
}

# verify_user_owned <back-out|keep> — join=login INVERTS the tag assertion:
# the whole point of a login join is a user-owned, untagged node, so here a tag
# is the hazard (control granted this device fleet identity) and untagged is
# the success case. Same poll as verify_effective_tag — tags ride the netmap —
# but the empty read is what we WANT once the backend reaches Running.
# back-out: first join, so a refusal logs the node out (mirror of the
# untagged-key back-out on the authkey path). keep: the box was already joined
# before this run — never back out state rig did not create; detect, refuse,
# and name the by-hand repair instead.
verify_user_owned() {
  local mode="$1" deadline=$((SECONDS + 30)) tags="" state="" json shown
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

  if [ -n "$tags" ]; then
    shown="$(printf '%s' "$tags" | tr '\n' ' ')"
    if [ "$mode" = "back-out" ]; then
      tailscale logout >/dev/null 2>&1 \
        || warn "tailscale logout failed — this node is joined TAGGED; remove it from the tailnet by hand"
      die "joined TAGGED (${shown}) but join=login expects a user-owned, untagged node — a tag here means control granted this device fleet identity; use a pre-auth key path (--join authkey) for fleet machines. Backed it out."
    fi
    die "this node is TAGGED (${shown}) but join=login expects a user-owned, untagged node — a tag here means control granted this device fleet identity. It was joined before this run, so nothing was backed out: run 'tailscale logout' and re-run bootstrap, or re-run with --join authkey."
  fi
  log "user-owned join verified (untagged)"
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
  # The check the traits demand: authkey wants the granted tag, login wants none
  # (`keep`: never back out a join this run did not perform).
  if [ "$JOIN" = "login" ]; then
    verify_user_owned keep
  else
    verify_effective_tag
  fi
elif [ "$JOIN" = "login" ]; then
  # No pre-auth key on this path — the human at the keyboard is the credential.
  # `tailscale up` prints a login URL and blocks until the browser login lands.
  log "joining tailnet as ${TS_HOSTNAME} (interactive login; follow the URL tailscale prints)"
  tailscale up --hostname="$TS_HOSTNAME"
  verify_user_owned back-out
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

# --- role marker --------------------------------------------------------------
# /etc/rig/role is the traits' ground truth for later rig commands (`rig users`
# reads class from it to decide root SSH's fate). Written only AFTER the tag
# verification, so a marker never describes a box that failed to become what it
# claims — and cmp-guarded like every file rig converges.
MARKER=/etc/rig/role
MARKER_TMP="$(mktemp)"
printf 'role=%s class=%s host=%s join=%s\n' "$ROLE" "$CLASS" "$HOST" "$JOIN" > "$MARKER_TMP"
if ! cmp -s "$MARKER_TMP" "$MARKER" 2>/dev/null; then
  mkdir -p /etc/rig
  install -m 0644 "$MARKER_TMP" "$MARKER"
  log "role marker written: role=$ROLE class=$CLASS host=$HOST join=$JOIN"
else
  log "role marker already current"
fi
rm -f "$MARKER_TMP"

log "done — role ${ROLE}, hostname ${TS_HOSTNAME}"
if [ "$ROLE" = "control-plane" ]; then
  log "next: rig coolify install --version <pin>"
elif [ "$ROLE" = "runner" ]; then
  log "next: rig runner install --repo <owner/repo> --version <pin>"
fi
if [ "$HOST" = "yes" ]; then
  log "next: install the box CLI and run 'box setup-host' to prepare Incus for guest boxes"
fi
# Every class gets operators: humans always enter as themselves and elevate via
# sudo — a shared root login is unattributable. What differs by class is root
# SSH's fate once named users exist.
if [ "$CLASS" = "human" ]; then
  log "next: rig users apply --file <users-file>, then 'rig users close-root' once your admin key works"
else
  log "next: rig users apply --file <users-file> for named operator logins; root SSH stays — it is the control plane's automation door"
fi
