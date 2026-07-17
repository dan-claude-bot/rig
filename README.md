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

There is **no `--ts-tag` flag**. A pre-auth key is minted *with* its tags, so
the key is the single source of truth for the tailnet tag — rig no longer states
a second one it might disagree with. It **verifies** the tag control actually
granted after join instead (see below). Passing `--ts-tag` now exits 2 with a
message pointing you at the key.

What it does: installs `curl ca-certificates unattended-upgrades` (and
enables periodic unattended upgrades); writes an sshd hardening drop-in
(`PermitRootLogin prohibit-password`, `PasswordAuthentication no`) and
**verifies it took effect** via `sshd -T`; sets the system hostname; installs
tailscale and joins your tailnet — then **verifies the tag the key granted**
(see *The tag comes from the key* below).

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
the interactive prompt. Use a **single-use, tagged, short-expiry** key — the
**tagged** part is now load-bearing, not advice (see below). It lives in process
memory only — rig never writes a credential to disk.

**The tag comes from the key, and rig verifies the one control granted.** rig
used to pass `--ts-tag` to `tailscale up --advertise-tags`, stating the tag a
*second* time — with no way to know whether its request and the key's own tags
agreed. It asserted the tag it **requested**, never the tag control **granted**;
this is the same shape as the sshd first-wins bug above, and it left the same
scar (both M900s joined carrying `tag:server` and had to be retagged by hand,
because nothing in rig ever read the effective tag back). So rig stops
overriding the key: `tailscale up` carries no `--advertise-tags`, the key's tags
apply, and after join rig polls `tailscale status --json` for `.Self.Tags` — the
netmap's ground truth, not `tailscale debug prefs`, which prints what was
*requested* — and asserts on that, on **first join and on every re-run** (which
catches a box bootstrapped before this change, or retagged behind rig's back).

> **An untagged key is a hard refusal.** Drop `--advertise-tags` and you also
> drop the accidental net that used to tag an untagged key's node anyway. An
> untagged node joins owned by the *key creator's user identity* — it inherits
> that human's ACL grants, expires with the key, and vanishes if the account is
> deleted. That is a fleet-shaped mistake, not a warning: rig runs `tailscale
> logout` to back the half-joined node out and dies telling you to mint a tagged
> key. A wrong tag **cannot** be fixed in place either — `tailscale set` has no
> tag flag, re-tagging needs a fresh key via `up --force-reauth` — so rig detects
> and refuses, and never claims a convergence it cannot perform.

`control-plane` and `workload` are identical today except the default
hostname; they exist because the boxes diverge over time, and because each
follow-up command applies to exactly one role. `runner` is the box a CI agent
will live on, and it differs behaviorally: it **refuses `tag:server`**. That
refusal moved onto the *effective* tag and is strictly stronger for it — it is
no longer "don't advertise `tag:server`" but "the key you actually used must not
grant `tag:server` to repo-controlled code." A runner executes that code, and
`tag:server`'s grants (SSH between your servers, say) must never extend to it;
the check turns the worst misconfiguration from a documentation warning into a
hard, post-join error.

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
