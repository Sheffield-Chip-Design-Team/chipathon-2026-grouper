---
name: hlab-sge
description: Run and manage EDA jobs on the homelab-sge job scheduler using its CLI (hqsub, hqstat, hqhost, hqlog, hqwait, hqdel, hqlogin). Use when GrouperSoC work needs to submit a batch EDA/simulation/PnR job to the scheduler, check queue or node status, follow job logs, wait on a job in a pipeline, cancel a job, or open an interactive/VNC session. This is the everyday job-operations skill; for GrouperSoC-specific SGE usage (NFS layout, PDK selection inside the container, LibreLane run dirs), use the sge-job skill instead.
---

<!--
Adapted for GrouperSoC from the Trouper copy of this skill, which is itself a synced
copy of git.home/TimothyNewman/homelab-sge .claude/skills/hlab-sge/SKILL.md.
Last merged from Trouper commit 9b04422 (2026-08-23).
The hq* CLI mechanics below are scheduler-generic (the same homelab-sge daemon at
nas.home serves both repos); only repo-specific paths/project details live in sge-job.
The frontmatter `description` is intentionally GrouperSoC-flavoured — merge body/content
changes on future syncs, don't overwrite it wholesale.
-->

# homelab-sge — running jobs

homelab-sge is an SGE-style job scheduler that runs EDA workloads in isolated Docker
containers with CPU/RAM/GPU accounting. You interact with it through a handful of `hq*`
CLI tools. Treat `<cmd> --help` as the source of truth for the full flag list; this skill
covers the commands and the flags you'll actually reach for.

## Prerequisites

- The `hq*` CLIs must be installed and on `PATH`, and a daemon must be reachable. Point the
  client at the daemon with `export HLAB_SGE_URL=http://nas.home:4783`.
- Auth is by API token. Provide it via the `HLAB_SGE_TOKEN` env var, or write it to
  `~/.config/hlab-sge/token` (chmod 600). Without a valid token every call returns 401.
- If you don't have a token, ask the scheduler's admin for one — it's not self-serve.

## Submit a batch job — `hqsub`

```bash
hqsub --name <name> --cpus <n> --mem <8G> [options] <script.sh>
```

The positional argument is a shell script; it runs as `bash <script>` inside the container.
The script must already live at a path the daemon can read (for GrouperSoC that means under
the NFS designs tree — see the `sge-job` skill). Common flags:

- `--name <name>` — human label shown in the queue.
- `--cpus <n>` — CPU cores to reserve. GrouperSoC LibreLane full flow scales to ~20 cores.
- `--cpus-hard` / `--cpus-soft` — `--cpus-hard` (the default) enforces a real Docker CPU
  quota/cpuset; `--cpus-soft` only reserves the cores in the scheduler's accounting and
  lets the job use whatever the node has.
