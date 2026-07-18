#!/usr/bin/env bash
# rig coolify backup install — nightly age-encrypted dump of the Coolify
# control-plane database, as a systemd timer.
#
# rig installs the machinery and templates the bindings file. It never writes
# a credential and never reads the file back. Convergent: safe to re-run; an
# already-filled bindings file is left untouched.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/users-config.sh
. "$HERE/lib/users-config.sh"   # read_role_marker — the traits line bootstrap wrote

log()  { printf 'rig-coolify-backup: %s\n' "$*"; }
warn() { printf 'rig-coolify-backup: WARNING: %s\n' "$*" >&2; }
die()  { printf 'rig-coolify-backup: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
usage: rig coolify backup install [options]

  --schedule <OnCalendar>  systemd OnCalendar expression
                           (default: *-*-* 04:00:00 UTC)
  --pg-container <name>    Coolify's postgres container (default: coolify-db)
  --pg-user <name>         postgres role to dump as (default: coolify)
  --pg-db <name>           database to dump (default: coolify)

Installs a nightly dump of the Coolify control-plane database: pg_dump piped
straight into age (encrypted CLIENT-SIDE, on this box) and shipped to an
S3-compatible bucket. Control-plane box only. Run as root.

That database holds the GitHub App private key, every registered server's SSH
key, and every environment value for every environment this control plane
manages — which is why it is never written to disk or to S3 in the clear.

rig installs: age, awscli, /usr/local/sbin/coolify-dump.sh, a systemd service
+ timer, and an EMPTY 0600 bindings file at /etc/coolify-dump.env.

You supply, by filling that file and nothing else: the age recipient (a PUBLIC
key), the S3 bucket + endpoint, and the S3 credentials. Until you do, the unit
fails loudly on every run — the correct failure mode for a backup.
EOF
}

# --- args (validated before the root check, so errors stay testable) --------
SCHEDULE="*-*-* 04:00:00 UTC"
PG_CONTAINER="coolify-db"
PG_USER="coolify"
PG_DB="coolify"
while [ $# -gt 0 ]; do
  case "$1" in
    --schedule)
      [ $# -ge 2 ] || die "--schedule needs a value" 2
      SCHEDULE="$2"; shift 2 ;;
    --pg-container)
      [ $# -ge 2 ] || die "--pg-container needs a value" 2
      PG_CONTAINER="$2"; shift 2 ;;
    --pg-user)
      [ $# -ge 2 ] || die "--pg-user needs a value" 2
      PG_USER="$2"; shift 2 ;;
    --pg-db)
      [ $# -ge 2 ] || die "--pg-db needs a value" 2
      PG_DB="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown flag: $1" 2 ;;
  esac
done

[ -n "$SCHEDULE" ]     || die "--schedule must not be empty" 2
[ -n "$PG_CONTAINER" ] || die "--pg-container must not be empty" 2
[ -n "$PG_USER" ]      || die "--pg-user must not be empty" 2
[ -n "$PG_DB" ]        || die "--pg-db must not be empty" 2

# --- role-marker sanity (issue #25) ------------------------------------------
# Same advisory check as `rig coolify install`, same reasoning: this command
# dumps the CONTROL PLANE's database, so a marker naming any other role almost
# certainly means the wrong SSH session — but the marker is advisory and may be
# absent, so WARN, never die, and warn before the root check so the harness can
# prove it non-root (RIG_ROLE_MARKER points it at fixtures, repo precedent).
MARKER_LINE="$(read_role_marker "${RIG_ROLE_MARKER:-/etc/rig/role}")"
case "$MARKER_LINE" in
  ""|"role=control-plane"|"role=control-plane "*) ;;
  *) warn "this box's role marker says '${MARKER_LINE}' — not a control-plane box. The nightly dump targets Coolify's own database, which lives on role control-plane; if this is the wrong box, stop here and re-check your SSH session." ;;
esac

# --- guards ----------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root"
if [ -r /etc/os-release ]; then
  # Sourced in a subshell — /etc/os-release defines VERSION and would clobber
  # a caller's variables (see test/cli.sh's regression check).
  # shellcheck source=/dev/null
  OS_FAMILY="$(. /etc/os-release && printf '%s %s' "${ID:-}" "${ID_LIKE:-}")"
  case "$OS_FAMILY" in
    *debian*) ;;
    *) warn "not a Debian-family system (${OS_FAMILY:-unknown}); proceeding anyway" ;;
  esac
