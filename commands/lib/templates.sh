#!/usr/bin/env bash
# The tenant-template REGISTRY (#110): resolve where role definitions come
# from, parse a definition's template.env against an allowlist, and lint a
# whole definition. Sourced by bootstrap-tenant.sh (the mint-time consumer)
# and template-lint.sh (the registry repo's CI gate) — pure functions plus
# one pin, no side effects at source time (repo precedent: netmap-json,
# and the tenant-config table this lib replaces).
#
# The registry moved out of rig's tree so mechanism and data can move at
# different cadences (#109 is the evidence: adding kimi — pure data — meant
# editing six files here). rig keeps the mechanism and this schema; the
# definitions live in heavy-duty/rig-templates, one directory per role:
#
#   <role>/template.env   KEY="value" data, parsed against the allowlist
#                         below and NEVER sourced — a definition cannot
#                         execute shell through its data file
#   <role>/install.sh     the CLI install (the one inherently executable part)
#   <role>/creds.md       the per-vendor creds-free paragraph the context
#                         renderer splices in
#
# THE SOURCE IS THREE KNOBS plus the installed pin snapshot, precedence
# _DIR > _REF > snapshot > pin fetch:
#   RIG_TEMPLATES_DIR    a local folder — bypasses the fetch entirely (the
#                        offline-test path, and "try a template before it
#                        exists anywhere")
#   RIG_TEMPLATES_REF    a ref in the registry repo, fetched as a tarball at
#                        bootstrap time (the same shape as the operator's rig install)
#   RIG_TEMPLATES_REPO   which repo that ref lives in (default
#                        heavy-duty/rig-templates)
# and, absent both overrides, the snapshot installed beside this file when it
# matches the PIN below, then a live fetch of that pin as the fallback.

# The default registry ref a tenant converge uses — the BOX_RELEASE discipline
# (#103): one line, bumped deliberately by ordinary rig PR after review, so a
# rig release freezes the mechanism+registry pair and a newer rig matches
# newer templates by default (ruled 2026-07-24 on #110: pinned, not
# main-tracked). RIG_TEMPLATES_REF overrides it per converge.
#
# The commit below is the registry's own release **0.1.0** — published
# 2026-08-20, https://github.com/heavy-duty/rig-templates/releases/tag/0.1.0 —
# carrying the four agent tenants, the six machine-role definitions formerly
# held in bootstrap.sh, and staging-box, the agentless hardened tenant whose
# arrival leaves rig's tree defining no role at all. Pinning a released commit
# means the definitions that run as root on tailnet-joined metal are an
# artifact with a version, published notes and a drill record behind it (#187).
#
# The VALUE IS THE SHA the tag names, never the tag: a tag is mutable and this
# pin resolves code that runs as root (rig-templates#8 D3). It is also the
# MERGE commit, not the merged PR's head — that repo merges with merge commits
# today, but a switch to squash or rebase orphans the head, and only the commit
# on `main` is a pin a fetch can always resolve. The release name lives in this
# block and never trailing on the assignment: four readers parse that line with
# `sed -n 's/^RIG_TEMPLATES_PIN=//p'` and not one of them strips a comment.
RIG_TEMPLATES_PIN=4011092d8b23a2c8f077899325a98f3d84c275b9

# The template.env schema. Grammar: blank lines, '#' comments, and
# KEY="value" — nothing else. Parsed by regex, never sourced.
TEMPLATE_KEYS_REQUIRED=(USER)
TEMPLATE_AGENT_KEYS=(CONTEXT_PATH CLI_NAME CLI_SRC PATH_LINE NEEDS_NODE)
TEMPLATE_KEYS_OPTIONAL=(AGENT HARDEN_SSHD CONTEXT_PATH CLI_NAME CLI_SRC PATH_LINE NEEDS_NODE APT_EXTRAS SWAP_SIZE)
MACHINE_KEYS_REQUIRED=(ROOT_DOOR HOST JOIN)

