# limabox

distrobox, but on a Mac: a Fedora VM (Lima) where your Mac home is your Linux home, plus Linux GUI
apps as native macOS windows (Cocoa-Way rootless + waypipe) with Launchpad/Dock launchers that
stay in sync with `dnf`.

## Install

Needs Homebrew on Apple Silicon. Takes ~5 min the first time; safe to re-run (keeps the VM).

```bash
./install.sh
```

| Variable | Default | |
|---|---|---|
| `NAME` | `default` | Lima instance name (`default` makes plain `lima` work) |
| `LX_DIR` | `~/.local/bin` | where `lx` goes; must be on `PATH` |
| `APPS_DIR` | `~/Applications/Linux` | Mac launchers (home Applications, not `/Applications`) |
| `TEXT_SCALE` | `1.25` | Linux GUI text scale |

If a Lima `default` VM already exists and is not Fedora, the installer stops: use
`NAME=fedora ./install.sh` or `limactl delete -f default` first.

## Use

| | |
|---|---|
| Fedora shell (opens in the current Mac dir) | `lima` |
| One command | `lima make`, `lima cargo build` |
| GUI app | click it in `~/Applications/Linux` / Launchpad / Spotlight, or `lx tabby` |
| Install / remove | `lima sudo dnf install -y <pkg>` — launchers appear/vanish on their own |
| Rebuild launchers | `lx --sync` (e.g. after flatpak, which bypasses dnf) |
| Open a URL/file on the Mac, from Fedora | `open .`, `open https://…`, `xdg-open file.pdf` (links clicked in Linux apps too) |
| Use a Fedora command from a Mac terminal | `lx --bin rg` → `rg` on the Mac runs Fedora's; `lx --bin tree ltree` to rename; `lx --unbin rg` |
| Extra packages / setup that survive a rebuild | list them in `~/.config/limabox/packages`, script in `~/.config/limabox/init.sh` (runs as root) |
| Save what a rebuild needs | `lx --save-config` → Linux app settings into `~/.config/limabox/linux-home`, lists hand-installed packages missing from `packages` |
| Stop / start / reset | `limactl stop default` / `limactl start default` / `limactl delete -f default && ./install.sh` |

## What you get

- Fedora on VZ + virtiofs, Rosetta for x86 binaries, sound on the Mac, dev toolchain, zsh, uv, opencode-v2, Brave,
  Tabby (tabs on the left), gnome-terminal, foot, Files (nautilus).
- **Seamless home**: shells get `HOME=/Users/<you>`, so all zsh dotfiles, aliases, `~/.ssh` and
  git config just work. Linux-only data (XDG data/state/cache, cargo, go, pip) goes to `~/.linux`.
  Mac-only `PATH` entries (Homebrew, `~/.cargo/bin`, `~/.local/bin`, …) are dropped after your
  dotfiles load, since those are macOS binaries.
- Optional per-user setup: `~/.linux/limabox/init.sh` runs as the VM user on each install, after
  zsh wrappers are regenerated. Keep machine-specific tools, aliases and proxy settings there
  instead of in this repo.
- GUI apps keep the Linux home (`$LINUX_HOME`) so their own settings live there. That's why
  Files opens on a near-empty home: your Mac home is the **Mac** bookmark in its sidebar (or
  Ctrl+L, `/Users/<you>`).
- **git / ssh**: your Mac ssh-agent is forwarded into Fedora, and shells keep a stable
  `~/.ssh-agent.sock` link so GUI terminals get it too. ssh reads the Linux home, not `$HOME`, so
  the installer puts a `# limabox:` header in `$LINUX_HOME/.ssh/config` that includes the Mac
  `~/.ssh/config` and uses the Mac `known_hosts`. A login agent (`local.fedora-lima.ssh-keys`) runs
  `ssh-add --apple-load-keychain`, since the macOS agent starts empty; if it has no keys, the
  installer adds your default ones to it and the Keychain once. Keys the Mac config names by
  `~/.ssh/...` path must be in the agent (the `~` means the Linux home in Fedora). For HTTPS, Linux shells override
  git's credential helper through `GIT_CONFIG_*` env vars (the shared `~/.gitconfig` is untouched):
  `gh` for github.com (run `gh auth login` once in Fedora; its config lives in `~/.linux/config/gh`)
  and an 8h memory cache for other hosts.
- **Open on the Mac**: `xdg-open`, `open`, `$BROWSER` and Fedora's default browser all hand off to
  macOS `open`. The Mac side only accepts http(s)/mailto URLs and existing files under your home,
  and refuses app bundles and scripts (`.app`, `.command`, `.pkg`, …).
- **Exported commands** (`lx --bin`): tiny wrappers next to `lx` that run the Fedora command in the
  current directory; inside the VM the same wrapper runs the real command instead of itself.
- **Declarative extras**: `~/.config/limabox/packages` and `init.sh` are applied on every
  `./install.sh`. Removing a line doesn't uninstall the package.

## How it works

- `install.sh` embeds the Lima template and writes everything else after boot, so re-running it
  updates an existing VM.
