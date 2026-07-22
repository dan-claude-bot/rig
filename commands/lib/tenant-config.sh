#!/usr/bin/env bash
# Shared parameters for the box TENANT roles (claude-box, codex-box, grok-box,
# kimi-box, staging-box) — the '-box' suffix names the FAMILY (a guest a box mints, vs the
# '-server' machine roles rig converges); see #76.
# sourced by bootstrap-tenant.sh and by the test harness. Pure text→text, no
# side effects: the per-tenant differences live HERE, in one table, so the
# mechanism stays one script parameterized per tenant instead of four
# hand-maintained copies (repo precedent: parse_users_file, runner-config).

# tenant_user <role> — the user the box seed creates (box.env BOX_USER). The
# agent tenants are named after their agent (minus the suffix — the USER is not
# the role); staging-box keeps box#69's `ops`.
tenant_user() {
  case "$1" in
    claude-box)  printf 'claude' ;;
    codex-box)   printf 'codex' ;;
    grok-box)    printf 'grok' ;;
    kimi-box)    printf 'kimi' ;;
    staging-box) printf 'ops' ;;
    *) return 1 ;;
  esac
}

# tenant_context_path <role> <home> — where the agent-context file lands. Each
# agent CLI reads its own instructions file from its own dotdir (named for the
# agent, not the role — the dotdir is the CLI's, and the suffix is rig's);
# staging-box has no agent and no context file (return 1).
tenant_context_path() {
  case "$1" in
    claude-box) printf '%s/.claude/CLAUDE.md' "$2" ;;
    codex-box)  printf '%s/.codex/AGENTS.md' "$2" ;;
    grok-box)   printf '%s/.grok/AGENTS.md' "$2" ;;
    # kimi documents only PROJECT-level AGENTS.md today (no global file); its
    # dotdir is ~/.kimi (config.toml, sessions/, credentials/). The context
    # file lands at the <dotdir>/AGENTS.md convention the other CLIs converged
    # on, so it is where an operator (or a future global-read) will look — an
    # honest placement, not a claim that the CLI auto-loads it.
    kimi-box)   printf '%s/.kimi/AGENTS.md' "$2" ;;
    *) return 1 ;;
  esac
}

# render_tenant_context <role> — the agent-context file's content, on stdout.
# One renderer for all four agents: only the creds paragraph is per-vendor,
# and the box#80 guard note lives HERE once — never copy-pasted per template.
# staging-box renders nothing (return 1): no agent lives there.
render_tenant_context() {
  local role="$1" creds
  # The single-quoted markdown below carries literal `$`-free backtick prose;
  # single quotes are deliberate — nothing in it may expand here.
  # shellcheck disable=SC2016
  case "$role" in
    claude-box)
      creds='- **Creds-free by default.** The box starts with no Claude and no git
  credentials. If you need to authenticate Claude, the operator runs `/login`
  interactively. For git, the operator adds their own credentials (a PAT or
  `gh auth login`). Never assume credentials are present; never ask for or
  store secrets on disk beyond what the operator sets up.' ;;
    codex-box)
      creds='- **Creds-free by default.** The box starts with no OpenAI and no git
  credentials. If you need to authenticate Codex, the operator runs the
  login flow (`codex`) interactively. For git, the operator adds their own
  credentials (a PAT or `gh auth login`). Never assume credentials are
  present; never ask for or store secrets on disk beyond what the operator
  sets up.' ;;
    grok-box)
      creds='- **Creds-free by default.** The box starts with no xAI and no git
  credentials. If you need to authenticate, the operator runs
  `grok login` interactively (SuperGrok / X Premium+). For git, the
  operator adds their own credentials (a PAT or `gh auth login`). Never
  assume credentials are present; never ask for or store secrets on disk
  beyond what the operator sets up.' ;;
    kimi-box)
      creds='- **Creds-free by default.** The box starts with no Moonshot and no git
  credentials. If you need to authenticate, the operator runs `kimi` and
  its `/login` flow interactively (Kimi Code OAuth, or an API key). For
  git, the operator adds their own credentials (a PAT or `gh auth login`).
  Never assume credentials are present; never ask for or store secrets on
  disk beyond what the operator sets up.' ;;
    *) return 1 ;;
  esac
  cat <<EOF
# You are running inside a box (tenant: ${role})

A box is a trust-less, network-isolated, ephemeral VM created by the
\`box\` CLI. Keep this context in mind:

${creds}
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
