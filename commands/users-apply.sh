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

roles:
  admin   group rig-admin — full NOPASSWD sudo
  rig     group rig       — NOPASSWD sudo for /usr/local/bin/rig only
  box     the box restricted tier, no sudo. On a host=yes box rig delegates
          the whole grant to 'box grant <user>' (group, project, hardened
          boxnet) and a dropped user gets a bare 'box revoke' — box owns
          Incus, rig only asserts it is there.

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

declare -A USER_ROLES=() USER_KEYS=()
USERS=()
BOX_USERS=()
NEED_SUDO=0
NEED_INCUS=0
while IFS='|' read -r u r k; do
  [ -n "$u" ] || continue
  if [ -z "${USER_ROLES[$u]:-}" ]; then
    USERS+=("$u")
    USER_ROLES[$u]="$r"
    case ",$r," in *,box,*) BOX_USERS+=("$u") ;; esac
  fi
  USER_KEYS[$u]="${USER_KEYS[$u]:-}$k"$'\n'
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
# rig NEVER installs Incus: box's setup-host owns the daemon and its group. An
# absent incus group means that never ran — but what that MEANS is the host=
# trait's call. The box role binds where VMs live; a users file is fleet-wide,
# its box grants are not. So on host=yes an absent group is a broken VM host
# (refuse, point at setup-host), while on host=no it is simply not this box's
# role to converge — skip it, never abort the admins the file also carries.
INCUS_OK=0
if getent group incus >/dev/null; then INCUS_OK=1; fi
if [ "$NEED_INCUS" -eq 1 ] && [ "$INCUS_OK" -eq 0 ]; then
  case "$(read_role_marker "${RIG_ROLE_MARKER:-/etc/rig/role}")" in
    *host=yes*)
      die "a user carries role box and this box hosts VMs (host=yes) but group incus is absent — install the box CLI and run 'box setup-host' first (re-running 'rig bootstrap' does both); rig never installs Incus" ;;
    *host=no*)
      warn "box role skipped for ${BOX_USERS[*]}: this box does not host VMs (host=no); everything else converges" ;;
    *)
      warn "box role skipped for ${BOX_USERS[*]}: the role marker names no host= trait — re-run rig bootstrap so this box knows whether it hosts VMs" ;;
  esac
fi

# The box role is MORE than the incus group. box 0.6.0's restricted tier
# (box#75) is a per-user CONVERGENCE: box grant puts the user in the group AND
# narrows their incus-user project onto the hardened boxnet
# (restricted.networks.access=boxnet and ONLY boxnet), allows snapshots, and
# installs the box-net placement profile into their project. A bare group add —
# what this command did before — leaves incus-user's auto-created private
# bridge (a stock NAT bridge: no ACL, no DNS isolation, none of box's
# contract) one --network flag away from any box the operator mints. That
# undercuts the very contract bootstrap's "box owns Incus" delegation exists
# to uphold: the maintainer's whole point is that rig on a host-class machine
# wraps the devserver up END TO END, and an operator whose tier is only half
# granted is not wrapped up. So on a host=yes box rig DELEGATES the tier to
# `box grant` (idempotent convergence by design) and only asserts the
# preconditions — the same law as bootstrap's box install: rig never touches
# Incus itself.
#
# The gate is host=yes AND the box CLI resolving: host=no boxes already
# skipped the role above, and a host=yes box without the box CLI is a broken
# VM host exactly like the absent-group case — refuse and name the repair
# (bootstrap installs box and runs its setup-host), never quietly fall back
# to the bare group add the delegation exists to replace.
BOX_DELEGATE=0
if [ "$NEED_INCUS" -eq 1 ] && [ "$INCUS_OK" -eq 1 ]; then
  case "$(read_role_marker "${RIG_ROLE_MARKER:-/etc/rig/role}")" in
    *host=yes*)
      command -v box >/dev/null 2>&1 \
        || die "a user carries role box and this box hosts VMs (host=yes) but the box CLI is not installed — re-run 'rig bootstrap' (host=yes installs box and runs its setup-host); rig never installs Incus"
      BOX_DELEGATE=1 ;;
  esac
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
  # incus joins the wanted set only when the group exists (host=no boxes
  # skipped it above): converging membership in a conjured group would hand
  # the daemon's arrival an audience it never granted.
  case ",$roles," in *,box,*) if [ "$INCUS_OK" -eq 1 ]; then want="$want incus"; fi ;; esac
  for g in rig-admin rig incus; do
    case " $want " in
      *" $g "*)
        # Under delegation the incus ADD is box grant's alone — a deliberate
        # division so the two tools cannot fight. box grant performs its own
        # usermod -aG incus and, when a grant IT started fails, verifiably
        # backs that membership out: a half-granted user must not hold live
        # socket access onto an un-narrowed project. If rig added the group
        # first, box grant would read the user as a pre-existing member and
        # KEEP the group on failure — rig's eager add would have disarmed
        # box's own safety. So rig's exact-membership logic still DECLARES
        # incus wanted (the removal arm below must never strip a granted
        # membership), but the add is left to the grant that runs after this
        # loop. The REMOVE stays rig's: the moment the box role is gone,
        # want lacks incus and rig strips it — and box revoke's own
        # gpasswd -d is guarded on membership, so whichever side acts first,
        # the other is a clean no-op.
        if [ "$g" = "incus" ] && [ "$BOX_DELEGATE" -eq 1 ]; then
          :
        elif ! in_group "$u" "$g"; then
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
  AK_TMP="$(mktemp)"
  printf '%s' "${USER_KEYS[$u]}" > "$AK_TMP"
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

