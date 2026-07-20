#!/usr/bin/env bash
# rig users apply — converge named operator accounts from a declarative users
# file, on every box. Humans always enter as themselves and elevate via
# sudo: a shared root login is unattributable, so operators belong on servers
# too — the root-door trait never gates this command, it only decides root
# SSH's fate AFTER users exist (close-root on root-door=closed, kept as the
# control plane's automation door on root-door=open). Convergent: a second
# identical run changes nothing and says so.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/users-config.sh
. "$HERE/lib/users-config.sh"

log()  { printf 'rig-users: %s\n' "$*"; }
warn() { printf 'rig-users: WARNING: %s\n' "$*" >&2; }
die()  { printf 'rig-users: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
usage: rig users apply --file <path> [--yes]

  --file <path>   users file (required; '-' reads it from stdin)
  --yes           consent, up front, to the one prompt this command can ask:
                  a file naming ZERO users against a box that still has
                  managed operators revokes all of them. RIG_YES=1 says the
                  same thing (the installer-family convention). Without
                  either, that case asks on a TTY and REFUSES (exit 2)
                  without one — it never assumes consent it cannot get.

The file is line-based and bash-parseable on purpose — a rig box has no YAML
parser and no jq, and gets neither for this. Whitespace-separated: user,
comma-joined roles, then the SSH public key (the rest of the line). '#'
comments and blank lines are fine. Repeated username lines add authorized
keys; the roles must be identical on every line of one user.

  # user   roles       ssh public key
  dan      admin,box   ssh-ed25519 AAAA... dan@laptop
  maria    rig,box     ssh-ed25519 AAAA... maria@mac

The key field may also be the literal token '@root': this user's
authorized_keys is seeded from root's CURRENT /root/.ssh/authorized_keys.
You provably hold a root private key — you SSHed in with it to run apply at
all — so the seeded key is the one key that cannot lock you out. '@root'
mixes with literal key lines: seeded keys land first, literal keys are
appended after them, and every re-run re-seeds from root's then-current file
(convergent to it — a seeded key you remove from the admin by hand returns;
switch the line to literal keys to pin them). Root's key lines are copied
verbatim, options included — a from= or command= restriction on a root key
follows it to the user. Apply dies if root has no authorized_keys to seed.

roles:
  admin   group rig-admin — full NOPASSWD sudo
  rig     group rig       — NOPASSWD sudo for /usr/local/bin/rig only
  box     group incus     — Incus restricted tier, no sudo. On host=yes apply
                            calls 'box grant <user>', which is the tier: the
                            group is only its socket, the user-<uid> project,
                            the boxnet-only narrowing, snapshots, backups and
                            the box-net profile are the rest of it. Dropping
                            the role hands the group back through
                            'box revoke' — never --purge: convergence removes
                            access, never someone's running boxes. box's
                            setup-host owns the Incus install; rig only
                            asserts it, and defers BOTH directions to box.

All passwords stay locked, always — the SSH key at the door is the
authentication, and NOPASSWD sudo does not weaken it. Convergent: membership
in the three rig-managed groups is made exact (other groups are never
touched), authorized_keys becomes exactly the file's keys, and a user dropped
from the file is REVOKED: account expired (which blocks SSH keys too, not
just the password), authorized_keys renamed to authorized_keys.revoked-by-rig,
rig groups stripped — home kept, nothing deleted, and re-adding the user
brings them back. Run as root; under sudo, only rig-admin members may — the
users family changes who holds root, so role rig's scoped sudo does not reach
it.
EOF
}

