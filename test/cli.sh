#!/usr/bin/env bash
# Dependency-free CLI assertions. Run: bash test/cli.sh
# Deliberately no `set -e` — the harness asserts on failing commands.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0 FAIL=0

# check <desc> <want_exit> <want_substr> <cmd...>
# Runs cmd, asserts exit code and (if non-empty) that combined output
# contains want_substr.
check() {
  local desc="$1" want="$2" substr="$3"; shift 3
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "FAIL: $desc — exit $rc, wanted $want"
    printf '%s\n' "$out" | sed 's/^/    /'
    FAIL=$((FAIL + 1)); return
  fi
  if [ -n "$substr" ] && ! printf '%s' "$out" | grep -qF -e "$substr"; then
    echo "FAIL: $desc — output missing '$substr'"
    printf '%s\n' "$out" | sed 's/^/    /'
    FAIL=$((FAIL + 1)); return
  fi
  echo "ok: $desc"; PASS=$((PASS + 1))
}

check "no args shows usage, exit 2"      2 "usage:" "$ROOT/bin/rig"
check "--help exits 0"                   0 "usage:" "$ROOT/bin/rig" --help
check "help exits 0"                     0 "usage:" "$ROOT/bin/rig" help
check "unknown command exits 2"          2 "unknown command" "$ROOT/bin/rig" frobnicate
check "bare coolify shows usage, exit 2" 2 "usage:" "$ROOT/bin/rig" coolify

check "bootstrap: role required, exit 2"   2 "role required"  "$ROOT/commands/bootstrap.sh"
check "bootstrap: --help exits 0"          0 "usage:"         "$ROOT/commands/bootstrap.sh" --help
check "bootstrap: unknown role exits 2"    2 "unknown role"   "$ROOT/commands/bootstrap.sh" potato
check "bootstrap: unknown flag exits 2"    2 "unknown flag"   "$ROOT/commands/bootstrap.sh" workload-server --nope
check "bootstrap: hostname needs value"    2 "needs a value"  "$ROOT/commands/bootstrap.sh" workload-server --hostname
# --ts-tag is REMOVED, not demoted: the tag now comes from the pre-auth key and
# rig verifies the GRANTED tag after join. The old runner-refuses-tag:server test
# asserted the request-time refusal THROUGH this flag; that policy now lives on
# the EFFECTIVE tag and needs a real tailnet, so it belongs to the rehearsal, not
# here. What this harness CAN prove is that the flag dies with a message pointing
# at the key (exit 2, a usage error), rather than an "unknown flag" that would
# leave an operator guessing where the tag went — value present or absent.
check "bootstrap: --ts-tag is removed (with value), exit 2" 2 "comes from the pre-auth key" \
  "$ROOT/commands/bootstrap.sh" runner-server --ts-tag tag:server
check "bootstrap: --ts-tag is removed (no value), exit 2"   2 "comes from the pre-auth key" \
  "$ROOT/commands/bootstrap.sh" runner-server --ts-tag
# staging-box is a box TENANT role (the guest, not the VM host), and it
# never joins the tailnet — but --ts-tag on it must still die with a story,
# not an "unknown flag": scripts from its trait-preset life may pass it, and
# the message must say where both the tag AND the join went.
check "bootstrap: staging-box + removed --ts-tag exits 2" 2 "never join the tailnet" \
  "$ROOT/commands/bootstrap.sh" staging-box --ts-tag tag:server
# The VM-HOST shape has a named role again (staging-server, #76), but it is
# still not one of the two the control plane manages, so the catch-all
# tag:server refusal must own it. Grep-pinned so a deleted guard cannot ship
# green (repo precedent: the login-path refusal below).
check "bootstrap: the catch-all tag:server refusal is present" 0 "" \
  grep -q "Only control-plane-server and workload-server are managed by the control plane" "$ROOT/commands/bootstrap.sh"
# ...and staging-server must NOT have slipped into the allow-list arm beside
# control-plane-server|workload-server. A new preset silently landing there
# would extend every server grant to a VM host, which is the exact shape the
# refusal exists to prevent — and nothing else in the suite would notice.
check "bootstrap: staging-server is not in the tag:server allow-list" 1 "" \
  grep -qE '^ *control-plane-server\|workload-server\)[^#]*staging-server' "$ROOT/commands/bootstrap.sh"

# --- the role taxonomy (#76): -server names the family, and it was a hard cut -
# Every machine role carries the suffix; custom and workstation deliberately do
# not. Proven by reaching the ROOT CHECK, which is the last thing before the
# converge and therefore proof the name resolved to a preset.
if [ "$(id -u)" -ne 0 ]; then
  for r in control-plane-server workload-server runner-server staging-server dev-server; do
    check "bootstrap: role $r resolves" 1 "must run as root" \
      env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" "$r" --no-users
  done
fi
# THE HARD CUT. No aliases: the pre-#76 names are gone, and must fail as
# UNKNOWN rather than quietly resolving to anything. Asserted per name because
# an alias accidentally left in for one role is exactly the shape that survives
# review — the taxonomy reads as complete while one old name still works.
# 'staging' is deliberately absent HERE: it is a TENANT name, and its own hard
# cut is asserted in the tenant section below, at both entrypoints.
for r in control-plane workload runner dev; do
  check "bootstrap: the pre-#76 name '$r' is gone (hard cut)" 2 "unknown role" \
    "$ROOT/commands/bootstrap.sh" "$r"
done
# ...but the two roles that legitimately carry no suffix must NOT have been
# swept up in the rename. This is the inverse error and it fails silently: a
# workstation that stopped resolving would only surface at someone's laptop.
check "bootstrap: workstation keeps its bare name" 2 "unset TS_AUTHKEY" \
  env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" workstation
check "bootstrap: custom keeps its bare name" 2 "--hostname" \
  "$ROOT/commands/bootstrap.sh" custom --root-door open --host no --join authkey
# NOTHING may still TELL an operator to run a pre-#76 role. The rename is a
# hard cut, so a next-step string, a usage line or a refusal that still recites
# a bare role name is a command that fails when someone copy-pastes it — and it
# fails later and further from the cause than a broken flag would, because it
# fails on a different box, minutes after this run reported success. The tenant
# script is the one that emits the staging guest's workload-join next step, so
# it is where this bites first (caught in review on #80, fixed here where the
# rename actually happens). Swept across every shipped script rather than
# asserted at the one known site: the next instance of this will be somewhere
# else, and a site-specific check would not see it.
check "roles: no shipped script tells an operator to run a pre-#76 role name" 1 "" \
  grep -rnE "rig bootstrap (control-plane|workload|runner|dev)( |'|\"|$)" \
    "$ROOT/bin/rig" "$ROOT/commands/"
# --- traits: roles are presets, every trait individually settable (#26) -----
check "bootstrap: unknown role still exits 2"    2 "unknown role" "$ROOT/commands/bootstrap.sh" potato
check "bootstrap: bad --root-door value exits 2" 2 "closed|open" "$ROOT/commands/bootstrap.sh" workload-server --root-door potato
check "bootstrap: bad --host value exits 2"      2 "yes|no"       "$ROOT/commands/bootstrap.sh" workload-server --host maybe
check "bootstrap: bad --join value exits 2"      2 "authkey|login" "$ROOT/commands/bootstrap.sh" workload-server --join carrier-pigeon
check "bootstrap: custom without --hostname exits 2" 2 "--hostname" \
  "$ROOT/commands/bootstrap.sh" custom --root-door open --host no --join authkey
check "bootstrap: custom without traits exits 2" 2 "--root-door" "$ROOT/commands/bootstrap.sh" custom --hostname box1
# workstation is join=login by preset: a set TS_AUTHKEY is a usage error, and it
# must die BEFORE the root check — provable non-root, which also proves the
# preset actually landed.
check "bootstrap: workstation + TS_AUTHKEY exits 2" 2 "unset TS_AUTHKEY" \
  env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" workstation
# A trait override changes derived behavior, provable non-root: dev is
# join=authkey (TS_AUTHKEY fine → falls through to the root check), but
# --join login flips it into the TS_AUTHKEY refusal.
check "bootstrap: dev --join login + TS_AUTHKEY exits 2" 2 "unset TS_AUTHKEY" \
  env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" dev-server --join login
# The login-path inverted assertion needs a real tailnet; grep the refusal so a
# deleted guard cannot ship green (repo precedent: staging/runner tag greps).
check "bootstrap: login-path tagged refusal is present" 0 "" \
  grep -q "join=login expects a user-owned, untagged node" "$ROOT/commands/bootstrap.sh"
# Re-running with join=authkey on a box that was legitimately login-joined
# (untagged BY DESIGN) lands in verify_effective_tag's untagged branch. Backing
# out a join this run did not perform would tear down a user-owned workstation;
# the already-joined path must refuse WITHOUT logout and name both repairs.
# Needs a real tailnet to exercise, so grep the keep-mode die instead.
check "bootstrap: already-joined untagged refusal keeps the join" 0 "" \
  grep -q "joined but UNTAGGED" "$ROOT/commands/bootstrap.sh"
# verify_user_owned must fail CLOSED on a stalled backend: empty tags is its
# SUCCESS signal, so a 30s poll that never saw Running would wave a tagged node
# through as user-owned. Grep the timeout die (same real-tailnet excuse).
check "bootstrap: login verify fails closed on a stalled backend" 0 "" \
  grep -q "could not verify the join is user-owned" "$ROOT/commands/bootstrap.sh"
# The marker is the traits' ground truth for rig users; assert the write exists.
check "bootstrap: role marker write is present" 0 "" \
  grep -q "/etc/rig/role" "$ROOT/commands/bootstrap.sh"
# ...and that it is written in the CURRENT vocabulary (#77). New markers say
# root-door=; the retired class= spelling is something rig READS forever and
# WRITES never, so a marker line that reintroduces it must not ship green.
check "bootstrap: the marker is written as root-door=, not class=" 0 "" \
  grep -qF "printf 'role=%s root-door=%s host=%s join=%s" "$ROOT/commands/bootstrap.sh"
# shellcheck disable=SC2016
check "bootstrap: no shipped script WRITES the retired class= spelling" 0 "" \
  sh -c '! grep -n "printf .*class=" "$1"/commands/*.sh' _ "$ROOT"
# --- host=yes box install (issues #12, #25) --------------------------------
# A host=yes box finishes the job: bootstrap installs the box CLI globally and
# lets box's own setup-host build the Incus stack. The install itself runs as
# root, over the network, against a real host — none of which this harness can
# fabricate — so, exactly like the tag refusals and the runner repo guard, prove
# the shipped script by grepping its load-bearing pieces.
# The step is guarded on host=yes: the exact guard line (no `&&`, unlike the
# /dev/kvm advisory) belongs to the box block alone. The `\$HOST` is a literal
# we grep for in the script — single quotes are the point, as in the db checks.
# shellcheck disable=SC2016
check "bootstrap: box install is guarded on host=yes" 0 "" \
  grep -qxE 'if \[ "\$HOST" = "yes" \]; then' "$ROOT/commands/bootstrap.sh"
# It runs box's OWN global installer with BOX_YES=1 (non-interactive AND keeps
# setup-host, so box builds Incus rather than only dropping the CLI on PATH).
check "bootstrap: box install runs box's installer non-interactively" 0 "" \
  grep -q "BOX_YES=1 bash" "$ROOT/commands/bootstrap.sh"
# Pin points: BOX_REPO / BOX_REF override the source, default heavy-duty/box@main.
check "bootstrap: box source is pinnable, defaults to heavy-duty/box@main" 0 "" \
  grep -qF 'BOX_REPO:-heavy-duty/box' "$ROOT/commands/bootstrap.sh"
# Opt-out for rehearsals / offline / hand-managed hosts.
check "bootstrap: box install honors RIG_SKIP_BOX_INSTALL opt-out" 0 "" \
  grep -q "RIG_SKIP_BOX_INSTALL" "$ROOT/commands/bootstrap.sh"
# The DESIGN LAW rig users apply also enforces: rig NEVER apt-installs Incus —
# box's setup-host is the single owner of the daemon and its group. A grep that
# finds nothing (exit 1) is the pass; a stray `apt-get install ... incus` would
# make it exit 0 and fail the check, so the law cannot silently erode.
check "bootstrap: rig never apt-installs incus (box owns the daemon)" 1 "" \
  grep -nE 'apt-get install.* incus' "$ROOT/commands/bootstrap.sh"
# Ordering is the safety property: box must be installed only AFTER the role
# marker is written, so a box that failed to become what it claims (tag refused,
# join backed out — all of which die above) never installs box on a half-built
# host. Compare line numbers, same idiom as the visudo/sshd -t ordering asserts.
# Defaults fail closed (marker missing -> huge, box missing -> 0 -> fails).
# $MARKER_TMP is a literal we grep for in the script — single quotes intended.
# shellcheck disable=SC2016
box_marker_at="$(grep -n 'install -m 0644 "$MARKER_TMP"' "$ROOT/commands/bootstrap.sh" | head -n1 | cut -d: -f1)"
box_install_at="$(grep -n 'BOX_YES=1 bash' "$ROOT/commands/bootstrap.sh" | grep -v 'BOX_MANUAL=' | tail -n1 | cut -d: -f1)"
check "bootstrap: box install runs after the role marker write" \
  0 "" test "${box_marker_at:-999999}" -lt "${box_install_at:-0}"
# On the skip/failure paths, keep pointing operators at the manual command so a
# host whose box did not install is never left without the next move.
check "bootstrap: box skip/failure keeps a pointer to the manual install" 0 "" \
  grep -q "prepare Incus" "$ROOT/commands/bootstrap.sh"
# "Don't trust exit codes" (#12): box's installer can exit 0 having done less
# than it claims (its setup-host has a path that exits 0 after only adding a
# group, asking for a re-login). After a claimed success bootstrap must prove
# the one artifact it asked for — box on PATH — and a hollow success WARNS,
# never dies: box is the host extra. Exercising it needs root + the network,
# so grep the shipped script (repo precedent: the tag-refusal greps). Match
# the CALL, not the word — the rationale comment says `command -v box` too.
check "bootstrap: a box-install success is verified, not trusted" 0 "" \
  grep -qE '^[[:space:]]*if command -v box' "$ROOT/commands/bootstrap.sh"
check "bootstrap: a hollow box-install success warns, never dies" 0 "" \
  grep -q "reported success but no 'box' is on PATH" "$ROOT/commands/bootstrap.sh"
# Ordering: the effective check must sit AFTER the installer run it verifies.
# Line-number compare, defaults fail closed (same idiom as the marker/install
# ordering assert above; box_install_at is computed there).
box_check_at="$(grep -nE '^[[:space:]]*if command -v box' "$ROOT/commands/bootstrap.sh" | head -n1 | cut -d: -f1)"
check "bootstrap: the effective check follows the installer run" \
  0 "" test "${box_install_at:-999999}" -lt "${box_check_at:-0}"
# rig's delegation law caps the check's depth: rig never interrogates Incus —
# the host verdict is box's own verb, and the "host set up" CLAIM is gated on
# it. Two asserts: the gate exists as a call (not just prose naming the verb),
# and the claim line sits inside/after it (line order, fail-closed defaults —
# a claim that outruns its proof is exactly the overclaim this closes).
check "bootstrap: the host-set-up claim is gated on box doctor" 0 "" \
  grep -qE '^[[:space:]]*if box doctor' "$ROOT/commands/bootstrap.sh"
doctor_at="$(grep -nE '^[[:space:]]*if box doctor' "$ROOT/commands/bootstrap.sh" | head -n1 | cut -d: -f1)"
claim_at="$(grep -n 'box installed and host set up' "$ROOT/commands/bootstrap.sh" | head -n1 | cut -d: -f1)"
check "bootstrap: the claim follows the doctor gate" \
  0 "" test "${doctor_at:-999999}" -lt "${claim_at:-0}"
check "bootstrap: a failed doctor warns without claiming the host" 0 "" \
  grep -q "the CLI landed, the host stack is unproven" "$ROOT/commands/bootstrap.sh"
# --- the users phase (#51): --users is required, --no-users is the opt-out ----
# Bootstrap takes the users file and applies it as its LAST phase, so one
# command leaves a box with its people on it. Everything about the FLAG is
# provable here — the whole surface sits before the root check, deliberately,
# because a users file with a typo must not be discovered after apt, a hostname
# change and a spent pre-auth key.
BOOT_USERS="$(mktemp -d)"
cat > "$BOOT_USERS/ok" <<'USERS'
dan      admin      ssh-ed25519 AAAAC3fixture dan@laptop
maria    rig        ssh-ed25519 AAAAC3fixture maria@mac
USERS
printf '%s\n' 'dan admin,box ssh-ed25519 AAAAC3fixture dan@laptop' > "$BOOT_USERS/box"
printf '%s\n' 'maria ops ssh-ed25519 AAAA maria@mac'               > "$BOOT_USERS/bad"
# The REQUIREMENT, and the message that carries it: omitting both flags must
# name BOTH ways out, because an operator who forgot the file and one who meant
# to skip it type the identical command — the error is the only place rig can
# tell them apart.
check "bootstrap: omitting --users and --no-users exits 2" 2 "one of --users <path> or --no-users is required" \
  "$ROOT/commands/bootstrap.sh" workload-server