else
  warn "cannot read /etc/os-release; proceeding anyway"
fi
command -v docker >/dev/null \
  || die "docker not found — this is a control-plane box command (run rig coolify install first)"
command -v systemctl >/dev/null || die "systemd is required"

SCRIPT_PATH="/usr/local/sbin/coolify-dump.sh"
ENV_FILE="/etc/coolify-dump.env"
UNIT_DIR="/etc/systemd/system"

# --- packages ---------------------------------------------------------------
# age encrypts the dump before it leaves the box. awscli is used ONLY as an
# S3 protocol client (--endpoint-url); no AWS account is involved.
log "installing age + awscli"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq age awscli >/dev/null
log "age $(age --version 2>/dev/null || echo '?') · $(aws --version 2>&1 | cut -d' ' -f1)"

# --- the dump script --------------------------------------------------------
log "writing ${SCRIPT_PATH}"
cat > "$SCRIPT_PATH" <<'DUMP_SCRIPT'
#!/usr/bin/env bash
# Nightly age-encrypted dump of the Coolify control-plane database.
# Installed by `rig coolify backup install` — edit rig, not this copy.
#
# Forensics, not a restore path: a lost control plane is rebuilt fresh and
# reconciled from its manifest, never restored from this artifact. It exists
# to answer "what WAS the state" and to recover a credential otherwise lost.
set -euo pipefail

die() { printf 'coolify-dump: ERROR: %s\n' "$1" >&2; exit 1; }

: "${AGE_RECIPIENT:?not set — fill /etc/coolify-dump.env (age PUBLIC key)}"
: "${S3_BUCKET:?not set — fill /etc/coolify-dump.env (e.g. s3://backups/coolify-db)}"
: "${S3_ENDPOINT:?not set — fill /etc/coolify-dump.env (e.g. https://hel1.your-objectstorage.com)}"

# Validate the bindings HERE, before spending a pg_dump on them. A bare bucket
# name reads to `aws` as a LOCAL path, so it fails deep in the upload with
# "Invalid argument type" and a usage dump — after the database has been read
# and encrypted, and with nothing pointing at the actual mistake.
case "$S3_BUCKET" in
  s3://?*) ;;
  *) die "S3_BUCKET must be an s3:// URI (got: '${S3_BUCKET}') — aws reads a bare bucket name as a local path" ;;
esac
case "$S3_ENDPOINT" in
  http://?*|https://?*) ;;
  *) die "S3_ENDPOINT needs a scheme (got: '${S3_ENDPOINT}') — e.g. https://hel1.your-objectstorage.com" ;;
esac

# NOTE: no check can tell you the recipient is the RIGHT key. age's X25519
# header does not reveal who it encrypts to, so a valid-but-wrong recipient
# (staging's key instead of prod's) produces a perfect backup nobody can open.
# Only decrypting an artifact proves that. Do it once, from a machine that
# holds the private key — never on this box.

PG_CONTAINER="${PG_CONTAINER:-coolify-db}"
PG_USER="${PG_USER:-coolify}"
PG_DB="${PG_DB:-coolify}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
OUT="${WORKDIR}/coolify-db-$(date -u +%Y%m%dT%H%M%SZ).sql.age"

# `set -o pipefail` (above) is load-bearing: without it a failing pg_dump still
# exits 0 through the pipe, and age faithfully encrypts the truncated output.
docker exec "$PG_CONTAINER" pg_dump -U "$PG_USER" "$PG_DB" \
  | age -r "$AGE_RECIPIENT" -o "$OUT"

# A failed dump piped into age still yields a valid, tiny, encrypted file. That
# would upload cleanly every night and look exactly like a working backup.
[ -s "$OUT" ] || { printf 'coolify-dump: refusing to upload an empty artifact\n' >&2; exit 1; }

aws s3 cp "$OUT" "${S3_BUCKET}/" --endpoint-url "$S3_ENDPOINT"
printf 'coolify-dump: uploaded %s (%s bytes)\n' "$(basename "$OUT")" "$(stat -c %s "$OUT")"
DUMP_SCRIPT
chmod 700 "$SCRIPT_PATH"

