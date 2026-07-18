#!/usr/bin/env bash
set -euo pipefail

# rig installer — intended for: curl -fsSL .../install.sh | bash
#
# Three channels from this one script (heavy-duty/rig#32; box#83's design):
#
#   RIG_REF unset      the latest RELEASE — the tag is resolved from the
#                      releases/latest redirect, the download is that tag's
#                      source tarball (which IS the package)
#   RIG_REF=<tag>      that release, pinned (a tag outranks a branch of the
#                      same name)
#   RIG_REF=<branch>   the development tree, e.g. RIG_REF=main
#
# Downloads the rig repo tarball and installs it into the VERSIONED layout
# under $DEST (box#79's layout, ported — heavy-duty/rig#35):
#
#   $DEST/versions/<version>/    one full tree per installed version
#   $DEST/current -> versions/<version>       the default version
#   $BINDIR/rig   -> $DEST/current/bin/rig    the PATH entry
#
# Versions install side by side: `rig versions` lists them, `rig use <v>`
# switches the default, `rig uninstall` removes them. Re-running with an
# already-installed version is a converging no-op (RIG_REINSTALL=1 replaces
# that version's tree); a NEW version installs beside the old one and becomes
# the default — with a WARNING when this host is bootstrapped (/etc/rig/role
# exists), because switching the rig under a converged host changes what a
# re-converge would do. rig warns where box refuses: rig has no boxes to
# protect, and the operator flipping versions on purpose is the common case.
# A pre-versioning flat tree is migrated in place, so upgrading is seamless.
#
# RIG_INSTALL_SOURCE=<dir-or-tarball> installs from a local tree instead of
# downloading — for CI and the test suite, so what lands is the code under
# review.

REPO="${RIG_REPO:-heavy-duty/rig}"
REF="${RIG_REF:-}"   # empty = the latest release, resolved below
DEST="${RIG_HOME:-$HOME/.local/share/rig}"
if [ "$(id -u)" -eq 0 ]; then
  BINDIR="${RIG_BIN:-/usr/local/bin}"
else
  BINDIR="${RIG_BIN:-$HOME/.local/bin}"
fi

log() { printf 'rig-install: %s\n' "$*"; }
warn() { printf 'rig-install: WARNING: %s\n' "$*" >&2; }
die() { printf 'rig-install: ERROR: %s\n' "$*" >&2; exit 1; }

# A version is a DIRECTORY NAME under versions/ — nothing else. One strict
# gate for every caller that builds a path from one (the installer's new_ver,
# migration's flat_ver, and bin/rig's 'use'/single-version uninstall): only
# [A-Za-z0-9._+-], no leading '.' or '-'. That forbids '/', '..'-escapes,
# spaces and option-lookalikes by construction — a crafted version dies HERE,
# never in an rm -rf or an ln. bin/rig carries a byte-identical copy;
# test/cli.sh diffs the two so the gates cannot drift.
valid_version() {
  case "$1" in
    ''|.*|-*) return 1 ;;
    *[!A-Za-z0-9._+-]*) return 1 ;;
  esac
  return 0
}

# The flip gate, rig's shape (#35): box refuses version flips under existing
# boxes; rig's stake is the converged HOST — /etc/rig/role marks a box that
# bootstrap has made into something. Switching the default rig under it
# changes what a re-converge would do, which is worth a warning, not a
# refusal: there is no user state a flip can strand, and flipping versions on
# a bootstrapped host is the normal upgrade. RIG_ROLE_MARKER overrides the
# path so tests point it at fixtures (repo precedent: the coolify marker
# gate). bin/rig carries a byte-identical copy; test/cli.sh diffs the two.
warn_bootstrapped() {   # $1 = what is about to happen
  local marker="${RIG_ROLE_MARKER:-/etc/rig/role}"
  [ -e "$marker" ] || return 0
  warn "this host is bootstrapped ($(head -n1 "$marker" 2>/dev/null || echo "role marker at $marker"))"
  warn "$1 changes what a re-converge (rig bootstrap, users apply) would do — proceeding."
}

