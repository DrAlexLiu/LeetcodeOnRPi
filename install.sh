#!/bin/bash
# Turn a Raspberry Pi 5 (Raspberry Pi OS / Debian 13 "trixie", arm64) into a
# distraction-free LeetCode + VS Code practice machine. Also tested on a
# Radxa Dragon Q6A (Ubuntu 24.04, arm64) with MODE=single COMPOSITOR=frame.
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
[ "$(dpkg --print-architecture)" = arm64 ] || die "this installer targets arm64 (e.g. 64-bit Raspberry Pi OS)"
[ -r "$CONF" ] || die "$CONF not found. Run: cp kiosk.conf.example kiosk.conf  and edit it"

# shellcheck source=kiosk.conf.example
. "$CONF"
: "${MODE:=dual}" "${SCREEN_WIDTH:=1920}" "${SCREEN_HEIGHT:=1080}" "${SCREEN_REFRESH:=60.0}"
: "${COMPOSITOR:=cage}" "${SCREEN_OUTPUT:=HDMI-A-1}" "${CODER_ADMIN:=no}"
: "${REMOVE_OTHER_BROWSERS:=yes}" "${CODER_BLOCK_SSH:=no}"
: "${START_URL:=https://leetcode.com}" "${ALLOWED_URLS:=leetcode.com challenges.cloudflare.com}"
: "${STUDY_REPO_URL:=}" "${STUDY_DIR:=/home/coder/study}"
: "${GIT_USER_NAME:=}" "${GIT_USER_EMAIL:=}"
: "${CHROME_INITIAL_TITLE:=Untitled - Google Chrome}"
case "$MODE" in dual|single) ;; *) die "MODE must be 'dual' or 'single' (got '$MODE')" ;; esac
case "$COMPOSITOR" in cage|frame) ;; *) die "COMPOSITOR must be 'cage' or 'frame' (got '$COMPOSITOR')" ;; esac
case "$CODER_ADMIN" in yes|no) ;; *) die "CODER_ADMIN must be 'yes' or 'no' (got '$CODER_ADMIN')" ;; esac
case "$REMOVE_OTHER_BROWSERS" in yes|no) ;; *) die "REMOVE_OTHER_BROWSERS must be 'yes' or 'no' (got '$REMOVE_OTHER_BROWSERS')" ;; esac
case "$CODER_BLOCK_SSH" in yes|no) ;; *) die "CODER_BLOCK_SSH must be 'yes' or 'no' (got '$CODER_BLOCK_SSH')" ;; esac
# FLAVOR names the rootfs/ tree to install. Every flavor except `single`
# (Cage) runs Ubuntu Frame as the `frame` account.
case "$MODE:$COMPOSITOR" in
  dual:*)       FLAVOR=dual ;;
  single:cage)  FLAVOR=single ;;
  single:frame) FLAVOR=single-frame ;;
esac

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
if [ "$FLAVOR" = single ]; then PKGS="$PKGS cage"; else PKGS="$PKGS snapd"; fi
apt-get update
# shellcheck disable=SC2086
DEBIAN_FRONTEND=noninteractive apt-get install -y $PKGS

if [ "$FLAVOR" != single ]; then
  log "Installing Ubuntu Frame (snap)"
  snap wait system seed.loaded
  snap list ubuntu-frame >/dev/null 2>&1 || snap install ubuntu-frame --channel=24/stable
  # Frame is started by our own systemd unit, not by the snap's daemon.
  snap set ubuntu-frame daemon=false
fi

# The kiosk browser is the locked-down Chrome. Any other browser is a way out
# of the allowlist (open a link, reach the whole web), so remove it and hold it
# so an upgrade cannot bring it back. No-op on images that ship none.
if [ "$REMOVE_OTHER_BROWSERS" = yes ]; then
  log "Removing any browser other than the kiosk Chrome"
  for b in firefox firefox-esr chromium chromium-browser; do
    if dpkg -l "$b" 2>/dev/null | grep -q '^ii'; then
      DEBIAN_FRONTEND=noninteractive apt-get purge -y "$b" || warn "could not purge $b"
      apt-mark hold "$b" >/dev/null 2>&1 || true
    fi
  done
fi

# ---------------------------------------------------------------- accounts --
log "Creating kiosk accounts"
for u in leetcode coder; do
  id "$u" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$u"
  # Explicit membership: do not rely on logind's dynamic device ACLs.
  usermod -aG video,render "$u"
done
if [ "$FLAVOR" != single ]; then
  # Display host for the Frame session. Neither app account may own the
  # whole display, so a third, powerless account runs the compositor.
  id frame >/dev/null 2>&1 || useradd --system --shell /usr/sbin/nologin --groups video,render frame
  install -d -o frame -g frame -m 0750 /home/frame   # snap needs $HOME/snap
  FRAME_UID=$(id -u frame)
else
  FRAME_UID=""
fi

