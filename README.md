# rig

A CLI that turns a **pristine Debian server into a hardened, tailnet-joined
node** — one curl, one command. A second command installs a version-pinned
Coolify on a control-plane box.

Philosophy (shared with [claudebox](https://github.com/heavy-duty/claudebox)):
**public tool, private state**. rig carries plumbing logic only — no
hostnames, no bindings, no secrets, nothing about *your* infrastructure. It
takes arguments, does its work, and stores no credential, ever.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/heavy-duty/rig/main/install.sh | bash
```

Installs the tree to `~/.local/share/rig` and links `rig` onto your
PATH (`/usr/local/bin` when root). Re-run any time to upgrade.

## Commands

### `rig bootstrap <control-plane|workload>`

Run as root on the fresh box (over SSH). Convergent — safe to re-run; a
second run changes nothing.

```sh
rig bootstrap control-plane --hostname my-coolify-box
rig bootstrap workload --hostname my-prod-box
```

- `--hostname <name>` — tailnet hostname (default: the role name)
- `--ts-tag <tag>` — tailnet tag to advertise (default: `tag:server`)

What it does: installs `curl ca-certificates unattended-upgrades` (and
enables periodic unattended upgrades); writes an sshd hardening drop-in
(`PermitRootLogin prohibit-password`, `PasswordAuthentication no`); installs
tailscale and joins your tailnet.

**The pre-auth key:** provide it via the `TS_AUTHKEY` env var or type it at
the interactive prompt. Use a **single-use, tagged, short-expiry** key. It
lives in process memory only — rig never writes a credential to disk.

The two roles are identical today except the default hostname; they exist
because control-plane and workload boxes diverge over time, and because the
next command applies to exactly one of them.

### `rig coolify install --version <pin>`

Control-plane box only. Installs Coolify at exactly the pinned version with
`AUTOUPDATE=false` — your deploy tooling is verified against an API surface;
the platform must never move underneath it on its own. Upgrading is an
explicit re-run with a new pin. The pin is required; there is no default.

### `rig runner install --repo <owner/repo> --version <pin>`

Workload box only, run after `rig bootstrap workload`:

```sh
rig bootstrap workload --hostname my-ci-box --ts-tag tag:ci
rig runner install --repo acme/widgets --version 2.335.1
```

Installs GitHub's official `actions/runner` as a systemd service under an
unprivileged user (default `github-runner`, created if absent, never root, no
supplementary groups). The runner is an agent, not a server: it long-polls
GitHub outbound and receives jobs down that already-established connection,
so it needs **zero inbound ports** and works fine behind a deny-all
firewall — it can even trigger deploys on hosts only it can reach, like a
tailnet-only control plane.

No Docker, deliberately: the Docker socket is a root API and `docker` group
membership is root-equivalent, which is a gratuitous path to root on a box
whose whole point is a narrow blast radius. Add Docker only once a job
genuinely needs it, and rethink the isolation model then.

- `--name <name>` — runner name (default: this host's hostname)
- `--labels <csv>` — runner labels, replacing the `ci-runner` default — keep
  any label your workflows' `runs-on` needs (GitHub adds `self-hosted` itself)
- `--user <name>` — the unprivileged service user (default: `github-runner`)

**The registration token:** provide it via the `RUNNER_TOKEN` env var or type
it at the interactive prompt. It's short-lived, consumed at registration, and
never written to disk by rig.

The version pin is required, same as `coolify install` — but unlike Coolify,
the installed runner **self-updates**: GitHub refuses jobs from stale
runners, so freezing the version would just make it silently stop taking
work. The pin states what you install today; GitHub owns the treadmill after
that.

Convergent — safe to re-run; an already-registered runner is left alone.

## What rig deliberately does NOT do

- **Provider firewalls** — Docker publishes ports past host firewalls, so
  the real boundary is your cloud provider's firewall, configured outside
  this tool.
- **Fetch your config** — boxes never receive repo credentials. Everything
  rig needs arrives as arguments or an interactive prompt.
- **Manage deployments** — deploy manifests/executors are separate concerns.
  (Planned: the `apply`/`diff` executor half joins rig as commands that
  run on operator machines, never on boxes.)

## Testing

`bash test/cli.sh` (dependency-free assertions) + shellcheck run in CI. The
end-to-end rehearsal is a throwaway VM/container: pristine Debian → install →
`bootstrap workload` with a real single-use key → assert the sshd drop-in,
tailnet join, and a no-op second run → destroy, remove the node from the
tailnet.
