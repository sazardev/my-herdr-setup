# my-herdr-setup

Mi configuración de [herdr](https://herdr.dev) (tema, opciones de UI,
keybindings/shortcuts) más las herramientas que uso encima de él, para
tenerlo unificado e idéntico en todas mis máquinas (Linux, WSL, macOS).

> herdr es un terminal workspace manager para agentes de código con IA
> (Claude Code, Codex, opencode, etc.): sidebar de agentes, workspaces,
> panes con split, y una API por socket para automatizarlo.

## 🚀 Quick start — VM nueva de un jalón (copy-paste, sin clonar nada)

Arma una VM nueva completa para **gm-erp2** (Windows host + CachyOS-WSL)
pegando estas dos líneas, una por máquina. No hace falta `git clone` de
este repo primero — cada script se descarga y ejecuta directo desde
GitHub (más detalle en [Provisioning](#provisioning-de-máquina-nueva-windows-host--cachyos-wsl)).

**1) Windows (PowerShell, se auto-eleva a admin):**

```powershell
iwr -useb "https://raw.githubusercontent.com/sazardev/my-herdr-setup/main/provisioning/windows-host-setup.ps1" -OutFile "$env:TEMP\windows-host-setup.ps1"; & "$env:TEMP\windows-host-setup.ps1"
```

**2) Ya dentro de CachyOS-WSL (usuario normal, no root — funciona en bash,
zsh y fish, no uses `bash <(curl ...)` porque esa sustitución de procesos
no existe en fish):**

```bash
curl -fsSL https://raw.githubusercontent.com/sazardev/my-herdr-setup/main/provisioning/cachyos-provision.sh | bash
```

Con parámetros (token de GitHub, dotfiles, binario de herdr, rama de
gm-erp2 — todos opcionales):

```bash
curl -fsSL https://raw.githubusercontent.com/sazardev/my-herdr-setup/main/provisioning/cachyos-provision.sh | GH_TOKEN=ghp_xxx bash -s -- \
  --dotfiles-repo <url-tus-dotfiles> \
  --herdr-binary <ruta-al-binario-si-lo-tienes> \
  --gm-erp2-branch dev
```

`GH_TOKEN` es opcional: si no lo exportas, el script cae al flujo
interactivo normal de `gh auth login` (URL + código de un solo uso). Sin
autenticar, el clone de `gm-erp2` falla si el repo es privado.

**Nota de seguridad**: esto ejecuta contenido remoto sin revisarlo primero
— razonable porque es tu propio repo, pero si prefieres auditar antes de
correr, descarga el archivo y ábrelo (`iwr ... -OutFile` / `curl -fsSL ...
-o script.sh`) antes de ejecutarlo, en vez del one-liner combinado.

