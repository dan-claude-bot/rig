# Changelog

History before 0.1.0 lives in git — rig grew its version surface (`VERSION`,
`rig --version`, the side-by-side `versions/<v>` install layout; #35/#36)
on the way to cutting its first release, and this file starts there.

## Unreleased

### Fixed

- **An unreadable check rollup no longer reads as "nothing is failing"** (#90)
  — when `gh pr view` failed, the fallback left the `statusCheckRollup` key
  absent entirely, and `(.statusCheckRollup // [])` collapsed that into the
  same `NONE` as a PR that genuinely has no checks. `NONE` blocks nothing, so
  a transient API failure presented the PR as mergeable by a human: an unknown
  certified as green, which is the exact shape of the bug #87 was opened to
  stop, surviving in the one place that fix never looked.

  `checks_state` now separates the two — `UNREADABLE` for an absent key (a
  read that failed), `NONE` for a present-but-empty array (a PR that really
  has no checks) — and the sweep leaves an `UNREADABLE` PR exactly as it
  found it rather than recomputing labels from facts it did not read.
  Deliberately *not* a blocker: blocking would flap the whole board on one bad
  API call, and the next tick is fifteen minutes away. Caught by the author
  after opening the PR, not by review.

- **CI runs `test/labels-reconcile.sh`, which it had never run** (#90) — the
  file arrived with #87 and `ci.yml` was not extended to call it, so the label
  state machine that gates every PR in this repo went covered only by whoever
  remembered to run its fixtures by hand. #88 merged reporting 51 passing
  fixtures: true on the author's machine, never once verified here. Box and
  cast both ran the suite already; only rig did not, so this closes a rig-local
  gap rather than a family-wide one. It was found by asking, while adding
  fixtures to the suite, where the suite actually ran.

- **`state:needs-human` no longer appears on PRs a human cannot merge**
  (#87, heavy-duty/box#136) — `decide_state()` derived state from three inputs
  (draft flag, requested reviewers, submitted reviews) and read *nothing* about
  mergeability or checks. Combined with the `if requested "$HUMAN"`
  short-circuit at the top of its precedence, the label was **sticky**: once
  the maintainer was requested, the PR read `state:needs-human` through
  conflicts, through red CI, through a force-push that staled every approval.
  Nothing demoted it.

  This repo paid for it directly. During the ten-PR batch merged on 2026-07-20,
  every merge re-conflicted the PRs below it through `CHANGELOG.md` — and each
  one kept its `state:needs-human` label the whole time, inviting a merge that
  could not happen. It was noticed only by opening them one at a time, which is
  the exact work the label exists to save.

  The rule the label now keeps is that **`state:needs-human` means a human
  could merge this right now**, so anything making that false outranks the
  request that put it there. A `CONFLICTING` branch or a failing check is the
  agent's to fix: new `state:needs-rebase`. Approvals staled by a push mean
  nobody reviewed this tree: `state:addressing`, because the agent owes a
  re-request. An *unfinished* round still yields to an explicit human request —
  a maintainer pulling a PR to themselves early is deliberate, and `MISSING`
  (nobody has reviewed yet) is a different fact from `STALE` (everyone reviewed
  something else). Precedence is applied to the round as a whole, after every
  verdict is collected: deciding inside the loop let the order of `BOTS` pick
  the answer, so a round that was *both* unfinished and staled returned on the
  `MISSING` before any later bot's `STALE` was read — and came out
  `needs-human` over a head nobody had reviewed, the original bug wearing a
  different hat.

  Whether a check blocks is judged by listing the outcomes that *don't* —
  `SUCCESS`, `NEUTRAL`, `SKIPPED`, and the pending set — rather than the
  outcomes that do. The rollup mixes two closed enums (`CheckRun.conclusion`
  and `StatusContext.state`), and an outcome the list forgets is one the label
  cannot certify as mergeable: `ERROR`, `CANCELLED` and `STALE` all read as
  green under an allow-list of failures. The costs are not symmetric — a false
  failure parks the PR on the agent, who looks; a false success invites a human
  to merge a tree that will not merge. Superseded runs are dropped first, each
  context collapsing to its newest entry: a re-run does not evict the run it
  replaced, so box#137's own tip carried a `CANCELLED` `scope` beside the
  `SUCCESS` `scope` that superseded it, and judging every entry would have
  stranded every re-run PR in `needs-rebase`.

  Which entry is newest is dated by **when the run began** — `startedAt`,
  falling back only if it never recorded one — discarding *both* spellings of
  absent. A run still in flight has no completion, but `gh` does not omit the
  field: its Go struct marshals the zero time as the string
  `0001-01-01T00:00:00Z`, and `//` falls through `null` and `false` only.
  Dating by completion therefore sorted the *live* re-run to the bottom and
  let `last` pick the very run it superseded — a green context with a
  replacement mid-flight read `SUCCESS`, inviting a merge the button had
  already disabled, which is #136 restored by the fix for it.

  Taking the *newest* stamp each run carries is not a fix either, and this is
  the subtle part: it compares a finished predecessor by when it **ended**
  against a live successor by when it **began**, which is not an ordering on
  runs at all. A run cancelled by the concurrency group does not stop the
  instant its replacement starts — the runner has to receive the signal and
  wind down — so the predecessor completing *after* the successor started is
  the ordinary case, 13s wide on the box#137 tip that motivated the supersede
  rule. For that whole drain window the dying predecessor out-dated its own
  replacement. One consistent quantity, start time, is the only ordering that
  holds. An entry carrying no usable timestamp at all sorts last rather than
  first, so something that cannot be dated is never discarded in favour of a
  stale success. Every ambiguity here resolves toward "not settled".

  `UNKNOWN` mergeability is deliberately not treated as unmergeable: GitHub
  reports it for about a minute after every merge while it recomputes, and
  flapping every open PR through `needs-rebase` on each merge would be worse
  than the bug. A failed read of either fact degrades to the same "do not know"
  value, for the same reason.

  Also adds `merge-next`, because a correct `needs-human` still does not say
  *which* PR to merge first, and order matters when they conflict. Queue order
  is intent, so the reconciler never sets it — it only **clears** it once the
  PR stops being mergeable-by-a-human, which is precisely the staleness that
  made `needs-human` untrustworthy. Both live shapes, the mixed round, the
  whole check-outcome enum, and the re-run in every temporal arrangement it
  occurs in — superseded, still in flight in both spellings of an absent
  completion, undateable, and still draining past its replacement's start —
  are pinned in `test/labels-reconcile.sh`. Ported from heavy-duty/box#137 so
  the three repos' reconcilers stay byte-identical; fixtures 19 → 51.

### Added

- **`rig platform` — what is this machine, calculated at run time, stored
  nowhere** (#64) — rig read no hardware at all; the single exception was
  `uname -m` in `runner-install.sh`, used to pick a tarball and then
  discarded. So "is this the 32GB one, or the M900?" was answered by logging
  in and running `free -h`, `nproc`, `df -h` and `uname -r` by hand, four
  commands deep, on a machine you were already unsure about. `rig platform`
  prints hostname, OS, kernel, CPU, memory, disk and virtualization, then a
  provenance block (which rig, when, and the role marker's traits). It
  **computes rather than stores**: specs change without rig doing anything —
  RAM added, root disk resized, the unattended-upgrades bootstrap itself
  enables patching the kernel — so a stored spec is stale the moment the
  machine changes, and refreshing one per run would collide with bootstrap's
  "a second run changes nothing" contract. Nothing is written, so nothing can
  go stale. The corollary is deliberate: reading only `/proc`, `uname`,
  `/etc/os-release`, `df` and `systemd-detect-virt` means it needs no root,
  makes no network call, and **runs on a pristine Debian box rig has never
  bootstrapped** — useful for deciding what to converge a machine into, not
  only for auditing it afterwards. That also makes it the rare rig command
  the harness can RUN for real instead of grepping: the tests assert the
  actual answer describes the actual test machine. Provenance is read, never
  written, and degrades per-file — `/etc/rig/manifest` is #61 and does not
  exist yet, so those lines read `not bootstrapped` on every machine today and
  nothing else depends on it. The reader is keyed to #61's documented schema
  (`schema`, `bootstrapped_by`/`_at`, `converged_by`/`_at`) and fixtures pin
  that exact spelling, so the integration cannot land silently broken; birth
  and latest stay separate rather than one being inferred from the other. A
  fresh machine writes both pairs equal, so two identical lines read as
  "never re-converged"; a manifest missing the pair is partial rather than
  fresh, and says so instead of backfilling from birth. Named `platform` and not `status` on purpose:
  `users status` and `runner status` cross-check recorded against live state
  and print `DRIFT`, and a command that records nothing cannot drift — which
  also leaves `rig status` free for the machine-wide roll-up. Known
  limitation, stated rather than guessed at: `CPU`/`MEMORY` are read from
  `/proc` with no cgroup awareness, and whether an `lxc` guest sees its own
  limits or the host's totals depends on whether `lxcfs` is in play — it is
  unverified, so those two lines are unreliable there.

- **`/etc/rig/manifest` records which rig converged a machine, and when**
  (#61) — the entire durable output of a bootstrap run was one line in
  `/etc/rig/role`, and that line is about what the box *is*, never about what
  built it. `VERSION` was read in exactly one place (`bin/rig:9`, for
  `--version`) and that reports the *currently installed* tree, not the one
  that ran; there was no timestamp anywhere in the codebase. SSH into a
  control plane six months on and a machine converged by `0.1.0-dev` was
  indistinguishable from one converged by `0.4.0`. Bootstrap — both the
  machine roles and the box tenant roles — now stamps a second file beside
  the marker: `schema=1`, `bootstrapped_by`/`bootstrapped_at` (the rig that
  *first* converged this machine, pinned forever) and
  `converged_by`/`converged_at` (the newest rig to have converged it), read
  back with a new `rig manifest [<key>]`. `key=value`, one per line, `0644` —
  never JSON or YAML, because this is the one file that must stay readable on
  the most broken machine in the fleet and a rig-bootstrapped box has no YAML
  parser and no `jq`.

  Only **decided** facts go in, which is what keeps `bootstrap.sh:3`'s
  contract ("a second run changes nothing", enforced by cmp-guards at nine
  sites) intact: `bootstrapped_*` is first-write-wins, and `converged_*`
  updates **only when the version actually differs** — it is the time the
  converging version last changed, not the time of the last run. A naive
  timestamp would have made every re-run a diff and had rig report a change it
  did not make. **Observed** facts — cores, RAM, disk, kernel — are
  deliberately absent: they go stale without rig doing anything, so they
  belong to `rig platform` (#64), which computes them fresh and stores
  nothing. `/etc/rig/role` is untouched — the marker holds traits and has six
  readers; the manifest holds provenance. Readers must ignore keys they do not
  know, and the writer preserves lines it does not own, so a manifest written
  by a newer rig stays readable to (and survives a rewrite by) an older one.

### Changed

- **PR labels split into two axes: `state:*` (whose ball) and `blocker:*`
  (what is in the way)** (heavy-duty/box#137) — `state:needs-rebase`, added
  here only days ago by #87, is retired in the same breath. In its place:
  `blocker:conflict`, `blocker:ci-red` and `blocker:unrequested`, applied
  additively. A single rule joins the axes — `state:needs-human` requires zero
  blockers — which is the invariant #87 was reaching for, stated once instead
  of defended at every branch of a precedence chain.

  The single-label design projected independent facts onto one totally-ordered
  value. Mergeability, check status and the review round move on their own
  clocks; a PR can be conflicted *and* red *and* stalled at the same instant.
  A total order has to pick one of those to say, so the rest vanish. Every
  precedence bug this machine has had lived on that ordering, #87's included:
  the fix there was to reorder the chain and collect the round before deciding,
  which bought correctness for one more configuration without removing the
  reason the next one would break. `state:needs-rebase` was the design's
  clearest tell — a single label fired by both a conflict and a failing check,
  two problems needing opposite work, telling an agent to rebase when what it
  owed was a bug fix. Box's board has the case in the open: #120 was conflicted
  **and** red, and could only ever say one of them.

  Blockers are a set. There is no precedence between them to get wrong, and
  adding a fourth one later cannot reshuffle the meaning of the other three.
  What stays on the ordered axis is purely the review round, which is the one
  place here where an ordering is genuinely meaningful — a round really does
  have a sequence.

  `state:bots-reviewing` tightens with it, to mean strictly *a request is live
  and an answer is coming*. A ready PR nobody was asked to review used to read
  as "waiting on the reviewers" until the stale sweep caught up; it now reads
  `state:addressing` + `blocker:unrequested`, because the agent owes the ask
  and the board should say so. `blocker:unrequested` covers both shapes of
  "this head has no verdict from somebody": nobody reviewed it, or everybody
  reviewed an older tree and the approvals staled behind a push. The second is
  the worse of the two, since it leaves approvals on the page that no longer
  describe the code. Drafts stay exempt — the bots ignore drafts by design —
  as does an explicit human request, since a maintainer claiming a PR early is
  deliberate.

  The reconciler strips `state:needs-rebase` on sight via a `RETIRED` list, so
  the retirement heals the existing board instead of stranding a label that
  nothing recomputes. It also filters every label it is about to *add* against
  the repo's actual label set, read once per sweep: `gh issue edit` rejects the
  whole call on one unknown name, so on a repo that has not yet bootstrapped
  the new `blocker:*` labels a single missing one would have taken the state
  convergence down with it — on exactly the PRs this change exists to heal.
  Now the state still converges and the missing labels are named in the log.
  Fixtures 51 → 72.

- **BREAKING: `--class human|server` is now `--root-door closed|open`** (#77) —
  the trait was named for who *lives on* a box; what it decides is one thing,
  and it is not occupancy: whether root SSH stays open as the control plane's
  automation door, or `rig users close-root` shuts it once named operators can
  get in. The roles had been saying so for a while. `dev-server` is an
  unattended VM-host appliance — nobody lives there, operators visit it to mint
  boxes and leave — and by occupancy it is plainly a server. It was
  `class=human` anyway, and correctly so, because operators enter it *as
  themselves* and its root door must close. The trait was right; its name
  described the wrong axis.

  That stayed cheap until a second thing wanted the word "server". After #76
  the `-server` suffix names the machine *family*, so `dev-server` carried a
  suffix saying server and a trait saying human, and nothing in the name told a
  reader that the two words were answering unrelated questions. `dev-server
  --root-door closed` says exactly what is true, and `-server` means one thing
  everywhere. The values moved with the name: `human` → `closed`, `server` →
  `open`, and the marker field follows as `root-door=`.

  Other names were considered. `--root-door open|closed` describes a
  *destination* rather than the state at bootstrap time — bootstrap leaves root
  SSH open on every box, and the door only shuts later, when `close-root` runs
  — so `--root-door closes|stays` was on the table for naming the fate as a
  verb, as was `--automation-door yes|no` for naming the thing itself. Both were
  rejected in favour of the plainer pair: the marker is already a declaration of
  *intent* rather than a report of observed state everywhere else in this repo
  (`host=yes` claims a box hosts VMs; #58 settled that the marker's claim wins
  over probing the machine), so a trait that states the door's designed end
  state is consistent with how every other field is read. Every string that
  prints the trait says "once operators exist" or names `close-root` explicitly,
  so the tense never has to be inferred.

  **Old markers still resolve, permanently, and that is the substance of this
  change.** Unlike #76's role rename — role names are informational, nothing
  reads them back — this field is written into `/etc/rig/role` and read *from*
  there on live machines, where it gates `rig users close-root`. Every box
  bootstrapped before this carries `class=human` or `class=server` and carries
  it until someone re-bootstraps it, which for a fleet is never. Dropping the
  old read would have broken in both directions at once and both are incidents:
  a machine whose door is supposed to close loses the ability to close it, and
  — through `bootstrap-tenant`'s machine-marker guard, which used the presence
  of `class=` as its "is this a real fleet machine?" test — a live box stops
  looking like a machine at all, so a tenant converge sails past the refusal
  that exists to protect it and clobbers its marker. That second one is the
  fail-*open* direction and was the least obvious part of the change.

  So one resolver, `root_door_of`, reads both vocabularies, and every consumer
  goes through it — close-root's gate, apply's root-SSH note, and the tenant
  guard — because a compat read that lives at three call sites is three chances
  to drift. `root-door=` wins where both fields are present and agree;
  `class=` answers alone on every pre-#77 marker. A marker carrying **both and
  disagreeing** resolves to a refusal rather than a winner: bootstrap writes one
  line fresh and never produces that state, so a marker in it was hand-edited,
  and rig declines to arbitrate between two equally-authored claims about a root
  door. A marker naming **neither** refuses too, unchanged from before. Both
  refusals fail closed, which here means the door stays open and the operator is
  told to re-run bootstrap — never a door welded shut on a machine whose only
  entrance it was.

  The resolver matches **whole fields, not substrings** — the marker is one
  line of space-separated `key=value` pairs, so it pads both ends and matches
  on field boundaries. Review caught the first cut doing unanchored matching,
  which resolved any value that *extended* a real one: `root-door=closedish`
  read as `closed` and passed close-root's gate — the single arm that
  authorizes an irreversible act — and `class=humanoid` did the same through
  the compat arm, both contradicting the resolver's own promise that a value
  outside the set resolves empty and fails closed. Only reachable by hand-
  editing a marker, so never a live incident, but this is the one function
  every consumer trusts and it owes them exactness rather than nearly. Both
  vocabularies are anchored: fixing only the current spelling would have left
  every pre-#77 box carrying the hole. Whitespace is normalised first, so a
  hand-edit using tabs reads the same rather than trading one silent misread
  for another.

  **New markers are written in the new vocabulary only.** Writing both would
  keep an old rig reading a new marker, but it would entrench the retired
  spelling on every box rig ever converges and make the disagreement case
  reachable from rig's own hand instead of only from a text editor. The compat
  obligation runs the other way and only the other way: new rig reads old
  markers. The bounded consequence to know about is downgrade — flipping a
  box back to a pre-#77 rig with `rig use` leaves that older code unable to
  recognize the new marker; the flip already WARNS on a bootstrapped host (#35),
  and re-running bootstrap under whichever rig you settle on rewrites the line.

  The suite proves the compat read rather than asserting it. Fixture markers are
  kept **deliberately** at the retired spelling — byte for byte as a real
  pre-#77 box reads, the same convention #76's `pre-rename-cp` fixture
  established — and pinned at both consumers: `close-root` still passes on
  `class=human` and still *refuses* on `class=server`, with today's refusal text
  naming today's flag, and the tenant guard still recognizes a pre-#77 machine
  marker as a machine. Deleting the compat arm turns ten of them red.

- **BREAKING: the box tenant roles carry a `-box` suffix** (#76) — the other
  half of the rename below. `claude` → `claude-box`, `codex` → `codex-box`,
  `grok` → `grok-box`, `staging` → `staging-box`, so a role name always says
  which family it belongs to: `-server` builds a fleet machine, `-box`
  converges a guest a box minted.

  **The role carries the suffix; nothing inside the guest does.** A tenant user
  is the account the box *seed* created (`BOX_USER`) and each agent CLI reads
  its own dotdir, so `claude-box` still converges the `claude` user and still
  writes `~/.claude/CLAUDE.md`. The suffix is rig's word for "this is a guest",
  not a rename of anything the guest contains — no path, no account, and no CLI
  binary moved.

  **Migration: hard cut, no aliases**, same as the machine roles. The old names
  are refused as unknown tenant roles at both entrypoints — `rig bootstrap
  <name>` and the tenant script directly — and the suite asserts each one at
  both, because an alias left in for a single tenant is exactly the shape that
  survives review: the taxonomy reads complete while one old name still quietly
  converges. The practical consequence is cross-repo: a box seed carrying
  `BOX_BOOTSTRAP_ROLE="claude"` now fails its own mint-time bootstrap, so
  heavy-duty/box#125 (closing heavy-duty/box#123) updates the seeds and must
  land after this.

- **BREAKING: machine roles carry a `-server` suffix, and the VM host gets its
  name back** (#76) — rig builds two kinds of thing that sit on opposite sides
  of a trust boundary: tailnet **machines** it converges, and **guests** a box
  mints. Both families lived in one flat namespace, and no role name said which
  one you were asking for. `staging` is where that stopped being cosmetic — the
  word names the metal that hosts guests *and* the guests on it, only one of
  them could have the name, and #31 gave it to the guests. The VM-host shape
  was left with no name at all, spelled `custom --class server --host yes
  --join authkey`, which is what every refusal in the tree recited at an
  operator who had confused the two.

  So the suffix names the family: `control-plane-server`, `workload-server`,
  `runner-server`, `dev-server`, and the restored `staging-server`
  (`class=server host=yes join=authkey` — the preset #31 retired, back under a
  name that cannot be mistaken for its own guests). `host=yes` already installs
  the box CLI and runs box's `setup-host`, so `staging-server` is a table row
  rather than new machinery, and it stays **out** of the `tag:server`
  allow-list on purpose: a host is never managed by the control plane, its
  guests are, so mint its key with `tag:local`.

  **`custom` and `workstation` keep bare names**, and that is the rule rather
  than an exception to it. `custom` presets nothing and can be any shape — a
  guest included — so a family claim is one it cannot make. `workstation` is
  somebody's own device rather than fleet infrastructure: it joins by
  interactive login, comes up user-owned and untagged, and the tailnet never
  manages it.

  **Migration — this is a hard cut, with no aliases.** The old names are
  refused as unknown roles; a box bootstrapped under one is re-bootstrapped
  rather than migrated, which at this fleet size costs less than four
  deprecation paths each quietly keeping an old name alive. Two consequences
  worth knowing before you re-run anything. `TS_HOSTNAME` defaults to the role
  name, so a box that took the default now comes up as `control-plane-server`
  rather than `control-plane` — pass `--hostname` to hold a name steady, and
  check anything pinning one (ACL entries, a `cast` `environments.yaml` server
  name, host keys). And `rig coolify install` / `rig coolify backup install`
  match the **role name** in `/etc/rig/role`, so they now look for
  `role=control-plane-server`; a pre-rename control plane takes their warning
  branch until it is re-bootstrapped. That check has always been advisory and
  never a gate, so the run still proceeds and the warning names the repair.

  The rename also reaches every string that *tells an operator to run a role*,
  not just the code that accepts one — `bootstrap-tenant.sh` emits the staging
  guest's tailnet-join next step (`sudo rig bootstrap workload-server`), and
  two of its refusals recite the machine-role list. A stale next-step is worse
  than a stale flag: it fails when someone copy-pastes it, on a different box,
  minutes after the run that printed it reported success. `test/cli.sh` sweeps
  every shipped script for pre-rename role names rather than pinning the known
  sites, because the next instance of this will be somewhere else.

  `dev-server` was `class=human` when this landed, which read like a
  contradiction and was not: the suffix names the family, the class named the
  root-SSH door policy, and operators enter a dev box as themselves so
  `close-root` shuts its door. The two axes genuinely shared the word "server",
  which was a wart — #77, above, renames the trait to what it actually controls
  and retires it. It stayed a separate change because it reaches markers on live
  machines that guard root SSH, and so needed a compat read this rename did not.

### Fixed

- **CI's shellcheck sweep now reaches `.github/scripts/`** (#70) — the step
  ran `shopt -s globstar` and globbed `bin/* **/*.sh`, but globs skip
  dot-prefixed names without `dotglob`, so `**/` never descended into
  `.github/` and two tracked scripts were linted by nothing:
  `labels-reconcile.sh` and `release-lib.sh`. The second is the one that
  stings — it holds `changelog_section`, the extraction `release.yml` sources
  to build the published release body and the same function `test/release.sh`'s
  `changelog_armed` guard (#66) calls to decide whether main is armed. The
  script deciding both what ships and whether the changelog is safe was the
  script CI never read. Adding `dotglob` pulls in exactly those two files and
  nothing else; both already pass, so this closes a hole in the net rather
  than fixing a defect behind it. Paired with a class check that fails the
  step when any tracked `.sh` falls outside the globbed set, so the gap
  cannot reopen quietly — including via a symlinked directory, which
  `globstar` declines to traverse.

- **Ctrl-D at the `rig uninstall` confirm no longer aborts in silence**
  (#68) — `uninstall_confirm`'s `read -r reply` was unguarded. Under
  `set -euo pipefail`, and called as a plain statement, EOF made `read`
  return non-zero and killed the shell *at the read* — the `case` on the
  next line never ran, so `die "aborted."` never fired. The operator saw
  the question, pressed Ctrl-D, and got nothing back: no message, just
  exit 1, at the exact moment the tool had asked whether to delete their
  install. It failed closed (nothing was ever removed), but nothing said
  so. Now `read -r reply || reply=""`, so EOF falls through to the `*)`
  arm and aborts out loud — the spelling `commands/db.sh` already used for
  the same `[y/N]` shape, one file away. `test/cli.sh` gains the first
  drills of the interactive path, driving `y` and Ctrl-D through a real
  pty (util-linux `script`, skipped where it is absent) and asserting the
  MESSAGE rather than the exit code, which the bug also produced.

- **`users apply` now tells "revoke everyone" apart from "I truncated the
  file"** (#65) — a users file naming zero users is a valid instruction to
  revoke every operator on the box, and it is indistinguishable from a file a
  stray `>` produced. The per-user warnings apply already emitted arrive after
  the decision and scale wrong: twenty operators is twenty lines of scrollback,
  so the signal was loudest exactly where it read as noise. The `/etc/rig/users`
  ledger draws the line apply needs — an empty file against an empty ledger is
  an unambiguous no-op; against a populated one it closes every named door — so
  only the second case now stops, states how many operators are about to be
  revoked, and requires explicit consent: `--yes`, `RIG_YES=1` (the
  installer-family variable `rig uninstall` already reads), or a `y` on a TTY.
  Without a terminal and without consent it exits 2, in `uninstall_confirm`'s
  words, rather than assume a yes it cannot ask for or hang on a prompt nothing
  can answer. A **confirmation**, not `rig bootstrap`'s flat refusal of the same
  file (#57/#59): bootstrap asserts who lives on a box, apply converges, and
  converging to zero stays a legitimate de-provisioning. Ledger entries already
  marked `revoked` don't count toward the number, so a second identical run
  stays the silent no-op. Mass revocation below the empty-file bright line (a
  file dropping 19 of 20) is deliberately still ungated — that needs a threshold
  someone has to justify, and #65 stays open for it.

## 0.2.0 — 2026-07-19

### Added

- **`users apply` grants the box *tier*, not just its socket** (#49) — role
  `box` resolved to exactly one action, `usermod -aG incus`. That is the
  socket; it is step 1 of the five `box grant` performs, so every box-role
  user still needed an admin to run `box grant <user>` by hand before their
  first `box new` would do anything but refuse ("your project has no box-net
  profile"), and until that admin arrived they held an `incus` membership
  with no converged project — incus-user would lazily hand them a stock
  unhardened NAT bridge, which is worse than no grant at all. On `host=yes`
  apply now calls `box grant` per box-role user, after `useradd` (grant
  refuses an unknown account) and with the group ADD deferred to grant, so a
  grant that fails partway can take the socket back with it. Failures split
  the way the `host=` guard beside them already splits: a missing `box` CLI
  on `host=yes` dies (a broken VM host), a per-user grant failure warns and
  continues (one box-role user must not stop apply for the fleet). `host=no`
  and marker-less boxes keep their existing skip-with-warning. An
  `incus-admin` member is warned, not fatal — `box grant` refuses them today,
  which heavy-duty/box#99 fixes box-side with no rig change needed.

### Changed

- **BREAKING: `rig bootstrap` takes the users file, and requires it** (#51) —
  bootstrap already knew everything else about what a box *is* (class, host,
  join, hostname) and wrote `/etc/rig/role` to say so; the users file was the
  last piece of that answer it did not take, so bring-up was two commands and
  the second was the forgettable one. `--users <path>` now runs the `users
  apply` convergence as bootstrap's **final phase** — after the traits, after
  the verified tailnet join, after the role marker (apply *reads* that
  marker), and after the `host=yes` box install (so box-role users find the
  `incus` group box's own `setup-host` built). One command, and the box has
  its people on it. The file is still passed per invocation and **never
  persisted**; `--users -` is refused, because bootstrap's stdin belongs to
  the pre-auth key prompt.

  **Migration: every existing `rig bootstrap` invocation must add `--users
  <path>` or `--no-users`.** Omitting both is now a usage error (exit 2)
  naming both flags, and passing both is a usage error too. Scripted
  bring-up that already ran `rig users apply` as a separate step can either
  fold it in (`--users ./users`, and drop the separate call) or keep the old
  shape verbatim by adding `--no-users`. Required on `class=server` as well
  as `class=human`: a server nobody logs into routinely is exactly where
  shared-root access rots, and per-human accounts keep attribution intact
  for the times someone does go in — so the complete path is the default
  path, and skipping it is deliberate rather than an omission that looks
  identical to forgetting. The box TENANT roles (`claude|codex|grok|
  staging`) take neither flag: a guest is minted non-interactively by box,
  never joins the tailnet, and has no SSH door of its own — entry is `box
  shell`, gated by the host's `incus` grants.

  A bad users file is caught **up front** now (the same parser apply uses,
  before `apt`, the hostname change, and any spent pre-auth key), and on
  `host=yes` with `RIG_SKIP_BOX_INSTALL=1` a box-role user with no `incus`
  group refuses immediately instead of a hundred lines later — the one case
  where the outcome is already certain. rig still never installs Incus and
  never calls `box setup-host` on its own account; every other way that step
  can fail lands in `users apply`'s existing refusal, unchanged.

### Fixed

- **A release no longer disarms the changelog under the PRs still in
  flight** (#67) — the ceremony stamps `## Unreleased` to
  `## X.Y.Z — YYYY-MM-DD` and stops. Every PR authored before that merge
  wrote its entry under `## Unreleased`; with the heading gone, git files
  the entry under whatever now occupies the position — the release that
  already shipped. There is no conflict, because the stamped heading and
  the incoming entry never overlap textually, so the one signal an author
  relies on ("git told me to look") is absent exactly when the outcome is
  wrong. It happened here: #60's #58 entry landed inside `## 0.1.0` at
  `67386b4` and was repaired two minutes later by `0ff520c`; #54 would
  have filed a **BREAKING** entry the same way. The published release body
  is never affected — `release.yml` extracts it from the tree at the tag,
  before the late merges land — so the only file that drifts is the one
  only maintainers read, which is why it survived a whole release batch
  unnoticed. Fixed in both halves the failure has. The ceremony now
  **re-arms**: it adds a fresh empty `## Unreleased` above the section it
  just stamped, so a late merge has somewhere correct to land with no
  author action. That belongs to the ceremony step in
  [CONTRIBUTING.md](CONTRIBUTING.md), not to `release.yml` — no workflow
  has ever touched the heading; the stamping was always by hand, and the
  `-dev` re-arm the workflow does perform was only ever about `VERSION`.
  And `test/release.sh` now keys its guard to `VERSION` rather than
  demanding a literal heading: a stamped top section is legal exactly when
  `VERSION` is bare, and the moment it carries `-dev` — main, where
  feature PRs merge — the top section must be `## Unreleased`. That
  distinguishes the two states the old check collapsed into one, so it
  catches a disarmed main **without** re-breaking the ceremony's own tree
  the way the pre-#44 guard did. The rule is proven against seven
  constructed `VERSION` + `CHANGELOG.md` pairs, including a re-armed
  ceremony whose top section is legitimately empty — the state the old
  non-empty assert would have rejected. box and cast carry the same flow
  and the same exposure (`heavy-duty/box#96`); cast is disarmed on `main`
  as of this writing and is getting the sibling fix.

- **A `host=no` box with an `incus` group no longer hands out the bare
  socket** (#58) — `users apply` consulted the `host=` trait only when group
  `incus` was ABSENT (die on `host=yes`, skip on `host=no`). When the group
  was PRESENT the trait was never asked, so a `host=no` or marker-less box
  that nonetheless carried the group — `box setup-host` ran, then the box was
  re-bootstrapped with other traits — gave every box-role user a bare
  `usermod -aG incus`: the socket with no tier behind it, which `incus-user`
  answers by lazily building an UNHARDENED project under whoever opens it
  (`incusbr-<uid>`, NAT on v4 and v6, no ACL, no `dns.mode=none`, no port
  isolation). The marker now decides in BOTH directions, through one new pure
  gate (`assert_marker_hosts_vms`, testable against fixture markers non-root
  like `assert_marker_human`): the box role applies only where the box CLAIMS
  to host VMs, so the verdict is identical whether or not the group exists.
  The machine deliberately does not overrule the marker — but the skip is not
  silent either: when the group exists and the trait disagrees, the warning
  names the contradiction and `rig bootstrap` as the repair. On such a box
  exact-membership convergence now strips box-role users out of `incus`, on
  the same reasoning: a membership inherited from a previous life is the same
  half-grant as a freshly added one.
- **Dropping the box role revokes through `box`, not behind its back**
  (#50) — `users apply` converged group `incus` with a bare `gpasswd -d`,
  the same move it makes for `rig-admin` and `rig`. Those two are rig's;
  `incus` is box's, and `box revoke` does strictly more with it: it says
  out loud that supplementary groups are read at LOGIN, so a session the
  dropped operator already holds keeps the Incus socket until it dies, and
  hands over `loginctl terminate-user <user>` as the remedy. rig logged
  `removed <user> from incus` and moved on, so an operator who dropped
  someone from the users file and watched apply succeed believed the VM
  access was gone — and was wrong for as long as that user held a session.
  Both removal paths (the per-user convergence and the dropped-user sweep)
  now call `box revoke`, which keeps one owner for the group. Never
  `--purge`: that deletes the user's boxes, images and project, and
  destroying someone's running machines is not a convergence step — it
  stays an explicit admin act. The exit code is not trusted (#12's lesson):
  a revoke that returns 0 with the membership still standing has not closed
  the socket, and rig falls back to removing the group itself, as it also
  does where box is not installed. Every fallback path carries the session
  warning, because the silence was the bug.
- **`rig bootstrap` refuses a users file that names no users** (#57) — an
  empty, comments-only or whitespace-only file is not a parse error, so it
  passed pre-flight, converged nothing, and left the box root-only: the exact
  outcome `--no-users` exists to make explicit, reached by the flag added to
  guarantee the opposite. Bootstrap's pre-flight now catches the zero-user
  parse — before `apt`, the hostname change, or a spent pre-auth key — and
  refuses, naming `--no-users` as the way to ask for a root-only box out loud.
  Scoped to `rig bootstrap`'s contract only: a standalone `rig users apply`
  against an emptied file is a real de-provisioning operation and is
  unchanged.

## 0.1.0 — 2026-07-19

### Fixed

- **The release suite accepts the ceremony's own tree** (#44) —
  `test/release.sh` demanded a literal `## Unreleased` heading in the real
  `CHANGELOG.md`, extracting non-empty and containing `#32`. All three are
  false by construction on the `release: X.Y.Z` tree the ceremony's own PR
  produces (it stamps that heading into `## X.Y.Z — date`), so the first
  real release PR turned CI red and the flow blocked itself — invisible to
  both fork rehearsals, which tag a branch (`release.yml` runs; `ci.yml`
  never does). The guard now asserts what it was for: whatever the TOP
  `## ` section is — `Unreleased` between releases, the stamped version on
  and right after one — the exact `changelog_section` the workflow runs
  extracts it non-empty. The rotting issue-number grep is gone.

- **The installer survives an environment with no `$HOME`** (#39) —
  cloud-init's `runcmd` runs `install.sh` with no `$HOME` set, and under
  `set -u` the first expansion died with a bash unbound-variable stack
  instead of an install — found live by box#88's template seed, which
  pins `HOME=/root` as its own scar. The installer now derives the home
  from `getent` for the effective user (root included) before any path
  is built from `$HOME`, and when getent has no answer either it refuses
  by name. Driven with a shim getent both ways: the derived-home install
  lands, the no-answer refusal is pinned. (#41 — merged without its
  entry; restored here at the release gate.)
- **Headless credential prompts refuse loudly instead of dying silently**
  (#42) — the interactive credential prompts (`TS_AUTHKEY` in `bootstrap`,
  `RUNNER_TOKEN` in `runner install`, `RUNNER_REMOVE_TOKEN` in
  `runner remove`, and both tokens in `runner repoint` — a site the new
  no-bare-read test caught after the issue counted three) were bare
  `read -rsp`: with stdin not a tty (CI,
  `box exec`, any script), `read` fails, `set -e` ends the run, and the
  log just *stops* — exit 1, no last word, measured live in the
  2026-07-19 release drill. Each prompt now checks for a tty first and
  dies naming the variable that unblocks an unattended run (`runner
  remove` also names `--local`), and every `read` is `|| die`-guarded so
  EOF at a real prompt gets the same courtesy. `db.sh` already held the
  line here; now all of rig does.

### Added

- **Merging a release-labeled PR IS the release — and the release re-arms
  main itself** (#47) — the rig twin of heavy-duty/box#96, born of the
  ceremony retro: the tag was a separate, manual, silent-when-forgotten
  step, and a forgotten tag produces no red X. `release.yml` now fires on
  pushes to main (fork-sourced ceremony PRs get a read-only token on
  `pull_request` events), reading the transition from the push itself:
  `event.before` to the pushed head. A decide step answers four states —
  release-flow *work* merged under the `release` label (`-dev` endstates,
  the post-release window) no-ops green with a NOTICE; the two genuinely
  ambiguous bare states refuse loudly; a true transition then requires a
  merged, `release`-labeled PR behind the commit (read via the API — the
  label is the operator's declared intent). Then, in the same job, it
  API-creates the tag at the merge commit, publishes with the extracted
  notes — and bumps main to `X.Y.(Z+1)-dev` itself, direct push with a
  loud open-a-PR fallback, so no follow-up bump PR exists on the paved
  road. A `GITHUB_TOKEN`-created tag never fires the tag-push trigger, so
  the paths cannot double-publish — and that tag-push path survives intact
  as the documented manual fallback and backfill.

- **Tagged releases, and an installer that installs them** (#32) — the rig
  half of the flow designed in heavy-duty/box#83, near-verbatim. A release
  is a PR, then a tag: the `release: X.Y.Z` PR bumps `VERSION` and stamps
  this file's Unreleased section with version + date; the merge commit is
  tagged bare `X.Y.Z` (box's tag scheme — no `v` prefix). `release.yml`
  turns the tag into the GitHub release — after asserting tag == `VERSION`
  (mismatch fails loudly and creates nothing) — with that version's section
  of this file as the body, extracted by the same `changelog_section` the
  test harness drives. No assets: for a pure-bash tree, GitHub's source
  tarball for the tag IS the package. `install.sh` now defaults to the
  **latest release**: the tag is resolved by following the
  `releases/latest` redirect and reading the `Location` header — no API, no
  token — and the download is `archive/refs/tags/<tag>.tar.gz`. `RIG_REF`
  picks the other two channels: a tag pins (`refs/tags` outranks a
  same-named branch), a branch (`RIG_REF=main`) tracks the development
  tree. Until 0.1.0 is cut the default channel has nothing to resolve and
  dies saying exactly that, naming `RIG_REF=main` as the way to install
  today — it never falls back to main silently, because "I installed the
  latest release" must not quietly mean "I installed whatever main was that
  second". Step 5 of #32 — pinning `BOX_REF` in the host-installs-box path
  — stays open until box cuts its next tagged release.
