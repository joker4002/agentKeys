#!/usr/bin/env bash
# Reset Chrome for a clean workflow-recorder run: kill any Chrome on port
# 9222, wipe the throwaway profile, relaunch Chrome fresh, wait for CDP.
#
# Usage: ./scripts/reset-chrome-for-recording.sh
#
# Idempotent — safe to re-run.

set -eu

PORT=9222
PROFILE_DIR=/tmp/agentkeys-chrome-profile
CHROME=/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome

# Kill whatever's listening on $PORT (only the recorder Chrome; user's
# normal Chrome binds to a different port, so safe).
if lsof -ti :"$PORT" >/dev/null 2>&1; then
  echo "[reset] killing PIDs on port $PORT: $(lsof -ti :$PORT | tr '\n' ' ')"
  lsof -ti :"$PORT" | xargs kill -9 2>/dev/null || true
  # Wait for port to actually free
  for _ in $(seq 1 20); do
    lsof -ti :"$PORT" >/dev/null 2>&1 || break
    sleep 0.2
  done
fi

# Wipe profile
if [ -d "$PROFILE_DIR" ]; then
  echo "[reset] wiping profile dir $PROFILE_DIR"
  rm -rf "$PROFILE_DIR"
fi
mkdir -p "$PROFILE_DIR"

# Relaunch Chrome in background
echo "[reset] launching fresh Chrome with port=$PORT profile=$PROFILE_DIR"
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --remote-debugging-port="$PORT" \
  --user-data-dir="$PROFILE_DIR" \
  --no-first-run \
  --no-default-browser-check \
  --disable-background-networking \
  >/tmp/chrome-recorder.log 2>&1 &
CHROME_PID=$!
echo "[reset] chrome PID=$CHROME_PID"

# Wait for CDP endpoint
echo "[reset] waiting for CDP on port $PORT..."
for i in $(seq 1 60); do
  if curl -sS "http://localhost:$PORT/json/version" >/dev/null 2>&1; then
    echo "[reset] CDP ready (waited ${i}x 0.5s)"
    exit 0
  fi
  sleep 0.5
done

echo "[reset] ERROR: CDP never became available on port $PORT after 30s" >&2
exit 1
