#!/bin/bash
# Turn a Raspberry Pi 5 (Raspberry Pi OS / Debian 13 "trixie", arm64) into a
# distraction-free LeetCode + VS Code practice machine.
#
# Usage:
#   cp kiosk.conf.example kiosk.conf   # then edit it
#   sudo ./install.sh
#
# Safe to re-run: every step is idempotent, and re-running after editing
# kiosk.conf re-renders and re-applies the configuration.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
CONF=${KIOSK_CONF:-$REPO_DIR/kiosk.conf}

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0"
[ "$(dpkg --print-architecture)" = arm64 ] || die "this installer targets arm64 (64-bit Raspberry Pi OS)"
[ -r "$CONF" ] || die "$CONF not found. Run: cp kiosk.conf.example kiosk.conf  and edit it"

# shellcheck source=kiosk.conf.example
. "$CONF"
: "${MODE:=dual}" "${SCREEN_WIDTH:=1920}" "${SCREEN_HEIGHT:=1080}" "${SCREEN_REFRESH:=60.0}"
: "${START_URL:=https://leetcode.com}" "${ALLOWED_URLS:=leetcode.com challenges.cloudflare.com}"
: "${STUDY_REPO_URL:=}" "${STUDY_DIR:=/home/coder/study}"
: "${GIT_USER_NAME:=}" "${GIT_USER_EMAIL:=}"
: "${CHROME_INITIAL_TITLE:=Untitled - Google Chrome}"
case "$MODE" in dual|single) ;; *) die "MODE must be 'dual' or 'single' (got '$MODE')" ;; esac

# ---------------------------------------------------------------- packages --
log "Adding Google Chrome and VS Code apt repositories"
command -v curl >/dev/null && command -v gpg >/dev/null || { apt-get update && apt-get install -y curl gpg; }
install -d -m 0755 /etc/apt/keyrings
if [ ! -s /usr/share/keyrings/google-chrome.gpg ]; then
  curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
fi
if ! ls /etc/apt/sources.list.d/google-chrome.* >/dev/null 2>&1; then
  # Same deb822 file the Chrome package itself maintains, so the two agree.
  cat > /etc/apt/sources.list.d/google-chrome.sources <<'EOF'
X-Repolib-Name: Google Chrome
Types: deb
URIs: https://dl.google.com/linux/chrome-stable/deb/
Suites: stable
Components: main
Architectures: arm64
Signed-By: /usr/share/keyrings/google-chrome.gpg
EOF
fi
if [ ! -s /etc/apt/keyrings/packages.microsoft.gpg ]; then
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/packages.microsoft.gpg
fi
if ! ls /etc/apt/sources.list.d/vscode.* >/dev/null 2>&1; then
  echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
    > /etc/apt/sources.list.d/vscode.list
fi

log "Installing packages"
PKGS="google-chrome-stable code git acl python3 python3-yaml dbus"
if [ "$MODE" = dual ]; then PKGS="$PKGS snapd"; else PKGS="$PKGS cage"; fi
apt-get update
# shellcheck disable=SC2086
DEBIAN_FRONTEND=noninteractive apt-get install -y $PKGS

if [ "$MODE" = dual ]; then
  log "Installing Ubuntu Frame (snap)"
  snap wait system seed.loaded
  snap list ubuntu-frame >/dev/null 2>&1 || snap install ubuntu-frame --channel=24/stable
  # Frame is started by our own systemd unit, not by the snap's daemon.
  snap set ubuntu-frame daemon=false
fi

# ---------------------------------------------------------------- accounts --
log "Creating kiosk accounts"
for u in leetcode coder; do
  id "$u" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$u"
  # Explicit membership: do not rely on logind's dynamic device ACLs.
  usermod -aG video,render "$u"
done
if [ "$MODE" = dual ]; then
  # Display host for the dual-screen session. Neither app account may own the
  # whole display, so a third, powerless account runs the compositor.
  id frame >/dev/null 2>&1 || useradd --system --shell /usr/sbin/nologin --groups video,render frame
  install -d -o frame -g frame -m 0750 /home/frame   # snap needs $HOME/snap
  FRAME_UID=$(id -u frame)
else
  FRAME_UID=""
fi

# --------------------------------------------------------------- templates --
ALLOWED_URLS_JSON=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1].split()))' "$ALLOWED_URLS")
export FRAME_UID SCREEN_WIDTH SCREEN_HEIGHT SCREEN_REFRESH START_URL STUDY_DIR \
       ALLOWED_URLS_JSON CHROME_INITIAL_TITLE

# Copy one tree from rootfs/ into /, substituting @PLACEHOLDER@ tokens.
render_tree() {
  src_root=$1
  ( cd "$src_root" && find . -type f ) | while read -r rel; do
    src="$src_root/${rel#./}"; dst="/${rel#./}"
    install -d -m 0755 "$(dirname "$dst")"
    python3 - "$src" "$dst" <<'PY'
import os, re, sys
src, dst = sys.argv[1], sys.argv[2]
keys = ["FRAME_UID", "SCREEN_WIDTH", "SCREEN_HEIGHT", "SCREEN_REFRESH", "START_URL",
        "STUDY_DIR", "ALLOWED_URLS_JSON", "CHROME_INITIAL_TITLE"]
text = open(src).read()
text = re.sub(r"@(%s)@" % "|".join(keys), lambda m: os.environ[m.group(1)], text)
left = re.findall(r"@[A-Z_]{3,}@", text)
if left:
    sys.exit("unrendered placeholder(s) %s in %s" % (left, src))
open(dst, "w").write(text)
PY
    case "$dst" in
      *.sh|*.py) chmod 0755 "$dst" ;;
      *)         chmod 0644 "$dst" ;;
    esac
  done
}

