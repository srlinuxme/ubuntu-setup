# Configuração inicial do Ubuntu

Perfil validado no Ubuntu 26.04.1 LTS, GNOME/Wayland, usuário `srlinux`.

O script principal deste documento é:

```bash
~/install_ubuntu_packages.sh
```

Ele é idempotente, cria backups antes de alterar configurações, gera logs em
`~/.local/state/ubuntu-initial-setup/` e, por padrão, apenas mostra o plano.
Não execute o script inteiro com `sudo`; rode como usuário normal e autentique
quando solicitado.

## Uso do script

```bash
# Mostrar etapas padrão, sem alterar o sistema
bash ~/install_ubuntu_packages.sh --plan all

# Auditar o estado atual
bash ~/install_ubuntu_packages.sh --audit

# Aplicar o perfil padrão
bash ~/install_ubuntu_packages.sh --apply all

# Aplicar apenas etapas específicas
bash ~/install_ubuntu_packages.sh --apply apt shell desktop fingerprint

# Etapas que exigem parâmetros explícitos
bash ~/install_ubuntu_packages.sh --apply grub --resolution 1920x1080
bash ~/install_ubuntu_packages.sh --apply codex-app --codex-deb-url URL_OFICIAL
bash ~/install_ubuntu_packages.sh --apply claude-desktop --claude-desktop-deb-url URL_OFICIAL
```

`all` não inclui GRUB, Codex App nem Claude Desktop, pois essas etapas dependem
de resolução ou URL oficial confirmada no momento da instalação.

## 1. Aplicativos e pacotes

### APT

- `git`
- `curl`
- `btop`
- `vlc`
- `vim`
- `zsh`
- `fonts-firacode`
- `flatpak`
- `gnome-software-plugin-flatpak`
- `fprintd`
- `libpam-fprintd`
- dependências de download, repositórios e compilação

### Aplicativos oficiais

- Google Chrome, pelo DEB oficial.
- Visual Studio Code, pelo DEB oficial.
- Docker Desktop, pelo repositório e DEB oficiais.
- Lens, pelo repositório APT oficial.
- Claude Code, pelo instalador oficial do canal estável.
- Hermes Agent CLI e Desktop, pelo instalador oficial da Nous Research.
- Codex App e Claude Desktop somente com uma URL oficial fornecida
  explicitamente ao script.

### Snap

- KeePassXC
- DBeaver Community (`dbeaver-ce`, modo classic)
- VLC
- Telegram Desktop

### Flatpak

- Instalar Flatpak e a integração com GNOME Software.
- Adicionar Flathub para o usuário atual.

### Homebrew

Instalar no prefixo oficial `/home/linuxbrew/.linuxbrew` e adicionar ao Zsh:

- `oci-cli`
- `rclone`
- `kubectl`
- `helm`

## 2. GNOME e terminal

Configurar:

- Dock na parte inferior.
- Desabilitar modo painel (`extend-height=false`).
- Habilitar auto-hide.
- Ocultar a pasta Home da área de trabalho.
- Preferir esquema de cores escuro.
- Usar ícones `Yaru-purple-dark` quando disponíveis.
- Usar Fira Code no terminal.
- Aplicar a paleta Dracula no Ptyxis ou GNOME Terminal.

A observação trazida do Omarchy continua válida no Ubuntu: não instalar
`dracula-icons-theme` para obter pastas roxas. O tema de ícones correto para o
Nautilus é a variante roxa do Yaru, atualmente `Yaru-purple-dark` nesta máquina.

## 3. Cedilha no teclado US International

Arquivo `~/.XCompose`:

```text
# Preserve the standard compose sequences for the current locale.
include "%L"

# US international: acute accent + C produces Portuguese cedilla.
<dead_acute> <c> : "ç" ccedilla
<dead_acute> <C> : "Ç" Ccedilla
```

Resultado:

- Acento agudo + `c` → `ç`
- Acento agudo + `C` → `Ç`

## 4. Zsh, Oh My Zsh, Zinit e Spaceship

Instalar:

- Zsh
- Oh My Zsh
- Spaceship Prompt
- Zinit
- `zsh-autocomplete`
- `zsh-autosuggestions`
- `zsh-completions`
- `fast-syntax-highlighting`

A configuração mais recente do prompt, portada do setup do Omarchy, deve ficar
em `~/.spaceshiprc.zsh`, separada do `.zshrc`:

```zsh
SPACESHIP_USER_SHOW=always
SPACESHIP_PROMPT_ADD_NEWLINE=false
SPACESHIP_CHAR_SYMBOL="λ"
SPACESHIP_CHAR_SUFFIX=" "
SPACESHIP_PROMPT_ORDER=(
  user dir host git package node bun elixir erlang rust
  docker docker_compose terraform exec_time line_sep jobs exit_code char
)
```

O script preserva conteúdo externo ao bloco gerenciado no `.zshrc`, cria backup
antes de migrar a configuração antiga e mantém histórico persistente.

## 5. WhatsApp

Criar um atalho local usando o Google Chrome em modo aplicativo:

```text
/usr/bin/google-chrome-stable --app=https://web.whatsapp.com/
```

## 6. GRUB

Esta etapa nunca faz parte de `all`; exige a resolução explicitamente.
Configuração validada nesta máquina:

```text
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="text"
GRUB_GFXMODE=1920x1080
GRUB_GFXPAYLOAD_LINUX=keep
```

O script remove somente `quiet` e `splash`, acrescenta `text`, preserva os
demais argumentos, cria backup e executa `update-grub`. Ele não altera o target
do systemd nem reinicia a máquina.

## 7. Biometria no sudo — configuração atual e obrigatória

Esta seção é mais recente que o antigo setup do Omarchy e não deve ser
substituída pela regra `NOPASSWD` daquele documento.

Hardware validado:

- Sensor Synaptics Prometheus `06cb:00bd`.
- Firmware atualizado pelo LVFS/fwupd.
- `fprintd`, `libfprint-2-2` e `libpam-fprintd` instalados.
- Indicadores esquerdo e direito cadastrados.

Cadastrar ou recadastrar uma digital, variando ângulo e posição:

```bash
fprintd-enroll -f left-index-finger "$USER"
fprintd-verify -f left-index-finger "$USER"
```

Configuração de `/etc/pam.d/sudo`, antes de `@include common-auth`:

```pam
# Fingerprint for sudo; common-auth remains password fallback
auth       sufficient   pam_fprintd.so max-tries=3 timeout=10
@include common-auth
```

A política `/etc/sudoers.d/90-srlinux` deve exigir autenticação:

```sudoers
srlinux ALL=(ALL:ALL) ALL
```

Nunca usar `NOPASSWD` neste perfil, pois ele ignora o PAM e impede que o sudo
solicite a digital. Sempre validar com:

```bash
sudo chmod 0440 /etc/sudoers.d/90-srlinux
sudo visudo -cf /etc/sudoers.d/90-srlinux
sudo visudo -c
sudo -k
sudo -v
```

Se a digital falhar ou atingir o timeout, o sudo deve oferecer a senha como
fallback.

## 8. Validação final

Após aplicar o setup:

```bash
bash -n ~/install_ubuntu_packages.sh
bash ~/install_ubuntu_packages.sh --audit
fprintd-list "$USER"
hermes --version
code --version
kubectl version --client
helm version --short
rclone version
oci --version
```

Logout/login pode ser necessário para atualizar o shell padrão e grupos. O
script não autentica contas cloud, não configura credenciais OCI/rclone, não
aceita termos do Docker Desktop e não reinicia o computador.