# templates_source_desc — where the resolved registry came from, for error
# messages and logs: a misconfigured RIG_TEMPLATES_REPO must be visible in
# the unknown-role refusal rather than looking like a typo.
templates_source_desc() {
  if [ -n "${RIG_TEMPLATES_DIR:-}" ]; then
    printf 'local dir %s (RIG_TEMPLATES_DIR)' "$RIG_TEMPLATES_DIR"
  elif [ -z "${RIG_TEMPLATES_REF:-}" ] && templates_snapshot_usable; then
    printf '%s@%s (snapshot)' \
      "${RIG_TEMPLATES_REPO:-heavy-duty/rig-templates}" \
      "$RIG_TEMPLATES_PIN"
  else
    printf '%s@%s%s' \
      "${RIG_TEMPLATES_REPO:-heavy-duty/rig-templates}" \
      "${RIG_TEMPLATES_REF:-$RIG_TEMPLATES_PIN}" \
      "$([ -n "${RIG_TEMPLATES_REF:-}" ] && printf ' (RIG_TEMPLATES_REF)' || printf ' (the in-tree pin)')"
  fi
}

# The snapshot path is derived from this library's installed tree. Its
# pin-bearing directory name is the staleness guard: an older snapshot is
# invisible after a pin bump. A usable registry has at least one definition;
# an empty directory means an interrupted extraction and falls through to the
# same live fetch as an absent snapshot.
templates_snapshot_dir() {
  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s/templates@%s' "$(cd "$lib_dir/../.." && pwd)" "$RIG_TEMPLATES_PIN"
}

templates_snapshot_usable() {
  local snapshot role_env
  snapshot="$(templates_snapshot_dir)"
  [ -d "$snapshot" ] || return 1
  role_env="$(find "$snapshot" -mindepth 2 -maxdepth 2 -type f -name template.env -print -quit 2>/dev/null)"
  [ -n "$role_env" ]
}

# templates_resolve — resolve the knobs to a LOCAL directory holding
# the registry, left in the REGISTRY_DIR global (a global, not stdout: a
# $(…) call site would run the fetch in a subshell and lose TEMPLATES_TMP,
# the path the caller's cleanup trap must rm). RIG_TEMPLATES_DIR wins and is
# used as-is; otherwise the repo@ref tarball is fetched and extracted under
# a temp dir, recorded in TEMPLATES_TMP. Candidate URLs follow install.sh's
# precedence — a tag outranks a branch that shares its name — plus the bare
# archive/<ref> form, which is how a commit-SHA pin (the default) downloads.
# Failure lists every URL tried: the fetch is unauthenticated by contract
# (a tenant is converged by hand from a root shell in the guest, holding
# nothing), so "is the repo public and the ref real" is the whole diagnosis.
TEMPLATES_TMP=""
# shellcheck disable=SC2034  # REGISTRY_DIR is this function's OUTPUT, read by the sourcing script
REGISTRY_DIR=""
templates_resolve() {
  local repo ref url got=""
  if [ -n "${RIG_TEMPLATES_DIR:-}" ]; then
    [ -d "$RIG_TEMPLATES_DIR" ] || {
      printf 'RIG_TEMPLATES_DIR is not a directory: %s\n' "$RIG_TEMPLATES_DIR" >&2
      return 1
    }
    REGISTRY_DIR="$RIG_TEMPLATES_DIR"
    return 0
  fi
  if [ -z "${RIG_TEMPLATES_REF:-}" ] && templates_snapshot_usable; then
    REGISTRY_DIR="$(templates_snapshot_dir)"
    return 0
  fi
  repo="${RIG_TEMPLATES_REPO:-heavy-duty/rig-templates}"
  ref="${RIG_TEMPLATES_REF:-$RIG_TEMPLATES_PIN}"
  command -v curl >/dev/null 2>&1 || { printf 'curl is required to fetch the template registry\n' >&2; return 1; }
  command -v tar  >/dev/null 2>&1 || { printf 'tar is required to extract the template registry\n' >&2; return 1; }
  TEMPLATES_TMP="$(mktemp -d)"
  for url in \
    "https://github.com/$repo/archive/refs/tags/$ref.tar.gz" \
    "https://github.com/$repo/archive/refs/heads/$ref.tar.gz" \
    "https://github.com/$repo/archive/$ref.tar.gz"; do
    if curl -fsSL "$url" -o "$TEMPLATES_TMP/templates.tar.gz" 2>/dev/null; then got="$url"; break; fi
  done
  if [ -z "$got" ]; then
    printf 'cannot fetch the template registry %s@%s — tried:\n' "$repo" "$ref" >&2
    printf '  https://github.com/%s/archive/refs/tags/%s.tar.gz\n' "$repo" "$ref" >&2
    printf '  https://github.com/%s/archive/refs/heads/%s.tar.gz\n' "$repo" "$ref" >&2
    printf '  https://github.com/%s/archive/%s.tar.gz\n' "$repo" "$ref" >&2
    printf 'the fetch is unauthenticated by contract (a mint holds no credentials): the repo must be public and the ref must exist. RIG_TEMPLATES_DIR=<dir> bypasses the fetch.\n' >&2
    return 1
  fi
  tar -xzf "$TEMPLATES_TMP/templates.tar.gz" -C "$TEMPLATES_TMP" || {
    printf 'cannot extract the registry tarball from %s\n' "$got" >&2
    return 1
  }
  # A GitHub archive holds exactly one top-level directory (<repo>-<ref>,
  # slashes flattened) — assert that shape instead of assuming the name.
  set -- "$TEMPLATES_TMP"/*/
  { [ $# -eq 1 ] && [ -d "$1" ]; } || {
    printf 'the registry tarball from %s does not hold exactly one top-level directory\n' "$got" >&2
    return 1
  }
  # shellcheck disable=SC2034  # the function's output global, read by the sourcing script
  REGISTRY_DIR="${1%/}"
}

# templates_roles <registry-dir> — the roles a registry defines: its
# immediate subdirectories that carry a template.env. This list IS the
# unknown-role refusal's body, so it reflects what the resolved source
# actually contains — never a hardcoded set.
templates_roles() {
  local d
  for d in "$1"/*/; do
    [ -f "$d/template.env" ] || continue
    basename "$d"
  done
}