check "bootstrap: the requirement names --no-users as the way out" 2 "--no-users to leave it root-only" \
  "$ROOT/commands/bootstrap.sh" dev-server --hostname b
check "bootstrap: the requirement holds on root-door=open too" 2 "one of --users" \
  "$ROOT/commands/bootstrap.sh" control-plane-server --hostname cp
check "bootstrap: --users needs a value" 2 "needs a value" \
  "$ROOT/commands/bootstrap.sh" workload-server --users
# MUTUAL EXCLUSION, both orders: rig refuses to pick a winner rather than let a
# precedence rule decide who may enter the box. Both orders, because a
# "last flag wins" implementation would pass one of them silently.
check "bootstrap: --users with --no-users exits 2" 2 "contradictory" \
  "$ROOT/commands/bootstrap.sh" workload-server --users "$BOOT_USERS/ok" --no-users
check "bootstrap: --no-users with --users exits 2 (either order)" 2 "contradictory" \
  "$ROOT/commands/bootstrap.sh" workload-server --no-users --users "$BOOT_USERS/ok"
# Pre-flight: an unreadable or invalid file dies at the top of the run, exit 2,
# before the root check — the same contract every other flag here has.
check "bootstrap: an unreadable users file exits 2" 2 "cannot read users file" \
  "$ROOT/commands/bootstrap.sh" workload-server --users "$BOOT_USERS/nope"
check "bootstrap: an invalid users file exits 2 with the parser's errors" 2 "invalid users file" \
  "$ROOT/commands/bootstrap.sh" workload-server --users "$BOOT_USERS/bad"
check "bootstrap: the invalid-file refusal carries the parser's own line error" 2 "valid roles: admin rig box" \
  "$ROOT/commands/bootstrap.sh" workload-server --users "$BOOT_USERS/bad"
# '-' is apply's stdin convenience and cannot survive the trip through
# bootstrap: stdin here is the pre-auth key prompt's. Refused, with the split
# ('--no-users' then apply by hand) named.
check "bootstrap: --users - is refused, naming the pre-auth key prompt" 2 "pre-auth key prompt" \
  "$ROOT/commands/bootstrap.sh" workload-server --users -
# A file that parses to ZERO users (#57). Not a parse error — the parser is
# right to accept empty, comments-only and whitespace-only files — but it walks
# straight through #51's requirement: `--users ./empty` and `--no-users`
# converge the identical root-only box, and only one of them says so. All three
# shapes are tested separately because they take different paths through the
# parser's skip rules, and an implementation that checked, say, file size alone
# would pass one and fail the others.
: > "$BOOT_USERS/empty"
cat > "$BOOT_USERS/comments" <<'USERS'
# the operators for this box
#dan     admin      ssh-ed25519 AAAAC3fixture dan@laptop
USERS
printf '   \n\t\n\n' > "$BOOT_USERS/blank"
check "bootstrap: an empty users file exits 2" 2 "names no users" \
  "$ROOT/commands/bootstrap.sh" workload-server --users "$BOOT_USERS/empty"
check "bootstrap: a comments-only users file exits 2" 2 "names no users" \
  "$ROOT/commands/bootstrap.sh" workload-server --users "$BOOT_USERS/comments"
check "bootstrap: a whitespace-only users file exits 2" 2 "names no users" \
  "$ROOT/commands/bootstrap.sh" workload-server --users "$BOOT_USERS/blank"
# The refusal must name --no-users, for the same reason the missing-flag one
# does: the root-only box IS reachable, it just has to be said out loud. An
# error that only reported "no users" would leave the operator who genuinely
# wants root-only with no named way to ask for it.
check "bootstrap: the zero-user refusal names --no-users as the way to say it" 2 "pass --no-users to leave this box root-only" \
  "$ROOT/commands/bootstrap.sh" workload-server --users "$BOOT_USERS/empty"
# It must NOT over-refuse: a file that names even one operator passes pre-flight
# untouched. Reaching the root check (exit 1) is the proof — same idiom as the
# incus precondition's negative cases below.
if [ "$(id -u)" -ne 0 ]; then
  check "bootstrap: a users file naming operators still passes pre-flight" 1 "must run as root" \
    env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" workload-server --users "$BOOT_USERS/ok"
fi
# Scope guard (#57): the refusal is BOOTSTRAP's contract, not the parser's and
# not apply's. A standalone `rig users apply` against an emptied file is a real
# de-provisioning operation and must stay possible — greps that find nothing
# (exit 1) are the pass, the repo's negative-law idiom.
check "users apply: an empty file is still a legal de-provisioning input" 1 "" \
  grep -nE 'names no users' "$ROOT/commands/users-apply.sh"
check "users-config: zero users stays bootstrap policy, not a parser error" 1 "" \
  grep -nE 'names no users' "$ROOT/commands/lib/users-config.sh"
# The host=yes box-role precondition, surfaced EARLY — but only where the
# outcome is already proven: RIG_SKIP_BOX_INSTALL=1 means this run will not
# install box, so a missing incus group can no longer be rescued by the install
# further down. The group's presence is a property of whatever machine runs
# this harness, so it is driven with a shim `getent` instead — both directions,
# on any machine (repo precedent: the install.sh getent shim below).
#
# The box CLI's presence is the SECOND half of the precondition (#49 merged a
# matching die into apply), and it is a property of the runner in exactly the
# same way — this machine happens to have box on PATH, a CI runner may not. So
# it is shimmed in both directions too, and `box` is deliberately NOT inherited
# from the real PATH in these runs: a test that passes only where box happens
# to be installed proves nothing about the machine where it isn't.
INCUS_SHIM_NO="$BOOT_USERS/shim-no"; INCUS_SHIM_YES="$BOOT_USERS/shim-yes"
BOXLESS_SHIM="$BOOT_USERS/shim-nobox"
mkdir -p "$INCUS_SHIM_NO" "$INCUS_SHIM_YES" "$BOXLESS_SHIM"
# Answer only the `group incus` question; everything else falls through to the
# real getent, so the shim cannot quietly change some other lookup's answer.
cat > "$INCUS_SHIM_NO/getent" <<'SHIM'
#!/bin/sh
if [ "$1" = group ] && [ "$2" = incus ]; then exit 2; fi
exec /usr/bin/getent "$@"
SHIM
cat > "$INCUS_SHIM_YES/getent" <<'SHIM'
#!/bin/sh
if [ "$1" = group ] && [ "$2" = incus ]; then echo "incus:x:900:"; exit 0; fi
exec /usr/bin/getent "$@"
SHIM
# Group present, box absent — the shape #49's die now owns, and the one the
# old group-only precondition let through to fail a hundred lines later.
cat > "$BOXLESS_SHIM/getent" <<'SHIM'
#!/bin/sh
if [ "$1" = group ] && [ "$2" = incus ]; then echo "incus:x:900:"; exit 0; fi
exec /usr/bin/getent "$@"
SHIM
# A `box` that exists, for the satisfied case — so INCUS_SHIM_YES proves the
# precondition passes on its own terms rather than on the runner's luck.
printf '#!/bin/sh\nexit 0\n' > "$INCUS_SHIM_YES/box"
chmod +x "$INCUS_SHIM_NO/getent" "$INCUS_SHIM_YES/getent" \
         "$BOXLESS_SHIM/getent" "$INCUS_SHIM_YES/box"
check "bootstrap: host=yes + box role + no incus + skipped box install exits 2" 2 "group incus is absent" \
  env RIG_SKIP_BOX_INSTALL=1 PATH="$INCUS_SHIM_NO:$PATH" \
      "$ROOT/commands/bootstrap.sh" dev-server --hostname h --users "$BOOT_USERS/box"
check "bootstrap: that refusal points at box setup-host, not at rig" 2 "rig never installs Incus" \
  env RIG_SKIP_BOX_INSTALL=1 PATH="$INCUS_SHIM_NO:$PATH" \
      "$ROOT/commands/bootstrap.sh" dev-server --hostname h --users "$BOOT_USERS/box"
# The group can be there while the CLI is not — #49's die owns that shape, and
# under the skip it is just as final and just as knowable now. PATH is built
# WITHOUT the real one so the absence is the test's, not the machine's.
check "bootstrap: host=yes + box role + incus group + no box CLI + skip exits 2" 2 "box CLI is not on PATH" \
  env RIG_SKIP_BOX_INSTALL=1 PATH="$BOXLESS_SHIM:/usr/bin:/bin" \
      "$ROOT/commands/bootstrap.sh" dev-server --hostname h --users "$BOOT_USERS/box"
check "bootstrap: that refusal names the tier, not just the socket" 2 "the restricted tier is 'box grant'" \
  env RIG_SKIP_BOX_INSTALL=1 PATH="$BOXLESS_SHIM:/usr/bin:/bin" \
      "$ROOT/commands/bootstrap.sh" dev-server --hostname h --users "$BOOT_USERS/box"
if [ "$(id -u)" -ne 0 ]; then
  # It must NOT fire in the three shapes that are not doomed. A users file with
  # no box-role user converges fine on a host that never saw Incus (refusing it
  # would be rig inventing a prerequisite apply does not have); an incus group
  # that exists satisfies it outright; and WITHOUT RIG_SKIP_BOX_INSTALL the
  # missing group is the box install's to create further down — refusing there
  # would reject the exact one-command bring-up this flag is for. Reaching the
  # root check (exit 1) is the proof each passed the precondition.
  check "bootstrap: no box-role user means no incus precondition" 1 "must run as root" \
    env TS_AUTHKEY=x RIG_SKIP_BOX_INSTALL=1 PATH="$INCUS_SHIM_NO:$PATH" \
        "$ROOT/commands/bootstrap.sh" dev-server --hostname h --users "$BOOT_USERS/ok"
  check "bootstrap: an existing incus group satisfies the precondition" 1 "must run as root" \
    env TS_AUTHKEY=x RIG_SKIP_BOX_INSTALL=1 PATH="$INCUS_SHIM_YES:$PATH" \
        "$ROOT/commands/bootstrap.sh" dev-server --hostname h --users "$BOOT_USERS/box"
  check "bootstrap: without the skip, the box install is left to create the group" 1 "must run as root" \
    env TS_AUTHKEY=x PATH="$INCUS_SHIM_NO:$PATH" \
        "$ROOT/commands/bootstrap.sh" dev-server --hostname h --users "$BOOT_USERS/box"
  # host=no is the other side of apply's host= rule — the box role is skipped
  # with a warning there, never refused, so bootstrap must not refuse it either.
  check "bootstrap: host=no never gets the incus precondition" 1 "must run as root" \
    env TS_AUTHKEY=x RIG_SKIP_BOX_INSTALL=1 PATH="$INCUS_SHIM_NO:$PATH" \
        "$ROOT/commands/bootstrap.sh" workload-server --users "$BOOT_USERS/box"
fi
# rig does NOT resolve the open "should rig install box" question here: the
# precondition refuses, it never calls setup-host itself. A grep that finds
# nothing (exit 1) is the pass — same shape as the never-apt-install-incus law.
check "bootstrap: the users phase never runs box setup-host itself" 1 "" \
  grep -nE '^[[:space:]]*box setup-host' "$ROOT/commands/bootstrap.sh"
# ORDERING is a correctness property, not taste: apply READS /etc/rig/role
# (root-door= picks its root-SSH note, host= decides what a missing incus group
# means), and on host=yes it needs the group box's installer built. So the
# users phase must sit after BOTH the marker write and the box install. Line
# numbers, same idiom as the marker/box-install ordering asserts above;
# defaults fail closed. The apply call is grepped as a literal — single quotes
# intended, $HERE/$USERS_FILE are the script's own.
# shellcheck disable=SC2016
users_apply_at="$(grep -n '"$HERE/users-apply.sh" --file "$USERS_FILE"' "$ROOT/commands/bootstrap.sh" | head -n1 | cut -d: -f1)"
check "bootstrap: the users phase invokes users apply" 0 "" \
  test -n "$users_apply_at"
check "bootstrap: the users phase runs after the role marker write" \
  0 "" test "${box_marker_at:-999999}" -lt "${users_apply_at:-0}"
check "bootstrap: the users phase runs after the box install" \
  0 "" test "${box_install_at:-999999}" -lt "${users_apply_at:-0}"
# The users file is passed per invocation and NEVER persisted (README: "rig
# never persists it"). Taking it as a bootstrap flag must not quietly turn it
# into box state, so nothing may copy it anywhere. A grep that finds nothing
# (exit 1) is the pass — same shape as the never-apt-install-incus law.
check "bootstrap: the users file is never copied onto the box" 1 "" \
  grep -nE '^[[:space:]]*(cp|install|mv|tee|cat)[[:space:]].*USERS_FILE' "$ROOT/commands/bootstrap.sh"
# Usage must carry both flags: an operator hitting the new requirement reads
# --help next, and finding only --users there would leave the opt-out a secret.
check "bootstrap: usage documents --users"    0 "--users"    "$ROOT/commands/bootstrap.sh" --help
check "bootstrap: usage documents --no-users" 0 "--no-users" "$ROOT/commands/bootstrap.sh" --help
check "rig usage documents the bootstrap users flags" 0 "(--users <path> | --no-users)" \
  "$ROOT/bin/rig" --help
# The TENANT family takes neither flag. Dispatch happens before this parser
# runs, so --users lands in the tenant script's own unknown-flag refusal — the
# decision (a box-minted guest has no SSH door of its own; entry is `box shell`,
# gated by the HOST's incus grants) is documented in usage and the README.
check "bootstrap: --users does not reach the tenant roles" 2 "unknown flag" \
  "$ROOT/commands/bootstrap.sh" claude-box --users "$BOOT_USERS/ok"
check "bootstrap: usage explains why tenants take no --users" 0 "box-minted GUEST" \
  "$ROOT/commands/bootstrap.sh" --help
# --- README: the box rename (#12) --------------------------------------------
# The philosophy line must point at heavy-duty/box — the old claudebox slug
# only works through a GitHub redirect that one squatted rename away from
# breaking (box's own installer was already bitten by the rename once). A
# negative grep (exit 1 = pass) keeps the stale slug from creeping back.
check "README: no stale heavy-duty/claudebox links" 1 "" \
  grep -n "heavy-duty/claudebox" "$ROOT/README.md"
check "README: points at heavy-duty/box" 0 "" \
  grep -q "github.com/heavy-duty/box" "$ROOT/README.md"

# The users-apply section is the operator's reference for what the box role
# does, and #58 inverted its central claim: the trait decides in BOTH
# directions now, and the group's presence never overrides it. A reference
# that still says "when the incus group is absent, the host= trait decides"
# asserts the very bypass that was the bug. Pinned in both directions — the
# current sentence present, the superseded one gone — so the prose cannot
# drift back to describing a semantics the code no longer has.
check "README: the trait gates the box role regardless of the group" 0 "" \
  grep -q "the \`incus\` group never overrides it" "$ROOT/README.md"
check "README: documents the mismatch strip on host=no" 0 "" \
  grep -q "half-grant is the same defect as a fresh one" "$ROOT/README.md"
check "README: no stale 'group absent decides' semantics" 1 "" \
  grep -n "when the \`incus\` group is absent, the \`host=\` trait decides" "$ROOT/README.md"
if [ "$(id -u)" -ne 0 ]; then
  # Every machine-role invocation now states its users answer — the flag is
  # required (#51), so reaching the root check at all proves it was accepted.
  # --no-users here keeps these asserts about the ROOT CHECK; the --users path
  # gets its own root-check assert below, against a valid fixture.
  check "bootstrap: refuses non-root"      1 "must run as root" env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" workload-server --no-users
  check "bootstrap: --users file reaches the root check" 1 "must run as root" \
    env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" workload-server --users "$BOOT_USERS/ok"
  check "bootstrap: runner role parses, refuses non-root" 1 "must run as root" env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" runner-server --no-users
  # staging-box dispatches to the tenant mechanism; reaching ITS root check
  # through bootstrap.sh proves the dispatch and the tenant arg pass in one go.
  # RIG_ROLE_MARKER points at an absent fixture: the tenant marker guard runs
  # before the root check, and the machine running this harness may well have
  # a real /etc/rig/role of its own.
  check "bootstrap: staging-box dispatches to the tenant mechanism, refuses non-root" 1 "must run as root" \
    env RIG_ROLE_MARKER=/nonexistent/rig-role "$ROOT/commands/bootstrap.sh" staging-box
  check "bootstrap: dev role parses, refuses non-root" 1 "must run as root" env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" dev-server --no-users
  check "bootstrap: workstation parses, refuses non-root" 1 "must run as root" env -u TS_AUTHKEY "$ROOT/commands/bootstrap.sh" workstation --no-users
  check "bootstrap: custom parses, refuses non-root" 1 "must run as root" \
    env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" custom --hostname b --root-door open --host no --join authkey --no-users
else
  echo "skip: bootstrap non-root refusals (running as root)"
fi

