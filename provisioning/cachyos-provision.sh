#!/usr/bin/env bash
# cachyos-provision.sh — provisioning idempotente del entorno gm-erp2 dentro de CachyOS-WSL
# Version: 1.1.0
# Uso:
#   ./cachyos-provision.sh
#   GH_TOKEN=ghp_xxx ./cachyos-provision.sh          # gh auth login no interactivo
#   ./cachyos-provision.sh --dotfiles-repo https://github.com/tuusuario/dotfiles.git
#   ./cachyos-provision.sh --herdr-binary /mnt/c/temp/herdr
#   ./cachyos-provision.sh --gm-erp2-repo https://github.com/erpv2/gm-erp2.git --gm-erp2-branch dev
#   ./cachyos-provision.sh --only zram_swap

set -uo pipefail  # sin -e: los pasos se controlan explícitamente para no abortar todo el script

SCRIPT_VERSION="1.1.0"
DOTFILES_REPO=""
HERDR_BINARY=""
ONLY=""
FORCE=0
EXPECTED_CORES=18
EXPECTED_RAM_GB=23
EXPECTED_SWAP_GB=13
ZRAM_SIZE_MB=5907
DISK_SWAP_GB=8

# repos propios reales (verificados: tienen remote en GitHub)
NVIM_SETUP_REPO="https://github.com/sazardev/my-nvim-setup.git"
HERDR_SETUP_REPO="https://github.com/sazardev/my-herdr-setup.git"

# gm-erp2: default tomado del remote real ya clonado en la máquina de referencia
GM_ERP2_REPO="https://github.com/erpv2/gm-erp2.git"
GM_ERP2_BRANCH="dev"
GM_ERP2_DIR="$HOME/dev/gm-erp2"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dotfiles-repo)  DOTFILES_REPO="$2"; shift 2 ;;
    --herdr-binary)   HERDR_BINARY="$2"; shift 2 ;;
    --gm-erp2-repo)   GM_ERP2_REPO="$2"; shift 2 ;;
    --gm-erp2-branch) GM_ERP2_BRANCH="$2"; shift 2 ;;
    --only)           ONLY="$2"; shift 2 ;;
    --force)          FORCE=1; shift ;;
    *) echo "Argumento desconocido: $1"; exit 2 ;;
  esac
done

STATE_DIR="$HOME/.local/state/gm-erp2-provision"
LOG_DIR="$STATE_DIR/logs"
LOG_FILE="$LOG_DIR/provision-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$LOG_DIR"

declare -a RESULTS=()

log() {
  local level="$1"; shift
  local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
  local color=""; local reset="\033[0m"
  case "$level" in
    OK)   color="\033[32m" ;;
    WARN) color="\033[33m" ;;
    ERR)  color="\033[31m" ;;
    *)    color="\033[37m" ;;
  esac
  printf "%s [%b%s%b] %s\n" "$ts" "$color" "$level" "$reset" "$*" | tee -a "$LOG_FILE" >&2
}
log_info(){ log "INFO" "$@"; }
log_ok(){   log "OK"   "$@"; }
log_warn(){ log "WARN" "$@"; }
log_err(){  log "ERR"  "$@"; }

run_step() {
  local name="$1"; shift
  if [[ -n "$ONLY" && "$ONLY" != "$name" ]]; then return 0; fi
  log_info "-> $name"
  local start end dur
  start=$(date +%s)
  if "$@"; then
    end=$(date +%s); dur=$((end - start))
    log_ok "$name (${dur}s)"
    RESULTS+=("OK|$name|${dur}s")
  else
    local rc=$?
    end=$(date +%s); dur=$((end - start))
    log_err "$name FALLÓ (rc=$rc, ${dur}s) — ver $LOG_FILE"
    RESULTS+=("FAIL|$name|rc=$rc")
  fi
}

pkg_missing() { ! pacman -Qi "$1" &>/dev/null; }
bin_missing() { ! command -v "$1" &>/dev/null; }

# ---------- pasos ----------

