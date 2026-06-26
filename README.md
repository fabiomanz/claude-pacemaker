# claude-pacemaker

Claude subscriptions meter usage in rolling 5-hour windows. A window starts on
your first request and runs for 5 hours; whatever you don't use in it is gone.
If you only start coding at 10am, the 5–10am window is wasted, and your day ends
up unevenly carved into windows that don't line up with when you actually work.

claude-pacemaker starts each window for you at a fixed time. It sends one tiny
Haiku request at 06:20, 11:20, 16:20 and 21:20, so the windows always begin at
the same clock times and you walk into each one already open. It runs as a small
Docker container that sleeps between those times.

## How it works

The schedule is `ANCHOR + N×WINDOW_HOURS`, recomputed from the anchor every day
so it can't drift:

```
ANCHOR=06:20  WINDOWS=4  WINDOW_HOURS=5
  06:20  ->  covers to 11:20
  11:20  ->  covers to 16:20
  16:20  ->  covers to 21:20
  21:20  ->  covers to 02:20
  02:20–06:20: overnight gap, left alone
```

A new window only starts if you send a request *after* the previous one has
ended. A request sent mid-window just joins the current window — it doesn't
start a fresh one. So if the ping fires even a minute early (clock skew, or a
window you opened yourself earlier), it would land in the old window and the
anchor would be wasted.

To avoid that, the ping reads back the window's reset time:

- If the reset is ~5 hours out, a fresh window just started — done.
- If it's sooner, the old window is still running. It waits until that window
  ends, then pings again. Usually that's one extra ping.

Every ping and confirmed reset is logged to stdout. Pings are cheap and count
against the same 5-hour window they open, never the weekly cap.

## Why a ping moves the window

It has to use your subscription, not pay-as-you-go API credits — only
subscription usage advances the 5-hour window. So it sends the request the way
the `claude` CLI does: your OAuth token from `~/.claude/.credentials.json` (which
it also refreshes), the `oauth-2025-04-20` header, and the Claude Code system
prompt. It uses `curl` rather than bundling the Node CLI — that keeps the image
small and lets it read the rate-limit reset header it needs. To use the real
`claude` binary instead, replace the `do_ping` function in `pacemaker.sh`.

## Setup

Log in with the CLI once so the credentials file exists:

```bash
claude   # creates ~/.claude/.credentials.json
```

(On macOS the token may live in the Keychain instead; export it to
`~/.claude/.credentials.json` as `{"claudeAiOauth":{"accessToken","refreshToken","expiresAt"}}`.)

Then configure and run:

```bash
cp .env.example .env   # set TZ, ANCHOR, WINDOWS
docker compose up -d --build
docker compose logs -f
```

## Headless / WAF limitation

On headless servers — especially VPS / datacenter IPs — Cloudflare's bot wall in
front of the OAuth token endpoint (`platform.claude.com/v1/oauth/token`) often
rejects the token *refresh* as automated traffic, returning a `403`/`429` that
shows up as `rate_limit_error`. The ping itself (`api.anthropic.com`) is not
behind that wall, so pings work but refresh fails. This is a platform-side block
(see anthropics/claude-code#47754), not your plan usage.

pacemaker sends the refresh with the real CLI's `User-Agent` to reduce the
chance of being flagged, but that may not be enough to pass the wall. When a
refresh is blocked it logs the cause and stops retrying for that anchor instead
of hammering the endpoint.

If your host is blocked, refresh the token **off-host** and let pacemaker only
read and ping. The OAuth token is account-scoped, so a token minted anywhere
moves the same 5-hour window. Practical options:

- Run pacemaker on a non-blocked machine (e.g. a box on a residential IP), or
- Refresh `~/.claude/.credentials.json` on a machine where login works and sync
  it to the server (e.g. a periodic `scp`/`rsync` from your laptop), so the
  mounted credentials file always holds a valid token.

## Configuration

| Var | Default | Meaning |
|-----|---------|---------|
| `TZ` | `UTC` | Clock the anchors are pinned to |
| `ANCHOR` | `06:20` | First window of the day (HH:MM) |
| `WINDOWS` | `4` | Windows per day |
| `WINDOW_HOURS` | `5` | Window length |
| `MODEL` | `claude-haiku-4-5-20251001` | Model used for the ping |
| `PING_PROMPT` | `hi` | The prompt |
| `MAX_TOKENS` | `1` | Cap the reply |
| `FRESH_TOLERANCE_MIN` | `10` | Slack when judging a window "fresh" |
| `RETRY_INTERVAL_SEC` | `120` | Base wait between retries on error / at a window edge |
| `RESET_BUFFER_SEC` | `45` | Extra wait past a still-active window's reset |
| `MAX_RETRIES` | `10` | Attempt cap per anchor |
| `MAX_BACKOFF_SEC` | `1800` | Cap on the exponential backoff for failed pings |
| `CLAUDE_DIR` | `$HOME/.claude` | Host dir mounted to `/root/.claude` |
| `USER_AGENT` | `claude-cli/2.1.179 (external, cli)` | Sent on refresh/ping to mimic the real CLI |
| `RESET_HEADER` | `anthropic-ratelimit-unified-reset` | Reset header to read |
| `DEBUG` | `0` | `1` dumps the rate-limit headers |

The reset header name can change. If pings never confirm, set `DEBUG=1`, read the
dumped `*ratelimit*` headers, and point `RESET_HEADER` at the one carrying the
5-hour reset. Its value can be an epoch or a timestamp; both are handled. The
OAuth endpoints and `client_id` match how the CLI authenticates today — if those
change, override them in `.env`.