# --- args (validated before the root check, so errors are testable) ---------
FILE=""
# RIG_YES is the installer-family consent contract (bin/rig's uninstall_confirm
# reads the same variable): how automation says yes where there is no terminal
# to say it on. Set here so --yes and the env var are one flag with two doors.
ASSUME_YES=0
[ -n "${RIG_YES:-}" ] && ASSUME_YES=1
while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      [ $# -ge 2 ] || die "--file needs a value" 2
      FILE="$2"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown flag: $1" 2 ;;
  esac
done
[ -n "$FILE" ] || die "--file <path> is required" 2

# stdin is read ONCE into a temp: the file is parsed for validation and then
# walked again to converge, and a pipe only plays once.
if [ "$FILE" = "-" ]; then
  STDIN_TMP="$(mktemp)"
  cat > "$STDIN_TMP"
  FILE="$STDIN_TMP"
fi
[ -r "$FILE" ] || die "cannot read users file: $FILE" 2

# File parsing is argument validation: every error in the file is reported in
# one pass, exit 2, still before the root check.
PARSED="$(parse_users_file "$FILE")" \
  || die "invalid users file: $FILE — every error is listed above; nothing was changed" 2

declare -A USER_ROLES=() USER_KEYS=() USER_SEED=()
USERS=()
BOX_USERS=()
NEED_SUDO=0
NEED_INCUS=0
NEED_SEED=0
while IFS='|' read -r u r k; do
  [ -n "$u" ] || continue
  if [ -z "${USER_ROLES[$u]:-}" ]; then
    USERS+=("$u")
    USER_ROLES[$u]="$r"
    case ",$r," in *,box,*) BOX_USERS+=("$u") ;; esac
  fi
  # '@root' is a key SOURCE, not a key: remember who seeds and resolve the
  # actual lines after the root check — /root/.ssh is unreadable before it.
  if [ "$k" = "@root" ]; then
    USER_SEED[$u]=1
    NEED_SEED=1
  else
    USER_KEYS[$u]="${USER_KEYS[$u]:-}$k"$'\n'
  fi
  case ",$r," in *,admin,*|*,rig,*) NEED_SUDO=1 ;; esac
  case ",$r," in *,box,*) NEED_INCUS=1 ;; esac
done <<< "$PARSED"

# --- guards ------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root"

# Identity management gates its INVOKER, not just its uid: %rig's sudoers rule
# is binary-scoped but not argument-scoped, so without this gate a rig-role
# user could run `sudo rig users apply --file <me-as-admin>` — the scoped
# grant silently root-equivalent through this very command. Direct root (no
# SUDO_USER: bring-up, a root shell) proceeds.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] \
    && ! id -nG "$SUDO_USER" 2>/dev/null | tr ' ' '\n' | grep -qx rig-admin; then
  die "the users family changes who holds root — only rig-admin members (or root itself) may run it; role rig grants operational rig use, not identity management (invoker: $SUDO_USER)"
fi

# --- @root seed source (#17) -------------------------------------------------
# The lockout-avoidance move: the operator SSHed in as root to run this at
# all, so root's CURRENT authorized_keys provably contains a key they hold —
# the one claim no local check can make about a pasted literal. Resolved ONCE
# here (post-root-check: /root/.ssh needs root) and copied verbatim, options
# included: a from=/command= restriction on a root key line follows it to the
# user, which is honest — rig will not silently widen what a key can do.
# Comments and blanks are dropped so the seeded block is exactly key lines;
# an empty result is a hard stop, because seeding nothing would converge the
# admin's authorized_keys to empty and close-root would then refuse — better
# to name the real problem now.
ROOT_SEED_KEYS=""
if [ "$NEED_SEED" -eq 1 ]; then
  ROOT_SEED_KEYS="$(grep -Ev '^[[:space:]]*(#|$)' /root/.ssh/authorized_keys 2>/dev/null || true)"
  [ -n "$ROOT_SEED_KEYS" ] \
    || die "a user's keys seed from @root but root has no authorized_keys (/root/.ssh/authorized_keys missing or without key lines) — @root's whole point is copying a key you provably hold; list a literal key instead"
fi

# The root-door trait is a note here, never a refusal: #26's call is that
# operators belong on EVERY box — what differs is root SSH's fate once they
# exist. Resolved through root_door_of so this note and close-root's gate read
# one marker the same way, pre-#77 class= spellings included (#77): a box whose
# note says the door will shut must be a box where close-root agrees it shuts.
APPLY_MARKER="$(read_role_marker "${RIG_ROLE_MARKER:-/etc/rig/role}")"
if [ -z "$APPLY_MARKER" ]; then
  warn "no /etc/rig/role marker — re-run rig bootstrap so this box knows what it is"