step_preflight() {
  if [[ -r /etc/os-release ]]; then
    if ! grep -qi cachyos /etc/os-release && ! grep -qi arch /etc/os-release; then
      bin_missing pacman && { log_err "No parece ser CachyOS"; return 1; }
      log_warn "  /etc/os-release no menciona CachyOS/Arch, pero hay pacman -- continúo"
    fi
  else
    # rootfs recién extraído del .wsl: /etc/os-release todavía no existe hasta el primer
    # 'pacman -Syu' (lo instala el paquete 'filesystem'). pacman ya presente alcanza como señal.
    bin_missing pacman && { log_err "No existe /etc/os-release y no hay pacman -- no parece CachyOS"; return 1; }
    log_warn "  /etc/os-release no existe todavía (rootfs recién extraído) -- detectado CachyOS/Arch via pacman, continúo"
  fi
  grep -qi microsoft /proc/version || log_warn "No parece WSL, continúo igual"
  curl -fsS --max-time 5 https://archlinux.org >/dev/null || { log_err "Sin conectividad a internet"; return 1; }
  return 0
}

step_fix_wsl_conf() {
  local tmp; tmp=$(mktemp)
  cat > "$tmp" <<EOF
[boot]
systemd = true
command = /usr/local/sbin/gm-erp2-ensure-swap.sh

[network]
generateHosts = true
generateResolvConf = true

[interop]
enabled = true
appendWindowsPath = false

[user]
default = $USER
EOF
  if ! sudo diff -q "$tmp" /etc/wsl.conf &>/dev/null; then
    sudo cp /etc/wsl.conf "/etc/wsl.conf.bak.$(date +%s)" 2>/dev/null || true
    sudo cp "$tmp" /etc/wsl.conf
    log_warn "  /etc/wsl.conf cambió — corre 'wsl --shutdown' desde Windows y reabre para que systemd/red tomen efecto"
  fi
  rm -f "$tmp"
}

step_fix_systemd_user_session() {
  local uid; uid=$(id -u)
  if [[ ! -d /run/systemd/system ]]; then
    log_warn "  systemd todavía no es PID 1 en esta sesión (wsl.conf se acaba de escribir) -- corre 'wsl --shutdown' desde Windows, reabre, y vuelve a correr el script; no es un error bloqueante"
    return 0
  fi
  sudo systemctl unmask "user@${uid}.service" 2>/dev/null || true
  sudo loginctl enable-linger "$USER" 2>/dev/null || true
  sudo systemctl start "user@${uid}.service" 2>/dev/null || true
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$uid}"
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
  if systemctl --user status &>/dev/null; then
    return 0
  fi
  # 'curl | bash' corre en una shell no interactiva sin bus de sesión propio; el bus del usuario
  # ya quedó habilitado/arrancado arriba y estará disponible en la siguiente sesión (login/wsl nueva).
  log_warn "  'systemctl --user' no responde en esta shell no interactiva -- ya quedó habilitado, se validará solo en tu próxima sesión"
  return 0
}

step_system_update() {
  sudo pacman -Syu --noconfirm --needed
}

step_install_yay() {
  bin_missing yay || return 0
  local tmp; tmp=$(mktemp -d)
  git clone --depth 1 https://aur.archlinux.org/yay.git "$tmp/yay"
  (cd "$tmp/yay" && makepkg -si --noconfirm)
  rm -rf "$tmp"
}

step_base_packages() {
  sudo pacman -S --needed --noconfirm \
    base-devel git git-delta lazygit \
    nodejs-lts-jod npm python-pip python-pipx uv go \
    docker docker-buildx docker-compose \
    zsh neovim jq fzf fd bat eza zoxide tree yazi tealdeer navi w3m htop btop glances \
    kubectl httpie
}

step_aur_packages() {
  # instalación paquete-por-paquete: si uno falla, no se aborta el resto (solo se marca el step como FAIL al final)
  local pkgs=(cachyos-zsh-config github-cli lazydocker gitleaks azure-cli usql grpcurl resterm)
  local all_ok=1
  for p in "${pkgs[@]}"; do
    if pacman -Qi "$p" &>/dev/null; then
      log_info "  AUR: $p ya instalado"
      continue
    fi
    if yay -S --needed --noconfirm "$p" &>>"$LOG_FILE"; then
      log_ok "  AUR: $p"
    else
      log_warn "  AUR: $p falló — nombre incierto, verifica con 'yay -Ss $p'"
      all_ok=0
    fi
  done
  [[ $all_ok -eq 1 ]]
}

step_node_globals() {
  sudo npm install -g pnpm node-gyp corepack
  # @anthropic-ai/claude-code vía npm -g falla en este entorno: npm bloquea su script de
  # postinstall (install.cjs, el que baja el binario nativo) por su política de
  # allow-scripts, dejando un shim roto ("claude native binary not installed"). El
  # instalador oficial standalone no depende de ese postinstall y deja el binario listo
  # directo en ~/.local/bin.
  if bin_missing claude; then
    curl -fsSL https://claude.ai/install.sh | bash
  fi
  grep -q '.local/bin' ~/.zshrc 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
}