# --- box tier (host=yes): delegate to box grant ------------------------------
# AFTER the group convergence on purpose: the loop above settled every
# rig-managed membership except the delegated incus add, so box grant is the
# only writer of that group from here — its usermod and its verified back-out
# both act on state no rig line has pre-empted. Failure is a die, not a warn:
# an operator this apply is provisioning who did not actually receive the tier
# is a real refusal — reporting "converged" over it would be the bare-group-add
# bug wearing a success message. box grant's own back-out has already closed
# the group by the time we die, so the refused operator holds no socket
# access; everything converged before the failure stays converged, and a
# re-run picks up where this one stopped (grant is idempotent convergence).
#
# CHANGED is deliberately not touched here: box grant narrates its own
# convergence line by line ("already in 'incus'", "project ... already
# exists"), and rig cannot cheaply tell a no-op grant from a first one. The
# closing "already converged; no changes" therefore speaks only for rig's own
# moves — box's are printed right above it.
if [ "$BOX_DELEGATE" -eq 1 ]; then
  for u in "${BOX_USERS[@]}"; do
    log "box role for $u: delegating the restricted tier to box (box owns Incus, not rig)"
    box grant "$u" \
      || die "'box grant $u' failed — $u was NOT granted the box tier (box's own back-out closes the group on a failed grant, so they hold no socket access). Repair: check 'journalctl -u incus-user', make sure the host stack is built ('box setup-host', or re-run rig bootstrap), then re-run rig users apply — everything already converged stays converged."
  done
fi

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
    # Whether they held the tier is read BEFORE the strip: the ledger stores
    # names, not roles, and after the strip the membership that would have
    # said so is gone. This is also what keeps a re-run quiet — an
    # already-revoked user is no longer in incus, so box revoke is not
    # re-invoked to re-announce a tier that is already gone.
    had_incus=0
    if in_group "$prev" incus; then had_incus=1; fi
    for g in rig-admin rig incus; do
      if in_group "$prev" "$g"; then gpasswd -d "$prev" "$g" >/dev/null; fi
    done
    # box revoke, BARE — never with the purge flag: rig revokes access, it
    # does not destroy state ('home kept, nothing deleted' is this section's
    # own contract), and bare box revoke matches it exactly — the project and
    # its boxes stay restorable, 'box grant' brings everything back. The
    # group overlap cannot fight: rig stripped incus just above, so box
    # revoke's own gpasswd -d finds nothing to do and says so. What box
    # revoke ADDS is the tier's side of the story — the live-session warning
    # (group membership is read at login; a leftover tmux keeps the socket)
    # and the kept-project notice. A failure here is a WARN, not a die: the
    # access-closing move — the group strip — already happened by rig's own
    # hand, so nothing is left open; dying would strand the rest of the apply
    # (the ledger write below records the revocation) over messaging.
    if [ "$had_incus" -eq 1 ] && command -v box >/dev/null 2>&1; then
      box revoke "$prev" \
        || warn "'box revoke $prev' did not complete — their incus group is already stripped (rig's own strip above closed the socket at next login), but box could not report the tier's state; run 'box revoke $prev' by hand to check it"
    fi
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