else
  case "$(root_door_of "$APPLY_MARKER")" in
    open)   log "root-door=open: root SSH stays — it is the control plane's automation door" ;;
    closed) log "root-door=closed: once your admin key works, 'rig users close-root' shuts the root door" ;;
    # A marker naming both vocabularies in disagreement, or naming no door
    # policy at all, is exactly where close-root will refuse. Apply still
    # converges operators — that is the point of #26 — but it must not stay
    # quiet about the refusal waiting at the end of the sequence it just
    # pointed the operator at.
    conflict) warn "marker names both root-door= and the pre-#77 class= and they disagree ($APPLY_MARKER) — 'rig users close-root' will refuse until you re-run rig bootstrap" ;;
    *)        warn "marker names no root-door policy ($APPLY_MARKER) — 'rig users close-root' will refuse until you re-run rig bootstrap" ;;
  esac
fi

CHANGED=0

# --- sudo (only when some role actually grants through it) -------------------
if [ "$NEED_SUDO" -eq 1 ] && ! command -v sudo >/dev/null 2>&1; then
  log "installing sudo (admin/rig grants go through it)"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sudo
  CHANGED=1
fi

# --- groups ------------------------------------------------------------------
groupadd -f rig-admin
groupadd -f rig
# rig NEVER installs Incus: box's setup-host owns the daemon and its group.
#
# Whether the box role applies AT ALL is the host= trait's call, decided here,
# once, from the marker alone — never from what groups happen to exist on the
# machine (#58). The box role binds where VMs live; a users file is fleet-wide,
# its box grants are not. Apply used to ask the trait only when group incus was
# ABSENT, which meant a host=no or marker-less box that nonetheless carried the
# group (setup-host ran, then the box was re-bootstrapped with other traits)
# handed box-role users a bare `usermod -aG incus` — the socket with no tier
# behind it, and incus-user answers a socket it is given by lazily creating an
# UNHARDENED project under whoever opens it. The trait now decides the same way
# in both directions: BOX_ROLE_OK is the single gate, and the group's presence
# only ever answers the narrower question of whether a box that DOES claim to
# host VMs is ready to.
#
# The rejected alternative was letting the machine overrule the marker — treat
# a real incus group as evidence the box hosts VMs and converge anyway, warning
# that the marker disagrees. It reads reasonable, but it inverts what the rest
# of this family does with host=: the marker is the box's declared identity, and
# bootstrap is the one thing that writes it. Provisioning a VM-host tier onto a
# box that does not claim to be a VM host is rig deciding it knows better than
# the declaration, on evidence (a leftover group) that survives exactly the
# repurposing that makes the marker right and the group stale. The cost of
# choosing the marker is a genuine VM host mislabelled host=no that stops
# provisioning — so this does not do it SILENTLY: the skip warning below names
# the contradiction and names `rig bootstrap` as the one-line repair.
#
# Consequence worth stating plainly: on such a box the exact-membership
# convergence below will now STRIP box-role users out of incus rather than
# leave them there. That is the same call, not a second one. A membership
# inherited from a previous life is the identical half-grant state as one
# freshly added — socket, no tier — and rig's promise for its three managed
# groups is exactness, not "exact except where drift got there first".
INCUS_OK=0
if getent group incus >/dev/null; then INCUS_OK=1; fi
BOX_ROLE_OK=0
BOX_ROLE_WHY=""
if BOX_ROLE_WHY="$(assert_marker_hosts_vms "${RIG_ROLE_MARKER:-/etc/rig/role}")"; then
  BOX_ROLE_OK=1
fi
if [ "$NEED_INCUS" -eq 1 ] && [ "$BOX_ROLE_OK" -eq 0 ]; then
  # The group being present while the trait says otherwise is the marker/reality
  # mismatch — the case that used to slip through — so it gets its own sentence
  # rather than the generic skip. Never a die: a fleet-wide users file naming a
  # box-role user somewhere must not abort the admins it also carries here.
  if [ "$INCUS_OK" -eq 1 ]; then
    warn "box role skipped for ${BOX_USERS[*]}: $BOX_ROLE_WHY — yet group incus EXISTS here, so this box's marker and this box's reality disagree. rig believes the marker and grants nothing (the group alone is only the socket; without the tier behind it incus-user would lazily build an unhardened project under whoever opens it). If this machine really does host VMs, re-run rig bootstrap with --host yes and apply again; everything else converges"
  else
    warn "box role skipped for ${BOX_USERS[*]}: $BOX_ROLE_WHY; everything else converges"
  fi
