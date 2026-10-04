#!/bin/sh
# Liveness + config-drift check for the dual-screen kiosk.
#
# SCOPE -- what this does and does NOT cover:
#   Covered: each kiosk app is running under its intended account; each
#   account can actually open a connection to the compositor's Wayland
#   socket (a real connect(), not just a permission bit); the layout the
#   picker believes is live matches what Frame was actually given.
#   NOT covered: whether a window ended up on the correct physical output.
#   Frame places windows by exact surface-title match, and Chrome's rule
#   keys off its pre-navigation placeholder title, which is not a stable
#   API. If that stops matching, the window silently falls back to the
#   default output and THIS SCRIPT WILL STILL REPORT ok. Verifying actual
#   placement needs Frame's --window-management-trace and a swap test; see
#   the "swap test" section of docs/LESSONS.md.
STATUS=0

check_proc() {
  user=$1; pattern=$2; label=$3
  if ! pgrep -u "$user" -f "$pattern" >/dev/null 2>&1; then
    echo "KIOSK-HEALTH: $label is not running as user $user" >&2
    STATUS=1
  fi
}

# Match the real binary, not the google-chrome-stable wrapper script.
check_proc leetcode '/opt/google/chrome/chrome --ozone-platform=wayland' 'Chrome kiosk'
check_proc coder    '/usr/share/code/code --ozone-platform=wayland'      'VSCode kiosk'

SOCK=/run/user/@FRAME_UID@/wayland-0
if [ ! -S "$SOCK" ]; then
  echo "KIOSK-HEALTH: Wayland socket $SOCK does not exist; the compositor is probably down" >&2
  STATUS=1
else
  # Real connect() as each account -- a readable/writable bit is not proof
  # that the compositor will actually accept the connection.
  for u in leetcode coder; do
    if ! sudo -u "$u" python3 -c "
import socket,sys
s=socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.settimeout(5); s.connect('$SOCK'); s.close()
except Exception as e:
    print(e, file=sys.stderr); sys.exit(1)
" 2>/dev/null; then
      echo "KIOSK-HEALTH: user $u cannot connect to $SOCK (check the #effective column / mask in getfacl)" >&2
      STATUS=1
    fi
  done
fi

# Config drift: does Frame actually hold the layout the picker recorded?
LAST=$(cat /var/lib/kiosk-side/last-layout 2>/dev/null || echo "")
case "$LAST" in
  chrome_left)  EXPECT=/etc/kiosk/layouts/chrome-left.yaml ;;
  chrome_right) EXPECT=/etc/kiosk/layouts/chrome-right.yaml ;;
  *) echo "KIOSK-HEALTH: unexpected last-layout content ('$LAST')" >&2; STATUS=1; EXPECT="" ;;
esac
if [ -n "$EXPECT" ]; then
  if ! snap get ubuntu-frame display 2>/dev/null | diff -q - "$EXPECT" >/dev/null 2>&1; then
    echo "KIOSK-HEALTH: the display config Frame holds does not match last-layout ($LAST); picker state has drifted" >&2
    STATUS=1
  fi
fi

if [ "$STATUS" -eq 0 ]; then
  echo "KIOSK-HEALTH: ok (layout=$LAST; note: actual window placement is NOT verified)"
fi
exit "$STATUS"
