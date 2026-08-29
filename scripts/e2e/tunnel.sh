#!/usr/bin/env bash
#
# End-to-end test harness: puts this checkout on the public internet under a
# real certificate, so clients that refuse to talk to a development server can
# be tested against it (issue #1705).
#
# The one that forced this into existence is Apple's: iOS and macOS Contacts
# will not send HTTP Basic credentials over an unencrypted connection. They ask,
# they are told how to authenticate, and they stay silent — "CardDAV account
# verification failed", with the server log showing nothing but 401s. No
# certificate, no test. The same will be true of anything else that insists on
# TLS: OAuth redirects, webhooks somebody has to reach, a phone client.
#
#     ./scripts/e2e/tunnel.sh
#
#     device ──https──▶ Cloudflare Quick Tunnel ──▶ recording proxy ──▶ Phoenix
#
# **Cloudflare Quick Tunnels, deliberately.** They need no account, no token and
# no secret in the repository or in an instruction — one binary and one command,
# which is the only kind of tooling an open-source project can actually ask a
# contributor to run. The cost is a fresh random hostname per run, and no
# request inspector; the second is why the proxy beside this script exists.
#
# **Nothing touches the hostname before DNS is ready.** A fresh
# `*.trycloudflare.com` name takes a moment to resolve, and one lookup too early
# poisons the local resolver with a negative answer that outlives the tunnel.
# So this waits on a public resolver, and only then hands the URL over.
#
# Ctrl-C stops everything it started, and nothing else.

set -euo pipefail

APP_PORT="${APP_PORT:-4037}"
PROXY_PORT="${PROXY_PORT:-4038}"
PROXY_LOG="${PROXY_LOG:-/tmp/vutuv-e2e-proxy.log}"
TUNNEL_LOG="${TUNNEL_LOG:-/tmp/vutuv-e2e-tunnel.log}"
SERVER_LOG="${SERVER_LOG:-/tmp/vutuv-e2e-server.log}"
DNS_RESOLVER="${DNS_RESOLVER:-1.1.1.1}"
DNS_TIMEOUT="${DNS_TIMEOUT:-120}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

pids=()
cleanup() {
  echo
  echo "→ stopping what this script started"
  for pid in "${pids[@]:-}"; do
    [ -n "${pid:-}" ] && kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

command -v cloudflared >/dev/null || {
  echo "cloudflared is missing. brew install cloudflared" >&2
  exit 1
}

echo "→ recording proxy :$PROXY_PORT → :$APP_PORT (log: $PROXY_LOG)"
PROXY_PORT="$PROXY_PORT" APP_PORT="$APP_PORT" PROXY_LOG="$PROXY_LOG" \
  node scripts/e2e/inspect_proxy.mjs &
pids+=("$!")

echo "→ opening a Quick Tunnel"
: > "$TUNNEL_LOG"
cloudflared tunnel --url "http://127.0.0.1:$PROXY_PORT" --no-autoupdate \
  >>"$TUNNEL_LOG" 2>&1 &
pids+=("$!")

echo -n "→ waiting for the hostname"
host=""
for _ in $(seq 1 60); do
  host="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" | head -1 || true)"
  [ -n "$host" ] && break
  echo -n "."
  sleep 1
done
echo
[ -n "$host" ] || { echo "no tunnel hostname in $TUNNEL_LOG" >&2; exit 1; }
name="${host#https://}"
echo "   $host"

# The important wait. Ask a public resolver, never the local one: a miss here
# is what would be cached as NXDOMAIN and outlive the tunnel.
echo -n "→ waiting for DNS (via $DNS_RESOLVER, up to ${DNS_TIMEOUT}s)"
resolved=""
for _ in $(seq 1 "$DNS_TIMEOUT"); do
  resolved="$(dig +short "@$DNS_RESOLVER" "$name" A 2>/dev/null | head -1 || true)"
  [ -n "$resolved" ] && break
  echo -n "."
  sleep 1
done
echo
[ -n "$resolved" ] || { echo "$name did not resolve; not touching it" >&2; exit 1; }
echo "   $name → $resolved"

# `mix` is not on PATH under every version manager; mise is what this checkout
# is set up with, so fall back to it rather than failing on a missing binary.
mix_cmd=(mix)
command -v mix >/dev/null || mix_cmd=(mise exec -- mix)

echo "→ starting Phoenix on :$APP_PORT as $name (log: $SERVER_LOG)"
PORT="$APP_PORT" MIX_ENV=dev PHX_HOST="$name" PHX_SCHEME="https" PHX_PORT="443" \
  "${mix_cmd[@]}" phx.server >"$SERVER_LOG" 2>&1 &
pids+=("$!")

for _ in $(seq 1 60); do
  curl -sf -o /dev/null "http://127.0.0.1:$APP_PORT/" && break
  sleep 2
done

cat <<INFO

────────────────────────────────────────────────────────────
  $host
────────────────────────────────────────────────────────────
  requests   tail -f $PROXY_LOG
  server     tail -f $SERVER_LOG
  Ctrl-C stops the tunnel, the proxy and the server.
INFO

wait
