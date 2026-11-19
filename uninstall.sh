#!/bin/bash
# Remove the kiosk services and configuration installed by install.sh.
#
# Keeps the `leetcode`, `coder` and `frame` accounts and their home
# directories (your practice repo and LeetCode login live there), and keeps
# the installed packages. Pass --purge-users to delete the accounts too.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }

systemctl disable --now kiosk-health-check.timer kiosk-leetcode-dual kiosk-vscode-dual \
  kiosk-frame kiosk-side-picker kiosk-leetcode kiosk-vscode kiosk-mode-picker \
  kiosk-frame@leetcode kiosk-frame@vscode kiosk-leetcode-frame kiosk-vscode-frame 2>/dev/null || true

rm -f /etc/systemd/system/kiosk-*.service /etc/systemd/system/kiosk-*.timer \
      /usr/local/sbin/kiosk-*.sh \
      /etc/opt/chrome/policies/managed/kiosk.json \
      /etc/pam.d/cage /etc/logrotate.d/kiosk /etc/tmpfiles.d/kiosk.conf \
      /usr/local/sbin/kiosk-update /etc/polkit-1/rules.d/50-kiosk-coder-network.rules \
      /etc/sudoers.d/kiosk-coder-update
rm -rf /etc/kiosk /var/lib/kiosk-side /var/lib/kiosk-mode
systemctl daemon-reload

if [ "${1:-}" = --purge-users ]; then
  for u in leetcode coder frame; do
    id "$u" >/dev/null 2>&1 && userdel -r "$u" 2>/dev/null || true
  done
fi

echo "Kiosk removed. To get a desktop back: sudo systemctl set-default graphical.target"
echo "(and re-enable your display manager, e.g. sudo systemctl enable lightdm), then reboot."