# --------------------------------------------------------------- templates --
ALLOWED_URLS_JSON=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1].split()))' "$ALLOWED_URLS")
export FRAME_UID SCREEN_WIDTH SCREEN_HEIGHT SCREEN_REFRESH SCREEN_OUTPUT START_URL STUDY_DIR \
       ALLOWED_URLS_JSON CHROME_INITIAL_TITLE

# Copy one tree from rootfs/ into /, substituting @PLACEHOLDER@ tokens.
# Optional further arguments: copy only these files (./path relative to the tree).
render_tree() {
  src_root=$1; shift
  if [ $# -gt 0 ]; then printf '%s\n' "$@"; else ( cd "$src_root" && find . -type f ); fi | while read -r rel; do
    src="$src_root/${rel#./}"; dst="/${rel#./}"
    install -d -m 0755 "$(dirname "$dst")"
    python3 - "$src" "$dst" <<'PY'
import os, re, sys
src, dst = sys.argv[1], sys.argv[2]
keys = ["FRAME_UID", "SCREEN_WIDTH", "SCREEN_HEIGHT", "SCREEN_REFRESH", "SCREEN_OUTPUT",
        "START_URL", "STUDY_DIR", "ALLOWED_URLS_JSON", "CHROME_INITIAL_TITLE"]
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
  kiosk-leetcode kiosk-vscode kiosk-mode-picker \
  kiosk-frame@leetcode kiosk-frame@vscode kiosk-leetcode-frame kiosk-vscode-frame 2>/dev/null || true

remove_dual() {
  systemctl disable kiosk-side-picker kiosk-frame kiosk-leetcode-dual kiosk-vscode-dual \
    kiosk-health-check.timer 2>/dev/null || true
  rm -f /etc/systemd/system/kiosk-{side-picker,frame,leetcode-dual,vscode-dual}.service \
        /etc/systemd/system/kiosk-health-check.{service,timer} \
        /usr/local/sbin/kiosk-{side-picker,health-check}.sh
}
remove_single_cage() {
  rm -f /etc/systemd/system/kiosk-{leetcode,vscode}.service /etc/kiosk/wrapper-*.sh
}
remove_single_frame() {
  rm -f /etc/systemd/system/kiosk-frame@.service \
        /etc/systemd/system/kiosk-{leetcode,vscode}-frame.service
}
remove_mode_picker() {
  systemctl disable kiosk-mode-picker 2>/dev/null || true
  rm -f /etc/systemd/system/kiosk-mode-picker.service /usr/local/sbin/kiosk-mode-picker.sh
}

log "Removing units of the other modes (so they cannot be started by accident)"
case "$FLAVOR" in
  dual)         remove_single_cage; remove_single_frame; remove_mode_picker ;;
  single)       remove_dual; remove_single_frame ;;
  single-frame) remove_dual; remove_single_cage ;;
esac
# Shared Frame files are rendered again below when the flavor needs them.
rm -f /etc/kiosk/frame-host.sh /etc/kiosk/wait-for-wayland.py
rm -rf /etc/kiosk/layouts

log "Installing configuration files ($FLAVOR)"
render_tree "$REPO_DIR/rootfs/common"
case "$FLAVOR" in
  dual|single)
    render_tree "$REPO_DIR/rootfs/$FLAVOR" ;;
  single-frame)
    render_tree "$REPO_DIR/rootfs/dual" ./etc/kiosk/frame-host.sh ./etc/kiosk/wait-for-wayland.py
    render_tree "$REPO_DIR/rootfs/single-frame" ;;
esac

# Log files, one owner each. /var/log/kiosk stays root:root 0755 so that
# logrotate accepts it; the services only append to their own file.
{
  echo "d /var/log/kiosk 0755 root root -"
  if [ "$FLAVOR" != single ]; then
    echo "f /var/log/kiosk/frame.log 0640 frame frame -"
    echo "f /var/log/kiosk/leetcode.log 0640 leetcode leetcode -"
    echo "f /var/log/kiosk/vscode.log 0640 coder coder -"
  fi
} > /etc/tmpfiles.d/kiosk.conf
chmod 0644 /etc/tmpfiles.d/kiosk.conf
systemd-tmpfiles --create /etc/tmpfiles.d/kiosk.conf

if [ "$FLAVOR" = single-frame ]; then
  log "Applying the Ubuntu Frame display layout ($SCREEN_OUTPUT ${SCREEN_WIDTH}x${SCREEN_HEIGHT}@${SCREEN_REFRESH})"
  python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' /etc/kiosk/layouts/single.yaml
  snap set ubuntu-frame display="$(cat /etc/kiosk/layouts/single.yaml)"
fi