step_go_tools() {
  export PATH="$PATH:$(go env GOPATH)/bin"
  go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest
  go install honnef.co/go/tools/cmd/staticcheck@latest
  go install -tags 'postgres mysql' github.com/golang-migrate/migrate/v4/cmd/migrate@latest
  go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
  go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
  go install github.com/bufbuild/buf/cmd/buf@latest
  go install github.com/evilmartians/lefthook@latest
  # lazyazure / portainer-tui: confirma el import path real antes de descomentar
  # go install github.com/<owner>/lazyazure@latest
  # go install github.com/<owner>/portainer-tui@latest
  log_warn "  lazyazure y portainer-tui: confirma el import path exacto (se omiten por defecto)"
  grep -q 'GOPATH/bin' ~/.zshrc 2>/dev/null || echo 'export PATH="$PATH:$(go env GOPATH)/bin"' >> ~/.zshrc
}

step_zsh_stack() {
  if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
    RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
  fi
  local custom="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
  declare -A plugins=(
    [zsh-autosuggestions]="https://github.com/zsh-users/zsh-autosuggestions"
    [zsh-syntax-highlighting]="https://github.com/zsh-users/zsh-syntax-highlighting"
    [zsh-completions]="https://github.com/zsh-users/zsh-completions"
    [zsh-history-substring-search]="https://github.com/zsh-users/zsh-history-substring-search"
  )
  for name in "${!plugins[@]}"; do
    [[ -d "$custom/plugins/$name" ]] || git clone --depth 1 "${plugins[$name]}" "$custom/plugins/$name"
  done
  [[ -d "$custom/themes/powerlevel10k" ]] || git clone --depth 1 https://github.com/romkatv/powerlevel10k.git "$custom/themes/powerlevel10k"
  bin_missing oh-my-posh && curl -s https://ohmyposh.dev/install.sh | bash -s
  sudo usermod -s /usr/bin/zsh "$USER"
}

step_docker_setup() {
  sudo systemctl enable --now docker
  groups "$USER" | grep -qw docker || sudo usermod -aG docker "$USER"
}

step_git_config() {
  git config --global merge.conflictstyle zdiff3
  git config --global pull.ff only
  git config --global push.autosetupremote true
  git config --global fetch.prune true
  git config --global init.defaultBranch main
  git config --global credential.helper "!gh auth git-credential"
  bin_missing gh && { log_err "gh no instalado, saltando gh extensions"; return 1; }

  local gh_extensions=(
    "dlvhdr/gh-dash"
    "seachicken/gh-poi"
    "meiji163/gh-notify"
    "kudohamu/gh-graph"
  )
  local all_ok=1
  for ext in "${gh_extensions[@]}"; do
    gh extension list 2>/dev/null | grep -q "$ext" && continue
    if gh extension install "$ext" &>>"$LOG_FILE"; then
      log_ok "  gh extension: $ext"
    else
      log_warn "  gh extension $ext falló"
      all_ok=0
    fi
  done
  log_warn "  gh-branch NO se instala automáticamente: no hay certeza de cuál es el repo real en GitHub." \
           " Corre 'gh extension search branch' tú mismo, confirma el owner/repo y agrégalo al array" \
           " gh_extensions de este script."
  [[ $all_ok -eq 1 ]]
}

step_gh_auth() {
  bin_missing gh && { log_err "gh no instalado"; return 1; }
  if gh auth status &>/dev/null; then
    log_info "  gh ya autenticado"
    return 0
  fi
  if [[ -n "${GH_TOKEN:-}" ]]; then
    echo "$GH_TOKEN" | gh auth login --with-token
  else
    log_warn "  gh no autenticado y no hay GH_TOKEN en el entorno — sigue el flujo interactivo (URL + código de un solo uso)"
    gh auth login -h github.com -p https -w
  fi
  gh auth status &>/dev/null
}

step_zram_and_swap() {
  sudo pacman -S --needed --noconfirm zram-generator
  sudo tee /etc/systemd/zram-generator.conf >/dev/null <<EOF
[zram0]
zram-size = ${ZRAM_SIZE_MB}
compression-algorithm = zstd
EOF

  sudo tee /usr/local/sbin/gm-erp2-ensure-swap.sh >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail
SWAPFILE=/swapfile
if [[ ! -f "\$SWAPFILE" ]]; then
  fallocate -l ${DISK_SWAP_GB}G "\$SWAPFILE"
  chmod 600 "\$SWAPFILE"
  mkswap "\$SWAPFILE"
fi
swapon --show=NAME --noheadings | grep -qx "\$SWAPFILE" || swapon "\$SWAPFILE"
EOF
  sudo chmod +x /usr/local/sbin/gm-erp2-ensure-swap.sh
  sudo /usr/local/sbin/gm-erp2-ensure-swap.sh
  sudo systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || true
}

