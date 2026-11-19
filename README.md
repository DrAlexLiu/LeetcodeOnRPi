# LeetcodeOnRPi

Turn a Raspberry Pi 5 into a quiet, single-purpose machine for coding practice.

Switch it on and you get LeetCode on one screen and VS Code with **your own
practice repository** on the other. There is no desktop, no other websites, no
notifications and no app switching. You just practise.

```
 ┌──────────────────────────┐  ┌──────────────────────────┐
 │  Chrome (kiosk)          │  │  VS Code                 │
 │  leetcode.com only       │  │  ~/study (your repo)     │
 │  no address bar, no tabs │  │  git push your solutions │
 └──────────────────────────┘  └──────────────────────────┘
        HDMI 0                         HDMI 1
          (the two sides swap on every boot)
```

## Why

- **Focus.** The browser can only reach LeetCode. There is nothing else to click.
- **Silent and cheap.** A Pi 5 with an active cooler is quiet, uses a few
  watts, and can stay on your desk all the time.
- **Your work stays yours.** Solutions live in a git repository you own.
  Commit from the kiosk and review them anywhere.
- **Hard to break.** Each app runs as its own unprivileged account, services
  restart themselves, and there is an emergency exit through the boot command line.

## Two modes

| Mode     | Monitors | What happens                                                                 |
|----------|----------|------------------------------------------------------------------------------|
| `dual`   | 2        | LeetCode and VS Code side by side; they swap sides every boot (Ubuntu Frame) |
| `single` | 1        | Full-screen LeetCode on one boot, full-screen VS Code on the next            |

Single mode runs on Cage by default. Set `COMPOSITOR=frame` to run it on
Ubuntu Frame instead (GPU-accelerated Mir, the same compositor as dual mode).

## What you need

- Raspberry Pi 5 (4 GB works, 8 GB recommended), active cooler, official 27 W PSU
- microSD or (better) NVMe SSD
- 1 or 2 HDMI monitors (micro-HDMI cables), keyboard, mouse
- **Raspberry Pi OS Lite (64-bit), Debian 13 "trixie"**, with SSH enabled and an
  admin account you can SSH into. A Desktop image also works; the installer
  disables the desktop session.

