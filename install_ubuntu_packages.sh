#!/usr/bin/env bash
# Setup idempotente do Ubuntu para o perfil descrito em ~/INITIAL_SETUP.md.
# Atualizado em 2026-09-23. Execute como usuário normal, nunca com sudo bash.
set -Eeuo pipefail
IFS=$'\n\t'

trap 'printf "Erro na linha %s. Consulte o log da etapa.\n" "$LINENO" >&2' ERR

DEFAULT_STAGES=(
  apt chrome snaps flatpak whatsapp cedilla shell desktop
  brew brew-tools docker lens vscode claude-code hermes fingerprint
)
VALID_STAGES=(
  "${DEFAULT_STAGES[@]}" codex-app claude-desktop grub
)
MODE=plan
STAGES=()
RESOLUTION=''
CODEX_DEB_URL=''
CLAUDE_DESKTOP_DEB_URL=''
APT_UPDATED=0
REMOTE_SCRIPT_URL='https://raw.githubusercontent.com/srlinuxme/ubuntu-setup/refs/heads/main/install_ubuntu_packages.sh'

usage() {
  cat <<'HELP'
Uso:
  install_ubuntu_packages.sh [--plan | --audit | --apply] [ETAPA ...] [opções]

O padrão é --plan all, sem alterar o sistema.

Etapas padrão de "all":
  apt chrome snaps flatpak whatsapp cedilla shell desktop brew brew-tools
  docker lens vscode claude-code hermes fingerprint

Etapas explícitas:
  codex-app       requer --codex-deb-url URL_OFICIAL
  claude-desktop  requer --claude-desktop-deb-url URL_OFICIAL
  grub             requer --resolution LARGURAxALTURA

Opções:
  --plan
  --audit
  --apply
  --resolution 1920x1080
  --codex-deb-url HTTPS_URL
  --claude-desktop-deb-url HTTPS_URL
  -h, --help

Exemplos:
  bash ~/install_ubuntu_packages.sh --plan all
  bash ~/install_ubuntu_packages.sh --audit
  bash ~/install_ubuntu_packages.sh --apply apt shell desktop fingerprint
  bash ~/install_ubuntu_packages.sh --apply grub --resolution 1920x1080

Logs:
  ~/.local/state/ubuntu-initial-setup/AAAAmmdd-HHMMSS-PID/
HELP
}

is_valid_stage() {
  local wanted=$1 item
  for item in "${VALID_STAGES[@]}"; do
    [[ $item == "$wanted" ]] && return 0
  done
  return 1
}

while (($#)); do
  case "$1" in
    --plan) MODE=plan ;;
    --audit) MODE=audit ;;
    --apply) MODE=apply ;;
    --resolution)
      [[ $# -ge 2 ]] || { printf 'Falta o valor de --resolution.\n' >&2; exit 2; }
      RESOLUTION=$2
      shift
      ;;
    --codex-deb-url)
      [[ $# -ge 2 ]] || { printf 'Falta o valor de --codex-deb-url.\n' >&2; exit 2; }
      CODEX_DEB_URL=$2
      shift
      ;;
    --claude-desktop-deb-url)
      [[ $# -ge 2 ]] || { printf 'Falta o valor de --claude-desktop-deb-url.\n' >&2; exit 2; }
      CLAUDE_DESKTOP_DEB_URL=$2
      shift
      ;;
    all) STAGES+=("${DEFAULT_STAGES[@]}") ;;
    -h|--help) usage; exit 0 ;;
    --*) printf 'Opção desconhecida: %s\n' "$1" >&2; exit 2 ;;
    *)
      is_valid_stage "$1" || { printf 'Etapa desconhecida: %s\n' "$1" >&2; exit 2; }
      STAGES+=("$1")
      ;;
  esac
  shift
done