- `--mem <8G|512M>` — memory; accepts `G`/`M` shorthand.
- `--gpu 0|1` — whether the job needs the GPU. Single on/off slot, **not** VRAM or
  fractional — request `1` if the job touches the GPU at all (Grouper PnR/sim don't).
- `--priority <1-10>` — higher runs sooner among pending jobs.
- `--node <name>` — pin the job to a specific worker node (otherwise scheduler picks one).
  Names come from `hqhost --json` (`.nodes[].name`), e.g. `gaming-pc`, `proxmox-agent`,
  `nas-server` — the truncated `hqhost` table is not a reliable source for them.
- `--after <id,id>` — hold this job until the listed job IDs finish (dependencies).
- `--retry-on-exit <codes>` — auto-retry the job if it exits with one of these codes.
- `--storage default|nfs|scratch` (or the `--nfs` / `--scratch` shortcuts) — where the job's
  designs are staged. Use `scratch` for metadata-heavy flows (lots of small file opens)
  where shared-storage latency hurts.
- `--project <name>` — scope the input snapshot to `designs_dir/<user>/<project>` instead of
  the user's whole designs root. **Use this whenever the designs root is more than a few
  hundred MB** — an unscoped submit against a multi-GB or multi-project root can take well
  over a minute to stage (see the timeout note below) or hit the snapshot's size/file bounds
  outright (`413`). It also **changes the container mount point** — see the `sge-job` skill,
  because getting it wrong burns a whole job on a `cd: No such file or directory`.
- `--run-dir <path>` — relative output directory below the user's runs dir.
- `--snapshot-exclude <glob>` — repeatable; skip extra paths from the snapshot on top of
  whatever the daemon already excludes (it can only *add* exclusions, never remove one the
  daemon config sets). No `/` matches a basename at any depth (e.g. `*.vcd`); a `/` in the
  pattern matches a source-relative path (e.g. `librelane/classic/runs/**`). Reach for this
  when a project has large generated content sitting next to its inputs.

> **There is no per-job `--image` flag.** Jobs run against whatever container image the
> scheduler is preconfigured with. Don't try to override it on the `hqsub` line.

> **`Warning: --cpus N exceeds schedulable CPUs M` is advisory, not a rejection.** `M` is the
> master node's own capacity, not the pinned node's. A `--node gaming-pc --cpus 20` submit
> prints that warning against the 6-core master and still queues fine — check
> `hqstat --json` for `"runnable": true` rather than trusting the warning.

**Never submit concurrently from two worktrees (or any two working directories) against the
same `--project` name.** The snapshot destination is keyed by `<user>/<project>`, not by the
directory you ran `hqsub` from — two overlapping submits under the same project both
hash/copy into that one NFS location with no locking of their own, so one submit's in-flight
copy can be partially overwritten by the other's, and the job that gets staged may run
against a corrupted mix of both trees. Serialize with `hqwait` between them:

```bash
id=$(hqsub --project grouper-sim --name from-worktree-a build.sh | awk '{print $NF}')
hqwait "$id"   # must return before a second worktree submits under the same --project
```

Before submitting under a shared `--project`, check whether another submit against it is
already in flight — `hqstat --all --json`, filtered for `STAGING`/`PENDING` jobs whose name
or script path names the same project. There is no per-project lock to query directly, so
this is best-effort: a job already past `STAGING` into `RUNNING` is no longer a staging risk,
but one still `STAGING` (or one submitted moments ago that hasn't appeared in `hqstat` yet)
means hold off and `hqwait` on it first.

`hqsub` prints the assigned job ID as the last field of `Submitted job <id>`. For interactive
or GUI work, use `hqlogin` instead — `hqsub` is batch-only.

### Submit can still take a while to return

`hqsub` blocks until snapshot staging (hashing + copying) finishes, which can take a good
while for a real project even with `--project` scoping — 100–150 s isn't unusual for a
multi-GB design tree. The client timeout was raised to 180 s specifically for this, so a
plain hang usually means it's still staging, not stuck. If you do see a timeout error
(`Error: Request to http://<host>:4783/api/jobs timed out after ...s`), treat it as a
client-side timeout, not a submission failure — the job was very likely already accepted
and is staging server-side. Check `hqstat` (add `--all` if you need to find it by name)
before resubmitting; resubmitting on sight of this error can queue a duplicate job.

## Check status — `hqstat` / `hqhost`

- `hqstat` — table of active and recent jobs (ID, name, state, resources), **your own jobs
  only** by default. Add `--all` to see every user's jobs (e.g. after the timeout case above,
  when you need to find the job you just submitted). `hqstat --wide` adds peak RAM / CPU%
  columns; `hqstat --json [--all]` for machine-readable output when scripting a poll loop.
- `hqhost` — per-node resource summary (free vs. used CPU/RAM/GPU) and node **state**. Use
  this to see whether there's room before submitting, or `hqhost --json` for machine-readable
  output. **The table truncates node names and states to a few characters** (`gamin… unrea…`),
  so read `hqhost --json` whenever the exact name or state matters.

The `hqstat --json` fields worth knowing: `state`, `runnable`, `wait_reason`, `pinned_node`,
`assigned_node`, `exit_code`, `run_dir`, `source_dir`, `peak_ram_mb`, `peak_cpu_pct`.

Job states: `STAGING → PENDING → RUNNING → DONE | FAILED | CANCELLED`. A cancel of a
running job goes through an intermediate `RUNNING → CANCELLING → CANCELLED` — the job keeps
its resource reservation until the container is confirmed dead, so don't assume `hqhost`
shows the freed capacity the instant you run `hqdel`.

> **A scheduler restart can orphan a running job**: the worker process is silently killed,
> no further log output appears, but `hqstat` may still show it as `RUNNING`. If a job's
> log has gone quiet for a long time, confirm the process is actually alive (peak CPU/RAM
> still moving in `hqstat --wide`, or `docker stats`/`docker top` on the node) before
> concluding the *workload* hung — this exact confusion cost a debug cycle on a Grouper
> PnR run (see the pnr-run skill).

## Follow logs — `hqlog`

```bash
hqlog <id> [--stream out|err] [--follow]
```

- `--stream err` — show stderr (default is stdout).
- `--follow` / `-f` — stream live as the job runs.

The same content is on NFS at `/srv/eda/logs/<user>/job-<id>.{o,e}`, with the exact script
that ran alongside it as `job-<id>.sh` — useful for reconstructing how an old job was set up.

## Wait for a job — `hqwait`

```bash
hqwait <id>
```

Blocks until the job reaches a terminal state and **exits with the job's own exit code** —
so it composes in pipelines:

```bash
id=$(hqsub --name build --cpus 4 --mem 8G build.sh | awk '{print $NF}')
hqwait "$id" && ./next-step.sh
```

For a long PnR run, prefer polling `hqstat --json` on a wide interval (see the run-pnr
skill) over a foreground `hqwait`, so notifications don't fire constantly for an hour.

## Cancel — `hqdel`

```bash
hqdel <id> [id...] [--force]
```

Cancels queued or running jobs. Jobs already `DONE`/`FAILED`/`CANCELLED` can't be cancelled.
Without `--force`, `hqdel` prompts `Cancel job <id> (<name>, <state>)? [y/N]` and waits for
input — in a non-interactive context (script, no TTY) either pass `--force` or pipe an
answer, e.g. `echo y | hqdel <id>`.

## Interactive / GUI sessions — `hqlogin`

For an interactive shell, X11-forwarded tools, or a browser-based VNC desktop, use
`hqlogin` (not `hqsub`). It allocates the session and handles X11/VNC setup for you; see
`hqlogin --help` for the session flags. Not every node allows VNC — `hqhost --json` reports
`allow_vnc` per node (the master does; `gaming-pc` does not).

## If a job won't start

Work through it in order:

1. `hqstat --json` — is it `PENDING` because of a `--after` dependency that hasn't finished
   yet? Is `runnable` false, and does `wait_reason` say why?
2. `hqhost --json` — **is the target node's `state` still `online`?** A `--node`-pinned job
   whose node goes `unreachable` sits in `PENDING` **forever** with `runnable: true`, no
   `wait_reason`, and no error: nothing distinguishes it from a job merely waiting its turn.
   Nodes do drop out mid-session, so re-check `hqhost` rather than assuming the state you
   saw at submit time still holds. Either wait for the node to come back, or `hqdel` and
   resubmit pinned elsewhere / unpinned.
3. `hqhost --json` — is there actually free CPU/RAM/GPU on the target node? A `--node`-pinned
   job waits until *that* node has room; an unpinned job waits until *some* node does.
4. `hqlog <id> --stream err` — read the container's error output for a real failure.
5. A `FAILED` state with a nonzero exit code usually means the job **script** failed — that's
   the script's bug, not the scheduler. Check the log before assuming an infrastructure issue.