# --- the release channels (#32; box#83's design, near-verbatim) --------------
# resolve_latest_tag <owner/repo> — print the latest RELEASE tag, resolved by
# following the releases/latest redirect and reading the Location header
# (curl's %{redirect_url} is that header, parsed): no API, no token, no
# rate-limit pain. A repo with no releases redirects to /releases — not to
# /releases/tag/<tag> — so this returns 1 there instead of inventing a ref,
# and the CALLER owns the loud story. test/release.sh extracts this function
# (awk, the valid_version idiom) and drives it against a stubbed curl.
resolve_latest_tag() {
  local loc
  loc="$(curl -fsSI -o /dev/null -w '%{redirect_url}' "https://github.com/$1/releases/latest")" || return 1
  case "$loc" in
    */releases/tag/?*) printf '%s\n' "${loc##*/releases/tag/}" ;;
    *) return 1 ;;
  esac
}

# ref_candidate_urls <owner/repo> <ref> — the download candidates for an
# explicit RIG_REF, in order: refs/tags first, so a tag always outranks a
# branch that happens to share its name (the pin must win), refs/heads as
# the fallback that keeps RIG_REF=main the dev channel.
ref_candidate_urls() {
  printf 'https://github.com/%s/archive/refs/tags/%s.tar.gz\n' "$1" "$2"
  printf 'https://github.com/%s/archive/refs/heads/%s.tar.gz\n' "$1" "$2"
}

# --- prerequisites -----------------------------------------------------------
# curl only when something must be downloaded — a local RIG_INSTALL_SOURCE
# needs none, which is what lets test/cli.sh drive REAL installs offline.
if [ -z "${RIG_INSTALL_SOURCE:-}" ]; then
  command -v curl >/dev/null 2>&1 || die "curl is required but was not found."
fi
command -v tar  >/dev/null 2>&1 || die "tar is required but was not found."

if [ -n "${RIG_INSTALL_SOURCE:-}" ]; then
  SRCDESC="local source $RIG_INSTALL_SOURCE"
else
  SRCDESC="$REPO@${REF:-latest-release}"   # refined once the tag resolves
fi

# Flip $DEST/current to versions/<v> atomically: build the new link beside it,
# rename over. Plain ln -sfn is unlink+create — a window where current names
# nothing and a concurrent 'rig' invocation dies mid-chain. bin/rig's cmd_use
# flips with the same pattern.
flip_current() {
  ln -sfn "versions/$1" "$DEST/current.new.$$"
  mv -Tf "$DEST/current.new.$$" "$DEST/current"
}

# --- migrate a pre-versioning flat install -----------------------------------
# The old installer put the tree FLAT at $DEST (bin/rig directly under it).
# Move such a tree to versions/<its-VERSION> BEFORE anything else, so the
# upgrade is seamless and the version comparison below sees the truth. The
# move is two renames inside one parent directory — no copying, no window with
# no install — and the operator's tree is preserved bit for bit. Pre-VERSION
# trees (every flat rig install, rig#32) migrate as 0.0.0-unknown.
if [ -e "$DEST/bin/rig" ] && [ ! -d "$DEST/versions" ]; then
  flat_ver="$(cat "$DEST/VERSION" 2>/dev/null || echo 0.0.0-unknown)"
  # The flat tree's VERSION is data from disk, not from this installer — the
  # same trust boundary as the new_ver check, so the same gate: a corrupted
  # (or hostile) VERSION must not steer the mv/ln below out of versions/.
  valid_version "$flat_ver" || die "the flat install's VERSION is not a sane directory name: '$flat_ver' — fix $DEST/VERSION (one line, e.g. 0.1.0), then re-run"
  log "found a pre-versioning flat install at $DEST (version $flat_ver) — migrating it into the versioned layout"
  staging="$DEST.migrating.$$"
  mv "$DEST" "$staging"
  mkdir -p "$DEST/versions"
  mv "$staging" "$DEST/versions/$flat_ver"
  flip_current "$flat_ver"
  mkdir -p "$BINDIR"
  ln -sfn "$DEST/current/bin/rig" "$BINDIR/rig"
  log "migrated: it now lives at $DEST/versions/$flat_ver (still current)"