# --- bindings file (templated empty; NEVER clobbered) ------------------------
if [ -e "$ENV_FILE" ]; then
  log "${ENV_FILE} exists — leaving it alone (rig never reads or rewrites it)"
else
  log "templating ${ENV_FILE} (empty, 0600)"
  install -m 0600 /dev/null "$ENV_FILE"
  cat > "$ENV_FILE" <<'ENV_TEMPLATE'
# Coolify control-plane dump — bindings.
#
# rig installed the machinery; these values are yours. rig wrote this file
# empty and never reads it back. Nothing here is committed anywhere.
#
# AGE_RECIPIENT is a PUBLIC key (age1...) — safe to hold on this box. Its
# PRIVATE half must never live here: whoever holds it can read every secret
# this control plane manages. Keep it wherever your strictest key lives.
AGE_RECIPIENT=
S3_BUCKET=
S3_ENDPOINT=
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_DEFAULT_REGION=
ENV_TEMPLATE
  chmod 600 "$ENV_FILE"
fi

# --- systemd service + timer -------------------------------------------------
log "writing ${UNIT_DIR}/coolify-dump.service"
cat > "$UNIT_DIR/coolify-dump.service" <<UNIT
[Unit]
Description=Age-encrypted dump of the Coolify control-plane database
Documentation=https://github.com/heavy-duty/rig
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
# Defaults rig owns. Listed BEFORE EnvironmentFile so the operator's file wins
# on any key it sets, while a file that omits them still gets sane values.
#
# aws-cli >= 2.23 turns on new default upload checksums that S3-compatible
# backends (Hetzner, MinIO, Ceph) reject; \`when_required\` restores the older
# behavior. Debian 13 ships 2.23. Harmless where the backend does support them.
Environment=AWS_REQUEST_CHECKSUM_CALCULATION=when_required
Environment=AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
Environment=PG_CONTAINER=${PG_CONTAINER}
Environment=PG_USER=${PG_USER}
Environment=PG_DB=${PG_DB}
EnvironmentFile=${ENV_FILE}
ExecStart=${SCRIPT_PATH}
UNIT

log "writing ${UNIT_DIR}/coolify-dump.timer (${SCHEDULE})"
cat > "$UNIT_DIR/coolify-dump.timer" <<UNIT
[Unit]
Description=Nightly Coolify control-plane dump
Documentation=https://github.com/heavy-duty/rig

[Timer]
OnCalendar=${SCHEDULE}
# Catch a run missed while the box was down, rather than silently skipping a night.
Persistent=true
RandomizedDelaySec=15m

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now coolify-dump.timer >/dev/null 2>&1
log "timer enabled — next run: $(systemctl show -P NextElapseUSecRealtime coolify-dump.timer 2>/dev/null || echo '?')"

# --- what rig deliberately did NOT do ----------------------------------------
cat <<EOF

rig-coolify-backup: installed. The timer is live but the backup does NOT work yet —
rig has no credentials and cannot verify an upload. Two steps remain, both yours:

  1. Fill in the bindings:  nano ${ENV_FILE}
     (age recipient = a PUBLIC key; S3 bucket, endpoint, access key, secret, region)
     S3_BUCKET must be an s3:// URI, not a bare bucket name.

  2. Run it once by hand — do NOT wait for the timer to find out:
       systemctl start coolify-dump.service
       journalctl -u coolify-dump.service -n 20 --no-pager

  3. Prove you can OPEN it. A successful upload only proves the file ARRIVED.
     If the recipient is the wrong key, every run succeeds forever and produces
     an artifact nobody can decrypt — and you cannot tell by looking at it.
     From a machine holding the private key (NEVER this box), stream it down
     and decrypt; you want PostgreSQL SQL out the other end:

       ssh root@$(hostname) 'set -a; . ${ENV_FILE}; set +a; \\
         line=\$(aws s3 ls "\$S3_BUCKET/" --endpoint-url "\$S3_ENDPOINT" | sort | tail -1); \\
         aws s3 cp "\$S3_BUCKET/\${line##* }" - --endpoint-url "\$S3_ENDPOINT"' \\
         | age -d -i <your-key-file> | { head -5; cat >/dev/null; }

     A backup you have never read back is not yet a backup.

Until step 1 is done the unit fails loudly on every run. That is deliberate — a
silent backup is worse than a missing one.
EOF
