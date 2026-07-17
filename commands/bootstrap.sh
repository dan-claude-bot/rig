#!/usr/bin/env bash
# rig bootstrap — OS plumbing for a pristine Debian box.
# Convergent: safe to re-run; a second run changes nothing.
set -euo pipefail

log()  { printf 'rig-bootstrap: %s\n' "$*"; }
warn() { printf 'rig-bootstrap: WARNING: %s\n' "$*" >&2; }
die()  { printf 'rig-bootstrap: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
usage: rig bootstrap <control-plane|workload|runner> [--hostname <name>]
                     [--ts-tag <tag>] [--admin-user <name>] [--admin-key <pubkey>]
                     [--lock-root]

  --hostname    system + tailnet hostname (default: the role name)
  --ts-tag      tailnet tag to advertise (default: tag:server;
                role runner defaults to tag:ci and refuses tag:server —
                a CI box executes repo-controlled code, and your server
                tag's grants must never extend to it)
  --admin-user  non-root admin account to create on every role (default: admin;
                refuses root). sudo group, key-only, NEVER the docker group.
                Its authorized_keys is seeded ONCE from root's at creation —
                you are connected as root with one of those keys right now, so
                the copy is live proof the private key is in your hands.
  --admin-key   an extra public key to add to the admin account at creation,
                composed with the seed above (optional).
  --lock-root   close root's SSH door (PermitRootLogin no) once the admin user
                is proven reachable. ROLE-GATED: refused on control-plane
                (Coolify SSHes to its OWN host) and on workload (needs Coolify's
                experimental non-root mode, which rig does not provision);
                allowed on runner.

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
if [ "$ROLE" = "runner" ]; then
  TS_TAG="tag:ci"
else
  TS_TAG="tag:server"
fi
ADMIN_USER="admin"   # generic default; nothing org-specific ever ships in rig
ADMIN_KEY=""
LOCK_ROOT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --hostname)
      [ $# -ge 2 ] || die "--hostname needs a value" 2
      TS_HOSTNAME="$2"; shift 2 ;;
    --ts-tag)
      [ $# -ge 2 ] || die "--ts-tag needs a value" 2
      TS_TAG="$2"; shift 2 ;;
    --admin-user)
      [ $# -ge 2 ] || die "--admin-user needs a value" 2
      ADMIN_USER="$2"; shift 2 ;;
    --admin-key)
      [ $# -ge 2 ] || die "--admin-key needs a value" 2
      ADMIN_KEY="$2"; shift 2 ;;
    --lock-root)
      LOCK_ROOT=1; shift ;;
    *) die "unknown flag: $1" 2 ;;
  esac
done

# A runner executes repo-controlled code; advertising the server tag would
# extend every grant your servers hold to that code. Refused, not warned.
if [ "$ROLE" = "runner" ] && [ "$TS_TAG" = "tag:server" ]; then
  die "role runner must not advertise tag:server" 2
fi

# The admin account is the non-root human door; making it "root" is a
# contradiction in terms. Refused, not warned — same spirit as runner-install
# refusing --user root.
[ "$ADMIN_USER" != "root" ] || die "--admin-user must not be root" 2

