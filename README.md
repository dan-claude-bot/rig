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

### `rig bootstrap <control-plane|workload|runner|staging|dev|workstation|custom>`

Run as root on the fresh box (over SSH). Convergent — safe to re-run; a
second run changes nothing.

```sh
rig bootstrap control-plane --hostname my-coolify-box
rig bootstrap workload --hostname my-prod-box
rig bootstrap runner --hostname my-ci-box
rig bootstrap staging --hostname my-vm-host
rig bootstrap dev --hostname my-dev-box
rig bootstrap workstation --hostname my-laptop
rig bootstrap custom --hostname odd-duck --class server --host yes --join authkey
```

- `--hostname <name>` — system + tailnet hostname (default: the role name;
  `custom` has no default and requires it)
- `--class <human|server>` — who lives here; decides root SSH's fate after
  `rig users apply` (see *The identity model* below)
- `--host <yes|no>` — does this box host VMs (box/Incus)
- `--join <authkey|login>` — how it enters the tailnet

**Roles are presets over three orthogonal traits**, nothing more — every
per-role behavior keys off a trait, so any flag overrides its trait without
needing a new role (`rig bootstrap workstation --host no` for a laptop that
will never run VMs), and `custom` exists for the shape nobody foresaw: it
presets nothing and requires `--hostname` plus all three traits.

| trait   | values             | what it drives |
|---------|--------------------|----------------|
| `class` | `human`, `server`  | root SSH's fate once operators exist — human closes it, server keeps it as the control plane's automation door |
| `host`  | `yes`, `no`        | whether the box exists to run VMs — the `/dev/kvm` advisory and the `box setup-host` pointer |
| `join`  | `authkey`, `login` | tagged pre-auth key (fleet identity) vs interactive browser login (user-owned device) |

| role            | class  | host | join    | tailnet tag |
|-----------------|--------|------|---------|-------------|
| `control-plane` | server | no   | authkey | `tag:server` |
| `workload`      | server | no   | authkey | `tag:server` |
| `runner`        | server | no   | authkey | `tag:ci` — refuses `tag:server` |
| `staging`       | server | yes  | authkey | `tag:local` — refuses `tag:server` |
| `dev`           | human  | yes  | authkey | `tag:local` — refuses `tag:server` |
| `workstation`   | human  | yes  | login   | untagged — any tag refused |

The tag column is **derived policy, not a fourth trait**: `tag:server` means
"the control plane manages this box", and `control-plane` and `workload` are
the only shapes it manages — every other role refuses an effective
`tag:server` after join, one rule instead of per-role exceptions.

After the tag verification passes, bootstrap writes `/etc/rig/role` — one
line, `role=… class=… host=… join=…` — recording the **effective** traits,
overrides and all, so an overridden role never lies to the commands that read
the marker later (`rig users` keys root policy off `class=`). Written
post-join and cmp-guarded, so a marker never describes a box that failed to
become what it claims.

**`join=login` inverts the tag assertion.** A workstation joins as a
user-owned device: there is no pre-auth key — a set `TS_AUTHKEY` is a loud
usage error (exit 2; unset it, or pass `--join authkey`) — `tailscale up`
prints a login URL, and the human at the keyboard is the credential. After
join the assertion flips: **untagged** is what rig asserts, and any effective
tag is the refusal — a tag here means control granted this device fleet
identity, and on a first join the half-joined node is backed out with
`tailscale logout` (a box that was already joined is refused without backout;
rig never unwinds state it did not create). Same principle as the authkey
path, mirrored: verify what control **granted**, never what was requested.

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

**The pre-auth key** (`join=authkey` roles — everything but `workstation`):
provide it via the `TS_AUTHKEY` env var or type it at
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

