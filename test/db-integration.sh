#!/usr/bin/env bash
# test/db-integration.sh — a REAL dump/restore round-trip for `rig db`.
#
# test/cli.sh proves the arg parsing; this proves the actual thing works. It
# stands up throwaway PostgreSQL containers, seeds a known table, runs the real
# `rig db dump` / `rig db restore`, and reads the rows back out the far side —
# because a dump piped through gzip can look perfectly valid while being
# truncated, and only restoring it and reading it back proves otherwise.
#
# It exercises the two invariants db.sh is built around:
#   * the source superuser is a NON-default name (src_super), so a green run
#     proves the code reads the CONTAINER's own $POSTGRES_USER/$POSTGRES_DB and
#     never a hardcoded `postgres`;
#   * the destination superuser is a DIFFERENT name (dst_super), so the restore
#     only succeeds because --no-owner --no-acl stripped the source role graph —
#     a plain dump would abort under ON_ERROR_STOP=1 on the first missing role.
#
# Skips cleanly (exit 0) when it cannot run — no Docker, no reachable daemon, or
# no way to become root (rig db requires root) — so it never reddens a dev box
# that simply has no Docker. On ubuntu-latest CI, Docker is preinstalled and
# running and passwordless sudo works, so it EXECUTES for real there.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RIG="$ROOT/bin/rig"
PG_IMAGE="${RIG_DBIT_PG_IMAGE:-postgres:16-alpine}"