step_validate_resources() {
  local cores ram_gb swap_gb
  cores=$(nproc)
  ram_gb=$(free -g | awk '/^Mem:/{print $2}')
  swap_gb=$(free -g | awk '/^Swap:/{print $2}')
  log_info "  CPU cores: $cores (esperado ~$EXPECTED_CORES)"
  log_info "  RAM: ${ram_gb}Gi (esperado ~$EXPECTED_RAM_GB)"
  log_info "  Swap: ${swap_gb}Gi (esperado ~$EXPECTED_SWAP_GB)"
  [[ "$cores" -lt $((EXPECTED_CORES / 2)) ]] && log_warn "  CPU muy por debajo de lo esperado — revisa .wslconfig en Windows"
  [[ "$ram_gb"  -lt $((EXPECTED_RAM_GB / 2)) ]] && log_warn "  RAM muy por debajo de lo esperado — revisa .wslconfig en Windows"
  return 0
}

step_herdr_setup() {
  local dest="$HOME/.local/share/my-herdr-setup"
  if [[ ! -d "$dest/.git" ]]; then
    git clone "$HERDR_SETUP_REPO" "$dest"
  else
    git -C "$dest" pull --ff-only || true
  fi
  (cd "$dest" && ./install.sh)

  if [[ -n "$HERDR_BINARY" && -f "$HERDR_BINARY" ]]; then
    mkdir -p "$HOME/.local/bin"
    cp "$HERDR_BINARY" "$HOME/.local/bin/herdr"
    chmod +x "$HOME/.local/bin/herdr"
    log_ok "  binario herdr copiado desde $HERDR_BINARY"
  else
    log_warn "  binario 'herdr' no provisto (--herdr-binary <ruta>) — cópialo manualmente a ~/.local/bin/herdr"
  fi
}

step_nvim_setup() {
  local dest="$HOME/personal/my-nvim-setup"
  mkdir -p "$HOME/personal"
  if [[ ! -d "$dest/.git" ]]; then
    git clone "$NVIM_SETUP_REPO" "$dest"
  else
    git -C "$dest" pull --ff-only || true
  fi
  if [[ ! -d "$dest/nvim" ]]; then
    log_err "  $dest no trae carpeta nvim/ — revisa el repo"
    return 1
  fi
  if [[ -e "$HOME/.config/nvim" && ! -L "$HOME/.config/nvim" ]]; then
    mv "$HOME/.config/nvim" "$HOME/.config/nvim.bak.$(date +%s)"
    log_warn "  ~/.config/nvim existente respaldado como .bak"
  fi
  ln -sfn "$dest/nvim" "$HOME/.config/nvim"
}

step_clone_gm_erp2() {
  mkdir -p "$HOME/dev"
  if [[ -z "$GM_ERP2_REPO" ]]; then
    log_err "  --gm-erp2-repo vacío"
    return 1
  fi
  if [[ ! -d "$GM_ERP2_DIR/.git" ]]; then
    git clone --branch "$GM_ERP2_BRANCH" "$GM_ERP2_REPO" "$GM_ERP2_DIR" 2>>"$LOG_FILE" \
      || git clone "$GM_ERP2_REPO" "$GM_ERP2_DIR"
  else
    git -C "$GM_ERP2_DIR" fetch --all
    git -C "$GM_ERP2_DIR" checkout "$GM_ERP2_BRANCH"
    git -C "$GM_ERP2_DIR" pull --ff-only
  fi
}

step_gm_erp2_deps() {
  [[ -d "$GM_ERP2_DIR/.git" ]] || { log_err "  gm-erp2 no está clonado, saltando pnpm install"; return 1; }
  (
    cd "$GM_ERP2_DIR" || exit 1
    export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
    corepack enable 2>&1 | tee -a "$LOG_FILE"
    pnpm install
  )
}

step_gm_erp2_hooks() {
  [[ -d "$GM_ERP2_DIR/.git" ]] || return 1
  (cd "$GM_ERP2_DIR" && lefthook install)
}