# template_family <role> — directory names are the registry's family tag.
# workstation is the one intentional suffix-less machine role (#152 / epic D5).
template_family() {
  case "$1" in
    *-box) printf 'tenant\n' ;;
    *-server|workstation) printf 'machine\n' ;;
    *) return 1 ;;
  esac
}

# templates_machine_roles <registry-dir> — only machine definitions, for the
# machine bootstrap's unknown-role refusal.
templates_machine_roles() {
  local role
  while IFS= read -r role; do
    [ "$(template_family "$role" 2>/dev/null || true)" = "machine" ] || continue
    printf '%s\n' "$role"
  done < <(templates_roles "$1")
}

# template_parse_env <template.env> — parse against the allowlist. Sets
# TPL_USER, TPL_CONTEXT_PATH, TPL_CLI_NAME, TPL_CLI_SRC, TPL_PATH_LINE,
# TPL_AGENT (default yes), TPL_HARDEN_SSHD (default no), TPL_NEEDS_NODE
# (default no), TPL_APT_EXTRAS, TPL_SWAP_SIZE (default empty: no swap
# change). Every refusal names the
# failing key (or line): the box.env discipline — a definition is data, and
# bad data is refused loudly, never executed to find out.
# shellcheck disable=SC2034  # the TPL_* globals are this function's OUTPUT, read by the sourcing script
template_parse_env() {
  local file="$1" line key val n=0 seen=" " k ok
  TPL_USER="" TPL_CONTEXT_PATH="" TPL_CLI_NAME="" TPL_CLI_SRC=""
  TPL_PATH_LINE="" TPL_AGENT="yes" TPL_HARDEN_SSHD="no"
  TPL_NEEDS_NODE="no" TPL_APT_EXTRAS="" TPL_SWAP_SIZE=""
  [ -f "$file" ] || { printf 'template.env missing: %s\n' "$file" >&2; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1))
    case "$line" in ''|'#'*) continue ;; esac
    if [[ ! "$line" =~ ^([A-Z_]+)=\"(.*)\"$ ]]; then
      printf 'template.env:%d: not KEY="value": %s\n' "$n" "$line" >&2
      return 1
    fi
    key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
    ok=""
    for k in "${TEMPLATE_KEYS_REQUIRED[@]}" "${TEMPLATE_KEYS_OPTIONAL[@]}"; do
      [ "$key" = "$k" ] && ok=1
    done
    [ -n "$ok" ] || { printf 'template.env:%d: unknown key: %s (allowed: %s %s)\n' \
      "$n" "$key" "${TEMPLATE_KEYS_REQUIRED[*]}" "${TEMPLATE_KEYS_OPTIONAL[*]}" >&2; return 1; }
    case "$seen" in *" $key "*)
      printf 'template.env:%d: duplicate key: %s\n' "$n" "$key" >&2; return 1 ;;
    esac
    seen="$seen$key "
    case "$key" in
      USER)         TPL_USER="$val" ;;
      AGENT)        TPL_AGENT="$val" ;;
      HARDEN_SSHD)  TPL_HARDEN_SSHD="$val" ;;
      CONTEXT_PATH) TPL_CONTEXT_PATH="$val" ;;
      CLI_NAME)     TPL_CLI_NAME="$val" ;;
      CLI_SRC)      TPL_CLI_SRC="$val" ;;
      PATH_LINE)    TPL_PATH_LINE="$val" ;;
      NEEDS_NODE)   TPL_NEEDS_NODE="$val" ;;
      APT_EXTRAS)   TPL_APT_EXTRAS="$val" ;;
      SWAP_SIZE)    TPL_SWAP_SIZE="$val" ;;
    esac
  done < "$file"
  for k in "${TEMPLATE_KEYS_REQUIRED[@]}"; do
    case "$seen" in *" $k "*) ;; *)
      printf 'template.env: missing required key: %s\n' "$k" >&2; return 1 ;;
    esac
  done
  case "$TPL_AGENT" in
    yes|no) ;;
    *) printf 'template.env: AGENT: want yes or no, got: %s\n' "$TPL_AGENT" >&2; return 1 ;;
  esac
  case "$TPL_HARDEN_SSHD" in
    yes|no) ;;
    *) printf 'template.env: HARDEN_SSHD: want yes or no, got: %s\n' "$TPL_HARDEN_SSHD" >&2; return 1 ;;
  esac
  if [ "$TPL_AGENT" = "yes" ]; then
    for k in CONTEXT_PATH CLI_NAME PATH_LINE; do
      case "$seen" in *" $k "*) ;; *)
        printf 'template.env: missing required key: %s\n' "$k" >&2; return 1 ;;
      esac
    done
  else
    for k in "${TEMPLATE_AGENT_KEYS[@]}"; do
      case "$seen" in *" $k "*)
        printf 'template.env: %s: not allowed when AGENT=no\n' "$k" >&2; return 1 ;;
      esac
    done
  fi
  # Value shapes — each refusal names its key. USER shares the charset the
  # users file enforces (a leading '-' reads as a usermod flag; '|', ':'
  # corrupt things downstream).
  [[ "$TPL_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
    || { printf 'template.env: USER: invalid user name: %s (want ^[a-z_][a-z0-9_-]{0,31}$)\n' "$TPL_USER" >&2; return 1; }
  if [ "$TPL_AGENT" = "yes" ]; then
    case "$TPL_CONTEXT_PATH" in
      /*|*..*|'') printf 'template.env: CONTEXT_PATH: must be relative to the tenant home, without "..": %s\n' "$TPL_CONTEXT_PATH" >&2; return 1 ;;
    esac
    [[ "$TPL_CLI_NAME" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
      || { printf 'template.env: CLI_NAME: not a sane command name: %s\n' "$TPL_CLI_NAME" >&2; return 1; }
    # A literal '~/' on purpose (SC2088): the value is DATA — the mechanism
    # expands it to the tenant home by string substitution, never the shell.
    # shellcheck disable=SC2088
    case "$TPL_CLI_SRC" in
      *..*) printf 'template.env: CLI_SRC: must not contain "..": %s\n' "$TPL_CLI_SRC" >&2; return 1 ;;
      ''|'~/'*|/*) ;;
      *) printf 'template.env: CLI_SRC: must be absolute or ~/-relative: %s\n' "$TPL_CLI_SRC" >&2; return 1 ;;
    esac
    case "$TPL_NEEDS_NODE" in
      yes|no) ;;
      *) printf 'template.env: NEEDS_NODE: want yes or no, got: %s\n' "$TPL_NEEDS_NODE" >&2; return 1 ;;
    esac
    [ -n "$TPL_PATH_LINE" ] \
      || { printf 'template.env: PATH_LINE: must not be empty\n' >&2; return 1; }
  fi
  # Every word must be a sane package name — the list is handed to apt-get
  # unquoted by design, and this is what keeps an option ('-o …') or a path
  # from riding in through the data file.
  local pkg
  for pkg in $TPL_APT_EXTRAS; do
    [[ "$pkg" =~ ^[a-z0-9][a-z0-9.+-]*$ ]] \
      || { printf 'template.env: APT_EXTRAS: not a sane package name: %s\n' "$pkg" >&2; return 1; }
  done
  # SWAP_SIZE reaches fallocate as one quoted argument, and only after this
  # gate: a number and a unit, M or G, inside 256M..64G. Empty means unset.
  if [ -n "$TPL_SWAP_SIZE" ]; then
    swap_size_bytes "$TPL_SWAP_SIZE" >/dev/null \
      || { printf 'template.env: SWAP_SIZE: want a size from 256M to 64G (a number then M or G), got: %s\n' "$TPL_SWAP_SIZE" >&2; return 1; }
  fi
}

# swap_size_bytes <size> — the byte count of a SWAP_SIZE value, on stdout, or
# return 1 when the value is not a number followed by M or G within 256M..64G
# (fallocate -l reads M and G as MiB and GiB). The parser's gate and the
# swap converger's size comparison share this one reading of the value. The
# digit cap keeps the arithmetic far from overflow.
SWAP_SIZE_MIN_MIB=256
SWAP_SIZE_MAX_MIB=65536
swap_size_bytes() {
  local n unit mib
  [[ "${1:-}" =~ ^([1-9][0-9]{0,5})([MG])$ ]] || return 1
  n="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]}"
  case "$unit" in
    M) mib=$((10#$n)) ;;
    G) mib=$((10#$n * 1024)) ;;
  esac
  [ "$mib" -ge "$SWAP_SIZE_MIN_MIB" ] && [ "$mib" -le "$SWAP_SIZE_MAX_MIB" ] || return 1
  printf '%s\n' "$((mib * 1024 * 1024))"
}

# machine_template_parse_env <template.env> — the fleet-machine traits schema.
# The globals match bootstrap's table columns so a definition becomes a table
# row without changing any downstream trait behavior.
# shellcheck disable=SC2034
machine_template_parse_env() {
  local file="$1" line key val n=0 seen=" " k ok
  TPL_ROOT_DOOR="" TPL_HOST="" TPL_JOIN=""
  [ -f "$file" ] || { printf 'template.env missing: %s\n' "$file" >&2; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1))
    case "$line" in ''|'#'*) continue ;; esac
    if [[ ! "$line" =~ ^([A-Z_]+)=\"(.*)\"$ ]]; then
      printf 'template.env:%d: not KEY="value": %s\n' "$n" "$line" >&2
      return 1
    fi
    key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
    ok=""
    for k in "${MACHINE_KEYS_REQUIRED[@]}"; do
      [ "$key" = "$k" ] && ok=1
    done
    [ -n "$ok" ] || {
      printf 'template.env:%d: unknown key: %s (allowed: %s)\n' \
        "$n" "$key" "${MACHINE_KEYS_REQUIRED[*]}" >&2
      return 1
    }
    case "$seen" in *" $key "*)
      printf 'template.env:%d: duplicate key: %s\n' "$n" "$key" >&2
      return 1 ;;
    esac
    seen="$seen$key "
    case "$key" in
      ROOT_DOOR) TPL_ROOT_DOOR="$val" ;;
      HOST)      TPL_HOST="$val" ;;
      JOIN)      TPL_JOIN="$val" ;;
    esac
  done < "$file"
  for k in "${MACHINE_KEYS_REQUIRED[@]}"; do
    case "$seen" in *" $k "*) ;; *)
      printf 'template.env: missing required key: %s\n' "$k" >&2
      return 1 ;;
    esac
  done
  case "$TPL_ROOT_DOOR" in
    open|closed) ;;
    *) printf 'template.env: ROOT_DOOR: want open or closed, got: %s\n' "$TPL_ROOT_DOOR" >&2; return 1 ;;
  esac
  case "$TPL_HOST" in
    yes|no) ;;
    *) printf 'template.env: HOST: want yes or no, got: %s\n' "$TPL_HOST" >&2; return 1 ;;
  esac
  case "$TPL_JOIN" in
    authkey|login) ;;
    *) printf 'template.env: JOIN: want authkey or login, got: %s\n' "$TPL_JOIN" >&2; return 1 ;;
  esac
}

# render_tenant_context <role> <creds.md> — the agent-context file's
# content, on stdout: the one file every agent reads before touching
# anything. The skeleton is MECHANISM and lives here once — the box#80 guard
# note ("never run box setup-host or the drill inside a box; the box you are
# in is not a host you own") must never be copy-pasted per template again —
# and only the creds paragraph is per-vendor DATA, spliced in from the
# definition's creds.md.
render_tenant_context() {
  local role="$1" creds_file="$2"
  cat <<EOF
# You are running inside a box (tenant: ${role})

A box is a trust-less, network-isolated, ephemeral VM created by the
\`box\` CLI. Keep this context in mind:

$(cat "$creds_file")
- **Isolated.** The box reaches the public internet but nothing on the host or
  local network. There is no inbound path.
- **Disposable.** Nothing here is backed up. State is discarded when the box is
  removed; the operator persists work via git push and via \`box snapshot\`.
- **Not a host you own.** Never run \`box setup-host\`, \`box teardown-host\`,
  or the drill inside a box. The box you are in is not a host you own: a
  nested box stack claims the guest's own uplink subnet and gateway, and
  silently breaks this box's networking with intermittent egress blackouts
  (heavy-duty/box#80). Working ON the box repo from in here is fine — editing
  and testing never needs the host stack; host setup belongs to the operator's
  machine, never this one.
- **Bootstrap runbook.** If the repository you are working in contains a
  \`.box/\` folder (older repos may use \`.claudebox/\`), read it as your setup
  runbook — how to install dependencies, start services, template environment
  files, seed data, and smoke-test — and follow it. It is documentation for
  you, not a script the host runs.
EOF
}

# template_lint <role-dir> — the whole-definition check the registry repo's
# CI runs on every PR (rig defines what a valid template is; rig-templates
# CI enforces it, so a broken definition is refused before it can reach a
# mint). Same parser the mint runs — the two gates are not redundant: CI
# protects the registry, the mint-time parse protects a mint served through
# RIG_TEMPLATES_REPO/_DIR that CI never saw.
template_lint() {
  local dir="${1%/}" role family
  role="$(basename "$dir")"
  [ -d "$dir" ] || { printf '%s: not a directory\n' "$dir" >&2; return 1; }
  family="$(template_family "$role" 2>/dev/null || true)"
  [ -n "$family" ] || {
    printf '%s: role directories carry a family suffix (-box for box tenants, -server for fleet machines — rig#76; workstation is #152 machine carve-out)\n' "$role" >&2
    return 1
  }
  if [ "$family" = "tenant" ]; then
    template_parse_env "$dir/template.env" || return 1
    if [ "$TPL_AGENT" = "yes" ]; then
      [ -s "$dir/install.sh" ] \
        || { printf '%s: install.sh missing or empty\n' "$role" >&2; return 1; }
      head -n1 "$dir/install.sh" | grep -q '^#!' \
        || { printf '%s: install.sh has no shebang\n' "$role" >&2; return 1; }
      grep -q '[^[:space:]]' "$dir/creds.md" 2>/dev/null \
        || { printf '%s: creds.md missing or blank (the context renderer splices it in — a blank paragraph would ship a context file with a hole)\n' "$role" >&2; return 1; }
    else
      { [ ! -e "$dir/creds.md" ] && [ ! -L "$dir/creds.md" ]; } \
        || { printf '%s: creds.md is not allowed when AGENT=no\n' "$role" >&2; return 1; }
      if [ -e "$dir/install.sh" ]; then
        [ -s "$dir/install.sh" ] \
          || { printf '%s: install.sh is empty\n' "$role" >&2; return 1; }
        head -n1 "$dir/install.sh" | grep -q '^#!' \
          || { printf '%s: install.sh has no shebang\n' "$role" >&2; return 1; }
      fi
    fi
  else
    machine_template_parse_env "$dir/template.env" || return 1
    [ ! -e "$dir/creds.md" ] \
      || { printf '%s: creds.md is not allowed for machine roles (machines render no tenant context)\n' "$role" >&2; return 1; }
    if [ -e "$dir/install.sh" ]; then
      [ -s "$dir/install.sh" ] \
        || { printf '%s: install.sh is empty\n' "$role" >&2; return 1; }
      head -n1 "$dir/install.sh" | grep -q '^#!' \
        || { printf '%s: install.sh has no shebang\n' "$role" >&2; return 1; }
    fi
  fi
  return 0
}