if [[ $MODE == plan && ${#STAGES[@]} -eq 0 ]]; then
  STAGES=("${DEFAULT_STAGES[@]}")
fi
if [[ $MODE == apply && ${#STAGES[@]} -eq 0 ]]; then
  printf 'Selecione uma etapa ou use "all".\n' >&2
  exit 2
fi

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
else
  printf 'Não foi possível identificar o sistema operacional.\n' >&2
  exit 2
fi
[[ ${ID:-} == ubuntu ]] || { printf 'Este script suporta somente Ubuntu.\n' >&2; exit 2; }
[[ $(dpkg --print-architecture) == amd64 ]] || { printf 'Este script suporta somente Ubuntu amd64.\n' >&2; exit 2; }
[[ $(id -u) -ne 0 ]] || { printf 'Execute como usuário normal, não como root.\n' >&2; exit 2; }

STATE_ROOT="$HOME/.local/state/ubuntu-initial-setup"
CACHE_DIR="$HOME/.cache/ubuntu-initial-setup"
RUN_DIR="$STATE_ROOT/$(date +%Y%m%d-%H%M%S)-$$"
export PATH="$HOME/.local/bin:/home/linuxbrew/.linuxbrew/bin:$PATH"

pkg_installed() {
  [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true) == 'install ok installed' ]]
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

admin() {
  sudo "$@"
}

apt_update_once() {
  local marker="$RUN_DIR/.apt-updated"
  if [[ $APT_UPDATED -eq 0 && ! -e $marker ]]; then
    admin apt-get -o DPkg::Lock::Timeout=120 update
    APT_UPDATED=1
    : >"$marker"
  fi
}

# Força apt-get update após adicionar/alterar um repositório APT.
apt_refresh() {
  admin apt-get -o DPkg::Lock::Timeout=120 update
  APT_UPDATED=1
  : >"$RUN_DIR/.apt-updated"
}

apt_install() {
  local missing=() package
  for package in "$@"; do
    pkg_installed "$package" || missing+=("$package")
  done
  if ((${#missing[@]})); then
    apt_update_once
    admin env DEBIAN_FRONTEND=noninteractive \
      apt-get -o DPkg::Lock::Timeout=120 install -y "${missing[@]}"
  fi
}

download() {
  local url=$1 destination=$2
  [[ $url == https://* ]] || { printf 'Somente URL HTTPS é aceita: %s\n' "$url" >&2; return 2; }
  curl --fail --location --retry 2 --connect-timeout 30 --max-time 1200 \
    "$url" -o "$destination.part"
  mv -f -- "$destination.part" "$destination"
}

backup_file() {
  local path=$1
  [[ -e $path ]] || return 0
  cp -a -- "$path" "$path.before-ubuntu-setup-$(date +%Y%m%d-%H%M%S)-$$"
}

install_deb() {
  local package=$1 url=$2
  local destination="$CACHE_DIR/$package.deb"
  pkg_installed "$package" && return 0
  [[ -n $url ]] || { printf 'URL oficial obrigatória para %s.\n' "$package" >&2; return 3; }
  apt_install curl ca-certificates
  download "$url" "$destination"
  [[ $(dpkg-deb -f "$destination" Package) == "$package" ]] || {
    printf 'O DEB baixado não pertence ao pacote esperado: %s.\n' "$package" >&2
    return 2
  }
  admin env DEBIAN_FRONTEND=noninteractive \
    apt-get -o DPkg::Lock::Timeout=120 install -y "$destination"
}

clone_if_missing() {
  local url=$1 destination=$2
  if [[ -d $destination/.git ]]; then
    return 0
  fi
  [[ ! -e $destination ]] || {
    printf 'Diretório existente não é um repositório Git: %s\n' "$destination" >&2
    return 3
  }
  git clone --depth 1 "$url" "$destination"
}

write_root_file_if_changed() {
  local source=$1 target=$2 mode=$3
  if admin test -e "$target" && admin cmp -s "$source" "$target"; then
    return 0
  fi
  if admin test -e "$target"; then
    admin cp -a "$target" "$target.before-ubuntu-setup-$(date +%Y%m%d-%H%M%S)-$$"
  fi
  admin install -m "$mode" "$source" "$target"
}

stage_apt() {
  apt_install \
    git curl btop vlc vim zsh fonts-firacode build-essential procps file \
    ca-certificates gnupg lsb-release software-properties-common \
    flatpak gnome-software-plugin-flatpak snapd fwupd fprintd libpam-fprintd
}

stage_chrome() {
  install_deb google-chrome-stable \
    https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
}

stage_snaps() {
  apt_install snapd
  local package
  for package in keepassxc vlc telegram-desktop dbeaver-ce; do
    if snap list "$package" >/dev/null 2>&1; then
      continue
    fi
    if [[ $package == dbeaver-ce ]]; then
      admin snap install "$package" --classic
    else
      admin snap install "$package"
    fi
    snap list "$package" >/dev/null
  done
}

stage_flatpak() {
  apt_install flatpak gnome-software-plugin-flatpak
  flatpak --user remote-add --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo
  flatpak --user remotes | awk 'NF {found=1} END {exit !found}'
}

stage_whatsapp() {
  command_exists google-chrome-stable || {
    printf 'Execute a etapa chrome antes de whatsapp.\n' >&2
    return 3
  }
  local target="$HOME/.local/share/applications/whatsapp-web.desktop"
  mkdir -p "$(dirname "$target")"
  local temporary
  temporary=$(mktemp "$CACHE_DIR/whatsapp.XXXXXX")
  cat >"$temporary" <<'DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=WhatsApp
Exec=/usr/bin/google-chrome-stable --app=https://web.whatsapp.com/
Icon=google-chrome
Terminal=false
Categories=Network;InstantMessaging;
StartupNotify=true
DESKTOP
  if [[ ! -e $target ]] || ! cmp -s "$temporary" "$target"; then
    backup_file "$target"
    install -m 0644 "$temporary" "$target"
  fi
  rm -f "$temporary"
}

stage_cedilla() {
  TARGET="$HOME/.XCompose" python3 - <<'PY'
from pathlib import Path
import datetime
import os
import re
import shutil

path = Path(os.environ['TARGET'])
old = path.read_text() if path.exists() else 'include "%L"\n'
old = re.sub(r'^\s*<dead_acute>\s*<[cC]>\s*:.*(?:\n|$)', '', old, flags=re.M)
new = old.rstrip() + '\n\n# US international: acute accent + C produces Portuguese cedilla.\n'
new += '<dead_acute> <c> : "ç" ccedilla\n<dead_acute> <C> : "Ç" Ccedilla\n'
if not path.exists() or path.read_text() != new:
    if path.exists():
        stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
        shutil.copy2(path, f'{path}.before-ubuntu-setup-{stamp}')
    path.write_text(new)
PY
}

stage_shell() {
  apt_install git zsh fonts-firacode
  clone_if_missing https://github.com/ohmyzsh/ohmyzsh.git "$HOME/.oh-my-zsh"
  clone_if_missing https://github.com/spaceship-prompt/spaceship-prompt.git \
    "$HOME/.local/share/zsh/themes/spaceship"
  clone_if_missing https://github.com/zdharma-continuum/zinit.git \
    "$HOME/.local/share/zinit/zinit.git"

  mkdir -p "$HOME/.oh-my-zsh/custom/themes"
  local theme_link="$HOME/.oh-my-zsh/custom/themes/spaceship.zsh-theme"
  if [[ -e $theme_link && ! -L $theme_link ]]; then
    printf 'Revise o arquivo existente antes de substituí-lo: %s\n' "$theme_link" >&2
    return 3
  fi
  ln -sfn "$HOME/.local/share/zsh/themes/spaceship/spaceship.zsh-theme" "$theme_link"

  HOME_DIR="$HOME" python3 - <<'PY'
from pathlib import Path
import datetime
import hashlib
import os
import shutil

home = Path(os.environ['HOME_DIR'])
zshrc = home / '.zshrc'
spaceship = home / '.spaceshiprc.zsh'
start = '# >>> ubuntu-initial-setup managed zsh >>>'
end = '# <<< ubuntu-initial-setup managed zsh <<<'
prompt_start = '# >>> ubuntu-initial-setup managed spaceship >>>'
prompt_end = '# <<< ubuntu-initial-setup managed spaceship <<<'
managed = r'''# >>> ubuntu-initial-setup managed zsh >>>
if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv zsh)"
fi

export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="spaceship"

if [[ "$TERM_PROGRAM" == "vscode" ]]; then
  export XDG_DATA_HOME="$HOME/.local/share"
fi

export ZINIT_HOME="$HOME/.local/share/zinit"
source "$ZINIT_HOME/zinit.git/zinit.zsh"
zinit light marlonrichert/zsh-autocomplete
zinit light zsh-users/zsh-autosuggestions
zinit light zsh-users/zsh-completions

source "$ZSH/oh-my-zsh.sh"

HISTFILE="$HOME/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000
setopt HIST_IGNORE_DUPS HIST_IGNORE_SPACE SHARE_HISTORY
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=#6272a4'

# Carregar o destaque após os demais widgets.
zinit ice wait lucid
zinit light zdharma-continuum/fast-syntax-highlighting
export PATH="$HOME/.local/bin:$PATH"
# <<< ubuntu-initial-setup managed zsh <<<
'''
prompt = '''# >>> ubuntu-initial-setup managed spaceship >>>
SPACESHIP_USER_SHOW=always
SPACESHIP_PROMPT_ADD_NEWLINE=false
SPACESHIP_CHAR_SYMBOL="λ"
SPACESHIP_CHAR_SUFFIX=" "
SPACESHIP_PROMPT_ORDER=(
  user dir host git package node bun elixir erlang rust
  docker docker_compose terraform exec_time line_sep jobs exit_code char
)
# <<< ubuntu-initial-setup managed spaceship <<<
'''

def backup(path):
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    shutil.copy2(path, f'{path}.before-ubuntu-setup-{stamp}')

old = zshrc.read_text() if zshrc.exists() else ''
if start in old and end in old:
    prefix, rest = old.split(start, 1)
    _, suffix = rest.split(end, 1)
    new = prefix.rstrip() + ('\n\n' if prefix.strip() else '') + managed + suffix.lstrip('\n')
elif not old.strip():
    new = managed
else:
    # Migrate only the exact previous Ubuntu profile. Any other unmarked file
    # may contain user aliases/functions and must be merged manually.
    legacy_hash = '3ec5257d127866f7a783cbafc2a22b50974b7a0a0ba9cd243eff69e47888aa64'
    if hashlib.sha256(old.encode()).hexdigest() != legacy_hash:
        raise SystemExit('O .zshrc existente requer merge manual; nenhum conteúdo foi alterado.')
    new = managed
if old != new:
    if zshrc.exists():
        backup(zshrc)
    zshrc.write_text(new)
old_prompt = spaceship.read_text() if spaceship.exists() else ''
if prompt_start in old_prompt and prompt_end in old_prompt:
    prefix, rest = old_prompt.split(prompt_start, 1)
    _, suffix = rest.split(prompt_end, 1)
    new_prompt = prefix.rstrip() + ('\n\n' if prefix.strip() else '') + prompt + suffix.lstrip('\n')
elif not old_prompt.strip():
    new_prompt = prompt
elif 'SPACESHIP_' in old_prompt:
    raise SystemExit('O .spaceshiprc.zsh existente requer merge manual; nenhum conteúdo foi alterado.')
else:
    new_prompt = old_prompt.rstrip() + '\n\n' + prompt
if old_prompt != new_prompt:
    if spaceship.exists():
        backup(spaceship)
    spaceship.write_text(new_prompt)
PY

  local zsh_path
  zsh_path=$(command -v zsh)
  if [[ $(getent passwd "$(id -un)" | cut -d: -f7) != "$zsh_path" ]]; then
    admin chsh -s "$zsh_path" "$(id -un)"
  fi
  zsh -n "$HOME/.zshrc"
}

stage_desktop() {
  apt_install fonts-firacode
  [[ -n ${DBUS_SESSION_BUS_ADDRESS:-} ]] || {
    printf 'Execute a etapa desktop dentro da sessão GNOME do usuário.\n' >&2
    return 3
  }
  local dock=org.gnome.shell.extensions.dash-to-dock
  local ding=org.gnome.shell.extensions.ding
  if command_exists dconf; then
    dconf dump / >"$RUN_DIR/dconf-before-desktop.ini"
  fi
  gsettings set "$dock" dock-position 'BOTTOM'
  gsettings set "$dock" extend-height false
  gsettings set "$dock" autohide true
  gsettings set "$dock" dock-fixed false
  gsettings set "$ding" show-home false
  gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'

  if [[ -d /usr/share/icons/Yaru-purple-dark ]]; then
    gsettings set org.gnome.desktop.interface icon-theme 'Yaru-purple-dark'
  elif [[ -d /usr/share/icons/Yaru-purple ]]; then
    gsettings set org.gnome.desktop.interface icon-theme 'Yaru-purple'
  fi

  python3 - <<'PY'
import ast
import subprocess

def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()

schemas = set(run('gsettings', 'list-schemas').splitlines())
if 'org.gnome.Ptyxis' in schemas:
    subprocess.run(['gsettings', 'set', 'org.gnome.Ptyxis', 'use-system-font', 'false'], check=True)
    subprocess.run(['gsettings', 'set', 'org.gnome.Ptyxis', 'font-name', "'Fira Code 11'"], check=True)
    profile = ast.literal_eval(run('gsettings', 'get', 'org.gnome.Ptyxis', 'default-profile-uuid'))
    if profile:
        schema = f'org.gnome.Ptyxis.Profile:/org/gnome/Ptyxis/Profiles/{profile}/'
        subprocess.run(['gsettings', 'set', schema, 'palette', "'dracula'"], check=True)
elif 'org.gnome.Terminal.ProfilesList' in schemas:
    profile = ast.literal_eval(run('gsettings', 'get', 'org.gnome.Terminal.ProfilesList', 'default'))
    schema = f'org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:{profile}/'
    settings = {
        'use-system-font': 'false',
        'font': "'Fira Code 11'",
        'use-theme-colors': 'false',
        'background-color': "'rgb(40,42,54)'",
        'foreground-color': "'rgb(248,248,242)'",
    }
    for key, value in settings.items():
        subprocess.run(['gsettings', 'set', schema, key, value], check=True)
PY

  [[ $(gsettings get "$dock" dock-position) == "'BOTTOM'" ]]
  [[ $(gsettings get "$ding" show-home) == false ]]
}

stage_brew() {
  if [[ ! -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    apt_install curl git build-essential procps file
    local installer="$CACHE_DIR/homebrew-install.sh"
    download https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh "$installer"
    NONINTERACTIVE=1 bash "$installer"
  fi
  /home/linuxbrew/.linuxbrew/bin/brew --version
}

stage_brew_tools() {
  local brew=/home/linuxbrew/.linuxbrew/bin/brew package
  [[ -x $brew ]] || { printf 'Execute a etapa brew antes de brew-tools.\n' >&2; return 3; }
  for package in oci-cli rclone kubectl helm; do
    if ! "$brew" list --versions "$package" >/dev/null 2>&1; then
      "$brew" install "$package"
    fi
  done
  "$brew" list --versions oci-cli rclone kubectl helm
}

stage_docker() {
  pkg_installed docker-desktop && return 0
  apt_install curl ca-certificates
  admin install -d -m 0755 /etc/apt/keyrings
  local key="$CACHE_DIR/docker.asc"
  download https://download.docker.com/linux/ubuntu/gpg "$key"
  admin install -m 0644 "$key" /etc/apt/keyrings/docker.asc
  local source="$CACHE_DIR/docker.sources"
  cat >"$source" <<EOF_DOCKER
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-${VERSION_CODENAME}}
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF_DOCKER
  write_root_file_if_changed "$source" /etc/apt/sources.list.d/docker.sources 0644
  apt_refresh
  install_deb docker-desktop \
    https://desktop.docker.com/linux/main/amd64/docker-desktop-amd64.deb
}

stage_lens() {
  pkg_installed lens && return 0
  apt_install curl gnupg ca-certificates
  local ascii_key="$CACHE_DIR/lens.asc" binary_key="$CACHE_DIR/lens.gpg"
  download https://downloads.k8slens.dev/keys/gpg "$ascii_key"
  gpg --batch --yes --dearmor -o "$binary_key" "$ascii_key"
  write_root_file_if_changed "$binary_key" /usr/share/keyrings/lens-archive-keyring.gpg 0644
  local source="$CACHE_DIR/lens.list"
  printf '%s\n' 'deb [arch=amd64 signed-by=/usr/share/keyrings/lens-archive-keyring.gpg] https://downloads.k8slens.dev/apt/debian stable main' >"$source"
  write_root_file_if_changed "$source" /etc/apt/sources.list.d/lens.list 0644
  apt_refresh
  apt_install lens
}

stage_vscode() {
  if pkg_installed code; then
    return 0
  fi
  printf 'code code/add-microsoft-repo boolean true\n' | admin debconf-set-selections
  install_deb code https://update.code.visualstudio.com/latest/linux-deb-x64/stable
}

stage_codex_app() {
  [[ -n $CODEX_DEB_URL ]] || {
    printf 'Forneça --codex-deb-url com a URL oficial atual.\n' >&2
    return 3
  }
  install_deb chatgpt "$CODEX_DEB_URL"
}

stage_claude_code() {
  if command_exists claude; then
    claude --version
    return 0
  fi
  apt_install curl ca-certificates
  local installer="$CACHE_DIR/claude-install.sh"
  download https://claude.ai/install.sh "$installer"
  bash "$installer" stable
  "$HOME/.local/bin/claude" --version
}

stage_claude_desktop() {
  [[ -n $CLAUDE_DESKTOP_DEB_URL ]] || {
    printf 'Forneça --claude-desktop-deb-url com a URL oficial atual.\n' >&2
    return 3
  }
  install_deb claude-desktop "$CLAUDE_DESKTOP_DEB_URL"
}

stage_hermes() {
  local installer="$CACHE_DIR/hermes-install.sh"
  local desktop="$HOME/.hermes/hermes-agent/apps/desktop/release/linux-unpacked/Hermes"
  if ! command_exists hermes || [[ ! -x $desktop ]]; then
    apt_install curl git build-essential ca-certificates
    download https://hermes-agent.nousresearch.com/install.sh "$installer"
    if ! command_exists hermes; then
      bash "$installer" --include-desktop --skip-setup --non-interactive
    elif [[ ! -x $desktop ]]; then
      bash "$installer" --stage desktop --skip-setup --non-interactive
      bash "$installer" --stage complete --skip-setup --non-interactive
    fi
  else
    hermes update --check
  fi
  hermes --version
}

stage_grub() {
  [[ $RESOLUTION =~ ^[1-9][0-9]{2,4}x[1-9][0-9]{2,4}$ ]] || {
    printf 'A etapa grub requer --resolution LARGURAxALTURA.\n' >&2
    return 2
  }
  [[ -f /etc/default/grub ]] || { printf '/etc/default/grub não existe.\n' >&2; return 3; }
  local output="$CACHE_DIR/grub.new"
  RESOLUTION_VALUE="$RESOLUTION" OUTPUT_FILE="$output" python3 - <<'PY'
from pathlib import Path
import ast
import os
import re

path = Path('/etc/default/grub')
text = path.read_text()
resolution = os.environ['RESOLUTION_VALUE']
for key in ('GRUB_CMDLINE_LINUX_DEFAULT', 'GRUB_CMDLINE_LINUX'):
    matches = re.findall(r'^' + key + r'=(.*)$', text, re.M)
    raw = matches[-1].strip() if matches else '""'
    if '$' in raw or '`' in raw:
        raise SystemExit(f'{key} contém expansão; revise manualmente.')
    value = ast.literal_eval(raw)
    args = [arg for arg in value.split() if arg not in ('quiet', 'splash')]
    if key == 'GRUB_CMDLINE_LINUX' and 'text' not in args:
        args.append('text')
    replacement = key + '="' + ' '.join(args).replace('"', '\\"') + '"'
    if re.search(r'^' + key + r'=.*$', text, re.M):
        text = re.sub(r'^' + key + r'=.*$', replacement, text, flags=re.M)
    else:
        text += '\n' + replacement + '\n'
for key, value in (('GRUB_GFXMODE', resolution), ('GRUB_GFXPAYLOAD_LINUX', 'keep')):
    replacement = f'{key}={value}'
    if re.search(r'^' + key + r'=.*$', text, re.M):
        text = re.sub(r'^' + key + r'=.*$', replacement, text, flags=re.M)
    else:
        text += '\n' + replacement + '\n'
Path(os.environ['OUTPUT_FILE']).write_text(text)
PY
  if ! cmp -s "$output" /etc/default/grub; then
    admin cp -a /etc/default/grub "/etc/default/grub.before-ubuntu-setup-$(date +%Y%m%d-%H%M%S)-$$"
    admin install -m 0644 "$output" /etc/default/grub
    admin update-grub
  fi
}

stage_fingerprint() {
  apt_install fprintd libpam-fprintd fwupd
  if ! fprintd-list "$USER" 2>/dev/null | grep -q -- '-finger'; then
    [[ -w /dev/tty ]] || {
      printf 'Cadastro de digital requer um terminal interativo.\n' >&2
      return 3
    }
    printf 'Nenhuma digital cadastrada. Cadastre o indicador esquerdo.\n'
    fprintd-enroll -f left-index-finger "$USER" 2>&1 | tee /dev/tty
    fprintd-verify -f left-index-finger "$USER" 2>&1 | tee /dev/tty
  fi

  local policy_script="$CACHE_DIR/configure-fingerprint-sudo.py"
  cat >"$policy_script" <<'PY'
from pathlib import Path
import datetime
import os
import re
import shutil
import subprocess
import sys

user = sys.argv[1]
if not re.fullmatch(r'[a-z_][a-z0-9_-]*', user):
    raise SystemExit('Nome de usuário inválido.')
stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
pam = Path('/etc/pam.d/sudo')
sudoers = Path('/etc/sudoers.d') / f'90-{user}'
if not pam.exists():
    raise SystemExit('/etc/pam.d/sudo não existe.')

def backup(path):
    if path.exists():
        shutil.copy2(path, path.with_name(path.name + f'.before-ubuntu-setup-{stamp}'))

pam_text = pam.read_text()
desired = 'auth sufficient pam_fprintd.so max-tries=3 timeout=10'
managed_line = 'auth       sufficient   pam_fprintd.so max-tries=3 timeout=10'
marker = '# Fingerprint for sudo; common-auth remains password fallback'
lines = pam_text.splitlines()
anchors = [i for i, value in enumerate(lines) if value.strip() == '@include common-auth']
if not anchors:
    raise SystemExit('Não foi encontrado @include common-auth em /etc/pam.d/sudo.')
active_fprint = [
    (i, value) for i, value in enumerate(lines)
    if 'pam_fprintd.so' in value and not value.lstrip().startswith('#')
]
for _, value in active_fprint:
    if ' '.join(value.split()) != desired:
        raise SystemExit('Configuração pam_fprintd existente é incompatível; revise manualmente.')
# Remove only the compatible managed entry and marker, then place one canonical
# entry directly before common-auth. Comments/blanks elsewhere are preserved.
filtered = [
    value for value in lines
    if ' '.join(value.split()) != desired and value.strip() != marker
]
anchor_index = next(i for i, value in enumerate(filtered) if value.strip() == '@include common-auth')
filtered[anchor_index:anchor_index] = [marker, managed_line]
new_text = '\n'.join(filtered) + '\n'
if new_text != pam_text:
    backup(pam)
    temporary = pam.with_name('sudo.ubuntu-setup-new')
    temporary.write_text(new_text)
    os.chmod(temporary, 0o644)
    os.replace(temporary, pam)

expected = f'{user} ALL=(ALL:ALL) ALL\n'
if sudoers.exists():
    current = sudoers.read_text()
    simple = current.strip() in {
        f'{user} ALL=(ALL) NOPASSWD: ALL',
        f'{user} ALL=(ALL) NOPASSWD:ALL',
        f'{user} ALL=NOPASSWD:ALL',
        f'{user} ALL=(ALL:ALL) ALL',
    }
    if not simple:
        raise SystemExit(f'{sudoers} contém política personalizada; revise manualmente.')
    if current == expected:
        subprocess.run(['visudo', '-cf', str(sudoers)], check=True)
        subprocess.run(['visudo', '-c'], check=True)
        raise SystemExit(0)
    backup(sudoers)
else:
    sudoers.parent.mkdir(parents=True, exist_ok=True)
temporary = sudoers.with_name(sudoers.name + '.ubuntu-setup-new')
temporary.write_text(expected)
os.chmod(temporary, 0o440)
subprocess.run(['visudo', '-cf', str(temporary)], check=True)
os.replace(temporary, sudoers)
subprocess.run(['visudo', '-c'], check=True)
PY
  admin python3 "$policy_script" "$(id -un)"
  sudo -k
  printf 'Teste do sudo: encoste uma digital cadastrada; a senha continuará disponível como fallback.\n'
  sudo -v
}

audit() {
  printf 'Ubuntu: %s %s (%s)\n' "${NAME:-desconhecido}" "${VERSION:-}" "$(dpkg --print-architecture)"
  printf 'Usuário: %s\n' "$(id -un)"
  printf '\nPacotes APT/DEB:\n'
  local package
  for package in git curl btop vlc vim zsh fonts-firacode flatpak fprintd libpam-fprintd google-chrome-stable code docker-desktop lens; do
    if pkg_installed "$package"; then
      printf '  OK      %s\n' "$package"
    else
      printf '  AUSENTE %s\n' "$package"
    fi
  done
  printf '\nComandos:\n'
  for package in hermes claude brew oci rclone kubectl helm; do
    if command_exists "$package"; then
      printf '  OK      %s (%s)\n' "$package" "$(command -v "$package")"
    else
      printf '  AUSENTE %s\n' "$package"
    fi
  done
  printf '\nDigital cadastrada:\n'
  fprintd-list "$USER" 2>&1 || true
  printf '\nPAM do sudo:\n'
  python3 - <<'PY'
from pathlib import Path
p = Path('/etc/pam.d/sudo')
if not p.exists():
    print('  AUSENTE /etc/pam.d/sudo')
else:
    lines = p.read_text().splitlines()
    desired = 'auth sufficient pam_fprintd.so max-tries=3 timeout=10'
    active = [
        (i, line) for i, line in enumerate(lines)
        if 'pam_fprintd.so' in line and not line.lstrip().startswith('#')
    ]
    anchors = [i for i, line in enumerate(lines) if line.strip() == '@include common-auth']
    valid = False
    if len(active) == 1 and anchors and ' '.join(active[0][1].split()) == desired:
        finger_index = active[0][0]
        anchor_index = anchors[0]
        between = lines[finger_index + 1:anchor_index]
        valid = finger_index < anchor_index and all(
            not line.strip() or line.lstrip().startswith('#') for line in between
        )
    if valid:
        print('  OK ' + active[0][1])
    elif active:
        print('  INVÁLIDO: pam_fprintd existe, mas opções ou ordem não correspondem ao perfil')
    else:
        print('  AUSENTE pam_fprintd.so')
PY
  printf '\nGNOME:\n'
  if [[ -n ${DBUS_SESSION_BUS_ADDRESS:-} ]]; then
    printf '  dock-position: %s\n' "$(gsettings get org.gnome.shell.extensions.dash-to-dock dock-position 2>/dev/null || true)"
    printf '  show-home: %s\n' "$(gsettings get org.gnome.shell.extensions.ding show-home 2>/dev/null || true)"
    printf '  icon-theme: %s\n' "$(gsettings get org.gnome.desktop.interface icon-theme 2>/dev/null || true)"
  else
    printf '  Sessão GNOME indisponível neste terminal.\n'
  fi
}

if [[ $MODE == audit ]]; then
  audit
  exit 0
fi

if [[ $MODE == plan ]]; then
  printf 'Plano; nenhuma alteração será feita:\n'
  printf '  - %s\n' "${STAGES[@]}"
  exit 0
fi

for stage in "${STAGES[@]}"; do
  case "$stage" in
    grub)
      [[ $RESOLUTION =~ ^[1-9][0-9]{2,4}x[1-9][0-9]{2,4}$ ]] || {
        printf 'A etapa grub requer --resolution LARGURAxALTURA.\n' >&2
        exit 2
      }
      ;;
    codex-app)
      [[ -n $CODEX_DEB_URL ]] || {
        printf 'A etapa codex-app requer --codex-deb-url HTTPS_URL.\n' >&2
        exit 2
      }
      ;;
    claude-desktop)
      [[ -n $CLAUDE_DESKTOP_DEB_URL ]] || {
        printf 'A etapa claude-desktop requer --claude-desktop-deb-url HTTPS_URL.\n' >&2
        exit 2
      }
      ;;
  esac
done

mkdir -p "$RUN_DIR" "$CACHE_DIR"
exec 9>"$CACHE_DIR/setup.lock"
flock -n 9 || { printf 'Outra execução do setup está ativa.\n' >&2; exit 1; }

printf 'Validando acesso administrativo. Use a digital ou a senha quando solicitado.\n'
sudo -v

run_stage() {
  local stage=$1
  local function_name="stage_${stage//-/_}" log="$RUN_DIR/$stage.log" rc
  printf 'RUN %s (log: %s)\n' "$stage" "$log"
  set +e
  (
    set -Eeuo pipefail
    "$function_name"
  ) >"$log" 2>&1
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    printf 'FAILED %s (código %s). Consulte %s\n' "$stage" "$rc" "$log" >&2
    return "$rc"
  fi
  printf 'OK %s\n' "$stage"
}

for stage in "${STAGES[@]}"; do
  run_stage "$stage"
done

printf '\nSetup concluído. Auditoria recomendada:\n'
if [[ -f $0 ]]; then
  printf '  bash %q --audit\n' "$0"
else
  printf '  bash <(curl -fsSL %q) --audit\n' "$REMOTE_SCRIPT_URL"
fi
printf 'Logout/login pode ser necessário para shell e grupos. Nenhum reboot foi executado.\n'
exit 0
