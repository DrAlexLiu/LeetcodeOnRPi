# How it works, and the traps we hit

This is the engineering log behind the scripts. Read it before changing
anything: almost every odd-looking line in `rootfs/` exists because of one of
the traps below.

Tested on: Raspberry Pi 5 (8 GB), Raspberry Pi OS based on Debian 13 "trixie"
arm64, NVMe boot, two 1920x1080 HDMI monitors. Ubuntu Frame `457-mir2.26.0`
(snap channel `24/stable`), Cage `0.2.0`, Google Chrome 151, VS Code 1.134.

## Accounts

| Account    | Runs                  | sudo | Why                                                         |
|------------|-----------------------|------|-------------------------------------------------------------|
| your admin | SSH only              | yes  | maintenance; never shown on screen                          |
| `leetcode` | Chrome (kiosk)        | no   | least-privileged; the only account rendering web content    |
| `coder`    | VS Code               | no   | owns your practice repo                                     |
| `frame`    | Ubuntu Frame (dual)   | no   | system account, `nologin`; hosts the display for both apps  |

All three kiosk accounts are added to `video` and `render` explicitly instead
of relying on logind's dynamic device ACLs, which are not always applied to
sessions started by systemd units.

**Do not put `coder` in the `docker` group.** Docker group membership is
equivalent to root on the host (mount `/`, `--privileged`). Practising
LeetCode does not need it.

Optional hardening for your admin account: once SSH key login works, lock its
password with `sudo passwd -l <admin>` (and `sudo passwd -l root`). SSH keys
and `NOPASSWD` sudo keep working; nobody at the keyboard can log in.

## Dual-screen mode (Ubuntu Frame)

```
kiosk-side-picker.service   (oneshot, once per boot: decides which side is which)
        | Before=
kiosk-frame.service         (User=frame, Ubuntu Frame compositor, tty1)
        | BindsTo= / Upholds=
        +-- kiosk-leetcode-dual.service  (User=leetcode, Chrome)
        +-- kiosk-vscode-dual.service    (User=coder,    VS Code)
kiosk-health-check.timer    (every 15 min, logs to journal at err priority)
```

The two micro-HDMI ports of a Pi 5 are independent outputs, so one compositor
can drive both and place a different app on each.

### Why a third `frame` account

Both apps must connect to the same compositor. Letting `leetcode` host it would
give the account that renders untrusted web content control over the whole
display, including the other screen. Letting `coder` host it makes the two
apps unequal. So a third account that runs nothing but the compositor hosts
it, and both apps are equal clients.

Snap needs `$HOME/snap/...`, so `/home/frame` must exist even though the
account has no login shell (otherwise: `cannot create user data directory`).

### Trap 1: the ACL mask silently eats write permission

Frame's socket is `/run/user/<frame-uid>/wayland-0`, mode `0700`. The clients
are granted access with ACLs, and **the mask must be set explicitly**:

```sh
setfacl -m u:leetcode:x,u:coder:x,m::rx  /run/user/<uid>            # dir: search only
setfacl -d -m u:leetcode:rw,u:coder:rw,m::rw /run/user/<uid>        # default ACL for new sockets
setfacl -m u:leetcode:rw,u:coder:rw,m::rw /run/user/<uid>/wayland-0
```

Without `m::`, `getfacl` shows `user:leetcode:rw-  #effective:r--`. The
declared permission looks right, but the client fails with
`Failed to connect to Wayland display: Permission denied`. Always read the
`#effective:` column.

The directory only gets `x`: connecting to a unix socket needs search on the
path plus `rw` on the socket. With `w` on the directory a client could
delete or replace `wayland-0` in the compositor's own runtime dir.

Frame sometimes recreates the socket, so `frame-host.sh` re-applies the socket
ACL a few times after it appears.

### Trap 2: `pam_systemd` overwrites `XDG_RUNTIME_DIR` (the sneakiest one)

The client units use `PAMName=cage` so they get a real logind session (needed
for device access). But `pam_systemd` then **resets `XDG_RUNTIME_DIR` to the
client's own `/run/user/<uid>`**, overriding the unit's `Environment=`. The
client looks for the socket in the wrong directory.

It shows up as an *intermittent* `Failed to connect to Wayland display`, and
manual tests like `sudo -u leetcode env XDG_RUNTIME_DIR=... google-chrome`
always succeed, because they skip the PAM session.

**Diagnose** by putting `env > /tmp/envcheck.log` in front of `ExecStart` and
looking at what systemd actually passed. Do not reason about it.

