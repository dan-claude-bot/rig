#!/usr/bin/env bash
# rig users apply — converge named operator accounts from a declarative users
# file, on every class. Humans always enter as themselves and elevate via
# sudo: a shared root login is unattributable, so operators belong on servers
# too — class never gates this command, it only decides root SSH's fate AFTER
# users exist (close-root on human, kept as the control plane's automation
# door on server). Convergent: a second identical run changes nothing and
# says so.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/users-config.sh
. "$HERE/lib/users-config.sh"

log()  { printf 'rig-users: %s\n' "$*"; }
warn() { printf 'rig-users: WARNING: %s\n' "$*" >&2; }
die()  { printf 'rig-users: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
usage: rig users apply --file <path>

  --file <path>   users file (required; '-' reads it from stdin)

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
  box     group incus     — Incus restricted tier, no sudo (box's setup-host
                            owns the Incus install; rig only asserts it)

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
while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      [ $# -ge 2 ] || die "--file needs a value" 2
      FILE="$2"; shift 2 ;;
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

# Class is a note, never a refusal: #26's call is that operators belong on
# EVERY class — what differs is root SSH's fate once they exist.
case "$(read_role_marker "${RIG_ROLE_MARKER:-/etc/rig/role}")" in
  *class=server*) log "class=server: root SSH stays — it is the control plane's automation door" ;;
  *class=human*)  log "class=human: once your admin key works, 'rig users close-root' shuts the root door" ;;
  "")             warn "no /etc/rig/role marker — re-run rig bootstrap so this box knows what it is" ;;
esac

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

in_group() { id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qx "$2"; }

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
        if ! in_group "$u" "$g"; then
          usermod -aG "$g" "$u"
          log "added $u to $g"
          CHANGED=1
        fi ;;
      *)
        if in_group "$u" "$g"; then
          gpasswd -d "$u" "$g" >/dev/null
          log "removed $u from $g"
          CHANGED=1
        fi ;;
    esac
  done

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
    for g in rig-admin rig incus; do
      if in_group "$prev" "$g"; then gpasswd -d "$prev" "$g" >/dev/null; fi
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