fi
if [ "$NEED_INCUS" -eq 1 ] && [ "$BOX_ROLE_OK" -eq 1 ] && [ "$INCUS_OK" -eq 0 ]; then
  die "a user carries role box and this box hosts VMs (host=yes) but group incus is absent — install the box CLI and run 'box setup-host' first; rig never installs Incus"
fi

# --- the box TIER, not just its socket (#49) ---------------------------------
# Group incus is step 1 of the five 'box grant' performs: the group is the
# SOCKET, while the tier is the per-user convergence behind it — the
# user-<uid> project, its narrowing to boxnet and only boxnet, the snapshot
# and backup allowances clone and 'box export' ride, and the shipped box-net
# profile installed into that project. rig doing step 1 alone left every
# box-role user's first 'box new' refusing ("your project has no box-net
# profile"), so apply's promise — the users file is the fleet's source of
# truth — was not kept for this role. It is kept by CALLING box's own grant
# rather than reimplementing four fifths of it: 'box grant' is idempotent,
# root-or-sudo (which apply already is), stdin-pinned so no incus client can
# wedge waiting on an answer, and does its own run-as-the-user touch, so the
# granted user never has to log in first for the lazy project to exist.
#
# Only on host=yes. The box role binds where VMs live, and the two other
# arms of the host= decision above are deliberately untouched: host=no keeps
# its skip-with-warning, and a marker with no host= trait keeps its own.
# Granting a tier on a box that does not host VMs would be converging policy
# into a daemon that is not there to enforce it.
#
# The box CLI's ABSENCE is a host-level fact, so it dies here, in the same
# register and for the same reason as the missing-incus-group die above: a
# host=yes box carrying box-role users but no box CLI is a broken VM host,
# not a per-user accident, and no amount of continuing converges it.
BOX_GRANT=0
if [ "$NEED_INCUS" -eq 1 ] && [ "$INCUS_OK" -eq 1 ]; then
  case "$(read_role_marker "${RIG_ROLE_MARKER:-/etc/rig/role}")" in
    *host=yes*)
      command -v box >/dev/null 2>&1 \
        || die "a user carries role box and this box hosts VMs (host=yes) but the box CLI is not on PATH — the incus group is only the socket; the restricted tier is 'box grant', which rig calls rather than reimplements. Install the box CLI (rig bootstrap does it on host=yes) and re-run"
      BOX_GRANT=1 ;;
  esac
fi

in_group() { id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qx "$2"; }

# --- dropping role box: give the group back to the tool that owns it (#50) ---
# rig-admin and rig are rig's own groups, and `gpasswd -d` is the whole story
# for them. incus is not rig's: box's setup-host creates it, `box grant` hands
# it out, and `box revoke` takes it back — doing strictly MORE than removing
# the membership. It says out loud what removing the membership does not do:
# supplementary groups are read at LOGIN, so a session the dropped operator
# already holds keeps the Incus socket until that session dies, and the remedy
# is `loginctl terminate-user <user>`. rig's bare `gpasswd -d` logged "removed
# <user> from incus" and left it there, so an operator who dropped someone from
# the users file and watched apply succeed believed the VM access was gone —
# and was wrong for as long as that user held a session.
#
# So box takes its own group back. The fallback below exists for the host where
# box is not installed (someone else built the Incus stack, or box was removed
# from under it), and it carries the session warning ITSELF: the silence is the
# bug being fixed, not the gpasswd call.
#
# NEVER --purge from here. A bare revoke ends access and leaves the user's
# project and boxes intact — still RUNNING, because revoking a person does not
# kill their workloads. Deleting them is irreversible and is not a convergence
# step: an edit to the users file must never destroy someone's machines behind
# an admin's back. `box revoke <user> --purge`, run deliberately, is where that
# lives.
#
# The absent-group case needs no guard of its own: `id -nG` cannot report a
# group that does not exist, so every caller's `in_group` test is already false
# on a host=no box or one where `box setup-host` never ran — there is nothing
# to revoke, and apply says nothing and moves on.
drop_incus() { # drop_incus <user> — hand group 'incus' back to box
  local u="$1"
  if command -v box >/dev/null 2>&1; then
    # Don't trust the exit code — prove the effective state (the #12 lesson,
    # the same one bootstrap applies to box's installer). A revoke that exits
    # 0 having left the membership in place would otherwise be reported as a
    # removal; the membership is what closes the socket, so it gets checked.
    if box revoke "$u" && ! in_group "$u" incus; then
      log "removed $u from incus (via 'box revoke' — box owns that group)"
      return 0
    fi
    warn "'box revoke $u' did not remove the incus group — removing it directly; check box on this host"
  fi
  if in_group "$u" incus; then
    gpasswd -d "$u" incus >/dev/null
    log "removed $u from incus"
  fi
  # box's warning, in rig's voice, because rig is the one that took the group
  # here. pgrep decides whether it applies; if pgrep is absent rig cannot tell,
  # and an unnecessary warning costs an operator one command while a missing
  # one costs them a wrong belief about who can reach the daemon.
  if ! command -v pgrep >/dev/null 2>&1 || pgrep -u "$u" >/dev/null 2>&1; then
    warn "$u may hold live sessions, and group membership is read at login — those sessions keep the Incus socket until they end. To end them now: loginctl terminate-user $u"
  fi
}

