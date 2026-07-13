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