# Optional, off by default: coder may manage the network and update packages.
# Copied with exact modes (no templates) so system directories keep theirs.
ADMIN_SRC=$REPO_DIR/rootfs/coder-admin
if [ "$CODER_ADMIN" = yes ]; then
  log "Letting coder manage the network (nmtui/nmcli) and run 'sudo kiosk-update'"
  install -D -m 0755 "$ADMIN_SRC/usr/local/sbin/kiosk-update" /usr/local/sbin/kiosk-update
  install -D -m 0644 "$ADMIN_SRC/etc/polkit-1/rules.d/50-kiosk-coder-network.rules" \
    /etc/polkit-1/rules.d/50-kiosk-coder-network.rules
  # sudo ignores names containing '.', so the rule is inert until it validates.
  tmp=$(mktemp /etc/sudoers.d/.kiosk-coder-update.XXXXXX)
  install -m 0440 "$ADMIN_SRC/etc/sudoers.d/kiosk-coder-update" "$tmp"
  visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; die "sudoers rule for kiosk-update failed validation"; }
  mv -f "$tmp" /etc/sudoers.d/kiosk-coder-update
else
  rm -f /usr/local/sbin/kiosk-update /etc/polkit-1/rules.d/50-kiosk-coder-network.rules \
        /etc/sudoers.d/kiosk-coder-update
fi

# Optional, off by default: stop coder ssh-ing out to other machines. git keeps
# working because github is reached over its 443 endpoint, which the firewall
# does not touch; so does all HTTPS (Codex, extensions). This is set up before
# the practice repo is cloned below, so the clone already uses 443.
LOCKDOWN_SRC=$REPO_DIR/rootfs/coder-lockdown
if [ "$CODER_BLOCK_SSH" = yes ]; then
  log "Blocking coder's outbound SSH (port 22); routing its git over github:443"
  install -d -o coder -g coder -m 0700 /home/coder/.ssh
  CODER_SSH_CFG=/home/coder/.ssh/config
  if ! grep -q 'HostName ssh.github.com' "$CODER_SSH_CFG" 2>/dev/null; then
    cat >> "$CODER_SSH_CFG" <<'EOF'

Host github.com
    HostName ssh.github.com
    Port 443
    User git
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
EOF
    chown coder:coder "$CODER_SSH_CFG"; chmod 600 "$CODER_SSH_CFG"
  fi
  if ! sudo -u coder ssh-keygen -F '[ssh.github.com]:443' >/dev/null 2>&1; then
    ssh-keyscan -p 443 -t ed25519 ssh.github.com 2>/dev/null \
      | sudo -u coder tee -a /home/coder/.ssh/known_hosts >/dev/null
  fi
  install -D -m 0755 "$LOCKDOWN_SRC/usr/local/sbin/kiosk-coder-firewall" /usr/local/sbin/kiosk-coder-firewall
  install -D -m 0644 "$LOCKDOWN_SRC/etc/systemd/system/kiosk-coder-firewall.service" \
    /etc/systemd/system/kiosk-coder-firewall.service
  systemctl enable kiosk-coder-firewall.service >/dev/null 2>&1 || warn "could not enable kiosk-coder-firewall"
else
  systemctl disable --now kiosk-coder-firewall.service 2>/dev/null || true
  rm -f /usr/local/sbin/kiosk-coder-firewall /etc/systemd/system/kiosk-coder-firewall.service
fi

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

# Send any link coder opens (VS Code "open in browser", xdg-open) through the
# policy-locked Chrome rather than an unmanaged browser.
if [ "$REMOVE_OTHER_BROWSERS" = yes ]; then
  sudo -H -u coder xdg-settings set default-web-browser google-chrome.desktop 2>/dev/null || true
fi

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
    # On Ubuntu gdm3 is an alias of a static unit and cannot always be disabled;
    # multi-user.target below keeps it from starting either way.
    systemctl disable "$dm" || warn "could not disable $dm; relying on multi-user.target"
  fi
done
systemctl set-default multi-user.target
case "$FLAVOR" in
  dual)
    systemctl enable kiosk-side-picker.service kiosk-frame.service \
      kiosk-leetcode-dual.service kiosk-vscode-dual.service kiosk-health-check.timer ;;
  single|single-frame)
    systemctl enable kiosk-mode-picker.service ;;
esac

# Where the kernel command line lives decides how to leave the kiosk.
if [ -f /boot/firmware/cmdline.txt ]; then
  EXIT_HINT="add 'kiosk=off' to /boot/firmware/cmdline.txt and reboot."
elif ls /boot/efi/loader/entries/*.conf >/dev/null 2>&1; then
  EXIT_HINT="add 'kiosk=off' to the 'options' line in /boot/efi/loader/entries/*.conf
                   (or press 'e' in the systemd-boot menu) and reboot."
else
  EXIT_HINT="add 'kiosk=off' to the kernel command line and reboot."
fi

log "Done. Reboot to start the kiosk: sudo reboot"
cat <<EOF

  Mode:            $MODE ($FLAVOR)
  Browser opens:   $START_URL   (allowed: $ALLOWED_URLS)
  VS Code opens:   $STUDY_DIR

  Maintenance:     keep using SSH with your admin account.
  Emergency exit:  $EXIT_HINT
  Docs:            README.md, docs/LESSONS.md
EOF