# Role-aware root policy. --lock-root means exactly `PermitRootLogin no` (see the
# lock-root block far below for why not the other four "lock root" techniques),
# and on the two Coolify roles that is a self-inflicted fleet outage, so it is
# REFUSED here (exit 2) rather than warned — a flag that silently bricks a box's
# only door is worse than no flag. Validated before the root check so the
# refusal is unit-testable without a live box.
if [ "$LOCK_ROOT" -eq 1 ]; then
  case "$ROLE" in
    control-plane)
      die "role control-plane must not --lock-root: Coolify reaches its OWN host over SSH (host.docker.internal) and non-root localhost is unsupported upstream (coollabsio/coolify#4245); PermitRootLogin no would cut the control plane off from itself" 2 ;;
    workload)
      die "role workload must not --lock-root: closing root here needs Coolify's experimental non-root mode — a 'coolify' user with NOPASSWD: ALL (root by another name), which rig does not provision. Get attribution cheaper via sshd key-fingerprint logging + auditd. Revisit when Coolify ships granular sudo" 2 ;;
    runner)
      : ;;  # no Coolify on a runner; lock-root is allowed once the admin proves reachable
  esac
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
# sudo: the admin user below is placed in the sudo group, which the sudo
# package creates — and the lock-root verification runs `sudo -n true` under
# the admin before it will close root's door. A pristine Debian container ships
# neither the package nor the group; cloud images do.
apt-get install -y -qq curl ca-certificates unattended-upgrades openssh-server sudo

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
# `no` is accepted here too, not just the two prohibit-password spellings: once
# --lock-root has installed 00-rig-root.conf (below), the effective policy is
# `no`, which is STRICTLY MORE restrictive (root cannot log in at all, password
# or key). Refusing it would make the very first re-run of a locked box die in
# the base-hardening assert — breaking convergence exactly where it matters
# most. `no` still means "no root password login", so it satisfies the intent.
echo "$eff" | grep -qxE 'permitrootlogin (prohibit-password|without-password|no)' \
  || die "sshd still permits root password login — check ls /etc/ssh/sshd_config.d/"
log "sshd hardening verified (sshd -T: passwordauthentication no)"

# --- admin user (a non-root human door on every role) ------------------------
# rig hardens the SSH door but, until now, never created a human to walk through
# it: every box was administered as root, survivable only because of the
# prohibit-password drop-in above. The admin is a non-root account in the sudo
# group with an SSH key — and NEVER the docker group: the docker socket is a
# root API and docker-group membership is root-equivalent, a gratuitous path to
# root that runner-install refuses for the same reason. sudo is the ONLY
# supplementary group it gets. Created on every role (control-plane included,
# where root must stay) so there is always a human door even where root's stays
# open.
ADMIN_HOME="$(getent passwd "$ADMIN_USER" 2>/dev/null | cut -d: -f6)"
if [ -z "$ADMIN_HOME" ]; then
  log "creating admin user ${ADMIN_USER} (sudo group, no docker)"
  useradd --create-home --shell /bin/bash "$ADMIN_USER"
  usermod -aG sudo "$ADMIN_USER"
  ADMIN_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"

  # NOPASSWD sudo for the admin — and yes, this is the same NOPASSWD the issue
  # warns against for Coolify's service user. The distinction is who holds the
  # account: the admin is a HUMAN who authenticates with an SSH key they hold
  # and has NO password (useradd leaves the password locked). Requiring a sudo
  # password they do not have would make sudo unusable — a non-root user who
  # cannot escalate is not an admin. Key-only + NOPASSWD sudo is exactly what
  # Debian/Ubuntu cloud images do for their default user. It is wrong for
  # Coolify's user (a non-human identity you are trying to CONSTRAIN, where
  # NOPASSWD hands an attacker who takes the account full root and makes
  # attribution merely cooperative); it is right for a human you are EMPOWERING.
  # visudo -cf validates before install: a malformed sudoers file breaks sudo
  # for everyone, and we are about to (maybe) close root's door behind it.
  SUDOERS_TMP="$(mktemp)"
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$ADMIN_USER" > "$SUDOERS_TMP"
  if visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then
    install -m 0440 -o root -g root "$SUDOERS_TMP" "/etc/sudoers.d/90-rig-${ADMIN_USER}"
  else
    rm -f "$SUDOERS_TMP"
    die "generated sudoers file for ${ADMIN_USER} failed visudo -c; not installed"
  fi
  rm -f "$SUDOERS_TMP"

  # Seed authorized_keys from ROOT's — ONCE, at creation, and never again.
  #   WHY seed from root: the operator is connected as root RIGHT NOW using one
  #   of root's keys, so copying them into the admin account is live proof the
  #   matching private key is in their hands — strictly better than any check
  #   rig could invent, needs no new argument, and a public key is not a secret,
  #   so "no credential, ever" does not bend.
  #   WHY only once: re-seeding on every run would resurrect a key the operator
  #   DELIBERATELY removed from the admin account. Seed-once is therefore, in
  #   strict honesty, NOT convergent — an exception named here rather than
  #   papered over. An existing admin user (the else branch) is left untouched.
  install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$ADMIN_HOME/.ssh"
  ADMIN_KEYS="$ADMIN_HOME/.ssh/authorized_keys"
  : > "$ADMIN_KEYS"
  if [ -r /root/.ssh/authorized_keys ]; then
    # Two hazards make a blind copy wrong:
    #  - Coolify writes its OWN key into root's authorized_keys when it
    #    registers a server. We cannot tell it from the operator's, so we cannot
    #    drop it; on control-plane/workload the operator should audit the seeded
    #    file (documented in the README).
    #  - Cloud images can carry command="…"/from="…" forced-command or source
    #    restrictions on a key. Copied verbatim those silently follow to the
    #    admin (a from="1.2.3.4" that no longer matches would lock the admin out
    #    just as surely). We SKIP any line whose first field is not a bare key
    #    type — i.e. one carrying leading options — and warn, rather than seed a
    #    key that behaves differently than it reads. Pass it via --admin-key if
    #    the restriction is intended.
    while IFS= read -r line; do
      case "$line" in
        ""|\#*) continue ;;
        ssh-*|ecdsa-*|sk-ssh-*|sk-ecdsa-*)
          printf '%s\n' "$line" >> "$ADMIN_KEYS" ;;
        *)
          warn "skipping a restricted key line (command=/from=/…) while seeding ${ADMIN_USER} from root; re-add it with --admin-key if intended" ;;
      esac
    done < /root/.ssh/authorized_keys
  fi
  # --admin-key composes with the seed: an explicit key the operator supplies,
  # added at creation alongside whatever was copied from root.
  if [ -n "$ADMIN_KEY" ]; then
    printf '%s\n' "$ADMIN_KEY" >> "$ADMIN_KEYS"
    log "added --admin-key to ${ADMIN_USER}"
  fi
  chown -R "$ADMIN_USER:$ADMIN_USER" "$ADMIN_HOME/.ssh"
  chmod 0600 "$ADMIN_KEYS"
  if [ ! -s "$ADMIN_KEYS" ]; then
    warn "${ADMIN_USER} has an EMPTY authorized_keys (root had none to seed and no --admin-key given) — it cannot log in yet; add a key before relying on it"
  fi
  log "admin user ${ADMIN_USER} created"
