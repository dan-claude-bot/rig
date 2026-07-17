#!/usr/bin/env bash
# rig db — ad-hoc PostgreSQL dump/restore for the containers running on THIS box.
#
# Imperative on-box tooling, deliberately: this is the "I need a copy of that
# database right now" / "put this artifact back" verb an operator reaches for by
# hand. It is the counterpart to `coolify backup install`, which is the
# scheduled, declarative, forensics-only path — this one is interactive, targets
# any container, and (for restore) overwrites live data behind a confirm gate.
#
# Two rules run through everything below and are non-negotiable:
#   * $POSTGRES_USER / $POSTGRES_DB are read INSIDE the container (that is why
#     every pg_dump/psql lives in a SINGLE-quoted `sh -c '...'` — the container's
#     own environment, not the host's). Coolify randomizes the superuser per
#     database, so the host must never hardcode `postgres`; a hardcoded role is
#     simply wrong on the next container.
#   * dumps carry `--no-owner --no-acl`. Without them a cross-instance restore
#     aborts under ON_ERROR_STOP=1 the moment psql hits a GRANT/ALTER OWNER for
#     a role that does not exist on the target (source and target superusers
#     differ by construction). The dump must describe *data and schema*, not the
#     source box's role graph.
set -euo pipefail

log()  { printf 'rig-db: %s\n' "$*"; }
warn() { printf 'rig-db: WARNING: %s\n' "$*" >&2; }
die()  { printf 'rig-db: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
usage: rig db <dump|restore> ...

  dump <container> [outfile]
      Dump the PostgreSQL database inside <container> to a gzipped SQL file.
      When [outfile] is omitted, writes <container>-<UTC-timestamp>.sql.gz in
      the current directory. The dump is taken with --clean --if-exists
      --no-owner --no-acl, so it restores cleanly onto a different instance
      whose superuser differs from this one's.

  restore <artifact> <container> [db] [--yes]
      Restore a gzipped SQL artifact into <container>, connecting as the
      container's OWN superuser. [db] targets a NAMED database in a shared
      container (e.g. a `umami` database in a shared Postgres); omit it to
      restore into the container's default database. Restore OVERWRITES the
      target and prompts before doing so — pass --yes (or --force) to run
      non-interactively.
EOF
}

# --- common guards ----------------------------------------------------------
# Called AFTER arg validation (arg errors must stay testable without root).
require_common_guards() {
  [ "$(id -u)" -eq 0 ] || die "must run as root"
  if [ -r /etc/os-release ]; then
    # Sourced in a subshell — /etc/os-release defines VERSION and would clobber
    # a caller's variables (see test/cli.sh's regression check).
    local OS_FAMILY
    # shellcheck source=/dev/null
    OS_FAMILY="$(. /etc/os-release && printf '%s %s' "${ID:-}" "${ID_LIKE:-}")"
    case "$OS_FAMILY" in
      *debian*) ;;
      *) warn "not a Debian-family system (${OS_FAMILY:-unknown}); proceeding anyway" ;;
    esac
  else
    warn "cannot read /etc/os-release; proceeding anyway"
  fi
  # dump/restore only make sense on a box actually running the containers.
  command -v docker >/dev/null \
    || die "docker not found — rig db operates on containers running on this box"
}

