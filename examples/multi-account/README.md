# Running claude-pacemaker for two accounts

Yes — pacemaker is single-account *per container*, but nothing in it is
global. The credentials file it reads (`CREDENTIALS`, default
`/root/.claude/.credentials.json`) and the schedule both come from env, so two
accounts = two containers, each with its own `.env` and its own mounted
credentials directory.

The 5-hour usage window is a property of the account, so the two pacemakers
never interact: each one opens its own account's window.

## If you only have one account

Don't use this directory — use the root `docker-compose.yml` and `.env.example`.
One account is the case pacemaker is built for and nothing here improves on it.

In particular, **keep the root compose file's default mount**
(`${CLAUDE_DIR:-${HOME}/.claude}:/root/.claude`) rather than copying the
isolated `creds/<account>` layout below. That isolation exists only because two
containers cannot share one credentials file. With a single account it works
against you: you would end up with two separate copies of the same account's
refresh token — pacemaker's and your interactive CLI's — rotating
independently, which is exactly the `invalid_grant` failure described in
[Two things to know about token rotation](#two-things-to-know-about-token-rotation).
Mounting the real `~/.claude` keeps one file and one rotation chain, so
pacemaker and `claude` on that host cooperate instead of retiring each other's
tokens.

Everything else on this page still applies to a single account: the anchor
scheduling, and especially the headless/WAF refresh check in step 3.

## What's here

| File | Purpose |
|---|---|
| `docker-compose.yml` | Two services, `pacemaker-private` and `pacemaker-work` |
| `.env.private` / `.env.work` | Per-account schedule |
| `creds/private/` `creds/work/` | One `.credentials.json` per account (mounted read-write) |

Run `docker compose` from this directory — `build: ../..` picks up the
Dockerfile at the repo root, and the mounts are relative to this file.

The root `docker-compose.yml` stays the single-account default; it hardcodes
`container_name: claude-pacemaker`, so two copies of it cannot run side by
side. That's the only thing that actually needed changing here.

## Setup

### 1. Mint one credentials file per account

On the server, log each account in with its own `CLAUDE_CONFIG_DIR` pointing
straight at its `creds/` folder (run from this directory). No logout dance, and `~/.claude` stays
untouched. On a headless box the CLI prints a URL to open in any browser.

```bash
CLAUDE_CONFIG_DIR=$PWD/creds/private claude   # log in as private, then /exit
CLAUDE_CONFIG_DIR=$PWD/creds/work    claude   # log in as work, then /exit
```

Renewing one account later is the same single command; the running container
picks up the new file at its next anchor, no restart needed.

Use these dedicated directories — do **not** point either service at your real
`~/.claude`. pacemaker rewrites `.credentials.json` in place on every refresh,
and two containers sharing one directory would overwrite each other's token.

### 2. Start both

```bash
docker compose up -d --build
docker compose logs -f                       # both
docker compose logs -f pacemaker-work        # one
```

Each container logs its own anchor schedule on startup.

### 3. Check the token refresh actually works from the server

This is the one thing likely to bite you, and it bites both accounts equally:
on a VPS/datacenter IP, Cloudflare in front of `platform.claude.com` often
rejects the OAuth *refresh* as bot traffic. Test each account explicitly:

```bash
docker compose exec pacemaker-private   pacemaker.sh refresh
docker compose exec pacemaker-work      pacemaker.sh refresh
```

Exit `0` = fine. `2` = the WAF is blocking this host; refresh off-host and
keep the credentials file in sync instead. `3` = that account's refresh token
is dead, log in again for it (step 1).

## Two things to know about token rotation

Refresh tokens **rotate**: each successful refresh issues a new one and retires
the old. Two consequences for a two-account setup:

- Per account, only one thing should be refreshing that token. If you also use
  the same account interactively from your laptop, whichever side refreshes
  last invalidates the other's token, and the loser eventually logs
  `invalid_grant`. If you hit that, treat the server copy as authoritative and
  sync *from* it, or accept re-authing the account occasionally.
- The two accounts are fully independent here, so a dead token on one does not
  affect the other. pacemaker pauses that one service's pings until its
  `.credentials.json` changes on disk, then resumes on its own — no restart.

## Schedule note

The anchors in `.env.work` are offset by 5 minutes purely so the two
containers don't hit the API in the same second; there's no quota reason for it.
Set each account's `ANCHOR` to whenever you actually start using that account —
if you only use the work account in the afternoon, `ANCHOR=13:00 WINDOWS=2`
is a better fit than mirroring the private schedule.
