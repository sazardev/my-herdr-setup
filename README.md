# my-herdr-setup

Mi configuración de [herdr](https://herdr.dev) (tema, opciones de UI,
keybindings/shortcuts) más las herramientas que uso encima de él, para
tenerlo unificado e idéntico en todas mis máquinas (Linux, WSL, macOS).

> herdr es un terminal workspace manager para agentes de código con IA
> (Claude Code, Codex, opencode, etc.): sidebar de agentes, workspaces,
> panes con split, y una API por socket para automatizarlo.

## Contenido

```
herdr/config.toml        configuración de herdr: tema, UI, keybindings
scripts/herdr-workspace       arma un grid de panes y lanza Claude en cada uno
scripts/herdr-workspace-safe  igual, pero nunca descarta cambios sin commitear
scripts/list.conf.example     plantilla de la lista de proyectos/clones
install.sh                    symlinks + reload, para instalar en una máquina nueva
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

## Qué NO está en este repo (a propósito)

- `~/.config/herdr/session.json` — contiene el estado/tokens de la sesión
  en vivo; nunca debe publicarse.
- `~/.config/herdr/*.sock`, `*.log` — runtime, no configuración.
- `~/.config/herdr-workspaces/list.conf` — rutas y nombres de proyectos
  reales; privado por máquina (usa `scripts/list.conf.example`).
