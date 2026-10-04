#!/bin/bash
# Connect YOUR OWN practice repository to the kiosk VS Code.
#
# Creates an SSH key for the `coder` account (if it has none), shows the
# public key so you can add it to your repository as a deploy key, then
# clones the repository into STUDY_DIR.
#
# Usage:
#   sudo ./scripts/setup-study-repo.sh                 # reads ../kiosk.conf
#   sudo STUDY_REPO_URL=git@github.com:<you>/<repo>.git ./scripts/setup-study-repo.sh
#
# A deploy key is scoped to a single repository, so even if the kiosk is
# compromised it cannot touch anything else on your GitHub account. Tick
# "Allow write access" when adding it if you want to push your solutions.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
CONF=${KIOSK_CONF:-$REPO_DIR/kiosk.conf}
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }

# Environment wins over kiosk.conf.
ENV_URL=${STUDY_REPO_URL:-}; ENV_DIR=${STUDY_DIR:-}
# shellcheck source=../kiosk.conf.example
[ -r "$CONF" ] && . "$CONF"
STUDY_REPO_URL=${ENV_URL:-${STUDY_REPO_URL:-}}
STUDY_DIR=${ENV_DIR:-${STUDY_DIR:-/home/coder/study}}
[ -n "$STUDY_REPO_URL" ] || { echo "set STUDY_REPO_URL in kiosk.conf or the environment" >&2; exit 1; }

as_coder() { sudo -H -u coder "$@"; }

KEY=/home/coder/.ssh/id_ed25519
install -d -o coder -g coder -m 0700 /home/coder/.ssh
if [ ! -f "$KEY" ]; then
  as_coder ssh-keygen -q -t ed25519 -N "" -C "coder@$(hostname)-practice-kiosk" -f "$KEY"
fi

case "$STUDY_REPO_URL" in
  git@*:*|ssh://*)
    HOST=$(printf '%s' "$STUDY_REPO_URL" | sed -E 's#^ssh://##; s#^[^@]*@##; s#[:/].*$##')
    if ! as_coder ssh-keygen -F "$HOST" >/dev/null 2>&1; then
      ssh-keyscan -t ed25519 "$HOST" 2>/dev/null | as_coder tee -a /home/coder/.ssh/known_hosts >/dev/null
    fi
    ;;
esac

try_clone() {
  if [ -d "$STUDY_DIR/.git" ]; then
    echo "$STUDY_DIR is already a git repository; nothing to clone."
    return 0
  fi
  if [ -e "$STUDY_DIR" ] && [ -n "$(ls -A "$STUDY_DIR" 2>/dev/null)" ]; then
    echo "$STUDY_DIR exists and is not empty; move it away first." >&2
    return 1
  fi
  install -d -o coder -g coder -m 0755 "$(dirname "$STUDY_DIR")"
  rmdir "$STUDY_DIR" 2>/dev/null || true
  as_coder env GIT_SSH_COMMAND="ssh -o BatchMode=yes" git clone "$STUDY_REPO_URL" "$STUDY_DIR"
}

if try_clone 2>/dev/null; then
  echo "Cloned $STUDY_REPO_URL into $STUDY_DIR"
  exit 0
fi

cat <<EOF

Add this public key to your practice repository as a deploy key
(GitHub: Settings -> Deploy keys -> Add deploy key; tick "Allow write access"
if you want to push from the kiosk):

$(cat "$KEY.pub")

EOF
if [ -t 0 ]; then
  read -r -p "Press Enter once the key is added... " _
  try_clone && { echo "Cloned $STUDY_REPO_URL into $STUDY_DIR"; exit 0; }
fi
echo "Clone not done yet. Re-run this script after adding the key." >&2
exit 1
