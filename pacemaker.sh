#!/usr/bin/env bash
# claude-pacemaker — opens each 5-hour subscription window at a fixed local time
# by sending one cheap Haiku ping. See README.md.
set -euo pipefail

# ---- config (all overridable from .env) ----
TZ="${TZ:-UTC}"; export TZ
ANCHOR="${ANCHOR:-06:20}"
WINDOWS="${WINDOWS:-4}"
WINDOW_HOURS="${WINDOW_HOURS:-5}"

MODEL="${MODEL:-claude-haiku-4-5-20251001}"
PING_PROMPT="${PING_PROMPT:-hi}"
MAX_TOKENS="${MAX_TOKENS:-1}"

FRESH_TOLERANCE_MIN="${FRESH_TOLERANCE_MIN:-10}"
RETRY_INTERVAL_SEC="${RETRY_INTERVAL_SEC:-120}"
RESET_BUFFER_SEC="${RESET_BUFFER_SEC:-45}"
MAX_RETRIES="${MAX_RETRIES:-30}"

CREDENTIALS="${CREDENTIALS:-/root/.claude/.credentials.json}"
API_BASE="${API_BASE:-https://api.anthropic.com}"
OAUTH_BASE="${OAUTH_BASE:-https://console.anthropic.com}"
OAUTH_CLIENT_ID="${OAUTH_CLIENT_ID:-9d1c250a-e61b-44d9-88ed-5944d1962f5e}"
RESET_HEADER="${RESET_HEADER:-anthropic-ratelimit-unified-reset}"
DEBUG="${DEBUG:-0}"

# Required verbatim by OAuth tokens. Set in two steps — an apostrophe inside
# ${x:-default} breaks the parser.
if [[ -z "${SYSTEM_PROMPT:-}" ]]; then
  SYSTEM_PROMPT="You are Claude Code, Anthropic's official CLI for Claude."
fi

WINDOW_SEC=$(( WINDOW_HOURS * 3600 ))
FRESH_THRESHOLD=$(( WINDOW_SEC - FRESH_TOLERANCE_MIN * 60 ))

PING_BODY=$(jq -nc \
  --arg m "$MODEL" --argjson mt "$MAX_TOKENS" --arg sys "$SYSTEM_PROMPT" --arg p "$PING_PROMPT" \
  '{model:$m,max_tokens:$mt,system:$sys,messages:[{role:"user",content:$p}]}')

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
fmt() { date -d "@$1" '+%F %T %Z'; }

# Reset header value -> epoch seconds. Accepts a bare epoch or a timestamp.
reset_to_epoch() {
  local v="${1:-}"
  [[ -n "$v" ]] || { echo ""; return; }
  if [[ "$v" =~ ^[0-9]+$ ]]; then echo "$v"; else date -u -d "$v" +%s 2>/dev/null || echo ""; fi
}

# ---------------------------------------------------------------------------
# ---- OAuth token (read, and refresh when expired, from the CLI's creds file) ----
read_token()      { jq -r '.claudeAiOauth.accessToken  // empty' "$CREDENTIALS"; }
read_refresh()    { jq -r '.claudeAiOauth.refreshToken // empty' "$CREDENTIALS"; }
read_expiry_ms()  { jq -r '.claudeAiOauth.expiresAt    // 0'     "$CREDENTIALS"; }

refresh_token() {
  local rt body resp at newrt exp_in new_exp tmp snippet
  rt=$(read_refresh)
  [[ -n "$rt" ]] || { log "refresh: no refresh token in $CREDENTIALS"; return 1; }
  body=$(jq -nc --arg rt "$rt" --arg cid "$OAUTH_CLIENT_ID" \
    '{grant_type:"refresh_token",refresh_token:$rt,client_id:$cid}')
  resp=$(curl -sS -X POST "$OAUTH_BASE/v1/oauth/token" \
    -H 'content-type: application/json' --data "$body" 2>/dev/null) \
    || { log "refresh: request failed"; return 1; }
  at=$(echo "$resp" | jq -r '.access_token // empty')
  if [[ -z "$at" ]]; then
    snippet=$(printf '%s' "$resp" | head -c 160)
    log "refresh: failed ($snippet)"; return 1
  fi
  newrt=$(echo "$resp" | jq -r '.refresh_token // empty')
  exp_in=$(echo "$resp" | jq -r '.expires_in // 0')
  new_exp=$(( ( $(date +%s) + exp_in ) * 1000 ))
  tmp=$(mktemp)
  jq --arg at "$at" --arg rt "${newrt:-$rt}" --argjson exp "$new_exp" \
    '.claudeAiOauth.accessToken=$at | .claudeAiOauth.refreshToken=$rt | .claudeAiOauth.expiresAt=$exp' \
    "$CREDENTIALS" > "$tmp" && mv "$tmp" "$CREDENTIALS"
  log "refresh: token renewed, expires $(fmt $((new_exp/1000)))"
}

ensure_token() {
  [[ -f "$CREDENTIALS" ]] || { log "credentials not found: $CREDENTIALS"; return 1; }
  local exp now_ms
  exp=$(read_expiry_ms); now_ms=$(( $(date +%s) * 1000 ))
  if (( exp > 0 && now_ms < exp - 60000 )); then return 0; fi
  log "access token expired/expiring; refreshing"
  refresh_token
}