# --- db dump ----------------------------------------------------------------
cmd_dump() {
  local container="" outfile="" tmp
  local -a pos=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --*|-*) die "unknown flag: $1" 2 ;;
      *) pos+=("$1"); shift ;;
    esac
  done

  # Args first, so these errors are reachable without docker or root.
  [ "${#pos[@]}" -le 2 ] || die "dump takes at most <container> [outfile]" 2
  container="${pos[0]:-}"
  outfile="${pos[1]:-}"
  [ -n "$container" ] || die "dump needs a container name" 2
  # Mirror coolify-dump.sh's timestamp style for the default name.
  [ -n "$outfile" ] || outfile="${container}-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"

  require_common_guards
  command -v gzip >/dev/null || die "gzip not found (part of coreutils on Debian)"

  log "dumping database in container ${container} -> ${outfile}"
  # Write to a sibling temp and promote on success, so a failed dump never
  # leaves a plausible-looking artifact in place of a real one. Same directory
  # as the target keeps the final mv atomic.
  tmp="$(mktemp "${outfile}.XXXXXX")" || die "could not create a temp file next to ${outfile}"
  trap 'rm -f "$tmp"' EXIT

  # pipefail (set above) is load-bearing: without it a failing pg_dump still
  # exits 0 through the pipe and gzip faithfully compresses the truncated output
  # into a valid .gz that looks exactly like a good backup. The `sh -c` is
  # single-quoted on purpose — $POSTGRES_USER/$POSTGRES_DB are the CONTAINER's.
  # shellcheck disable=SC2016
  if ! docker exec "$container" \
        sh -c 'pg_dump -U "$POSTGRES_USER" --clean --if-exists --no-owner --no-acl "$POSTGRES_DB"' \
        | gzip > "$tmp"; then
    die "pg_dump failed — no artifact written"
  fi
  # Even an empty dump gzips to a ~20-byte VALID file; refuse to keep one.
  [ -s "$tmp" ] || die "refusing to keep an empty dump artifact"
  mv "$tmp" "$outfile"
  trap - EXIT
  log "wrote ${outfile} ($(stat -c %s "$outfile") bytes)"
}

# --- db restore -------------------------------------------------------------
cmd_restore() {
  local artifact="" container="" target_db="" assume_yes=0 reply=""
  local -a pos=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes|--force) assume_yes=1; shift ;;
      -h|--help) usage; exit 0 ;;
      --*|-*) die "unknown flag: $1" 2 ;;
      *) pos+=("$1"); shift ;;
    esac
  done

  # Args first: required-arg errors are exit 2 and reachable without root.
  [ "${#pos[@]}" -le 3 ] || die "restore takes at most <artifact> <container> [db]" 2
  artifact="${pos[0]:-}"
  container="${pos[1]:-}"
  target_db="${pos[2]:-}"
  [ -n "$artifact" ]  || die "restore needs an artifact file" 2
  [ -n "$container" ] || die "restore needs a target container" 2
  # Artifact existence/non-emptiness is checkable without docker or root, so we
  # check it HERE — a fat-fingered path fails clearly and cheaply, before the
  # confirm gate and before anything touches the database.
  [ -e "$artifact" ] || die "artifact not found: ${artifact}"
  [ -f "$artifact" ] || die "artifact is not a regular file: ${artifact}"
  [ -s "$artifact" ] || die "artifact is empty: ${artifact}"

  require_common_guards
  command -v gunzip >/dev/null || die "gunzip not found (part of coreutils on Debian)"

  # Destructive: restore overwrites the target database in place. Default to
  # prompting; --yes/--force is the automation bypass.
  if [ "$assume_yes" -eq 0 ]; then
    printf 'rig-db: restore OVERWRITES the database in container %s%s. Continue? [y/N] ' \
      "$container" "${target_db:+ (database ${target_db})}" >&2
    read -r reply || reply=""
    case "$reply" in
      y|Y|yes|YES|Yes) ;;
      *) die "aborted — no changes made" ;;
    esac
  fi

  log "restoring ${artifact} into container ${container}${target_db:+ (database ${target_db})}"
  # Connect as the container's OWN superuser ($POSTGRES_USER); never hardcode
  # postgres. RIG_TARGET_DB carries the optional [db] arg INTO the container so
  # a shared Postgres can be restored into a NAMED database; empty falls back to
  # the container's own $POSTGRES_DB. ON_ERROR_STOP=1 aborts on the first error
  # rather than limping to a half-applied restore and reporting success.
  # shellcheck disable=SC2016
  if ! gunzip -c "$artifact" \
        | docker exec -i -e RIG_TARGET_DB="$target_db" "$container" \
            sh -c 'psql -U "$POSTGRES_USER" -d "${RIG_TARGET_DB:-$POSTGRES_DB}" -v ON_ERROR_STOP=1'; then
    die "restore failed — the database may be partially applied; inspect container ${container}"
  fi
  log "restore complete"
}

# --- dispatch ---------------------------------------------------------------
sub="${1:-}"
case "$sub" in
  dump)    shift; cmd_dump "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