# --- converge each user ------------------------------------------------------
for u in "${USERS[@]}"; do
  if ! id -u "$u" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$u"
    log "created user $u"
    CHANGED=1
  fi
  # Locked always, created or found: no password ever exists to guess or
  # rotate — the SSH key at the door is the authentication. The expiry is
  # cleared just as idempotently: revocation below IS an expiry date, so a
  # user dropped once and re-added comes back to life on this line.
  usermod -L -e '' "$u"

  # Membership in the three rig-managed groups is made EXACT — added and
  # removed to match the file. Other groups are never touched: they are not
  # rig's to converge.
  roles="${USER_ROLES[$u]}"
  want=""
  case ",$roles," in *,admin,*) want="$want rig-admin" ;; esac
  case ",$roles," in *,rig,*)   want="$want rig" ;; esac
  # incus joins the wanted set only when the box role APPLIES to this box —
  # the host= trait's call, made once above — and only when the group is
  # actually there. Deliberately a gate on whether the role applies, not on
  # the add: it is the same question no matter who performs the add, so it
  # keeps answering correctly if the add itself later moves elsewhere (#53
  # defers it to `box grant`). BOX_ROLE_OK=1 already implies the group exists
  # (the arm above dies otherwise), but INCUS_OK is kept in the condition
  # because converging membership in a conjured group would hand the daemon's
  # arrival an audience it never granted, and that must not depend on a
  # neighbouring branch staying fatal.
  case ",$roles," in *,box,*) if [ "$BOX_ROLE_OK" -eq 1 ] && [ "$INCUS_OK" -eq 1 ]; then want="$want incus"; fi ;; esac
  for g in rig-admin rig incus; do
    case " $want " in
      *" $g "*)
        # incus stays in the WANTED set — that is what keeps the exact
        # convergence below from stripping a box-role user's socket — but on
        # a host where we are about to run 'box grant', the ADD is deferred to
        # grant itself. Two reasons, both load-bearing:
        #
        # Grant's rollback only reaches a membership THAT RUN added: a user it
        # finds already in incus keeps it when a later step trips
        # (box/host/grant-user.sh's was_member branch), by design — stripping
        # a membership it did not add could break a working user over a failed
        # re-run. So if rig opens the socket first, grant can no longer close
        # it, and a grant that fails midway leaves the user holding live
        # access to an UN-narrowed project: the stock unhardened incusbr-<uid>
        # one --network flag away. That state is strictly worse than no grant
        # at all, which is the sharp end of #49. Deferring makes the socket and
        # the tier land together or fail together.
        #
        # And grant is the authority on whether the group belongs at all: for
        # an incus-admin member it deliberately does NOT add incus (admin
        # membership already wins at the socket, so the row would only mislead
        # whoever reads the group list later). rig adding it here would put a
        # membership on that user which box has decided against — not a loop
        # that oscillates, but rig overruling box on box's own tier, which is
        # exactly the boundary this whole change is respecting.
        if [ "$g" = incus ] && [ "$BOX_GRANT" -eq 1 ]; then continue; fi
        if ! in_group "$u" "$g"; then
          usermod -aG "$g" "$u"
          log "added $u to $g"
          CHANGED=1
        fi ;;
      *)
        if in_group "$u" "$g"; then
          if [ "$g" = incus ]; then
            drop_incus "$u"
          else
            gpasswd -d "$u" "$g" >/dev/null
            log "removed $u from $g"
          fi
          CHANGED=1
        fi ;;
    esac
  done

  # The tier itself. AFTER the account exists — 'box grant' opens with a
  # getent passwd and refuses an unknown user — and after the other groups,
  # so a user whose grant fails still lands with everything rig owns outright.
  #
  # Per-user failures WARN and continue, matching the governing call the
  # host= split above already makes: one box-role user somewhere in the fleet
  # must not stop apply everywhere VMs don't live, and a project that would
  # not converge is exactly that shape of local fact. Host-level facts still
  # die, but they die before this loop — the missing group and the missing
  # CLI both. What is left here (project creation refused, an instance still
  # parked on the private bridge blocking the narrowing, an incus-user socket
  # that will not answer) is per-user by construction.
  if [ "$BOX_GRANT" -eq 1 ]; then
    case ",$roles," in
      *,box,*)
        had_socket=0
        if in_group "$u" incus; then had_socket=1; fi
        log "granting $u the box restricted tier (box grant $u)"
        grant_rc=0
        box grant "$u" || grant_rc=$?
        if [ "$grant_rc" -eq 0 ]; then
          # CHANGED is a claim about what apply DID, and the only part of the
          # grant rig can observe from out here is the group transition —
          # every other step converges inside incus's own state, with no cheap
          # "already converged?" probe short of redoing the work. So report
          # the transition when it happens and stay silent otherwise: a
          # convergent call that changed nothing must not turn "already
          # converged; no changes" into a permanent lie on every host=yes box.
          if [ "$had_socket" -eq 0 ] && in_group "$u" incus; then
            log "granted $u the restricted tier (incus group, user-$(id -u "$u") project, boxnet-only, box-net profile)"
            CHANGED=1
          fi
        elif in_group "$u" incus-admin; then
          # Today 'box grant' refuses incus-admin members outright — it reads
          # their admin membership as "there is nothing tighter to grant",
          # which conflates permission with provisioning: they hold the full
          # socket but have no project of their own. heavy-duty/box#99 makes
          # grant provision them instead of refusing, at which point this
          # branch simply stops being reached — no rig change needed, because
          # rig asks for the tier and lets box decide what that means. Until
          # then the honest report is that nothing was lost: they still hold
          # strictly more access than the tier would give them.
          warn "box grant $u exited $grant_rc and $u is in incus-admin, which box refuses to grant today — they keep the full socket (incus-admin is strictly stronger than the tier), but they get no user-<uid> project of their own and land in the shared default project alongside every other admin. Blocked on heavy-duty/box#99; everything else converged, and a later apply picks the tier up once box stops refusing"
        else
          warn "box grant $u exited $grant_rc: $u has their account, keys and rig groups, but NOT the box restricted tier — no user-<uid> project, no boxnet narrowing, no box-net profile, so their 'box new' will refuse. box's own output above names the cause; fix it and re-run apply (or 'box grant $u' by hand). Every other user still converged — one box-role user must not stop apply for the fleet"
        fi ;;
    esac
  fi

  # authorized_keys becomes exactly the file's keys — only the content WRITE
  # is cmp-guarded, so an unchanged file is a clean no-op. Ownership and mode
  # converge UNCONDITIONALLY: sshd's StrictModes treats them as load-bearing
  # (a group-writable .ssh is a rejected key), so drifted perms behind
  # matching content would otherwise stay broken while apply logs "already
  # converged". Perms are part of the converged state.
  home="$(getent passwd "$u" | cut -d: -f6)"
  ugroup="$(id -gn "$u")"
  mkdir -p "$home/.ssh"
  # Seeded (@root) keys land FIRST, literal lines append after — fixed order
  # so the cmp-guard sees identical bytes on identical state and re-runs
  # converge to root's then-current keys plus the literals (#17). A literal
  # that duplicates a seeded key writes twice; sshd does not mind and the
  # bytes stay deterministic.
  AK_TMP="$(mktemp)"
  {
    if [ -n "${USER_SEED[$u]:-}" ]; then printf '%s\n' "$ROOT_SEED_KEYS"; fi
    printf '%s' "${USER_KEYS[$u]:-}"
  } > "$AK_TMP"
  if ! cmp -s "$AK_TMP" "$home/.ssh/authorized_keys" 2>/dev/null; then
    install -m 0600 -o "$u" -g "$ugroup" "$AK_TMP" "$home/.ssh/authorized_keys"
    log "authorized_keys for $u: $(grep -c . "$AK_TMP") key(s)"
    CHANGED=1
  fi
  rm -f "$AK_TMP"
  chmod 0700 "$home/.ssh"
  chown "$u:$ugroup" "$home/.ssh"
  chmod 0600 "$home/.ssh/authorized_keys"
  chown "$u:$ugroup" "$home/.ssh/authorized_keys"
