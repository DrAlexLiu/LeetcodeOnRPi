#!/bin/sh
STATE_DIR=/var/lib/kiosk-mode
COUNTER=$STATE_DIR/counter
OVERRIDE=$STATE_DIR/next-mode
mkdir -p "$STATE_DIR"

MODE=""
if [ -s "$OVERRIDE" ]; then
  CANDIDATE=$(cat "$OVERRIDE")
  rm -f "$OVERRIDE"
  case "$CANDIDATE" in
    leetcode|vscode) MODE=$CANDIDATE ;;
    *) echo "invalid next-mode '$CANDIDATE', ignoring it and falling back to the counter" ;;
  esac
fi

if [ -z "$MODE" ]; then
  COUNT=$(cat "$COUNTER" 2>/dev/null); case "$COUNT" in ''|*[!0-9]*) COUNT=0 ;; esac
  NEXT=$((COUNT + 1))
  printf '%s' "$NEXT" > "$COUNTER.tmp" && sync && mv -f "$COUNTER.tmp" "$COUNTER"
  if [ $((COUNT % 2)) -eq 0 ]; then MODE=leetcode; else MODE=vscode; fi
fi

echo "$MODE" > "$STATE_DIR/last-mode"
systemctl start --no-block "kiosk-${MODE}.service"
