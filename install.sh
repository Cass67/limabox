#!/bin/bash
# shellcheck disable=SC2016  # single-quoted scripts are meant to expand inside the VM, not here
# Distrobox-style Fedora on macOS: Lima VM + Cocoa-Way (rootless) for Linux GUI apps.
#   ./install.sh                        # instance "default" (so plain `lima` works)
#   NAME=dev ./install.sh               # other instance name
# Safe to re-run: existing VM is started, not recreated.
set -euo pipefail

NAME=${NAME:-default}
LX_DIR=${LX_DIR:-$HOME/.local/bin}
TEXT_SCALE=${TEXT_SCALE:-1.25}
APPS_DIR=${APPS_DIR:-$HOME/Applications/Linux}

step() { printf '\n==> %s\n' "$*"; }

command -v brew >/dev/null || {
  echo "Homebrew is required: https://brew.sh" >&2
  exit 1
}
[[ $(uname -m) == arm64 ]] || echo "warning: tested on Apple Silicon only" >&2

step "Installing lima, cocoa-way, waypipe"
brew install lima j-x-z/tap/cocoa-way j-x-z/tap/waypipe-darwin pulseaudio switchaudio-osx

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cfg=$tmp/fedora.yaml
cat >"$cfg" <<'EOF'
base:
  - template:fedora

vmType: vz
mountType: virtiofs
cpus: 6
memory: 8GiB
disk: 100GiB

mounts:
  - location: "~"
    writable: true

vmOpts:
  vz:
    rosetta:
      enabled: true
      binfmt: true

ssh:
  forwardX11: true
  forwardX11Trusted: true
  forwardAgent: true # Mac ssh-agent (Keychain keys) inside the VM; keys never leave the Mac

provision:
  - mode: system
    script: |
      #!/bin/bash
      set -eux
      curl -fsSLo /etc/yum.repos.d/brave-browser.repo \
        https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo
      dnf install -y \
        zsh git curl wget unzip which vim neovim htop tree xauth \
        waypipe foot gnome-terminal nautilus dconf brave-browser ripgrep librsvg2-tools uv gh \
        @development-tools gcc-c++ cmake ninja-build clang llvm \
        python3-devel nodejs golang rust cargo java-25-openjdk-devel
      usermod -s /bin/zsh "{{.User}}"
      # Tabby (terminal with side tabs): latest GitHub release, re-checked every boot.
      t=$(curl -fsSL https://api.github.com/repos/Eugeny/tabby/releases/latest \
        | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p')
      case $(uname -m) in aarch64) ta=arm64 ;; *) ta=x64 ;; esac
      if [ -n "$t" ] && ! rpm -q "tabby-terminal-$t" >/dev/null 2>&1; then
        dnf install -y "https://github.com/Eugeny/tabby/releases/download/v$t/tabby-$t-linux-$ta.rpm"
      fi
      # Chromium/Electron apps need Wayland explicitly; Cocoa-Way rootless has no Xwayland.
      for app in brave-browser tabby; do
        printf '#!/bin/sh\nexec /usr/bin/%s --ozone-platform=wayland "$@"\n' "$app" > "/usr/local/bin/$app"
        chmod 755 "/usr/local/bin/$app"
      done
      # opencode-v2: latest release from its Homebrew tap, re-checked every boot.
      v=$(curl -fsSL https://raw.githubusercontent.com/anomalyco/homebrew-tap/HEAD/opencode-v2.rb \
        | sed -n 's/^  version "\(.*\)"/\1/p')
      case $(uname -m) in aarch64) a=arm64 ;; *) a=x64-baseline ;; esac
      if [ -n "$v" ] && ! /usr/local/bin/opencode --version 2>/dev/null | grep -qF "$v"; then
        curl -fsSL "https://opencode.ai/files/bin/$v/opencode-linux-$a.tar.gz" \
          | tar -xz -C /usr/local/bin opencode
      fi
  - mode: user
    script: |
      #!/bin/bash
      mac=/Users/{{.User}}
      # .config/opencode is providers + AGENTS.md; auth and sessions stay per-OS.
      for f in .zshrc .gitconfig .vimrc .config/nvim .config/opencode; do
        [ -e "$mac/$f" ] && mkdir -p "$(dirname "$HOME/$f")" && ln -sfn "$mac/$f" "$HOME/$f"
      done
      mkdir -p ~/.config/foot
      [ -e ~/.config/foot/foot.ini ] || printf '[main]\nfont=monospace:size=14\n' > ~/.config/foot/foot.ini
      mkdir -p ~/.config/tabby
      [ -e ~/.config/tabby/config.yaml ] || printf 'version: 8\nappearance:\n  tabsLocation: left\n' > ~/.config/tabby/config.yaml
      true
EOF

if limactl list -q 2>/dev/null | grep -qx "$NAME"; then
  step "VM '$NAME' exists, keeping it (delete with: limactl delete -f $NAME)"
else
  step "Creating VM '$NAME' (Fedora, first boot installs packages: ~5 min)"
  limactl create --tty=false --name "$NAME" "$cfg"
  created=1
fi

if [[ $(limactl list --format '{{.Status}}' "$NAME") != Running ]]; then
  step "Starting VM '$NAME'"
  limactl start "$NAME"
fi

if ! grep -q 'forwardAgent: true' ~/.lima/"$NAME"/lima.yaml; then
  step "Enabling SSH agent forwarding for VM '$NAME' (one-time restart)"
  limactl stop "$NAME"
  limactl edit --tty=false --set '.ssh.forwardAgent = true' "$NAME"
  limactl start "$NAME"
fi

