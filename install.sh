#!/usr/bin/env bash
set -euo pipefail

# rig installer — intended for: curl -fsSL .../install.sh | bash
#
# Downloads the rig repo tarball, installs the whole tree under $DEST,
# and puts a `rig` symlink on PATH via $BINDIR. Re-run any time to
# upgrade.

REPO="${RIG_REPO:-heavy-duty/rig}"
REF="${RIG_REF:-main}"
DEST="${RIG_HOME:-$HOME/.local/share/rig}"
if [ "$(id -u)" -eq 0 ]; then
  BINDIR="${RIG_BIN:-/usr/local/bin}"
else
  BINDIR="${RIG_BIN:-$HOME/.local/bin}"
fi

log() { printf 'rig-install: %s\n' "$*"; }
warn() { printf 'rig-install: WARNING: %s\n' "$*" >&2; }
die() { printf 'rig-install: ERROR: %s\n' "$*" >&2; exit 1; }

# --- prerequisites -----------------------------------------------------------
command -v curl >/dev/null 2>&1 || die "curl is required but was not found."
command -v tar  >/dev/null 2>&1 || die "tar is required but was not found."

# --- temp workspace ----------------------------------------------------------
TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

URL="https://github.com/$REPO/archive/refs/heads/$REF.tar.gz"

log "installing rig ($REPO@$REF)"
log "downloading $URL"
curl -fsSL "$URL" -o "$TMPDIR/rig.tar.gz" \
  || die "failed to download $URL"

log "extracting archive"
tar -xzf "$TMPDIR/rig.tar.gz" -C "$TMPDIR" \
  || die "failed to extract archive"

# GitHub archives extract to a single top-level dir like rig-<ref>/
EXTRACTED="$(find "$TMPDIR" -maxdepth 1 -type d -name 'rig-*' | head -n1)"
[ -n "$EXTRACTED" ] || die "could not find extracted rig-* directory in archive"
[ -f "$EXTRACTED/bin/rig" ] || die "archive does not contain bin/rig — is $REPO@$REF correct?"

# --- atomically replace $DEST --------------------------------------------------
log "installing into $DEST"
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
mv "$EXTRACTED" "$DEST"

chmod +x "$DEST/bin/rig" "$DEST"/commands/*.sh

# --- put rig on PATH ------------------------------------------------------
mkdir -p "$BINDIR"
ln -sf "$DEST/bin/rig" "$BINDIR/rig"
log "linked $BINDIR/rig -> $DEST/bin/rig"

# --- PATH check ----------------------------------------------------------------
case ":$PATH:" in
  *":$BINDIR:"*) : ;;
  *)
    warn "$BINDIR is not on your PATH."
    warn "  add: export PATH=\"$BINDIR:\$PATH\""
    ;;
esac

log "done — try: rig --help"