**Fix:** do not depend on `XDG_RUNTIME_DIR` at all. Give `WAYLAND_DISPLAY` an
absolute path. libwayland uses a value starting with `/` as the full socket
path:

```ini
Environment=WAYLAND_DISPLAY=/run/user/<frame-uid>/wayland-0
```

### Trap 3: `size` is mandatory in `applications`

Frame's docs list both `position` and `size` as required. Leave out `size` and
Frame logs `Invalid application strategy: 'size' is required` and drops the
rule; the window lands on the default output. It looks exactly like "title
matching does not work", and it is easy to waste hours on race-condition
theories. **First thing to check:**

```sh
grep -c 'Invalid application strategy' /var/log/kiosk/frame.log   # must be 0
```

### Window placement: exact title match

Frame's `applications` rules match only `snap-name` or `surface-title`. There
is no `app_id` match. There is no arm64 VS Code snap, so `surface-title` it is.

The match is **exact equality**, and Frame places a window **once, when its
first surface is created**. Later title changes do not move it. So you must
match the title at creation time:

| App     | Title at creation           | How it is kept stable                                         |
|---------|-----------------------------|---------------------------------------------------------------|
| Chrome  | `Untitled - Google Chrome`  | placeholder before the page loads; **depends on locale**      |
| VS Code | `Visual Studio Code`        | pinned via `"window.title"` in the coder's `settings.json`     |

Writing `Google Chrome` does not match. If your system locale is not English,
Chrome's placeholder title differs: find it with the swap test below and set
`CHROME_INITIAL_TITLE` in `kiosk.conf`.

### The swap test: looking at the screen lies

The default output is the left screen `[0, 0]`. "Chrome shows up on the left"
proves nothing, because a broken rule also puts it on the left. An earlier
version of this setup passed three reboots "visually" while the Chrome rule had
never matched once.

To actually verify:

1. Temporarily make the rule point to a non-default position (`[WIDTH, 0]`).
2. Add `--window-management-trace` to the `ubuntu-frame` command in
   `/etc/kiosk/frame-host.sh` and restart `kiosk-frame`.
3. Read the actual placements:

```sh
sudo grep -E 'place_new_window' /var/log/kiosk/frame.log | python3 -c "
import sys,re
for line in sys.stdin.buffer:
    nm=re.search(rb'name=([^,}]*)',line)
    arrow=re.split(rb' -> ',line)
    if nm and len(arrow)>1:
        tl=re.search(rb'top_left=([-0-9]+, *[-0-9]+)',arrow[1])
        print(repr(nm.group(1)), '-> top_left=', tl.group(1).decode() if tl else '?')
"
```

The `name=` column also tells you the exact creation-time title for your
locale. Remove `--window-management-trace` afterwards; it grows the log fast.

Acceptance after any config change:

- `grep -c 'Invalid application strategy' /var/log/kiosk/frame.log` is 0
- Frame log says `Display config using layout: 'default'`
- both windows' actual coordinates match the config, and at least one is non-default
- the window does not jump screens when its title changes

### Trap 4: `display-layout` selector does not work, so the whole config is swapped

Frame supports several named layouts selected with
`snap set ubuntu-frame display-layout=<name>`. On this build the selector does
nothing: `snap get` echoes the new name, but Frame keeps logging
`Display config using layout: 'default'`, every rule is ignored, and both apps
land on the same screen.

So there are two complete files, **both naming their layout `default`**:

```
/etc/kiosk/layouts/chrome-left.yaml    Chrome -> left,  VS Code -> right
/etc/kiosk/layouts/chrome-right.yaml   Chrome -> right, VS Code -> left
```

and `kiosk-side-picker.sh` writes one of them with
`snap set ubuntu-frame display="$(cat ...)"` on every boot.

The picker is transactional: it validates the YAML, applies it, and only after
`snap set` succeeds does it advance the counter and record `last-layout`. A
manual override is consumed last. `flock` stops a manual run racing the boot
run. Force the next boot's layout with:

```sh
echo chrome_left | sudo tee /var/lib/kiosk-side/next-layout     # or chrome_right
```

### Self-healing

`BindsTo=` only says "if Frame stops, stop the clients". It does not bring
them back after `Restart=always` restarts Frame. `Upholds=` (systemd >= 249)
in `kiosk-frame.service` does. Tested: `kill -9` of the Frame process, Frame
comes back with a new PID, both clients come back, placement is still right.