- One persistent Wayland display for the whole VM, `wayland-limabox`: `waypipe server`
  (`limabox-waypipe.service`, systemd --user) ↔ `ssh -R` unix-socket tunnel ↔ `waypipe client` →
  Cocoa-Way (rootless). The Mac side is `lx --display`, kept alive by the LaunchAgent
  `local.fedora-lima.display.<NAME>`, which reconnects after VM restarts. `WAYLAND_DISPLAY` is set
  for systemd and all shells, so any Linux process can open windows: helpers such as
  gnome-terminal's Preferences, and apps started from a Linux shell.
- Cocoa-Way is built by `install.sh` from a pinned upstream commit plus `patches/cocoa-way.patch`
  (into `~/.local/share/limabox/cocoa-way`; needs `cargo`, installed via Homebrew if missing):
  balanced `NSCursor` hide/unhide (a pointer hidden by YouTube no longer stays hidden until a
  click, also after leaving fullscreen or closing a window), and no native title bar for clients
  that draw their own (GTK4 apps such as gnome-terminal and Files would otherwise get two).
  Apps that can use the Mac frame do: foot, Qt/KDE apps, Tabby with `appearance.frame: native`,
  Brave with "Use system title bar and borders".
- Cocoa-Way runs under launchd (`local.fedora-lima.cocoa-way`, KeepAlive): started at login and
  restarted within seconds if it quits, is killed or crashes, so Linux apps started from inside
  the VM always have a compositor (windows open at that moment close with it). Stop it for real
  with `launchctl bootout gui/$(id -u)/local.fedora-lima.cocoa-way`.
- **Sound**: `lx --sound` (LaunchAgent `local.fedora-lima.sound.<NAME>`) runs an output-only
  PulseAudio server on the Mac (CoreAudio, no microphone) on a unix socket that the display tunnel
  carries into the VM as `/tmp/limabox-pulse.sock`. `PULSE_SERVER` points every app there and
  `PULSE_LATENCY_MSEC=60` stops gaps over the tunnel. It follows the macOS output device
  (`SwitchAudioSource`) and moves playing streams when you switch.
- Both display LaunchAgents set `ProcessType=Interactive`. Without it launchd treats them as
  background work and macOS coalesces Cocoa-Way's 4–16 ms frame timers to ~80 ms, capping every
  Linux app at 12.5 fps (YouTube in Linux Brave dropped half its frames; now ~30–40 fps, ~5% drops).
- `lx <app>` (Mac): makes sure Cocoa-Way runs, then starts the app with `systemd-run --user` in the
  current directory, so it gets the persistent display and the Linux home and outlives the call.
- `lx-apps` (VM) lists GUI `.desktop` entries + icons; `lx --sync` turns them into `.app` bundles.
- A dnf5 `actions` hook writes `~/.cache/fedora-lima/<NAME>.stamp` after every transaction; a
  LaunchAgent (`local.fedora-lima.sync.<NAME>`) watches it plus the open queue
  (`~/.cache/fedora-lima/open-<NAME>/`) and runs `lx --agent`, which opens queued requests and
  re-syncs launchers. No Mac ssh server is needed; everything goes through the shared home.
- `/etc/profile.d/mac-home.sh` (sourced from `/etc/zshenv`) switches `HOME`; zsh reads the Mac
  dotfiles through wrappers in `$LINUX_HOME/.zdot` that then apply `/etc/zsh-mac-path`.

## Gotchas

- Chromium/Electron apps need `--ozone-platform=wayland` (there is no Xwayland); known ones get a
  wrapper in `/usr/local/bin`, unknown ones are detected by `lx-apps`. X11-only apps (Java/AWT)
  can't be shown.
- opencode v2 keeps logins in its database, per machine: in Fedora run `opencode auth login` and
  `opencode mcp auth <name>`. MCPs that run `/Applications/...` binaries can't work in Linux;
  ones that talk to Mac apps must use `host.lima.internal`, not `localhost`.
- `~/Documents` (also Desktop/Downloads if macOS asks) is empty in Fedora until the app that
  starts Lima (your terminal, or `limactl`) gets Full Disk Access in System Settings → Privacy &
  Security; restart the VM after. A symlink *into* Documents doesn't help; move the folder out
  and symlink `~/Documents/<dir>` → `~/<dir>` instead.
- Caps Lock can desync between Mac and Linux windows; press it twice.

## Backup and rebuild

The VM is disposable: everything needed to rebuild it lives on the Mac.

- Already on the Mac: projects, dotfiles, `~/.linux` (Linux tool data, opencode/gh logins),
  `~/.config/limabox`.
- Only inside the VM: packages installed by hand, `/etc` tweaks, and the Linux home (GUI app
  settings and data, e.g. a Linux Brave profile).
- `lx --save-config` closes the gap for settings: it copies the Linux apps' config files and a dconf
  dump into `~/.config/limabox/linux-home` (restored automatically when `install.sh` creates a new
  VM) and lists packages you installed by hand that aren't in `~/.config/limabox/packages`.
  User setup goes in `~/.config/limabox/user-init.sh` (runs as you) next to `init.sh` (root).
- So `~/.config/limabox` is the whole recipe: keep it in a private git repo (review
  `linux-home/.config/tabby/config.yaml` for host names first). Rebuild with
  `limactl delete -f default && ./install.sh`, then log in again (`gh auth login`,
  `opencode auth login`).
- Before risky changes, an instant local snapshot: `limactl stop default && cp -c -R
  ~/.lima/default ~/.lima-backup-default && limactl start default`.
