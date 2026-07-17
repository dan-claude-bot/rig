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

### `rig bootstrap <control-plane|workload|runner>`

Run as root on the fresh box (over SSH). Convergent — safe to re-run; a
second run changes nothing.

```sh
rig bootstrap control-plane --hostname my-coolify-box
rig bootstrap workload --hostname my-prod-box
rig bootstrap runner --hostname my-ci-box
```

- `--hostname <name>` — tailnet hostname (default: the role name)
- `--ts-tag <tag>` — tailnet tag to advertise (default: `tag:server`;
  the `runner` role defaults to `tag:ci` instead, and **refuses**
  `tag:server` outright — see below)
- `--admin-user <name>` — non-root admin account to create on every role
  (default: `admin`; **refuses `root`**). See [The admin user](#the-admin-user).
- `--admin-key <pubkey>` — an extra public key to add to the admin account at
  creation, composed with the seed-from-root below (optional).
- `--lock-root` — close root's SSH door (`PermitRootLogin no`). **Role-gated**:
  refused on `control-plane` and `workload`, allowed on `runner`. See
  [The role-aware root door](#the-role-aware-root-door).

What it does: installs `curl ca-certificates unattended-upgrades sudo openssh-server`
(and enables periodic unattended upgrades); writes an sshd hardening drop-in
(`PermitRootLogin prohibit-password`, `PasswordAuthentication no`) and
**verifies it took effect** via `sshd -T`; creates a non-root **admin user**;
optionally **closes root's SSH door** on roles where that is safe; sets the
system hostname; installs tailscale and joins your tailnet.

#### The admin user

rig hardens the SSH door but, until now, never created a human to walk through
it — every box was administered as `root`, survivable only because of the
`prohibit-password` drop-in. `bootstrap` now creates a non-root **admin user**
on **every** role (`control-plane` included, where root's door stays open):

- In the **`sudo` group, never `docker`** — no supplementary group beyond
  `sudo`. The docker socket is a root API and `docker`-group membership is
  root-equivalent, the same gratuitous path to root `runner install` refuses.
- **Passwordless (`NOPASSWD`) sudo.** The admin authenticates with an SSH key it
  holds and has no password, so a sudo *password* it does not have would make
  sudo unusable — a non-root user who cannot escalate is not an admin. Key-only
  login + `NOPASSWD` sudo is exactly what Debian/Ubuntu cloud images do for their
  default user. (This is the same `NOPASSWD` the docs warn against for *Coolify's*
  service user — the difference is who holds the account: a human you are
  empowering vs. a non-human identity you are trying to constrain.)
- **Its `authorized_keys` is seeded once from root's, at creation.** You are
  connected as `root` **right now** using one of root's keys, so copying them
  into the admin account is **live proof the matching private key is in your
  hands** — strictly better than any check rig could invent, and a public key is
  not a secret, so "no credential, ever" does not bend. `--admin-key` composes
  with the seed to add an explicit key.

> **Seed-once is a deliberate, honest exception to convergence.** Re-seeding on
> every run would resurrect a key you *deliberately removed* from the admin
> account. So rig seeds **only at creation** and leaves an existing admin user
> (and its keys) completely untouched on re-run. Two caveats it handles or names:
> Coolify writes its **own** key into root's `authorized_keys` when it registers a
> server, and a blind copy would hand the admin account to Coolify's key — audit
> the seeded file on Coolify roles. And cloud images can carry `command=`/`from=`
> forced-command or source restrictions on a key; rig **skips** obviously
> restricted lines while seeding and warns, rather than let a restriction silently
> follow to the admin (re-add it with `--admin-key` if it was intended).

#### The role-aware root door

"Lock root" sounds like one action. It is **four**, and they do not behave
alike — measured empirically against a live sshd (OpenSSH 10 / Debian 13), not
inferred from hardening guides:

| Technique | Key-based root SSH after | Verdict |
|---|---|---|
| `passwd -l root` (shadow → `!*`) | ✅ still works | **harmless** — locking a *password* is not disabling an account; near no-op on cloud images where root already has `*` |
| `PermitRootLogin prohibit-password` | ✅ works | **safe — what rig does by default** |
| `usermod --expiredate 1 root` | ❌ PAM denies | **breaks** |
| root shell → `/usr/sbin/nologin` | ❌ denied | **breaks** (and `chsh` then fails too — recover with `usermod -s /bin/bash root`) |
| **`PermitRootLogin no`** | ❌ denied | **the only technique `--lock-root` uses** |

So `--lock-root` means **exactly `PermitRootLogin no`** — never
`usermod --expiredate` or a nologin shell. Those don't just break interactive
root; they break **rig's own convergence**, since rig is run as root over SSH and
a re-run to pick up a fix would find the door bolted from a direction sshd cannot
reopen. `PermitRootLogin no` leaves the account intact and reopenable by deleting
one drop-in. (rig's default `PermitRootLogin prohibit-password` already means
key-only root with **no password surface**, so `passwd -l root` would buy
approximately nothing on top of it — rig does not bother.)

Whether root's door *may* close is **per role**, because the constraint is real
only where something depends on it:

| Role | Root SSH | `--lock-root` | Why |
|---|---|---|---|
| `control-plane` | **must stay** | **refused (exit 2)** | Coolify SSHes to its **own** host (`host.docker.internal`); non-root localhost is unsupported upstream ([coolify#4245](https://github.com/coollabsio/coolify/issues/4245)). A uniform lock-root would cut the control plane off from itself. |
| `workload` | stays by default | **refused (exit 2)** | Closing it needs Coolify's **experimental** non-root mode — a `coolify` user with `NOPASSWD: ALL` (root by another name) that rig does not provision. Attribution is cheaper via sshd key-fingerprint logging + `auditd`. Revisitable. |
| `runner` | may close | **allowed** | No Coolify involved. |

The refusals are **hard errors (exit 2)**, not warnings — the same spirit as
`runner` refusing `tag:server`. A flag that silently bricks a box's only door is
worse than no flag. (The `dev` role from #12 does not exist on `main` yet; when
it lands it joins `runner` as a lockable role.)

**The lockout problem — verified before the door closes.** Closing root on a box
whose admin key does not actually work means rescue mode. So before it writes
`PermitRootLogin no`, rig verifies **locally** that the admin is reachable, and if
**any** check fails the **door stays open** and rig says which one:

1. the account exists and is not expired/disabled (an expired account is refused
   by PAM — a *locked password* is fine, key auth is unaffected);
2. it has a real login shell (not `nologin`/`false`);
3. `authorized_keys` is non-empty with sane ownership and perms (sshd silently
   ignores a group/world-writable keys file);
4. `sudo -n true` succeeds under `runuser -u <admin>`;
5. `sshd -T -C user=<admin>` resolves to something that **permits** the login —
   an `AllowUsers`/`AllowGroups`/`DenyUsers`/`Match` block elsewhere can quietly
   exclude the admin even when the account is perfect.

What rig **cannot** verify is that you hold the admin's private key — which is
exactly why it seeds `authorized_keys` from root's (the key you are connected
with **right now**). The `PermitRootLogin no` drop-in is `00-rig-root.conf`,
which sorts **before** `00-rig.conf` on purpose (see the first-wins note below),
installed with the same validate-before-restart + `sshd -t` + rollback + `sshd -T`
effective-assert dance as the base drop-in. Reopening root later is a deliberate
manual act: `rm /etc/ssh/sshd_config.d/00-rig-root.conf && systemctl restart ssh`
— rig will not silently reopen it on a re-run without `--lock-root`.

**`--hostname` converges both names.** On a box that has already joined,
`bootstrap` skips `tailscale up` (so a re-run needs no pre-auth key) — but it
still reconciles the **tailnet** hostname via `tailscale set --hostname`. Without
that, a box which joined under the wrong name — say `--hostname` was omitted, so
it defaulted to the *role* — stayed misnamed forever, and re-running rig, the
documented repair, could not fix it. A machine you deliberately renamed in the
admin console keeps that name; rig will not fight it.

> **Why the drop-in is `00-rig.conf` and not `99-`.** `sshd_config` is
> **first-wins** — *"for each keyword, the first obtained value will be used"*
> (`sshd_config(5)`) — and `Include` expands its glob in lexical order. Cloud
> images ship `/etc/ssh/sshd_config.d/50-cloud-init.conf` carrying
> `PasswordAuthentication yes`, so a `99-` drop-in is read **second** and every
> keyword in it is silently discarded. This is the opposite of the
> last-wins convention most config systems use, and it shipped green here for
> a month: rig asserted the *file existed* rather than what `sshd` actually
> resolved, and the Incus rehearsal container has no cloud-init drop-in to
> lose to. Every Hetzner box rig had bootstrapped was still serving
> `passwordauthentication yes`. `bootstrap` now sweeps a stale `99-rig.conf`
> on re-run, and refuses to claim success unless `sshd -T` agrees.

**The pre-auth key:** provide it via the `TS_AUTHKEY` env var or type it at
the interactive prompt. Use a **single-use, tagged, short-expiry** key. It
lives in process memory only — rig never writes a credential to disk.

`control-plane` and `workload` are identical today except the default
hostname; they exist because the boxes diverge over time, and because each
follow-up command applies to exactly one role. `runner` is the box a CI
agent will live on, and it differs behaviorally: it defaults `--ts-tag` to
`tag:ci` and **refuses `tag:server`** — a runner executes repo-controlled
code, and advertising your server tag would extend every grant your servers
hold (SSH between them, say) to that code. The refusal turns the worst
misconfiguration from a documentation warning into a hard error.

### `rig coolify install --version <pin>`

Control-plane box only. Installs Coolify at exactly the pinned version with
`AUTOUPDATE=false` — your deploy tooling is verified against an API surface;
the platform must never move underneath it on its own. Upgrading is an
explicit re-run with a new pin. The pin is required; there is no default.

### `rig coolify backup install`

Control-plane box only. Installs a **nightly age-encrypted dump of Coolify's own
database** as a systemd timer.

```sh
rig coolify backup install
rig coolify backup install --schedule '*-*-* 02:30:00 UTC' --pg-container coolify-db
```

- `--schedule <OnCalendar>` — systemd calendar expression (default: `*-*-* 04:00:00 UTC`)
- `--pg-container` / `--pg-user` / `--pg-db` — Coolify's postgres (defaults: `coolify-db`,
  `coolify`, `coolify`)

That database holds the GitHub App private key, every registered server's SSH key,
and every environment value for every environment the control plane manages. It is
`pg_dump`ed straight into `age` — encrypted **client-side, on the box** — and only
then shipped to S3. The bucket is never trusted with plaintext.

It is **forensics, not a restore path.** A lost control plane is rebuilt fresh and
reconciled from your manifest, never restored from this artifact. Which is exactly
why the plumbing belongs in rig: there *will* be a next control-plane box, and it
should be backed up from birth rather than depending on someone remembering a
runbook step mid-incident.

**rig installs the machinery; you supply the bindings.** rig writes
`/etc/coolify-dump.env` **empty**, `0600`, and never reads it back — no credential
ever passes through rig. You fill in the age recipient (a *public* key), the S3
bucket + endpoint, and the S3 credentials. Until you do, the unit **fails loudly on
every run**: a silent backup is worse than a missing one.

rig cannot verify that the upload works — that needs your credentials. So prove it
by hand once, rather than letting the timer discover it at 04:00:

```sh
systemctl start coolify-dump.service
journalctl -u coolify-dump.service -n 20 --no-pager
```

A backup you have never read back is not yet a backup.

### `rig runner install --repo <owner/repo>`

Runner box only, run after `rig bootstrap runner` (the same two-step rhythm
as `bootstrap control-plane` → `coolify install`):

```sh
rig bootstrap runner --hostname my-ci-box
rig runner install --repo acme/widgets
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

- `--version <pin>` — actions/runner release to install (default: the
  latest release, resolved at install time; e.g. `--version 2.335.1` —
  the latest as of this writing). Pin it when you need a deterministic,
  auditable install.
- `--name <name>` — runner name (default: this host's hostname)
- `--labels <csv>` — runner labels, replacing the `ci-runner` default — keep
  any label your workflows' `runs-on` needs (GitHub adds `self-hosted` itself)
- `--user <name>` — the unprivileged service user (default: `github-runner`)

**The registration token:** provide it via the `RUNNER_TOKEN` env var or type
it at the interactive prompt. It's short-lived, consumed at registration, and
never written to disk by rig.

Why latest-by-default here when `coolify install` demands a pin: the two
tools age differently. Coolify never self-updates (`AUTOUPDATE=false`), so
its version is a contract your deploy tooling is verified against — stating
it is the point. The runner **self-updates regardless**: GitHub refuses jobs
from stale runners, so freezing it would just make it silently stop taking
work. The install-time version is a starting point either way; `--version`
exists for when you want that starting point deterministic and auditable.

Convergent **toward `--repo`** — re-running against the repo this box is
already on re-uses the binary, skips registration, and never asks for a token.
Pointed at a *different* repo it **refuses**, and names both: skipping there
would not be convergence, it would be ignoring the argument — restarting the
runner on the **old** repo while reporting success, leaving the repo you asked
for with no runner and its `runs-on` jobs queued forever. Moving a runner
between repos is a trust-boundary act; that verb is
[`rig runner repoint`](#rig-runner-repoint---repo-ownerrepo).

### `rig runner status`

```sh
rig runner status
```

What this box's runner is registered to — repo, runner name, labels,
install dir, systemd unit and its state. Reads the runner's own on-disk
config; no token, no network call. Exits 1 when no runner is installed.

The answer to "wait, which repo is this box wired to?" should not require
knowing that the config lives in a dotfile under an unprivileged user's home.

### `rig runner remove`

```sh
rig runner remove
rig runner remove --local     # no token; leaves a stale entry to delete by hand
```

Stops and uninstalls the systemd service, then deregisters the runner from
GitHub. The binary and its user stay put, so a later `rig runner install`
re-registers without downloading anything.

**The token here is a *removal* token, not a registration token** — a
different endpoint, and mixing them up is the easy mistake:

```sh
gh api -X POST repos/<owner/repo>/actions/runners/remove-token
```

Supply it via `RUNNER_REMOVE_TOKEN` or the prompt; it never touches disk.

`--local` is the escape hatch for when the registration is already gone
server-side (or you can't mint a token): the box is cleaned, but a stale
offline runner stays listed in the repo, for you to delete from
Settings → Actions → Runners.

The service always comes down *first*, in both paths. GitHub's own removal
refuses to run while the service is installed ("Uninstall service first"),
and `--local` skips that check entirely — which would otherwise leave a
running service pointed at config that no longer exists.

Convergent — a box with no runner installed exits 0.

### `rig runner repoint --repo <owner/repo>`

```sh
rig runner repoint --repo acme/widgets
```

Moves an installed runner from one repository to another: deregister,
re-register, reusing the binary already on the box. It keeps the runner's
existing name unless you pass `--name`.

This is the verb that was missing. `runner install` can create a runner but
never move one — pointed at a repo the box is not on, it fails and sends you
here — and re-pointing a box otherwise meant hand-rolled `config.sh`/`svc.sh`
incantations against an install path only rig knew.

Two short-lived tokens, each minted from **its own** repo — `RUNNER_REMOVE_TOKEN`
for the one it's leaving, `RUNNER_TOKEN` for the one it's joining. Both are
collected **before** anything is torn down: a token you turn out not to have
should fail while the runner is still registered and working, not halfway
through the move. If re-registration fails anyway, rig says so plainly and
prints the exact `runner install` line that finishes the job.

> **Labels do not survive a move on their own.** GitHub holds them; the runner
> does not persist them locally. rig now records what it registered with, so
> `repoint` and `status` can read it back — but a runner installed before rig
> did that has nothing to read, and `repoint` falls back to the `ci-runner`
> default and warns loudly before it touches anything. Labels are what
> `runs-on` matches, so a silent change there is a workflow that simply stops
> finding its runner. Pass `--labels` if yours differ.

Convergent — repointing to the repo it is already on changes nothing, exits 0,
and never asks for a token.

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