Also tested: **Radxa Dragon Q6A** (Qualcomm QCS6490, one HDMI port) on
Ubuntu 24.04 with `MODE=single`, `COMPOSITOR=frame`. See
[docs/LESSONS.md](docs/LESSONS.md#single-screen-mode-with-ubuntu-frame-radxa-dragon-q6a).

## Install

On the Pi, over SSH:

```sh
git clone https://github.com/DrAlexLiu/LeetcodeOnRPi.git
cd LeetcodeOnRPi
cp kiosk.conf.example kiosk.conf
nano kiosk.conf          # choose MODE, set STUDY_REPO_URL to YOUR repo, git name/email
sudo ./install.sh
sudo reboot
```

### Connect your practice repository

1. Create an (ideally private) repository for your solutions on GitHub, e.g.
   `my-leetcode`. An empty one is fine.
2. Put its **SSH** URL in `kiosk.conf`:
   `STUDY_REPO_URL=git@github.com:<you>/my-leetcode.git`
3. `install.sh` (or later `sudo ./scripts/setup-study-repo.sh`) generates a key
   for the `coder` account and prints its public key.
4. Add the key to **that repository only**: *Settings → Deploy keys → Add deploy
   key*. Tick *Allow write access* so you can push. Then press Enter.

A deploy key only grants access to one repository, so the kiosk never holds
credentials for the rest of your account. If you leave `STUDY_REPO_URL` empty,
VS Code opens a fresh local git repository at `STUDY_DIR`, and you can connect
a remote later.

### Log in to LeetCode

On first boot, sign in to LeetCode in the kiosk browser once. The session is
kept in the `leetcode` account's Chrome profile.

## Daily use

- Turn it on. Solve on the LeetCode side, write and run code in VS Code,
  then `git commit` and `git push` from VS Code's Source Control panel.
- Turn it off. Power off over SSH (`sudo poweroff`), or just cut the power if
  you don't mind the risk.

## Maintenance (over SSH)

| Task                               | Command                                                                  |
|------------------------------------|--------------------------------------------------------------------------|
| Status                             | `systemctl status 'kiosk-*'`                                             |
| Health problems                    | `journalctl -p err -u kiosk-health-check`                                |
| Logs (dual, single on Frame)       | `sudo tail -f /var/log/kiosk/{frame,leetcode,vscode}.log`                |
| Restart everything (dual)          | `sudo systemctl restart kiosk-frame`                                     |
| Restart everything (single, Frame) | `sudo systemctl restart "kiosk-frame@$(cat /var/lib/kiosk-mode/last-mode)"` |
| Force sides next boot (dual)       | `echo chrome_right \| sudo tee /var/lib/kiosk-side/next-layout`          |
| Force app next boot (single)       | `echo vscode \| sudo tee /var/lib/kiosk-mode/next-mode`                  |
| Change settings                    | edit `kiosk.conf`, `sudo ./install.sh`, reboot                           |
| Install a VS Code extension        | `sudo -H -u coder code --install-extension ms-python.python`             |
| Update packages from VS Code       | `sudo kiosk-update` (only with `CODER_ADMIN=yes`)                        |
| Emergency: boot without the kiosk  | append ` kiosk=off` to the kernel command line, reboot (`install.sh` prints where it lives) |
| Remove                             | `sudo ./uninstall.sh` (add `--purge-users` to delete the accounts)       |

## How it works

| Account    | Runs           | Privileges                       |
|------------|----------------|----------------------------------|
| your admin | SSH            | sudo; never on screen            |
| `frame`    | Ubuntu Frame   | none (`nologin`, only when Frame is used) |
| `leetcode` | Chrome kiosk   | none                             |
| `coder`    | VS Code        | none (deliberately *not* in `docker`); with `CODER_ADMIN=yes`, network settings and `sudo kiosk-update` only |

- **Dual mode:** one Ubuntu Frame compositor drives both HDMI ports. Chrome and
  VS Code connect to it as equal clients from their own accounts, and are pinned
  to a screen by exact window title. A boot-time picker swaps the layout.
- **Single mode:** a picker alternates between two full-screen Cage sessions,
  or with `COMPOSITOR=frame` starts `kiosk-frame@leetcode` or
  `kiosk-frame@vscode`: Frame as `frame`, upholding the one client of this boot.
- **Chrome policy** blocks every URL except the allowlist, along with the
  dangerous `chrome://` pages, downloads, file dialogs, DevTools, extensions,
  incognito and guest mode. For that allowlist to mean "only LeetCode", no other
  browser may be installed: `REMOVE_OTHER_BROWSERS=yes` (the default) removes
  and holds them and points coder's default browser at the locked Chrome.
- **`CODER_BLOCK_SSH=yes`** (optional) stops the coder account ssh-ing out to
  other machines, so it cannot reach another host's sshd and log in as the admin
  account here. git still works, over github's 443 endpoint. Change the admin
  account's password from the image default for this to be worth anything.
- **VS Code** has GitHub Copilot turned off by default, because the point is
  to practise. Change it in `/home/coder/.config/Code/User/settings.json`.

The non-obvious parts (ACL masks, `pam_systemd` overriding `XDG_RUNTIME_DIR`,
Frame's exact-title matching, why "it looks right on screen" is not proof)
are written up in **[docs/LESSONS.md](docs/LESSONS.md)**. Read it before you
change anything under `rootfs/`.

## Repository layout

```
install.sh / uninstall.sh       installer (idempotent) and remover
kiosk.conf.example              all settings
scripts/setup-study-repo.sh     deploy key + clone of your practice repo
rootfs/common/                  files for both modes (Chrome policy, PAM, logrotate)
rootfs/dual/                    Ubuntu Frame dual-screen units, picker, health check, layouts
rootfs/single/                  Cage single-screen units and picker
rootfs/single-frame/            Ubuntu Frame single-screen units, picker, display layout
rootfs/coder-admin/             optional (CODER_ADMIN=yes): NetworkManager polkit rule, kiosk-update
rootfs/coder-lockdown/          optional (CODER_BLOCK_SSH=yes): firewall that blocks coder's outbound ssh
coder-home/                     default VS Code settings for the coder account
docs/LESSONS.md                 design notes and troubleshooting
```

Files under `rootfs/` are templates: `@PLACEHOLDER@` tokens are filled in from
`kiosk.conf` (and the `frame` account's UID) when they are installed.

## Known limits

- Dual mode assumes two monitors with the same resolution, side by side.
- Chrome is placed by its locale-dependent placeholder title. Re-run the swap
  test in `docs/LESSONS.md` after Chrome major upgrades, or if your system
  language is not English.
- If you edit `rootfs/` files directly on the Pi, the next `install.sh` run
  overwrites them. Edit the repository instead.

## License

MIT
