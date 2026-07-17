#!/usr/bin/env bash
# Shared reader for the runner's own on-disk config ($RUNNER_DIR/.runner).
# Sourced by the runner-* commands; never executed on its own.

# .runner is JSON, parsed here with grep/sed on purpose: a rig-bootstrapped box
# has no jq, and installing one to read two fields would be a poor trade.
#
# json_field <file> <key> — the first string value for <key>, empty if absent.
# Never fails: callers run under `set -e` with pipefail, where a grep that
# matches nothing would otherwise kill the script with no message. A missing
# key is a fact to test for, not an error to die on.
json_field() {
  grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" 2>/dev/null \
    | head -n1 | sed 's/.*:[[:space:]]*"//; s/"$//' || true
}

# json_string_array <file> <key> — the elements of the FIRST array named <key>,
# one per line, empty when the key is absent or the array is empty.
#
# json_field's sibling for the one shape it cannot read: `.Self.Tags` from
# `tailscale status --json` is a JSON array, and bootstrap must assert on it to
# learn the tag control actually GRANTED the node (the netmap's ground truth),
# not the tag rig requested. Same grep/sed spirit, same jq-free reason: a
# rig-bootstrapped box has no jq and we will not install one to read one field.
#
# `tr -d '\n'` first, because tailscale pretty-prints its JSON and an array
# spans lines — grep is line-oriented and would never see `[ ... ]` whole
# otherwise. `\[[^]]*\]` then captures the first flat array body for <key>
# (tag strings never contain `]`, so this is safe); the inner `grep -o` pulls
# every quoted token out of it, and `sed 1d` drops the key's own name — which
# `"key":[...]` leads with — leaving just the elements.
#
# FIRST array wins by design, and the caller leans on it: `tailscale status
# --json` emits Self before Peer (Go struct field order, stable), so the first
# "Tags" is the node's OWN, never a peer's. An absent key omits itself entirely
# (Go's omitempty) rather than emitting `[]` — which is exactly the untagged,
# user-owned node bootstrap must catch. Never fails under `set -e`+pipefail: a
# non-match is a fact to test for, like json_field, not a reason to die.
json_string_array() {
  tr -d '\n' < "$1" 2>/dev/null \
    | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\[[^]]*\]" \
    | head -n1 | grep -o '"[^"]*"' | sed '1d; s/^"//; s/"$//' || true
}

# runner_repo_url <runner_dir> — the repository this box's runner is registered
# to, empty when nothing is registered there.
runner_repo_url() {
  [ -e "$1/.runner" ] || return 0
  json_field "$1/.runner" gitHubUrl
}

# runner_agent_name <runner_dir> — the runner's name, empty when unregistered.
runner_agent_name() {
  [ -e "$1/.runner" ] || return 0
  json_field "$1/.runner" agentName
}

# assert_runner_repo <runner_dir> <owner/repo>
#
# Returns 0 when the box has no runner, or has one already registered to
# <owner/repo>: re-running `install` against the repo the box is already on is
# real convergence — it re-uses the binary, skips registration, exits 0.
#
# Returns 1, explaining itself on stderr, when the runner is registered to a
# DIFFERENT repo. Skipping *that* is not convergence, it is ignoring the
# argument: `install` would skip its configure step, restart the service on the
# OLD repo, and report success — leaving the repo you asked for with no runner
# and its jobs queued against one that will never come. Moving a runner between
# repos is a trust-boundary act, so it belongs to `repoint`, out loud.
assert_runner_repo() {
  local dir="$1" repo="$2" current wanted
  [ -e "$dir/.runner" ] || return 0

  current="$(runner_repo_url "$dir")"
  wanted="https://github.com/${repo}"

  if [ -z "$current" ]; then
    printf 'rig-runner: ERROR: %s\n' \
"${dir}/.runner exists but names no repository — this box's registration cannot
be read, so rig cannot tell whether it is already on ${wanted}.
Wipe the local registration and install again:
  rig runner remove --local" >&2
    return 1
  fi

  if [ "$current" = "$wanted" ]; then
    return 0
  fi

  printf 'rig-runner: ERROR: %s\n' \
"this box's runner is already registered to ${current}, not ${wanted}.
install will not move a runner between repositories: it would leave the service
running against the OLD repo and report success. To move it in one act:
  rig runner repoint --repo ${repo}
or take it off the old repo first, then install:
  rig runner remove             (deregisters from ${current}; needs a removal token)
  rig runner remove --local     (when you cannot mint one)" >&2
  return 1
}