fi

# --- temp workspace ----------------------------------------------------------
TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

# --- acquire the tree --------------------------------------------------------
if [ -n "${RIG_INSTALL_SOURCE:-}" ]; then
  SRC="$RIG_INSTALL_SOURCE"
  INSTALLED_FROM="local:$SRC"
  if [ -d "$SRC" ]; then
    log "copying local tree $SRC"
    mkdir -p "$TMPDIR/tree"
    # tar, not cp -a: --exclude=.git, so a working checkout never carries its
    # VCS state (or its size) into the install tree.
    tar -C "$SRC" --exclude=.git -cf - . | tar -xf - -C "$TMPDIR/tree"
    EXTRACTED="$TMPDIR/tree"
  elif [ -f "$SRC" ]; then
    log "extracting local tarball $SRC"
    tar -xzf "$SRC" -C "$TMPDIR" || die "failed to extract $SRC"
    EXTRACTED="$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  else
    die "RIG_INSTALL_SOURCE is set but is neither a directory nor a tarball: $SRC"
  fi
else
  # Which ref? RIG_REF unset means the latest release — and while no release
  # exists (rig cuts its first, 0.1.0, right after #32 lands), that channel
  # must FAIL, loudly and with the way out, never silently fall back to
  # main: "I installed the latest release" must not quietly mean "I
  # installed whatever main was that second".
  if [ -z "$REF" ]; then
    log "resolving the latest release of $REPO"
    if ! REF="$(resolve_latest_tag "$REPO")"; then
      warn "could not resolve the latest release of $REPO — either no release exists yet, or GitHub was unreachable."
      warn "(rig has no release until 0.1.0 is cut — rig#32. Until then, install the development tree explicitly.)"
      die "set RIG_REF: e.g.  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | RIG_REF=main bash"
    fi
    log "latest release: $REF"
    urls=("https://github.com/$REPO/archive/refs/tags/$REF.tar.gz")
  else
    mapfile -t urls < <(ref_candidate_urls "$REPO" "$REF")
  fi
  SRCDESC="$REPO@$REF"
  INSTALLED_FROM="$REPO@$REF"
  log "installing rig ($REPO@$REF)"
  got=""
  for URL in "${urls[@]}"; do
    log "downloading $URL"
    if curl -fsSL "$URL" -o "$TMPDIR/rig.tar.gz"; then
      got="$URL"
      break
    fi
  done
  [ -n "$got" ] \
    || die "failed to download $REPO@$REF — not a tag and not a branch (tried refs/tags then refs/heads)"

  log "extracting archive"
  tar -xzf "$TMPDIR/rig.tar.gz" -C "$TMPDIR" \
    || die "failed to extract archive"

  # GitHub names the archive's top dir <repo>-<ref> — deriving that name is
  # guesswork (it broke for real at box's repo rename). The tarball has
  # exactly ONE top-level directory: take the directory, whatever it is
  # called, and let the bin/rig check below judge whether it is the right tree.
  EXTRACTED="$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d | head -n1)"
fi
[ -n "${EXTRACTED:-}" ] || die "could not find the source tree in $SRCDESC"
[ -f "$EXTRACTED/bin/rig" ] || die "source does not contain bin/rig — is $SRCDESC correct?"

# The tree's own VERSION file names the directory it lands in — the version IS
# the identity of what is being installed, and 'rig versions' lists these names.
new_ver="$(cat "$EXTRACTED/VERSION" 2>/dev/null || true)"
[ -n "$new_ver" ] || die "source has no VERSION file — cannot install it as a version"
valid_version "$new_ver" || die "the source's VERSION is not a sane directory name: '$new_ver'"

set_exec() {   # $1 = a rig tree: the executable bits install.sh owns
  chmod +x "$1/bin/rig"
  if [ -d "$1/commands" ]; then
    find "$1/commands" -name '*.sh' -exec chmod +x {} +
  fi
}