if ! limactl shell "$NAME" grep -qx 'ID=fedora' /etc/os-release; then
  echo "error: existing VM '$NAME' is not Fedora (e.g. Lima's default Ubuntu)." >&2
  echo "  keep it:    NAME=fedora $0" >&2
  echo "  replace it: limactl delete -f $NAME && $0" >&2
  exit 1
fi

# Apple M4-class CPUs expose SME (streaming SVE) but not SVE. Chromium-based renderers (Brave) treat
# SME as SVE, execute SVE outside streaming mode and die with SIGILL in a crash loop (slow browsing,
# systemd-coredump eating CPU). Hiding SME from the guest sends everything down the NEON paths.
if limactl shell "$NAME" sh -c 'f=$(grep -m1 ^Features /proc/cpuinfo); case " $f " in *" sme "*) case " $f " in *" sve "*) exit 1 ;; esac; exit 0 ;; esac; exit 1' &&
  ! limactl shell "$NAME" grep -qw arm64.nosme /proc/cmdline; then
  step "Hiding SME from the VM (arm64.nosme; fixes Brave SIGILL crashes) and restarting it"
  limactl shell "$NAME" sudo grubby --update-kernel=ALL --args=arm64.nosme
  limactl stop "$NAME" && limactl start "$NAME"
fi

# Provisioning switches the login shell to zsh after Lima's SSH master and the systemd --user
# session have started, so both keep SHELL=/bin/bash until restarted.
if ! limactl shell "$NAME" sh -c 'systemctl --user show-environment | grep -qx SHELL=/bin/zsh'; then
  step "Restarting the VM user session so zsh is the default shell"
  limactl shell "$NAME" sudo systemctl restart "user@$(id -u).service"
  ssh -F ~/.lima/"$NAME"/ssh.config -O exit "lima-$NAME" 2>/dev/null || true
fi

step "Making the Mac home the shell \$HOME (distrobox-style)"
limactl shell "$NAME" sudo tee /etc/profile.d/mac-home.sh >/dev/null <<'EOF'
# Distrobox-style: shells get the Mac home (same path, mounted) as $HOME, so dotfiles, aliases,
# ~/.ssh and ~/.gitconfig just work. Linux-only data goes to ~/.linux so it never mixes with macOS.
if [ -d "/Users/$USER" ] && [ "$HOME" != "/Users/$USER" ]; then
  _lh=$HOME
  export LINUX_HOME=$_lh HOME=/Users/$USER
  export XDG_DATA_HOME=$HOME/.linux/share XDG_STATE_HOME=$HOME/.linux/state
  export XDG_CACHE_HOME=$HOME/.linux/cache
  export CARGO_HOME=$HOME/.linux/cargo RUSTUP_HOME=$HOME/.linux/rustup GOPATH=$HOME/.linux/go
  export PYTHONUSERBASE=$HOME/.linux/local
  export PATH=$HOME/.linux/bin:$PYTHONUSERBASE/bin:$CARGO_HOME/bin:$GOPATH/bin:$PATH
  # zsh reads the Mac dotfiles through wrappers in $LINUX_HOME/.zdot (see /etc/zsh-mac-path).
  [ -n "$ZSH_VERSION" ] && export ZDOTDIR=$_lh/.zdot
  [ "$PWD" = "$_lh" ] && cd "$HOME"
  unset _lh
fi
export BROWSER=/usr/local/bin/xdg-open # opens on the Mac, see lx --agent
export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-limabox} # persistent display, see lx --display
export PULSE_SERVER=${PULSE_SERVER:-unix:/tmp/limabox-pulse.sock} # sound plays on the Mac, see lx --sound
export PULSE_LATENCY_MSEC=${PULSE_LATENCY_MSEC:-60} # bigger buffers: no gaps over the tunnel

# The forwarded Mac ssh-agent socket changes per ssh session; keep a stable link so shells started
# later (GUI terminals, which aren't ssh sessions) find it too.
_as=${LINUX_HOME:-$HOME}/.ssh-agent.sock
if [ -S "$SSH_AUTH_SOCK" ] && [ "$SSH_AUTH_SOCK" != "$_as" ]; then ln -sfn "$SSH_AUTH_SOCK" "$_as"; fi
[ -S "$_as" ] && export SSH_AUTH_SOCK=$_as
unset _as

# git over HTTPS: the Mac ~/.gitconfig often names credential.helper osxkeychain, which Linux lacks.
# Override it for Linux shells only (env config wins over files): gh for github.com, a memory cache
# elsewhere. gh keeps its own login under ~/.linux, apart from the Mac's gh.
export GH_CONFIG_DIR=/Users/$USER/.linux/config/gh
export GIT_CONFIG_COUNT=4 \
  GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= \
  GIT_CONFIG_KEY_1=credential.helper GIT_CONFIG_VALUE_1='cache --timeout=28800' \
  GIT_CONFIG_KEY_2=credential.https://github.com.helper GIT_CONFIG_VALUE_2= \
  GIT_CONFIG_KEY_3=credential.https://github.com.helper GIT_CONFIG_VALUE_3='!/usr/bin/gh auth git-credential'
EOF
# /etc/zshenv runs for every zsh (before ~/.zshenv), so zsh picks it up before reading any dotfile.
limactl shell "$NAME" sudo sh -c \
  'grep -q mac-home.sh /etc/zshenv 2>/dev/null || echo ". /etc/profile.d/mac-home.sh" >> /etc/zshenv'