`wait-for-wayland.py` runs as `ExecStartPre` and does a real `connect()` on the
socket instead of only checking that the file exists.

### Health check: what it does and does not cover

`kiosk-health-check.timer` runs every 15 minutes and logs problems at `err`
priority (`journalctl -p err -u kiosk-health-check`). It checks:

- Chrome runs as `leetcode` and VS Code runs as `coder`. It matches the real
  binary `/opt/google/chrome/chrome`, not the `google-chrome-stable` wrapper
  script.
- Both accounts can really `connect()` to the Wayland socket.
- The layout Frame holds equals the one the picker recorded (no drift).

It does **not** verify which screen a window is on. If Chrome's placeholder
title changes after an upgrade, Chrome silently falls back to the left screen
and the check still says ok. **After every Chrome major upgrade, run the swap
test again.**

## Single-screen mode (Cage)

One monitor, one app per boot, alternating: boot 1 = LeetCode, boot 2 =
VS Code, and so on. `kiosk-mode-picker.sh` keeps a counter in
`/var/lib/kiosk-mode/` and starts `kiosk-leetcode` or `kiosk-vscode`, each a
full-screen Cage session on tty1. The two units `Conflicts=` each other.

Force the next mode with:

```sh
echo vscode | sudo tee /var/lib/kiosk-mode/next-mode     # or leetcode
```

## Chrome lockdown

`/etc/opt/chrome/policies/managed/kiosk.json`:

- `URLBlocklist: ["*"]` + `URLAllowlist` = only LeetCode (and Cloudflare's
  bot challenge) is reachable.
- **`"*"` does not cover `chrome://` pages.** Checked: before hardening,
  `chrome://settings`, `downloads`, `extensions` and `flags` all rendered. The
  dangerous internal pages are now listed one by one. `chrome://*` is not blocked
  wholesale because Chrome warns that this can break the browser.
- **Kiosk mode hides the address bar but not the keyboard shortcuts.**
  `Ctrl+H` (history) and `Ctrl+J` (downloads) still navigate, and from the
  history page you could click your way out of the allowlist. With the
  policy they now land on `ERR_BLOCKED_BY_ADMINISTRATOR`. This was verified
  with a real keyboard: tests over DevTools/CDP only prove the policy rule,
  not that the real entry point is closed. Include shortcuts, context menus,
  drag-and-drop and `window.open` in your threat model.
- Downloads, file pickers, printing, guest/add-person, password manager,
  autofill, translate, extensions, DevTools and incognito are all disabled.

## Logs

The client units run inside PAM sessions, where the journal does not reliably
capture their stderr, so dual mode logs to files:

```
/var/log/kiosk/frame.log  leetcode.log  vscode.log
```

`/var/log/kiosk` must be `root:root 0755`. If it is world-writable, logrotate
refuses with `skipping ... because parent directory has insecure permissions`.
"Config syntax is valid" does not mean "it rotates": check with
`sudo logrotate -d /etc/logrotate.d/kiosk` and look for `skipping`.
`/etc/tmpfiles.d/kiosk.conf` pre-creates each log with its service's owner
(`0640`). The services only append (`>>`), so they never need write access
to the directory.

## Operations

- **Emergency exit:** add `kiosk=off` to the single line in
  `/boot/firmware/cmdline.txt` (from SSH, or by putting the SD/NVMe in another
  machine) and reboot. Every kiosk unit has `ConditionKernelCommandLine=!kiosk=off`.
- **Stop the kiosk before testing Frame/Cage by hand.** DRM master is exclusive;
  a second compositor fails with `Failed to acquire DRM master`. **Start the
  kiosk again afterwards.**
- **Never debug with the real Chrome profile.** Use a separate `--user-data-dir`.
  A `pkill -9` in the middle of a SQLite write can make Chrome treat the
  profile as corrupt and wipe it, and you lose your LeetCode login.
- **`systemctl mask` does not work on unit files that live in
  `/etc/systemd/system/`** (`File already exists`). To make a unit impossible to
  start by accident, move the file out of the unit search path. `install.sh`
  deletes the unused mode's units for this reason.
- dpkg can be left half-configured if a package's postinst fails during
  `apt-get install`. Fix with `sudo dpkg --configure -a`, then check that
  `sudo dpkg --audit` prints nothing.
- Thermals: with both screens running, the Pi 5 (active cooler) stays around
  50 °C with `vcgencmd get_throttled` = `0x0`.