PASS=0 FAIL=0
ok()   { echo "ok: $*";   PASS=$((PASS + 1)); }
bad()  { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
skip() { echo "skip: $*"; exit 0; }
die()  { echo "FAIL: $*" >&2; exit 1; }   # trap still runs cleanup

# --- privilege / docker preflight -------------------------------------------
# rig db requires root (require_common_guards). CI's runner user is not root but
# has passwordless sudo and docker-group access; mirror that exactly. EVERYTHING
# that touches Docker or rig goes through as_root so containers and the artifact
# share one owner and cleanup is uniform (root can always reach the socket).
if [ "$(id -u)" -eq 0 ]; then
  as_root() { "$@"; }
elif sudo -n true >/dev/null 2>&1; then
  as_root() { sudo "$@"; }
else
  skip "not root and no passwordless sudo — rig db requires root; cannot run the round-trip here"
fi

command -v docker >/dev/null 2>&1 || skip "docker not installed — nothing to exercise"
as_root docker info >/dev/null 2>&1 || skip "docker daemon not reachable — skipping the live round-trip"
# Pull up front so an offline box SKIPS (not FAILS): a missing network is not a
# regression in rig. On CI the image is fetched here and the run below is fast.
as_root docker pull "$PG_IMAGE" >/dev/null 2>&1 || skip "could not pull ${PG_IMAGE} (offline?) — skipping"

# --- unique names + guaranteed cleanup --------------------------------------
PREFIX="rig_dbit_$$"
SRC="${PREFIX}_src"
DST="${PREFIX}_dst"
WORKDIR="$(mktemp -d)"
ARTIFACT="$WORKDIR/roundtrip.sql.gz"

cleanup() {
  as_root docker rm -f "$SRC" "$DST" >/dev/null 2>&1 || true
  as_root rm -rf "$WORKDIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# A stale run must never collide with this one.
as_root docker rm -f "$SRC" "$DST" >/dev/null 2>&1 || true

# --- helpers ----------------------------------------------------------------
# Poll until <container> answers a real query as <user>/<db>. pg_isready alone
# reports "ready" during the entrypoint's temp-server phase, so gate on an
# actual SELECT succeeding instead. Bounded (~60s) so a wedged box fails, loudly.
wait_ready() { # <container> <user> <db>
  local c="$1" u="$2" d="$3" i=0
  while [ "$i" -lt 60 ]; do
    if as_root docker exec "$c" psql -U "$u" -d "$d" -tAc 'SELECT 1' >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  die "container ${c} never started accepting connections as ${u}/${d}"
}

# An ordered, checksummable fingerprint of the fixture table — the thing that
# must survive the round-trip byte for byte.
fingerprint() { # <container> <user> <db>
  as_root docker exec "$1" psql -U "$2" -d "$3" -tAc \
    "SELECT id||'|'||name||'|'||qty FROM widgets ORDER BY id" | md5sum | cut -d' ' -f1
}
rowcount() { # <container> <user> <db>
  as_root docker exec "$1" psql -U "$2" -d "$3" -tAc 'SELECT count(*) FROM widgets' | tr -d '[:space:]'
}

# --- source: NON-default superuser, seeded fixture --------------------------
as_root docker run -d --name "$SRC" \
  -e POSTGRES_USER=src_super -e POSTGRES_DB=src_appdb -e POSTGRES_PASSWORD=srcpw \
  "$PG_IMAGE" >/dev/null
wait_ready "$SRC" src_super src_appdb

as_root docker exec "$SRC" psql -U src_super -d src_appdb -v ON_ERROR_STOP=1 -c "
  CREATE TABLE widgets (id int PRIMARY KEY, name text NOT NULL, qty int NOT NULL);
  INSERT INTO widgets VALUES (1,'alpha',10),(2,'beta',20),(3,'gamma',30);
" >/dev/null

# assert_eq <desc> <want> <got>
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — wanted [$2] got [$3]"; fi
}

SRC_FP="$(fingerprint "$SRC" src_super src_appdb)"
assert_eq "source seeded with 3 known rows" 3 "$(rowcount "$SRC" src_super src_appdb)"

# --- dump (explicit outfile) ------------------------------------------------
if as_root "$RIG" db dump "$SRC" "$ARTIFACT" >/dev/null 2>&1; then
  ok "rig db dump exited 0"
else
  bad "rig db dump failed"
fi
if as_root test -s "$ARTIFACT"; then
  ok "dump wrote a non-empty artifact"
else
  die "dump produced no usable artifact — nothing to restore"
fi

# --- dump (default outfile naming: <container>-<UTC-timestamp>.sql.gz) -------
( cd "$WORKDIR" && as_root "$RIG" db dump "$SRC" >/dev/null 2>&1 )
if compgen -G "$WORKDIR/${SRC}-*.sql.gz" >/dev/null; then
  ok "dump with no outfile wrote <container>-<timestamp>.sql.gz in cwd"
else
  bad "default dump name not produced"
fi

# --- destination: DIFFERENT superuser (the portability proof) ---------------
as_root docker run -d --name "$DST" \
  -e POSTGRES_USER=dst_super -e POSTGRES_DB=dst_appdb -e POSTGRES_PASSWORD=dstpw \
  "$PG_IMAGE" >/dev/null
wait_ready "$DST" dst_super dst_appdb

# --- restore into the default database --------------------------------------
if as_root "$RIG" db restore "$ARTIFACT" "$DST" --yes >/dev/null 2>&1; then
  ok "rig db restore exited 0 across a differing superuser"
else
  bad "rig db restore failed (a role-graph leak would abort here)"
fi

DST_FP="$(fingerprint "$DST" dst_super dst_appdb)"
assert_eq "destination has exactly 3 rows after restore" 3 "$(rowcount "$DST" dst_super dst_appdb)"
if [ "$DST_FP" = "$SRC_FP" ]; then
  ok "restored fingerprint matches source ($SRC_FP)"
else
  bad "restored data differs — src=$SRC_FP dst=$DST_FP"
fi

# --- idempotency: --clean --if-exists means a second restore is a no-op-ish --
if as_root "$RIG" db restore "$ARTIFACT" "$DST" --yes >/dev/null 2>&1; then
  ok "second restore exited 0 (dump is --clean --if-exists)"
else
  bad "second restore failed"
fi
assert_eq "still exactly 3 rows after re-restore (no duplication)" 3 "$(rowcount "$DST" dst_super dst_appdb)"
assert_eq "fingerprint stable after re-restore" "$SRC_FP" "$(fingerprint "$DST" dst_super dst_appdb)"

# --- restore into a NAMED scratch db (the [db] arg / shared-Postgres path) ---
# This is exactly the safe manual proof the README documents: restore into a
# fresh scratch database rather than over live data.
as_root docker exec "$DST" createdb -U dst_super rig_verify >/dev/null
if as_root "$RIG" db restore "$ARTIFACT" "$DST" rig_verify --yes >/dev/null 2>&1; then
  ok "rig db restore into a named [db] exited 0"
else
  bad "restore into named database failed"
fi
assert_eq "named-database restore reproduced the source fingerprint" \
  "$SRC_FP" "$(fingerprint "$DST" dst_super rig_verify)"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
