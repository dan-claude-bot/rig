#!/usr/bin/env bash
# Shared sshd hardening — sourced by bootstrap.sh (machine roles) and by
# bootstrap-tenant.sh (the staging tenant). Root-requiring, unlike the pure
# parsing libs: it converges /etc/ssh and bounces the daemon. Extracted so the
# two roles converging ONE drop-in stay literally the same code — two copies of
# a hardening block is drift by construction, the same law that keeps rig's
# hands off Incus. Callers provide log/warn/die.

# sshd_privsep_gap <status> <stderr> — true when a FAILED `sshd -t` failed for
# the missing privilege-separation directory rather than for anything in the
# config. Pure and sourceable (repo precedent: parse_users_file, deny_verdict)
# so the distinction is provable without root or a live sshd.
#
# `sshd -t` folds two questions into one exit code: is the merged config
# parseable, and is /run/sshd there. The second is not a fact about the config
# at all — /run is a tmpfs and /run/sshd is ssh.service's RuntimeDirectory,
# which systemd creates with that unit and removes when it stops, so the
# directory is legitimately absent under socket activation (ssh.socket, the
# default on current Debian/Ubuntu) on a box whose SSH door is serving
# connections perfectly well. Reading that as a config refusal aborted
# bootstrap with a verdict sshd never reached (#92).
#
# The STATUS is the verdict; this text match only classifies a failure. A
# passing `sshd -t` is never diverted here, whatever its output happens to say.
sshd_privsep_gap() {
  [ "$1" -ne 0 ] || return 1
  case "$2" in
    *"Missing privilege separation directory"*) return 0 ;;
    *) return 1 ;;
  esac
}

# sshd_config_ok — validate the merged config, repairing a privsep gap once and
# retesting. Returns sshd's verdict and leaves sshd's own stderr in $sshd_err
# for the caller's refusal message: a message that asserts a cause must carry
# the evidence for it, or the operator greps /etc/ssh blind (#92).
#
# The repair is `install -d`, which is idempotent and creates exactly what
# systemd would. It does not survive a reboot and is not meant to — by then the
# ssh unit has recreated it.
sshd_config_ok() {
  local rc
  sshd_err="$(sshd -t 2>&1)"; rc=$?
  if sshd_privsep_gap "$rc" "$sshd_err"; then
    install -d -m 0755 /run/sshd
    sshd_err="$(sshd -t 2>&1)"; rc=$?
  fi
  return "$rc"
}

# harden_sshd <closed|open> — install the 00-rig.conf hardening drop-in,
# validate the merged config before touching the daemon, restart only when the
# drop-in actually changed, and assert the EFFECTIVE config (sshd -T), with the
# permitrootlogin acceptance gated on the ROOT-DOOR policy passed in (#77; this
# argument was <human|server> before the trait was renamed for what it decides).
# Callers pass their own trait value, never a marker read: bootstrap knows its
# root-door from its flags, and the staging tenant is open by construction.
harden_sshd() {
  local root_door="$1"
  local dropin=/etc/ssh/sshd_config.d/00-rig.conf
  local legacy_dropin=/etc/ssh/sshd_config.d/99-rig.conf
  local tmp backup eff
  # The name must sort BEFORE cloud-init's drop-in. sshd_config is FIRST-wins
  # ("for each keyword, the first obtained value will be used" — sshd_config(5)),
  # and Include expands the glob in lexical order. Cloud images ship
  # /etc/ssh/sshd_config.d/50-cloud-init.conf carrying `PasswordAuthentication
  # yes`, so the old 99-rig.conf was read second and silently lost every keyword
  # it set. 00- wins. (Found 2026-07-12: every Hetzner box rig had bootstrapped
  # was still serving `passwordauthentication yes`. The Incus rehearsal never
  # caught it — a pristine Debian container has no cloud-init drop-in.)
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
EOF
  if ! cmp -s "$tmp" "$dropin" 2>/dev/null || [ -e "$legacy_dropin" ]; then
    backup=""
    [ -e "$dropin" ] && { backup="$(mktemp)"; cp -a "$dropin" "$backup"; }
    install -m 0644 "$tmp" "$dropin"
    rm -f "$legacy_dropin"   # sweep the losing file from already-bootstrapped boxes

    # Validate the MERGED config BEFORE bouncing the daemon. On a box whose only
    # door is SSH, `systemctl restart ssh` against a config sshd refuses to parse
    # leaves no listener and no way back in. `sshd -t` parses everything sshd
    # would parse — our drop-in, cloud-init's, and any third-party file — so a
    # broken neighbour is caught here rather than after the door has shut.
    if ! sshd_config_ok; then
      if [ -n "$backup" ]; then cp -a "$backup" "$dropin"; else rm -f "$dropin"; fi
      rm -f "$tmp" "$backup"
      die "sshd rejects the merged config; drop-in rolled back, daemon untouched: $sshd_err"
    fi
    rm -f "$backup"

    systemctl restart ssh
    log "sshd hardening drop-in installed"
  else
    log "sshd hardening drop-in already in place"
  fi
  rm -f "$tmp"

  # Assert the EFFECTIVE config, not the file's existence — asserting the file is
  # what let the first-wins bug ship green. `sshd -T` is what the daemon actually
  # resolved, cloud-init and all.
  eff="$(sshd -T 2>/dev/null)" || die "sshd -T failed; refusing to claim a hardened box"
  echo "$eff" | grep -qx 'passwordauthentication no' \
    || die "sshd still resolves passwordauthentication=yes — a drop-in is beating ${dropin}; check ls /etc/ssh/sshd_config.d/"
  # The permitrootlogin acceptance is ROOT-DOOR-gated, because `no` means
  # opposite things on the two policies. root-door=closed: `no` is the post-`rig
  # users close-root` state — strictly harder than the prohibit-password this
  # function installs. Hardening must never read a closed door as a broken one,
  # and it cannot reopen one either: by first-wins its own drop-in loses to
  # 00-rig-users.conf. root-door=open: root SSH is the control plane's automation
  # door (Coolify SSHes in as root), so `no` is not hardening — it is fleet
  # management silently dead, and the likely culprit is a drop-in left over from
  # a former root-door=closed life on a repurposed box. rig can DETECT that but
  # must not FIX it: silently reopening a root door is worse than a loud stop, so
  # — same doctrine as the tag checks — detect, refuse, and name the repair.
  if [ "$root_door" = "closed" ]; then
    echo "$eff" | grep -qxE 'permitrootlogin (no|prohibit-password|without-password)' \
      || die "sshd still permits root password login — check ls /etc/ssh/sshd_config.d/"
  elif echo "$eff" | grep -qx 'permitrootlogin no'; then
    die "sshd resolves permitrootlogin=no, but this is a root-door=open box: root SSH is the control plane's automation door, and with it shut the fleet cannot manage this box. Likely cause: a leftover /etc/ssh/sshd_config.d/00-rig-users.conf from a former root-door=closed life ('rig users close-root' ran here once). Remove that drop-in and re-run bootstrap."
  else
    echo "$eff" | grep -qxE 'permitrootlogin (prohibit-password|without-password)' \
      || die "sshd still permits root password login — check ls /etc/ssh/sshd_config.d/"
  fi
  log "sshd hardening verified (sshd -T: passwordauthentication no)"
}