done

# --- previously managed users no longer in the file --------------------------
# The ledger is what lets a REMOVED user be found at all — so it must REMEMBER
# them: two-field lines, 'name active' / 'name revoked' (a legacy bare name
# reads as active). Revoked, not deleted: deleting frees the uid for reuse and
# orphans file ownership — attribution would rot. Home stays for the same
# reason. But revoked must actually mean revoked: a '!'-locked password is not
# a closed door under UsePAM — Debian sshd still honors the pubkey — so the
# lock alone left a dropped operator with working SSH. Account expiry (a date
# in the past) is the switch PAM actually enforces, against every auth method
# including keys; the keys themselves are renamed, never deleted — access
# revoked, data kept, convergence never destroys.
LEDGER=/etc/rig/users
REVOKED=()

# --- the empty-file gate (#65) -----------------------------------------------
# "Revoke everyone" and "I truncated the file" are the same instruction in this
# file format, and apply cannot read intent. What it CAN read is the ledger, and
# that draws the only line worth drawing: a file naming zero users against an
# empty ledger is an unambiguous no-op, while the same file against a populated
# one closes every named door on the box. Only the second is dangerous.
#
# So this is a CONFIRMATION, not a refusal — deliberately unlike bootstrap's
# flat die on the same file (#57/#59). bootstrap ASSERTS who lives on a box, so
# an empty answer there is a self-contradiction; apply CONVERGES, and converging
# to zero is a complete, legitimate de-provisioning that must keep working. The
# difference between the two commands is the whole point, and it survives here.
#
# The per-user warnings below are not this gate and cannot replace it: they
# arrive after the decision, one line per operator, so the signal is loudest
# exactly where it reads as scrollback rather than as a question.
#
# Count FIRST, then speak: the message states a real number, and counting is
# what makes the already-converged case silent. An entry the ledger already
# marks `revoked`, or one whose account no longer exists, is not at risk — this
# run would not change it — so a second identical run of an emptied file stays
# the clean no-op convergence promises, with no prompt to answer twice.
#
# SCOPE: the bright line only. Whether a file that drops 19 of 20 operators
# deserves the same gate is the issue's open question — it needs a threshold
# someone has to justify, where "the file is empty" needs nothing. Left open.
if [ "${#USERS[@]}" -eq 0 ] && [ -r "$LEDGER" ] && [ "$ASSUME_YES" -eq 0 ]; then
  AT_RISK=0
  while read -r prev pstate _; do
    [ -n "$prev" ] || continue
    [ "${pstate:-active}" != "revoked" ] || continue
    id -u "$prev" >/dev/null 2>&1 || continue
    AT_RISK=$((AT_RISK + 1))
  done < "$LEDGER"
  if [ "$AT_RISK" -gt 0 ]; then
    warn "this users file names ZERO users, and this box still manages $AT_RISK operator(s): applying it revokes every one of them — accounts expired, authorized_keys renamed, rig groups stripped. If the file was meant to be empty this is de-provisioning; if it was truncated by accident, stop here."
    # No terminal means no consent, and a question nobody can answer must not
    # be assumed into a yes or left to hang. Same shape and same words as
    # bin/rig's uninstall_confirm, on purpose — one refusal in this codebase.
    if [ ! -t 0 ]; then
      printf 'rig-users: refusing to revoke every managed operator without --yes (no terminal to confirm on; RIG_YES=1 also means yes)\n' >&2
      exit 2
    fi
    # `|| reply=""` is load-bearing: under `set -e` a read that hits EOF is a
    # non-zero command, and an unguarded read would abort the script rather
    # than take the safe default (#68, the same bug class).
    printf 'rig-users: revoke all %s managed operator(s) on this box? [y/N] ' "$AT_RISK"
    read -r reply || reply=""
    case "$reply" in
      y|Y|yes|YES|Yes) ;;
      *) die "aborted — no operator was revoked" ;;
    esac
  fi
