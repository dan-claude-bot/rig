#!/usr/bin/env bash
# rig bootstrap — OS plumbing for a pristine Debian box.
# Convergent: safe to re-run; a second run changes nothing.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/runner-config.sh
. "$HERE/lib/runner-config.sh"   # json_field / json_string_array read the netmap
# shellcheck source=SCRIPTDIR/lib/sshd.sh
. "$HERE/lib/sshd.sh"            # harden_sshd — shared with the staging tenant
# shellcheck source=SCRIPTDIR/lib/users-config.sh
. "$HERE/lib/users-config.sh"    # parse_users_file — the --users PRE-FLIGHT only
# shellcheck source=SCRIPTDIR/lib/manifest.sh
. "$HERE/lib/manifest.sh"        # manifest_stamp — provenance, written beside the marker
# The users lib is sourced for validation, never for convergence: `users apply`
# stays the single owner of what a users file DOES to a box (#51). Bootstrap
# borrows the parser so a typo'd users file is caught in the same breath as a
# bad --root-door — before apt, before the tailnet join, before a pre-auth key is
# spent — instead of at the very end of a run the operator already paid for.

log()  { printf 'rig-bootstrap: %s\n' "$*"; }
warn() { printf 'rig-bootstrap: WARNING: %s\n' "$*" >&2; }
die()  { printf 'rig-bootstrap: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
usage: rig bootstrap <control-plane-server|workload-server|runner-server|
                      staging-server|dev-server|workstation|custom>
                     (--users <path> | --no-users)
                     [--hostname <name>] [--root-door <closed|open>]
                     [--host <yes|no>] [--join <authkey|login>]
       rig bootstrap <claude-box|codex-box|grok-box|kimi-box|staging-box> [--user <name>]
                     (the box TENANT roles — see their own --help; they take
                      no --users, see below)

  --users     the users file this box's operators come from — REQUIRED. It is
              applied as bootstrap's last phase, exactly as `rig users apply
              --file <path>` would, so one command leaves a box with its
              people on it. Passed per invocation and never persisted.
  --no-users  the deliberate opt-out — bootstrap converges the OS and the
              tailnet and leaves the box with root as its only door.
  --hostname  system + tailnet hostname (default: the role name; custom has
              no default and requires it)
  --root-door what happens to root SSH after the users phase — closed|open.
              closed: `rig users close-root` shuts it once named operators can
              get in. open: it stays, as the control plane's automation door.
              (Named --class human|server before #77 — same trait, renamed for
              what it decides rather than for who lives on the box. Markers
              written by the old flag are still read.)
  --host      does this box host VMs (box/Incus) — yes|no
  --join      how it enters the tailnet — authkey|login

One of --users/--no-users is required on every role, root-door=open included:
a box nobody logs into routinely is exactly where shared-root access rots,
and per-human accounts keep attribution intact for the times someone does go
in. So the complete path is the default path and skipping it is a deliberate
--no-users, not an omission.

--users does NOT reach the box TENANT roles (claude-box|codex-box|grok-box|kimi-box|staging-box). A
tenant is a box-minted GUEST: box auto-runs its bootstrap at mint,
non-interactively, with no file to hand it; the guest never joins the tailnet
and has no SSH door of its own — entry is `box shell`, gated by the HOST's
incus grants, which the host's own users file already converged. A fleet-wide
operator file has nothing to converge in there.

Roles are presets over the three traits; any flag overrides its trait.
custom presets nothing and requires --hostname plus all three traits.

  role                   root-door  host  join
  control-plane-server   open       no    authkey
  workload-server        open       no    authkey
  runner-server          open       no    authkey
  staging-server         open       yes   authkey
  dev-server             closed     yes   authkey
  workstation            closed     yes   login

THE SUFFIX NAMES THE FAMILY, not the door policy. '-server' means this role builds a
fleet MACHINE — a tailnet node rig converges; '-box' (the tenant roles) means a
GUEST a box mints. Two families lived in one flat namespace and nothing in a
name said which you were asking for; 'staging' made that concrete by naming
both the metal and the guests on it.

  custom       no suffix: it presets nothing and can be any shape, a guest
               included, so a family claim would be one it cannot make.
  workstation  no suffix: somebody's own device, not fleet infrastructure —
               it joins by interactive login and comes up user-owned and
               untagged, and the tailnet never manages it.

'dev-server --root-door closed' says what is true and says it once: the suffix
names the FAMILY (a fleet machine), the trait names the DOOR (operators enter a
dev box as themselves, so 'users close-root' shuts its door). Until #77 this
trait was '--class human|server', which named the wrong axis — who lives on the
box — and left 'dev-server' reading as a class=human contradiction. Nobody
lives on a dev box; what makes it different is that its root door closes.

The tailnet tag is NOT a rig argument. A pre-auth key is minted WITH its tags,
so the key is the single source of truth: rig no longer requests a tag it might
disagree with. After the box joins, rig reads the tag control actually GRANTED
(tailscale status .Self.Tags) and asserts on THAT — an untagged key is refused
outright, and only control-plane-server and workload-server may carry
tag:server (they are the only shapes the control plane manages). Mint a
correctly-tagged key.

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
  control-plane-server|workload-server|runner-server|staging-server|dev-server|workstation|custom) shift ;;
  claude-box|codex-box|grok-box|kimi-box|staging-box)
    # The box TENANT roles (#31) are a different family — guests a box mints,
    # never tailnet machines — and live in their own mechanism, one script
    # parameterized per tenant. Dispatched here so `rig bootstrap <role>`
    # stays the single entrypoint for both families.
    exec "$HERE/bootstrap-tenant.sh" "$@" ;;
  -h|--help) usage; exit 0 ;;
  "") usage >&2; die "role required (control-plane-server|workload-server|runner-server|staging-server|dev-server|workstation|custom — or a tenant role: claude-box|codex-box|grok-box|kimi-box|staging-box)" 2 ;;
  *) die "unknown role: $ROLE (want control-plane-server|workload-server|runner-server|staging-server|dev-server|workstation|custom — or a tenant role: claude-box|codex-box|grok-box|kimi-box|staging-box)" 2 ;;
esac

# Role→traits map — the single place a role's shape is declared (issue #26).
# Roles are presets, nothing more: every behavior below keys off the traits,
# so a flag override changes behavior without a new role, and custom exists
# for the shape nobody foresaw — it declares nothing and must state all three.
ROOT_DOOR="" HOST="" JOIN=""
case "$ROLE" in
  control-plane-server) ROOT_DOOR=open   HOST=no  JOIN=authkey ;;
  workload-server)      ROOT_DOOR=open   HOST=no  JOIN=authkey ;;
  runner-server)        ROOT_DOOR=open   HOST=no  JOIN=authkey ;;
  # The unattended VM host — the shape #31 retired when 'staging' moved to the
  # tenant family, restored under a name that cannot be confused with its own
  # guests. host=yes is the whole point: it is what installs the box CLI and
  # runs box's setup-host further down, so this is a table row, not machinery.
  staging-server)       ROOT_DOOR=open   HOST=yes JOIN=authkey ;;
  dev-server)           ROOT_DOOR=closed HOST=yes JOIN=authkey ;;
  workstation)          ROOT_DOOR=closed HOST=yes JOIN=login   ;;
  custom)        ;;
esac

# custom has no hostname default: a made-up name on a made-up shape helps nobody.
TS_HOSTNAME="$ROLE"
[ "$ROLE" = "custom" ] && TS_HOSTNAME=""
USERS_FILE=""
NO_USERS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --users)
      [ $# -ge 2 ] || die "--users needs a value" 2
      USERS_FILE="$2"; shift 2 ;;
    --no-users)
      NO_USERS=1; shift ;;
    --hostname)
      [ $# -ge 2 ] || die "--hostname needs a value" 2
      TS_HOSTNAME="$2"; shift 2 ;;
    --root-door)
      [ $# -ge 2 ] || die "--root-door needs a value" 2
      case "$2" in
        closed|open) ROOT_DOOR="$2" ;;
        *) die "bad --root-door: $2 (want closed|open)" 2 ;;
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
  [ -n "$ROOT_DOOR" ]   || MISSING="$MISSING --root-door"
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

# --- who lives here (#51) -----------------------------------------------------
# The users file is the last piece of "what this box is" that bootstrap did not
# take, and it is REQUIRED rather than optional: a bootstrapped box with no
# users converges to a box only root can enter, and on root-door=closed that is a
# half-built machine waiting for a second command the operator has to remember
# (`rig users close-root` is itself gated behind "once your admin key works" —
# which needs an admin to exist). root-door=open gets the same requirement on
# purpose: a server nobody logs into routinely is exactly where shared-root
# access rots, and per-human accounts keep attribution intact for the times
# someone does go in.
#
# The opt-out is a FLAG, not a default. Both states are then something the
# operator said out loud, which is the whole point — an omitted --users used to
# be indistinguishable from "I meant to and forgot", and the box that resulted
# looked identical either way. Contradicting yourself is a usage error too:
# --users and --no-users together is not a precedence puzzle rig should silently
# resolve, because whichever way it resolved would be the wrong one half the
# time.
if [ -n "$USERS_FILE" ] && [ "$NO_USERS" -eq 1 ]; then
  die "--users and --no-users are contradictory: pass the file, or say --no-users, not both" 2
fi
if [ -z "$USERS_FILE" ] && [ "$NO_USERS" -eq 0 ]; then
  die "one of --users <path> or --no-users is required: bootstrap converges this box's operators as its last phase, and a box with no named users is one only root can enter. Pass --users <path>, or --no-users to leave it root-only deliberately" 2
fi

# The users file is PRE-FLIGHTED here and applied at the very end: everything
# below this point costs the operator something — apt, a hostname change, a
# single-use pre-auth key — and a users file with a typo in it must not be
# discovered after all of that was already spent. Same reason every other flag
# is validated before the root check: errors belong at the top of the run.
USERS_HAS_BOX_ROLE=0
if [ -n "$USERS_FILE" ]; then
  # '-' (stdin) is apply's own convenience and cannot survive the trip through
  # bootstrap: stdin here belongs to the pre-auth key prompt, and a users file
  # piped in would either eat that prompt or be eaten by it. Refuse the token
  # rather than let the two credentials-shaped reads fight over one pipe.
  [ "$USERS_FILE" != "-" ] \
    || die "--users needs a real path: bootstrap's stdin is the pre-auth key prompt's, so it cannot also carry the users file. Write it to a file, or run 'rig users apply --file -' separately after --no-users" 2
  [ -r "$USERS_FILE" ] || die "cannot read users file: $USERS_FILE" 2
  if ! USERS_PARSED="$(parse_users_file "$USERS_FILE")"; then
    die "invalid users file: $USERS_FILE — every error is listed above; nothing was changed" 2
  fi
  # A file that parses to ZERO users is not a parse error — empty, comments-only
  # and whitespace-only files are all perfectly valid input, and the parser is
  # right to accept them. But they walk straight through the requirement #51
  # built: `--users ./empty-file` and `--no-users` converge the identical
  # root-only box, and only one of them says so. The ambiguity the required flag
  # exists to kill would survive in a narrower form — an operator who pointed at
  # the wrong path and one who meant root-only would again produce indis-
  # tinguishable boxes, which is precisely the state the flag was made to end.
  #
  # Refuse, and name --no-users: the outcome is reachable, it just has to be
  # said out loud. That is the whole shape of #51's contract — both answers are
  # available, neither is a side effect of what you did not type.
  #
  # The sharper reason this belongs at pre-flight rather than nowhere: against a
  # box that ALREADY has operators, a truncated file does not converge nothing,
  # it revokes every one of them. That is apply's correct and documented
  # drop-semantics and it warns per user, so it is loud rather than silent — but
  # a stray '>' is all it takes to produce that file, and every other failure
  # mode on this command was deliberately made to fail before apt, the hostname
  # change, or a spent pre-auth key. This one should not be the exception that
  # fails after them.
  #
  # Deliberately scoped to BOOTSTRAP, not to the parser and not to apply. The
  # lib stays a parser — "zero users is not allowed here" is bootstrap's policy,
  # not a property of the file format — and a standalone `rig users apply`
  # against an emptied file remains a real de-provisioning operation that must
  # keep working. Bootstrap is where the claim "this box's people are these" is
  # being made, so bootstrap is where an empty answer is a contradiction.
  if [ -z "$USERS_PARSED" ]; then
    die "users file names no users: $USERS_FILE parsed to zero operators (it is empty, or only comments and blank lines). Bootstrapping with it would converge a box only root can enter — the same outcome as --no-users, reached by the flag that exists to guarantee the opposite. Check the path, or pass --no-users to leave this box root-only deliberately" 2
  fi
  # Does anyone in the file carry role box? That single fact decides whether the
  # incus precondition below applies at all — a users file naming only admins
  # converges perfectly well on a host that has never seen Incus, and refusing
  # it there would be rig inventing a prerequisite its own apply does not have.
  if printf '%s\n' "$USERS_PARSED" | cut -d'|' -f2 | grep -qE '(^|,)box(,|$)'; then
    USERS_HAS_BOX_ROLE=1
  fi
fi

# host=yes + a box-role user + no incus group = the refusal `users apply` already
# owns ("rig NEVER installs Incus: box's setup-host owns the daemon and its
# group"). rig does not build that stack here and does not call setup-host —
# whether rig should install box on a VM host is an open boundary question, and
# resolving it by accident inside a users change would be the worst way to
# answer it. What bootstrap CAN do is stop early instead of late.
#
# Early only where the outcome is already PROVEN, though. The ordinary host=yes
# path installs box further down, and box's own installer runs setup-host — so
# the group that is missing now will exist by the time the users phase runs, and
# an unconditional refusal here would reject the exact bring-up this issue is
# about. RIG_SKIP_BOX_INSTALL=1 is the one case with no such rescue: the
# operator has said this run will not touch box, so the group's absence is final
# and the run is doomed a hundred lines before it notices. The other failure
# shapes (no network, box's installer breaking) are not knowable this early and
# land in apply's own refusal at the end — the same message, one phase later.
#
# #49 (merged) added a SECOND host-level refusal to apply: the box CLI itself
# missing on host=yes, because the group is only the socket and the tier is
# `box grant`, which apply calls rather than reimplements. Under
# RIG_SKIP_BOX_INSTALL=1 that absence is just as final and just as knowable
# now as the group's, so the early check mirrors both rather than being a
# weaker proxy for one of them. Either one alone dooms the run.
if [ "$USERS_HAS_BOX_ROLE" -eq 1 ] && [ "$HOST" = "yes" ] \
    && [ "${RIG_SKIP_BOX_INSTALL:-}" = "1" ]; then
  if ! getent group incus >/dev/null 2>&1; then
    die "a user carries role box and this box hosts VMs (host=yes) but group incus is absent and RIG_SKIP_BOX_INSTALL=1 means this run will not install box — install the box CLI and run 'box setup-host' first; rig never installs Incus. (Or drop RIG_SKIP_BOX_INSTALL and let bootstrap install box as it normally does.)" 2
  fi
  if ! command -v box >/dev/null 2>&1; then
    die "a user carries role box and this box hosts VMs (host=yes) but the box CLI is not on PATH and RIG_SKIP_BOX_INSTALL=1 means this run will not install it — the incus group is only the socket; the restricted tier is 'box grant', which rig calls rather than reimplements. Install the box CLI first. (Or drop RIG_SKIP_BOX_INSTALL and let bootstrap install box as it normally does.)" 2
  fi
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

# --- sshd hardening ----------------------------------------------------------
# The whole block lives in lib/sshd.sh, shared with the staging TENANT role —
# one drop-in, one converger, never two copies drifting apart. Everything the
# block learned the hard way (00- beats cloud-init's 50- under first-wins,
# validate-then-restart, assert sshd -T not the file, the root-door-gated
# permitrootlogin acceptance) moved with it, verbatim.
harden_sshd "$ROOT_DOOR"

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
#
# verify_effective_tag <back-out|keep> — same mode discipline as
# verify_user_owned: back-out on first join (rig just spent the key, so an
# untagged result is rig's own mess to undo), keep on the already-joined path
# (never back out state rig did not create — the join there may be a
# legitimately login-joined, user-owned workstation that someone re-ran with
# join=authkey by mistake).
verify_effective_tag() {
  local mode="$1" deadline=$((SECONDS + 30)) tags="" state="" json
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
  # user-owned device squatting a hostname. That back-out is EARNED only on the
  # first-join path, where rig itself just performed the join; on the
  # already-joined path an untagged node may be exactly what someone built on
  # purpose — a login-joined workstation is untagged BY DESIGN — and tearing it
  # off the tailnet because a re-run said join=authkey would destroy state rig
  # did not create. keep mode refuses without touching the join and names both
  # ways out, since rig cannot tell which one the operator meant.
  if [ -z "$tags" ]; then
    if [ "$mode" = "back-out" ]; then
      tailscale logout >/dev/null 2>&1 \
        || warn "tailscale logout failed — this node is joined UNTAGGED and user-owned; remove it from the tailnet by hand"
      die "joined with NO tag: the pre-auth key was untagged, so this node is owned by the key creator's user identity, not a tag. Backed it out. Fix: mint a TAGGED pre-auth key and re-run."
    fi
    die "this box is joined but UNTAGGED — possibly a login-joined (user-owned) machine re-run with join=authkey. It was joined before this run, so nothing was backed out. If it should be fleet-owned: run 'tailscale logout' and re-run with a TAGGED pre-auth key. If it is a workstation: re-run with --join login."
  fi

  # tag:server policy is DERIVED, not a trait: it means "the control plane
  # manages this box", and only control-plane-server and workload-server are shapes the
  # control plane manages. Everything else refuses it on the EFFECTIVE tag —
  # strictly stronger than the old request-time check, which only guarded the
  # tag rig HOPED for. The fleet has been bitten both ways: a runner-server carrying
  # tag:server extends every server grant to repo-controlled code, and a
  # staging host carrying it extends them to a box the control plane does not
  # even know. Refused, never warned; rig can DETECT this but cannot FIX it,
  # so each refusal names its repair.
  if printf '%s\n' "$tags" | grep -qx 'tag:server'; then
    case "$ROLE" in
      control-plane-server|workload-server) ;;
      runner-server)
        die "role runner-server joined with tag:server (effective tags: $(printf '%s' "$tags" | tr '\n' ' ')). The key you used grants tag:server to repo-controlled code; that must never happen. Re-run bootstrap with a key minted for a CI tag (e.g. tag:ci)." ;;
      *)
        # This arm owns the VM-host shape too — 'staging-server' by name now,
        # plus custom/dev-server --root-door open: a host is never managed by the
        # control plane — its guest VMs are — so tag:server is refused there
        # like everywhere else outside the two control-plane-managed shapes.
        # Mint the metal's key with tag:local.
        die "role $ROLE joined with tag:server (effective tags: $(printf '%s' "$tags" | tr '\n' ' ')). Only control-plane-server and workload-server are managed by the control plane; tag:server on this box extends every server grant to it. Re-run bootstrap with a key minted for a non-server tag (e.g. tag:local)." ;;
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

  # Fail CLOSED on a poll that never reached Running: empty tags is this
  # function's SUCCESS signal, which makes a timeout uniquely dangerous here —
  # a tagged node on a slow tailscaled reads as empty and would be waved
  # through as user-owned (verify_effective_tag has the mirror problem, but
  # there timeout-empty already lands in a refusal). Nothing was verified
  # either way, and the join may be perfectly fine, so neither mode logs out;
  # the only honest move is to stop and have the operator re-run the verify.
  if [ "$state" != "Running" ]; then
    die "tailscale backend never reached Running within 30s — could not verify the join is user-owned and untagged. Nothing was backed out; re-run bootstrap to verify once tailscaled settles."
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
  # — both in `keep` mode: never back out a join this run did not perform.
  if [ "$JOIN" = "login" ]; then
    verify_user_owned keep
  else
    verify_effective_tag keep
  fi
elif [ "$JOIN" = "login" ]; then
  # No pre-auth key on this path — the human at the keyboard is the credential.
  # `tailscale up` prints a login URL and blocks until the browser login lands.
  log "joining tailnet as ${TS_HOSTNAME} (interactive login; follow the URL tailscale prints)"
  tailscale up --hostname="$TS_HOSTNAME"
  verify_user_owned back-out
else
  # env override, else prompt; never touches disk. The prompt only fires on a
  # tty: with no terminal, a bare `read` exits non-zero and `set -e` would end
  # the whole bootstrap with NO last word — the 2026-07-19 drill met exactly
  # that, a log that stops mid-converge with exit 1 and nothing to grep. An
  # unattended run gets the same refusal every other guard gives: loud, and
  # naming the variable that unblocks it.
  if [ -z "${TS_AUTHKEY:-}" ]; then
    [ -t 0 ] || die "TS_AUTHKEY is unset and stdin is not a tty — set TS_AUTHKEY to run unattended"
    read -rsp "tailscale pre-auth key (single-use, tagged, <=1h expiry): " TS_AUTHKEY || { echo; die "no pre-auth key read (EOF) — set TS_AUTHKEY to run unattended"; }
    echo
  fi
  [ -n "${TS_AUTHKEY:-}" ] || die "empty pre-auth key"
  # No --advertise-tags: the key's own tags apply (documented default for a
  # tagged key), and rig verifies them below instead of stating a second tag it
  # cannot reconcile with the key's. A tagged key needs no flag; an untagged one
  # cannot be rescued by one (verify_effective_tag refuses it and logs out).
  log "joining tailnet as ${TS_HOSTNAME} (tag comes from the pre-auth key)"
  tailscale up --authkey="$TS_AUTHKEY" --hostname="$TS_HOSTNAME"
  verify_effective_tag back-out
fi

# --- role marker --------------------------------------------------------------
# /etc/rig/role is the traits' ground truth for later rig commands (`rig users`
# reads root-door= from it to decide root SSH's fate). Written only AFTER the
# tag verification, so a marker never describes a box that failed to become what
# it claims — and cmp-guarded like every file rig converges.
#
# The line is written in the CURRENT vocabulary only — `root-door=`, never the
# `class=` it replaced (#77). Writing both would keep an old rig reading a new
# marker, but it would also entrench the retired spelling on every box rig ever
# converges, and make the both-fields-disagree case reachable from rig's own
# hand instead of only from a text editor. The compat obligation runs the other
# way and is discharged in root_door_of: NEW rig reads OLD markers, because
# those exist in the field by the thousand and nothing will rewrite them.
MARKER=/etc/rig/role
MARKER_TMP="$(mktemp)"
printf 'role=%s root-door=%s host=%s join=%s\n' "$ROLE" "$ROOT_DOOR" "$HOST" "$JOIN" > "$MARKER_TMP"
if ! cmp -s "$MARKER_TMP" "$MARKER" 2>/dev/null; then
  mkdir -p /etc/rig
  install -m 0644 "$MARKER_TMP" "$MARKER"
  log "role marker written: role=$ROLE root-door=$ROOT_DOOR host=$HOST join=$JOIN"
else
  log "role marker already current"
fi
rm -f "$MARKER_TMP"

# --- provenance manifest ------------------------------------------------------
# /etc/rig/manifest records WHICH rig converged this machine and WHEN (#61).
# The marker above says what the box IS; this says what BUILT it — two files,
# two jobs, and the marker is deliberately untouched (it has six readers,
# install.sh:82-90 among them).
#
# Placed HERE, immediately after the marker, so the two agree by construction
# and both inherit the marker's discipline verbatim: written only AFTER the tag
# verification, so neither ever describes a box that failed to become what it
# claims. A manifest that survives a failed run is worse than no manifest — it
# is a confident wrong answer. It deliberately does NOT trail the box install
# and the users phase below: those are the host EXTRA and the operator phase,
# and a box whose people failed to converge was still converged BY this rig at
# this time. Stamping provenance is not a claim that everything after it
# succeeded — the marker beside it makes exactly the same claim, and the two
# landing together is what keeps them readable as one statement.
#
# The version stamped is the one that RAN, captured now — not what `rig
# --version` would answer after a later upgrade.
if manifest_stamp "$(manifest_running_version "$HERE/..")"; then
  log "provenance manifest written: $(manifest_path)"
else
  log "provenance manifest already current"
fi

# --- box install (host=yes only) -------------------------------------------
# A host=yes box exists to run guest boxes, so bootstrap finishes the job rather
# than printing a to-do: it installs the box CLI globally and lets box's OWN
# setup-host build the Incus stack. Placed AFTER the role marker write on
# purpose — a box that failed to become what it claims (tag refused, join backed
# out) dies above and never reaches here, so box is never installed on top of a
# half-built host.
#
# rig DELEGATES to box; it never touches Incus itself. This is the same design
# law `rig users apply` enforces — "rig NEVER installs Incus: box's setup-host
# owns the daemon and its group." rig does not apt-install incus, does not
# configure the daemon, does not create the incus group. It runs BOX'S global
# installer as root, and box installs Incus via its setup-host. Two tools
# converging one daemon is drift by construction; box is the single owner.
#
# CONVERGENT: box's installer is a no-op when box is already installed — it says
# so and changes nothing — so re-running bootstrap is safe and cheap.
#
# OPT-OUT: RIG_SKIP_BOX_INSTALL=1 skips the whole step (a container rehearsal
# with no /dev/kvm, an offline box, or a host whose box you manage by hand). The
# step ALSO skips gracefully — with a warning pointing at the manual command —
# when curl is missing or the network is down: bootstrap's core job is OS
# hardening + the tailnet, and box is the host EXTRA, so a failed box install
# must never abort a bootstrap that otherwise fully succeeded.
#
# PIN POINTS: BOX_REPO / BOX_REF override the source (default heavy-duty/box@main).
# BOX_YES=1 makes box's installer non-interactive AND keeps setup-host (so the
# Incus stack is actually built, not just the CLI dropped on PATH).
#
# rig#12's hard constraints hold here: the HOST joined the tailnet above; the
# guest boxes never do (box does not join the tailnet — fine), and there are no
# credentials on the host (box is creds-free — fine).
#
# DEPENDENCY (box#71): the GLOBAL, world-readable install path — box under
# /opt/box with a /usr/local/bin shim that every non-root user can read — depends
# on box PR #71. Until that merges, box's root install lands in /root and non-root
# users cannot reach it, so this step is only fully correct once box#71 is merged.
if [ "$HOST" = "yes" ]; then
  BOX_REPO="${BOX_REPO:-heavy-duty/box}"
  BOX_REF="${BOX_REF:-main}"
  BOX_INSTALL_URL="https://raw.githubusercontent.com/${BOX_REPO}/${BOX_REF}/install.sh"
  BOX_MANUAL="curl -fsSL ${BOX_INSTALL_URL} | BOX_YES=1 bash"
  if [ "${RIG_SKIP_BOX_INSTALL:-}" = "1" ]; then
    log "RIG_SKIP_BOX_INSTALL=1 — skipping box install; to prepare Incus by hand later: ${BOX_MANUAL}"
  elif ! command -v curl >/dev/null 2>&1; then
    warn "curl not found — skipping box install; once curl is present, prepare Incus with: ${BOX_MANUAL}"
  else
    log "installing box (${BOX_REPO}@${BOX_REF}) and running its host setup — box owns Incus, not rig"
    # BOX_YES=1 in the environment: non-interactive AND keeps setup-host, so box
    # builds the Incus stack rather than only dropping the CLI on PATH. Running as
    # root, box installs globally (/opt/box + /usr/local/bin). No-op if box is
    # already installed, so re-running bootstrap converges instead of reinstalling.
    # A curl failure (no network) fails the pipe under pipefail and lands in the
    # else — a warning, never an abort: box is the host extra, the OS+tailnet core
    # is already done.
    if curl -fsSL "$BOX_INSTALL_URL" | BOX_YES=1 bash; then
      # Don't trust the exit code — prove the effective state (issue #12). An
      # installer can exit 0 having done less than it claims: box's setup-host
      # is written for a sudo-capable user, and one of its paths exits 0 after
      # only adding a group, asking for a re-login. That is the sshd first-wins
      # bug's exact shape — asserting what was REQUESTED (here: the installer's
      # claimed success) instead of what actually TOOK.
      # Two proofs, one claim each. `command -v box` proves the CLI landed
      # (box's root install symlinks into /usr/local/bin, already on this
      # shell's PATH — no login shell needed). "Host set up" is a separate
      # claim and gets box's OWN effective-state verdict, `box doctor` —
      # the daemon, the pool, the network stay box's domain (the same
      # delegation law as the install itself: box owns the daemon), rig
      # just refuses to claim what that verdict does not answer. Both
      # failures WARN, never die: box is the host EXTRA, and the OS+tailnet
      # core above is already done and asserted.
      if command -v box >/dev/null 2>&1; then
        if box doctor >/dev/null 2>&1; then
          log "box installed and host set up — 'box doctor' passed; mint guest boxes with 'box new'"
        else
          warn "box is on PATH but 'box doctor' does not pass — the CLI landed, the host stack is unproven. Run 'box doctor' for the verdict, then 'box setup-host' (or finish by hand: ${BOX_MANUAL})"
        fi
      else
        warn "box's installer reported success but no 'box' is on PATH — the install did not take effect. Finish the host by hand: ${BOX_MANUAL}"
      fi
    else
      warn "box install did not complete (no network, or box's installer failed); bootstrap's core work is done. Finish the host by hand: ${BOX_MANUAL}"
    fi
  fi
fi

# --- users (the last phase, and it must be last) -------------------------------
# Ordering is a correctness property, not a preference. `users apply` READS
# /etc/rig/role: root-door= decides which root-SSH note it prints, and host= decides
# what an absent incus group means (refuse on yes, skip the box role with a
# warning on no). Run before the marker write, apply would see no marker at all
# and warn "re-run rig bootstrap so this box knows what it is" — in the middle
# of the very bootstrap that is teaching it. Run before the box install, a
# host=yes box would refuse its own box-role users for a group arriving twenty
# lines later. So: traits, then join, then marker, then box, then people.
#
# NOT persisted. rig takes the path, reads it once through apply, and keeps
# nothing — the users file lives in your private infra repo and is passed per
# invocation (README: "rig never persists it"). Taking it as a bootstrap flag
# must not quietly turn it into box state, so nothing here copies it anywhere,
# and /etc/rig keeps only the ledger of NAMES apply already wrote.
#
# Invoked as a child, not exec'd: bootstrap still owns the last word (the
# next-steps below), and a failing apply must fail the bootstrap — under
# `set -e` a non-zero apply ends the run right here, which is correct. The box
# is already hardened and joined at this point; what failed is one named phase,
# and it is re-runnable on its own with `rig users apply --file <path>`.
#
# A child also keeps apply's INVOKER gate intact, which is the point: SUDO_USER
# rides through, so `sudo rig bootstrap --users <file-naming-me-admin>` by a
# role-rig user refuses exactly as `sudo rig users apply` would. Bootstrap must
# not become a laundering path around the one gate that stops rig's scoped sudo
# from being root-equivalent. Bring-up runs as real root and is unaffected.
if [ -n "$USERS_FILE" ]; then
  log "converging operators from ${USERS_FILE} (rig users apply)"
  "$HERE/users-apply.sh" --file "$USERS_FILE"
fi

log "done — role ${ROLE}, hostname ${TS_HOSTNAME}"
if [ "$ROLE" = "control-plane-server" ]; then
  log "next: rig coolify install --version <pin>"
elif [ "$ROLE" = "runner-server" ]; then
  log "next: rig runner install --repo <owner/repo> --version <pin>"
fi
# Every box gets operators: humans always enter as themselves and elevate via
# sudo — a shared root login is unattributable. What differs, per the root-door
# trait, is root SSH's fate once named users exist. With --users the accounts exist already, so
# the note that used to point at the missing command now points at what is left
# to do; --no-users still owes the box its people, and says so.
if [ -n "$USERS_FILE" ]; then
  if [ "$ROOT_DOOR" = "closed" ]; then
    log "next: 'rig users close-root' once your admin key works — verify you can SSH in as an admin FIRST"
  else
    log "operators are converged; root SSH stays — it is the control plane's automation door"
  fi
else
  if [ "$ROOT_DOOR" = "closed" ]; then
    log "--no-users: this box has no named operators — root is its only door. When you want them: rig users apply --file <users-file>, then 'rig users close-root' once your admin key works"
  else
    log "--no-users: this box has no named operators — root SSH is its only door, and it stays (the control plane's automation door). For named logins: rig users apply --file <users-file>"
  fi
fi
