# Ubuntu Setup

Automação idempotente para preparar uma estação Ubuntu amd64 com aplicativos, ferramentas de desenvolvimento e preferências pessoais de desktop.

O repositório contém:

- `install_ubuntu_packages.sh`: script principal de auditoria, planejamento e instalação.
- `INITIAL_SETUP.md`: documentação detalhada do perfil e das configurações aplicadas.

## O que o script faz

O script organiza o setup em etapas independentes e pode apenas mostrar o plano, auditar a máquina ou aplicar mudanças.

O perfil padrão instala e configura:

- Pacotes APT essenciais: Git, curl, btop, VLC, Vim, Zsh, Fira Code, Flatpak, ferramentas de compilação e suporte a biometria.
- Google Chrome, Visual Studio Code, Docker Desktop e Lens por fontes oficiais.
- KeePassXC, DBeaver Community, VLC e Telegram Desktop via Snap.
- Flatpak com o Flathub habilitado para o usuário.
- Um atalho do WhatsApp Web aberto pelo Chrome em modo aplicativo.
- Cedilha no teclado US International por meio do `~/.XCompose`.
- Zsh, Oh My Zsh, Spaceship Prompt, Zinit, autocomplete, autosuggestions, completions e syntax highlighting.
- Preferências do GNOME: dock inferior com auto-hide, pasta Home oculta, tema escuro, ícones Yaru roxos e terminal com Fira Code/Dracula.
- Homebrew e as ferramentas `oci-cli`, `rclone`, `kubectl` e `helm`.
- Claude Code e Hermes Agent CLI/Desktop pelos instaladores oficiais.
- Autenticação do `sudo` por impressão digital, mantendo senha como fallback.

Há também etapas opcionais para GRUB, Codex App e Claude Desktop. Elas não fazem parte do perfil padrão porque exigem parâmetros explícitos.

## Segurança e comportamento

- O padrão é `--plan all`: nenhuma alteração é feita sem `--apply`.
- O script deve ser executado como usuário normal, nunca com `sudo bash`.
- Operações administrativas chamam `sudo` apenas quando necessário.
- Arquivos de configuração são preservados com backup antes de mudanças.
- As etapas são idempotentes e pulam componentes já instalados quando possível.
- Um lock impede duas execuções simultâneas.
- Cada etapa grava seu próprio log em `~/.local/state/ubuntu-initial-setup/`.
- O script não reinicia o computador.
- Logins em serviços, credenciais cloud e aceite inicial do Docker Desktop continuam sob responsabilidade do usuário.

## Requisitos

- Ubuntu em arquitetura amd64.
- Usuário comum com acesso a `sudo`.
- Conexão com a internet para as etapas de instalação.
- Sessão GNOME ativa para aplicar as preferências do desktop.

## Uso

### Execução remota (sem clonar)

O script pode ser executado diretamente do GitHub, sem clonar o repositório. Rode como usuário normal (sem `sudo`); o próprio script pede autenticação quando necessário:

```bash
bash <(curl -s "https://raw.githubusercontent.com/srlinuxme/ubuntu-setup/refs/heads/main/install_ubuntu_packages.sh")
```

Sem argumentos, isso apenas mostra o plano (`--plan all`). Passe as opções depois do comando, como na execução local:

```bash
# Auditar o estado atual
bash <(curl -s "https://raw.githubusercontent.com/srlinuxme/ubuntu-setup/refs/heads/main/install_ubuntu_packages.sh") --audit

# Aplicar o perfil padrão
bash <(curl -s "https://raw.githubusercontent.com/srlinuxme/ubuntu-setup/refs/heads/main/install_ubuntu_packages.sh") --apply all

# Aplicar somente algumas etapas
bash <(curl -s "https://raw.githubusercontent.com/srlinuxme/ubuntu-setup/refs/heads/main/install_ubuntu_packages.sh") --apply chrome vscode
```

Use `bash <(...)`, não `curl ... | bash`: a substituição de processo mantém o terminal como entrada padrão, permitindo que o `sudo` peça a digital ou a senha. Para inspecionar o script antes, baixe-o, leia e execute localmente.

### Execução local

Clone o repositório e entre no diretório:

```bash
git clone https://github.com/srlinuxme/ubuntu-setup.git
cd ubuntu-setup
chmod +x install_ubuntu_packages.sh
```

Mostrar o plano padrão sem alterar o sistema:

```bash
./install_ubuntu_packages.sh --plan all
```

Auditar o estado atual:

```bash
./install_ubuntu_packages.sh --audit
```

Aplicar o perfil padrão:

```bash
./install_ubuntu_packages.sh --apply all
```

Aplicar somente algumas etapas:

```bash
./install_ubuntu_packages.sh --apply apt shell desktop fingerprint
```

## Etapas disponíveis

Etapas incluídas em `all`:

```text
apt chrome snaps flatpak whatsapp cedilla shell desktop
brew brew-tools docker lens vscode claude-code hermes fingerprint
```

Etapas que exigem parâmetros explícitos:

```bash
./install_ubuntu_packages.sh --apply grub \
  --resolution 1920x1080

./install_ubuntu_packages.sh --apply codex-app \
  --codex-deb-url URL_HTTPS_OFICIAL

./install_ubuntu_packages.sh --apply claude-desktop \
  --claude-desktop-deb-url URL_HTTPS_OFICIAL
```

Use uma resolução realmente suportada pela máquina. Para Codex App e Claude Desktop, forneça somente uma URL HTTPS oficial e atual.

## Logs e diagnóstico

Os logs são criados por execução e por etapa em:

```text
~/.local/state/ubuntu-initial-setup/AAAAMMDD-HHMMSS-PID/
```

Se uma etapa falhar, o script informa o caminho exato do log correspondente. Depois da instalação, execute novamente a auditoria:

```bash
./install_ubuntu_packages.sh --audit
```

Logout/login pode ser necessário para atualizar o shell padrão, grupos e configurações da sessão. Consulte `INITIAL_SETUP.md` para detalhes técnicos, validações e limitações de cada configuração.
