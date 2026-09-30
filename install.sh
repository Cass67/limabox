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
brew install lima j-x-z/tap/cocoa-way j-x-z/tap/waypipe-darwin

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
        waypipe foot gnome-terminal dconf brave-browser ripgrep librsvg2-tools uv gh \
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

# Optional per-user setup runs in Fedora after shell wrappers are regenerated on each install.
if [[ -f $HOME/.linux/limabox/init.sh ]]; then
  step "Running per-user VM setup"
  limactl shell "$NAME" bash "$HOME/.linux/limabox/init.sh"
fi

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
read -r -a pkgs <<<"$(sed 's/#.*//' "$cfgdir/packages" | xargs)"
if ((${#pkgs[@]})); then
  step "Installing packages from $cfgdir/packages: ${pkgs[*]}"
  limactl shell "$NAME" sudo dnf install -y -q "${pkgs[@]}"
fi
if [[ -f $cfgdir/init.sh ]]; then
  step "Running $cfgdir/init.sh in the VM as root"
  limactl shell "$NAME" sudo bash "$cfgdir/init.sh"
fi

step "Setting Linux text scale to $TEXT_SCALE"
limactl shell "$NAME" gsettings set org.gnome.desktop.interface text-scaling-factor "$TEXT_SCALE"

step "Installing lx-apps (GUI app scanner) and dnf hook in the VM"
stampdir=$HOME/.cache/fedora-lima # under ~ so the VM can write it
mkdir -p "$stampdir"
limactl shell "$NAME" sudo dnf install -y -q librsvg2-tools libdnf5-plugin-actions uv gh >/dev/null
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
[[ $# -gt 0 ]] || { echo "usage: lx <app> [args] | --sync | --bin <cmd> [name] | --unbin <name>" >&2; exit 1; }

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
export PATH=@BREW@:\$PATH LX_WAIT=1
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

export XDG_RUNTIME_DIR="${TMPDIR%/}/cocoa-way" WAYLAND_DISPLAY=wayland-1
if [[ ! -S $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY ]]; then
  COCOA_WAY_PRESENTATION=rootless cocoa-way >/dev/null 2>&1 &!
  for _ in {1..20}; do [[ -S $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY ]] && break; sleep 0.25; done
fi

# gnome-terminal and other D-Bus-activated apps start via systemd --user, which needs the display.
# GUI apps keep the Linux home (their settings live there); shells they spawn switch to the Mac one.
remote="[ -n \"\$LINUX_HOME\" ] && export HOME=\$LINUX_HOME && unset LINUX_HOME ZDOTDIR XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME; cd ${(q)PWD} 2>/dev/null; systemctl --user import-environment WAYLAND_DISPLAY; export ELECTRON_OZONE_PLATFORM_HINT=wayland; exec ${(j: :)${(q)@}}"
run() {
  waypipe ssh -F ~/.lima/@NAME@/ssh.config lima-@NAME@ "sh -c ${(qq)remote}" 2>&1 \
    | grep -v -e '^warn' -e 'No child processes' -e 'degenerate damage'
}
# .app launchers set LX_WAIT: macOS kills an app's children when it exits, which would drop waypipe.
if [[ -n $LX_WAIT ]]; then run; else run &!; fi
EOF
chmod 755 "$LX_DIR/lx"
[[ ":$PATH:" == *":$LX_DIR:"* ]] || echo "note: add $LX_DIR to PATH in ~/.zshrc"

step "Creating Mac launchers in $APPS_DIR"
"$LX_DIR/lx" --sync

step "Installing login agent (opens xdg-open requests, re-syncs launchers after dnf)"
label=local.fedora-lima.sync.$NAME
agent=$HOME/Library/LaunchAgents/$label.plist
touch "$stampdir/$NAME.stamp"
mkdir -p "${agent%/*}"
cat >"$agent" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$LX_DIR/lx</string><string>--agent</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$(brew --prefix)/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>WatchPaths</key><array><string>$stampdir/$NAME.stamp</string><string>$queue</string></array>
  <key>ThrottleInterval</key><integer>1</integer>
  <key>StandardOutPath</key><string>$stampdir/sync-$NAME.log</string>
  <key>StandardErrorPath</key><string>$stampdir/sync-$NAME.log</string>
</dict></plist>
EOF
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$agent"

step "Checking"
limactl shell "$NAME" sh -c 'echo "  home: $HOME  shell: $(getent passwd $USER | cut -d: -f7)"; for c in zsh gcc waypipe brave-browser tabby opencode; do printf "  %-14s %s\n" $c "$(command -v $c || echo MISSING)"; done'

cat <<EOF

Done.
  Shell:      $([[ $NAME == default ]] && echo lima || echo "limactl shell $NAME")   (opens in your current Mac directory)
  Home:       shells use your Mac home and dotfiles; Linux-only data goes to ~/.linux
  GUI apps:   Launchpad/Finder: $APPS_DIR (drag to the Dock; kept in sync after dnf install/remove)
              or from a Mac terminal: lx tabby | lx gnome-terminal | lx brave-browser | lx foot
  Resync:     lx --sync   (e.g. after flatpak installs, which bypass dnf)
  Open:       'open <url|file>' or xdg-open in Fedora opens it on the Mac
  Commands:   lx --bin <cmd>  adds a Mac command that runs the Fedora one (lx --unbin <cmd>)
  Extras:     $cfgdir/packages (+ optional init.sh) are applied on every run
  git/ssh:    your Mac ssh-agent is forwarded into Fedora; for HTTPS to GitHub run 'gh auth login'
              once inside Fedora (other HTTPS hosts prompt once, then are cached for 8h)
  opencode:   config + MCPs shared with the Mac; logins are per-machine: in Fedora run
              'opencode auth login' per provider and 'opencode mcp auth <name>' per OAuth MCP
  Packages:   $([[ $NAME == default ]] && echo lima || echo "limactl shell $NAME") sudo dnf install -y <pkg>
  Text size:  TEXT_SCALE=1.5 $0

Your Mac ~/.zshrc is also the VM's. Wrap Mac-only lines (brew shellenv, Mac paths) in:
  if [[ \$(uname) == Darwin ]]; then ... fi
EOF