fi

if [ -r "$LEDGER" ]; then
  while read -r prev pstate _; do
    [ -n "$prev" ] || continue
    case " ${USERS[*]:-} " in *" $prev "*) continue ;; esac
    id -u "$prev" >/dev/null 2>&1 || continue
    usermod -L -e 1 "$prev"
    prevhome="$(getent passwd "$prev" | cut -d: -f6)"
    if [ -f "$prevhome/.ssh/authorized_keys" ]; then
      mv "$prevhome/.ssh/authorized_keys" "$prevhome/.ssh/authorized_keys.revoked-by-rig"
    fi
    # incus goes back through box here too — a user dropped from the file
    # entirely is exactly the offboarding this warning was written for, and it
    # would be perverse for the full revocation to be the quiet one. It fires
    # once, on the transition: the membership is gone on the next run, so
    # in_group is false and an already-revoked user stays a clean no-op.
    for g in rig-admin rig incus; do
      if in_group "$prev" "$g"; then
        if [ "$g" = incus ]; then
          drop_incus "$prev"
        else
          gpasswd -d "$prev" "$g" >/dev/null
        fi
      fi
    done
    REVOKED+=("$prev")
    # Warn on the TRANSITION only: an already-revoked user is converged above
    # (quietly — repairing drift, not announcing news) so a second identical
    # run stays a clean no-op.
    if [ "${pstate:-active}" != "revoked" ]; then
      warn "$prev is no longer in the file: account expired (blocks SSH keys too, not just the password), authorized_keys renamed to authorized_keys.revoked-by-rig, rig groups stripped (home kept — rig never deletes a user)"
      CHANGED=1
    fi
  done < "$LEDGER"
