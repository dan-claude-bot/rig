#!/usr/bin/env bash
# rig manifest — print this machine's provenance record, /etc/rig/manifest
# (#61). Reads only: this command NEVER writes the file. `rig bootstrap` is its
# single writer, and it stamps it as its own last durable act.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/manifest.sh
. "$HERE/lib/manifest.sh"        # manifest_path / manifest_value

die() { printf 'rig-manifest: ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
usage: rig manifest [<key>]

Print /etc/rig/manifest — which rig converged this machine, and when. With a
key, print that key's value alone, unquoted and newline-terminated, so a shell
caller does not re-parse the file:

  rig manifest                    schema=1
                                  bootstrapped_by=0.2.0
                                  bootstrapped_at=2026-07-19T14:24:51Z
                                  converged_by=0.4.0
                                  converged_at=2026-08-02T09:11:03Z

  rig manifest converged_by       0.4.0

Both pairs are provenance, both immutable in the sense that matters: BIRTH —
the rig that first converged this machine, pinned forever — and LATEST — the
newest rig to have converged it. On a fresh machine the two are equal. Ask the
second pair "is this machine converged by something ancient?"; ask the first
"what built it".

The version recorded is the one that RAN. `rig --version` reports the tree
installed NOW, which after an upgrade is a different question — a machine
outlives the rig that built it.

Reads only. Needs no root (the file is 0644), no network, and works on a
machine whose rig has since been upgraded or removed. Specs — cores, RAM,
disk, kernel — are NOT here: they are observed rather than decided, so they go
stale on their own and belong to `rig platform`, which computes them fresh and
stores nothing.

Exit 1 when there is no manifest — a machine converged before rig wrote one,
or never converged at all.

  RIG_MANIFEST   override the path (default /etc/rig/manifest)
EOF
}

KEY=""
for a in "$@"; do
  case "$a" in
    -h|--help) usage; exit 0 ;;
    -*)
      printf 'rig-manifest: unknown option: %s\n' "$a" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [ -n "$KEY" ]; then
        printf 'rig-manifest: manifest takes at most one key\n' >&2
        usage >&2
        exit 2
      fi
      KEY="$a"
      ;;
  esac
done

MPATH="$(manifest_path)"
[ -r "$MPATH" ] || die "no manifest at $MPATH — this machine has not been converged by a rig that writes one (rig bootstrap writes it)"

if [ -z "$KEY" ]; then
  cat "$MPATH"
  exit 0
fi

# A key that is absent and a key whose value is empty are different answers to
# a shell caller, and $(...) collapses both to "". So the ABSENCE is the exit
# code, and only a present key ever prints — a caller reading `rig manifest
# converged_by` into a variable can trust that an empty result it accepted was
# a real empty value, not a missing key.
manifest_has "$MPATH" "$KEY" \
  || die "no such key: $KEY (keys present: $(cut -d= -f1 "$MPATH" | tr '\n' ' '))"
manifest_value "$MPATH" "$KEY"
echo
