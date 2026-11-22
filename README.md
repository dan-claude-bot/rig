# rig

A CLI that turns a **pristine Debian server into a hardened, tailnet-joined
node** — one curl, one command. It converges the machine an external control
plane runs on, but does not install that payload. And inside a
[box](https://github.com/heavy-duty/box)-minted guest, the same verb converges
the **box tenants** — claude-box, codex-box, grok-box, kimi-box, staging-box —
from thin, creds-free seeds (see *the box tenants* below).

Philosophy (shared with [box](https://github.com/heavy-duty/box)):
**public tool, private state**. rig carries plumbing logic only — no
hostnames, no bindings, no secrets, nothing about *your* infrastructure. It
takes arguments, does its work, and stores no credential, ever.

## Install

```sh
# the development tree this README documents:
curl -fsSL https://raw.githubusercontent.com/heavy-duty/rig/main/install.sh | RIG_REF=main bash
# the latest release:
curl -fsSL https://raw.githubusercontent.com/heavy-duty/rig/main/install.sh | bash
```

This README tracks `main`, so the quick start installs that same development
tree. To install a stable version instead, use the latest-release or pinned-tag
channel and read the documentation shipped with it at
`$RIG_HOME/current/README.md` (`~/.local/share/rig/current/README.md` with the
default install root). Three channels come from the same script; `RIG_REF`
picks:

```sh
curl -fsSL .../install.sh | bash                   # the latest release
curl -fsSL .../install.sh | RIG_REF=0.2.0 bash     # pinned to a release
curl -fsSL .../install.sh | RIG_REF=main bash      # the development tree
```

A tag outranks a branch of the same name (the pin must win); anything that
is not a tag falls back to `refs/heads/<ref>`.

### The offline channel — one file you can copy

A machine that cannot reach GitHub, or that you would rather not give a
credential, installs from a **self-contained installer** instead: a single
`rig-<version>.sh` carrying the whole tree, published on each release beside
its `.sha256` sidecar. Copy it over and run it — no `curl`, no `git`, no
repository name and no ref:

```sh
scp rig-0.4.0.sh root@host:
ssh root@host 'bash rig-0.4.0.sh'
```

It verifies its own payload's checksum **before** unpacking anything, so a
truncated or mangled copy fails loudly and writes nothing; `--check` verifies
without installing and `--version` prints the checksum. What it unpacks is
handed to the same `install.sh` as every other channel, so the versioned
layout, the atomic flip and the PATH heal are identical — the artifact adds
integrity-checked, offline transport and nothing else. Extra arguments pass
straight through.

Build one from any checkout with `bash dist/release-artifact.sh --version
<v> --assets-dir <dir>`; that is also how a release candidate reaches the
drill host (see [`drill/README.md`](drill/README.md)).

The layout, under the install root (`~/.local/share/rig`):

```
versions/<version>/          one full tree per installed version
current -> versions/<v>      the tracked default
$BINDIR/rig -> current/bin/rig    the PATH entry, riding the chain
```

`rig` lands on your PATH via `~/.local/bin` (`/usr/local/bin` when root).

**Re-running is a safe converge.** Installing a version you already have
changes nothing and says so (`RIG_REINSTALL=1` replaces that version's
tree); a **new** version installs side by side and becomes the default — so
"re-run any time to upgrade" stays true, and now means *upgrade to the
latest release*; every version you had stays installed as the way back:

```sh
rig versions        # what is installed, which is current, which is running
rig use <version>   # flip the default (atomic; asserts the flip took)
```

On a **bootstrapped host** (one where `/etc/rig/role` exists) switching the
default — by upgrade or by `rig use` — prints a WARNING, because a
different rig under a converged host changes what a re-converge
(`rig bootstrap`, `rig users apply`) would do. It warns rather than
refuses: unlike box (which protects live boxes), rig holds no user state a
flip can strand, and upgrading a bootstrapped host is the normal case.

A pre-versioning flat install is migrated into `versions/` automatically on
the next installer run — the tree is moved, not re-downloaded, and
preserved bit for bit. For scripting: `RIG_HOME`/`RIG_BIN` override the
install root and bin dir, `RIG_INSTALL_SOURCE=<dir-or-tarball>` installs
from a local tree instead of downloading (how the test suite proves the
installer under review), and `RIG_YES=1` answers `rig uninstall`'s prompt
in automation.

### Uninstall

`rig uninstall` is the real uninstall — no more "rm -rf two paths" prose —
and it **ends with an absence assert**: every path it removed is
re-checked, and any survivor makes it exit 1 naming the leftovers instead
of reporting a clean uninstall that wasn't.

```sh
rig uninstall <version>    # one non-current version (side-by-side cleanup)
rig uninstall --all        # everything: every version, current, the PATH symlinks
```

Asks before removing; `--force` or `RIG_YES=1` skips the prompt. The host
itself is untouched — what bootstrap converged stays converged.

## Commands

### `rig bootstrap <control-plane-server|workload-server|runner-server|staging-server|dev-server|workstation|custom>`

Run as root on the fresh box (over SSH). Convergent — safe to re-run; a
second run changes nothing. (The box TENANT roles — `claude-box`, `codex-box`,
`grok-box`, `kimi-box`, `staging-box` — share the verb but are their own family; the
`-box` suffix says so. See *the box tenants* below.)

```sh
rig bootstrap control-plane-server --hostname my-coolify-box --users ./users
rig bootstrap workload-server --hostname my-prod-box --users ./users
rig bootstrap runner-server --hostname my-ci-box --users ./users
rig bootstrap dev-server --hostname my-dev-box --users ./users
rig bootstrap workstation --hostname my-laptop --users ./users
rig bootstrap custom --hostname my-vm-host --root-door open --host yes --join authkey --users ./users
```

- `--users <path>` / `--no-users` — **required**, one or the other: the users
  file this box's operators come from, converged as bootstrap's last phase
  (see *One command, box ready* below)
- `--hostname <name>` — system + tailnet hostname (default: the role name;
  `custom` has no default and requires it)
- `--root-door <closed|open>` — what happens to root SSH after the users
  phase: `closed` means `rig users close-root` shuts it once named operators
  can get in, `open` means it stays as the control plane's automation door
  (see *The identity model* below)
- `--host <yes|no>` — does this box host VMs (box/Incus)
- `--join <authkey|login>` — how it enters the tailnet

#### One command, box ready — `--users` is required

`rig bootstrap` already knows everything else about what a box *is* — the
root-door policy, host, join, hostname — and writes `/etc/rig/role` to say so.
The users file was the last piece of that answer it did not take, so bring-up
was two commands and the second one was easy to forget. Now it takes it, and
**requires** it:

```sh
rig bootstrap dev-server --hostname my-dev-box --users ./users   # one command, people included
rig bootstrap dev-server --hostname my-dev-box --no-users        # deliberately root-only
```

`--users <path>` runs exactly what `rig users apply --file <path>` runs, as
bootstrap's **final phase** — after the traits are set, after the tailnet
join is verified, and after `/etc/rig/role` is written, because apply *reads*
that marker (`root-door=` picks its root-SSH note, `host=` decides what a missing
`incus` group means). On a `host=yes` box it also lands after the `box`
install, so box-role users find the `incus` group box's `setup-host` built.
The file is passed per invocation and **never persisted** — bootstrap reads
it through apply and keeps nothing; `--users -` is refused, because
bootstrap's stdin belongs to the pre-auth key prompt.

Required on **every** role, `root-door=open` included. A bootstrapped box with
no users converges to a box only root can enter — on `root-door=closed` a
half-built machine, and on `root-door=open` something worse than half-built: a
machine nobody logs into routinely is exactly where shared-root access rots,
and per-human accounts keep attribution intact for the times someone does go
in. So the complete path is the default path, and skipping it is a deliberate
`--no-users` rather than an omission that looks identical to forgetting.
Omitting both is a usage error naming both flags; passing both is a usage
error too — rig will not silently pick a winner.

A bad users file is caught **up front**, in the same breath as a bad
`--root-door`: bootstrap pre-flights it with the same parser apply uses, before
`apt`, before the hostname change, and before a single-use pre-auth key is
spent. A file that names **no users** is refused there too — empty,
comments-only and whitespace-only files all parse fine, but bootstrapping
with one converges the same root-only box `--no-users` asks for, via the
flag that exists to guarantee the opposite. The refusal names `--no-users`,
because that box is reachable; it just has to be asked for out loud. This is
bootstrap's contract only: `rig users apply` against an emptied file is a
genuine de-provisioning operation and stays available. And on `host=yes`
with `RIG_SKIP_BOX_INSTALL=1`, a box-role user with no `incus` group refuses
immediately rather than a hundred lines later — that is the one case where
the outcome is already certain, since the run has been told it will not
install box. rig still **never** installs Incus or runs `box setup-host` on
its own account; the box CLI's own installer does that (see the `host`
trait), and every other way that step can fail lands in apply's existing
refusal at the end.

`--users` does **not** reach the box TENANT roles (`claude-box`, `codex-box`,
`grok-box`, `kimi-box`, `staging-box`). A tenant is a box-minted *guest*,
converged by hand from a root shell inside that one box; the guest never joins
the tailnet and has no SSH door of its own — you enter with `box shell`, gated
by the **host's** `incus` grants, which the host's own users file already
converged. A fleet-wide operator file has nothing to converge in there: one
guest is not the fleet the file describes, and the accounts that reach it are
the host's.

**Registry roles are presets over three orthogonal traits**, nothing more — every
per-role behavior keys off a trait, so any flag overrides its trait without
needing a new role (`rig bootstrap workstation --host no` for a laptop that
will never run VMs), and `custom` exists for the shape nobody foresaw: it
presets nothing and requires `--hostname` plus all three traits.

| trait   | values             | what it drives |
|---------|--------------------|----------------|
| `root-door` | `closed`, `open` | root SSH's fate once operators exist — `closed` shuts it via `rig users close-root`, `open` keeps it as the control plane's automation door |
| `host`  | `yes`, `no`        | whether the box exists to run VMs — the `/dev/kvm` advisory and, on `yes`, installing the `box` CLI + running box's `setup-host` |
| `join`  | `authkey`, `login` | tagged pre-auth key (fleet identity) vs interactive browser login (user-owned device) |

The role-to-trait rows below live in the pinned
[rig-templates registry](https://github.com/heavy-duty/rig-templates/tree/f77deae523112293320f29e1f8e5036257c6a685),
not in rig's bootstrap mechanism.

| role                   | root-door | host | join    | tailnet tag |
|------------------------|-----------|------|---------|-------------|
| `control-plane-server` | open      | no   | authkey | `tag:server` |
| `workload-server`      | open      | no   | authkey | `tag:server` |
| `runner-server`        | open      | no   | authkey | `tag:ci` — refuses `tag:server` |
| `staging-server`       | open      | yes  | authkey | `tag:local` — refuses `tag:server` |
| `dev-server`           | closed    | yes  | authkey | `tag:local` — refuses `tag:server` |
| `workstation`          | closed    | yes  | login   | untagged — any tag refused |

> **The suffix names the family, not the door policy** (#76). rig builds two kinds
> of thing on opposite sides of a trust boundary — tailnet **machines** it
> converges, and **guests** a box mints — and for a while nothing in a role
> name said which you were asking for. `staging` made that concrete: the word
> named both the metal that hosts guests and the guests on it, and only one of
> them could have it. So `-server` marks a fleet machine and `-box` marks a
> box tenant, everywhere, and `staging-server` / `staging-box` are simply the
> two halves spelled out. `staging-server` restores the VM-host preset #31
> retired, under a name that cannot be confused with its own guests.
>
> Two roles take **no** suffix, on purpose. `custom` presets nothing and can
> be any shape — a guest included — so a family claim is one it cannot make.
> `workstation` is somebody's own device rather than fleet infrastructure: it
> joins by interactive login, comes up user-owned and untagged, and the
> tailnet never manages it.
>
> **`dev-server --root-door closed` says what is true, and says it once**
> (#77). The suffix names the *family* — a fleet machine — and the trait names
> the *door*: operators enter a dev box as themselves, so `close-root` shuts
> its door. Until #77 this trait was `--class human|server`, which named the
> wrong axis (who lives on the box) and made `dev-server` read as a
> `class=human` contradiction: one word, "server", doing duty on two unrelated
> questions. Nobody *lives* on a dev box; what distinguishes it is that its
> root door closes. Markers written before the rename still say
> `class=human|server` and are still read — see *The root-door trait was
> renamed* below.
>
> **This was a hard cut — no aliases.** Old role names stop working, and a
> box bootstrapped under one is re-bootstrapped rather than migrated. Two
> things follow. The default tailnet hostname is the role name, so a box that
> took the default now comes up as `control-plane-server`; pass `--hostname`
> to hold a name steady.

The tag column is **derived policy, not a fourth trait**: `tag:server` means
"the control plane manages this box", and `control-plane-server` and `workload-server` are
the only shapes it manages — every other role refuses an effective
`tag:server` after join, one rule instead of per-role exceptions.

After the tag verification passes, bootstrap writes `/etc/rig/role` — one
line, `role=… root-door=… host=… join=… join-by=…` — recording the
**effective** traits, overrides and all, plus whether this run performed the
tailnet join. `join-by=rig` means bootstrap called `tailscale up`;
`join-by=preexisting` means it found the node already joined. Old markers name
neither and are treated as unknown, never as permission to remove a join.
Written post-join and cmp-guarded, so a marker never describes a box that
failed to become what it claims.

### `rig bootstrap --undo`

```sh
rig bootstrap --undo
```

Leaves the tailnet and then removes `/etc/rig/role`, but only when the marker
says `join-by=rig`. A pre-existing join, an old marker with no provenance, or
no marker at all is refused without calling `tailscale logout`; the refusal
names the manual repair. Re-running bootstrap writes the current marker shape.
An installed GitHub runner is also refused so undo cannot leave a ghost
registration; deregister it outside rig before retrying.

If `tailscale logout` fails, the marker stays in place so the command is
retryable.

This is intentionally not a general rollback. It does not uninstall packages,
reverse sshd hardening, remove Docker, Node, agent CLIs, or users. Those changes
are convergent rather than transactional and cannot be safely inferred away.

Immediately after it, bootstrap stamps `/etc/rig/manifest` — **provenance**:
which rig converged this box and when (see [`rig
manifest`](#rig-manifest)). Same discipline, same guarantee, and the two files
stay consistent because they land together. The marker says what the box *is*;
the manifest says what *built* it. The tenant roles stamp it too — a
box-minted guest is a machine rig converged.

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

`control-plane-server` and `workload-server` are identical today except the default
hostname; they exist because the boxes diverge over time, and because each
follow-up command applies to exactly one role. `runner-server` is the box a CI agent
will live on, and it differs behaviorally: it **refuses `tag:server`**. That
refusal moved onto the *effective* tag and is strictly stronger for it — it is
no longer "don't advertise `tag:server`" but "the key you actually used must not
grant `tag:server` to repo-controlled code." A runner executes that code, and
`tag:server`'s grants (SSH between your servers, say) must never extend to it;
the check turns the worst misconfiguration from a documentation warning into a
hard, post-join error.

The VM-host shape — the box that *hosts* staging boxes: Incus VMs minted by
the [`box`](https://github.com/heavy-duty/box) CLI, each converged from inside
with the tenant roles and (for staging guests) `rig bootstrap workload-server` —
is the `staging-server` role (`--root-door open --host yes --join authkey`; see
the note above). It is `root-door=open`: an unattended VM appliance — operators
converge it and leave; nobody lives there. Mint its key with `tag:local`: the
host and its guests sit on opposite sides of a trust boundary, and the *host*
is never managed by the control plane — so an effective **`tag:server` is
refused**, same mechanism as `runner-server`.

On a VM-hosting box (`host=yes`), bootstrap finishes the job instead of leaving
a to-do: after the role marker is written it **installs the `box` CLI globally
and runs box's own `setup-host`**, so the Incus stack is ready for
`box new` when bootstrap returns. rig **delegates to box; it
never touches Incus itself** — it does not `apt-get install incus`, does not
configure the daemon, does not create the `incus` group. It runs box's global
installer (`curl … | BOX_YES=1 bash`) as root, and box installs Incus via its
`setup-host`; two tools converging one daemon is drift by construction, and box
is the single owner. The step is **convergent** (box's installer is a no-op once
box is present) and **opt-out** (`RIG_SKIP_BOX_INSTALL=1`, plus a graceful skip
with a manual-command pointer when curl or the network is missing — box is the
host *extra*, so a failed box install never aborts a bootstrap that otherwise
succeeded). Source is pinnable with `BOX_REPO` / `BOX_REF` (default
`heavy-duty/box@0.10.0`). If `/dev/kvm` is absent, rig warns (a host that exists to
run VMs should have it) but does not fail — the shape is rehearsed in containers,
which legitimately lack it. (The global install path is world-readable by
construction: box's root install lands in `/opt/box`, readable by every
non-root user, with the entrypoint on every login PATH via `/usr/local/bin`.)

> **The box install is release-pinned.** A rig release carries one box release
> pin, so two machines bootstrapped from the same rig install the same box.
> `BOX_REPO` / `BOX_REF` remain explicit overrides for development and
> pre-release drills; `RIG_SKIP_BOX_INSTALL=1` opts out entirely for a host
> whose box you manage by hand.

`dev-server` is the closed-door VM-hosting shape — `tag:local`, box CLI installed as
above, operators entering as themselves (`--root-door open` turns it into the
unattended VM-host appliance) — and `workstation` is the machine at the keyboard
end of all the SSH connections: `root-door=closed`, `join=login`, entering the
tailnet as *your* device rather than the fleet's.

### Machine-role templates

Machine presets live in the
[heavy-duty/rig-templates](https://github.com/heavy-duty/rig-templates)
registry. A `*-server` directory is a fleet-machine definition; the exact
name `workstation` is the deliberate suffix-less exception. Its
`template.env` contains exactly the three traits bootstrap consumes:

```dotenv
ROOT_DOOR="open"    # open|closed
HOST="no"           # yes|no
JOIN="authkey"      # authkey|login
```

An `install.sh` is optional. When present, bootstrap runs it as root,
non-interactively, from the definition directory with `RIG_ROLE` set, after
the tailnet join, host setup, role marker prerequisites, and operator
convergence. A nonzero exit fails bootstrap and names the role and registry
source. The definition owns idempotence, just as bootstrap does.

`custom` remains in rig and takes precedence over registry names because it
has no preset traits. Every named non-tenant role is looked up in the resolved
registry; the same three source knobs below apply, including
`RIG_TEMPLATES_DIR` for an offline local definition. Pin reviewed registry
content into rig's tree before using it on fleet machines: an optional machine
`install.sh` executes as root on metal, and an override is the operator
explicitly choosing a different trust root.

### `rig bootstrap <role>-box` — the box tenants

Run as root, **inside** a [box](https://github.com/heavy-duty/box)-minted
guest. Convergent — safe to re-run; a second run changes nothing.

```sh
rig bootstrap claude-box          # or codex-box, grok-box, kimi-box — the agent tenants
rig bootstrap staging-box         # the server tenant (docker + sshd hardening)
rig bootstrap claude-box --user dev   # when the seed's BOX_USER differs
```

**The layering** (rig#31, originating with box#81): a box template stops being
where tenant content lives. box mints a **thin, creds-free seed** — base image,
the `BOX_USER`, fixed `/tmp` (swap leaves the seed for `SWAP_SIZE`, below), `tmux`, `curl`, `ca-certificates`,
`chrony`, `python3-venv` and `shellcheck` — and everything the guest *becomes*
is a rig tenant role. cloud-init is a first-boot
one-shot: not convergent, not re-runnable, and only parse-and-grep testable.
rig roles are idempotent scripts with effective-state asserts, driven by the
same harness as everything else — and re-runnable on an *existing* box to
converge it to a new spec instead of re-minting it. One convergence engine;
the guests were the hole.

It is **one mechanism, parameterized per DEFINITION** (#110), not four
hand-maintained scripts. Agent-tenant definitions live in the
**[heavy-duty/rig-templates](https://github.com/heavy-duty/rig-templates)
registry** — one directory per role (`template.env`, the allowlisted data
table rig parses and never sources; `install.sh`, the CLI install; `creds.md`,
the per-vendor context paragraph) — so adding an agent tenant is a data PR
there, never a mechanism edit here (#109 was the evidence: adding kimi, pure
data, meant editing six files in this repo). Which `-box` roles exist is the
registry's fact; `rig bootstrap <anything>-box` dispatches on the family
suffix and refuses an unknown role by listing what the resolved registry
actually contains. Tenant definitions default to `AGENT="yes"` and
`HARDEN_SSHD="no"`; `AGENT="no"` removes the CLI, context, node and creds
contract, while `HARDEN_SSHD="yes"` independently invokes the shared
`lib/sshd.sh` mechanism. Those two keys are what let the registry describe
`staging-box` — user `ops`, no agent, box#69's hardened server posture — so
rig's tree now defines **no** tenant role at all (#185).

**Swap is a definition fact too** (#229). An optional `SWAP_SIZE` — a number
then `M` or `G`, from `256M` to `64G`, anything else refused at parse —
converges a `/swapfile` of that size with an `/etc/fstab` line, **on a VM
only**: a container logs one skip line and creates nothing. A re-run leaves a
right-sized swapfile alone and recreates one of any other size (swapoff,
recreate, swapon); with no `SWAP_SIZE`, rig neither creates nor removes swap.
It replaces the 4GiB `/swapfile` box's cloud-init used to give every guest,
which box#253 removes, so a definition that wants the old behaviour says
`SWAP_SIZE="4G"`. An existing box's 4GiB file already matches that and is
left as it is.

**Where the registry comes from — precedence high to low:**

| knob | meaning |
|------|---------|
| `RIG_TEMPLATES_DIR` | a local folder — no fetch: the offline-test path, and "try a template before it exists anywhere" |
| `RIG_TEMPLATES_REF` | any ref of `RIG_TEMPLATES_REPO` (default `heavy-duty/rig-templates`), fetched as an unauthenticated tarball at bootstrap time |
| *(neither set; matching snapshot installed)* | **the installed pin snapshot** — `install.sh` best-effort fetches `RIG_TEMPLATES_PIN` once into `templates@<pin-sha>/` inside the versioned rig tree; default converges read it with zero registry network I/O |
| *(snapshot absent, empty, or stale)* | **live fetch of the in-tree pin** — the pre-snapshot fallback: `RIG_TEMPLATES_PIN` in `commands/lib/templates.sh` is fetched at converge time. A failed snapshot download only warns during install, so rig remains usable and retries here |

The pin remains the only source of truth. An older `templates@<sha>/`
directory cannot answer after a pin bump, and an explicit
`RIG_TEMPLATES_REF` always fetches that ref rather than consulting the
snapshot. Logs mark the installed path as `(snapshot)` so drill evidence
records which source actually served the converge.

**The security trade — in bold, not a footnote.** **A main-tracked
rig-templates repo means every merged PR there executes as root inside every
future mint.** This is acceptable — and an improvement — only because of
three facts together: (1) it *narrows* today's surface, where all of rig is
main-tracked-as-root; (2) the repo is small, single-purpose, and
ceremony-governed with a **human merge** as the gate and the review panel
ahead of it; (3) drills pin the SHA they proved. If any of those three
weakens, the default flips to a pinned `RIG_TEMPLATES_REF`. install.sh diffs
in that repo are the highest-trust review surface in the org — the reviewer
doctrine should say so. *(2026-07-24: the flip this paragraph reserves was
taken, before the migration and by the decider — the default IS the pin
above, so a merged template reaches mints only through a reviewed pin bump
here, or an explicit per-mint `RIG_TEMPLATES_REF`.)*

**The role carries the suffix; the user does not.** A tenant user is the
account the box *seed* created (`BOX_USER`) and the agent CLI's own dotdir
hangs off it — `claude-box` converges the `claude` user and writes
`~/.claude/CLAUDE.md`. The suffix is rig's word for "this is a guest", not a
rename of anything inside the box, so nothing in the guest's filesystem moved.

Every install is **asserted on effective state**, not exit codes: the CLI must
*answer* (`--version`, run as the tenant user — a CLI that exists but cannot
run has already cost a drill), docker must answer, `sshd -T` must resolve the
hardening. The CLI also lands on the **system** PATH (`/usr/local/bin`):
`box exec <box> -- claude …` runs a non-interactive shell that reads no rc
files, so a PATH export alone is invisible to it.

**Creds-free and non-interactive, by contract.** box mints a blank guest and a
human converges it — mint, `box root <box>`, install rig, then this command —
the four steps
[box's own quick start](https://github.com/heavy-duty/box#quick-start)
documents; rig's half of that path is what happens after the invocation, and it
is unchanged. Nothing here prompts, joins, or admits — no tailnet, no keys (the
harness pins this by *absence*: no `tailscale`, no prompt, in the shipped
script) — and the registry fetch stays **unauthenticated** because a converge
run this way holds nothing to authenticate with. The one creds-holding step a
staging guest eventually needs — the tailnet workload join — stays
**operator-run**, exactly as box#69 designed it: `box root <box>` → `rig
bootstrap workload-server --hostname <name> --users <path>` (or `--no-users` —
a guest's door is `box shell`, gated by the host's grants) with a single-use
tagged pre-auth key. After that join, re-running
`rig bootstrap staging-box` still converges docker + hardening and leaves the
workload marker alone — the machine role is the truer statement of what the
box became.

**The agent-context file carries the box#80 guard, once.** Every agent tenant
writes its agent's instructions file (`CLAUDE.md` / `AGENTS.md`), rendered
from one shared template: the creds-free contract, the isolation and
disposability facts, and the guard note — **never run `box setup-host`,
`box teardown-host`, or the drill inside a box; the box you are in is not a
host you own**. A nested box stack claims the guest's own uplink subnet and
silently breaks its networking (box#80). The note lives in
`lib/templates.sh`'s renderer exactly once — mechanism, not template data —
never copy-pasted per definition; that was the point of moving it here. Only
the creds paragraph is the definition's (`creds.md`).

**Tenants and the role marker.** A tenant run writes `role=<tenant> tenant=yes
host=no` — no `root-door=`, because a guest has no root-door policy of its own
(`rig users close-root` fails closed on it, by design). The guard runs the
other way too: a box already carrying a **machine** role refuses the agent
tenants outright, and *any* tenant refuses a `host=yes` box — a VM host is
the opposite of a guest, and a pre-#31 staging *host* re-running its old
command is exactly who that refusal catches (it names the new spelling).

> **The rig install a guest receives is unpinned.** A human runs rig's curl
> installer from a root shell inside the guest; that installer resolves
> `RIG_REPO`/`RIG_REF` and, since rig#32, defaults to the
> **latest release**, with `RIG_REF=<tag>` the pin and `RIG_REF=main` the
> dev channel. An install that needs main must set `RIG_REF=main` explicitly;
> the default channel never silently falls back to a development branch.
> The install edge points both ways: rig installs box on VM-hosting machines
> at `BOX_RELEASE`, and an operator installs rig in a guest. `RIG_REPO` and
> `RIG_REF` are that operator's pin points, or can point at a frozen branch
> of a fork. box#81 established the old automatic edge; [box 0.10.0 documents
> its retirement](https://github.com/heavy-duty/box/blob/0.10.0/README.md#sizes-and-seeds).

### The identity model

**Named operators exist on every box, and humans never enter as root.** The
tailnet is network-only — no Tailscale SSH — so there is no identity broker at
the door: whoever holds a key to an account *is* that account, and a shared
root login is unattributable by construction. `rig users apply` puts named
operators on every box, `root-door=open` included; a human always enters as
themself and elevates via sudo.

Per role, the whole identity picture at a glance — issue #25's class
comparison, translated onto the traits that replaced the class binary. Note
that "who lives here" and the root-door trait are **different columns**: that
they were ever one word is exactly what #77 fixed.

| role                   | root-door | host | join    | who lives here                       | root SSH after `rig users apply` |
|------------------------|-----------|------|---------|--------------------------------------|----------------------------------|
| `control-plane-server` | open      | no   | authkey | nobody — Coolify runs here           | open — the automation door       |
| `workload-server`      | open      | no   | authkey | nobody — deployed services run here  | open — the automation door       |
| `runner-server`        | open      | no   | authkey | nobody — CI jobs as `github-runner`  | open — the automation door       |
| `staging-server`       | open      | yes  | authkey | nobody — it mints and hosts guests   | open — the automation door       |
| `dev-server`           | closed    | yes  | authkey | operators, minting boxes             | closed by `rig users close-root` |
| `workstation`          | closed    | yes  | login   | its owner                            | closed by `rig users close-root` |

(`staging-server` is that unattended VM-host appliance, and the row above is
the whole of it: nobody lives there, root SSH stays open as the automation
door. The box TENANT roles sit outside this table on
purpose: a guest is not a tailnet machine, and its marker carries no `root-door=`,
so `rig users close-root` fails closed on it.)

Who installs what, and who runs as what: **bootstrap is always root** and
installs everything a role needs — on `host=yes` that includes the box CLI
(globally) and box's own `setup-host`. **Humans always run as themselves**:
operators land via `rig users apply` on every box and elevate through sudo
(roles `admin`/`rig`) or the `incus` group (role `box`) — never by logging in
as root. **Machine identities stay machine-shaped**: Coolify's automation
SSHes in as root (that is what `root-door=open` root *is*), CI jobs run as the
unprivileged `github-runner`, and guest VMs are their own open-door boxes,
converged from inside by `rig bootstrap workload-server`.

**`root-door` decides root SSH's fate — after `rig users apply`, never before.**
On `root-door=closed`, root SSH closes entirely (`rig users close-root`, below).
On `root-door=open` it stays open — key-only, as bootstrap left it — because
root there is the **automation** identity the control plane (Coolify) SSHes
in as. It is a machine door, never a human one.

#### The root-door trait was renamed, and old markers still resolve

This trait was `--class human|server` until
[#77](https://github.com/heavy-duty/rig/issues/77). `class` named who *lived
on* the box; what it actually decides is whether root SSH stays open as the
control plane's automation door. Those are different questions, and the roles
proved it: `dev-server` is an unattended VM-host appliance — nobody lives
there — yet it was `class=human`, correctly, because operators enter it as
themselves and its root door must close. After #76 gave `-server` a second
job (naming the machine *family*), `dev-server` carried a suffix saying server
and a trait saying human, and nothing in the name said which axis was which.
`--root-door closed|open` names the axis rig actually branches on.

**This is not a cosmetic rename, and it is not a hard cut.** Unlike role
names — which nothing reads back — this trait is written into `/etc/rig/role`
and read *from* there on live machines, where it gates `rig users close-root`.
Every box bootstrapped before #77 carries `class=human` or `class=server` and
carries it **forever**, until someone re-bootstraps it; nothing migrates a
fleet. So rig **reads both spellings, permanently**:

| marker says | resolves to | means |
|---|---|---|
| `root-door=closed` | closed | the current spelling |
| `root-door=open` | open | the current spelling |
| `class=human` | closed | pre-#77, still honored |
| `class=server` | open | pre-#77, still honored |
| both, agreeing | that value | one claim said twice |
| both, **disagreeing** | refusal | rig will not pick a winner — re-run bootstrap |
| neither | refusal | no door policy to act on — re-run bootstrap |

New markers are written in the **new vocabulary only**. Writing both would
keep an old rig reading a new marker, but it would also entrench the retired
spelling on every box rig ever converges and make the disagreement row
reachable from rig's own hand rather than only from a text editor. The compat
obligation runs the other way: new rig reads old markers, because those exist
in the field and nothing will rewrite them.

The two refusal rows are **fail-closed** on purpose. A marker that names no
door policy, or names two that disagree, leaves rig unable to say whether root
here is a human's bad habit or the fleet's management plane — and the safe
error is a door that stays open and a loud instruction to re-run bootstrap,
never a door welded shut on a machine whose only entrance it was.

**Where this diverges from #17's original table:** that table let the
`runner-server` role close root ("no Coolify involved"). The trait model supersedes
the per-role call: runner is `root-door=open` — an automation identity, not a
person's box — and on every open-door machine root SSH is the management
plane rig itself converges through, so `close-root` refuses there
deliberately, runner included. A CI box you mean to administer like a human
machine is `--root-door closed` at bootstrap, not an exception carved out of
the gate.

**The detection side benefit:** once humans never use root, any root login
that is not the control plane is anomalous *by definition* — a cheap,
high-signal alert that a shared root identity makes impossible to write.

**The honest caveat:** on a Docker-running box this buys attribution, not
privilege reduction — an operator with sudo is root-equivalent anyway.
Attribution is the goal: *who did what* survives, even where *what they could
do* is everything.

### `rig db <dump|restore>`

Ad-hoc PostgreSQL dump/restore for a container running on this box. Run as
root.

```sh
rig db dump coolify-db                          # -> coolify-db-20260717T041500Z.sql.gz
rig db dump my-app-db /srv/snapshots/pre-migrate.sql.gz
rig db restore pre-migrate.sql.gz my-app-db     # prompts before overwriting
rig db restore umami.sql.gz shared-pg umami --yes
```

This is **imperative on-box tooling** — the "give me a copy of that database
right now", "put this artifact back" verbs you reach for by hand. It targets
any container and, on restore, overwrites live data behind a confirm gate.
Declarative convergence lives elsewhere by design — this verb exists precisely
for the moments that are not convergent.

**`dump`** pipes `pg_dump` straight into `gzip`:

```sh
docker exec <container> sh -c \
  'pg_dump -U "$POSTGRES_USER" --clean --if-exists --no-owner --no-acl "$POSTGRES_DB"' | gzip
```

- **`--no-owner --no-acl` is mandatory, not cosmetic.** A cross-instance restore
  runs as the *target's* superuser, and Coolify randomizes that role per
  database — so the source's `ALTER OWNER`/`GRANT` statements name a role that
  does not exist on the target and, under `ON_ERROR_STOP=1`, abort the whole
  restore on the first one. Stripping ownership and ACLs makes the dump describe
  *data and schema*, portable onto any instance.
- **`$POSTGRES_USER` / `$POSTGRES_DB` are read inside the container** — that is
  why the command is a *single-quoted* `sh -c`: it evaluates the container's own
  environment, never the host's. The host never hardcodes `postgres`; on the
  next container that role name is simply wrong.
- With no `[outfile]`, it writes `<container>-<UTC-timestamp>.sql.gz` in the
  current directory (same timestamp shape as the nightly dump). `pipefail` is
  load-bearing: without it a failing `pg_dump` still exits 0 through the pipe and
  `gzip` compresses the truncated output into a valid `.gz` that looks exactly
  like a good backup. rig dumps to a sibling temp, promotes it only on success,
  and refuses to keep an empty artifact.

**`restore <artifact> <container> [db]`** streams the artifact back in:

```sh
gunzip -c <artifact> | docker exec -i <container> sh -c \
  'psql -U "$POSTGRES_USER" -d "${db:-$POSTGRES_DB}" -v ON_ERROR_STOP=1'
```

- It connects as the container's **own superuser** (`$POSTGRES_USER`), again
  never a hardcoded role, and runs with `ON_ERROR_STOP=1` so a bad restore fails
  loudly instead of limping to a half-applied state and reporting success.
- **`[db]` targets a named database in a shared container** — e.g. a `umami`
  database living in a Postgres that also hosts other apps. Omit it to restore
  into the container's default `$POSTGRES_DB`. rig passes the name *into* the
  container as an env var rather than splicing it into the command string.
- **Restore overwrites the target**, so it prompts `y/N` first. `--yes` (or
  `--force`) is the automation bypass. The artifact is checked for existence and
  non-emptiness *before* the prompt and before anything touches the database, so
  a fat-fingered path fails cheaply.

#### Verifying a dump/restore actually works

A `.gz` that opens without error is not proof of a good backup: a `pg_dump`
truncated mid-stream still compresses into a perfectly valid gzip file that
*looks* exactly like a complete one. The same ethos as the nightly dump applies
here — **a backup you have never read back is not yet a backup.** The only
fully-trustworthy proof is to restore the artifact and read the rows back out.

On a real Coolify box you can do that **without touching prod data** by
restoring into a fresh *scratch* database rather than over the live one:

```sh
# 1. dump the live database (read-only; harmless)
rig db dump coolify-db /srv/snapshots/verify.sql.gz

# 2. create a throwaway database as the container's OWN superuser
docker exec coolify-db sh -c 'createdb -U "$POSTGRES_USER" rig_verify'

# 3. restore the artifact INTO the scratch db (not the live one)
rig db restore /srv/snapshots/verify.sql.gz coolify-db rig_verify --yes

# 4. spot-check a table you expect to see
docker exec coolify-db sh -c \
  'psql -U "$POSTGRES_USER" -d rig_verify -c "\dt"'
docker exec coolify-db sh -c \
  'psql -U "$POSTGRES_USER" -d rig_verify -c "SELECT count(*) FROM <some-table>"'

# 5. drop the scratch db — live data was never touched
docker exec coolify-db sh -c 'dropdb -U "$POSTGRES_USER" rig_verify'
```

If the counts and tables are there, the artifact is real. This is exactly the
round-trip `test/db-integration.sh` automates in CI (the `db-integration` job):
it seeds a known table in a source container whose superuser is *not* the
default, dumps it, restores into a second container whose superuser differs, and
asserts the rows and an ordered checksum survived — the same proof, done against
throwaway containers on every push.

### `rig platform`

```sh
rig platform
```

What is this machine — computed at run time, **stored nowhere**:

```
PLATFORM
HOSTNAME   hetzner-cp-1
ID         cd9fb802-1493-2336-d027-7955f328bcd8
OS         Debian GNU/Linux 13 (trixie)
KERNEL     6.12.95+deb13-amd64 (x86_64)
CPU        AMD Ryzen 7 3700X 8-Core Processor (16 cores)
MEMORY     31Gi total, 24Gi available
DISK       456Gi total, 201Gi free on /
VIRT       kvm

PROVENANCE
CONVERGED  0.6.0, 2026-08-02T09:11:03Z
BOOTSTRAP  0.4.0, 2026-07-19T14:24:51Z
ROLE       dev-server (root-door=closed host=yes join=authkey)
```

"Is this the 32GB one, or the M900?" was previously a question you answered by
logging in and running `free -h`, `nproc`, `df -h` and `uname -r` by hand —
four commands deep, on a machine you were already unsure about.

**Why this computes instead of storing.** It would be easy to write the specs
into a file at bootstrap. That is the wrong shape: specs change without rig
doing anything — someone adds RAM, resizes the root disk, or the
unattended-upgrades that bootstrap itself enables patches the kernel. A stored
spec is stale the moment the machine changes, and refreshing it on every run
would collide with bootstrap's contract that a second run changes nothing.
Computing at run time removes the problem instead of managing it: the answer
is correct by construction because there is nothing to go stale.

The corollary is deliberate: **`rig platform` works on a machine rig has never
converged.** It reads only `/proc`, `uname`, `/etc/os-release`,
`/etc/machine-id`, `df` and `systemd-detect-virt`, so it runs on bare Debian
before bootstrap — useful for deciding *what to converge this into*, not just
for auditing afterwards. It needs no root, makes no network call, and writes
nothing, ever.

**`ID` names the machine where `HOSTNAME` names the slot** — that contrast is
why they sit together. rig sets the hostname itself during bootstrap and
reuses it across rebuilds (`hetzner-cp-1` is a role, not hardware), so the
hostname cannot answer "is this the same machine I converged in June, or its
replacement?". `ID` can: it is derived from `/etc/machine-id` as
`sha256("rig-machine-id:<machine-id>")`, first 32 hex chars rendered
8-4-4-4-12 — computed at run time and stored nowhere, like every other fact in
the block, so it exists before bootstrap too. It is deliberately **not** the
raw machine-id: `machine-id(5)` asks that the value not be exposed, and the
namespaced hash is its documented remedy — a reader of `rig platform` output
cannot recover `/etc/machine-id`, nor correlate the id with any other tool's
derivation of it. A missing, empty or `uninitialized` machine-id renders
`ID unavailable (reason)` while every other field still reports; it is never
an empty string and never a hash of nothing, which would hand every such
machine the same identity.

**Two machines reporting the same `ID` means a cloned image** — actionable
information, not a coincidence. A host cloned from a golden image carries the
image's `/etc/machine-id`, and no identity that lives in the filesystem
survives the filesystem being copied. If you hit it, regenerate the clone's
machine-id (`systemd-machine-id-setup`) rather than doubting the field.

The `PROVENANCE` block is the complementary half — which rig, and when, which
is *decided* rather than observed, so it is stored. It is **read, never
written**: `CONVERGED`/`BOOTSTRAP` come from `/etc/rig/manifest` and `ROLE`
from `/etc/rig/role`. Neither file is required — a machine missing one reads
`not bootstrapped` for that line, which is itself the useful answer. The
manifest is #61 and is not implemented yet, so today those lines read `not
bootstrapped` on every machine; nothing else in the command depends on it.

**The two dates are deliberately separate**, matching #61's schema: `BOOTSTRAP`
is birth (`bootstrapped_by`/`bootstrapped_at`, first-write-wins, pinned
forever) and `CONVERGED` is latest (`converged_by`/`converged_at`, updated only
when the converging version actually differs). That distinction is what answers
"is this machine still converged by a rig that predates the fix?".

A **fresh machine writes both pairs with equal values**, so two identical lines
mean "bootstrapped and never re-converged since" — not a missing record. A
later re-converge by a different rig moves `CONVERGED` and leaves `BOOTSTRAP`
untouched, which is the whole point of keeping them apart.

`CONVERGED  not recorded` therefore does **not** describe a freshly
bootstrapped box; no writer produces a manifest without the pair. It means the
file is partial or hand-edited, and the value is deliberately not backfilled
from `BOOTSTRAP` — inferring a convergence that never happened would be worse
than saying so. Likewise a manifest whose `schema=` this rig does not know is
named as such instead of being half-read in silence.

**Known limitation — `CPU` and `MEMORY` inside a container-style guest are
unverified.** `CPU` and `MEMORY` are read straight from `/proc/cpuinfo` and
`/proc/meminfo`, with no cgroup awareness. Inside a box-minted guest (`VIRT`
says `lxc`) it is **not currently established** whether those files report the
instance's configured limits or the host's totals: neither file is namespaced
by the kernel, but `lxcfs` — when the guest has it — overmounts both with
limit-aware versions, so the answer depends on the guest's setup rather than
on anything rig controls. Until someone confirms it against a real guest,
treat those two lines as unreliable on `lxc` machines and check the instance
config if the number matters. Everything else (OS, kernel, disk, virt,
provenance) is the guest's own either way.

Deliberately not guessed at: cgroup-aware limit detection would be the fix if
the numbers do turn out to be the host's, but writing it against a *reasoned*
answer rather than an *observed* one risks correcting a bug that isn't there
and papering over one that is.

Deliberately **not** here: NIC names, MAC addresses, PCI inventory, mount
tables, sensors — this is a cheatsheet, not `inxi`, and the bar is "what would
I want to know before I SSH in". Nor any health judgement ("disk nearly
full"): that needs thresholds this command has no business owning. It is
called `platform` and not `status` on purpose — `rig users status`
cross-checks recorded state against live state and prints `DRIFT`, and this
command records nothing, so it cannot drift and must not borrow a promise it
structurally cannot make. That leaves `rig status` free for the machine-wide
roll-up it will eventually want to be.

### `rig users apply --file <path>`

Converges named operator accounts from a declarative users file — on **every**
box, whatever its root-door policy (see *The identity model*). Run as root. Convergent: a second identical
run says "already converged; no changes".

This is also what `rig bootstrap --users <path>` runs as its last phase, so on
a fresh box you rarely call it by hand — it is the *re-converge* verb (a key
added, an operator revoked, a `--no-users` box growing people later).

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
refused as a username: this file names operators; root's fate is root-door policy.
`--file -` reads stdin. A bad file exits 2 with **every** error listed at
once, before anything changes — one fix cycle, not one round-trip per line.

**A file naming zero users is confirmed, not refused (#65).** "Revoke
everyone" and "I truncated the file" are the same instruction in this format,
and a stray `>` writes the second one. apply cannot read intent — but it can
read the `/etc/rig/users` ledger, which draws the only line worth drawing:
against an empty ledger an empty file is an unambiguous no-op, and against a
populated one it closes every named door on the box. So that second case, and
only it, stops and asks — naming how many operators are about to go:

```sh
rig users apply --file ./users            # empty file + managed operators -> asks
rig users apply --file ./users --yes      # ...or say yes up front
RIG_YES=1 rig users apply --file ./users  # same, for automation
```

**Without a terminal and without consent it exits 2** rather than assume a
yes it cannot ask for — the contract `rig uninstall` already uses, and the
same `RIG_YES` the installer family reads. Consent that cannot be obtained is
not consent, and a prompt nothing can answer must not hang either.

This is a *confirmation*, deliberately unlike `rig bootstrap`'s flat refusal
of the same file (see *Bootstrap*): bootstrap **asserts** who lives on a box,
so an empty answer contradicts itself, while apply **converges** — and
converging to zero is a complete, legitimate de-provisioning that has to keep
working. Already-revoked ledger entries don't count toward the number, so a
second identical run of an emptied file stays the silent no-op convergence
promises. Dropping *most* users — nineteen of twenty — is not yet gated;
that needs a threshold, where "the file is empty" is a bright line that needs
none.

**`@root` — seed keys from the door you came in through (#17).** A key field
of exactly `@root` means "this user's `authorized_keys` becomes root's
CURRENT `/root/.ssh/authorized_keys`". The point is lockout-avoidance: you
provably hold a root private key — you SSHed in with it to run apply at all —
so the seeded key is the one key rig can *know* opens for you; any pasted
literal can be a key you do not hold. `@root` mixes with literal lines
(seeded keys land first, literals append after), re-runs re-seed from root's
then-current file — convergent to it, so a seeded key you hand-remove from
the admin returns until you switch the line to literal keys — and apply dies
if root has no `authorized_keys` to seed. Root's key lines are copied
verbatim, options included: a `from=`/`command=` restriction follows the key,
and on a Coolify-managed box root's file also carries *Coolify's* key — on
`root-door=open`, prefer literal keys.

**Public tool, private state, here too.** The users file lives in *your*
private infra repo and is passed per invocation — rig never persists it. It
holds nothing secret anyway: usernames, roles, and *public* keys.

| role    | grants                                       | via group   |
|---------|----------------------------------------------|-------------|
| `admin` | full NOPASSWD sudo                           | `rig-admin` |
| `rig`   | NOPASSWD sudo for `/usr/local/bin/rig` only  | `rig`       |
| `box`   | Incus **restricted** tier, no sudo           | `incus` + `box grant` |

**The honest limit of the `rig` role:** its sudo grant is binary-scoped, not
argument-scoped — it trusts its holder with every rig verb *except* identity
management. The `rig users` commands gate their **invoker**: run under sudo
by anyone outside `rig-admin`, they refuse. Without that gate, a `rig users
apply` run through that grant, against a file naming yourself admin, would
make it silently root-equivalent through the very tool it scopes. Direct root — a
bring-up shell, before any admin exists — proceeds.

`box` binds where VMs live, and a users file is fleet-wide — its box grants
are not. **The `host=` trait decides whether the box role applies here, and
the `incus` group never overrides it.** On `host=no` — or a marker that names
no `host=` at all, or no marker — the role is **skipped with a warning** and
everything else, admins included, still converges: one box-role user
somewhere in the fleet must not stop apply everywhere VMs don't live. The
verdict is the same whether or not the group happens to exist.

That last part is the point. rig never installs Incus — box's `setup-host`
owns the daemon — so a `host=no` box can still carry a leftover `incus`
group from a previous life. Adding someone to it there would hand out the
socket with no tier behind it, and incus-user would lazily build them an
**unhardened** project on first contact: `incusbr-<uid>`, NAT on v4 *and*
v6, no ACL, no `dns.mode=none`, no port isolation. So on that mismatch apply
warns — naming the contradiction and `rig bootstrap --host yes` as the
repair — and **strips** box-role users out of `incus`, because an inherited
half-grant is the same defect as a fresh one.

The group's presence matters only once the trait already said yes: on
`host=yes` an absent `incus` group means the daemon was never set up, so
apply dies pointing at `box setup-host` rather than conjure a group nothing
would consult. `incus-admin` is deliberately **not** a role: that group is
host-root-equivalent, break-glass by hand only.

**The group is the socket; the tier is `box grant`.** On `host=yes`, apply
calls `box grant <user>` for every box-role user — the `incus` group is only
the first of the five steps that grant performs (the `user-<uid>` project,
its narrowing to `boxnet` and *only* `boxnet`, the snapshot and backup
allowances `box clone` and `box export` ride, and the shipped `box-profile`
profile installed into that project). rig calls box's own grant rather than
reimplementing four fifths of it: the "rig never installs Incus" boundary is
about installation, not invocation, and deferring here respects it harder
than a rig-side copy would. The group ADD is left to grant too, so a grant
that fails partway can take the socket back with it — rig opening the socket
first would leave a user with live access to an *un-narrowed* project, which
is worse than no grant at all. A grant that fails **warns and continues**:
one box-role user's project must not stop apply for the fleet. A missing
`box` CLI on `host=yes` **dies**, like the missing `incus` group — that is a
broken VM host, not a per-user accident.

Losing the `box` role goes back through box, too. `rig-admin` and `rig` are
rig's groups and a `gpasswd -d` is the whole story for them; `incus` is box's,
and `box revoke` does more with it than remove a membership — it says out loud
that supplementary groups are read **at login**, so a session the dropped
operator already holds keeps the Incus socket until it dies, and names
`loginctl terminate-user <user>` as the way to end it now. So apply calls
`box revoke` and lets box speak. Never `--purge`: that deletes the user's
boxes, images and project, and destroying someone's running machines is not a
convergence step — `box revoke <user> --purge` stays a deliberate admin act.
Where box is not installed (or the revoke returns success with the membership
still standing — an exit code is not effective state) rig removes the group
itself **and carries the session warning**, because a silent removal is what
lets an operator believe access ended when it has not.

**All passwords stay locked, always** — created or found. The SSH key at the
door is the authentication, and NOPASSWD sudo does not weaken it: there was
never a password to guess or rotate.

Convergence is exact. Membership in the three rig-managed groups is made to
match the file — added *and* removed — while every other group is left alone:
not rig's to converge. `authorized_keys` becomes exactly the file's keys, and
its ownership and mode (and `.ssh`'s) are converged on **every** run, not
just when content changes — sshd's `StrictModes` treats them as
load-bearing, so drifted perms are a broken login that "already converged"
would lie about. A user dropped from the file is found via the
`/etc/rig/users` ledger and **revoked, never deleted**: the account is
expired — the switch PAM actually enforces; a locked password alone still
lets a pubkey in under Debian's `UsePAM` — and `authorized_keys` is renamed
to `authorized_keys.revoked-by-rig`. Access revoked, data kept: deletion
frees the uid for reuse and orphans file ownership, so attribution would rot;
home stays for the same reason, and re-adding the user to the file brings
them back, fresh keys and all. And the sudoers rules land in
`/etc/sudoers.d/rig-roles` only after `visudo -c` passes on the candidate — a
bad file under `/etc/sudoers.d` can take down *all* of sudo, locking every
admin out of the very escalation path apply just granted.

### `rig manifest`

```sh
rig manifest                 # the whole provenance record
rig manifest converged_by    # one value, for a shell caller
```

Prints `/etc/rig/manifest` — **which rig converged this machine, and when**.
`rig bootstrap` writes it as its last durable act, beside the role marker;
this command only reads, needs no root (the file is `0644`), and works on a
machine whose rig has since been upgraded or removed.

```
schema=1
bootstrapped_by=0.4.0
bootstrapped_at=2026-07-19T14:24:51Z
converged_by=0.6.0
converged_at=2026-08-02T09:11:03Z
```

Two pairs: **birth** — the rig that *first* converged this machine, pinned
forever — and **latest** — the newest rig to have converged it. On a fresh
machine they are equal. The version recorded is the one that **ran**, captured
at run time; `rig --version` reports the tree installed *now*, which after an
upgrade answers a different question, because a machine outlives the rig that
built it.

Only **decided** facts live here, and that is what keeps bootstrap's
convergence contract intact. `bootstrapped_*` is first-write-wins;
`converged_*` moves **only when the version actually differs** — it records
the time the converging version last changed, not the time of the last run. A
re-run by the same rig therefore renders a byte-identical file and the
cmp-guard stays silent; a re-converge by a *different* rig is a real change and
the guard firing there is correct.

**Observed** facts — cores, RAM, disk, kernel — are deliberately absent: they
go stale on their own (someone adds RAM; unattended-upgrades patches the
kernel), so storing them would either lie or force a rewrite on every run. They
belong to `rig platform`, which computes them fresh and stores nothing.

`key=value`, one per line — never JSON, never YAML. This is the one file that
must stay readable on the most broken machine in the fleet, and a
rig-bootstrapped box has no YAML parser and no `jq`. Readers must ignore keys
they do not know, so `schema=` is bumped only when a key is removed or
repurposed; a manifest written by a newer rig stays readable to an older one,
and the writer preserves lines it does not own rather than eating them. Nothing
here is ever a credential.

Exits 1 when there is no manifest — a machine converged before rig wrote one,
or never converged at all. `RIG_MANIFEST` overrides the path.

The manifest does **not** replace `/etc/rig/role`. The marker holds *traits*
(what this box is) and has six readers; the manifest holds *provenance* (what
built it). Two files, two jobs.

### `rig users status`

```sh
rig users status
```

Read-only truth: per rig-managed user, the roles derived from the groups the
user is **actually** in — not the ledger's memory of an apply — plus the
`authorized_keys` count (`revoked` when only the `.revoked-by-rig` rename
remains) and the user's state, **active** or **revoked**. The state is the
ledger's word corroborated by the account's real expiry — the switch that
actually revokes — and a mismatch is flagged loudly as drift: a box someone
changed behind rig's back must never read as healthy. Reads the box only; no
network, no writes. Run as root (shadow is read).

### `rig users close-root`

```sh
rig users close-root
```

Shuts the root SSH door — `root-door=closed` boxes only, and only once a named
admin can already get in. The gates run in order: the `/etc/rig/role` marker
must resolve to `closed` — an absent marker refuses (never shut the root door
blind; re-run bootstrap so the box knows what it is), and `root-door=open`
refuses with no `--force`, because root there is the control plane's
automation identity and closing it severs fleet management. A marker written
before #77 says `class=human|server` and resolves to `closed|open`
respectively, so a box bootstrapped before the rename gates exactly as it
always did. Then at least one
`rig-admin` member must hold a login sshd would plausibly **accept** — a
non-empty `authorized_keys` alone proves a file, not a door: the gate checks
the `StrictModes` shape (home, `.ssh`, and `authorized_keys` owned by the
user and not group/world-writable), a real login shell, and an unexpired
account — and then two **reachability** proofs (#17): `sudo -n true` under
`runuser` must answer, so NOPASSWD sudo is effective rather than merely
written, and `sshd -T -C user=<admin>` must resolve a per-user effective
config that accepts the login (`pubkeyauthentication yes`, no `DenyUsers`
hit — where any pattern or `USER@HOST` entry counts as a hit, fail closed,
since `DenyUsers dan*` really denies admin `dan` and rig will not re-implement
sshd's pattern engine to prove a miss — `AllowUsers`, if set, names them
literally, and the same fail-closed pair for `DenyGroups`/`AllowGroups`
judged against the admin's actual groups), so a `Match` block elsewhere
cannot quietly exclude the admin
while every file looks right. The refusal names which check failed, per
candidate. What no local check can prove: that you *hold* the private key,
and how a `Match Address` rule treats your real client address (the probe
resolves against a synthetic `addr=127.0.0.1`) — which is why the
separate-session verification below stays load-bearing. Never close the only
door.

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

> **On `root-door=open`, root stays — so lock its key instead.** This is README
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
versioned install is proven by REAL installer runs: `RIG_INSTALL_SOURCE`
points install.sh at the tree under review and the harness drives it against
throwaway `RIG_HOME`/`RIG_BIN` roots — fresh install, converge, reinstall,
side-by-side upgrade, `use`/rollback, flat-tree migration, symlink healing,
the bootstrapped-host warning (via `RIG_ROLE_MARKER` fixtures), and both
uninstalls with their absence asserts. The
`rig users` family is covered the same way: the harness drives its refusal
matrix — users-file parsing, the marker gates, the lexical drop-in-name
assertion, the validate-then-apply ordering — through the sourced lib
functions, non-root and network-free. The tenant family follows the same
split: the harness proves the arg/refusal surface, the marker guards (off
fixture markers), the pure parameter table, and the rendered agent-context
file — guard note included — plus absence-greps for the creds-free contract;
the real converge belongs to the rehearsal. The end-to-end rehearsal is a
throwaway VM/container: pristine Debian → install → `bootstrap workload-server` with
a real single-use key → assert the sshd drop-in, tailnet join, and a no-op
second run → destroy, remove the node from the tailnet. The tenant rehearsal
is the same shape, creds-free: container + seed user → `rig bootstrap claude-box`
/ `staging-box` → assert the CLI answers, docker answers, `sshd -T`, the context
file — then re-run and watch it no-op.