Qué hace cada script, parámetros completos, y todo lo que NO se puede
automatizar (dotfiles personales, binario de herdr, etc.): ver
[Provisioning de máquina nueva](#provisioning-de-máquina-nueva-windows-host--cachyos-wsl)
más abajo.

## Contenido

```
herdr/config.toml        configuración de herdr: tema, UI, keybindings
scripts/herdr-workspace       arma un grid de panes y lanza Claude en cada uno
scripts/herdr-workspace-safe  igual, pero nunca descarta cambios sin commitear
scripts/list.conf.example     plantilla de la lista de proyectos/clones
install.sh                    symlinks + reload, para instalar en una máquina nueva
provisioning/                 setup de máquina nueva (Windows host + CachyOS-WSL) para gm-erp2
```

## Instalación en una máquina nueva

Requiere `herdr` instalado (`herdr --version`) y, si vas a usar los scripts
de workspace, también `jq` y `claude` (Claude Code) en el `PATH`.

```bash
git clone https://github.com/sazardev/my-herdr-setup.git ~/.local/share/my-herdr-setup
cd ~/.local/share/my-herdr-setup
./install.sh
```

`install.sh` hace symlinks (no copia archivos), así que actualizar la
configuración en cualquier máquina es `git pull` dentro del repo clonado —
sin volver a correr el instalador.

Qué instala:

1. `herdr/config.toml` → `~/.config/herdr/config.toml` (respalda el archivo
   real anterior como `.bak.<timestamp>` si existía y no era ya un symlink)
2. `scripts/herdr-workspace` y `scripts/herdr-workspace-safe` →
   `~/.local/bin/` (asegúrate de que esa carpeta esté en tu `PATH`)
3. Si el servidor de herdr ya está corriendo, recarga el config en caliente
   con `herdr server reload-config` (no hace falta reiniciar herdr)

## `herdr/config.toml` — qué cambia y por qué

herdr trae buenos defaults; este archivo solo lista lo que se cambió
respecto a ellos (`herdr --default-config` imprime la referencia completa
con todas las opciones disponibles, comentadas):

| Opción | Valor | Por qué |
|---|---|---|
| `theme.name` | `gruvbox` | oscuro, buen contraste, colores tierra — cómodo en sesiones largas |
| `theme.auto_switch` | `false` | tema fijo manualmente; no depende del modo claro/oscuro del terminal host (así se ve igual en todas las máquinas) |
| `ui.agent_panel_sort` | `priority` | el sidebar ordena por quién necesita atención, no por workspace — importa cuando hay varios agentes corriendo en paralelo |
| `ui.pane_gaps` | `false` | sin espacio extra entre panes al hacer split: comparten el borde divisor, máximo aprovechamiento de pantalla |
| `ui.toast.delivery` | `off` | sin pop-ups; el estado de cada agente ya se ve en el sidebar |
| `keys.switch_workspace` | `prefix+shift+1..9` | cambia de workspace directo por índice, sin abrir el picker (`prefix+w`) |
| `keys.focus_pane_*` | `prefix+←↓↑→` | moverse entre panes con flechas; deja `h/j/k/l` libres |
| `keys.command` (×4) | `prefix+h/j/k/l` → `herdr pane focus --direction ...` | re-bindea hjkl al mismo foco por dirección, así **ambos** esquemas (flechas y hjkl) funcionan a la vez |

Para validar el archivo después de editarlo: `herdr config check`.
Para aplicar cambios sin reiniciar herdr: `herdr server reload-config`.

## Scripts de workspace

`herdr-workspace` y `herdr-workspace-safe` arman un *space* de herdr con un
grid de panes (3×2 si hay 6 proyectos en la lista, o una fila si hay otra
cantidad) y lanzan `claude` interactivo en cada uno, a partir de un archivo
de texto con `etiqueta|ruta` por línea (ver `scripts/list.conf.example`).

Diferencia entre los dos:

- **herdr-workspace**: antes de lanzar claude, sincroniza cada clone con
  `git fetch` + checkout a la rama requerida + `git pull --ff-only`. Si hay
  cambios sin commitear, **los descarta** (`reset --hard` + `clean -fd`).
  Pensado para clones que son puramente de trabajo desechable/agéntico,
  donde la regla es "todo debe estar commiteado siempre".
- **herdr-workspace-safe**: mismo objetivo, pero **nunca** descarta cambios
  ni fuerza un checkout que pudiera perderlos. Si el working tree no está
  limpio, avisa y lanza claude igual en la rama actual, sin tocar nada.

Ambos son configurables por variables de entorno (todas opcionales):

| Variable | Default | Qué controla |
|---|---|---|
| `HERDR_WORKSPACE_CONF` | `~/.config/herdr-workspaces/list.conf` | lista de proyectos a abrir |
| `HERDR_WORKSPACE_LABEL` | `claude workspaces` (`... safe` en la variante safe) | nombre del space en herdr |
| `HERDR_WORKSPACE_BRANCH` | `main` | rama requerida en cada clone |
| `HERDR_WORKSPACE_LAUNCH_DIR` | `~/.cache/herdr-workspaces` | dónde quedan los launchers y logs |
| `PS_EXE` | ruta a `powershell.exe` en WSL | para notificación nativa de Windows si algo falla (no-op si no existe) |

La lista de proyectos (`list.conf`) es intencionalmente **privada y no vive
en este repo** — cada máquina/proyecto tiene la suya. Cópiala desde la
plantilla y edítala:

```bash
cp scripts/list.conf.example ~/.config/herdr-workspaces/list.conf
```

## Integraciones con agentes (Claude Code, opencode, …)

Los hooks/plugins que reportan el estado del agente al sidebar de herdr
(`~/.claude/hooks/herdr-agent-state.sh`, plugin de opencode, etc.) los
instala y actualiza el propio herdr — **no se versionan aquí** porque se
sobrescriben en cada reinstalación de la integración. Para instalarlos en
una máquina nueva:

```bash
herdr integration install claude
herdr integration install opencode
herdr integration status
```

## Probar herdr en el celular (SSH)

herdr no trae servidor SSH propio ni nada especial de red: el transporte es
**OpenSSH normal**. Lo que aporta herdr es que la sesión queda corriendo en
el servidor como un multiplexor de terminal (similar a `tmux`) y que su UI
es responsive — en pantallas chicas cambia a un switcher pensado para tocar
con el dedo en vez de atajos de teclado (`prefix+1..9`, etc).

O sea: te conectás por SSH a la máquina donde vive herdr, corrés `herdr`
(o te reengancha a la sesión que ya estaba corriendo) y listo.

### Linux / macOS "normal" (no WSL)

Si la máquina donde corre herdr es Linux o macOS directo en la red (sin
capas de virtualización de por medio), alcanza con:

1. Tener `openssh-server` instalado y el servicio activo
   (`sudo systemctl enable --now ssh` en Linux, "Remote Login" en
   Preferencias del Sistema en macOS).
2. Conocer la IP local de esa máquina (`ip addr` / `ifconfig`).
3. Desde el celular, un cliente SSH (Termius, Blink Shell, JuiceSSH) al
   `usuario@ip`, y una vez adentro correr `herdr`.

### WSL2 (Windows)

WSL2 en modo NAT (el default, y el que hay que usar si corrés Docker
Desktop con `mirrored` — `mirrored` rompe la resolución de nombres de los
containers) vive en una red interna (`172.x.x.x`) que **no** es alcanzable
directo desde el WiFi. Instalar y exponer el `sshd` de WSL implicaría
además llevar la cuenta de que su IP cambia en cada reinicio (port
forwarding con `netsh interface portproxy`).

La forma más simple es no tocar el `sshd` de WSL para nada y usar el
**servidor OpenSSH de Windows**, configurado para que la sesión caiga
directo en WSL:

1. **PowerShell como Administrador**, instalar y arrancar el servidor:

   ```powershell
   Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
   Start-Service sshd
   Set-Service -Name sshd -StartupType 'Automatic'
   ```

2. Hacer que la sesión SSH caiga directo en WSL en vez de `cmd.exe`:

   ```powershell
   New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value "C:\Windows\System32\wsl.exe" -PropertyType String -Force
   Restart-Service sshd
   ```

   Con esto entrás directo al home de tu distro default de WSL, donde ya
   está `herdr` instalado.

3. Conseguir la IP de la PC en el WiFi (no la de WSL):

   ```powershell
   ipconfig
   ```

   Buscar la IPv4 del adaptador WiFi/Ethernet (ej. `192.168.1.xx`) — no la
   `172.x.x.x`, esa es la interna de WSL.

4. Desde el celular, cliente SSH → `usuario@192.168.1.xx` puerto `22`. La
   contraseña es la de la **cuenta de Windows** (el sshd que responde es
   el de Windows, no el de WSL).

5. Ya adentro, correr `herdr` y debería mostrarse el layout adaptado a
   pantalla chica.

**Nota de seguridad**: esto deja el puerto 22 abierto solo dentro de la
red local (el firewall de Windows limita la regla al perfil de red
Private/Domain por default, no expone nada a internet mientras no se
configure port forwarding en el router). Para acceso desde fuera de la
LAN (datos móviles), preferir una VPN tipo Tailscale antes que abrir el
puerto 22 directo al router.

## Provisioning de máquina nueva (Windows host + CachyOS-WSL)

`provisioning/` trae los dos scripts usados para armar una VM nueva desde
cero para el proyecto **gm-erp2** (Node/pnpm/Turborepo, Docker nativo,
toolchain de Go, stack de zsh, herdr, nvim, Alacritty, etc.). Son
idempotentes (se pueden re-correr sin romper nada), no abortan al primer
error (reportan y siguen) y terminan con una tabla resumen + log en disco.

```
provisioning/windows-host-setup.ps1   Windows, admin: features de WSL, Nerd Fonts
                                       (JetBrainsMono), imagen de CachyOS-WSL,
                                       .wslconfig, Alacritty (config real de
                                       sazardev/my-alacritty-setup), Claude Code
                                       nativo en Windows
provisioning/cachyos-provision.sh     Dentro de CachyOS: paquetes (pacman/AUR/go),
                                       stack de zsh, Docker, git/gh + gh auth login,
                                       zram+swapfile, este mismo repo de herdr,
                                       sazardev/my-nvim-setup, clone de gm-erp2 +
                                       pnpm install + lefthook install + playwright
                                       install, dotfiles
```

Orden de uso:

```powershell
# 1) En el host Windows, PowerShell (se auto-eleva a admin):
.\provisioning\windows-host-setup.ps1
```

```bash
# 2) Ya dentro de CachyOS-WSL, como el usuario normal (no root):
chmod +x provisioning/cachyos-provision.sh
GH_TOKEN=ghp_xxx ./provisioning/cachyos-provision.sh \
  --dotfiles-repo <url-tus-dotfiles> \
  --herdr-binary <ruta-al-binario-si-lo-tienes> \
  --gm-erp2-branch dev
```

`GH_TOKEN` es opcional: si no lo exportas, el paso `gh_auth` cae al flujo
interactivo normal de `gh auth login` (te da una URL + código de un solo
uso para pegar en el navegador). Sin autenticar, el clone de `gm-erp2`
falla si el repo es privado.

El copy-paste de una sola línea para no clonar nada primero está hasta
arriba de este README, en **Quick start**. Notas:

- El `.wslconfig` que escribe el script de Windows pone `swap=0GB` **a
  propósito**: todo el swap real (zram + swapfile en disco) se gestiona
  dentro de CachyOS por `cachyos-provision.sh`, para no duplicar swap en
  dos capas.
- `cachyos-provision.sh` clona y corre el `install.sh` de este mismo repo
  (`my-herdr-setup`), así que al terminar ya quedan armados `hw`/`hws`
  (una vez que también tengas tu `.zshrc` con esos aliases, vía
  `--dotfiles-repo`).
- También clona `sazardev/my-nvim-setup` y symlinkea `nvim/` a
  `~/.config/nvim` automáticamente (respaldando cualquier config previa).
- El script de Windows instala la config real de Alacritty desde
  `sazardev/my-alacritty-setup` (fuente `JetBrainsMono NFM`, tema
  Gruvbox) en vez de una genérica — parchea `local.toml` para que el
  nombre de distro coincida (`cachyos` en minúsculas).
- `cachyos-provision.sh` clona `gm-erp2` (default:
  `https://github.com/erpv2/gm-erp2.git`, rama `dev`), corre
  `corepack enable && pnpm install`, `lefthook install` y
  `pnpm exec playwright install --with-deps` — el repo queda listo para
  trabajar, no solo el sistema operativo alrededor.
- El binario `herdr` en sí y el repo de dotfiles personales (`.zshrc`,
  `.gitconfig`) no se pueden descargar de un origen público — pásalos por
  parámetro (`--herdr-binary`, `--dotfiles-repo`) o el script deja
  instrucciones para hacerlo a mano.
- `my-fastfetch-setup` no tiene remote en GitHub (solo existe local en la
  máquina de referencia) — no hay forma de automatizarlo hasta que lo
  publiques.
- Algunos nombres de paquete AUR (`usql`, `grpcurl`, `azure-cli`,
  `httpie`, `resterm`) están marcados como "verificar" en el script —
  confírmalos con `yay -Ss <nombre>` la primera vez que lo corras en una
  máquina real. Lo mismo para la extensión `gh-branch` (no se instala:
  no hay certeza de cuál es el repo real en GitHub) y para
  `lazyazure`/`portainer-tui` (`go install`, comentados hasta confirmar
  el import path).

## Qué NO está en este repo (a propósito)

- `~/.config/herdr/session.json` — contiene el estado/tokens de la sesión
  en vivo; nunca debe publicarse.
- `~/.config/herdr/*.sock`, `*.log` — runtime, no configuración.
- `~/.config/herdr-workspaces/list.conf` — rutas y nombres de proyectos
  reales; privado por máquina (usa `scripts/list.conf.example`).