fi
LEDGER_TMP="$(mktemp)"
if [ "${#USERS[@]}" -gt 0 ]; then printf '%s active\n' "${USERS[@]}" > "$LEDGER_TMP"; fi
if [ "${#REVOKED[@]}" -gt 0 ]; then printf '%s revoked\n' "${REVOKED[@]}" >> "$LEDGER_TMP"; fi
if ! cmp -s "$LEDGER_TMP" "$LEDGER" 2>/dev/null; then
  mkdir -p /etc/rig
  install -m 0644 "$LEDGER_TMP" "$LEDGER"
  CHANGED=1
fi
rm -f "$LEDGER_TMP"

# --- sudoers -----------------------------------------------------------------
# Both group rules ship in one drop-in whether or not both roles are in use:
# the groups exist and the rules are inert without members. visudo gates the
# install because a bad file under /etc/sudoers.d can take down ALL of sudo —
# locking every admin out of the very escalation path apply just granted.
SUDOERS_TMP="$(mktemp)"
cat > "$SUDOERS_TMP" <<'EOF'
# Managed by `rig users apply` — do not edit; the next apply converges it.
%rig-admin ALL=(ALL:ALL) NOPASSWD: ALL
%rig ALL=(root) NOPASSWD: /usr/local/bin/rig
EOF
if command -v visudo >/dev/null 2>&1; then
  visudo -c -f "$SUDOERS_TMP" >/dev/null \
    || die "sudoers candidate failed validation — /etc/sudoers.d untouched; candidate kept at $SUDOERS_TMP for inspection"
  if ! cmp -s "$SUDOERS_TMP" /etc/sudoers.d/rig-roles 2>/dev/null; then
    install -m 0440 "$SUDOERS_TMP" /etc/sudoers.d/rig-roles
    log "sudoers role rules installed (/etc/sudoers.d/rig-roles)"
    CHANGED=1
  fi
  rm -f "$SUDOERS_TMP"
else
  # No sudo on the box means no role needed it (the install above would have
  # run otherwise): rules for a binary that is not there can wait for the
  # apply that brings a sudo-bearing role.
  rm -f "$SUDOERS_TMP"
  log "sudo not installed and no role needs it; skipping the sudoers drop-in"
fi

if [ "$CHANGED" -eq 0 ]; then
  log "already converged; no changes"
else
  log "converged ${#USERS[@]} user(s)"
fi