limactl shell "$NAME" sudo tee /etc/zsh-mac-path >/dev/null <<'EOF'
# Sourced after each Mac zsh dotfile: drop Mac-only PATH entries, whose binaries are macOS builds
# that cannot run here. ~/bin (usually scripts) and ~/.linux (Linux tools) stay.
() {
  local d; local -a keep
  for d in $path; do
    case $d in
      $HOME/bin|$HOME/.linux/*) keep+=$d ;;
      $HOME/*|/opt/homebrew/*|/Applications/*|/Library/*|/System/*|/var/run/com.apple*) ;;
      *) keep+=$d ;;
    esac
  done
  typeset -gU path
  path=($keep)
}
EOF
# limactl shell itself runs via zsh, so $HOME is already the Mac home here; use LINUX_HOME.
limactl shell "$NAME" sh -c 'z=${LINUX_HOME:-$HOME}/.zdot; mkdir -p $z && for f in .zshenv .zprofile .zshrc .zlogin; do
  { [ $f = .zshrc ] && echo "HISTFILE=\$HOME/.zsh_history"
    echo "[[ -r \$HOME/$f ]] && source \$HOME/$f"; echo "source /etc/zsh-mac-path"; } > $z/$f
done'

# One-time move of CLI data written before shells switched homes (e.g. opencode auth + sessions).
limactl shell "$NAME" sh -c 'o=$LINUX_HOME/.local/share/opencode n=$HOME/.linux/share/opencode
  [ -n "$LINUX_HOME" ] && [ -d "$o" ] && [ ! -e "$n" ] && mkdir -p "${n%/*}" && mv "$o" "$n"; true'

# Extra packages + setup script: declarative, re-applied on every run (distrobox --additional-packages
# and --init-hooks). Both live on the Mac, so a rebuilt VM gets them back.
cfgdir=$HOME/.config/limabox
mkdir -p "$cfgdir"
[[ -e $cfgdir/packages ]] || cat >"$cfgdir/packages" <<'EOF'
# Extra Fedora packages, one per line (# comments ok). Installed on every ./install.sh run.
EOF
# Record the packages the VM came with plus everything this installer installs, so lx --save-config
# can report what was added by hand. Captured before the packages list is applied.
known=/etc/limabox/known-packages
if [[ -n ${created:-} ]] || ! limactl shell "$NAME" test -f $known; then
  [[ -n ${created:-} ]] || echo "  note: package tracking starts now; anything dnf-installed by hand before this counts as" \
    "known. Review once with: limactl shell $NAME dnf repoquery --userinstalled"
  limactl shell "$NAME" sudo sh -c "mkdir -p /etc/limabox && dnf repoquery --userinstalled -q --qf '%{name}\n' >$known"
fi
{
  awk '/dnf install -y \\/{f=1;next} f{print; if ($0 !~ /\\$/) exit}' "$cfg" | tr -d '\134' | xargs -n1
  printf '%s\n' librsvg2-tools libdnf5-plugin-actions uv gh tabby-terminal
} | limactl shell "$NAME" sudo sh -c "cat - $known | sort -u >$known.new && mv $known.new $known"

read -r -a pkgs <<<"$(sed 's/#.*//' "$cfgdir/packages" | xargs)"
if ((${#pkgs[@]})); then
  step "Installing packages from $cfgdir/packages: ${pkgs[*]}"
  limactl shell "$NAME" sudo dnf install -y -q "${pkgs[@]}"
fi
if [[ -f $cfgdir/init.sh ]]; then
  step "Running $cfgdir/init.sh in the VM as root"
  limactl shell "$NAME" sudo bash "$cfgdir/init.sh"
fi
# Per-user setup, run as you after the shell wrappers are regenerated. ~/.linux/limabox/init.sh is
# the older location; lx --save-config moves it here.
uinit=$cfgdir/user-init.sh
[[ -f $uinit ]] || uinit=$HOME/.linux/limabox/init.sh
if [[ -f $uinit ]]; then
  step "Running $uinit in the VM as you"
  limactl shell "$NAME" bash "$uinit"
fi

step "Setting Linux text scale to $TEXT_SCALE"
limactl shell "$NAME" gsettings set org.gnome.desktop.interface text-scaling-factor "$TEXT_SCALE"

# A rebuilt VM gets back the Linux app settings saved by lx --save-config.
if [[ -n ${created:-} && -d $cfgdir/linux-home ]]; then
  step "Restoring Linux app settings from $cfgdir/linux-home"
  # dconf load rejects a whole file if any key is read-only (e.g. org/gnome/login-screen), so load
  # each [section] on its own and skip the ones that refuse.
  limactl shell "$NAME" sh -c 'lh=${LINUX_HOME:-$HOME}; cp -R "$1"/. "$lh"/ && rm -f "$lh/dconf.ini"
    [ -f "$1/dconf.ini" ] || exit 0
    t=$(mktemp -d); awk -v t="$t" "BEGIN{RS=\"\"} {print > (t \"/\" NR)}" "$1/dconf.ini"
    for s in "$t"/*; do
      p=$(head -1 "$s" | tr -d "[]"); [ "$p" = / ] && p= || p=/$p
      { echo "[/]"; tail -n +2 "$s"; } | dconf load "$p/" 2>/dev/null || echo "  skipped read-only dconf section $p"
    done; rm -rf "$t"' _ "$cfgdir/linux-home"
fi

step "Bookmarking the Mac home in Files (GUI apps start in the Linux home)"
limactl shell "$NAME" sh -c 'b=${LINUX_HOME:-$HOME}/.config/gtk-3.0/bookmarks; mkdir -p ${b%/*}
  grep -qs "^file://$HOME " $b || echo "file://$HOME Mac" >>$b'

step "Installing lx-apps (GUI app scanner) and dnf hook in the VM"
stampdir=$HOME/.cache/fedora-lima # under ~ so the VM can write it
mkdir -p "$stampdir"
limactl shell "$NAME" sudo dnf install -y -q librsvg2-tools libdnf5-plugin-actions uv gh nautilus >/dev/null
limactl shell "$NAME" sudo tee /usr/local/bin/lx-apps >/dev/null <<'EOF'
#!/bin/bash
# lx-apps OUTDIR: print GUI apps as id<TAB>name<TAB>command; write each icon to OUTDIR/<id>.png.
out=$1; mkdir -p "$out"
skip=" footclient foot-server ${LX_SKIP:-} "
for f in /usr/share/applications/*.desktop /var/lib/flatpak/exports/share/applications/*.desktop; do
  [ -f "$f" ] || continue
  id=$(basename "$f" .desktop)
  case $skip in *" $id "*) continue ;; esac
  case $id in java-*) continue ;; esac   # AWT is X11-only; Cocoa-Way rootless has no Xwayland
  g=$(sed -n '/^\[Desktop Entry\]/,/^\[/p' "$f")
  get() { printf '%s\n' "$g" | sed -n "s/^$1=//p" | head -1; }
  [ "$(get Type)" = Application ] || continue
  printf '%s\n' "$g" | grep -qiE '^(NoDisplay|Hidden|Terminal)=true|^OnlyShowIn=' && continue
  if [ -x "/usr/local/bin/$id" ]; then
    cmd=/usr/local/bin/$id
  else
    cmd=$(get Exec | sed -E 's/ ?%[a-zA-Z]//g')
    bin=$(command -v "${cmd%% *}") || continue
    dir=$(dirname "$(readlink -f "$bin")")
    # Chromium/Electron apps pick X11 unless told otherwise.
    if [ -e "$dir/resources.pak" ] || [ -e "$dir/chrome_crashpad_handler" ]; then
      cmd="$cmd --ozone-platform=wayland"
    fi
  fi
  i=$(get Icon) src=
  if [ "${i#/}" != "$i" ]; then
    src=$i
  else
    for s in /usr/share/icons/hicolor/scalable/apps/$i.svg \
             /var/lib/flatpak/exports/share/icons/hicolor/scalable/apps/$i.svg; do
      [ -f "$s" ] && src=$s && break
    done
    [ -n "$src" ] || src=$(ls /usr/share/icons/hicolor/*/apps/"$i".png \
      /var/lib/flatpak/exports/share/icons/hicolor/*/apps/"$i".png \
      /usr/share/pixmaps/"$i".png 2>/dev/null | sort -V | tail -1)
  fi
  case $src in
    *.svg) rsvg-convert -w 512 -h 512 "$src" -o "$out/$id.png" ;;
    ?*) cp "$src" "$out/$id.png" ;;
  esac
  printf '%s\t%s\t%s\n' "$id" "$(get Name)" "$cmd"
done
EOF
limactl shell "$NAME" sudo chmod 755 /usr/local/bin/lx-apps
# Every dnf transaction rewrites the stamp; a launchd agent on the Mac watches it and runs lx --sync.
# No .desktop file filter: dnf5 lacks filelists for not-yet-installed packages, so fresh installs
# would never match. It must be a content write: launchd's WatchPaths ignores a bare touch.
printf '#!/bin/sh\ndate > %s\n' "$stampdir/$NAME.stamp" |
  limactl shell "$NAME" sudo tee /usr/local/bin/lx-stamp >/dev/null
limactl shell "$NAME" sudo chmod 755 /usr/local/bin/lx-stamp
echo "post_transaction::::/usr/local/bin/lx-stamp" |
  limactl shell "$NAME" sudo tee /etc/dnf/libdnf5-plugins/actions.d/fedora-lima.actions >/dev/null

step "Routing xdg-open/open in the VM to macOS open"
queue=$stampdir/open-$NAME
mkdir -p "$queue"
sed "s|@Q@|$queue|" <<'EOF' | limactl shell "$NAME" sudo tee /usr/local/bin/xdg-open >/dev/null
#!/bin/sh
# limabox: xdg-open/open hand URLs and files to macOS `open`. Each request is a file in a queue dir
# (under the shared Mac home) that the Mac-side agent (lx --agent) validates and opens.
q=@Q@
[ $# -gt 0 ] || { echo "usage: ${0##*/} <url|file>..." >&2; exit 1; }
for a; do
  case $a in
    *://* | mailto:*) t=$a ;;
    *) t=$(realpath -e -- "$a" 2>/dev/null) || { echo "${0##*/}: $a: no such file" >&2; exit 1; } ;;
  esac
  case $t in
    /Users/* | *://* | mailto:*) ;;
    *) echo "${0##*/}: $t is inside the VM; macOS only sees files under /Users" >&2; exit 1 ;;
  esac
  printf '%s\n' "$t" >"$q/.tmp.$$" && mv "$q/.tmp.$$" "$q/req.$$.$(date +%s%N)"
done
EOF
limactl shell "$NAME" sudo sh -c 'chmod 755 /usr/local/bin/xdg-open && ln -sfn xdg-open /usr/local/bin/open'
# GUI apps that ask GIO for the default browser (instead of calling xdg-open) get it too.
limactl shell "$NAME" sudo tee /usr/local/share/applications/limabox-mac-open.desktop >/dev/null <<'EOF'
[Desktop Entry]
Type=Application
Name=Open on Mac
Exec=/usr/local/bin/xdg-open %u
NoDisplay=true
MimeType=x-scheme-handler/http;x-scheme-handler/https;x-scheme-handler/mailto;
EOF
limactl shell "$NAME" sh -c 'BROWSER= HOME=${LINUX_HOME:-$HOME} XDG_CONFIG_HOME= xdg-settings set default-web-browser limabox-mac-open.desktop'

step "Installing lx to $LX_DIR"
mkdir -p "$LX_DIR"
sed -e "s|@NAME@|$NAME|g" -e "s|@APPS@|$APPS_DIR|g" -e "s|@LX@|$LX_DIR/lx|g" \
  -e "s|@BREW@|$(brew --prefix)/bin|g" >"$LX_DIR/lx" <<'EOF'
#!/bin/zsh
# lx <app> [args]: run a Linux GUI app from the Lima VM as native macOS windows (Cocoa-Way rootless).
# lx --sync:       (re)build the Mac launchers in @APPS@ from the VM's installed GUI apps.
# lx --bin <cmd> [name]: add a Mac command that runs <cmd> in the VM; lx --unbin <name> removes it.
# lx --agent:      run by the LaunchAgent: open queued xdg-open requests, re-sync after dnf.
# lx --display:    run by a LaunchAgent: keep the VM's Wayland display connected to Cocoa-Way.
# lx --sound:      run by a LaunchAgent: Mac PulseAudio server for the VM, following the Mac output.
# lx --save-config: snapshot Linux app settings into ~/.config/limabox and list packages added by
#                  hand, so ~/.config/limabox alone is enough to rebuild the VM (commit it somewhere).
[[ $# -gt 0 ]] || { echo "usage: lx <app> [args] | --sync | --bin <cmd> [name] | --unbin <name> | --save-config" >&2; exit 1; }

if [[ $1 == --bin ]]; then
  [[ -n $2 ]] || { echo "usage: lx --bin <cmd> [name]" >&2; exit 1; }
  f=${0:A:h}/${3:-$2}
  # The marker must be line 2: lx itself contains the marker text inside this template.
  if [[ -e $f ]] && [[ $(sed -n 2p $f) != "# limabox-bin:"* ]]; then
    echo "lx --bin: $f exists and is not a limabox wrapper" >&2; exit 1
  fi
  cat >$f <<BIN
#!/bin/sh
# limabox-bin: runs '$2' in the Fedora VM '@NAME@' (in the current directory)
if [ "\$(uname -s)" = Linux ]; then # this dir can be on PATH inside the VM too: run the real one
  me=\$(dirname "\$0") IFS=:
  for d in \$PATH; do [ "\$d" != "\$me" ] && [ -x "\$d/$2" ] && exec "\$d/$2" "\$@"; done
  echo "$2: not found" >&2; exit 127
fi
exec @BREW@/limactl shell @NAME@ ${(q)2} "\$@"
BIN
  chmod 755 $f; echo "added ${f/#$HOME/~}"; exit 0
fi

if [[ $1 == --unbin ]]; then
  f=${0:A:h}/$2
  [[ -f $f && $(sed -n 2p $f) == "# limabox-bin:"* ]] || { echo "lx --unbin: $f is not a limabox wrapper" >&2; exit 1; }
  rm $f; echo "removed ${f/#$HOME/~}"; exit 0
fi

if [[ $1 == --save-config ]]; then
  c=$HOME/.config/limabox
  mkdir -p $c/linux-home
  if [[ -f $HOME/.linux/limabox/init.sh && ! -e $c/user-init.sh ]]; then
    mv $HOME/.linux/limabox/init.sh $c/user-init.sh && echo "moved ~/.linux/limabox/init.sh -> ${c/#$HOME/~}/user-init.sh"
  fi
  # Settings files only (no app data such as browser profiles), relative to the Linux home.
  limactl shell @NAME@ sh -c 'lh=${LINUX_HOME:-$HOME} d=$1
    for f in .config/tabby/config.yaml .config/foot/foot.ini .config/gtk-3.0/bookmarks .config/mimeapps.list; do
      [ -f "$lh/$f" ] && mkdir -p "$d/${f%/*}" && cp "$lh/$f" "$d/$f"
    done
    HOME=$lh dconf dump / >"$d/dconf.ini"' _ $c/linux-home
  echo "saved Linux app settings to ${c/#$HOME/~}/linux-home"
  extra=$(limactl shell @NAME@ sh -c 'dnf repoquery --userinstalled -q --qf "%{name}\n" | sort -u |
    comm -23 - /etc/limabox/known-packages' | grep -vxF -f <(sed 's/#.*//;s/[[:space:]]//g;/^$/d' $c/packages))
  if [[ -n $extra ]]; then
    print "installed by hand but not in ${c/#$HOME/~}/packages (add the ones to keep):"
    print -l -- "  "${(f)^extra}
  else
    print "every hand-installed package is in ${c/#$HOME/~}/packages"
  fi
  print "commit ${c/#$HOME/~} (no secrets in it) to rebuild with: ./install.sh"
  exit 0
fi

if [[ $1 == --agent ]]; then
  q=$HOME/.cache/fedora-lima/open-@NAME@ stamp=$HOME/.cache/fedora-lima/@NAME@.stamp
  # Events arriving mid-run are dropped by launchd, so loop until there is nothing left to do.
  while :; do
    busy=
    for req in $q/req.*(N); do
      busy=1; t=$(<$req); rm -f $req
      case $t in
        http://* | https://* | mailto:*) open $t ;;
        # Only existing files under this home, and never app bundles or scripts macOS would run.
        $HOME/*)
          if [[ -e $t && $t != *.(app|command|tool|terminal|workflow|pkg|mpkg)(|/*) ]]; then open $t
          else echo "refused: $t"; fi ;;
        *) echo "refused: $t" ;;
      esac
    done
    if [[ $(cat $stamp 2>/dev/null) != $(cat $stamp.synced 2>/dev/null) ]]; then
      busy=1; cp $stamp $stamp.synced; @LX@ --sync
    fi
    [[ -n $busy ]] || break
  done
  exit 0
fi

if [[ $1 == --sync ]]; then
  apps=@APPS@ icons=$HOME/.cache/fedora-lima/icons-@NAME@
  stamp=$HOME/.cache/fedora-lima/@NAME@.stamp
  # launchd drops WatchPaths events that land mid-run, so repeat until the stamp holds still.
  while :; do
    before=$(cat $stamp 2>/dev/null)
    typeset -A keep; keep=()
    rm -rf $icons; mkdir -p $apps
    list=$(limactl shell @NAME@ lx-apps $icons) || { echo "lx --sync: VM @NAME@ not reachable" >&2; exit 1; }
    for line in ${(f)list}; do
      IFS=$'\t' read -r id name cmd <<<$line
      app="$apps/${name//\//-} (Linux).app"; keep[$app]=1
      launch="#!/bin/zsh
export PATH=@BREW@:\$PATH
cd ~
exec @LX@ sh -c ${(qq)cmd}"
      [[ -f $app/Contents/MacOS/launch && $(<$app/Contents/MacOS/launch) == $launch ]] && continue
      rm -rf $app; mkdir -p $app/Contents/{MacOS,Resources}
      print -r -- $launch >$app/Contents/MacOS/launch; chmod 755 $app/Contents/MacOS/launch
      [[ -f $icons/$id.png ]] && sips -z 512 512 -s format icns $icons/$id.png \
        --out $app/Contents/Resources/icon.icns >/dev/null
      cat >$app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>${name//&/&amp;} (Linux)</string>
  <key>CFBundleIdentifier</key><string>local.fedora-lima.@NAME@.${id//[^A-Za-z0-9.-]/-}</string>
  <key>CFBundleExecutable</key><string>launch</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
      echo "  + ${app:t:r}"
    done
    for app in $apps/*" (Linux).app"(N); do
      [[ -n ${keep[$app]} ]] && continue
      grep -q "local.fedora-lima.@NAME@." $app/Contents/Info.plist 2>/dev/null \
        && rm -rf $app && echo "  - ${app:t:r}"
    done
    rm -rf $icons
    [[ $(cat $stamp 2>/dev/null) == $before ]] && break
  done
  exit 0
fi

cw=$(getconf DARWIN_USER_TEMP_DIR)cocoa-way
cocoa() { # launchd keeps Cocoa-Way running (local.fedora-lima.cocoa-way); nudge it if it's between restarts
  pgrep -qx cocoa-way && [[ -S $cw/wayland-1 ]] && return
  launchctl kickstart gui/$UID/local.fedora-lima.cocoa-way 2>/dev/null
  for _ in {1..40}; do pgrep -qx cocoa-way && [[ -S $cw/wayland-1 ]] && break; sleep 0.25; done
}

# Run by a LaunchAgent: one persistent display for the whole VM. waypipe client (Mac, talks to
# Cocoa-Way) <- ssh -R unix socket <- `waypipe server` in the VM (limabox-waypipe.service), which
# owns $XDG_RUNTIME_DIR/wayland-limabox. Per-launch `waypipe ssh` can't do this: its display
# socket disappears when the launched command exits, so helpers such as gnome-terminal's
# Preferences (a separate process) had nowhere to connect.
if [[ $1 == --display ]]; then
  sock=$HOME/.cache/fedora-lima/waypipe-@NAME@.sock
  cocoa
  rm -f $sock
  XDG_RUNTIME_DIR=$cw WAYLAND_DISPLAY=wayland-1 waypipe --socket $sock client &
  trap "kill $! 2>/dev/null" EXIT
  while :; do # reconnect whenever the VM restarts
    ssh -F ~/.lima/@NAME@/ssh.config -o ControlMaster=no -o ControlPath=none \
      -o ExitOnForwardFailure=yes -o ServerAliveInterval=10 -o ConnectTimeout=5 \
      -N -R /tmp/limabox-waypipe.sock:$sock -R /tmp/limabox-pulse.sock:$HOME/.cache/fedora-lima/pulse-@NAME@.sock lima-@NAME@
    sleep 5
  done
fi

# Run by a LaunchAgent: sound. An output-only PulseAudio server on the Mac (CoreAudio, no microphone)
# listening on a unix socket that lx --display tunnels into the VM as /tmp/limabox-pulse.sock, where
# PULSE_SERVER points every app. Follows the macOS output device and moves playing streams along.
if [[ $1 == --sound ]]; then
  d=$HOME/.cache/fedora-lima p=$d/pulse-@NAME@
  mkdir -p $p
  rm -f $p.sock
  print -l "load-module module-coreaudio-detect record=false playback=true" \
    "load-module module-native-protocol-unix socket=$p.sock auth-anonymous=1" \
    "load-module module-always-sink" >$p.pa
  export PULSE_RUNTIME_PATH=$p PULSE_STATE_PATH=$p PULSE_SERVER=unix:$p.sock
  pulseaudio -n -F $p.pa --exit-idle-time=-1 --daemonize=no --log-level=error &
  pa=$!
  trap "kill $pa 2>/dev/null" EXIT
  last=
  while kill -0 $pa 2>/dev/null; do
    out=$(SwitchAudioSource -c -t output 2>/dev/null)
    if [[ -n $out && $out != "$last" ]]; then
      sink=$(pactl list sinks 2>/dev/null | awk -v want="$out" \
        '/^\tName: /{n=$2} /^\tDescription: /{sub(/^\tDescription: /,""); if ($0 == want) {print n; exit}}')
      if [[ -n $sink ]] && pactl set-default-sink $sink 2>/dev/null; then
        for i in ${(f)"$(pactl list short sink-inputs 2>/dev/null | cut -f1)"}; do pactl move-sink-input $i $sink; done
        last=$out
      fi
    fi
    sleep 3
  done
  exit 1
fi

# GUI apps start under the VM's systemd --user manager: they get the persistent display and the
# Linux home (their settings live there), in the current directory, and outlive this command.
cocoa
exec limactl shell @NAME@ systemd-run --user --collect --quiet --same-dir -- "$@"
EOF
chmod 755 "$LX_DIR/lx"
[[ ":$PATH:" == *":$LX_DIR:"* ]] || echo "note: add $LX_DIR to PATH in ~/.zshrc"

step "Setting up the persistent Linux display (wayland-limabox)"
# sshd must replace the tunnel's socket when the Mac reconnects after a VM restart.
echo "StreamLocalBindUnlink yes" |
  limactl shell "$NAME" sudo tee /etc/ssh/sshd_config.d/60-limabox.conf >/dev/null
limactl shell "$NAME" sudo systemctl reload sshd
limactl shell "$NAME" sh -c 'd=${LINUX_HOME:-$HOME}/.config; mkdir -p $d/systemd/user $d/environment.d
  printf "WAYLAND_DISPLAY=wayland-limabox\nELECTRON_OZONE_PLATFORM_HINT=wayland\nPULSE_SERVER=unix:/tmp/limabox-pulse.sock\nPULSE_LATENCY_MSEC=60\n" > $d/environment.d/limabox.conf
  u=$d/systemd/user/limabox-waypipe.service
  cat > $u.new <<UNIT
[Unit]
Description=limabox: persistent Wayland display forwarded to Cocoa-Way on the Mac

[Service]
# A crash or unclean stop leaves the socket behind and waypipe refuses to bind over it.
ExecStartPre=/usr/bin/rm -f %t/wayland-limabox
ExecStart=/usr/bin/waypipe --socket /tmp/limabox-waypipe.sock --display wayland-limabox server -- sleep infinity
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
UNIT
  # A running server keeps its old flags until restarted, and server and client must agree (e.g. on
  # compression) or every app fails with "no compositor".
  changed=; cmp -s $u.new $u || changed=1; mv $u.new $u
  systemctl --user daemon-reload
  systemctl --user set-environment WAYLAND_DISPLAY=wayland-limabox ELECTRON_OZONE_PLATFORM_HINT=wayland \
    PULSE_SERVER=unix:/tmp/limabox-pulse.sock PULSE_LATENCY_MSEC=60 # Brave asks for ~20 ms, which gaps
  systemctl --user enable --now limabox-waypipe.service >/dev/null 2>&1
  [ -z "$changed" ] || systemctl --user restart limabox-waypipe.service
  pkill -f '\''[g]nome-terminal-server'\''; true' # restarts on next use with the new display
agent_plist() {                                   # label, lx mode, extra plist keys
  cat >"$HOME/Library/LaunchAgents/$1.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$1</string>
  <key>ProgramArguments</key><array><string>$LX_DIR/lx</string><string>$2</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$(brew --prefix)/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  $3
  <key>StandardOutPath</key><string>$stampdir/${2#--}-$NAME.log</string>
  <key>StandardErrorPath</key><string>$stampdir/${2#--}-$NAME.log</string>
</dict></plist>
PLIST
  launchctl bootout "gui/$(id -u)/$1" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$1.plist"
}
mkdir -p ~/Library/LaunchAgents
# Cocoa-Way 2.0.3 never balances NSCursor hide/unhide, so once a client hides the cursor (YouTube
# does on every idle period) the Mac cursor stays hidden until a click. Build the pinned upstream
# commit with patches/cocoa-way-cursor-hide-balance.patch until the fix is released.
cw_rev=e1ff9b9b333a826ba507fb8d8010f4c6ce2d4b93
cw_patch=$(cd "$(dirname "$0")" && pwd)/patches/cocoa-way-cursor-hide-balance.patch
cw_bin=$HOME/.local/share/limabox/cocoa-way
cw_stamp="$cw_rev $(shasum -a 256 "$cw_patch" | cut -c1-16)"
if [[ ! -x $cw_bin || $(cat "$cw_bin.rev" 2>/dev/null) != "$cw_stamp" ]]; then
  step "Building Cocoa-Way with the cursor fix (a few minutes, once)"
  command -v cargo >/dev/null || brew install rust
  git clone -q --filter=blob:none https://github.com/J-x-Z/cocoa-way.git "$tmp/cocoa-way"
  git -C "$tmp/cocoa-way" checkout -q "$cw_rev"
  git -C "$tmp/cocoa-way" apply "$cw_patch"
  (cd "$tmp/cocoa-way" && cargo build --release --locked --quiet --bin cocoa-way)
  mkdir -p "${cw_bin%/*}"
  # Replace via rename, never in place: macOS caches a binary's code signature per file and
  # kills a rewritten one at launch (OS_REASON_CODESIGNING).
  cp "$tmp/cocoa-way/target/release/cocoa-way" "$cw_bin.new"
  mv -f "$cw_bin.new" "$cw_bin"
  echo "$cw_stamp" >"$cw_bin.rev"
  launchctl kill TERM "gui/$(id -u)/local.fedora-lima.cocoa-way" 2>/dev/null || true # KeepAlive restarts it
fi
# Cocoa-Way itself runs under launchd: started at login and restarted if it quits or crashes, so a
# Linux app started from inside the VM always has a compositor. Only one instance may own the
# display socket, so any copy started outside launchd is stopped first.
cocoa_label=local.fedora-lima.cocoa-way
cat >"$HOME/Library/LaunchAgents/$cocoa_label.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$cocoa_label</string>
  <key>ProgramArguments</key><array><string>$cw_bin</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>COCOA_WAY_PRESENTATION</key><string>rootless</string>
    <key>TMPDIR</key><string>$(getconf DARWIN_USER_TEMP_DIR)</string>
  </dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <!-- Without this launchd treats the agent as background and macOS coalesces its 4-16 ms frame
       timers to ~80 ms: Linux apps were capped at 12.5 fps (YouTube 50% dropped). Now ~30 fps. -->
  <key>ProcessType</key><string>Interactive</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>$stampdir/cocoa-way.log</string>
  <key>StandardErrorPath</key><string>$stampdir/cocoa-way.log</string>
</dict></plist>
PLIST
# (Re)load when not loaded or pointing at another binary; any copy outside launchd is stopped first.
if ! launchctl print "gui/$(id -u)/$cocoa_label" 2>/dev/null | grep -qx "[[:space:]]*program = $cw_bin" ||
  ! cmp -s "$HOME/Library/LaunchAgents/$cocoa_label.plist" "$stampdir/cocoa-way.plist.loaded"; then
  launchctl bootout "gui/$(id -u)/$cocoa_label" 2>/dev/null || true
  pkill -x cocoa-way || true
  launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$cocoa_label.plist"
  cp "$HOME/Library/LaunchAgents/$cocoa_label.plist" "$stampdir/cocoa-way.plist.loaded"
fi
agent_plist "local.fedora-lima.display.$NAME" --display \
  '<key>ProcessType</key><string>Interactive</string><key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>10</integer>'

step "Making ssh/git in Fedora use your Mac ssh setup and keys"
# ssh reads the passwd home ($LINUX_HOME), not $HOME: point it at the Mac config and known_hosts.
limactl shell "$NAME" sh -c 'c=${LINUX_HOME:-$HOME}/.ssh/config; mkdir -p -m 700 ${c%/*}; touch $c
  grep -q "^# limabox:" $c || { printf "%s\n" "# limabox: use the Mac ~/.ssh (ssh reads the Linux home, not \$HOME)" \
    "IgnoreUnknown UseKeychain" "UserKnownHostsFile $HOME/.ssh/known_hosts ~/.ssh/known_hosts" \
    "Include $HOME/.ssh/config" "" | cat - $c >$c.new && mv $c.new $c; }; chmod 600 $c'
# The macOS agent (forwarded into the VM) starts empty; load the Keychain-stored keys at login.
keys_label=local.fedora-lima.ssh-keys
cat >"$HOME/Library/LaunchAgents/$keys_label.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$keys_label</string>
  <key>ProgramArguments</key><array><string>/usr/bin/ssh-add</string><string>--apple-load-keychain</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST
launchctl bootout "gui/$(id -u)/$keys_label" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$keys_label.plist"
/usr/bin/ssh-add --apple-load-keychain 2>/dev/null || true
if ! /usr/bin/ssh-add -l >/dev/null 2>&1 && [[ -t 0 ]]; then
  echo "  ssh-agent is empty: adding your default keys to it and the Keychain (passphrase asked once)"
  /usr/bin/ssh-add --apple-use-keychain || true
fi

agent_plist "local.fedora-lima.sound.$NAME" --sound \
  '<key>ProcessType</key><string>Interactive</string><key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>10</integer>'

step "Creating Mac launchers in $APPS_DIR"
"$LX_DIR/lx" --sync

step "Installing login agent (opens xdg-open requests, re-syncs launchers after dnf)"
touch "$stampdir/$NAME.stamp"
agent_plist "local.fedora-lima.sync.$NAME" --agent "<key>WatchPaths</key><array><string>$stampdir/$NAME.stamp</string><string>$queue</string></array>
  <key>ThrottleInterval</key><integer>1</integer>"

step "Checking"
limactl shell "$NAME" sh -c 'echo "  home: $HOME  shell: $(getent passwd $USER | cut -d: -f7)"; for c in zsh gcc waypipe brave-browser tabby opencode; do printf "  %-14s %s\n" $c "$(command -v $c || echo MISSING)"; done'

cat <<EOF

Done.
  Shell:      $([[ $NAME == default ]] && echo lima || echo "limactl shell $NAME")   (opens in your current Mac directory)
  Home:       shells use your Mac home and dotfiles; Linux-only data goes to ~/.linux
  GUI apps:   Launchpad/Finder: $APPS_DIR (drag to the Dock; kept in sync after dnf install/remove)
              or from a Mac terminal: lx tabby | lx gnome-terminal | lx nautilus | lx brave-browser | lx foot
  Resync:     lx --sync   (e.g. after flatpak installs, which bypass dnf)
  Cocoa-Way:  kept running by launchd (quitting it restarts it); to turn it off:
              launchctl bootout gui/\$(id -u)/local.fedora-lima.cocoa-way
  Open:       'open <url|file>' or xdg-open in Fedora opens it on the Mac
  Commands:   lx --bin <cmd>  adds a Mac command that runs the Fedora one (lx --unbin <cmd>)
  Extras:     $cfgdir/packages (+ optional init.sh) are applied on every run
  git/ssh:    Fedora uses your Mac ssh config, known_hosts and Keychain keys (loaded at login);
              for HTTPS to GitHub run 'gh auth login'
              once inside Fedora (other HTTPS hosts prompt once, then are cached for 8h)
  opencode:   config + MCPs shared with the Mac; logins are per-machine: in Fedora run
              'opencode auth login' per provider and 'opencode mcp auth <name>' per OAuth MCP
  Packages:   $([[ $NAME == default ]] && echo lima || echo "limactl shell $NAME") sudo dnf install -y <pkg>
  Text size:  TEXT_SCALE=1.5 $0

Your Mac ~/.zshrc is also the VM's. Wrap Mac-only lines (brew shellenv, Mac paths) in:
  if [[ \$(uname) == Darwin ]]; then ... fi
EOF
