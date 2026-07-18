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
check "bootstrap: unknown flag exits 2"    2 "unknown flag"   "$ROOT/commands/bootstrap.sh" workload --nope
check "bootstrap: hostname needs value"    2 "needs a value"  "$ROOT/commands/bootstrap.sh" workload --hostname
# --ts-tag is REMOVED, not demoted: the tag now comes from the pre-auth key and
# rig verifies the GRANTED tag after join. The old runner-refuses-tag:server test
# asserted the request-time refusal THROUGH this flag; that policy now lives on
# the EFFECTIVE tag and needs a real tailnet, so it belongs to the rehearsal, not
# here. What this harness CAN prove is that the flag dies with a message pointing
# at the key (exit 2, a usage error), rather than an "unknown flag" that would
# leave an operator guessing where the tag went — value present or absent.
check "bootstrap: --ts-tag is removed (with value), exit 2" 2 "comes from the pre-auth key" \
  "$ROOT/commands/bootstrap.sh" runner --ts-tag tag:server
check "bootstrap: --ts-tag is removed (no value), exit 2"   2 "comes from the pre-auth key" \
  "$ROOT/commands/bootstrap.sh" runner --ts-tag
check "bootstrap: staging + removed --ts-tag exits 2" 2 "comes from the pre-auth key" \
  "$ROOT/commands/bootstrap.sh" staging --ts-tag tag:server
# The staging tag:server refusal rides the EFFECTIVE tag, inside
# verify_effective_tag — a path that needs a real tailnet, so it belongs to the
# rehearsal. What the harness CAN prove is that the refusal exists in the
# shipped script: grep the die message, so a deleted guard cannot ship green
# (the same reason the runner-install repo guard is grepped below).
check "bootstrap: staging effective-tag refusal is present" 0 "" \
  grep -q "role staging joined with tag:server" "$ROOT/commands/bootstrap.sh"
# --- traits: roles are presets, every trait individually settable (#26) -----
check "bootstrap: unknown role still exits 2"    2 "unknown role" "$ROOT/commands/bootstrap.sh" potato
check "bootstrap: bad --class value exits 2"     2 "human|server" "$ROOT/commands/bootstrap.sh" workload --class potato
check "bootstrap: bad --host value exits 2"      2 "yes|no"       "$ROOT/commands/bootstrap.sh" workload --host maybe
check "bootstrap: bad --join value exits 2"      2 "authkey|login" "$ROOT/commands/bootstrap.sh" workload --join carrier-pigeon
check "bootstrap: custom without --hostname exits 2" 2 "--hostname" \
  "$ROOT/commands/bootstrap.sh" custom --class server --host no --join authkey
check "bootstrap: custom without traits exits 2" 2 "--class" "$ROOT/commands/bootstrap.sh" custom --hostname box1
# workstation is join=login by preset: a set TS_AUTHKEY is a usage error, and it
# must die BEFORE the root check — provable non-root, which also proves the
# preset actually landed.
check "bootstrap: workstation + TS_AUTHKEY exits 2" 2 "unset TS_AUTHKEY" \
  env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" workstation
# A trait override changes derived behavior, provable non-root: dev is
# join=authkey (TS_AUTHKEY fine → falls through to the root check), but
# --join login flips it into the TS_AUTHKEY refusal.
check "bootstrap: dev --join login + TS_AUTHKEY exits 2" 2 "unset TS_AUTHKEY" \
  env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" dev --join login
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
# --- host-class box install (issues #12, #25) --------------------------------
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
# --- README: the box rename (#12) --------------------------------------------
# The philosophy line must point at heavy-duty/box — the old claudebox slug
# only works through a GitHub redirect that one squatted rename away from
# breaking (box's own installer was already bitten by the rename once). A
# negative grep (exit 1 = pass) keeps the stale slug from creeping back.
check "README: no stale heavy-duty/claudebox links" 1 "" \
  grep -n "heavy-duty/claudebox" "$ROOT/README.md"
check "README: points at heavy-duty/box" 0 "" \
  grep -q "github.com/heavy-duty/box" "$ROOT/README.md"
if [ "$(id -u)" -ne 0 ]; then
  check "bootstrap: refuses non-root"      1 "must run as root" env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" workload
  check "bootstrap: runner role parses, refuses non-root" 1 "must run as root" env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" runner
  check "bootstrap: staging role parses, refuses non-root" 1 "must run as root" env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" staging
  check "bootstrap: dev role parses, refuses non-root" 1 "must run as root" env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" dev
  check "bootstrap: workstation parses, refuses non-root" 1 "must run as root" env -u TS_AUTHKEY "$ROOT/commands/bootstrap.sh" workstation
  check "bootstrap: custom parses, refuses non-root" 1 "must run as root" \
    env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" custom --hostname b --class server --host no --join authkey