# --- install into $DEST/versions/<version> -----------------------------------
VDIR="$DEST/versions/$new_ver"
newly_installed=0
if [ -d "$VDIR" ]; then
  if [ -n "${RIG_REINSTALL:-}" ]; then
    # Replace THIS version's tree, as atomically as two renames allow — never
    # a partial overlay of new files onto an old tree.
    log "RIG_REINSTALL=1 — replacing the installed $new_ver tree"
    stage="$VDIR.new.$$"; old="$VDIR.old.$$"
    rm -rf "$stage" "$old"
    set_exec "$EXTRACTED"
    mv "$EXTRACTED" "$stage"
    # Swap by renames, delete LAST: rm-then-move leaves a hole the whole
    # length of the delete where current -> this version resolves to nothing.
    mv "$VDIR" "$old"
    mv "$stage" "$VDIR"
    rm -rf "$old"
    printf '%s\n' "$INSTALLED_FROM" > "$VDIR/INSTALLED_FROM"
    log "reinstalled $new_ver"
  else
    cur_from="$(cat "$VDIR/INSTALLED_FROM" 2>/dev/null || echo '<unknown source>')"
    log "rig $new_ver is already installed ($cur_from) — nothing to do."
    log "(RIG_REINSTALL=1 replaces this version's tree; 'rig versions' lists what is installed.)"
  fi
else
  log "installing $new_ver into $VDIR"
  mkdir -p "$DEST/versions"
  set_exec "$EXTRACTED"
  mv "$EXTRACTED" "$VDIR"
  newly_installed=1
  # Record WHAT was installed, so a caller can assert it got what it asked
  # for — an installer invoked with stale env vars silently falls back to the
  # defaults, and INSTALLED_FROM is how that lie gets caught.
  printf '%s\n' "$INSTALLED_FROM" > "$VDIR/INSTALLED_FROM"
fi

# --- which version is the default? -------------------------------------------
# 'current' is the tracked default; flipping it is the ONLY step that changes
# what an operator's `rig` runs. A fresh host (or a dangling current) is
# claimed outright; an upgrade flips — with the bootstrapped-host warning —
# because a re-run that silently left you on the old version would make
# "re-run any time to upgrade" a lie. Judged from versions/<v> itself
# (readlink -f), never from what a wedged current claims.
cur="$(readlink -f "$DEST/current" 2>/dev/null || true)"
want="$(readlink -f "$VDIR")"
if [ -z "$cur" ] || [ ! -d "$cur" ]; then
  flip_current "$new_ver"
  log "default version: $new_ver"
elif [ "$cur" = "$want" ]; then
  : # already the default — nothing to flip
elif [ "$newly_installed" -eq 0 ]; then
  # A converge/no-op (or RIG_REINSTALL) of a version that is NOT the default
  # never moves the default — a re-run must change nothing; switching is
  # 'rig use', a deliberate act.
  log "the default stays $(basename "$cur") — 'rig use $new_ver' switches."
else
  old_ver="$(basename "$cur")"
  warn_bootstrapped "switching the default rig version ($old_ver -> $new_ver)"
  flip_current "$new_ver"
  log "default version switched: $old_ver -> $new_ver ('rig use $old_ver' switches back)"
fi

# --- put rig on PATH ---------------------------------------------------------
# ln -sfn converges, and that includes HEALING: a stale or dangling
# $BINDIR/rig (say, its tree half-removed by hand) must never block or wedge
# an install — it gets repointed at the current chain, whatever it said before.
mkdir -p "$BINDIR"
ln -sfn "$DEST/current/bin/rig" "$BINDIR/rig"
log "linked $BINDIR/rig -> $DEST/current/bin/rig"

# --- PATH check --------------------------------------------------------------
case ":$PATH:" in
  *":$BINDIR:"*) : ;;
  *)
    warn "$BINDIR is not on your PATH."
    warn "  add: export PATH=\"$BINDIR:\$PATH\""
    ;;
esac

log "done ($SRCDESC, version $new_ver) — try: rig --help"
