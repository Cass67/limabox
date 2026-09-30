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
| Stop / start / reset | `limactl stop default` / `limactl start default` / `limactl delete -f default && ./install.sh` |

## What you get

- Fedora on VZ + virtiofs, Rosetta for x86 binaries, dev toolchain, zsh, uv, opencode-v2, Brave,
  Tabby (tabs on the left), gnome-terminal, foot.
- **Seamless home**: shells get `HOME=/Users/<you>`, so all zsh dotfiles, aliases, `~/.ssh` and
  git config just work. Linux-only data (XDG data/state/cache, cargo, go, pip) goes to `~/.linux`.
  Mac-only `PATH` entries (Homebrew, `~/.cargo/bin`, `~/.local/bin`, …) are dropped after your
  dotfiles load, since those are macOS binaries.
- Optional per-user setup: `~/.linux/limabox/init.sh` runs as the VM user on each install, after
  zsh wrappers are regenerated. Keep machine-specific tools, aliases and proxy settings there
  instead of in this repo.
- GUI apps keep the Linux home (`$LINUX_HOME`) so their own settings live there.
- **git / ssh**: your Mac ssh-agent (Keychain keys included) is forwarded into Fedora, and shells keep
  a stable `~/.ssh-agent.sock` link so GUI terminals get it too. For HTTPS, Linux shells override
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
- `lx <app>` (Mac): makes sure Cocoa-Way runs, then starts the app with `systemd-run --user` in the
  current directory, so it gets the persistent display and the Linux home and outlives the call.
- Cocoa-Way runs under launchd (`local.fedora-lima.cocoa-way`, KeepAlive): started at login and
  restarted within seconds if it quits, is killed or crashes, so Linux apps started from inside
  the VM always have a compositor (windows open at that moment close with it). Stop it for real
  with `launchctl bootout gui/$(id -u)/local.fedora-lima.cocoa-way`.
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
- `ssh` in Fedora reads your Mac `~/.ssh/config`: add `IgnoreUnknown UseKeychain` if you use it.
- Caps Lock can desync between Mac and Linux windows; press it twice.