step_gm_erp2_playwright() {
  [[ -d "$GM_ERP2_DIR/.git" ]] || return 1
  # Playwright solo sabe auto-instalar deps de sistema (--with-deps) en distros basados
  # en apt/dnf; en Arch/CachyOS no existe ese soporte y truena buscando apt-get. Instalamos
  # a mano el equivalente en pacman de las libs que Chromium/Firefox/WebKit piden en
  # runtime, y luego solo bajamos los binarios de los navegadores (sin --with-deps).
  sudo pacman -S --needed --noconfirm \
    nss nspr atk at-spi2-atk at-spi2-core cups libdrm mesa \
    libxcomposite libxdamage libxfixes libxrandr libxkbcommon \
    pango cairo gtk3 gdk-pixbuf2 alsa-lib dbus \
    libxshmfence libxi libxtst libxext libx11 libxcb expat glib2
  if ! (cd "$GM_ERP2_DIR" && pnpm exec playwright install); then
    log_warn "  playwright install falló incluso con las libs de pacman -- corre 'pnpm exec playwright install-deps' manualmente en $GM_ERP2_DIR para ver qué falta exactamente"
    return 1
  fi
}

step_dotfiles() {
  if [[ -z "$DOTFILES_REPO" ]]; then
    log_warn "  --dotfiles-repo no provisto — restaura manualmente .zshrc, .zshrc.d, .gitconfig"
    return 0
  fi
  local dest="$HOME/.local/share/dotfiles"
  if [[ ! -d "$dest" ]]; then
    git clone "$DOTFILES_REPO" "$dest"
  else
    git -C "$dest" pull --ff-only || true
  fi
  if [[ -x "$dest/install.sh" ]]; then
    (cd "$dest" && ./install.sh)
  else
    log_warn "  el repo de dotfiles no tiene install.sh — symlinks manuales pendientes"
  fi
}

step_final_report() {
  node --version 2>/dev/null | xargs -I{} log_info "  node: {}"
  pnpm --version 2>/dev/null | xargs -I{} log_info "  pnpm: {}"
  go version 2>/dev/null | xargs -I{} log_info "  go: {}"
  docker --version 2>/dev/null | xargs -I{} log_info "  docker: {}"
  claude --version 2>/dev/null | xargs -I{} log_info "  claude: {}"
  gh --version 2>/dev/null | head -1 | xargs -I{} log_info "  {}"
  log_info "  gm-erp2 en: $GM_ERP2_DIR (rama $GM_ERP2_BRANCH)"
  log_info "  Pendiente manual: 'cd $GM_ERP2_DIR && docker compose up -d' para levantar mongo/redis"
  log_info "  Pendiente manual: cierra sesión y vuelve a entrar para que el grupo 'docker' tome efecto"
  return 0
}

# ---------- main ----------
log_info "=== cachyos-provision.sh v$SCRIPT_VERSION ==="

run_step "preflight"                step_preflight
run_step "fix_wsl_conf"             step_fix_wsl_conf
run_step "fix_systemd_user_session" step_fix_systemd_user_session
run_step "system_update"            step_system_update
run_step "install_yay"              step_install_yay
run_step "base_packages"            step_base_packages
run_step "aur_packages"             step_aur_packages
run_step "node_globals"             step_node_globals
run_step "go_tools"                 step_go_tools
run_step "zsh_stack"                step_zsh_stack
run_step "docker_setup"             step_docker_setup
run_step "git_config"               step_git_config
run_step "gh_auth"                  step_gh_auth
run_step "zram_swap"                step_zram_and_swap
run_step "validate_resources"       step_validate_resources
run_step "herdr_setup"              step_herdr_setup
run_step "nvim_setup"               step_nvim_setup
run_step "clone_gm_erp2"            step_clone_gm_erp2
run_step "gm_erp2_deps"             step_gm_erp2_deps
run_step "gm_erp2_hooks"            step_gm_erp2_hooks
run_step "gm_erp2_playwright"       step_gm_erp2_playwright
run_step "dotfiles"                 step_dotfiles
run_step "final_report"             step_final_report

echo
echo "=== RESUMEN ==="
fail_count=0
for r in "${RESULTS[@]}"; do
  IFS='|' read -r status name detail <<< "$r"
  printf "  %-6s %-28s %s\n" "$status" "$name" "$detail"
  [[ "$status" == "FAIL" ]] && ((fail_count++))
done
log_info "Log completo en: $LOG_FILE"
[[ $fail_count -gt 0 ]] && { log_err "$fail_count paso(s) fallaron"; exit 1; }
exit 0
