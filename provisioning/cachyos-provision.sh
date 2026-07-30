#!/usr/bin/env bash
# cachyos-provision.sh — provisioning idempotente del entorno gm-erp2 dentro de CachyOS-WSL
# Version: 1.0.0
# Uso:
#   ./cachyos-provision.sh
#   ./cachyos-provision.sh --dotfiles-repo https://github.com/tuusuario/dotfiles.git
#   ./cachyos-provision.sh --herdr-binary /mnt/c/temp/herdr
#   ./cachyos-provision.sh --only zram_swap

set -uo pipefail  # sin -e: los pasos se controlan explícitamente para no abortar todo el script

SCRIPT_VERSION="1.0.0"
DOTFILES_REPO=""
HERDR_BINARY=""
ONLY=""
FORCE=0
EXPECTED_CORES=18
EXPECTED_RAM_GB=23
EXPECTED_SWAP_GB=13
ZRAM_SIZE_MB=5907
DISK_SWAP_GB=8

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dotfiles-repo) DOTFILES_REPO="$2"; shift 2 ;;
    --herdr-binary)  HERDR_BINARY="$2"; shift 2 ;;
    --only)          ONLY="$2"; shift 2 ;;
    --force)         FORCE=1; shift ;;
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
  grep -qi cachyos /etc/os-release || { log_err "No parece ser CachyOS"; return 1; }
  grep -qi microsoft /proc/version || { log_warn "No parece WSL, continúo igual"; }
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
  sudo systemctl unmask "user@${uid}.service" 2>/dev/null || true
  sudo loginctl enable-linger "$USER" 2>/dev/null || true
  sudo systemctl start "user@${uid}.service" 2>/dev/null || true
  systemctl --user status &>/dev/null
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
    nodejs-lts-jod python-pip python-pipx uv go \
    docker docker-buildx docker-compose \
    zsh neovim jq fzf fd bat eza zoxide tree yazi tealdeer navi w3m htop btop glances \
    kubectl httpie
}

step_aur_packages() {
  # nombres exactos verifícalos con `yay -Ss <nombre>` si alguno falla: pueden variar entre AUR/community
  yay -S --needed --noconfirm \
    cachyos-zsh-config github-cli lazydocker gitleaks azure-cli usql grpcurl 2>&1 | tee -a "$LOG_FILE"
}

step_node_globals() {
  sudo npm install -g pnpm node-gyp @anthropic-ai/claude-code
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
  # lazyazure / portainer-tui: confirma el import path real que usabas antes de correr esto en serio
  log_warn "  lazyazure y portainer-tui: confirma el import path exacto antes de instalar (se omiten por defecto)"
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
  for ext in dlvhdr/gh-dash seachicken/gh-poi meiji163/gh-notify kudohamu/gh-graph; do
    gh extension list 2>/dev/null | grep -q "$ext" || gh extension install "$ext" || log_warn "  no se pudo instalar extensión $ext"
  done
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
  if [[ ! -d "$HOME/.local/share/my-herdr-setup" ]]; then
    git clone https://github.com/sazardev/my-herdr-setup.git "$HOME/.local/share/my-herdr-setup"
  else
    git -C "$HOME/.local/share/my-herdr-setup" pull --ff-only || true
  fi
  (cd "$HOME/.local/share/my-herdr-setup" && ./install.sh)

  if [[ -n "$HERDR_BINARY" && -f "$HERDR_BINARY" ]]; then
    mkdir -p "$HOME/.local/bin"
    cp "$HERDR_BINARY" "$HOME/.local/bin/herdr"
    chmod +x "$HOME/.local/bin/herdr"
    log_ok "  binario herdr copiado desde $HERDR_BINARY"
  else
    log_warn "  binario 'herdr' no provisto (--herdr-binary <ruta>) — cópialo manualmente a ~/.local/bin/herdr"
  fi
}

step_dotfiles() {
  if [[ -z "$DOTFILES_REPO" ]]; then
    log_warn "  --dotfiles-repo no provisto — restaura manualmente .zshrc, .zshrc.d, .gitconfig, nvim config"
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
run_step "zram_swap"                step_zram_and_swap
run_step "validate_resources"       step_validate_resources
run_step "herdr_setup"              step_herdr_setup
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