else
  # Convergent: an existing admin user is left completely alone — no re-seeding
  # (see the seed-once note above), no group changes, no sudoers rewrite.
  log "admin user ${ADMIN_USER} already exists; leaving it and its keys untouched"
fi

# --- lock root's SSH door (--lock-root, role-permitted only) ------------------
# Reached only when --lock-root was given AND the role passed the policy gate
# above (control-plane/workload already died at exit 2; only runner arrives
# here). "Lock root" is FOUR different actions that do NOT behave alike
# (measured on OpenSSH 10 / Debian 13):
#   passwd -l root           key-based root SSH still WORKS  (near no-op)
#   PermitRootLogin prohibit key SSH works                  (what rig does today)
#   usermod --expiredate 1   BREAKS root SSH via PAM
#   root shell -> nologin    BREAKS (and then chsh fails too)
#   PermitRootLogin no       BREAKS root SSH  <-- the ONLY one we want
# We want exactly `PermitRootLogin no`. The other break-paths (expiredate,
# nologin) would also break rig's OWN convergence: rig is run as root over SSH,
# so a re-run to pick up a fix would find the door bolted from a direction sshd
# cannot reopen. `PermitRootLogin no` leaves the account intact and reopenable
# by deleting one drop-in.
if [ "$LOCK_ROOT" -eq 1 ]; then
  log "verifying ${ADMIN_USER} is reachable before closing root's door"

  # NEVER close root's door in the same breath as opening the admin's without
  # these checks passing. What rig CANNOT verify is that the operator holds the
  # admin's private key — which is exactly why we seeded authorized_keys from
  # root's (the key they are connected with right now). Everything else, we can:
  fail() { die "refusing --lock-root: $1 (root's door stays OPEN)" 1; }

  # 1. Account exists.
  id -u "$ADMIN_USER" >/dev/null 2>&1 || fail "admin user ${ADMIN_USER} does not exist"

  # 2. Account not expired/disabled. A locked PASSWORD is fine (key auth is
  #    unaffected — that is the whole lesson of this issue), but an EXPIRED
  #    account (shadow field 8 in the past, i.e. `usermod --expiredate 1`) is
  #    refused by PAM and would block the admin's SSH too. Field 8 empty = never.
  expire_days="$(getent shadow "$ADMIN_USER" | cut -d: -f8)"
  if [ -n "$expire_days" ]; then
    today_days=$(( $(date -u +%s) / 86400 ))
    [ "$expire_days" -gt "$today_days" ] 2>/dev/null \
      || fail "admin account ${ADMIN_USER} is expired/disabled (shadow expire=${expire_days})"
  fi

  # 3. Valid, real login shell — not nologin/false (which PAM/login refuse).
  admin_shell="$(getent passwd "$ADMIN_USER" | cut -d: -f7)"
  case "$admin_shell" in
    */nologin|*/false|"") fail "admin ${ADMIN_USER} has no usable login shell (${admin_shell:-none})" ;;
  esac
  [ -x "$admin_shell" ] || fail "admin ${ADMIN_USER}'s shell ${admin_shell} is not executable"

  # 4. authorized_keys non-empty, sane ownership + perms. sshd silently ignores
  #    a keys file that is group/world-writable or not owned by the user, so a
  #    present-but-rejected file is as good as no key.
  akeys="$ADMIN_HOME/.ssh/authorized_keys"
  [ -s "$akeys" ] || fail "admin ${ADMIN_USER} has an empty/missing authorized_keys (${akeys})"
  owner="$(stat -c '%U' "$akeys" 2>/dev/null)"
  [ "$owner" = "$ADMIN_USER" ] || fail "authorized_keys is owned by ${owner:-?}, not ${ADMIN_USER}"
  perms="$(stat -c '%a' "$akeys" 2>/dev/null)"
  case "$perms" in
    600|640|644|400|440) ;;  # not group/world writable
    *) fail "authorized_keys perms ${perms} are too open (sshd would ignore it); want 0600" ;;
  esac

  # 5. sudo actually works for the admin, non-interactively, as the box will use
  #    it. runuser (not su) mirrors the runner-install precedent.
  runuser -u "$ADMIN_USER" -- sudo -n true >/dev/null 2>&1 \
    || fail "sudo -n true fails for ${ADMIN_USER} (no working passwordless sudo)"

  # 6. sshd's EFFECTIVE resolution for THIS user must permit a key login. An
  #    AllowUsers/AllowGroups/DenyUsers/DenyGroups or Match block elsewhere can
  #    silently exclude the admin even though the account is perfect. We assert
  #    against `sshd -T -C user=<admin>` — the daemon's own resolution — not the
  #    file we wrote, same discipline as the base hardening above. (A Match on
  #    address cannot be resolved without a real connection; that residual gap
  #    is what the second-terminal rehearsal covers.)
  actx="$(sshd -T -C user="$ADMIN_USER" 2>/dev/null)" \
    || fail "sshd -T -C user=${ADMIN_USER} failed to resolve"
  echo "$actx" | grep -qx 'pubkeyauthentication yes' \
    || fail "sshd does not offer publickey auth to ${ADMIN_USER}"
  admin_groups=" $(id -nG "$ADMIN_USER" 2>/dev/null) "
  au="$(echo "$actx" | sed -n 's/^allowusers //p')"
  if [ -n "$au" ]; then
    printf '%s' " $au " | grep -qF " $ADMIN_USER " \
      || fail "sshd AllowUsers excludes ${ADMIN_USER}"
  fi
  du="$(echo "$actx" | sed -n 's/^denyusers //p')"
  if [ -n "$du" ] && printf '%s' " $du " | grep -qF " $ADMIN_USER "; then
    fail "sshd DenyUsers lists ${ADMIN_USER}"
  fi
  ag="$(echo "$actx" | sed -n 's/^allowgroups //p')"
  if [ -n "$ag" ]; then
    permitted=0
    for g in $ag; do
      case "$admin_groups" in *" $g "*) permitted=1; break ;; esac
    done
    [ "$permitted" -eq 1 ] || fail "sshd AllowGroups admits none of ${ADMIN_USER}'s groups"
  fi
  dg="$(echo "$actx" | sed -n 's/^denygroups //p')"
  if [ -n "$dg" ]; then
    for g in $dg; do
      case "$admin_groups" in *" $g "*) fail "sshd DenyGroups lists ${ADMIN_USER}'s group ${g}" ;; esac
    done
  fi
  log "admin ${ADMIN_USER} verified reachable (account, shell, keys, sudo, sshd resolution)"

  # Only NOW do we touch root's door — with the exact validate-before-restart +
  # sshd -t + rollback + sshd -T effective-assert dance the base drop-in uses.
  # The file sorts BEFORE 00-rig.conf, on purpose: sshd_config is FIRST-wins, so
  # `PermitRootLogin no` in a 10-* file would be read AFTER 00-rig.conf's
  # `prohibit-password` and silently discarded — the same first-wins trap that
  # cost this repo a month of boxes serving passwordauthentication=yes. 00-rig-
  # root.conf sorts first ('-' < '.'), so it wins over both 00-rig.conf and
  # cloud-init. (Reopening root is a deliberate manual act: rm this file and
  # restart ssh — rig does not silently reopen it on a re-run without --lock-root.)
  ROOT_DROPIN=/etc/ssh/sshd_config.d/00-rig-root.conf
  RTMP="$(mktemp)"
  printf 'PermitRootLogin no\n' > "$RTMP"
  if ! cmp -s "$RTMP" "$ROOT_DROPIN" 2>/dev/null; then
    RBACK=""
    [ -e "$ROOT_DROPIN" ] && { RBACK="$(mktemp)"; cp -a "$ROOT_DROPIN" "$RBACK"; }
    install -m 0644 "$RTMP" "$ROOT_DROPIN"
    if ! sshd -t 2>/dev/null; then
      if [ -n "$RBACK" ]; then cp -a "$RBACK" "$ROOT_DROPIN"; else rm -f "$ROOT_DROPIN"; fi
      rm -f "$RTMP" "$RBACK"
      die "sshd rejects the merged config with PermitRootLogin no; rolled back, daemon untouched, root's door still OPEN. Run 'sshd -t'."
    fi
    rm -f "$RBACK"
    systemctl restart ssh
    log "root SSH door closed (PermitRootLogin no drop-in installed)"
  else
    log "root SSH door already closed (00-rig-root.conf in place)"
  fi
  rm -f "$RTMP"

  # Assert the EFFECTIVE policy, never the file — assert-the-file is what let the
  # first-wins bug ship green once already.
  reff="$(sshd -T 2>/dev/null)" || die "sshd -T failed after locking root; investigate before trusting this box" 1
  echo "$reff" | grep -qx 'permitrootlogin no' \
    || die "root door did NOT take effect (sshd -T still permits root login) — a drop-in is beating ${ROOT_DROPIN}; check ls /etc/ssh/sshd_config.d/" 1
  log "root door verified closed (sshd -T: permitrootlogin no) — from now on re-run rig THROUGH the ${ADMIN_USER} account"
fi

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

log "done — role ${ROLE}, hostname ${TS_HOSTNAME}"
if [ "$ROLE" = "control-plane" ]; then
  log "next: rig coolify install --version <pin>"
elif [ "$ROLE" = "runner" ]; then
  log "next: rig runner install --repo <owner/repo> --version <pin>"
fi
