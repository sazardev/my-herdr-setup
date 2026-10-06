#!/usr/bin/env bash
# install.sh — instala esta configuración de herdr en la máquina actual
# (Linux, macOS o WSL; cualquier sistema que use la ruta XDG ~/.config).
#
# Qué hace:
#   1) symlink de herdr/config.toml -> ~/.config/herdr/config.toml
#      (si ya existe un config.toml real, se respalda como .bak antes de
#      reemplazarlo por el symlink)
#   2) symlink de scripts/herdr-workspace(-safe) y claude-usage-report ->
#      ~/.local/bin/
#   3) symlink de claude/hooks/herdr-usage-metadata.sh -> ~/.claude/hooks/
#      (hook custom de Claude Code, sibling de herdr-agent-state.sh —
#      NO lo reemplaza; ese sigue gestionado por `herdr integration`)
#   4) si herdr está corriendo, recarga el config con `herdr server reload-config`
#
# No toca ~/.config/herdr-workspaces/list.conf: ese archivo es privado por
# proyecto y no vive en este repo (ver scripts/list.conf.example).
#
# El hook de herdr-usage-metadata.sh necesita además una entrada "Stop" en
# ~/.claude/settings.json (no se toca automáticamente porque ese archivo
# tiene más config personal tuya) — ver README para el bloque exacto a
# fusionar a mano.
#
# claude/herdr-statusline.sh (límites 5h/7d del plan Pro/Max en el sidebar)
# se conecta con una clave "statusLine" en ese mismo settings.json:
#   "statusLine": { "type": "command", "command": "sh ~/.claude/herdr-statusline.sh" }
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

link() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    mv "$dst" "$dst.bak.$(date +%s)"
    echo "  ⚠ respaldado $dst -> $dst.bak.*"
  fi
  ln -sfn "$src" "$dst"
  echo "  ✓ $dst -> $src"
}

echo "instalando config.toml de herdr…"
link "$REPO_DIR/herdr/config.toml" "$HOME/.config/herdr/config.toml"

echo "instalando scripts de workspace…"
mkdir -p "$HOME/.local/bin"
link "$REPO_DIR/scripts/herdr-workspace" "$HOME/.local/bin/herdr-workspace"
link "$REPO_DIR/scripts/herdr-workspace-safe" "$HOME/.local/bin/herdr-workspace-safe"
link "$REPO_DIR/scripts/claude-usage-report" "$HOME/.local/bin/claude-usage-report"
link "$REPO_DIR/scripts/claude-limits-bar" "$HOME/.local/bin/claude-limits-bar"

echo "instalando hook y statusline custom de Claude Code…"
link "$REPO_DIR/claude/hooks/herdr-usage-metadata.sh" "$HOME/.claude/hooks/herdr-usage-metadata.sh"
chmod +x "$HOME/.claude/hooks/herdr-usage-metadata.sh"
link "$REPO_DIR/claude/herdr-statusline.sh" "$HOME/.claude/herdr-statusline.sh"
chmod +x "$HOME/.claude/herdr-statusline.sh"

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "  ⚠ ~/.local/bin no está en tu PATH; agrégalo en tu .bashrc/.zshrc" ;;
esac

if command -v herdr >/dev/null 2>&1 && herdr status >/dev/null 2>&1; then
  echo "recargando config en el servidor herdr corriendo…"
  herdr server reload-config || true
fi

echo
echo "listo. Si es la primera vez que usas herdr-workspace en esta máquina:"
echo "  cp $REPO_DIR/scripts/list.conf.example ~/.config/herdr-workspaces/list.conf"
echo "  # edítalo con tus propios proyectos, luego: herdr-workspace  (o herdr-workspace-safe)"