`staging` is the box that *hosts* staging boxes — Incus VMs minted by the
[`box`](https://github.com/heavy-duty/box) CLI, each converged from inside with
`rig bootstrap workload` and registered in the control plane as its own server.
It is `class=server`: an unattended VM appliance — operators converge it and
leave; nobody lives there. Mint its key with `tag:local`: the host and its
guests sit on opposite sides of a trust boundary, and the *host* is never
managed by the control plane — so the role **refuses an effective
`tag:server`**, same mechanism as `runner`. rig deliberately installs no Incus
and no box here — box's own `setup-host` is the single owner of the Incus
daemon's configuration, and two tools converging one daemon is drift by
construction. The closing log points you at it: install box, run
`box setup-host`, then `box new --template staging`. If `/dev/kvm` is absent,
rig warns (a host that exists to run VMs should have it) but does not fail —
the shape is rehearsed in containers, which legitimately lack it.

`dev` is `staging`'s human-class sibling — the same VM-hosting, `tag:local`
shape with a person living on it — and `workstation` is the machine at the
keyboard end of all the SSH connections: human-class, `join=login`, entering
the tailnet as *your* device rather than the fleet's.

### The identity model

**Named operators exist on every class, and humans never enter as root.** The
tailnet is network-only — no Tailscale SSH — so there is no identity broker at
the door: whoever holds a key to an account *is* that account, and a shared
root login is unattributable by construction. `rig users apply` puts named
operators on every box, server-class included; a human always enters as
themself and elevates via sudo.

**`class` decides root SSH's fate — after `rig users apply`, never before.**
On `class=human`, root SSH closes entirely (`rig users close-root`, below).
On `class=server` it stays open — key-only, as bootstrap left it — because
root there is the **automation** identity the control plane (Coolify) SSHes
in as. It is a machine door, never a human one.

**The detection side benefit:** once humans never use root, any root login
that is not the control plane is anomalous *by definition* — a cheap,
high-signal alert that a shared root identity makes impossible to write.

**The honest caveat:** on a Docker-running box this buys attribution, not
privilege reduction — an operator with sudo is root-equivalent anyway.
Attribution is the goal: *who did what* survives, even where *what they could
do* is everything.

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

### `rig users apply --file <path>`

Converges named operator accounts from a declarative users file — on **every**
class (see *The identity model*). Run as root. Convergent: a second identical
run says "already converged; no changes".

```
# user   roles       ssh public key
dan      admin,box   ssh-ed25519 AAAA... dan@laptop
dan      admin,box   ssh-ed25519 AAAA... dan@desktop
maria    rig,box     ssh-ed25519 AAAA... maria@mac
```

One line per key — user, comma-joined roles, then the SSH public key (the rest
of the line). The format is bash-parseable on purpose: a rig box has no YAML
parser and no jq, and gets neither for this. Repeated username lines add
authorized keys, and the roles must be identical on each — a repeated line
always means "another key", never a quiet role edit hiding mid-file. `root` is
refused as a username: this file names operators; root's fate is class policy.
`--file -` reads stdin. A bad file exits 2 with **every** error listed at
once, before anything changes — one fix cycle, not one round-trip per line.

**Public tool, private state, here too.** The users file lives in *your*
private infra repo and is passed per invocation — rig never persists it. It
holds nothing secret anyway: usernames, roles, and *public* keys.

| role    | grants                                       | via group   |
|---------|----------------------------------------------|-------------|
| `admin` | full NOPASSWD sudo                           | `rig-admin` |
| `rig`   | NOPASSWD sudo for `/usr/local/bin/rig` only  | `rig`       |
| `box`   | Incus **restricted** tier, no sudo           | `incus`     |

`box` carries a refusal with it: rig never installs Incus — box's `setup-host`
owns the daemon — so an absent `incus` group means that never ran, and apply
dies pointing at `box setup-host` rather than conjure a group the
(nonexistent) daemon would never consult. `incus-admin` is deliberately
**not** a role: that group is host-root-equivalent, break-glass by hand only.

**All passwords stay locked, always** — created or found. The SSH key at the
door is the authentication, and NOPASSWD sudo does not weaken it: there was
never a password to guess or rotate.

Convergence is exact. Membership in the three rig-managed groups is made to
match the file — added *and* removed — while every other group is left alone:
not rig's to converge. `authorized_keys` becomes exactly the file's keys. A
user dropped from the file is found via the `/etc/rig/users` ledger and
**locked, never deleted** — deletion frees the uid for reuse and orphans file
ownership, so attribution would rot; home stays for the same reason. And the
sudoers rules land in `/etc/sudoers.d/rig-roles` only after `visudo -c`
passes on the candidate — a bad file under `/etc/sudoers.d` can take down
*all* of sudo, locking every admin out of the very escalation path apply just
granted.

### `rig users status`

```sh
rig users status
```

Read-only truth: per rig-managed user, the roles derived from the groups the
user is **actually** in — not the ledger's memory of an apply — plus the
`authorized_keys` count and whether the account is locked or active. Reads the
box only; no network, no writes. Run as root (shadow is read).

### `rig users close-root`

```sh
rig users close-root
```

Shuts the root SSH door — `class=human` boxes only, and only once a named
admin can already get in. The gates run in order: the `/etc/rig/role` marker
must say `class=human` — an absent marker refuses (never shut the root door
blind; re-run bootstrap so the box knows what it is), and `class=server`
refuses with no `--force`, because root there is the control plane's
automation identity and closing it severs fleet management. Then at least one
`rig-admin` member must hold a non-empty `authorized_keys` — never close the
only door.

Before running it, prove the admin door in a **separate** session — `ssh
<admin>@<box>` while this one stays open. Root SSH is being welded shut; the
admin login must be proven, not presumed.

> **The drop-in's name is the entire mechanism.** close-root installs
> `/etc/ssh/sshd_config.d/00-rig-users.conf` carrying exactly
> `PermitRootLogin no`. sshd_config is first-wins, `Include` expands its glob
> lexically, and `-` (0x2D) sorts before `.` (0x2E) — so `00-rig-users.conf`
> is read *before* bootstrap's `00-rig.conf` and beats its
> `prohibit-password`. Bootstrap's effective-config assertion accepts the
> closed state (`no` is strictly harder than what it installs), and by the
> same first-wins order its own drop-in can never reopen it — a bootstrap
> re-run on a closed box leaves it closed. Validate-then-apply as everywhere:
> `sshd -t` before the restart, rollback on failure, and success is only
> claimed once `sshd -T` resolves `permitrootlogin no`.

Convergent — once root is closed, a re-run says "root already closed; nothing
to do" and exits 0.

> **On `class=server`, root stays — so lock its key instead.** This is README
> guidance, deliberately not automation: prefix Coolify's line in root's
> `authorized_keys` with a `from="<control-plane-addr>"` clause, so the
> automation identity only opens from the one address supposed to use it. rig
> will not write that file — Coolify owns its key material on the servers it
> registers, and two tools converging one file is drift by construction (the
> same argument that keeps rig's hands off Incus).

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
`rig users` family is covered the same way: the harness drives its refusal
matrix — users-file parsing, the marker gates, the lexical drop-in-name
assertion, the validate-then-apply ordering — through the sourced lib
functions, non-root and network-free. The end-to-end rehearsal is a throwaway
VM/container: pristine Debian → install → `bootstrap workload` with a real
single-use key → assert the sshd drop-in, tailnet join, and a no-op second
run → destroy, remove the node from the tailnet.
