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
if [ "$(id -u)" -ne 0 ]; then
  check "bootstrap: refuses non-root"      1 "must run as root" env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" workload
  check "bootstrap: runner role parses, refuses non-root" 1 "must run as root" env TS_AUTHKEY=x "$ROOT/commands/bootstrap.sh" runner
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