# --- box tenant roles (#31/#76): claude-box|codex-box|grok-box|staging-box ---
# What a box-minted guest becomes — ONE mechanism (bootstrap-tenant.sh),
# parameterized per tenant through lib/tenant-config.sh, dispatched from
# bootstrap.sh so `rig bootstrap <role>` stays the single entrypoint. The real
# converge needs root, a tenant user, and the network — the container
# rehearsal's job — so the harness proves what it can non-root: the whole
# arg/refusal surface, the pure parameter table, the rendered agent-context
# file (guard note included), and grep-pins on the shipped script.
# THE HARD CUT, tenant half (#76). The pre-rename names are gone and must fail
# as UNKNOWN — asserted per name, because an alias left in for one tenant is the
# shape that survives review: the taxonomy reads complete while one old name
# still quietly converges. Checked at BOTH entrypoints, since bootstrap.sh has
# its own dispatch list and a name could survive in one and not the other.
for r in claude codex grok staging; do
  check "tenant: the pre-#76 name '$r' is gone (tenant entrypoint)" 2 "unknown tenant role" \
    "$ROOT/commands/bootstrap-tenant.sh" "$r"
  check "tenant: the pre-#76 name '$r' is gone (bootstrap dispatch)" 2 "unknown role" \
    "$ROOT/commands/bootstrap.sh" "$r"
done
check "tenant: --help exits 0"          0 "usage:" "$ROOT/commands/bootstrap-tenant.sh" --help
check "tenant: role required, exit 2"   2 "tenant role required" "$ROOT/commands/bootstrap-tenant.sh"
check "tenant: unknown role exits 2"    2 "unknown tenant role" "$ROOT/commands/bootstrap-tenant.sh" potato
check "tenant: unknown flag exits 2"    2 "unknown flag" "$ROOT/commands/bootstrap-tenant.sh" claude-box --nope
check "tenant: --user needs value"      2 "needs a value" "$ROOT/commands/bootstrap-tenant.sh" claude-box --user
check "tenant: bad --user charset exits 2" 2 "invalid user" "$ROOT/commands/bootstrap-tenant.sh" claude-box --user 'fo|o'
# The docker converge asserts the DAEMON answers, not just the client binary —
# a dead dockerd passing `docker --version` is the "linked but cannot run"
# scar in daemon form. Grep-pinned so the assert cannot ship deleted.
check "tenant: dockerd effective-state assert is present" 0 "" \
  grep -qF "docker info" "$ROOT/commands/bootstrap-tenant.sh"
# The machine-role traits die with the tenant story, never "unknown flag" — an
# operator reaching for --hostname must learn where the trait family went.
check "tenant: trait flags die with the tenant story" 2 "have no traits" \
  "$ROOT/commands/bootstrap-tenant.sh" claude-box --root-door closed
check "tenant: --hostname dies the same way" 2 "have no traits" \
  "$ROOT/commands/bootstrap-tenant.sh" staging-box --hostname my-guest
# Dispatch: the machine-role entrypoint hands tenant roles to the tenant
# mechanism with args intact (--help reaching the TENANT usage proves both).
check "bootstrap: tenant roles dispatch through bootstrap.sh" 0 "claude-box|codex-box|grok-box|staging-box" \
  "$ROOT/commands/bootstrap.sh" claude-box --help
# The marker guard fires BEFORE the root check (repo precedent: the coolify
# marker warning), so the refusals are provable here off fixture markers. A
# VM host (host=yes) refuses for every tenant — and names the staging PAIR,
# because whoever lands here has the two halves confused and wants the metal
# (staging-server). An agent tenant refuses ANY machine-role box; staging-box
# tolerates ONLY root-door=open with host=no — that is the guest after its
# operator-run workload join, and re-converging it is what convergence is for.
# A closed-door machine (root-door=closed via custom) is NOT that guest, and
# open-door hardening would die at it with root-door=open-specific messaging —
# refuse instead.
TEN_FIX="$(mktemp -d)"
printf 'role=dev-server root-door=closed host=yes join=authkey\n'      > "$TEN_FIX/host"
printf 'role=workload-server root-door=open host=no join=authkey\n'    > "$TEN_FIX/machine"
printf 'role=custom root-door=closed host=no join=login\n'             > "$TEN_FIX/closed"
printf 'role=claude-box tenant=yes host=no\n'                  > "$TEN_FIX/tenant"
check "tenant: staging-box refuses a closed-door machine box" 1 "root door is not open" \
  env RIG_ROLE_MARKER="$TEN_FIX/closed" "$ROOT/commands/bootstrap-tenant.sh" staging-box
check "tenant: refuses a host=yes box (a VM host is never a guest)" 1 "hosts VMs" \
  env RIG_ROLE_MARKER="$TEN_FIX/host" "$ROOT/commands/bootstrap-tenant.sh" claude-box
check "tenant: the host refusal sends you to the metal half of the pair" 1 "staging-server" \
  env RIG_ROLE_MARKER="$TEN_FIX/host" "$ROOT/commands/bootstrap-tenant.sh" staging-box
check "tenant: an agent role refuses a machine-role box" 1 "never tailnet machines" \
  env RIG_ROLE_MARKER="$TEN_FIX/machine" "$ROOT/commands/bootstrap-tenant.sh" claude-box

# The tenant guard's compat read (#77). This guard asks "does this marker name
# a root-door policy?" as its proxy for "is this a real fleet machine?", and it
# must ask it in BOTH vocabularies. Kept deliberately at the retired spelling,
# same reason as the close-root fixtures below: a pre-#77 box that stops
# looking like a machine here is the fail-OPEN direction of this rename — the
# agent-tenant refusal never fires, and `rig bootstrap claude-box` converges a
# tenant straight over a live fleet box, clobbering the marker that holds its
# root-door policy. Do not modernize these two fixtures.
printf 'role=workload-server class=server host=no join=authkey\n'      > "$TEN_FIX/pre77-machine"
printf 'role=custom class=human host=no join=login\n'                  > "$TEN_FIX/pre77-human"
check "tenant: an agent role refuses a PRE-#77 machine marker" 1 "never tailnet machines" \
  env RIG_ROLE_MARKER="$TEN_FIX/pre77-machine" "$ROOT/commands/bootstrap-tenant.sh" claude-box
check "tenant: staging-box refuses a PRE-#77 closed-door machine box" 1 "root door is not open" \
  env RIG_ROLE_MARKER="$TEN_FIX/pre77-human" "$ROOT/commands/bootstrap-tenant.sh" staging-box
if [ "$(id -u)" -ne 0 ]; then
  # RIG_ROLE_MARKER pinned to the absent fixture: the marker guard runs before
  # the root check, and the harness machine may carry a real /etc/rig/role.
  check "tenant: claude-box parses, refuses non-root" 1 "must run as root" \
    env RIG_ROLE_MARKER="$TEN_FIX/absent" "$ROOT/commands/bootstrap-tenant.sh" claude-box
  check "tenant: codex-box parses, refuses non-root"  1 "must run as root" \
    env RIG_ROLE_MARKER="$TEN_FIX/absent" "$ROOT/commands/bootstrap-tenant.sh" codex-box
  check "tenant: grok-box parses, refuses non-root"   1 "must run as root" \
    env RIG_ROLE_MARKER="$TEN_FIX/absent" "$ROOT/commands/bootstrap-tenant.sh" grok-box
  check "tenant: staging-box tolerates a workload-joined guest's marker" 1 "must run as root" \
    env RIG_ROLE_MARKER="$TEN_FIX/machine" "$ROOT/commands/bootstrap-tenant.sh" staging-box
  # ...and the same guest joined before #77: reaching the root check (rather
  # than a marker refusal) is what proves the tolerance survived the rename.
  check "tenant: staging-box tolerates a PRE-#77 workload-joined guest" 1 "must run as root" \
    env RIG_ROLE_MARKER="$TEN_FIX/pre77-machine" "$ROOT/commands/bootstrap-tenant.sh" staging-box
  check "tenant: a tenant marker re-runs fine (convergence)" 1 "must run as root" \
    env RIG_ROLE_MARKER="$TEN_FIX/tenant" "$ROOT/commands/bootstrap-tenant.sh" claude-box
else
  echo "skip: tenant non-root refusals (running as root)"
fi
rm -rf "$TEN_FIX"