else
  echo "skip: bootstrap non-root refusals (running as root)"
fi

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
printf 'role=workload class=server host=no join=authkey\n'      > "$MARKER_FIX/workload"
printf 'role=control-plane class=server host=no join=authkey\n' > "$MARKER_FIX/control-plane"
printf 'role=control-plane\n'                                   > "$MARKER_FIX/bare-control-plane"
if [ "$(id -u)" -ne 0 ]; then
  check "coolify: warns on a non-control-plane marker" 0 "1" \
    marker_warns "$MARKER_FIX/workload" "$ROOT/commands/coolify-install.sh" --version 4.1.2
  check "coolify: control-plane marker stays silent" 0 "0" \
    marker_warns "$MARKER_FIX/control-plane" "$ROOT/commands/coolify-install.sh" --version 4.1.2
  # A bare marker line with no trailing traits must read the same as the full
  # one — the guard must not couple to the marker's field formatting.
  check "coolify: a bare 'role=control-plane' line (no traits) stays silent" 0 "0" \
    marker_warns "$MARKER_FIX/bare-control-plane" "$ROOT/commands/coolify-install.sh" --version 4.1.2
  check "coolify: absent marker stays silent (advisory, not a gate)" 0 "0" \
    marker_warns "$MARKER_FIX/absent" "$ROOT/commands/coolify-install.sh" --version 4.1.2
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

if [ "$(id -u)" -ne 0 ]; then
  # A VALID fixture proves the whole file-validation pass sits before the
  # root check — a parse failure here would exit 2, not 1.
  check "users apply: refuses non-root"  1 "must run as root" "$ROOT/commands/users-apply.sh" --file "$FIX_OK"
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
# Marker-gate refusals through the sourced lib against fixture markers: the CLI
# path sits behind the root check, so the gate is a pure lib function on
# purpose (repo precedent: parse_users_file, assert_runner_repo). The command
# reads the marker path from RIG_ROLE_MARKER for the same reason — so the gate
# stays pointable at fixtures.
marker_gate() { # marker_gate <marker_path>
  bash -c 'set -euo pipefail
    . "$1/commands/lib/users-config.sh"
    assert_marker_human "$2"' _ "$ROOT" "$1"
}
MARKER_DIR="$(mktemp -d)"
printf 'role=workload class=server host=no join=authkey\n' > "$MARKER_DIR/server"
printf 'role=dev class=human host=yes join=authkey\n'      > "$MARKER_DIR/human"
check "users close-root: absent marker refuses, names bootstrap as the repair" \
  1 "no /etc/rig/role marker" marker_gate "$MARKER_DIR/absent"
check "users close-root: class=server refuses, names the control plane" \
  1 "control plane" marker_gate "$MARKER_DIR/server"
check "users close-root: class=human passes the gate" \
  0 "" marker_gate "$MARKER_DIR/human"
rm -rf "$MARKER_DIR"
if [ "$(id -u)" -ne 0 ]; then
  check "users close-root: refuses non-root" 1 "must run as root" "$ROOT/commands/users-close-root.sh"
else
  echo "skip: users close-root non-root refusal (running as root)"
fi
# Bootstrap must read the closed door as hardened, not broken: `no` is the
# post-close-root state, strictly harder than what bootstrap installs. Byte-grep
# the widened assertion so a revert cannot ship green.
check "bootstrap: permitrootlogin assertion accepts the closed state" 0 "" \
  grep -qF "permitrootlogin (no|prohibit-password|without-password)" "$ROOT/commands/bootstrap.sh"
# ...but only for class=human. On class=server a closed root door is a BROKEN
# box — root SSH is the control plane's automation door — and the usual cause
# is a 00-rig-users.conf left over from a former class=human life. The refusal
# must name that drop-in or the operator greps sshd configs blind; the path
# needs root + a doctored sshd, so grep the die message (repo precedent above).
check "bootstrap: class=server refusal names the stale close-root drop-in" 0 "" \
  grep -q "leftover /etc/ssh/sshd_config.d/00-rig-users.conf" "$ROOT/commands/bootstrap.sh"

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

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
