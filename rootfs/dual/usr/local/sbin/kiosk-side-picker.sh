#!/bin/sh
# Flip which physical output each kiosk app is pinned to, once per boot.
#
# NOTE: we deliberately do NOT use Frame's `snap set ubuntu-frame
# display-layout=<name>` selector. It does not reach Frame on this build
# (457-mir2.26.0): `snap get` echoes the new name back, but Frame's own log
# keeps saying "Display config using layout: 'default'", so any layout not
# literally named `default` is silently ignored and every placement rule
# falls back to the default output. Instead we rewrite the whole `display`
# config each boot from one of two files, both naming their layout `default`.
#
# Commit order is transactional on purpose: nothing that describes "what is
# live" (counter, last-layout, consuming next-layout) is mutated until
# `snap set` has actually succeeded. An earlier version bumped the counter
# and wrote last-layout first, so a failed `snap set` left the state file
# claiming a layout that was never applied.
set -eu

STATE_DIR=/var/lib/kiosk-side
COUNTER=$STATE_DIR/counter
OVERRIDE=$STATE_DIR/next-layout
LAYOUT_DIR=/etc/kiosk/layouts
LOCK=$STATE_DIR/.lock
mkdir -p "$STATE_DIR"

# Serialize against a manual run racing the boot-time run.
exec 9>"$LOCK"
flock 9

# --- 1. decide the candidate (no state mutated yet) ---
LAYOUT=""
USED_OVERRIDE=no
if [ -s "$OVERRIDE" ]; then
  CANDIDATE=$(cat "$OVERRIDE")
  case "$CANDIDATE" in
    chrome_left|chrome_right) LAYOUT=$CANDIDATE; USED_OVERRIDE=yes ;;
    *) echo "invalid next-layout '$CANDIDATE', ignoring it and falling back to the counter" >&2 ;;
  esac
fi

COUNT=$(cat "$COUNTER" 2>/dev/null || echo 0)
case "$COUNT" in ''|*[!0-9]*) COUNT=0 ;; esac

if [ -z "$LAYOUT" ]; then
  if [ $((COUNT % 2)) -eq 0 ]; then LAYOUT=chrome_left; else LAYOUT=chrome_right; fi
fi

case "$LAYOUT" in
  chrome_left)  SRC=$LAYOUT_DIR/chrome-left.yaml ;;
  chrome_right) SRC=$LAYOUT_DIR/chrome-right.yaml ;;
esac

# --- 2. validate before touching anything live ---
if [ ! -r "$SRC" ]; then
  echo "layout file $SRC is missing or unreadable; leaving the live config untouched" >&2
  exit 1
fi
if ! python3 -c "import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if isinstance(d,dict) and 'default' in d.get('layouts',{}) else 1)" "$SRC" 2>/dev/null; then
  echo "layout file $SRC is not valid YAML or lacks layouts.default; leaving the live config untouched" >&2
  exit 1
fi

# --- 3. apply; only proceed to state updates if this succeeds ---
if ! snap set ubuntu-frame display="$(cat "$SRC")"; then
  echo "snap set failed; not advancing the counter or consuming next-layout" >&2
  exit 1
fi

# --- 4. now record what actually went live (atomic writes) ---
NEXT=$((COUNT + 1))
printf '%s' "$NEXT" > "$COUNTER.tmp" && sync && mv -f "$COUNTER.tmp" "$COUNTER"
printf '%s' "$LAYOUT" > "$STATE_DIR/last-layout.tmp" && sync && mv -f "$STATE_DIR/last-layout.tmp" "$STATE_DIR/last-layout"

# --- 5. consume the override only after everything else succeeded ---
if [ "$USED_OVERRIDE" = yes ]; then
  rm -f "$OVERRIDE"
fi

echo "applied layout: $LAYOUT (counter now $NEXT)"