# The per-tenant parameter table and the agent-context renderer are pure lib
# functions on purpose (repo precedent: parse_users_file, json_string_array):
# the CLI path to them sits behind root + a real tenant user, so the harness
# proves them here, sourced, non-root and network-free.
tuser() { bash -c 'set -euo pipefail
  . "$1/commands/lib/tenant-config.sh"; tenant_user "$2"' _ "$ROOT" "$1"; }
tpath() { bash -c 'set -euo pipefail
  . "$1/commands/lib/tenant-config.sh"; tenant_context_path "$2" "$3"' _ "$ROOT" "$1" "$2"; }
tctx()  { bash -c 'set -euo pipefail
  . "$1/commands/lib/tenant-config.sh"; render_tenant_context "$2"' _ "$ROOT" "$1"; }
check "tenant params: agent users are named after their agent" 0 "claude" tuser claude-box
check "tenant params: staging's user is box#69's ops" 0 "ops" tuser staging-box
check "tenant params: claude context lands in ~/.claude/CLAUDE.md" 0 "/home/claude/.claude/CLAUDE.md" tpath claude-box /home/claude
check "tenant params: codex context lands in ~/.codex/AGENTS.md" 0 "/home/codex/.codex/AGENTS.md" tpath codex-box /home/codex
check "tenant params: grok context lands in ~/.grok/AGENTS.md" 0 "/home/grok/.grok/AGENTS.md" tpath grok-box /home/grok
check "tenant params: staging has no context file" 1 "" tpath staging-box /home/ops
# The box#80 guard note lives ONCE, in the renderer, and every agent's file
# carries it — the layering decision's whole point: never per-template again.
check "tenant context: claude carries the box#80 guard" 0 "box setup-host" tctx claude-box
check "tenant context: codex carries the box#80 guard"  0 "box setup-host" tctx codex-box
check "tenant context: grok carries the box#80 guard"   0 "box setup-host" tctx grok-box
check "tenant context: the guard says whose host this is not" 0 "not a host you own" tctx claude-box
check "tenant context: the guard cites box#80" 0 "box#80" tctx claude-box
check "tenant context: the creds-free contract is stated" 0 "Creds-free by default" tctx claude-box
check "tenant context: claude names /login as the operator's flow" 0 "/login" tctx claude-box
check "tenant context: codex names its login flow" 0 "login flow (\`codex\`)" tctx codex-box
check "tenant context: grok names its login flow" 0 "grok login" tctx grok-box
check "tenant context: staging renders nothing (no agent lives there)" 1 "" tctx staging-box
# Creds-free BY CONSTRUCTION, provable by absence (box#69's grep-refusal
# idiom): nothing in the tenant mechanism touches the tailnet, prompts, or
# apt-installs incus. A grep that finds nothing (exit 1) is the pass.
check "tenant: never touches the tailnet" 1 "" \
  grep -nE 'tailscale|TS_AUTHKEY' "$ROOT/commands/bootstrap-tenant.sh"
check "tenant: non-interactive — nothing prompts" 1 "" \
  grep -nE '\bread -r' "$ROOT/commands/bootstrap-tenant.sh"
check "tenant: never apt-installs incus (box owns the daemon)" 1 "" \
  grep -nE 'apt-get install.* incus' "$ROOT/commands/bootstrap-tenant.sh"
# staging-box's posture rides the SAME hardening code as the machine roles — the
# shared lib call is the anti-drift property, so pin the call, not the words.
check "tenant: staging-box hardens through the shared sshd lib" 0 "" \
  grep -qE '^[[:space:]]*harden_sshd open$' "$ROOT/commands/bootstrap-tenant.sh"
check "tenant: docker lands via docker's own installer" 0 "" \
  grep -q "get.docker.com" "$ROOT/commands/bootstrap-tenant.sh"
# The #15 lesson pinned: 'box exec' shells read no rc files, so the CLI must
# land on the SYSTEM path — and a claimed install is verified, not trusted:
# it must ANSWER as the tenant user (the grok-box template's scar: linked but
# cannot run). The $CLI/$TENANT_USER are literals we grep for in the script.
# shellcheck disable=SC2016
check "tenant: the agent CLI lands on the system PATH" 0 "" \
  grep -qF '/usr/local/bin/$CLI' "$ROOT/commands/bootstrap-tenant.sh"
# shellcheck disable=SC2016
check "tenant: the CLI install is verified as the tenant user" 0 "" \
  grep -qF 'runuser -l "$TENANT_USER" -c "$CLI --version"' "$ROOT/commands/bootstrap-tenant.sh"
# Ordering is the safety property, as with bootstrap's marker-then-box assert:
# the tenant marker may only describe converges that already happened, so the
# write sits after the context-file converge. Defaults fail closed.
ten_ctx_at="$(grep -n 'agent-context file written' "$ROOT/commands/bootstrap-tenant.sh" | head -n1 | cut -d: -f1)"
# shellcheck disable=SC2016
ten_marker_at="$(grep -nF 'install -m 0644 "$MARKER_TMP" "$MARKER_PATH"' "$ROOT/commands/bootstrap-tenant.sh" | head -n1 | cut -d: -f1)"
check "tenant: the marker write follows the context-file converge" \
  0 "" test "${ten_ctx_at:-999999}" -lt "${ten_marker_at:-0}"
# The write's "is a machine marker already here?" test must go through the
# resolver, not through a pattern match on one spelling (#77). Pinned as a
# byte-grep because the failure it prevents is silent and expensive: a
# spelling-specific test would let a tenant converge CLOBBER a machine marker
# written in the other vocabulary — on a joined workload box that means
# replacing its root-door policy with a tenant line close-root then refuses on.
# shellcheck disable=SC2016
check "tenant: the marker write is gated on the resolved root-door, not a spelling" 0 "" \
  grep -qxF 'if [ -z "$EXISTING_ROOT_DOOR" ]; then' "$ROOT/commands/bootstrap-tenant.sh"

check "coolify: version required, exit 2"  2 "--version"      "$ROOT/commands/coolify-install.sh"
check "coolify: --help exits 0"            0 "usage:"         "$ROOT/commands/coolify-install.sh" --help
check "coolify: version needs value"       2 "needs a value"  "$ROOT/commands/coolify-install.sh" --version
check "coolify: unknown flag exits 2"      2 "unknown flag"   "$ROOT/commands/coolify-install.sh" --nope
if [ "$(id -u)" -ne 0 ]; then
  check "coolify: refuses non-root"        1 "must run as root" "$ROOT/commands/coolify-install.sh" --version 4.1.2
else
  echo "skip: coolify non-root refusal (running as root)"
fi

check "bare coolify backup shows usage, exit 2" 2 "usage:" "$ROOT/bin/rig" coolify backup
check "coolify backup: bad subcommand exits 2"  2 "usage:" "$ROOT/bin/rig" coolify backup frobnicate
check "coolify backup: --help exits 0"          0 "usage:" "$ROOT/commands/coolify-backup-install.sh" --help
check "coolify backup: schedule needs value"    2 "needs a value" "$ROOT/commands/coolify-backup-install.sh" --schedule
check "coolify backup: pg-container needs value" 2 "needs a value" "$ROOT/commands/coolify-backup-install.sh" --pg-container
check "coolify backup: unknown flag exits 2"    2 "unknown flag"  "$ROOT/commands/coolify-backup-install.sh" --nope
if [ "$(id -u)" -ne 0 ]; then
  check "coolify backup: refuses non-root"      1 "must run as root" "$ROOT/commands/coolify-backup-install.sh"
else
  echo "skip: coolify backup non-root refusal (running as root)"
fi

# --- role-marker sanity: coolify verbs off the control plane (#25) -----------
# Both coolify commands read /etc/rig/role and WARN — never die — when the
# marker names a non-control-plane role: the likeliest story is the wrong SSH
# session, but the marker is advisory and must not outrank the operator. The
# warning fires BEFORE the root check (same testability rule as arg errors),
# so a non-root run prints it and then hits the root refusal — provable here
# with RIG_ROLE_MARKER pointed at fixtures (repo precedent: the close-root
# marker gate). Counting fires proves silence too: a control-plane marker, an
# absent marker, and a marker-less box must all stay quiet, because warning on
# absence would nag every pre-marker box on every legitimate run.
marker_warns() { # marker_warns <marker_path> <cmd...> — how many warnings fired
  local marker="$1"; shift
  env RIG_ROLE_MARKER="$marker" "$@" 2>&1 | grep -c "not a control-plane box" || true
}
MARKER_FIX="$(mktemp -d)"
printf 'role=workload-server root-door=open host=no join=authkey\n'    > "$MARKER_FIX/workload"
printf 'role=control-plane-server root-door=open host=no join=authkey\n' > "$MARKER_FIX/control-plane"
printf 'role=control-plane-server\n'                                   > "$MARKER_FIX/bare-control-plane"
# A PRE-#76 marker, verbatim as a real box bootstrapped before the rename
# carries it. This is the one fixture that must keep its old spelling: the
# CHANGELOG promises such a box takes the warning branch and keeps working,
# and until this existed nothing asserted it — every other fixture here was
# renamed with the code, so the migration story was documented and untested.
printf 'role=control-plane class=server host=no join=authkey\n'        > "$MARKER_FIX/pre-rename-cp"
if [ "$(id -u)" -ne 0 ]; then
  check "coolify: warns on a non-control-plane marker" 0 "1" \
    marker_warns "$MARKER_FIX/workload" "$ROOT/commands/coolify-install.sh" --version 4.1.2
  check "coolify: control-plane marker stays silent" 0 "0" \
    marker_warns "$MARKER_FIX/control-plane" "$ROOT/commands/coolify-install.sh" --version 4.1.2
  # A bare marker line with no trailing traits must read the same as the full
  # one — the guard must not couple to the marker's field formatting.
  check "coolify: a bare 'role=control-plane-server' line (no traits) stays silent" 0 "0" \
    marker_warns "$MARKER_FIX/bare-control-plane" "$ROOT/commands/coolify-install.sh" --version 4.1.2
  check "coolify: absent marker stays silent (advisory, not a gate)" 0 "0" \
    marker_warns "$MARKER_FIX/absent" "$ROOT/commands/coolify-install.sh" --version 4.1.2
  # The migration story, pinned in both halves: a pre-#76 control plane WARNS
  # (its marker no longer names a role that exists) but is never refused. Both
  # halves matter — a rename that turned this into a refusal would break the
  # exact boxes the CHANGELOG promises keep working, and it would do it on the
  # command that installs the control plane.
  check "coolify: a PRE-#76 'role=control-plane' marker warns (migration)" 0 "1" \
    marker_warns "$MARKER_FIX/pre-rename-cp" "$ROOT/commands/coolify-install.sh" --version 4.1.2
  check "coolify: ...and is still never refused" 1 "must run as root" \
    env RIG_ROLE_MARKER="$MARKER_FIX/pre-rename-cp" "$ROOT/commands/coolify-install.sh" --version 4.1.2
  check "coolify backup: a PRE-#76 'role=control-plane' marker warns (migration)" 0 "1" \
    marker_warns "$MARKER_FIX/pre-rename-cp" "$ROOT/commands/coolify-backup-install.sh"
  # The warning must stay a warning: the run proceeds past it and stops at the
  # root check (exit 1), never turned into a marker refusal.
  check "coolify: the marker warns but never refuses" 1 "must run as root" \
    env RIG_ROLE_MARKER="$MARKER_FIX/workload" "$ROOT/commands/coolify-install.sh" --version 4.1.2
  check "coolify backup: warns on a non-control-plane marker" 0 "1" \
    marker_warns "$MARKER_FIX/workload" "$ROOT/commands/coolify-backup-install.sh"
  check "coolify backup: control-plane marker stays silent" 0 "0" \
    marker_warns "$MARKER_FIX/control-plane" "$ROOT/commands/coolify-backup-install.sh"
  check "coolify backup: the marker warns but never refuses" 1 "must run as root" \
    env RIG_ROLE_MARKER="$MARKER_FIX/workload" "$ROOT/commands/coolify-backup-install.sh"
else
  echo "skip: coolify role-marker warning checks (running as root)"
fi
rm -rf "$MARKER_FIX"
# Root runs skip the live checks above, so also pin the warning's presence in
# both shipped scripts — a deleted advisory cannot ship green (repo precedent:
# the staging/runner tag greps).
check "coolify: marker warning present in the shipped script" 0 "" \
  grep -q "not a control-plane box" "$ROOT/commands/coolify-install.sh"
check "coolify backup: marker warning present in the shipped script" 0 "" \
  grep -q "not a control-plane box" "$ROOT/commands/coolify-backup-install.sh"

# --- rig db (ad-hoc dump/restore) -------------------------------------------
check "bare db shows usage, exit 2"       2 "usage:" "$ROOT/bin/rig" db
check "db --help exits 0"                 0 "usage:" "$ROOT/bin/rig" db --help
check "db bad subcommand exits 2"         2 "usage:" "$ROOT/bin/rig" db frobnicate
check "db dump: --help exits 0"           0 "usage:" "$ROOT/commands/db.sh" dump --help
check "db dump: container required, exit 2" 2 "needs a container" "$ROOT/commands/db.sh" dump
check "db dump: unknown flag exits 2"     2 "unknown flag" "$ROOT/commands/db.sh" dump --nope
check "db restore: artifact required, exit 2" 2 "needs an artifact" "$ROOT/commands/db.sh" restore
check "db restore: container required, exit 2" 2 "needs a target container" \
  "$ROOT/commands/db.sh" restore /tmp/whatever.sql.gz
check "db restore: unknown flag exits 2"  2 "unknown flag" "$ROOT/commands/db.sh" restore --nope
# Artifact existence is checked BEFORE docker/root, so a fat-fingered path fails
# clearly and cheaply — and is testable here without root or a live container.
check "db restore: missing artifact fails before the docker/root path" \
  1 "artifact not found" "$ROOT/commands/db.sh" restore /no/such/artifact.sql.gz somecontainer --yes

# The two DB invariants live as embedded command strings (single-quoted sh -c),
# not an extractable heredoc, so guard them directly: dropping --no-owner/--no-acl
# breaks every cross-instance restore, and hardcoding a role instead of the
# container's own $POSTGRES_USER/$POSTGRES_DB is wrong on Coolify's randomized
# superuser. ON_ERROR_STOP=1 is what makes a bad restore fail instead of limp.
check "db dump embeds --no-owner --no-acl" 0 "" \
  grep -qF -- "--no-owner --no-acl" "$ROOT/commands/db.sh"
# The $POSTGRES_USER below is a LITERAL we grep for in db.sh (it must read the
# container's env, not the host's) — single quotes are the point here.
# shellcheck disable=SC2016
check "db dump reads the container's own \$POSTGRES_USER/\$POSTGRES_DB" 0 "" \
  grep -qF 'pg_dump -U "$POSTGRES_USER"' "$ROOT/commands/db.sh"
# shellcheck disable=SC2016
check "db restore connects as the container's own \$POSTGRES_USER" 0 "" \
  grep -qF 'psql -U "$POSTGRES_USER"' "$ROOT/commands/db.sh"
check "db restore uses ON_ERROR_STOP=1" 0 "" \
  grep -qF "ON_ERROR_STOP=1" "$ROOT/commands/db.sh"
if [ "$(id -u)" -ne 0 ]; then
  # Valid args, so validation passes and we reach the root guard.
  check "db dump: refuses non-root"       1 "must run as root" "$ROOT/commands/db.sh" dump somecontainer
  # Restore needs a real, non-empty artifact to get PAST the artifact check and
  # reach the root guard; --yes skips the confirm prompt so the check is exit-clean.
  DB_ART="$(mktemp)"; printf 'SELECT 1;\n' > "$DB_ART"
  check "db restore: refuses non-root"    1 "must run as root" \
    "$ROOT/commands/db.sh" restore "$DB_ART" somecontainer --yes
  rm -f "$DB_ART"
else
  echo "skip: db non-root refusals (running as root)"
fi

check "bare runner shows usage, exit 2"  2 "usage:"          "$ROOT/bin/rig" runner
check "runner: --help exits 0"           0 "usage:"          "$ROOT/commands/runner-install.sh" --help
check "runner: repo required, exit 2"    2 "--repo"          "$ROOT/commands/runner-install.sh" --version 2.335.1
check "runner: version needs value"      2 "needs a value"   "$ROOT/commands/runner-install.sh" --repo acme/widgets --version
check "runner: repo needs value"         2 "needs a value"   "$ROOT/commands/runner-install.sh" --repo
check "runner: rejects bad repo slug"    2 "owner/repo"      "$ROOT/commands/runner-install.sh" --repo not-a-slug --version 2.335.1
check "runner: refuses --user root"      2 "must not be root" "$ROOT/commands/runner-install.sh" --repo acme/widgets --version 2.335.1 --user root
check "runner: unknown flag exits 2"     2 "unknown flag"    "$ROOT/commands/runner-install.sh" --nope
if [ "$(id -u)" -ne 0 ]; then
  check "runner: refuses non-root"       1 "must run as root" env RUNNER_TOKEN=x "$ROOT/commands/runner-install.sh" --repo acme/widgets --version 2.335.1
else
  echo "skip: runner non-root refusal (running as root)"
fi

check "runner: bad subcommand exits 2"   2 "usage:"           "$ROOT/bin/rig" runner frobnicate

# --- headless prompts refuse loudly (issue #42) ------------------------------
# The three credential prompts (TS_AUTHKEY, RUNNER_TOKEN, RUNNER_REMOVE_TOKEN)
# used to be bare `read -rsp`: with no tty, read exits non-zero and `set -e`
# ends the script with NO output at all — the drill watched a bootstrap die
# mid-converge with exit 1 and nothing to grep. Each prompt now refuses first,
# naming its variable. The prompts live behind the root check (and, for the
# runner pair, behind a real registration), so the harness cannot reach them
# non-root; grep the guards so a deleted one cannot ship green (repo
# precedent: the login-path tag refusals above).
check "bootstrap: headless TS_AUTHKEY prompt refuses loudly" 0 "" \
  grep -q 'TS_AUTHKEY is unset and stdin is not a tty' "$ROOT/commands/bootstrap.sh"
check "runner install: headless token prompt refuses loudly" 0 "" \
  grep -q 'RUNNER_TOKEN is unset and stdin is not a tty' "$ROOT/commands/runner-install.sh"
check "runner remove: headless token prompt refuses loudly" 0 "" \
  grep -q 'RUNNER_REMOVE_TOKEN is unset and stdin is not a tty' "$ROOT/commands/runner-remove.sh"
# The EOF-at-the-prompt path (Ctrl-D on a real tty) must also die with a last
# word rather than ride set -e into silence: every read is `|| die`-guarded,
# so a bare `read -rsp` (no `||` on its line) must not exist anywhere.
check "prompts: no bare read -rsp remains" 1 "" \
  grep -RE 'read -rsp[^|]*$' "$ROOT/commands/"

# --- runner install: --repo must agree with what the box is already on -------
# The bug: `install --repo B` on a box registered to repo A skipped configure,
# restarted the service on A, and reported success — --repo accepted, validated,
# then ignored. The guard is exercised here through the shared lib, against a
# fixture .runner: reaching it via the CLI needs root AND a really-registered
# runner, neither of which this harness can fabricate.
guard() { # guard <runner_dir> <owner/repo>
  bash -c 'set -euo pipefail
    . "$1/commands/lib/runner-config.sh"
    assert_runner_repo "$2" "$3"' _ "$ROOT" "$1" "$2"
}
REG_DIR="$(mktemp -d)"    # a box registered to acme/alpha
EMPTY_DIR="$(mktemp -d)"  # a box with no runner at all
printf '%s\n' '{"agentId":7,"agentName":"ci-box","gitHubUrl":"https://github.com/acme/alpha","workFolder":"_work"}' \
  > "$REG_DIR/.runner"

check "runner install: refuses a repo the box is not registered to" \
  1 "already registered to https://github.com/acme/alpha" guard "$REG_DIR" acme/beta
check "runner install: the refusal names the repo that was asked for" \
  1 "not https://github.com/acme/beta" guard "$REG_DIR" acme/beta
check "runner install: the refusal points at repoint" \
  1 "rig runner repoint --repo acme/beta" guard "$REG_DIR" acme/beta
# Convergence is the property worth keeping: same repo stays a clean no-op.
check "runner install: the repo it is already on is a no-op" \
  0 "" guard "$REG_DIR" acme/alpha
check "runner install: an unregistered box passes the guard" \
  0 "" guard "$EMPTY_DIR" acme/beta
# A .runner rig cannot read is not a licence to assume it matches.
printf '%s\n' '{"agentName":"ci-box"}' > "$REG_DIR/.runner"
check "runner install: refuses an unreadable registration" \
  1 "names no repository" guard "$REG_DIR" acme/alpha
rm -rf "$REG_DIR" "$EMPTY_DIR"

# --- json_string_array: json_field's array-aware sibling ---------------------
# bootstrap reads `.Self.Tags` (a JSON array) out of `tailscale status --json` to
# assert the tag control GRANTED the node — and a rig box has no jq. Exercise the
# reader against fixture netmaps here, the same shared-lib way the guard above is:
# the bootstrap path that calls it needs a real tailnet this harness cannot fake.
tags() { # tags <file> — prints one tag per line, exactly like the reader
  bash -c 'set -euo pipefail
    . "$1/commands/lib/runner-config.sh"
    json_string_array "$2" Tags' _ "$ROOT" "$1"
}
tags_count() { # tags_count <file> — prints how many tags were read (0 if none)
  bash -c 'set -euo pipefail
    . "$1/commands/lib/runner-config.sh"
    json_string_array "$2" Tags | grep -c . || true' _ "$ROOT" "$1"
}
tags_empty() { # tags_empty <file> — exit 0 iff the reader prints NOTHING
  bash -c 'set -euo pipefail
    . "$1/commands/lib/runner-config.sh"
    [ -z "$(json_string_array "$2" Tags)" ]' _ "$ROOT" "$1"
}
FIX_TAGGED="$(mktemp)"    # Self carries two tags; a peer carries a third
FIX_UNTAGGED="$(mktemp)"  # Self has no Tags key at all — the untagged hazard
cat > "$FIX_TAGGED" <<'JSON'
{
  "BackendState": "Running",
  "Self": {
    "HostName": "ci-box",
    "Tags": [
      "tag:ci",
      "tag:build"
    ]
  },
  "Peer": {
    "nodekey:abc": {
      "HostName": "coolify-box",
      "Tags": [
        "tag:server"
      ]
    }
  }
}
JSON
cat > "$FIX_UNTAGGED" <<'JSON'
{
  "BackendState": "Running",
  "Self": {
    "HostName": "user-owned-box"
  }
}
JSON
check "json_string_array: reads the first array element" 0 "tag:ci"    tags "$FIX_TAGGED"
check "json_string_array: reads a later array element"   0 "tag:build" tags "$FIX_TAGGED"
# Self precedes Peer in the netmap, so the FIRST "Tags" is the node's own: exactly
# two elements read proves the peer's tag:server did not leak into Self's tags.
check "json_string_array: reads Self's array, not a peer's" 0 "2" tags_count "$FIX_TAGGED"
# An absent key omits itself (Go omitempty), never emits []: empty is the signal
# bootstrap turns into a hard untagged-key refusal, so it must read as empty here.
check "json_string_array: absent Tags key prints nothing" 0 "" tags_empty "$FIX_UNTAGGED"
rm -f "$FIX_TAGGED" "$FIX_UNTAGGED"

# The guard is only worth something if it runs BEFORE the box is touched: the
# token prompt, the download, configure and svc.sh start all come after it.
# Ordering is the whole fix, so assert it rather than trust it.
# Matches the CALL, not the word: the comment above it mentions assert_runner_repo
# too, and a plain grep would keep finding that after the call itself was deleted.
# The defaults fail closed, so a guard that is gone cannot read as one that merely
# sits early in the file.
guard_at="$(grep -nE '^[[:space:]]*assert_runner_repo ' "$ROOT/commands/runner-install.sh" | head -n1 | cut -d: -f1)"
start_at="$(grep -n 'svc.sh start' "$ROOT/commands/runner-install.sh" | head -n1 | cut -d: -f1)"
check "runner install: the repo guard precedes svc.sh start" \
  0 "" test "${guard_at:-999999}" -lt "${start_at:-0}"

check "runner status: --help exits 0"        0 "usage:"           "$ROOT/commands/runner-status.sh" --help
check "runner status: user needs value"      2 "needs a value"    "$ROOT/commands/runner-status.sh" --user
check "runner status: refuses --user root"   2 "must not be root" "$ROOT/commands/runner-status.sh" --user root
check "runner status: unknown flag exits 2"  2 "unknown flag"     "$ROOT/commands/runner-status.sh" --nope

check "runner remove: --help exits 0"        0 "usage:"           "$ROOT/commands/runner-remove.sh" --help
check "runner remove: user needs value"      2 "needs a value"    "$ROOT/commands/runner-remove.sh" --user
check "runner remove: refuses --user root"   2 "must not be root" "$ROOT/commands/runner-remove.sh" --user root
check "runner remove: unknown flag exits 2"  2 "unknown flag"     "$ROOT/commands/runner-remove.sh" --nope

check "runner repoint: --help exits 0"       0 "usage:"           "$ROOT/commands/runner-repoint.sh" --help
check "runner repoint: repo required"        2 "--repo"           "$ROOT/commands/runner-repoint.sh"
check "runner repoint: repo needs value"     2 "needs a value"    "$ROOT/commands/runner-repoint.sh" --repo
check "runner repoint: rejects bad slug"     2 "owner/repo"       "$ROOT/commands/runner-repoint.sh" --repo not-a-slug
check "runner repoint: labels need value"    2 "needs a value"    "$ROOT/commands/runner-repoint.sh" --repo acme/widgets --labels
check "runner repoint: refuses --user root"  2 "must not be root" "$ROOT/commands/runner-repoint.sh" --repo acme/widgets --user root
check "runner repoint: unknown flag exits 2" 2 "unknown flag"     "$ROOT/commands/runner-repoint.sh" --nope
if [ "$(id -u)" -ne 0 ]; then
  check "runner status: refuses non-root"  1 "must run as root" "$ROOT/commands/runner-status.sh"
  check "runner remove: refuses non-root"  1 "must run as root" \
    env RUNNER_REMOVE_TOKEN=x "$ROOT/commands/runner-remove.sh"
  # --local too: the token-free path must still not be runnable by the runner user.
  check "runner remove: --local refuses non-root" 1 "must run as root" \
    "$ROOT/commands/runner-remove.sh" --local
  check "runner repoint: refuses non-root" 1 "must run as root" \
    env RUNNER_REMOVE_TOKEN=x RUNNER_TOKEN=y "$ROOT/commands/runner-repoint.sh" --repo acme/widgets
else
  echo "skip: runner status/remove/repoint non-root refusals (running as root)"
fi

check "bare users shows usage, exit 2"    2 "usage:"        "$ROOT/bin/rig" users
check "users: bad subcommand exits 2"     2 "usage:"        "$ROOT/bin/rig" users frobnicate

check "users apply: --help exits 0"       0 "usage:"        "$ROOT/commands/users-apply.sh" --help
check "users apply: --file required"      2 "--file"        "$ROOT/commands/users-apply.sh"
check "users apply: --file needs value"   2 "needs a value" "$ROOT/commands/users-apply.sh" --file
check "users apply: missing file exits 2" 2 "cannot read"   "$ROOT/commands/users-apply.sh" --file /nonexistent/users
check "users apply: unknown flag exits 2" 2 "unknown flag"  "$ROOT/commands/users-apply.sh" --nope
check "users status: --help exits 0"      0 "usage:"        "$ROOT/commands/users-status.sh" --help

# --- users file refusal matrix, through the sourced parser -------------------
# Reaching the parser via the CLI stops at the root check; it is pure and
# sourceable on purpose (repo precedent: assert_runner_repo, json_string_array),
# so the refusals are proven here against fixtures, non-root and network-free.
parse() { # parse <file> — the users-file parser, exactly as apply runs it
  bash -c 'set -euo pipefail
    . "$1/commands/lib/users-config.sh"
    parse_users_file "$2"' _ "$ROOT" "$1"
}
FIX_OK="$(mktemp)"   # two operators; dan carries a second key on a repeat line
FIX_BAD="$(mktemp)"  # rewritten per refusal below
cat > "$FIX_OK" <<'USERS'
# fleet operators
dan      admin,box      ssh-ed25519 AAAAC3fixture dan@laptop
dan      admin,box      ssh-ed25519 AAAAC3second dan@desk

maria    rig            ssh-ed25519 AAAAC3fixture maria@mac
USERS
printf '%s\n' 'maria ops ssh-ed25519 AAAA maria@mac' > "$FIX_BAD"
check "users parser: unknown role names the valid set" 1 "valid roles: admin rig box" parse "$FIX_BAD"
printf '%s\n' 'dan admin ssh-ed25519 AAAA a' 'dan admin,box ssh-ed25519 BBBB b' > "$FIX_BAD"
check "users parser: differing roles across one user's lines" 1 "roles must be identical" parse "$FIX_BAD"
printf '%s\n' 'root admin ssh-ed25519 AAAA r' > "$FIX_BAD"
check "users parser: root is refused" 1 "not a rig-managed user" parse "$FIX_BAD"
printf '%s\n' 'dan admin' > "$FIX_BAD"
check "users parser: malformed line is refused" 1 "malformed" parse "$FIX_BAD"
# Usernames are validated in the same one-pass refusal matrix: 'fo|o' would
# corrupt the parser's own '|'-delimited stream (user 'fo', garbage keys), and
# a leading '-' reads as a useradd flag mid-convergence. The refusal names the
# line and the rule, like every other parser refusal.
printf '%s\n' 'fo|o admin ssh-ed25519 AAAA x' > "$FIX_BAD"
check "users parser: '|' in a username is refused"     1 "invalid username" parse "$FIX_BAD"
check "users parser: the username refusal names the line" 1 "line 1"        parse "$FIX_BAD"
printf '%s\n' '-dan admin ssh-ed25519 AAAA x' > "$FIX_BAD"
check "users parser: leading-dash username is refused" 1 "invalid username" parse "$FIX_BAD"
check "users parser: valid file emits dan (both keys' roles agree)" \
  0 "dan|admin,box|ssh-ed25519 AAAAC3second dan@desk" parse "$FIX_OK"
check "users parser: valid file emits maria too" 0 "maria|rig|ssh-ed25519" parse "$FIX_OK"
# ALL errors in ONE pass: a bad file costs one fix cycle, not one per error.
# A single invocation, both messages asserted from its one stderr.
printf '%s\n' 'root admin ssh-ed25519 AAAA r' 'maria ops ssh-ed25519 AAAA m' > "$FIX_BAD"
MULTI_ERRS="$(mktemp)"
parse "$FIX_BAD" 2> "$MULTI_ERRS"; multi_rc=$?
check "users parser: multi-error file exits 1"       0 "" test "$multi_rc" -eq 1
check "users parser: one run reports the root line"  0 "" grep -q "not a rig-managed user" "$MULTI_ERRS"
check "users parser: same run reports the bad role"  0 "" grep -q "unknown role" "$MULTI_ERRS"
rm -f "$MULTI_ERRS"

# --- '@root': seed the admin's keys from root's own authorized_keys (#17) ----
# The operator provably holds a root private key — they SSHed in with it to
# run apply at all — so seeding root's CURRENT authorized_keys is the one key
# source that cannot lock them out. The parser owns only the token's SHAPE
# (reading /root/.ssh needs root and is apply's business), so the shape is
# proven here: the exact token parses, trailing material is refused, literal
# key lines mix (append semantics), a second '@root' is a duplicate, and root
# cannot seed itself.
printf '%s\n' 'dan admin @root' > "$FIX_BAD"
check "users parser: '@root' is a valid key field" 0 "dan|admin|@root" parse "$FIX_BAD"
printf '%s\n' 'dan admin @root ssh-ed25519 AAAA x' > "$FIX_BAD"
check "users parser: '@root' takes no trailing material" 1 "whole key field" parse "$FIX_BAD"
printf '%s\n' 'dan admin @root' 'dan admin ssh-ed25519 AAAAC3lit dan@desk' > "$FIX_BAD"
check "users parser: '@root' mixes with literal key lines" \
  0 "dan|admin|ssh-ed25519 AAAAC3lit dan@desk" parse "$FIX_BAD"
printf '%s\n' 'dan admin @root' 'dan admin @root' > "$FIX_BAD"
check "users parser: a second '@root' line is a duplicate" 1 "duplicate key line" parse "$FIX_BAD"
printf '%s\n' 'root admin @root' > "$FIX_BAD"
check "users parser: root cannot seed from itself" 1 "not a rig-managed user" parse "$FIX_BAD"
# The empty-seed refusal (root has no authorized_keys) sits behind the root
# check — /root/.ssh is unreadable before it — so grep the die message, the
# same way every root-only refusal in this harness is pinned.
check "users apply: '@root' with a keyless root dies naming the repair" 0 "" \
  grep -q "root has no authorized_keys" "$ROOT/commands/users-apply.sh"

if [ "$(id -u)" -ne 0 ]; then
  # A VALID fixture proves the whole file-validation pass sits before the
  # root check — a parse failure here would exit 2, not 1.
  check "users apply: refuses non-root"  1 "must run as root" "$ROOT/commands/users-apply.sh" --file "$FIX_OK"
  # An '@root' fixture reaching the root check proves the token is parse-pass
  # validation, not a runtime surprise.
  printf '%s\n' 'dan admin @root' > "$FIX_BAD"
  check "users apply: '@root' fixture parses, refuses non-root" 1 "must run as root" \
    "$ROOT/commands/users-apply.sh" --file "$FIX_BAD"
  check "users status: refuses non-root" 1 "must run as root" "$ROOT/commands/users-status.sh"
else
  echo "skip: users non-root refusals (running as root)"
fi
rm -f "$FIX_OK" "$FIX_BAD"

# Validate-then-apply: `visudo -c` must pass before anything lands in
# /etc/sudoers.d — a bad drop-in takes down ALL of sudo, locking every admin
# out of the escalation path apply just granted. Assert the order in the file,
# matching the calls rather than comments (repo precedent: the runner-install
# repo-guard ordering check). Defaults fail closed.
visudo_at="$(grep -n 'visudo -c' "$ROOT/commands/users-apply.sh" | head -n1 | cut -d: -f1)"
sudoers_at="$(grep -nE 'install .*sudoers\.d/rig-roles' "$ROOT/commands/users-apply.sh" | head -n1 | cut -d: -f1)"
check "users apply: visudo -c precedes the sudoers install" \
  0 "" test "${visudo_at:-999999}" -lt "${sudoers_at:-0}"

# The invoker gate: %rig's sudoers rule is binary-scoped (NOPASSWD for
# /usr/local/bin/rig, any args), so without a gate `sudo rig users apply
# --file <me-as-admin>` turns role rig root-equivalent through this very
# command. Exercising it needs a real SUDO_USER and real groups, so grep the
# refusal in both identity-management commands (repo precedent: the
# staging/runner tag greps).
check "users apply: invoker gate refusal is present" 0 "" \
  grep -q "changes who holds root" "$ROOT/commands/users-apply.sh"
check "users close-root: invoker gate refusal is present" 0 "" \
  grep -q "changes who holds root" "$ROOT/commands/users-close-root.sh"
# Offboarding must revoke SSH, not just the password: a '!'-locked password is
# not a closed door under UsePAM — pubkey auth still works. Expiry is the
# switch PAM actually honors, and the keys are renamed, never deleted
# (convergence never destroys). Needs root + real accounts, so grep both moves.
check "users apply: a dropped user's account is expired, not just locked" 0 "" \
  grep -qF -- "usermod -L -e 1" "$ROOT/commands/users-apply.sh"
check "users apply: revoked keys are renamed, never deleted" 0 "" \
  grep -q "revoked-by-rig" "$ROOT/commands/users-apply.sh"
# A fleet-wide users file must not abort apply on a host=no box just because
# it names a box-role user somewhere in the fleet: the box role binds where
# VMs live, so on host=no it skips (with a warning) and everything else —
# admins included — still converges.
check "users apply: box role skips on a host=no box" 0 "" \
  grep -q "box role skipped" "$ROOT/commands/users-apply.sh"
# Apply's root-SSH note and close-root's gate must read ONE marker the same
# way, pre-#77 spellings included — a box told "close-root will shut this door"
# by apply and then refused by close-root is the worst of both (#77). Sharing
# the resolver is what guarantees it, so pin the call rather than the message.
# shellcheck disable=SC2016
check "users apply: the root-SSH note resolves through root_door_of" 0 "" \
  grep -qF 'root_door_of "$APPLY_MARKER"' "$ROOT/commands/users-apply.sh"
# ...and it warns, rather than staying silent, on the two markers close-root
# will refuse: a note that only speaks on the happy paths is not a note.
check "users apply: a doorless marker warns that close-root will refuse" 0 "" \
  grep -q "names no root-door policy" "$ROOT/commands/users-apply.sh"
check "users apply: a contradictory marker warns that close-root will refuse" 0 "" \
  grep -q "they disagree" "$ROOT/commands/users-apply.sh"

# --- the box role's host= gate (#58) -----------------------------------------
# The gate is a pure marker->verdict lib function for the same reason
# assert_marker_closes_root is: apply's box arm sits behind the root check, so every
# arm is proven HERE against fixture markers, non-root.
#
# What #58 fixed: the trait used to be consulted only when group incus was
# ABSENT, so a host=no (or marker-less) box that happened to CARRY the group
# handed box-role users a bare `usermod -aG incus` — the socket with no tier,
# which incus-user answers by lazily building an unhardened project under
# whoever opens it. The load-bearing property below is that the verdict comes
# from the marker ALONE and is therefore identical whether or not the group
# exists; the group only decides whether a box that does claim host=yes is
# ready to serve the role.
hostvm_gate() { # hostvm_gate <marker_path>
  bash -c 'set -euo pipefail
    . "$1/commands/lib/users-config.sh"
    assert_marker_hosts_vms "$2"' _ "$ROOT" "$1"
}
HOSTVM_FIX="$(mktemp -d)"
printf 'role=dev-server root-door=closed host=yes join=authkey\n'   > "$HOSTVM_FIX/yes"
printf 'role=workload-server root-door=open host=no join=authkey\n' > "$HOSTVM_FIX/no"
# A marker that predates the host= trait (or was hand-edited): present, but it
# names no host=. Distinct from an ABSENT marker and it must not read as yes.
printf 'role=workload-server root-door=open join=authkey\n'         > "$HOSTVM_FIX/traitless"
check "users apply: host=yes passes the box-role gate" \
  0 "" hostvm_gate "$HOSTVM_FIX/yes"
check "users apply: host=no fails the box-role gate" \
  1 "does not host VMs" hostvm_gate "$HOSTVM_FIX/no"
# The marker-less case gets its own answer rather than falling through to
# either yes or no: rig cannot tell an unbootstrapped box from a repurposed
# one, so it withholds (recoverable by a re-run) and names the repair.
check "users apply: an absent marker fails the box-role gate, names bootstrap" \
  1 "re-run rig bootstrap" hostvm_gate "$HOSTVM_FIX/absent"
check "users apply: a marker with no host= trait fails the gate, names bootstrap" \
  1 "re-run rig bootstrap" hostvm_gate "$HOSTVM_FIX/traitless"
rm -rf "$HOSTVM_FIX"
# The gate must actually be WIRED to the wanted-groups decision, not merely
# exist: this is the line #58 reported, where the box arm used to test group
# presence alone. Pin both operands on that arm — a revert to the INCUS_OK-only
# test must not ship green. It is a gate on whether the ROLE APPLIES, kept
# separate from the mechanism of the add on purpose, so it survives #53 moving
# the add itself into `box grant`.
check "users apply: the incus want is gated on the host= verdict, not just the group" 0 "" \
  grep -qE '\*,box,\*\).*BOX_ROLE_OK.*INCUS_OK.*want incus' "$ROOT/commands/users-apply.sh"
# Marker says no, machine says yes: the skip must NAME the contradiction and
# the one-line repair. The cost of believing the marker is a genuine VM host
# that stops provisioning, and that is only acceptable while it is loud.
check "users apply: a marker/reality mismatch warns and names the repair" 0 "" \
  grep -q "marker and this box's reality disagree" "$ROOT/commands/users-apply.sh"

# --- dropping role box goes through box, not behind its back (#50) -----------
# The 'incus' group is box's: box's setup-host creates it and `box revoke`
# takes it back, warning that supplementary groups are read at LOGIN so a
# session the user already holds keeps the socket until it dies. rig's old bare
# `gpasswd -d` took the group and said nothing, so an operator watching apply
# succeed believed VM access had ended when it had not.
#
# Both removal paths route through one function, so both are covered by the one
# set of assertions below.
check "users apply: both removal paths route incus through drop_incus" 0 "" \
  test "$(grep -c 'drop_incus "\$' "$ROOT/commands/users-apply.sh")" -eq 2
# Convergence removes access, never someone's running machines: '--purge'
# deletes the user's boxes, images and project, and must stay an explicit admin
# act. Asserted by the SHAPE of the one line that invokes box — a bare revoke
# whose effective state is then checked — rather than by grepping the file for
# '--purge', which the rationale comments and --help text mention on purpose,
# to say where it does belong. The captures below prove the same thing at
# runtime, on every path.
# shellcheck disable=SC2016  # the literal source line is the pattern, unexpanded
check "users apply: the box invocation is a bare revoke" 0 "" \
  grep -qF 'if box revoke "$u" && ! in_group "$u" incus; then' \
    "$ROOT/commands/users-apply.sh"

# drop_incus is exercised, not argued about. users-apply.sh EXECUTES when
# sourced (and dies at the root check), so the function is lifted out of the
# real file verbatim — column-0 'drop_incus() {' through column-0 '}' — and
# driven against stub log/warn/in_group and a stub PATH holding only box,
# gpasswd and pgrep. The extraction is asserted first: if that shape ever
# changes the lift comes back empty and every case below fails loudly rather
# than passing vacuously.
DROP_FN="$(sed -n '/^drop_incus() {/,/^}/p' "$ROOT/commands/users-apply.sh")"
# shellcheck disable=SC2016  # $1 is the inner bash -c's positional, deliberately
check "users apply: drop_incus lifts out of the real file whole" 0 "" \
  bash -c '[ -n "$1" ] && printf %s "$1" | grep -q "^}$"' _ "$DROP_FN"

# The driving shell is named by absolute path: PATH below is REPLACED by the
# stub directory (not prefixed) so that 'absent' means absent even on a host
# that really has box installed — which also puts bash itself out of reach of
# a PATH lookup.
BASH_BIN="$(command -v bash)"
# drive_drop <ok|hollow|fail|absent> — run the real drop_incus against stubs.
# 'ok': box revokes and the membership is gone afterwards. 'hollow': box exits
# 0 and leaves the membership standing (the #12 lesson — an exit code is not
# effective state). 'fail': box exits non-zero. 'absent': no box on the host.
drive_drop() {
  local mode="$1" d
  d="$(mktemp -d)"
  mkdir -p "$d/bin"
  : > "$d/member"                     # 'dan is in incus' — removed when taken
  # The stub reports on STDERR: the real call is 'gpasswd -d ... >/dev/null',
  # so a stub that spoke on stdout would be silenced by the code under test and
  # every fallback assertion below would pass vacuously.
  # Each stub restores a real PATH for itself: the caller's PATH is REPLACED by
  # the stub dir (that is what makes 'absent' mean absent), which would other-
  # wise leave the stubs unable to find 'rm'.
  cat > "$d/bin/gpasswd" <<EOF
#!/bin/sh
PATH=/usr/bin:/bin
echo "CALL: gpasswd \$*" >&2
rm -f "$d/member"
EOF
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$d/bin/pgrep"   # dan holds a session
  if [ "$mode" != absent ]; then
    cat > "$d/bin/box" <<EOF
#!/bin/sh
PATH=/usr/bin:/bin
echo "CALL: box \$*"
case "$mode" in
  ok)     rm -f "$d/member" ;;
  hollow) : ;;
  fail)   exit 1 ;;
esac
EOF
  fi
  chmod +x "$d"/bin/*
  # shellcheck disable=SC2016  # $MEMBER/$* resolve inside the driving shell
  MEMBER="$d/member" PATH="$d/bin" "$BASH_BIN" -c '
    set -euo pipefail
    log()  { printf "rig-users: %s\n" "$*"; }
    warn() { printf "rig-users: WARNING: %s\n" "$*" >&2; }
    in_group() { [ -e "$MEMBER" ]; }
    '"$DROP_FN"'
    drop_incus dan' 2>&1
  rm -rf "$d"
}
DROP_OK="$(drive_drop ok)"
DROP_HOLLOW="$(drive_drop hollow)"
DROP_FAIL="$(drive_drop fail)"
DROP_ABSENT="$(drive_drop absent)"
in_out() { printf '%s' "$1" | grep -qF -e "$2"; }   # in_out <captured> <substr>

# The happy path: box takes its own group back, bare, and rig does not reach
# for gpasswd behind it.
check "drop_incus: calls 'box revoke <user>'" 0 "" in_out "$DROP_OK" "CALL: box revoke dan"
# Bare on EVERY path box is reached on, not just the one that works: a retry
# or a fallback must never escalate to the destructive verb.
check "drop_incus: the box call is bare — no --purge" 1 "" in_out "$DROP_OK" "--purge"
check "drop_incus: a hollow success never retries with --purge" 1 "" in_out "$DROP_HOLLOW" "--purge"
check "drop_incus: a failed revoke never retries with --purge" 1 "" in_out "$DROP_FAIL" "--purge"
check "drop_incus: box's success needs no gpasswd" 1 "" in_out "$DROP_OK" "CALL: gpasswd"
check "drop_incus: names box as the one that revoked" 0 "" in_out "$DROP_OK" "via 'box revoke'"

# Effective state, not exit codes: a revoke that returns 0 with the membership
# still standing has not closed the socket, and apply must not report that it
# has.
check "drop_incus: a hollow box success is caught" 0 "" \
  in_out "$DROP_HOLLOW" "did not remove the incus group"
check "drop_incus: a hollow box success falls back to gpasswd" 0 "" \
  in_out "$DROP_HOLLOW" "CALL: gpasswd -d dan incus"
check "drop_incus: a hollow box success never claims box did it" 1 "" \
  in_out "$DROP_HOLLOW" "via 'box revoke'"
check "drop_incus: a failing box revoke falls back to gpasswd" 0 "" \
  in_out "$DROP_FAIL" "CALL: gpasswd -d dan incus"

# No box on the host: rig takes the group itself and carries box's warning,
# because the silence is the bug — an operator must not read "removed" as
# "their sessions are gone too".
check "drop_incus: no box on PATH still removes the group" 0 "" \
  in_out "$DROP_ABSENT" "CALL: gpasswd -d dan incus"
check "drop_incus: the fallback warns that groups are read at login" 0 "" \
  in_out "$DROP_ABSENT" "group membership is read at login"
check "drop_incus: the fallback hands over the remedy" 0 "" \
  in_out "$DROP_ABSENT" "loginctl terminate-user dan"
# Every fallback path carries it, not just the box-less one.
check "drop_incus: the hollow-success fallback warns too" 0 "" \
  in_out "$DROP_HOLLOW" "loginctl terminate-user dan"
check "drop_incus: the failed-revoke fallback warns too" 0 "" \
  in_out "$DROP_FAIL" "loginctl terminate-user dan"
# box only warns when the user has live processes, and rig mirrors that — but
# an absent pgrep means rig cannot tell, and a wrong belief about who reaches
# the daemon costs more than one unnecessary command. Proven by running the
# fallback with a PATH that has no pgrep at all.
NOPGREP_D="$(mktemp -d)"
mkdir -p "$NOPGREP_D/bin"
printf '%s\n' '#!/bin/sh' 'PATH=/usr/bin:/bin' 'echo "CALL: gpasswd $*" >&2' \
  "rm -f $NOPGREP_D/member" > "$NOPGREP_D/bin/gpasswd"
chmod +x "$NOPGREP_D/bin/gpasswd"
: > "$NOPGREP_D/member"
# shellcheck disable=SC2016  # $MEMBER/$* resolve inside the driving shell
DROP_NOPGREP="$(MEMBER="$NOPGREP_D/member" PATH="$NOPGREP_D/bin" "$BASH_BIN" -c '
  set -euo pipefail
  log()  { printf "rig-users: %s\n" "$*"; }
  warn() { printf "rig-users: WARNING: %s\n" "$*" >&2; }
  in_group() { [ -e "$MEMBER" ]; }
  '"$DROP_FN"'
  drop_incus dan' 2>&1)"
check "drop_incus: an absent pgrep warns rather than guessing" 0 "" \
  in_out "$DROP_NOPGREP" "loginctl terminate-user dan"
rm -rf "$NOPGREP_D"

# --- the box role grants the TIER, not just the socket (#49) -----------------
# Group incus is step 1 of the five 'box grant' performs; without the rest the
# user's first 'box new' refuses for want of a box-net profile. Running the
# real thing needs root, an Incus daemon and real accounts, so these assert the
# CALL and its guard rails in the source — the same way every other root-only
# refusal in this harness is pinned.
# The $-refs below are literals we grep FOR in the script — single quotes
# are the point, as in the bootstrap ordering checks above.
# shellcheck disable=SC2016
check "users apply: box role calls 'box grant', not just usermod" 0 "" \
  grep -qE '^[[:space:]]*box grant "\$u"' "$ROOT/commands/users-apply.sh"
# Ordering is the safety property (repo precedent: bootstrap's marker-then-box
# assert): 'box grant' opens with a getent passwd and refuses an unknown user,
# so the call must come AFTER useradd, never before. Defaults fail closed.
useradd_at="$(grep -nE '^[[:space:]]*useradd -m' "$ROOT/commands/users-apply.sh" | head -n1 | cut -d: -f1)"
# shellcheck disable=SC2016
grant_at="$(grep -nE '^[[:space:]]*box grant "\$u"' "$ROOT/commands/users-apply.sh" | head -n1 | cut -d: -f1)"
check "users apply: 'box grant' runs after useradd (grant refuses unknown users)" \
  0 "" test "${useradd_at:-999999}" -lt "${grant_at:-0}"
# Failure granularity, both halves. A HOST-level fact — box-role users on a
# host=yes box with no box CLI — dies, like the missing-incus-group die beside
# it. A PER-USER grant failure warns and continues, because one box-role user
# somewhere in the fleet must not stop apply everywhere VMs don't live.
check "users apply: a missing box CLI on host=yes is a die, not a warning" 0 "" \
  grep -qF 'die "a user carries role box and this box hosts VMs (host=yes) but the box CLI is not on PATH' \
  "$ROOT/commands/users-apply.sh"
# shellcheck disable=SC2016
check "users apply: a per-user grant failure warns and continues" 0 "" \
  grep -qF 'warn "box grant $u exited $grant_rc:' "$ROOT/commands/users-apply.sh"
# The grant is host=yes only: a tier converged into a daemon that is not there
# to enforce it is not policy. Read the guard's own block — BOX_GRANT=0 up to
# the line that sets it to 1 — rather than the file at large, so a host=yes
# match borrowed from the die above cannot pass this for free.
# shellcheck disable=SC2016  # $1 resolves inside the inner bash -c
check "users apply: the grant is gated on host=yes" 0 "" \
  bash -c 'awk "/^BOX_GRANT=0\$/,/BOX_GRANT=1 ;;/" "$1" | grep -q "[*]host=yes[*])"' \
  _ "$ROOT/commands/users-apply.sh"
# The incus-admin case is blocked on heavy-duty/box#99: grant refuses those
# members today, and rig must NOT turn that refusal into a failed apply. The
# branch names the blocker so whoever reads the warning can find the fix.
# shellcheck disable=SC2016
check "users apply: an incus-admin grant refusal is warned, not fatal" 0 "" \
  grep -q 'elif in_group "$u" incus-admin; then' "$ROOT/commands/users-apply.sh"
check "users apply: the incus-admin warning cites the box-side blocker" 0 "" \
  grep -q "heavy-duty/box#99" "$ROOT/commands/users-apply.sh"
# The group ADD is deferred to grant so a failed grant can take the socket back
# with it (grant only rolls back a membership THAT RUN added). But incus must
# stay in the WANTED set, or the exact-convergence loop's other arm would strip
# a box-role user's socket on the very run that granted it — assert both, since
# either alone is a bug.
# shellcheck disable=SC2016
check "users apply: the incus group add is deferred to 'box grant'" 0 "" \
  grep -qF 'if [ "$g" = incus ] && [ "$BOX_GRANT" -eq 1 ]; then continue; fi' \
  "$ROOT/commands/users-apply.sh"
# The wanted-set arm gained #58's BOX_ROLE_OK gate on rebase, and the two
# conditions answer different questions: BOX_ROLE_OK is "does the box role
# apply on this box at all" (the marker's call), INCUS_OK is "is the group
# there to converge". Both must hold, and `incus` must still ENTER the wanted
# set when they do — otherwise the exact-convergence else-arm below would
# strip a box-role user's socket on the very run that granted it, which is
# the hazard this PR exists to remove. Pinned as the composed line so a
# regression in either operand fails here.
# shellcheck disable=SC2016
check "users apply: role box still puts incus in the wanted set" 0 "" \
  grep -qF 'case ",$roles," in *,box,*) if [ "$BOX_ROLE_OK" -eq 1 ] && [ "$INCUS_OK" -eq 1 ]; then want="$want incus"; fi ;; esac' \
  "$ROOT/commands/users-apply.sh"
# The deferral must be an ADD-side skip only. Landing it on the removal arm
# would leave a de-roled user's socket open forever, so prove the guard sits
# above the usermod -aG and below the wanted-set case, not in the else branch.
# shellcheck disable=SC2016
defer_at="$(grep -nF 'if [ "$g" = incus ] && [ "$BOX_GRANT" -eq 1 ]; then continue; fi' "$ROOT/commands/users-apply.sh" | head -n1 | cut -d: -f1)"
# shellcheck disable=SC2016
strip_at="$(grep -nE '^[[:space:]]*gpasswd -d "\$u" "\$g"' "$ROOT/commands/users-apply.sh" | head -n1 | cut -d: -f1)"
check "users apply: the deferral sits on the add arm, not the removal arm" \
  0 "" test "${defer_at:-999999}" -lt "${strip_at:-0}"
# rig still never installs Incus (the #12/#25 design law, asserted for
# bootstrap above): calling box's grant is invocation, not installation.
check "users apply: never apt-installs incus (box owns the daemon)" 1 "" \
  grep -nE 'apt-get install.* incus' "$ROOT/commands/users-apply.sh"

# --- users close-root: the human-class root-door shutter ---------------------
check "users close-root: --help exits 0"       0 "usage:"       "$ROOT/commands/users-close-root.sh" --help
check "users close-root: unknown flag exits 2" 2 "unknown flag" "$ROOT/commands/users-close-root.sh" --nope
# The whole command rests on first-wins + lexical include order: '-' (0x2D)
# sorts before '.' (0x2E), so 00-rig-users.conf is read before bootstrap's
# 00-rig.conf and its PermitRootLogin wins. Assert the actual comparison the
# glob makes, so a renamed drop-in cannot silently lose the fight.
check "users close-root: drop-in name sorts before bootstrap's" 0 "" \
  bash -c '[ "00-rig-users.conf" \< "00-rig.conf" ]'
check "users close-root: drop-in name is the load-bearing one" 0 "" \
  grep -q "00-rig-users.conf" "$ROOT/commands/users-close-root.sh"
# Validate-then-apply: `sshd -t` on the merged config must precede the restart —
# on a box whose only door is SSH (exactly what this box is about to become),
# bouncing the daemon into a config it refuses to parse leaves no way back in.
# Match the call, not the word (repo precedent: the repo-guard ordering check);
# defaults fail closed.
sshdt_at="$(grep -nE '^[[:space:]]*if ! sshd -t' "$ROOT/commands/users-close-root.sh" | head -n1 | cut -d: -f1)"
restart_at="$(grep -n 'systemctl restart ssh' "$ROOT/commands/users-close-root.sh" | head -n1 | cut -d: -f1)"
check "users close-root: sshd -t precedes the ssh restart" \
  0 "" test "${sshdt_at:-999999}" -lt "${restart_at:-0}"
# Convergence is a claim about the DOOR, not the file. Matching bytes can hide
# an earlier-sorting override (first-wins) or a daemon that died between
# install and restart and never read the file — so the no-op message may only
# be spoken after the effective-config assertion (`sshd -T`), and the no-op
# branch may only be TAKEN when the daemon provably started after the last
# change to sshd's config inputs. Pin both: the assert-before-claim ordering,
# and the daemon-start-vs-config-mtime proof's presence.
efft_at="$(grep -n 'sshd -T' "$ROOT/commands/users-close-root.sh" | grep -v '^[0-9]*:#' | head -n1 | cut -d: -f1)"
noop_at="$(grep -n 'nothing to do' "$ROOT/commands/users-close-root.sh" | tail -n1 | cut -d: -f1)"
check "users close-root: no-op claim sits after the effective-config assert" \
  0 "" test "${efft_at:-999999}" -lt "${noop_at:-0}"
check "users close-root: no-op needs a daemon start newer than the config" 0 "" \
  grep -q "ExecMainStartTimestamp" "$ROOT/commands/users-close-root.sh"
# The admin-door gate must check the StrictModes SHAPE, not file existence: a
# non-empty authorized_keys behind group/world-writable perms is a key sshd
# rejects — closing root behind it welds the only door shut. The full gate
# needs root + real accounts, so grep the load-bearing check's wording.
check "users close-root: gate checks the StrictModes shape" 0 "" \
  grep -q "group/world-writable" "$ROOT/commands/users-close-root.sh"
# The reachability proofs (#17): the shape checks prove the door SHOULD open;
# these prove what can be proven from inside — NOPASSWD sudo actually answers
# (`runuser ... sudo -n true`) and sshd's per-user EFFECTIVE config accepts
# the login (`sshd -T -C user=...`). Both need root, real accounts, and a
# live sshd, so grep the calls — and pin their ordering BEFORE the drop-in
# install, because reachability proven after the door shut is no proof at
# all. Match the calls, not the words (comments mention neither literal);
# defaults fail closed.
# The $a/$TMP/$DROPIN below are LITERALS we grep for in the script — single
# quotes are the point, as in the db and box-install checks.
# shellcheck disable=SC2016
check "users close-root: gate proves NOPASSWD sudo answers" 0 "" \
  grep -qF -- 'runuser -u "$a" -- sudo -n true' "$ROOT/commands/users-close-root.sh"
check "users close-root: gate resolves sshd's per-user config" 0 "" \
  grep -qF -- 'sshd -T -C "user=' "$ROOT/commands/users-close-root.sh"
# shellcheck disable=SC2016
sudon_at="$(grep -nF -- 'runuser -u "$a" -- sudo -n true' "$ROOT/commands/users-close-root.sh" | head -n1 | cut -d: -f1)"
pert_at="$(grep -nF -- 'sshd -T -C "user=' "$ROOT/commands/users-close-root.sh" | head -n1 | cut -d: -f1)"
# shellcheck disable=SC2016
dropin_at="$(grep -nF 'install -m 0644 "$TMP" "$DROPIN"' "$ROOT/commands/users-close-root.sh" | head -n1 | cut -d: -f1)"
check "users close-root: sudo -n proof precedes the drop-in install" \
  0 "" test "${sudon_at:-999999}" -lt "${dropin_at:-0}"
check "users close-root: per-user sshd resolve precedes the drop-in install" \
  0 "" test "${pert_at:-999999}" -lt "${dropin_at:-0}"
# runuser may be absent off-Debian; the gate must skip that one proof loudly,
# never die on a missing prover. Grep the graceful branch.
check "users close-root: a missing runuser skips the sudo proof, loudly" 0 "" \
  grep -q "runuser not found" "$ROOT/commands/users-close-root.sh"
# DenyUsers judged fail-closed through the lib's pure deny_verdict — sshd
# accepts patterns and USER@HOST forms, and 'DenyUsers dan*' REALLY denies
# admin 'dan', so a token the check cannot prove irrelevant must flag, never
# pass (the review's regression: a wildcard denial). Empty output is the only
# pass; every hit names its reason.
deny_v() { # deny_v <user> <token...>
  bash -c 'set -euo pipefail
    . "$1/commands/lib/users-config.sh"; shift
    deny_verdict "$@"' _ "$ROOT" "$@"
}
check "users close-root: deny_verdict flags a literal hit" \
  0 "names this user" deny_v admin root admin
check "users close-root: deny_verdict fails closed on a wildcard (dan* vs dan)" \
  0 "pattern entry 'dan*'" deny_v dan "dan*"
check "users close-root: deny_verdict fails closed on '?' patterns" \
  0 "pattern entry" deny_v admin "admi?"
check "users close-root: deny_verdict fails closed on USER@HOST forms" \
  0 "host-qualified" deny_v admin "admin@10.0.0.1"
deny_pass() { [ -z "$(deny_v "$@")" ]; } # empty verdict IS the pass
check "users close-root: deny_verdict passes provably-irrelevant literals" \
  0 "" deny_pass admin root git backup
# The group directives, same discipline, judged against the candidate's ACTUAL
# membership (the review's regressions: an unmet AllowGroups, a DenyGroups
# naming a group they hold). First arg is the id -Gn word list.
groups_v() { # groups_v <fn> <groups> <token...>
  bash -c 'set -euo pipefail
    . "$1/commands/lib/users-config.sh"; shift
    "$@"' _ "$ROOT" "$@"
}
groups_pass() { [ -z "$(groups_v "$@")" ]; }
check "users close-root: DenyGroups naming a held group flags" \
  0 "a group this user is in" groups_v group_deny_verdict "dan sudo rig-admin" backup sudo
check "users close-root: DenyGroups fails closed on patterns" \
  0 "pattern entry 'rig-*'" groups_v group_deny_verdict "dan rig-admin" "rig-*"
check "users close-root: DenyGroups passes provably-irrelevant literals" \
  0 "" groups_pass group_deny_verdict "dan rig-admin" docker backup
check "users close-root: an unmet AllowGroups flags (fail closed)" \
  0 "no entry literally names a group this user is in" groups_v group_allow_verdict "dan rig-admin" sudo
check "users close-root: AllowGroups pattern is no proof (fail closed)" \
  0 "no entry literally names" groups_v group_allow_verdict "dan rig-admin" "rig-*"
check "users close-root: a literally-named held group passes AllowGroups" \
  0 "" groups_pass group_allow_verdict "dan rig-admin" sudo rig-admin
# ...and the shipped gate consults both, against real membership.
# shellcheck disable=SC2016
check "users close-root: the gate consults the group verdicts" 0 "" \
  grep -qE '^[[:space:]]*denyg_reason="\$\(group_deny_verdict ' "$ROOT/commands/users-close-root.sh"
# shellcheck disable=SC2016
check "users close-root: the gate resolves real membership (id -Gn)" 0 "" \
  grep -qF -- 'id -Gn -- "$a"' "$ROOT/commands/users-close-root.sh"
# ...and the shipped gate must actually consult it (call, not comment).
# shellcheck disable=SC2016
check "users close-root: the gate consults deny_verdict" 0 "" \
  grep -qE '^[[:space:]]*deny_reason="\$\(deny_verdict ' "$ROOT/commands/users-close-root.sh"
# Marker-gate refusals through the sourced lib against fixture markers: the CLI
# path sits behind the root check, so the gate is a pure lib function on
# purpose (repo precedent: parse_users_file, assert_runner_repo). The command
# reads the marker path from RIG_ROLE_MARKER for the same reason — so the gate
# stays pointable at fixtures.
marker_gate() { # marker_gate <marker_path>
  bash -c 'set -euo pipefail
    . "$1/commands/lib/users-config.sh"
    assert_marker_closes_root "$2"' _ "$ROOT" "$1"
}
MARKER_DIR="$(mktemp -d)"
printf 'role=workload-server root-door=open host=no join=authkey\n'   > "$MARKER_DIR/open"
printf 'role=dev-server root-door=closed host=yes join=authkey\n'     > "$MARKER_DIR/closed"
check "users close-root: absent marker refuses, names bootstrap as the repair" \
  1 "no /etc/rig/role marker" marker_gate "$MARKER_DIR/absent"
check "users close-root: root-door=open refuses, names the control plane" \
  1 "control plane" marker_gate "$MARKER_DIR/open"
# #17's original table let the runner ROLE close root; the trait model
# supersedes it — runner is root-door=open, an automation identity, and the
# refusal must SAY so or the divergence reads as a bug to anyone holding the
# old table.
check "users close-root: the open-door refusal owns the runner row (#17)" \
  1 "runner included" marker_gate "$MARKER_DIR/open"
check "users close-root: root-door=closed passes the gate" \
  0 "" marker_gate "$MARKER_DIR/closed"

# --- the pre-#77 vocabulary, on live markers (#77) ---------------------------
# THIS is the block that makes #77 safe to ship, and it is not a formality.
# Unlike #76's role rename, the root-door trait is written into /etc/rig/role
# and read BACK by this gate, so every box bootstrapped before the rename
# carries `class=human|server` and carries it until someone re-bootstraps it —
# which, for a fleet, is never. A gate that stopped understanding that spelling
# would fail in both directions and both are incidents: `class=human` boxes
# (whose whole point is that root closes) would lose the ability to close it,
# and `class=server` boxes would... also refuse, but for the wrong reason,
# which is luck rather than design and would evaporate the moment the fallthrough
# arm changed.
#
# So the fixtures below stay DELIBERATELY at the retired spelling, byte for
# byte as a real pre-#77 box's marker reads — the same reason #76's
# `pre-rename-cp` fixture keeps `role=control-plane`. Do not "modernize" them:
# updating these fixtures to the new vocabulary would delete the only evidence
# that the compat read works, and the suite would stay green while the field
# broke. The pairs assert the OLD spelling produces the SAME verdict as its new
# equivalent above, refusal text included.
printf 'role=workload-server class=server host=no join=authkey\n'     > "$MARKER_DIR/pre77-server"
printf 'role=dev-server class=human host=yes join=authkey\n'          > "$MARKER_DIR/pre77-human"
check "users close-root: a PRE-#77 'class=human' marker still passes the gate" \
  0 "" marker_gate "$MARKER_DIR/pre77-human"
check "users close-root: a PRE-#77 'class=server' marker still REFUSES" \
  1 "control plane" marker_gate "$MARKER_DIR/pre77-server"
# The refusal an old box gets must be the CURRENT one, naming the current flag:
# an operator repairing a pre-#77 box is repairing it with today's rig, and
# being told to pass a flag that no longer exists is a dead end.
check "users close-root: the PRE-#77 refusal names today's flag, not --class" \
  1 "root-door closed" marker_gate "$MARKER_DIR/pre77-server"

# A marker naming NEITHER vocabulary refuses — unchanged from before #77, and
# distinct from an absent marker: the file exists and simply makes no claim
# about the door, which cannot authorize shutting one.
printf 'role=workload-server host=no join=authkey\n'                  > "$MARKER_DIR/doorless"
check "users close-root: a marker naming no door policy refuses" \
  1 "names no root-door policy" marker_gate "$MARKER_DIR/doorless"
# A marker naming a root-door= value outside the value set is doorless too —
# fail closed rather than guessing which door 'potato' means.
printf 'role=custom root-door=potato host=no join=login\n'            > "$MARKER_DIR/bogus"
check "users close-root: an unreadable root-door value refuses (fail closed)" \
  1 "names no root-door policy" marker_gate "$MARKER_DIR/bogus"

# BOTH vocabularies on one marker. Agreement is just the same claim twice and
# resolves normally; DISAGREEMENT is a hand-edited marker making two equally
# authored claims about a root door, and rig refuses to pick a winner — the
# fail-closed arm, since the alternative is guessing on the one field that
# decides whether a door welds shut. Both orders are checked so the verdict
# cannot depend on which field the editor happened to type first.
printf 'role=dev-server root-door=closed class=human host=yes join=authkey\n' > "$MARKER_DIR/both-agree"
check "users close-root: both vocabularies agreeing resolves normally" \
  0 "" marker_gate "$MARKER_DIR/both-agree"
printf 'role=custom root-door=closed class=server host=no join=login\n'  > "$MARKER_DIR/both-fight-a"
printf 'role=custom class=human root-door=open host=no join=login\n'     > "$MARKER_DIR/both-fight-b"
check "users close-root: contradictory vocabularies refuse (new-first)" \
  1 "will not pick a winner" marker_gate "$MARKER_DIR/both-fight-a"
check "users close-root: contradictory vocabularies refuse (old-first)" \
  1 "will not pick a winner" marker_gate "$MARKER_DIR/both-fight-b"
rm -rf "$MARKER_DIR"

# root_door_of is the ONE reader of this trait — close-root's gate, apply's
# note and bootstrap-tenant's machine-marker detector all resolve through it,
# so the compat read cannot drift between them. Pin the resolver directly,
# text->text, the way deny_verdict and group_allow_verdict are pinned.
door_of() { # door_of <marker line>
  bash -c 'set -euo pipefail
    . "$1/commands/lib/users-config.sh"
    printf "[%s]" "$(root_door_of "$2")"' _ "$ROOT" "$1"
}
check "root_door_of: reads the current vocabulary" 0 "[closed]" \
  door_of 'role=dev-server root-door=closed host=yes join=authkey'
check "root_door_of: reads the pre-#77 class=human as closed" 0 "[closed]" \
  door_of 'role=dev-server class=human host=yes join=authkey'
check "root_door_of: reads the pre-#77 class=server as open" 0 "[open]" \
  door_of 'role=workload-server class=server host=no join=authkey'
check "root_door_of: a tenant marker names no door at all" 0 "[]" \
  door_of 'role=claude-box tenant=yes host=no'
check "root_door_of: disagreement is a conflict, not a coin flip" 0 "[conflict]" \
  door_of 'role=custom root-door=open class=human host=no join=login'
# FIELD-ANCHORED, not substring (found in review on #77). A value that EXTENDS
# a real one must resolve EMPTY and fail closed, exactly as the function's
# header promises — before anchoring, `closedish` read as `closed` and PERMITTED
# close-root, the one arm that authorizes an irreversible act. Both vocabularies
# are checked: the compat arm had the identical hole, and a fix that anchored
# only the current spelling would leave every pre-#77 box exposed to it.
check "root_door_of: a value EXTENDING the current spelling resolves empty" 0 "[]" \
  door_of 'role=x root-door=closedish host=no'
check "root_door_of: a value extending the pre-#77 spelling resolves empty too" 0 "[]" \
  door_of 'role=x class=humanoid host=no'
check "root_door_of: a value PREFIXED by junk does not match either" 0 "[]" \
  door_of 'role=x notroot-door=closed host=no'
# ...and the gate itself must refuse on those, not merely resolve empty: the
# resolver returning "" is only safe because every consumer treats it as a
# refusal, so the end-to-end behaviour is what gets pinned.
DOOR_FIX="$(mktemp -d)"
printf 'role=x root-door=closedish host=no\n' > "$DOOR_FIX/bogus"
# shellcheck disable=SC2016  # $1/$2 are the inner shell's positionals, not ours
check "close-root: refuses a marker whose door value merely LOOKS closed" 1 "names no root-door policy" \
  bash -c '. "$1/commands/lib/users-config.sh"; assert_marker_closes_root "$2"' _ "$ROOT" "$DOOR_FIX/bogus"
# Whitespace normalisation: a hand-edit using tabs is still a real marker and
# must read the same, or anchoring would trade one silent misread for another.
check "root_door_of: tab-separated fields read the same as space-separated" 0 "[closed]" \
  door_of "$(printf 'role=x\troot-door=closed\thost=no')"
rm -rf "$DOOR_FIX"
if [ "$(id -u)" -ne 0 ]; then
  check "users close-root: refuses non-root" 1 "must run as root" "$ROOT/commands/users-close-root.sh"
else
  echo "skip: users close-root non-root refusal (running as root)"
fi
# Bootstrap must read the closed door as hardened, not broken: `no` is the
# post-close-root state, strictly harder than what bootstrap installs. Byte-grep
# the widened assertion so a revert cannot ship green. The hardening block
# lives in lib/sshd.sh since #31 — ONE converger shared by the machine roles
# and the staging-box tenant — so the greps pin the lib, and a call-site grep pins
# that bootstrap actually runs it (a function nobody calls is not hardening).
check "sshd lib: permitrootlogin assertion accepts the closed state" 0 "" \
  grep -qF "permitrootlogin (no|prohibit-password|without-password)" "$ROOT/commands/lib/sshd.sh"
# ...but only for root-door=closed. On root-door=open a closed root door is a
# BROKEN box — root SSH is the control plane's automation door — and the usual
# cause is a 00-rig-users.conf left over from a former closed-door life. The refusal
# must name that drop-in or the operator greps sshd configs blind; the path
# needs root + a doctored sshd, so grep the die message (repo precedent above).
check "sshd lib: root-door=open refusal names the stale close-root drop-in" 0 "" \
  grep -q "leftover /etc/ssh/sshd_config.d/00-rig-users.conf" "$ROOT/commands/lib/sshd.sh"
# Validate-then-apply survived the extraction: sshd -t on the merged config
# must still precede the restart (same idiom as the close-root ordering check).
libt_at="$(grep -nE '^[[:space:]]*if ! sshd -t' "$ROOT/commands/lib/sshd.sh" | head -n1 | cut -d: -f1)"
librestart_at="$(grep -nE '^[[:space:]]*systemctl restart ssh$' "$ROOT/commands/lib/sshd.sh" | head -n1 | cut -d: -f1)"
check "sshd lib: sshd -t precedes the ssh restart" \
  0 "" test "${libt_at:-999999}" -lt "${librestart_at:-0}"
# shellcheck disable=SC2016
check "bootstrap: hardening runs through the shared lib" 0 "" \
  grep -qE '^harden_sshd "\$ROOT_DOOR"$' "$ROOT/commands/bootstrap.sh"

# The dump script ships to control-plane boxes as an embedded heredoc. A syntax
# error in it would be invisible here and would first surface at 04:00 on a live
# control plane. Extract it and syntax-check what actually gets written.
DUMP_TMP="$(mktemp)"
sed -n "/<<'DUMP_SCRIPT'/,/^DUMP_SCRIPT\$/p" "$ROOT/commands/coolify-backup-install.sh" \
  | sed '1d;$d' > "$DUMP_TMP"
check "embedded dump script extracted (guards the sed above)" 0 "" grep -q "pg_dump" "$DUMP_TMP"
check "embedded dump script is valid bash"    0 ""        bash -n "$DUMP_TMP"
check "embedded dump script rejects a bare bucket name" 1 "must be an s3:// URI" \
  env AGE_RECIPIENT=age1x S3_BUCKET=my-bucket S3_ENDPOINT=https://s3.example.com bash "$DUMP_TMP"
check "embedded dump script rejects a schemeless endpoint" 1 "needs a scheme" \
  env AGE_RECIPIENT=age1x S3_BUCKET=s3://b/k S3_ENDPOINT=s3.example.com bash "$DUMP_TMP"
rm -f "$DUMP_TMP"

# Regression: /etc/os-release defines VERSION (e.g. "13 (trixie)" on Debian);
# sourcing it in the main shell clobbers a script's $VERSION and splices the
# OS string into download URLs. It must only ever be sourced in a subshell.
check "no main-shell os-release sourcing" 1 "" \
  grep -rnE '^[[:space:]]*\.[[:space:]]+/etc/os-release' "$ROOT/commands"

# ---------------------------------------------------------------------------
# The versioned install (box#79's layout, ported — #35). RIG_INSTALL_SOURCE
# bypasses the network, so these are REAL runs of install.sh against throwaway
# RIG_HOME/RIG_BIN roots — layout, symlink chain, flat-tree migration, symlink
# healing, use and uninstall are all DRIVEN, not grepped. The bootstrapped-host
# flip gate (rig's analog of box's #66 refusal: WARN, never refuse) is driven
# too, through RIG_ROLE_MARKER fixtures — no root, no network, no real marker.
# ---------------------------------------------------------------------------
check "install.sh is valid bash" 0 "" bash -n "$ROOT/install.sh"
VER="$(cat "$ROOT/VERSION")"
check "--version answers the tree's own VERSION" 0 "rig $VER" "$ROOT/bin/rig" --version
check "-V is --version" 0 "rig $VER" "$ROOT/bin/rig" -V
check "help lists the versioned verbs" 0 "uninstall" "$ROOT/bin/rig" --help

WORK="$(mktemp -d)"
FAKEHOME="$WORK/home"; mkdir -p "$FAKEHOME"

# A fabricated "newer release": the same CLI, a different VERSION — what an
# upgrade actually is, from the installer's point of view.
SRC9="$WORK/src-9.9.9"; mkdir -p "$SRC9/bin"
cp "$ROOT/bin/rig" "$SRC9/bin/rig"; chmod +x "$SRC9/bin/rig"
echo "9.9.9-drill" > "$SRC9/VERSION"
SRC8="$WORK/src-8.8.8"; mkdir -p "$SRC8/bin"
cp "$ROOT/bin/rig" "$SRC8/bin/rig"; chmod +x "$SRC8/bin/rig"
echo "8.8.8-drill" > "$SRC8/VERSION"

inst() {  # inst <rig_home> <rig_bin> [VAR=val ...] — run install.sh for real
  local h="$1" b="$2"; shift 2
  env HOME="$FAKEHOME" RIG_ROLE_MARKER="$WORK/no-marker" \
      RIG_HOME="$h" RIG_BIN="$b" \
      RIG_INSTALL_SOURCE="$ROOT" "$@" bash "$ROOT/install.sh"
}
irig() {  # irig [VAR=val ...] <cmd...> — run an installed rig, marker-free
  env HOME="$FAKEHOME" RIG_ROLE_MARKER="$WORK/no-marker" "$@"
}

# --- fresh install: the layout and the chain --------------------------------
H1="$WORK/h1"; B1="$WORK/b1"
check "install: a fresh install runs clean" 0 "done" inst "$H1" "$B1"
check "install: the tree lands in versions/<v>" 0 "" test -x "$H1/versions/$VER/bin/rig"
check "install: 'current' points at versions/<v>" 0 "versions/$VER" readlink "$H1/current"
check "install: the PATH symlink rides the chain" 0 "$H1/current/bin/rig" readlink "$B1/rig"
check "install: rig --version answers through the whole chain" 0 "rig $VER" irig "$B1/rig" --version
check "install: INSTALLED_FROM records the local source" 0 "local:" cat "$H1/versions/$VER/INSTALLED_FROM"

# --- rig#39: no $HOME in the environment (cloud-init's runcmd) ---------------
# The box#88 seed runs install.sh from runcmd, which carries NO $HOME; under
# set -u the first $HOME expansion was a death instead of an install. The
# installer now derives a home from getent — driven here with a shim getent
# so the derived home is a throwaway root, and proven fatal-BY-NAME when
# getent has no answer either (never a bare unbound-variable stack).
GESHIM="$WORK/geshim"; GEHOME="$WORK/gehome"; mkdir -p "$GESHIM" "$GEHOME"
printf '#!/bin/sh\necho "u:x:0:0::%s:/bin/sh"\n' "$GEHOME" > "$GESHIM/getent"
chmod +x "$GESHIM/getent"
check "install: no \$HOME derives one from getent (rig#39)" 0 "done" \
  env -u HOME PATH="$GESHIM:$PATH" RIG_ROLE_MARKER="$WORK/no-marker" \
      RIG_INSTALL_SOURCE="$ROOT" bash "$ROOT/install.sh"
check "install: ...and the tree landed under the derived home" 0 "" \
  test -x "$GEHOME/.local/share/rig/versions/$VER/bin/rig"
printf '#!/bin/sh\nexit 2\n' > "$GESHIM/getent"
check "install: no \$HOME and no getent answer refuses by name" 1 "set HOME and re-run" \
  env -u HOME PATH="$GESHIM:$PATH" RIG_ROLE_MARKER="$WORK/no-marker" \
      RIG_INSTALL_SOURCE="$ROOT" bash "$ROOT/install.sh"

# --- converge, don't clobber ------------------------------------------------
touch "$H1/versions/$VER/CANARY"
check "install: a same-version re-run is a no-op that says so" 0 "already installed" inst "$H1" "$B1"
check "install: the no-op left the tree untouched" 0 "" test -e "$H1/versions/$VER/CANARY"
check "install: RIG_REINSTALL=1 replaces that version's tree" 0 "reinstalled" inst "$H1" "$B1" RIG_REINSTALL=1
check "install: the reinstall really replaced it (canary gone)" 1 "" test -e "$H1/versions/$VER/CANARY"

# --- a second version: side-by-side, and the flip ---------------------------
check "install: a second version installs side-by-side" 0 "" inst "$H1" "$B1" RIG_INSTALL_SOURCE="$SRC9"
check "install: ...into its own versions dir" 0 "" test -x "$H1/versions/9.9.9-drill/bin/rig"
check "install: ...and the old version stays" 0 "" test -d "$H1/versions/$VER"
check "install: the default flips to the new version" 0 "rig 9.9.9-drill" irig "$B1/rig" --version

# --- rig versions -----------------------------------------------------------
check "versions: lists the installed versions" 0 "$VER" irig "$B1/rig" versions
check "versions: marks the current default" 0 "(current)" irig "$B1/rig" versions
check "versions: marks the running one" 0 "(running)" irig "$B1/rig" versions

# --- rig use ----------------------------------------------------------------
check "use: no argument is a usage error" 2 "use needs a version" irig "$B1/rig" use
check "use: an unknown version is refused by name" 1 "no such version" irig "$B1/rig" use 1.2.3
# A version is a directory NAME — a crafted one must die at the gate, never
# reach the ln (current pointing outside the root) or an rm -rf.
check "use: a path-traversal version dies at the gate" 1 "not a sane version name" \
  irig "$B1/rig" use '../../tmp/evil'
check "use: flips the default" 0 "switched to $VER" irig "$B1/rig" use "$VER"
check "use: the flip is effective through the PATH chain" 0 "rig $VER" irig "$B1/rig" --version
check "install: an installed-but-not-current version is a no-op too" 0 "already installed" \
  inst "$H1" "$B1" RIG_INSTALL_SOURCE="$SRC9"
check "install: ...and does not move the default" 0 "rig $VER" irig "$B1/rig" --version

# --- the flip gate: a bootstrapped host WARNS, never refuses (#35) ----------
# box refuses version flips under existing boxes; rig's stake is the converged
# host itself — /etc/rig/role. The deliberate decision: warn and proceed.
# Driven against a fixture marker; counting fires proves silence too.
MARK="$WORK/role-marker"
printf 'role=workload-server root-door=open host=no join=authkey\n' > "$MARK"
H2="$WORK/h2"; B2="$WORK/b2"
check "flip gate: baseline install" 0 "done" inst "$H2" "$B2"
check "flip gate: an upgrade on a bootstrapped host WARNS" 0 "this host is bootstrapped" \
  inst "$H2" "$B2" RIG_INSTALL_SOURCE="$SRC9" RIG_ROLE_MARKER="$MARK"
check "flip gate: ...and still flips (warn, not refuse)" 0 "rig 9.9.9-drill" irig "$B2/rig" --version
check "flip gate: 'rig use' on a bootstrapped host WARNS" 0 "this host is bootstrapped" \
  irig RIG_ROLE_MARKER="$MARK" "$B2/rig" use "$VER"
check "flip gate: ...and still flips" 0 "rig $VER" irig "$B2/rig" --version
# Silence when no marker: warning every un-bootstrapped host would train
# operators to ignore it.
flip_warns() { # flip_warns <cmd...> — how many bootstrapped warnings fired
  "$@" 2>&1 | grep -c "this host is bootstrapped" || true
}
check "flip gate: no marker, no warning (installer)" 0 "0" \
  flip_warns inst "$H2" "$B2" RIG_INSTALL_SOURCE="$SRC9"
check "flip gate: no marker, no warning (rig use)" 0 "0" \
  flip_warns irig "$B2/rig" use "$VER"
check "flip gate: a fresh install never warns (nothing changes under the host)" 0 "0" \
  flip_warns inst "$WORK/h2f" "$WORK/b2f" RIG_ROLE_MARKER="$MARK"

# --- migration: a flat pre-versioning tree becomes a versioned one ----------
H3="$WORK/h3"; B3="$WORK/b3"; mkdir -p "$H3/bin" "$B3"
cp "$ROOT/bin/rig" "$H3/bin/rig"; chmod +x "$H3/bin/rig"
cp "$ROOT/VERSION" "$H3/VERSION"
echo "test@flat" > "$H3/INSTALLED_FROM"
ln -s "$H3/bin/rig" "$B3/rig"
check "migrate: a flat tree is moved into versions/" 0 "migrating" inst "$H3" "$B3"
check "migrate: the OPERATOR'S tree moved (not a fresh copy)" 0 "test@flat" \
  cat "$H3/versions/$VER/INSTALLED_FROM"
check "migrate: nothing flat remains at the root" 1 "" test -e "$H3/bin"
check "migrate: current points at the migrated version" 0 "versions/$VER" readlink "$H3/current"
check "migrate: the PATH symlink was re-pointed through current" 0 "$H3/current/bin/rig" readlink "$B3/rig"
check "migrate: the migrated install answers --version" 0 "rig $VER" irig "$B3/rig" --version

# ...and the seamless upgrade every REAL flat rig install takes: no VERSION
# file at all (pre-rig#32), so it migrates as 0.0.0-unknown and the new
# version lands beside it and becomes the default.
H4="$WORK/h4"; B4="$WORK/b4"; mkdir -p "$H4/bin" "$B4"
cp "$ROOT/bin/rig" "$H4/bin/rig"; chmod +x "$H4/bin/rig"
ln -s "$H4/bin/rig" "$B4/rig"
check "migrate: a VERSION-less flat tree migrates as 0.0.0-unknown" 0 "0.0.0-unknown" \
  inst "$H4" "$B4" RIG_INSTALL_SOURCE="$SRC9"
check "migrate+upgrade: both versions present" 0 "" \
  bash -c "[ -d '$H4/versions/0.0.0-unknown' ] && [ -d '$H4/versions/9.9.9-drill' ]"
check "migrate+upgrade: the new version is the default" 0 "rig 9.9.9-drill" \
  irig "$B4/rig" --version

# A broken current must halt the single-version uninstall BEFORE any decision:
# the CURRENT guard keys off what current resolves to, and a dangling link
# makes that answer a lie. Drive the version tree's own binary — the current
# chain is exactly what is broken. Heal current afterwards.
ln -sfn "versions/gone" "$H4/current"
check "uninstall: refuses while current is dangling (heal before delete)" 1 "dangling" \
  irig "$H4/versions/9.9.9-drill/bin/rig" uninstall 0.0.0-unknown --force
check "uninstall: ...and both version trees survived the refusal" 0 "" \
  bash -c "[ -d '$H4/versions/0.0.0-unknown' ] && [ -d '$H4/versions/9.9.9-drill' ]"
ln -sfn "versions/9.9.9-drill" "$H4/current"

# The migration reads VERSION off the old tree — disk data, not installer
# data. A hostile value must refuse BEFORE the tree moves anywhere.
H9="$WORK/h9"; B9="$WORK/b9"; mkdir -p "$H9/bin" "$B9"
cp "$ROOT/bin/rig" "$H9/bin/rig"; chmod +x "$H9/bin/rig"
printf '%s\n' '../pwn' > "$H9/VERSION"
check "migrate: a hostile flat VERSION refuses to migrate" 1 "not a sane directory name" \
  inst "$H9" "$B9"
check "migrate: ...with the flat tree untouched where it was" 0 "" test -x "$H9/bin/rig"

# --- healing: a wedged $BINDIR/rig must never block an install --------------
H5="$WORK/h5"; B5="$WORK/b5"; mkdir -p "$B5"
ln -s "$WORK/nowhere/rig" "$B5/rig"                    # dangling
check "heal: a DANGLING \$BINDIR/rig does not wedge the install" 0 "done" inst "$H5" "$B5"
check "heal: ...and got repointed" 0 "rig $VER" irig "$B5/rig" --version
H6="$WORK/h6"; B6="$WORK/b6"; mkdir -p "$B6"
ln -s /bin/true "$B6/rig"                              # stale, but resolvable
check "heal: a STALE \$BINDIR/rig with no tree does not fake 'installed'" 0 "installing $VER" \
  inst "$H6" "$B6"
check "heal: ...the install is real and answers" 0 "rig $VER" irig "$B6/rig" --version

# --- rig uninstall: one version ---------------------------------------------
check "uninstall: refuses to remove the CURRENT version" 1 "CURRENT" \
  irig "$B1/rig" uninstall "$VER" --force
check "uninstall: an unknown version is refused by name" 1 "no such version" \
  irig "$B1/rig" uninstall 5.5.5 --force
check "uninstall: a path-traversal version dies at the gate (never an rm -rf)" 1 "not a sane version name" \
  irig "$B1/rig" uninstall '../../../../etc' --force
check "uninstall: a version plus --all is ambiguous (usage error)" 2 "ambiguous" \
  irig "$B1/rig" uninstall 9.9.9-drill --all --force
check "uninstall: an unknown flag is refused" 2 "unknown option" \
  irig "$B1/rig" uninstall --nope
check "uninstall: removes a non-current version" 0 "removed version" \
  irig "$B1/rig" uninstall 9.9.9-drill --force
check "uninstall: that version dir is gone" 1 "" test -e "$H1/versions/9.9.9-drill"
check "uninstall: the current version still answers" 0 "rig $VER" irig "$B1/rig" --version

# --- rig uninstall: everything ----------------------------------------------
check "uninstall: refuses without --force when no terminal" 2 "refusing" \
  irig bash -c "'$B1/rig' uninstall --all </dev/null"
check "uninstall --all: warns on a bootstrapped host (never refuses)" 0 "this host is bootstrapped" \
  irig RIG_ROLE_MARKER="$MARK" "$B1/rig" uninstall --all --force
check "uninstall --all: removed the whole install" 0 "" bash -c "
  [ ! -e '$H1' ] && [ ! -L '$H1' ] &&
  [ ! -e '$B1/rig' ] && [ ! -L '$B1/rig' ]"
# ...and RIG_YES=1 is the installer-family consent (no --force, no tty).
check "uninstall --all: RIG_YES=1 is consent without a terminal" 0 "uninstalled" \
  irig bash -c "RIG_YES=1 '$B2/rig' uninstall --all </dev/null"
check "uninstall --all: ZERO residue — root and symlinks" 0 "" bash -c "
  [ ! -e '$H2' ] && [ ! -L '$H2' ] &&
  [ ! -e '$B2/rig' ] && [ ! -L '$B2/rig' ]"
# The last word is a re-check: a survivor must turn into a loud INCOMPLETE,
# never a cheerful "uninstalled". (Root ignores file modes, so this drill is
# meaningful — and runnable — for a non-root runner only.)
if [ "$(id -u)" -ne 0 ]; then
  H7="$WORK/h7"; B7="$WORK/b7"
  inst "$H7" "$B7" >/dev/null 2>&1
  mkdir -p "$H7/versions/$VER/stuck"; touch "$H7/versions/$VER/stuck/pin"
  chmod 555 "$H7/versions/$VER/stuck"
  check "uninstall: a survivor makes it scream INCOMPLETE (exit 1)" 1 "INCOMPLETE" \
    irig "$B7/rig" uninstall --all --force
  chmod -R u+w "$H7" 2>/dev/null
else
  echo "skip: uninstall INCOMPLETE drill (root ignores file modes)"
fi

# --- the versioned verbs from a working tree: refuse, don't guess -----------
check "uninstall: refuses from a working tree" 1 "not a versioned install" "$ROOT/bin/rig" uninstall --all --force
check "versions: refuses from a working tree" 1 "not a versioned install" "$ROOT/bin/rig" versions
check "use: refuses from a working tree" 1 "not a versioned install" "$ROOT/bin/rig" use 1.0.0

# The version-name gate must be ONE decision: install.sh and bin/rig carry
# byte-identical copies (the installer runs before any tree exists), and a
# drifted copy is two gates pretending to be one — a version install.sh would
# refuse must not be one 'rig use' accepts.
VVBIN="$(mktemp)"; VVINST="$(mktemp)"
awk '/^valid_version\(\) \{/,/^\}/' "$ROOT/bin/rig"     > "$VVBIN"
awk '/^valid_version\(\) \{/,/^\}/' "$ROOT/install.sh"  > "$VVINST"
check "valid_version: extracted from bin/rig (guards the awk)" 0 "A-Za-z0-9" cat "$VVBIN"
check "valid_version: bin/rig and install.sh copies are byte-identical" 0 "" diff "$VVBIN" "$VVINST"
rm -f "$VVBIN" "$VVINST"
# Same discipline for the flip gate: one bootstrapped-host stance, two copies.
WBBIN="$(mktemp)"; WBINST="$(mktemp)"
awk '/^warn_bootstrapped\(\) \{/,/^\}/' "$ROOT/bin/rig"     > "$WBBIN"
awk '/^warn_bootstrapped\(\) \{/,/^\}/' "$ROOT/install.sh"  > "$WBINST"
check "warn_bootstrapped: extracted from bin/rig (guards the awk)" 0 "RIG_ROLE_MARKER" cat "$WBBIN"
check "warn_bootstrapped: bin/rig and install.sh copies are byte-identical" 0 "" diff "$WBBIN" "$WBINST"
rm -f "$WBBIN" "$WBINST"

rm -rf "$WORK"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