# ---- the ping ----
# One subscription request that nudges the window and reports its reset.
# Echoes "<http_code>|<reset_epoch>".
do_ping() {
  local token hdr code reset_raw
  token=$(read_token)
  [[ -n "$token" ]] || { echo "000|"; return; }
  hdr=$(mktemp)
  code=$(curl -sS -o /dev/null -D "$hdr" -w '%{http_code}' \
    -X POST "$API_BASE/v1/messages" \
    -H "authorization: Bearer $token" \
    -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "content-type: application/json" \
    --data "$PING_BODY" 2>/dev/null || echo 000)
  if [[ "$DEBUG" == "1" ]]; then { echo "---- rate-limit headers (http $code) ----"; grep -i ratelimit "$hdr" || true; } >&2; fi
  reset_raw=$(grep -i "^${RESET_HEADER}:" "$hdr" | head -n1 | sed 's/^[^:]*: *//; s/\r$//') || true
  rm -f "$hdr"
  printf '%s|%s' "$code" "$(reset_to_epoch "$reset_raw")"
}

# Sends one ping (refreshing auth once on 401/403). Echoes reset epoch; 0 on success.
ping_and_reset() {
  ensure_token >&2 || return 1
  local res code reset
  res=$(do_ping); code=${res%%|*}; reset=${res##*|}
  if [[ "$code" == "401" || "$code" == "403" ]]; then
    log "ping: auth $code, refreshing and retrying once" >&2
    refresh_token >&2 || return 1
    res=$(do_ping); code=${res%%|*}; reset=${res##*|}
  fi
  [[ "$code" =~ ^2 ]] || { log "ping: HTTP $code" >&2; return 1; }
  printf '%s' "$reset"
}

# ---- anchor: ping, then confirm a fresh window before counting it done ----
anchor() {
  local label="$1" attempt=0 reset now remaining wake out
  while (( attempt < MAX_RETRIES )); do
    attempt=$(( attempt + 1 ))
    log "[$label] attempt $attempt: ping ($MODEL)"
    if ! out=$(ping_and_reset); then
      log "[$label] ping failed; retry in ${RETRY_INTERVAL_SEC}s"
      sleep "$RETRY_INTERVAL_SEC"; continue
    fi
    reset=$out; now=$(date +%s)
    if [[ -z "$reset" ]]; then
      log "[$label] no '$RESET_HEADER' header — cannot confirm reset (set DEBUG=1 to inspect headers); retry in ${RETRY_INTERVAL_SEC}s"
      sleep "$RETRY_INTERVAL_SEC"; continue
    fi
    remaining=$(( reset - now ))
    if (( remaining >= FRESH_THRESHOLD )); then
      log "[$label] CONFIRMED fresh window — resets $(fmt "$reset") (in $((remaining/60))m). Anchor done."
      return 0
    fi
    if (( remaining > 0 )); then
      wake=$(( reset + RESET_BUFFER_SEC ))
      log "[$label] fired mid-window (reset in $((remaining/60))m, not fresh); previous window still active — waiting until $(fmt "$wake")"
      sleep $(( wake - now ))
    else
      log "[$label] window edge; retry in ${RETRY_INTERVAL_SEC}s"
      sleep "$RETRY_INTERVAL_SEC"
    fi
  done
  log "[$label] gave up after $MAX_RETRIES attempts without confirming a fresh window"
  return 1
}

# ---- schedule: ANCHOR + k*WINDOW_HOURS, recomputed daily so it can't drift ----
next_target() {
  local now today base t k best="" day
  now=$(date +%s); today=$(date +%F)
  for day in "$today" "$(date -d "$today +1 day" +%F)"; do
    base=$(date -d "$day ${ANCHOR}:00" +%s)
    for (( k=0; k<WINDOWS; k++ )); do
      t=$(( base + k * WINDOW_SEC ))
      if (( t > now )) && { [[ -z "$best" ]] || (( t < best )); }; then best=$t; fi
    done
  done
  echo "$best"
}

print_schedule() {
  local base t k day
  log "today's anchors:"
  for day in "$(date +%F)"; do
    base=$(date -d "$day ${ANCHOR}:00" +%s)
    for (( k=0; k<WINDOWS; k++ )); do
      t=$(( base + k * WINDOW_SEC ))
      log "  - $(date -d "@$t" '+%H:%M') (covers until $(date -d "@$((t+WINDOW_SEC))" '+%H:%M'))"
    done
  done
}

main() {
  log "claude-pacemaker up | tz=$TZ anchor=$ANCHOR windows=$WINDOWS window=${WINDOW_HOURS}h model=$MODEL"
  print_schedule
  local target label secs
  while true; do
    target=$(next_target); label=$(date -d "@$target" '+%H:%M'); secs=$(( target - $(date +%s) ))
    log "next anchor $(fmt "$target") (in $((secs/60))m); sleeping"
    (( secs > 0 )) && sleep "$secs"
    anchor "$label" || true
  done
}

main "$@"