log "Stopping any running kiosk services"
systemctl stop kiosk-health-check.timer kiosk-leetcode-dual kiosk-vscode-dual kiosk-frame \
  kiosk-leetcode kiosk-vscode kiosk-mode-picker 2>/dev/null || true

log "Removing units of the other mode (so they cannot be started by accident)"
if [ "$MODE" = dual ]; then
  systemctl disable kiosk-mode-picker 2>/dev/null || true
  rm -f /etc/systemd/system/kiosk-{leetcode,vscode,mode-picker}.service \
        /usr/local/sbin/kiosk-mode-picker.sh /etc/kiosk/wrapper-*.sh
else
  systemctl disable kiosk-side-picker kiosk-frame kiosk-leetcode-dual kiosk-vscode-dual \
    kiosk-health-check.timer 2>/dev/null || true
  rm -f /etc/systemd/system/kiosk-{side-picker,frame,leetcode-dual,vscode-dual}.service \
        /etc/systemd/system/kiosk-health-check.{service,timer} \
        /usr/local/sbin/kiosk-{side-picker,health-check}.sh \
        /etc/kiosk/frame-host.sh /etc/kiosk/wait-for-wayland.py
  rm -rf /etc/kiosk/layouts
fi

log "Installing configuration files ($MODE mode)"
render_tree "$REPO_DIR/rootfs/common"
render_tree "$REPO_DIR/rootfs/$MODE"
systemd-tmpfiles --create /etc/tmpfiles.d/kiosk.conf

# ------------------------------------------------------------ coder / VS Code --
log "Configuring VS Code for the coder account"
CODE_USER_DIR=/home/coder/.config/Code/User
install -d -o coder -g coder -m 0700 /home/coder/.config
install -d -o coder -g coder -m 0755 /home/coder/.config/Code "$CODE_USER_DIR" /home/coder/.vscode
if [ -e "$CODE_USER_DIR/settings.json" ]; then
  # Never clobber the user's own settings; only the window title is mandatory.
  grep -q '"window.title"' "$CODE_USER_DIR/settings.json" \
    || warn "$CODE_USER_DIR/settings.json lacks \"window.title\": \"Visual Studio Code\" -- dual mode needs it"
else
  install -o coder -g coder -m 0644 "$REPO_DIR/coder-home/settings.json" "$CODE_USER_DIR/settings.json"
fi
[ -e /home/coder/.vscode/argv.json ] \
  || install -o coder -g coder -m 0644 "$REPO_DIR/coder-home/argv.json" /home/coder/.vscode/argv.json

if [ -n "$GIT_USER_NAME" ]; then sudo -H -u coder git config --global user.name "$GIT_USER_NAME"; fi
if [ -n "$GIT_USER_EMAIL" ]; then sudo -H -u coder git config --global user.email "$GIT_USER_EMAIL"; fi

log "Preparing the practice workspace at $STUDY_DIR"
if [ -n "$STUDY_REPO_URL" ] && [ ! -d "$STUDY_DIR/.git" ]; then
  STUDY_REPO_URL=$STUDY_REPO_URL STUDY_DIR=$STUDY_DIR "$REPO_DIR/scripts/setup-study-repo.sh" \
    || warn "practice repo not cloned yet; re-run: sudo ./scripts/setup-study-repo.sh"
fi
if [ ! -d "$STUDY_DIR" ]; then
  install -d -o coder -g coder -m 0755 "$STUDY_DIR"
  sudo -H -u coder git -C "$STUDY_DIR" init -q
  printf '# My practice\n\nOne file per problem. Commit often.\n' \
    | sudo -H -u coder tee "$STUDY_DIR/README.md" >/dev/null
fi

# ----------------------------------------------------------------- systemd --
log "Enabling services"
systemctl daemon-reload
# The kiosk owns tty1 and the GPU; a desktop session would fight it for DRM master.
for dm in lightdm gdm3 sddm; do
  if systemctl is-enabled "$dm" >/dev/null 2>&1; then
    warn "disabling display manager $dm (the kiosk needs exclusive access to the display)"
    systemctl disable "$dm"
  fi
done
systemctl set-default multi-user.target
if [ "$MODE" = dual ]; then
  systemctl enable kiosk-side-picker.service kiosk-frame.service \
    kiosk-leetcode-dual.service kiosk-vscode-dual.service kiosk-health-check.timer
else
  systemctl enable kiosk-mode-picker.service
fi

log "Done. Reboot to start the kiosk: sudo reboot"
cat <<EOF

  Mode:            $MODE
  Browser opens:   $START_URL   (allowed: $ALLOWED_URLS)
  VS Code opens:   $STUDY_DIR

  Maintenance:     keep using SSH with your admin account.
  Emergency exit:  add 'kiosk=off' to /boot/firmware/cmdline.txt and reboot.
  Docs:            README.md, docs/LESSONS.md
EOF
