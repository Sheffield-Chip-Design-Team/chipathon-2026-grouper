---
name: hlab-sge
description: Run and manage EDA jobs on the homelab-sge job scheduler using its CLI (hqsub, hqstat, hqhost, hqlog, hqwait, hqdel, hqlogin). Use when GrouperSoC work needs to submit a batch EDA/simulation/PnR job to the scheduler, check queue or node status, follow job logs, wait on a job in a pipeline, cancel a job, or open an interactive/VNC session. This is the everyday job-operations skill; for GrouperSoC-specific SGE usage (NFS layout, PDK selection inside the container, LibreLane run dirs), use the sge-job skill instead.
---

<!--
Adapted for GrouperSoC from the Trouper copy of this skill. The hq* CLI mechanics
below are scheduler-generic (the same homelab-sge daemon at nas.home serves both
repos); only the repo-specific paths/project details live in the sge-job skill.
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
- `--mem <8G|512M>` — memory; accepts `G`/`M` shorthand.
- `--gpu 0|1` — whether the job needs the GPU. Single on/off slot, **not** VRAM or
  fractional — request `1` if the job touches the GPU at all (Grouper PnR/sim don't).
- `--priority <1-10>` — higher runs sooner among pending jobs.
- `--node <name>` — pin the job to a specific worker node (otherwise scheduler picks one).
- `--after <id,id>` — hold this job until the listed job IDs finish (dependencies).
- `--retry-on-exit <codes>` — auto-retry the job if it exits with one of these codes.
- `--snapshot-exclude <glob>` — repeatable; skip extra paths from the snapshot on top of
  whatever the daemon already excludes. No `/` matches a basename at any depth (e.g.
  `*.vcd`); a `/` in the pattern matches a source-relative path.

> **There is no per-job `--image` flag.** Jobs run against whatever container image the
> scheduler is preconfigured with. Don't try to override it on the `hqsub` line.

`hqsub` prints the assigned job ID. For interactive or GUI work, use `hqlogin` instead —
`hqsub` is batch-only.

### Submit can still take a while to return

`hqsub` blocks until snapshot staging (hashing + copying) finishes, which can take a good
while for a real project. If you ever see a timeout error
(`Error: Request to http://<host>:4783/api/jobs timed out after ...s`), treat it as a
client-side timeout, not a submission failure — the job was very likely already accepted
and is staging server-side. Check `hqstat` before resubmitting; resubmitting on sight of
this error can queue a duplicate job.

## Check status — `hqstat` / `hqhost`

- `hqstat` — table of active and recent jobs (ID, name, state, resources), **your own jobs
  only** by default. Add `--all` to see every user's jobs. `hqstat --wide` adds peak RAM /
  CPU% columns; `hqstat --json [--all]` for machine-readable output when scripting a poll
  loop.
- `hqhost` — per-node resource summary (free vs. used CPU/RAM/GPU). Use this to see whether
  there's room before submitting, or `hqhost --json` for machine-readable output.

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

## Wait for a job — `hqwait`

```bash
hqwait <id>
```

Blocks until the job reaches a terminal state and **exits with the job's own exit code** —
so it composes in pipelines:

```bash
id=$(hqsub --name build --cpus 4 --mem 8G build.sh | grep -oP '\d+')
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
`hqlogin --help` for the session flags.

## If a job won't start

Work through it in order:

1. `hqstat` — is it `PENDING` because of a `--after` dependency that hasn't finished yet?
2. `hqhost` — is there actually free CPU/RAM/GPU on the target node? A `--node`-pinned job
   waits until *that* node has room; an unpinned job waits until *some* node does.
3. `hqlog <id> --stream err` — read the container's error output for a real failure.
4. A `FAILED` state with a nonzero exit code usually means the job **script** failed — that's
   the script's bug, not the scheduler. Check the log before assuming an infrastructure issue.
