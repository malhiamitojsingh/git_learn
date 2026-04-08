#!/usr/bin/env bash
# appy — Service Installer & System Manager for CachyOS / Arch Linux
# Version: 3.0
# Usage: sudo bash appy.sh [--daemon|--health|--update|--status|--install|--remove|--backup|--logs|--version|--help]

# ── Strict mode ───────────────────────────────────────────────────────────────
# NOTE: We deliberately avoid `set -e` at the top level because `(( expr ))`
# returning 0 (false) would abort the script. We use explicit `|| true` guards.
set -uo pipefail

# ── Version & paths ───────────────────────────────────────────────────────────
readonly APPY_VERSION="3.1"
readonly APPY_DIR="/var/lib/appy"
readonly APPY_LOG="/var/log/appy.log"
readonly APPY_DAEMON_LOG="/var/log/appy-daemon.log"
readonly CRED_FILE="$HOME/appy-credentials.txt"

# ── Terminal capability check ─────────────────────────────────────────────────
_HAS_COLOR=true
[[ "${TERM:-}" == "dumb" || -z "${TERM:-}" ]] && _HAS_COLOR=false
[[ "${NO_COLOR:-}" == "1" ]] && _HAS_COLOR=false

# ── Colors ────────────────────────────────────────────────────────────────────
if $_HAS_COLOR; then
  RED='\033[0;31m';    GREEN='\033[0;32m';  YELLOW='\033[1;33m'
  BLUE='\033[0;34m';   CYAN='\033[0;36m';   MAGENTA='\033[0;35m'
  BOLD='\033[1m';      DIM='\033[2m';        RESET='\033[0m'
  ORANGE='\033[38;5;214m'; PURPLE='\033[38;5;141m'; TEAL='\033[38;5;43m'
  BG_DARK='\033[48;5;235m'; WHITE='\033[1;37m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''
  BOLD=''; DIM=''; RESET=''; ORANGE=''; PURPLE=''; TEAL=''
  BG_DARK=''; WHITE=''
fi

# ── Box-drawing chars ─────────────────────────────────────────────────────────
BX_TL='╔'; BX_TR='╗'; BX_BL='╚'; BX_BR='╝'
BX_H='═'; BX_V='║'; BX_ML='╠'; BX_MR='╣'; BX_MT='╦'; BX_MB='╩'; BX_X='╬'
SL_TL='┌'; SL_TR='┐'; SL_BL='└'; SL_BR='┘'; SL_H='─'; SL_V='│'
DOT_FULL='●'; DOT_EMPTY='○'; ARROW='▶'; CHECK='✓'; CROSS='✗'; WARN='!'
SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

# ── Logging helpers ───────────────────────────────────────────────────────────
_tee_log() { local f="$1"; shift; echo -e "$*" | tee -a "$f" 2>/dev/null || echo -e "$*"; }

info()       { _tee_log "$APPY_LOG" "${GREEN}[${CHECK}]${RESET} $*"; }
warn()       { _tee_log "$APPY_LOG" "${YELLOW}[${WARN}]${RESET} $*"; }
err()        { echo -e "${RED}[${CROSS}]${RESET} $*" | tee -a "$APPY_LOG" 2>/dev/null >&2 || echo -e "${RED}[${CROSS}]${RESET} $*" >&2; }
step()       { _tee_log "$APPY_LOG" "\n${BOLD}${BLUE}${ARROW} $*${RESET}"; }
die()        { err "$*"; exit 1; }
log()        { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$APPY_LOG" 2>/dev/null || true; }
daemon_log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$APPY_DAEMON_LOG" 2>/dev/null || true; }

# ── Spinner ───────────────────────────────────────────────────────────────────
# Usage: spin_start "message"; ...; spin_stop
_SPIN_PID=""
spin_start() {
  local msg="${1:-Working...}"
  (
    local i=0
    while true; do
      printf "\r  ${CYAN}%s${RESET} ${DIM}%s${RESET}  " \
        "${SPINNER_FRAMES[$((i % ${#SPINNER_FRAMES[@]}))]}" "$msg"
      sleep 0.1
      (( i++ )) || true
    done
  ) &
  _SPIN_PID=$!
}
spin_stop() {
  if [[ -n "$_SPIN_PID" ]]; then
    kill "$_SPIN_PID" 2>/dev/null || true
    wait "$_SPIN_PID" 2>/dev/null || true
    _SPIN_PID=""
    printf "\r%*s\r" 60 ""   # clear the line
  fi
}
trap spin_stop EXIT INT TERM

# ── Init directories ──────────────────────────────────────────────────────────
init_dirs() {
  mkdir -p "$APPY_DIR" /var/log 2>/dev/null || true
  touch "$APPY_LOG" "$APPY_DAEMON_LOG" 2>/dev/null || true
  touch "$APPY_DIR/notifications.log" "$APPY_DIR/install_cache" 2>/dev/null || true
}

# ── Utility helpers ───────────────────────────────────────────────────────────

# Returns the primary LAN IP (not loopback, not docker bridge)
_get_server_ip() {
  ip -o -4 addr show scope global 2>/dev/null \
    | awk '!/docker|br-/{gsub(/\/[0-9]+/,"",$4); print $4; exit}'
}

# Returns "docker compose" (plugin) or "docker-compose" (legacy standalone),
# whichever is available. Dies if neither found.
_docker_compose_cmd() {
  if docker compose version &>/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose &>/dev/null; then
    echo "docker-compose"
  else
    return 1
  fi
}

# Wait up to N seconds for a TCP port to accept connections
_wait_for_port() {
  local host="${1:-localhost}" port="$2" max_secs="${3:-120}" secs=0
  while (( secs < max_secs )); do
    bash -c ">/dev/tcp/${host}/${port}" 2>/dev/null && return 0
    sleep 2
    (( secs += 2 )) || true
  done
  return 1
}

# ── Guards ────────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && {
  echo -e "${RED}[${CROSS}]${RESET} This script must be run as root."
  echo -e "  ${DIM}Try:${RESET}  sudo bash appy.sh"
  exit 1
}
command -v pacman &>/dev/null || {
  echo -e "${RED}[${CROSS}]${RESET} pacman not found — this script is for Arch Linux / CachyOS only."
  exit 1
}
init_dirs
log "appy v$APPY_VERSION started (args: ${*:-none})"

# ── Real user detection ───────────────────────────────────────────────────────
_detect_real_user() {
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    echo "$SUDO_USER"; return
  fi
  local lu
  lu=$(logname 2>/dev/null) && [[ -n "$lu" && "$lu" != "root" ]] && { echo "$lu"; return; }
  local u
  u=$(awk -F: '$3 >= 1000 && $3 < 65534 && ($7 ~ /bash|zsh|sh$/) {print $1; exit}' /etc/passwd 2>/dev/null)
  echo "${u:-root}"
}
REAL_USER=$(_detect_real_user)

# ── Terminal width ────────────────────────────────────────────────────────────
_tw() { tput cols 2>/dev/null || echo 80; }

# ── AUR helper ────────────────────────────────────────────────────────────────
ensure_yay() {
  command -v yay &>/dev/null && return 0
  step "Installing yay (AUR helper) — needed for some packages"
  info "yay lets us install software from the Arch User Repository (AUR)."
  pacman -S --noconfirm --needed git base-devel || die "Failed to install build dependencies"
  local tmp="/tmp/yay-install-$$"
  rm -rf "$tmp"
  sudo -u "$REAL_USER" git clone https://aur.archlinux.org/yay-bin.git "$tmp" \
    || die "Failed to clone yay repository"
  (cd "$tmp" && sudo -u "$REAL_USER" makepkg -si --noconfirm) \
    || die "Failed to build yay"
  rm -rf "$tmp"
  command -v yay &>/dev/null || die "yay installation failed — check internet connection"
  info "yay installed successfully"
}

# ── Package wrappers ──────────────────────────────────────────────────────────
pac() {
  local pkgs=()
  read -ra pkgs <<< "$*"
  spin_start "Installing ${pkgs[0]}..."
  pacman -S --noconfirm --needed "${pkgs[@]}" 2>&1 | tee -a "$APPY_LOG" > /dev/null || true
  spin_stop
}

aur() {
  ensure_yay
  local pkgs=()
  read -ra pkgs <<< "$*"
  spin_start "Installing ${pkgs[0]} from AUR..."
  sudo -u "$REAL_USER" yay -S --noconfirm --needed "${pkgs[@]}" 2>&1 | tee -a "$APPY_LOG" > /dev/null || true
  spin_stop
}

enable_svc() {
  local svc_name="$1"
  if systemctl enable --now "$svc_name" 2>/dev/null; then
    info "Service started: $svc_name"
  else
    warn "Could not auto-start '$svc_name' — check with:  systemctl status $svc_name"
  fi
}

# ── Installed check cache (speed optimization) ────────────────────────────────
# Cache pacman -Qi results for the session to avoid repeated slow calls
declare -A _PKG_CACHE=()

_is_pkg_installed() {
  local pkg="$1"
  if [[ -n "${_PKG_CACHE[$pkg]+_}" ]]; then
    [[ "${_PKG_CACHE[$pkg]}" == "1" ]]
    return
  fi
  if pacman -Qi "$pkg" &>/dev/null 2>&1; then
    _PKG_CACHE[$pkg]="1"; return 0
  else
    _PKG_CACHE[$pkg]="0"; return 1
  fi
}

_invalidate_pkg_cache() { _PKG_CACHE=(); }

# ── Service definitions ───────────────────────────────────────────────────────
# FORMAT: "display name|category|install_type|package(s)|systemd-service|port|desc"
# install_type: pac | aur | curl | docker
declare -A S=(
  # Containers & Web
  [docker]="Docker|containers|pac|docker|docker|unix socket|Run applications in isolated containers"
  [compose]="Docker Compose|containers|pac|docker-compose|-|-|Define multi-container apps with a YAML file"
  [nginx]="Nginx|web|pac|nginx|nginx|80/443|High-performance web server and reverse proxy"
  [caddy]="Caddy|web|pac|caddy|caddy|80/443|Web server with automatic HTTPS — no SSL config needed"
  [portainer]="Portainer|containers|docker|-|-|9443|Visual web UI to manage your Docker containers"
  # Databases
  [mariadb]="MariaDB|database|pac|mariadb|mariadb|3306|Drop-in MySQL replacement — great for web apps"
  [postgres]="PostgreSQL|database|pac|postgresql|postgresql|5432|Advanced open-source relational database"
  [redis]="Redis|database|pac|redis|redis|6379|Lightning-fast in-memory key-value store / cache"
  [sqlite]="SQLite|database|pac|sqlite|-|-|Lightweight file-based database (no server needed)"
  [mongodb]="MongoDB|database|aur|mongodb-bin|mongodb|27017|Flexible NoSQL document database"
  # Security & Networking
  [fail2ban]="Fail2ban|security|pac|fail2ban|fail2ban|-|Blocks IPs after repeated failed login attempts"
  [ufw]="UFW Firewall|security|pac|ufw|ufw|-|Simple firewall — deny all inbound except SSH"
  [wireguard]="WireGuard|security|pac|wireguard-tools|-|-|Fast, modern VPN — great for remote access"
  [tailscale]="Tailscale|security|pac|tailscale|tailscaled|-|Zero-config mesh VPN — works through NAT"
  [vaultwarden]="Vaultwarden|security|docker|-|-|8222|Self-hosted Bitwarden password manager"
  [crowdsec]="CrowdSec|security|pac|crowdsec|crowdsec|-|Community-powered intrusion prevention system"
  # Media & Files
  [jellyfin]="Jellyfin|media|aur|jellyfin|jellyfin|8096|Stream your movies, TV shows & music anywhere"
  [immich]="Immich|media|docker|-|-|2283|Self-hosted Google Photos alternative — AI-powered"
  [samba]="Samba|media|pac|samba|smb|-|Share files & printers on your local network"
  [syncthing]="Syncthing|media|pac|syncthing|syncthing|8384|Peer-to-peer file sync — no cloud needed"
  # Monitoring & Observability
  [btop]="btop|monitoring|pac|btop|-|-|Beautiful terminal resource monitor (CPU/RAM/disk)"
  [htop]="htop|monitoring|pac|htop|-|-|Interactive process viewer for the terminal"
  [netdata]="Netdata|monitoring|pac|netdata|netdata|19999|Real-time performance monitoring dashboard"
  [prometheus]="Prometheus|monitoring|pac|prometheus|prometheus|9090|Metrics collection and alerting"
  [grafana]="Grafana|monitoring|pac|grafana|grafana|3000|Beautiful dashboards for your metrics"
  [uptime_kuma]="Uptime Kuma|monitoring|docker|-|-|3001|Monitor uptime of websites and services"
  [cockpit]="Cockpit|monitoring|pac|cockpit|cockpit|9090|Web-based server admin panel"
  [loki]="Loki|monitoring|pac|loki|loki|3100|Log aggregation (works with Grafana)"
  # Development Tools
  [git]="Git|dev|pac|git|-|-|Version control system — essential for any developer"
  [neovim]="Neovim|dev|pac|neovim|-|-|Extensible terminal text editor"
  [zsh]="Zsh + Oh-My-Zsh|dev|pac|zsh|-|-|Powerful shell with plugins and themes"
  [node]="Node.js + npm|dev|pac|nodejs npm|-|-|JavaScript runtime for web servers and tools"
  [python]="Python 3 + pip|dev|pac|python python-pip|-|-|Versatile scripting language with huge ecosystem"
  [golang]="Go|dev|pac|go|-|-|Fast compiled language by Google"
  [rust]="Rust|dev|pac|rustup|-|-|Memory-safe systems language"
  [docker_buildx]="Docker Buildx|dev|pac|docker-buildx|-|-|Build multi-platform Docker images"
  # AI & Other
  [ollama]="Ollama|ai|curl|-|-|11434|Run AI language models locally (LLaMA, Mistral...)"
  [pihole]="Pi-hole|other|curl|-|-|80|Network-wide ad blocker — blocks ads for all devices"
  [timeshift]="Timeshift|other|aur|timeshift|-|-|System snapshot and restore tool"
  [restic]="Restic|other|pac|restic|-|-|Fast, encrypted, deduplicated backups"
)

# Ordered list for menu display (grouped)
KEYS=(
  docker compose nginx caddy portainer
  mariadb postgres redis sqlite mongodb
  fail2ban ufw wireguard tailscale vaultwarden crowdsec
  jellyfin immich samba syncthing
  btop htop netdata prometheus grafana uptime_kuma cockpit loki
  git neovim zsh node python golang rust docker_buildx
  ollama pihole timeshift restic
)

# ── Post-install info cards ───────────────────────────────────────────────────
# Each card is shown after a successful install. Beginner-friendly.

_print_info_card() {
  local title="$1"
  local -a lines=("${@:2}")
  local tw
  tw=$(_tw)
  local w=$(( tw - 6 ))
  [[ $w -gt 70 ]] && w=70
  [[ $w -lt 40 ]] && w=40

  local bar
  bar=$(printf '%0.s─' $(seq 1 $w))
  echo ""
  echo -e "  ${TEAL}${SL_TL}${bar}${SL_TR}${RESET}"
  printf "  ${TEAL}${SL_V}${RESET}  ${BOLD}${WHITE}%-*s${RESET}${TEAL}${SL_V}${RESET}\n" "$(( w - 2 ))" "  $title"
  echo -e "  ${TEAL}├${bar}┤${RESET}"
  local line
  for line in "${lines[@]}"; do
    printf "  ${TEAL}${SL_V}${RESET}  %-*s${TEAL}${SL_V}${RESET}\n" "$(( w - 2 ))" "$line"
  done
  echo -e "  ${TEAL}${SL_BL}${bar}${SL_BR}${RESET}"
  echo ""
}

# ── Post-install hooks ────────────────────────────────────────────────────────

post_docker() {
  usermod -aG docker "$REAL_USER" 2>/dev/null \
    && info "Added $REAL_USER to the 'docker' group"
  systemctl enable --now docker 2>/dev/null || true
  _print_info_card "🐳  Docker Installed" \
    "You can now run containers without sudo after logging out." \
    "  → Log out and back in, OR run:  newgrp docker" \
    "  → Test it:  docker run hello-world" \
    "  → Manage visually:  install Portainer (option in menu)"
}

post_compose() {
  _print_info_card "🐙  Docker Compose Installed" \
    "Define and run multi-container apps with a single YAML file." \
    "  → Create docker-compose.yml and run:  docker compose up -d" \
    "  → Stop everything:  docker compose down"
}

post_nginx() {
  _print_info_card "🌐  Nginx Installed" \
    "Config file:   /etc/nginx/nginx.conf" \
    "Web root:      /usr/share/nginx/html" \
    "  → Test config:  nginx -t" \
    "  → Reload:       systemctl reload nginx" \
    "  → Access:       http://localhost"
}

post_caddy() {
  _print_info_card "🔒  Caddy Installed" \
    "Caddy automatically gets Let's Encrypt SSL certificates!" \
    "Config file:   /etc/caddy/Caddyfile" \
    "  → Example: echo 'example.com { reverse_proxy localhost:8080 }'" \
    "  → Reload:   systemctl reload caddy" \
    "  → Docs:     https://caddyserver.com/docs"
}

post_postgres() {
  if [[ ! -f /var/lib/postgres/data/PG_VERSION ]]; then
    sudo -u postgres initdb -D /var/lib/postgres/data 2>/dev/null \
      || warn "PostgreSQL initdb failed — may already be initialized"
  fi
  enable_svc postgresql
  _print_info_card "🐘  PostgreSQL Installed" \
    "Port:          5432" \
    "Data dir:      /var/lib/postgres/data" \
    "  → Connect:   sudo -u postgres psql" \
    "  → Create DB: CREATE DATABASE mydb;" \
    "  → Create user: CREATE USER myuser WITH PASSWORD 'secret';"
}

post_mariadb() {
  if [[ ! -d /var/lib/mysql/mysql ]]; then
    mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql &>/dev/null \
      || warn "mariadb-install-db failed"
  fi
  enable_svc mariadb
  local retries=10
  while (( retries-- > 0 )); do
    mysqladmin ping --silent 2>/dev/null && break
    sleep 1
  done
  local pw
  pw=$(openssl rand -base64 16 | tr -d '/+=')
  mysql --user=root --connect-timeout=5 \
    -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${pw}';" 2>/dev/null \
    || warn "Could not set MariaDB root password — run:  mysql_secure_installation"
  {
    printf "=== MariaDB ===\nGenerated: %s\nHost: localhost\nPort: 3306\nRoot password: %s\n\n" "$(date)" "$pw"
  } >> "$CRED_FILE"
  chmod 600 "$CRED_FILE"
  _print_info_card "🗄️   MariaDB (MySQL) Installed" \
    "Port:          3306" \
    "Root password: saved to  ~/appy-credentials.txt" \
    "  → Connect:   mysql -u root -p" \
    "  → Create DB: CREATE DATABASE myapp;" \
    "  → Tip:       Keep credentials file secure — it's chmod 600"
}

post_redis() {
  _print_info_card "⚡  Redis Installed" \
    "Port:          6379  (localhost only by default)" \
    "Config file:   /etc/redis/redis.conf" \
    "  → Connect:   redis-cli" \
    "  → Test:      redis-cli ping   (should return PONG)" \
    "  → Tip:       Great for caching, sessions, and queues"
}

post_ufw() {
  ufw --force reset 2>/dev/null || true
  ufw default deny incoming  2>/dev/null || true
  ufw default allow outgoing 2>/dev/null || true
  ufw allow ssh              2>/dev/null || true
  ufw --force enable         2>/dev/null || true
  _print_info_card "🔥  UFW Firewall Enabled" \
    "Policy:        DENY all inbound (except SSH), ALLOW all outbound" \
    "  → Allow a port:   ufw allow 8080/tcp" \
    "  → Block a port:   ufw deny 3306/tcp" \
    "  → Check status:   ufw status verbose" \
    "  → ⚠  SSH is already allowed — you won't be locked out"
}

post_zsh() {
  if [[ ! -d "/home/$REAL_USER/.oh-my-zsh" ]]; then
    sudo -u "$REAL_USER" env RUNZSH=no CHSH=no \
      sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
      &>/dev/null || warn "Oh-My-Zsh install failed — try manually later"
  else
    info "Oh-My-Zsh already installed"
  fi
  chsh -s /bin/zsh "$REAL_USER" 2>/dev/null \
    || warn "Could not set Zsh as default shell — run:  chsh -s /bin/zsh $REAL_USER"
  _print_info_card "🐚  Zsh + Oh-My-Zsh Installed" \
    "Zsh is now your default shell — log out and back in." \
    "Config file:   ~/.zshrc" \
    "  → Change theme: edit ZSH_THEME in ~/.zshrc (try 'agnoster' or 'robbyrussell')" \
    "  → Add plugin:   add to plugins=(...) in ~/.zshrc" \
    "  → Popular:      git, z, zsh-autosuggestions"
}

post_samba() {
  enable_svc smb
  enable_svc nmb
  _print_info_card "📁  Samba File Sharing Installed" \
    "Config file:   /etc/samba/smb.conf" \
    "  → Add a share: edit smb.conf, then run:  systemctl restart smb nmb" \
    "  → Set password: smbpasswd -a $REAL_USER" \
    "  → Connect from Windows: \\\\$(hostname)\\sharename" \
    "  → Connect from Linux:   smb://$(hostname)/sharename"
}

post_syncthing() {
  systemctl enable --now "syncthing@${REAL_USER}.service" 2>/dev/null \
    || warn "Could not start syncthing — run:  systemctl enable --now syncthing@$REAL_USER"
  _print_info_card "🔄  Syncthing Installed" \
    "Web UI:        http://localhost:8384" \
    "  → Open the web UI and add folders to sync" \
    "  → Install Syncthing on other devices to sync between them" \
    "  → Data stays on YOUR hardware — no cloud involved"
}

post_rust() {
  sudo -u "$REAL_USER" rustup default stable 2>/dev/null \
    || warn "rustup default stable failed — run:  rustup default stable"
  _print_info_card "🦀  Rust Installed" \
    "  → Check version:  rustc --version" \
    "  → New project:    cargo new myproject && cd myproject && cargo run" \
    "  → Update Rust:    rustup update" \
    "  → Docs:           https://doc.rust-lang.org/book/"
}

post_prometheus() {
  if [[ ! -f /etc/prometheus/prometheus.yml ]]; then
    mkdir -p /etc/prometheus
    cat > /etc/prometheus/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node'
    static_configs:
      - targets: ['localhost:9100']
EOF
  fi
  pac prometheus-node-exporter 2>/dev/null || true
  enable_svc prometheus-node-exporter
  _print_info_card "📊  Prometheus Installed" \
    "Web UI:        http://localhost:9090" \
    "Config file:   /etc/prometheus/prometheus.yml" \
    "  → Node Exporter (host metrics) also installed on port 9100" \
    "  → Add Grafana for beautiful dashboards (install it from the menu)" \
    "  → Reload config:  systemctl reload prometheus"
}

post_grafana() {
  local cfg="/etc/grafana/grafana.ini"
  local pw
  pw="appy_$(openssl rand -hex 6)"
  if [[ -f "$cfg" ]]; then
    sed -i "s|^;*admin_password\s*=.*|admin_password = ${pw}|" "$cfg" 2>/dev/null || true
  fi
  {
    printf "=== Grafana ===\nGenerated: %s\nURL: http://localhost:3000\nAdmin user: admin\nAdmin password: %s\n\n" \
      "$(date)" "$pw"
  } >> "$CRED_FILE"
  chmod 600 "$CRED_FILE"
  _print_info_card "📈  Grafana Installed" \
    "Web UI:        http://localhost:3000" \
    "Admin user:    admin" \
    "Admin pass:    saved to  ~/appy-credentials.txt" \
    "  → Add Prometheus as data source: http://localhost:9090" \
    "  → Import dashboards from grafana.com (try ID 1860 for Node Exporter)"
}

post_netdata() {
  _print_info_card "📡  Netdata Installed" \
    "Web UI:        http://localhost:19999  (opens instantly — no config needed)" \
    "  → Shows CPU, RAM, disk, network, processes in real time" \
    "  → No agent needed — just open the URL in your browser" \
    "  → Config dir:  /etc/netdata"
}

post_cockpit() {
  if ufw status 2>/dev/null | grep -q "active"; then
    ufw allow 9090/tcp 2>/dev/null || true
  fi
  _print_info_card "🖥️   Cockpit Web Admin Installed" \
    "Web UI:        https://localhost:9090" \
    "  → Login with your Linux username and password" \
    "  → Manage services, storage, networking, and updates from browser" \
    "  → Great for beginners who prefer a GUI over the terminal"
}

post_mongodb() {
  {
    printf "=== MongoDB ===\nGenerated: %s\nHost: localhost\nPort: 27017\nNote: Run 'mongosh' to configure auth\n\n" "$(date)"
  } >> "$CRED_FILE"
  chmod 600 "$CRED_FILE"
  _print_info_card "🍃  MongoDB Installed" \
    "Port:          27017" \
    "  → Connect:   mongosh" \
    "  → Create DB: use mydb" \
    "  → ⚠  Set up authentication before exposing to network!" \
    "  → Docs:      https://www.mongodb.com/docs/manual/"
}

post_crowdsec() {
  sleep 2
  cscli collections install crowdsecurity/linux 2>/dev/null || true
  cscli collections install crowdsecurity/sshd  2>/dev/null || true
  _print_info_card "🛡️   CrowdSec Installed" \
    "Installed collections: linux, sshd" \
    "  → View alerts:      cscli alerts list" \
    "  → View decisions:   cscli decisions list" \
    "  → Add collection:   cscli collections install crowdsecurity/nginx" \
    "  → Dashboard:        https://app.crowdsec.net (free, optional)"
}

post_tailscale() {
  _print_info_card "🌐  Tailscale VPN Installed" \
    "  → Authenticate:  tailscale up" \
    "  → Check status:  tailscale status" \
    "  → Your devices will get 100.x.x.x addresses (Tailscale network)" \
    "  → Works through firewalls and NAT — no port forwarding needed" \
    "  → Sign up free at: https://tailscale.com"
}

post_wireguard() {
  _print_info_card "🔐  WireGuard VPN Installed" \
    "Config dir:    /etc/wireguard/" \
    "  → Generate keys:  wg genkey | tee privatekey | wg pubkey > publickey" \
    "  → Example config: https://www.wireguard.com/quickstart/" \
    "  → Start tunnel:   wg-quick up wg0" \
    "  → Tip: Consider Tailscale (in menu) for easier zero-config VPN"
}

post_fail2ban() {
  _print_info_card "🚫  Fail2ban Installed" \
    "Config dir:    /etc/fail2ban/" \
    "  → View banned IPs:  fail2ban-client status sshd" \
    "  → Unban an IP:      fail2ban-client unban <ip>" \
    "  → Custom rules:     create /etc/fail2ban/jail.local" \
    "  → SSH protection is active by default"
}

post_loki() {
  if [[ ! -f /etc/loki/loki.yaml ]]; then
    mkdir -p /etc/loki /var/lib/loki/index /var/lib/loki/index_cache /var/lib/loki/chunks
    cat > /etc/loki/loki.yaml <<'EOF'
auth_enabled: false
server:
  http_listen_port: 3100
ingester:
  lifecycler:
    ring:
      kvstore:
        store: inmemory
      replication_factor: 1
schema_config:
  configs:
    - from: 2024-01-01
      store: boltdb-shipper
      object_store: filesystem
      schema: v11
      index:
        prefix: index_
        period: 24h
storage_config:
  boltdb_shipper:
    active_index_directory: /var/lib/loki/index
    cache_location: /var/lib/loki/index_cache
  filesystem:
    directory: /var/lib/loki/chunks
limits_config:
  reject_old_samples: true
  reject_old_samples_max_age: 168h
EOF
    id loki &>/dev/null && chown -R loki:loki /var/lib/loki /etc/loki 2>/dev/null || true
  fi
  _print_info_card "📋  Loki Log Aggregation Installed" \
    "Port:          3100" \
    "Config file:   /etc/loki/loki.yaml" \
    "  → Install Promtail to ship logs:  yay -S promtail" \
    "  → Add Loki as Grafana data source: http://localhost:3100" \
    "  → Then query logs in Grafana's Explore view"
}

post_restic() {
  cat > /usr/local/bin/appy-backup <<'BKUP'
#!/usr/bin/env bash
# appy-backup: restic backup helper
set -uo pipefail
CMD="${1:-help}"
REPO="${2:-/var/backups/restic}"
SOURCE="${3:-/home}"
case "$CMD" in
  init)    restic init --repo "$REPO" ;;
  backup)
    restic backup --repo "$REPO" "$SOURCE" --exclude-caches
    restic forget --repo "$REPO" --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
    echo "Backup complete. Old snapshots pruned."
    ;;
  restore)
    echo "Available snapshots:"
    restic snapshots --repo "$REPO"
    ;;
  *)
    echo "Usage: appy-backup [init|backup|restore] [repo] [source]"
    ;;
esac
BKUP
  chmod +x /usr/local/bin/appy-backup
  _print_info_card "💾  Restic Backups Installed" \
    "Helper script: /usr/local/bin/appy-backup" \
    "  → Init repo:    appy-backup init /var/backups/myrepo" \
    "  → Backup:       appy-backup backup /var/backups/myrepo /home" \
    "  → View snaps:   appy-backup restore /var/backups/myrepo" \
    "  → Encrypts everything — set RESTIC_PASSWORD env var for automation"
}

post_btop() {
  _print_info_card "📊  btop Installed" \
    "  → Launch:  btop" \
    "  → Shows CPU, memory, disk I/O, network, and processes beautifully" \
    "  → Press F1 for help inside btop"
}

post_htop() {
  _print_info_card "📊  htop Installed" \
    "  → Launch:  htop" \
    "  → Interactive process viewer — press F1 for help"
}

post_git() {
  _print_info_card "🔀  Git Installed" \
    "  → Set your name:   git config --global user.name 'Your Name'" \
    "  → Set your email:  git config --global user.email 'you@example.com'" \
    "  → Init a repo:     git init && git add . && git commit -m 'first commit'" \
    "  → Clone a repo:    git clone https://github.com/user/repo"
}

post_neovim() {
  _print_info_card "📝  Neovim Installed" \
    "  → Launch:  nvim filename.txt" \
    "  → Exit:    press Esc, then type :q! and Enter" \
    "  → Tip:     consider LazyVim for a full IDE: https://www.lazyvim.org"
}

post_node() {
  _print_info_card "🟢  Node.js + npm Installed" \
    "  → Check version:  node --version && npm --version" \
    "  → Run a script:   node app.js" \
    "  → Install package: npm install express" \
    "  → Tip:            use 'nvm' for managing multiple Node versions"
}

post_python() {
  _print_info_card "🐍  Python 3 Installed" \
    "  → Check version:  python3 --version" \
    "  → Run script:     python3 script.py" \
    "  → Install pkg:    pip3 install requests" \
    "  → Virtual env:    python3 -m venv venv && source venv/bin/activate"
}

post_golang() {
  _print_info_card "🐹  Go Installed" \
    "  → Check version:  go version" \
    "  → New project:    mkdir myapp && cd myapp && go mod init myapp" \
    "  → Run code:       go run main.go" \
    "  → Build binary:   go build -o myapp"
}

post_ollama() {
  _print_info_card "🤖  Ollama (Local AI) Installed" \
    "API:           http://localhost:11434" \
    "  → Pull a model:   ollama pull llama3" \
    "  → Chat in terminal: ollama run llama3" \
    "  → List models:    ollama list" \
    "  → Models stored at: ~/.ollama/models   (can be several GB each)"
}

post_pihole() {
  _print_info_card "🕳️   Pi-hole Installed" \
    "  → Set your router's DNS to this machine's IP address" \
    "  → Admin panel: http://$(hostname)/admin" \
    "  → All devices on your network will have ads blocked!" \
    "  → Update block lists: pihole -g"
}

post_timeshift() {
  _print_info_card "⏰  Timeshift Installed" \
    "  → Launch GUI:   timeshift-gtk    (if desktop environment present)" \
    "  → CLI snapshot: timeshift --create --comments 'before update'" \
    "  → Restore:      timeshift --restore" \
    "  → Tip:          great to run before major system updates"
}

post_jellyfin() {
  _print_info_card "🎬  Jellyfin Media Server Installed" \
    "Web UI:        http://localhost:8096  (finish setup there)" \
    "  → Point it at your media folder during setup" \
    "  → Mobile apps available for iOS and Android (free)" \
    "  → Compatible with Infuse, Kodi, and more clients"
}

# ── Docker-based service installers ──────────────────────────────────────────

ensure_docker_running() {
  if ! command -v docker &>/dev/null; then
    warn "Docker not found — installing it first..."
    do_install docker
  fi
  systemctl start docker 2>/dev/null || true
  local i=0
  while (( i < 15 )); do
    docker info &>/dev/null 2>&1 && return 0
    sleep 1
    (( i++ )) || true
  done
  warn "Docker socket not ready — containers may not start"
}

install_portainer() {
  ensure_docker_running
  docker volume create portainer_data 2>/dev/null || true
  if docker inspect portainer &>/dev/null 2>&1; then
    docker start portainer 2>/dev/null || true
    info "Portainer container already exists — started"
  else
    spin_start "Pulling Portainer image..."
    docker run -d \
      --name=portainer \
      --restart=always \
      -p 8000:8000 -p 9443:9443 \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v portainer_data:/data \
      portainer/portainer-ce:latest &>/dev/null
    spin_stop
  fi
  _print_info_card "🐳  Portainer Docker UI Installed" \
    "Web UI:        https://localhost:9443  (accept the self-signed cert)" \
    "  → Create your admin account on first visit" \
    "  → View, start, stop, and inspect containers from a browser" \
    "  → Port 8000 is the agent port — can be closed if not using agents"
}

install_vaultwarden() {
  ensure_docker_running
  local vw_data="/var/lib/vaultwarden"
  mkdir -p "$vw_data"
  chmod 700 "$vw_data"   # Harden: owner-only access
  local admin_token
  admin_token=$(openssl rand -base64 48 | tr -d '\n/+=')
  if docker inspect vaultwarden &>/dev/null 2>&1; then
    docker start vaultwarden 2>/dev/null || true
    info "Vaultwarden container already exists — started"
  else
    spin_start "Pulling Vaultwarden image..."
    docker run -d \
      --name=vaultwarden \
      --restart=always \
      -p 127.0.0.1:8222:80 \
      -v "${vw_data}:/data" \
      -e ADMIN_TOKEN="$admin_token" \
      -e WEBSOCKET_ENABLED=true \
      -e SIGNUPS_ALLOWED=true \
      vaultwarden/server:latest &>/dev/null
    spin_stop
    {
      printf "=== Vaultwarden ===\nGenerated: %s\nURL: http://localhost:8222\nAdmin token: %s\nAdmin panel: http://localhost:8222/admin\n\n" \
        "$(date)" "$admin_token"
    } >> "$CRED_FILE"
    chmod 600 "$CRED_FILE"
  fi
  _print_info_card "🔑  Vaultwarden Password Manager Installed" \
    "Web UI:        http://localhost:8222" \
    "Admin panel:   http://localhost:8222/admin" \
    "Admin token:   saved to  ~/appy-credentials.txt" \
    "  → ⚠  Put Vaultwarden behind HTTPS (Caddy/Nginx) before real use" \
    "  → Bitwarden browser extension works with Vaultwarden" \
    "  → Bound to 127.0.0.1 for safety — use reverse proxy to expose"
}

install_uptime_kuma() {
  ensure_docker_running
  docker volume create uptime-kuma 2>/dev/null || true
  if docker inspect uptime-kuma &>/dev/null 2>&1; then
    docker start uptime-kuma 2>/dev/null || true
    info "Uptime Kuma container already exists — started"
  else
    spin_start "Pulling Uptime Kuma image..."
    docker run -d \
      --name=uptime-kuma \
      --restart=always \
      -p 127.0.0.1:3001:3001 \
      -v uptime-kuma:/app/data \
      louislam/uptime-kuma:latest &>/dev/null
    spin_stop
  fi
  _print_info_card "⏱️   Uptime Kuma Installed" \
    "Web UI:        http://localhost:3001" \
    "  → Create your admin account on first visit" \
    "  → Monitor websites, TCP ports, DNS, Docker containers, and more" \
    "  → Get alerts via Telegram, Slack, email, and 90+ other channels"
}

# ── Immich installer (official quickstart method) ─────────────────────────────
install_immich() {
  ensure_docker_running

  # Need 'docker compose' plugin or legacy 'docker-compose'
  local dc_cmd
  if ! dc_cmd=$(_docker_compose_cmd); then
    warn "Neither 'docker compose' plugin nor 'docker-compose' found."
    warn "Installing docker-compose via pacman..."
    pac docker-compose
    if ! dc_cmd=$(_docker_compose_cmd); then
      err "Could not find a working Docker Compose — aborting Immich install."
      return 1
    fi
  fi
  info "Using compose command: $dc_cmd"

  local immich_dir="/var/lib/immich"
  local upload_dir="${immich_dir}/library"
  local db_dir="${immich_dir}/postgres"
  local env_file="${immich_dir}/.env"
  local compose_file="${immich_dir}/docker-compose.yml"

  # ── Skip if already running ──────────────────────────────────────────────
  if [[ -f "$compose_file" ]]; then
    echo ""
    echo -e "  ${YELLOW}[!] Immich compose file already found at ${compose_file}${RESET}"
    echo -e "  ${DIM}Immich may already be installed. What would you like to do?${RESET}"
    echo ""
    echo "   1) Start / restart the existing stack"
    echo "   2) Re-download files and reinstall (overwrites existing config!)"
    echo "   3) Cancel"
    echo ""
    read -rp "  Choice: " _immich_choice
    case "${_immich_choice}" in
      1)
        spin_start "Starting existing Immich stack..."
        ( cd "$immich_dir" && $dc_cmd up -d 2>&1 | tee -a "$APPY_LOG" > /dev/null ) || true
        spin_stop
        _immich_show_info_card "$immich_dir" "$upload_dir" "$dc_cmd"
        return 0
        ;;
      2) info "Proceeding with fresh install..." ;;
      *) info "Cancelled."; return 0 ;;
    esac
  fi

  mkdir -p "$upload_dir" "$db_dir"
  chmod 750 "$immich_dir"

  # ── Download official compose + env from Immich GitHub releases ─────────
  echo ""
  echo -e "  ${BOLD}Downloading official Immich files from GitHub...${RESET}"
  echo -e "  ${DIM}(This uses the exact files from immich.app/docs/install/docker-compose)${RESET}"
  echo ""

  spin_start "Downloading docker-compose.yml..."
  if ! curl -fsSL \
      "https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml" \
      -o "$compose_file" 2>&1 | tee -a "$APPY_LOG" > /dev/null; then
    spin_stop
    err "Failed to download Immich docker-compose.yml — check internet connection."
    return 1
  fi
  spin_stop
  info "docker-compose.yml downloaded"

  spin_start "Downloading example .env..."
  if ! curl -fsSL \
      "https://github.com/immich-app/immich/releases/latest/download/example.env" \
      -o "$env_file" 2>&1 | tee -a "$APPY_LOG" > /dev/null; then
    spin_stop
    err "Failed to download Immich example.env — check internet connection."
    return 1
  fi
  spin_stop
  info ".env template downloaded"

  # ── Patch .env with our paths and generated secrets ───────────────────────
  local db_pass
  db_pass=$(openssl rand -base64 24 | tr -d '\n/+=')

  # UPLOAD_LOCATION
  if grep -q "^UPLOAD_LOCATION=" "$env_file" 2>/dev/null; then
    sed -i "s|^UPLOAD_LOCATION=.*|UPLOAD_LOCATION=${upload_dir}|" "$env_file"
  else
    echo "UPLOAD_LOCATION=${upload_dir}" >> "$env_file"
  fi

  # DB_DATA_LOCATION (newer official env)
  if grep -q "^DB_DATA_LOCATION=" "$env_file" 2>/dev/null; then
    sed -i "s|^DB_DATA_LOCATION=.*|DB_DATA_LOCATION=${db_dir}|" "$env_file"
  else
    echo "DB_DATA_LOCATION=${db_dir}" >> "$env_file"
  fi

  # DB_PASSWORD — replace the placeholder in the official env
  if grep -q "^DB_PASSWORD=" "$env_file" 2>/dev/null; then
    sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${db_pass}|" "$env_file"
  else
    echo "DB_PASSWORD=${db_pass}" >> "$env_file"
  fi

  chmod 600 "$env_file"
  info ".env configured with generated secrets"

  # ── Pull images ───────────────────────────────────────────────────────────
  echo ""
  echo -e "  ${YELLOW}[!] First-time image pull can take 5–15 minutes depending on connection.${RESET}"
  echo -e "  ${DIM}    Pulling: immich-server, machine-learning, postgresql, redis...${RESET}"
  echo ""
  spin_start "Pulling Immich images (please wait)..."
  ( cd "$immich_dir" && $dc_cmd pull 2>&1 | tee -a "$APPY_LOG" > /dev/null ) || true
  spin_stop
  info "Images pulled"

  # ── Start the stack ───────────────────────────────────────────────────────
  spin_start "Starting Immich containers..."
  ( cd "$immich_dir" && $dc_cmd up -d 2>&1 | tee -a "$APPY_LOG" > /dev/null ) || true
  spin_stop

  # ── Install systemd unit so Immich restarts on reboot ─────────────────────
  _immich_install_systemd_unit "$immich_dir" "$dc_cmd"

  # ── Wait for web UI to respond ─────────────────────────────────────────────
  echo ""
  echo -e "  ${CYAN}Waiting for Immich web UI to come online (up to 2 minutes)...${RESET}"
  if _wait_for_port localhost 2283 120; then
    info "Immich web UI is UP and responding on port 2283"
  else
    warn "Port 2283 not responding yet — containers may still be initialising."
    warn "Wait 1-2 more minutes and then try the URL below."
  fi

  # ── Save credentials ───────────────────────────────────────────────────────
  local server_ip
  server_ip=$(_get_server_ip)
  {
    printf "=== Immich ===\nGenerated: %s\nLocal URL:    http://localhost:2283\nNetwork URL:  http://%s:2283\nUpload dir:   %s\nDB dir:       %s\nDB password:  %s\nCompose file: %s\nEnv file:     %s\n\n" \
      "$(date)" "${server_ip:-<your-ip>}" "$upload_dir" "$db_dir" \
      "$db_pass" "$compose_file" "$env_file"
  } >> "$CRED_FILE"
  chmod 600 "$CRED_FILE"

  _immich_show_info_card "$immich_dir" "$upload_dir" "$dc_cmd"
}

# ── Immich: install systemd service for autostart ─────────────────────────────
_immich_install_systemd_unit() {
  local immich_dir="$1"
  local dc_cmd="$2"

  # Resolve the compose binary path for ExecStart
  local dc_bin
  if [[ "$dc_cmd" == "docker compose" ]]; then
    dc_bin="/usr/bin/docker compose"
  else
    dc_bin=$(command -v docker-compose 2>/dev/null || echo "docker-compose")
  fi

  cat > /etc/systemd/system/immich.service <<EOF
[Unit]
Description=Immich — Self-hosted photo & video backup
Documentation=https://immich.app
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${immich_dir}
ExecStart=${dc_bin} up -d --remove-orphans
ExecStop=${dc_bin} down
TimeoutStartSec=300
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable immich.service 2>/dev/null \
    && info "Immich systemd service installed → will auto-start on reboot" \
    || warn "Could not enable Immich systemd service"
}

# ── Immich: post-install info card ────────────────────────────────────────────
_immich_show_info_card() {
  local immich_dir="$1"
  local upload_dir="$2"
  local dc_cmd="$3"
  local server_ip
  server_ip=$(_get_server_ip)

  _print_info_card "📷  Immich Photo Manager" \
    "Local URL:     http://localhost:2283" \
    "Network URL:   http://${server_ip:-<your-server-ip>}:2283" \
    "Upload dir:    ${upload_dir}" \
    "Compose dir:   ${immich_dir}" \
    "" \
    "  → Open the URL above in your browser to create your admin account" \
    "  → If 'connection refused', wait ~2 min for containers to finish starting" \
    "  → Then press Ctrl+C if nothing loads and run:" \
    "       cd ${immich_dir} && ${dc_cmd} logs --tail=20" \
    "" \
    "  → Auto-starts on reboot via systemd (immich.service)" \
    "  → Mobile app: search 'Immich' on App Store / Google Play" \
    "  → Credentials saved to: ~/appy-credentials.txt" \
    "" \
    "  Useful commands:" \
    "    cd ${immich_dir} && ${dc_cmd} ps        (show container status)" \
    "    cd ${immich_dir} && ${dc_cmd} logs -f   (follow logs)" \
    "    cd ${immich_dir} && ${dc_cmd} down       (stop Immich)" \
    "    systemctl status immich                  (systemd status)"
}

# ── Curl-based installers ─────────────────────────────────────────────────────

install_ollama() {
  if command -v ollama &>/dev/null; then
    info "Ollama already installed"
  else
    spin_start "Installing Ollama..."
    curl -fsSL https://ollama.ai/install.sh | sh 2>&1 | tee -a "$APPY_LOG" > /dev/null \
      || die "Ollama installation failed — check internet connection"
    spin_stop
  fi
  enable_svc ollama
  post_ollama
}

install_pihole() {
  warn "Pi-hole requires port 53 to be free."
  warn "If systemd-resolved is running, it must be disabled first."
  echo ""
  read -rp "  Continue with Pi-hole installation? [y/N]: " _pihole_yn
  [[ "${_pihole_yn,,}" == "y" ]] || { info "Pi-hole installation cancelled."; return 0; }
  curl -sSL https://install.pi-hole.net | bash
  post_pihole
}

# ── Core install dispatcher ───────────────────────────────────────────────────
do_install() {
  local key="$1"
  local spec="${S[$key]:-}"
  if [[ -z "$spec" ]]; then
    err "Unknown service key: '$key'"
    err "Available keys:  ${KEYS[*]}"
    return 1
  fi

  local display category type pkg service port desc
  IFS='|' read -r display category type pkg service port desc <<< "$spec"

  step "Installing $display"
  log "Installing: $key ($display)"

  # Skip if already installed (pac/aur only)
  if [[ "$type" =~ ^(pac|aur)$ && "$pkg" != "-" ]]; then
    local first_pkg
    first_pkg=$(awk '{print $1}' <<< "$pkg")
    if _is_pkg_installed "$first_pkg"; then
      info "$display is already installed — skipping"
      # Still show info card on re-visit
      local post_fn="post_${key}"
      declare -f "$post_fn" &>/dev/null && "$post_fn"
      return 0
    fi
  fi

  # Docker: check container
  if [[ "$type" == "docker" ]]; then
    if docker inspect "${key//_/-}" &>/dev/null 2>&1; then
      info "$display container already exists — ensuring it's running"
      local fn="install_${key}"
      declare -f "$fn" &>/dev/null && "$fn"
      return 0
    fi
  fi

  # Install
  case "$type" in
    pac)  pac "$pkg" ;;
    aur)  aur "$pkg" ;;
    curl|docker)
      local fn="install_${key}"
      if declare -f "$fn" &>/dev/null; then
        "$fn"
      else
        err "No installer function found for: $key (expected: $fn)"
        return 1
      fi
      ;;
    *)
      err "Unknown install type '$type' for $key"
      return 1
      ;;
  esac

  # Enable systemd service
  if [[ "$type" =~ ^(pac|aur)$ && "$service" != "-" ]]; then
    enable_svc "$service"
  fi

  # Run post-install hook (shows info card)
  local post_fn="post_${key}"
  if declare -f "$post_fn" &>/dev/null; then
    "$post_fn"
  fi

  # Invalidate pkg cache after install
  _invalidate_pkg_cache

  log "Installed: $key"
  info "${display} installed successfully."
}

# ══════════════════════════════════════════════════════════════════════════════
# ── DAEMON / WATCHDOG MODE ────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════

DAEMON_INTERVAL="${APPY_DAEMON_INTERVAL:-300}"
NOTIFY_EMAIL="${APPY_NOTIFY_EMAIL:-}"

get_watched_services() {
  local svc_name
  for key in "${KEYS[@]}"; do
    local spec="${S[$key]:-}"
    [[ -z "$spec" ]] && continue
    IFS='|' read -r _ _ _ _ svc_name _ _ <<< "$spec"
    [[ "$svc_name" == "-" ]] && continue
    if systemctl list-unit-files "${svc_name}.service" &>/dev/null 2>&1 \
       && systemctl is-enabled "$svc_name" &>/dev/null 2>&1; then
      echo "$svc_name"
    fi
  done
}

watchdog_check_service() {
  local svc_name="$1"
  if ! systemctl is-active --quiet "$svc_name" 2>/dev/null; then
    daemon_log "WARN: $svc_name is DOWN — attempting restart"
    systemctl restart "$svc_name" 2>/dev/null || true
    sleep 3
    if systemctl is-active --quiet "$svc_name" 2>/dev/null; then
      daemon_log "OK: $svc_name restarted successfully"
      send_notification "✓ appy recovered $svc_name" "$svc_name was down and has been restarted."
    else
      daemon_log "ERROR: $svc_name failed to restart"
      send_notification "✗ appy FAILED to recover $svc_name" "$svc_name is still down after restart attempt."
    fi
  fi
}

health_snapshot() {
  local cpu_line cpu_idle=0 cpu_used
  cpu_line=$(top -bn1 2>/dev/null | grep -E "^(%Cpu|Cpu)" | head -1)
  [[ -n "$cpu_line" ]] && cpu_idle=$(echo "$cpu_line" | grep -oP '[0-9]+\.?[0-9]*(?=\s*id)' | head -1 || echo "0")
  cpu_used=$(awk "BEGIN{printf \"%.0f\", 100 - ${cpu_idle:-0}}" 2>/dev/null || echo "?")

  local mem_total mem_avail mem_used_pct
  mem_total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
  mem_avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
  mem_used_pct=$(awk "BEGIN{printf \"%.0f\", (1 - ${mem_avail}/${mem_total}) * 100}" 2>/dev/null || echo "?")

  local disk_used
  disk_used=$(df / --output=pcent 2>/dev/null | tail -1 | tr -d ' %' || echo "?")

  local load
  load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo "?")

  echo "cpu=${cpu_used}% mem=${mem_used_pct}% disk=${disk_used}% load=${load}"
}

send_notification() {
  local subject="$1"
  local body="$2"
  daemon_log "NOTIFY: $subject"
  if [[ -n "$NOTIFY_EMAIL" ]] && command -v mail &>/dev/null; then
    echo "$body" | mail -s "[appy] $subject" "$NOTIFY_EMAIL" 2>/dev/null || true
  fi
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $subject" >> "$APPY_DIR/notifications.log" 2>/dev/null || true
}

install_daemon() {
  step "Installing appy watchdog daemon"
  local script_src
  script_src=$(realpath "$0" 2>/dev/null || echo "/usr/local/bin/appy-daemon")
  local script_dest="/usr/local/bin/appy-daemon"

  cp "$script_src" "$script_dest" || die "Failed to copy appy to $script_dest"
  chmod 750 "$script_dest"   # root only executable
  chown root:root "$script_dest"

  cat > /etc/systemd/system/appy-daemon.service <<EOF
[Unit]
Description=appy System Manager Daemon (watchdog + health monitor)
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=${script_dest} --daemon
Restart=always
RestartSec=10
Environment=APPY_DAEMON_INTERVAL=${DAEMON_INTERVAL}
Environment=APPY_NOTIFY_EMAIL=${NOTIFY_EMAIL}
StandardOutput=append:${APPY_DAEMON_LOG}
StandardError=append:${APPY_DAEMON_LOG}
# Security hardening
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now appy-daemon
  info "appy-daemon installed and running"
  info "Logs:   tail -f $APPY_DAEMON_LOG"
  info "Status: systemctl status appy-daemon"
}

remove_daemon() {
  systemctl stop    appy-daemon 2>/dev/null || true
  systemctl disable appy-daemon 2>/dev/null || true
  rm -f /etc/systemd/system/appy-daemon.service /usr/local/bin/appy-daemon
  systemctl daemon-reload
  info "appy-daemon removed"
}

run_daemon() {
  daemon_log "appy-daemon v$APPY_VERSION started (interval=${DAEMON_INTERVAL}s)"

  local last_update_check=0
  local last_log_rotate=0
  local update_check_interval=$(( 6 * 3600 ))
  local log_rotate_interval=$(( 24 * 3600 ))

  while true; do
    local now
    now=$(date +%s)

    while IFS= read -r svc_name; do
      [[ -n "$svc_name" ]] && watchdog_check_service "$svc_name"
    done < <(get_watched_services)

    local snap
    snap=$(health_snapshot)
    daemon_log "HEALTH: $snap"

    local disk_pct mem_pct
    disk_pct=$(echo "$snap" | grep -oP 'disk=\K[0-9]+' || echo 0)
    mem_pct=$(echo "$snap"  | grep -oP 'mem=\K[0-9]+'  || echo 0)

    [[ "${disk_pct:-0}" -gt 90 ]] && \
      send_notification "⚠ Disk usage critical: ${disk_pct}%" "Root filesystem is ${disk_pct}% full."
    [[ "${mem_pct:-0}"  -gt 95 ]] && \
      send_notification "⚠ Memory usage critical: ${mem_pct}%" "System memory is ${mem_pct}% used."

    if (( now - last_update_check > update_check_interval )); then
      daemon_log "Checking for package updates..."
      local updates=0
      updates=$(pacman -Qu 2>/dev/null | wc -l || echo 0)
      if [[ "$updates" -gt 0 ]]; then
        daemon_log "INFO: $updates package(s) available for update"
        send_notification "📦 $updates system update(s) available" "Run 'pacman -Syu' or press U in appy menu."
        echo "$updates" > "$APPY_DIR/pending_updates"
      else
        rm -f "$APPY_DIR/pending_updates"
      fi
      last_update_check=$now
    fi

    if (( now - last_log_rotate > log_rotate_interval )); then
      rotate_logs
      last_log_rotate=$now
    fi

    sleep "$DAEMON_INTERVAL"
  done
}

rotate_logs() {
  daemon_log "Checking log rotation..."
  local max_size=$(( 10 * 1024 * 1024 ))
  local logfile
  for logfile in "$APPY_LOG" "$APPY_DAEMON_LOG" "$APPY_DIR/notifications.log"; do
    [[ ! -f "$logfile" ]] && continue
    local size=0
    size=$(stat -c%s "$logfile" 2>/dev/null || echo 0)
    if (( size > max_size )); then
      mv "$logfile" "${logfile}.$(date +%Y%m%d_%H%M%S).bak"
      touch "$logfile"
      ls -t "${logfile}."*".bak" 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
      daemon_log "Rotated: $logfile"
    fi
  done
}

# ══════════════════════════════════════════════════════════════════════════════
# ── SYSTEM HEALTH CHECK ───────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════

_bar() {
  local val="$1" max="${2:-100}" width="${3:-20}"
  local filled=$(( val * width / max ))
  [[ $filled -gt $width ]] && filled=$width
  local empty=$(( width - filled ))
  local col="$GREEN"
  (( val > 70 )) && col="$YELLOW"
  (( val > 85 )) && col="$RED"
  printf "${col}"
  printf '%0.s█' $(seq 1 $filled) 2>/dev/null || printf '█%.0s' $(seq 1 $filled)
  printf "${DIM}"
  printf '%0.s░' $(seq 1 $empty) 2>/dev/null || printf '░%.0s' $(seq 1 $empty)
  printf "${RESET}"
}

run_health_check() {
  clear
  local tw
  tw=$(_tw)
  local w=$(( tw - 4 ))
  [[ $w -gt 76 ]] && w=76
  local bar_w
  bar_w=$(printf '%0.s═' $(seq 1 $w))

  echo -e ""
  echo -e "  ${BOLD}${CYAN}${BX_TL}${bar_w}${BX_TR}${RESET}"
  printf "  ${BOLD}${CYAN}${BX_V}${RESET}  ${BOLD}${WHITE}%-*s${RESET}${BOLD}${CYAN}${BX_V}${RESET}\n" "$(( w - 2 ))" "  appy System Health Report  —  $(date '+%a %d %b %Y  %H:%M:%S')"
  echo -e "  ${BOLD}${CYAN}${BX_ML}${bar_w}${BX_MR}${RESET}"

  # CPU
  local cpu_line cpu_idle cpu_pct cpu_int
  cpu_line=$(top -bn1 2>/dev/null | grep -E "^(%Cpu|Cpu)" | head -1)
  cpu_idle=$(echo "$cpu_line" | grep -oP '[0-9]+\.?[0-9]*(?=\s*id)' | head -1 || echo "0")
  cpu_pct=$(awk "BEGIN{printf \"%.1f\", 100 - ${cpu_idle:-0}}" 2>/dev/null || echo "0")
  cpu_int=${cpu_pct%.*}
  printf "  ${CYAN}${BX_V}${RESET}  ${BOLD}CPU  ${RESET}%s ${YELLOW}%5s%%${RESET}%-*s${CYAN}${BX_V}${RESET}\n" \
    "$(_bar "$cpu_int" 100 20)" "$cpu_pct" "$(( w - 31 ))" ""

  # Memory
  local mem_total mem_avail mem_used_pct mem_used_mb mem_total_mb mem_int
  mem_total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
  mem_avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
  mem_used_pct=$(awk "BEGIN{printf \"%.1f\", (1-${mem_avail}/${mem_total})*100}" 2>/dev/null || echo "0")
  mem_used_mb=$(awk "BEGIN{printf \"%.0f\", (${mem_total}-${mem_avail})/1024}" 2>/dev/null || echo "0")
  mem_total_mb=$(awk "BEGIN{printf \"%.0f\", ${mem_total}/1024}" 2>/dev/null || echo "0")
  mem_int=${mem_used_pct%.*}
  printf "  ${CYAN}${BX_V}${RESET}  ${BOLD}MEM  ${RESET}%s ${YELLOW}%5s%%${RESET} ${DIM}(%s/%sMB)${RESET}%-*s${CYAN}${BX_V}${RESET}\n" \
    "$(_bar "$mem_int" 100 20)" "$mem_used_pct" "$mem_used_mb" "$mem_total_mb" \
    "$(( w - 43 ))" ""

  # Disk
  local disk_info disk_pct disk_used disk_total
  disk_info=$(df -h / | tail -1)
  disk_pct=$(echo "$disk_info" | awk '{print $5}' | tr -d '%')
  disk_used=$(echo "$disk_info" | awk '{print $3}')
  disk_total=$(echo "$disk_info" | awk '{print $2}')
  printf "  ${CYAN}${BX_V}${RESET}  ${BOLD}DISK ${RESET}%s ${YELLOW}%5s%%${RESET} ${DIM}(%s / %s)${RESET}%-*s${CYAN}${BX_V}${RESET}\n" \
    "$(_bar "${disk_pct:-0}" 100 20)" "$disk_pct" "$disk_used" "$disk_total" \
    "$(( w - 37 ))" ""

  # Load & uptime
  local load1 load5 load15 uptime_str
  read -r load1 load5 load15 _ < /proc/loadavg
  uptime_str=$(uptime -p 2>/dev/null || uptime)
  printf "  ${CYAN}${BX_V}${RESET}  ${BOLD}LOAD ${RESET}${GREEN}%-6s${RESET} (1m) ${GREEN}%-6s${RESET} (5m) ${GREEN}%-6s${RESET} (15m)%-*s${CYAN}${BX_V}${RESET}\n" \
    "$load1" "$load5" "$load15" "$(( w - 45 ))" ""
  printf "  ${CYAN}${BX_V}${RESET}  ${BOLD}UP   ${RESET}${DIM}%-*s${RESET}${CYAN}${BX_V}${RESET}\n" "$(( w - 5 ))" "$uptime_str"

  # Network
  echo -e "  ${CYAN}${BX_ML}${bar_w}${BX_MR}${RESET}"
  printf "  ${CYAN}${BX_V}${RESET}  ${BOLD}${BLUE}Network Interfaces${RESET}%-*s${CYAN}${BX_V}${RESET}\n" "$(( w - 20 ))" ""
  while IFS= read -r iface_line; do
    printf "  ${CYAN}${BX_V}${RESET}  ${DIM}%-*s${RESET}${CYAN}${BX_V}${RESET}\n" "$(( w - 2 ))" "$iface_line"
  done < <(ip -o -4 addr show 2>/dev/null | awk '{printf "  %-14s %s", $2, $4}' | grep -v '^\s*lo ')

  # Managed services
  echo -e "  ${CYAN}${BX_ML}${bar_w}${BX_MR}${RESET}"
  printf "  ${CYAN}${BX_V}${RESET}  ${BOLD}${BLUE}Managed Services${RESET}%-*s${CYAN}${BX_V}${RESET}\n" "$(( w - 18 ))" ""
  local all_ok=true
  local key svc_name display spec
  for key in "${KEYS[@]}"; do
    spec="${S[$key]:-}"; [[ -z "$spec" ]] && continue
    IFS='|' read -r display _ _ _ svc_name _ _ <<< "$spec"
    [[ "$svc_name" == "-" ]] && continue
    if systemctl list-unit-files "${svc_name}.service" &>/dev/null 2>&1 \
       && systemctl is-enabled "$svc_name" &>/dev/null 2>&1; then
      if systemctl is-active --quiet "$svc_name" 2>/dev/null; then
        printf "  ${CYAN}${BX_V}${RESET}    ${GREEN}${DOT_FULL}${RESET} %-24s ${GREEN}running${RESET}%-*s${CYAN}${BX_V}${RESET}\n" \
          "$display" "$(( w - 38 ))" ""
      else
        printf "  ${CYAN}${BX_V}${RESET}    ${RED}${DOT_FULL}${RESET} %-24s ${RED}stopped${RESET}%-*s${CYAN}${BX_V}${RESET}\n" \
          "$display" "$(( w - 38 ))" ""
        all_ok=false
      fi
    fi
  done

  # Docker containers
  if command -v docker &>/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
    echo -e "  ${CYAN}${BX_ML}${bar_w}${BX_MR}${RESET}"
    printf "  ${CYAN}${BX_V}${RESET}  ${BOLD}${BLUE}Docker Containers${RESET}%-*s${CYAN}${BX_V}${RESET}\n" "$(( w - 19 ))" ""
    local container_list
    container_list=$(docker ps -a --format "{{.Names}}|{{.Status}}" 2>/dev/null || true)
    if [[ -n "$container_list" ]]; then
      while IFS='|' read -r cname cstatus; do
        if [[ "$cstatus" == Up* ]]; then
          printf "  ${CYAN}${BX_V}${RESET}    ${GREEN}${DOT_FULL}${RESET} %-24s ${GREEN}%s${RESET}%-*s${CYAN}${BX_V}${RESET}\n" \
            "$cname" "${cstatus:0:25}" "$(( w - 57 ))" ""
        else
          printf "  ${CYAN}${BX_V}${RESET}    ${RED}${DOT_FULL}${RESET} %-24s ${RED}%s${RESET}%-*s${CYAN}${BX_V}${RESET}\n" \
            "$cname" "${cstatus:0:25}" "$(( w - 57 ))" ""
        fi
      done <<< "$container_list"
    else
      printf "  ${CYAN}${BX_V}${RESET}    ${DIM}(no containers running)${RESET}%-*s${CYAN}${BX_V}${RESET}\n" "$(( w - 27 ))" ""
    fi
  fi

  # Summary / alerts
  echo -e "  ${CYAN}${BX_ML}${bar_w}${BX_MR}${RESET}"
  if [[ -f "$APPY_DIR/pending_updates" ]]; then
    local upd
    upd=$(cat "$APPY_DIR/pending_updates")
    printf "  ${CYAN}${BX_V}${RESET}  ${YELLOW}[!] ${upd} package update(s) available — press U in main menu${RESET}%-*s${CYAN}${BX_V}${RESET}\n" \
      "$(( w - 57 ))" ""
  fi
  local failed=0
  failed=$(systemctl --failed --no-legend 2>/dev/null | wc -l || echo 0)
  if [[ "$failed" -gt 0 ]]; then
    printf "  ${CYAN}${BX_V}${RESET}  ${RED}[!] ${failed} systemd service(s) FAILED system-wide${RESET}%-*s${CYAN}${BX_V}${RESET}\n" \
      "$(( w - 47 ))" ""
  fi
  if $all_ok; then
    printf "  ${CYAN}${BX_V}${RESET}  ${GREEN}${BOLD}${CHECK} All monitored services are healthy${RESET}%-*s${CYAN}${BX_V}${RESET}\n" \
      "$(( w - 37 ))" ""
  else
    printf "  ${CYAN}${BX_V}${RESET}  ${YELLOW}${BOLD}[!] Some services need attention (see above)${RESET}%-*s${CYAN}${BX_V}${RESET}\n" \
      "$(( w - 45 ))" ""
  fi
  echo -e "  ${BOLD}${CYAN}${BX_BL}${bar_w}${BX_BR}${RESET}"
  echo ""
  log "Health check completed"
  read -rp "  Press Enter to continue..."
}

# ── Auto-update ───────────────────────────────────────────────────────────────
run_auto_update() {
  step "Running full system update"
  log "Auto-update started"

  echo -e "\n  ${BOLD}[1/4] Updating pacman packages...${RESET}"
  pacman -Syu --noconfirm 2>&1 | tee -a "$APPY_LOG" || warn "pacman update had errors"

  if command -v yay &>/dev/null; then
    echo -e "\n  ${BOLD}[2/4] Updating AUR packages...${RESET}"
    sudo -u "$REAL_USER" yay -Syu --noconfirm 2>&1 | tee -a "$APPY_LOG" || warn "yay update had errors"
  else
    echo -e "\n  ${BOLD}[2/4] Skipping AUR (yay not installed)${RESET}"
  fi

  echo -e "\n  ${BOLD}[3/4] Updating Docker images...${RESET}"
  if command -v docker &>/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
    docker ps --format "{{.Image}}" 2>/dev/null | sort -u | while IFS= read -r img; do
      [[ -z "$img" ]] && continue
      echo "  Pulling: $img"
      docker pull "$img" 2>/dev/null | grep -E "Status:|Digest:|error" || true
    done
    # Also update Immich if installed
    if [[ -f /var/lib/immich/docker-compose.yml ]]; then
      local _dc_up
      _dc_up=$(_docker_compose_cmd 2>/dev/null || echo "docker-compose")
      echo "  Updating Immich stack..."
      ( cd /var/lib/immich && $_dc_up pull 2>/dev/null | grep -E "Pulling|Status:" || true )
      ( cd /var/lib/immich && $_dc_up up -d 2>/dev/null || true )
    fi
    info "Docker images updated"
  else
    echo "  Docker not running — skipping."
  fi

  echo -e "\n  ${BOLD}[4/4] Cleaning package cache...${RESET}"
  pacman -Sc --noconfirm 2>&1 | tail -3 || true
  rm -f "$APPY_DIR/pending_updates"
  _invalidate_pkg_cache

  log "Auto-update completed"
  info "System fully updated!"
  read -rp "  Press Enter to continue..."
}

# ── Config backup ─────────────────────────────────────────────────────────────
run_config_backup() {
  local backup_dir="/var/backups/appy-configs"
  local timestamp
  timestamp=$(date +%Y%m%d_%H%M%S)
  local archive="$backup_dir/configs_${timestamp}.tar.gz"

  step "Backing up service configurations"
  mkdir -p "$backup_dir"
  chmod 700 "$backup_dir"

  local -a config_paths=(
    /etc/nginx
    /etc/caddy
    /etc/prometheus
    /etc/grafana
    /etc/loki
    /etc/fail2ban
    /etc/ufw
    /etc/wireguard
    /etc/samba
    /etc/redis.conf
    /etc/my.cnf
    /etc/mysql
    /etc/postgresql
    /var/lib/immich/.env
    /var/lib/immich/docker-compose.yml
    /etc/systemd/system/appy-daemon.service
    /etc/systemd/system/appy-update.service
    /etc/systemd/system/appy-update.timer
    "$CRED_FILE"
    "$APPY_DIR"
  )

  local -a existing=()
  local p
  for p in "${config_paths[@]}"; do
    [[ -e "$p" ]] && existing+=("$p")
  done

  if [[ ${#existing[@]} -eq 0 ]]; then
    warn "No configuration files found to back up."
    read -rp "  Press Enter to continue..."; return
  fi

  spin_start "Creating backup archive..."
  if tar -czf "$archive" "${existing[@]}" 2>/dev/null; then
    spin_stop
    chmod 600 "$archive"   # Protect backup (may contain credentials)
    info "Config backup saved to: $archive"
  else
    spin_stop
    warn "Backup completed with some warnings (non-critical)"
  fi

  ls -t "$backup_dir"/configs_*.tar.gz 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true

  local size
  size=$(du -sh "$archive" 2>/dev/null | awk '{print $1}' || echo "?")
  info "Backup size: $size"
  log "Config backup created: $archive"
  read -rp "  Press Enter to continue..."
}

# ── Service removal ───────────────────────────────────────────────────────────
run_rollback_menu() {
  clear
  echo -e "\n  ${BOLD}${RED}${CROSS} Remove / Rollback a Service${RESET}\n"
  echo -e "  ${YELLOW}[!] Warning: This will stop and remove the selected service.${RESET}"
  echo -e "  ${DIM}    Data directories are NOT deleted automatically.${RESET}\n"

  local i=1
  declare -A idx_to_key=()
  local key display type pkg svc_name spec installed

  for key in "${KEYS[@]}"; do
    spec="${S[$key]:-}"; [[ -z "$spec" ]] && continue
    IFS='|' read -r display _ type pkg svc_name _ _ <<< "$spec"
    installed=false
    if [[ "$type" =~ ^(pac|aur)$ && "$pkg" != "-" ]]; then
      local fp
      fp=$(awk '{print $1}' <<< "$pkg")
      _is_pkg_installed "$fp" && installed=true
    elif [[ "$type" == "docker" ]]; then
      if [[ "$key" == "immich" ]]; then
        [[ -f /var/lib/immich/docker-compose.yml ]] && installed=true
      else
        docker inspect "${key//_/-}" &>/dev/null 2>&1 && installed=true
      fi
    fi
    $installed || continue
    printf "  ${BLUE}%2d)${RESET} %-30s ${DIM}[%s]${RESET}\n" "$i" "$display" "$type"
    idx_to_key[$i]="$key"
    (( i++ )) || true
  done

  if [[ $i -eq 1 ]]; then
    echo -e "  ${DIM}No installed services found.${RESET}"
    read -rp "  Press Enter to continue..."; return
  fi

  echo ""
  echo -e "  ${YELLOW}B)${RESET} Back"
  echo ""
  read -rp "  Select service to remove: " chosen_idx

  [[ "${chosen_idx,,}" == "b" ]] && return
  [[ -z "${idx_to_key[$chosen_idx]+_}" ]] && { warn "Invalid selection."; read -rp "  Press Enter..."; return; }

  local chosen_key="${idx_to_key[$chosen_idx]}"
  spec="${S[$chosen_key]:-}"
  IFS='|' read -r display _ type pkg svc_name _ _ <<< "$spec"

  echo ""
  echo -e "  ${RED}You are about to remove: ${BOLD}${display}${RESET}"
  read -rp "  Type 'yes' to confirm: " confirm_rm
  [[ "$confirm_rm" != "yes" ]] && { info "Removal cancelled."; read -rp "  Press Enter..."; return; }

  step "Removing $display"

  if [[ "$svc_name" != "-" ]]; then
    systemctl stop    "$svc_name" 2>/dev/null || true
    systemctl disable "$svc_name" 2>/dev/null || true
  fi

  case "$type" in
    pac)
      local pkg_arr=()
      read -ra pkg_arr <<< "$pkg"
      pacman -Rns --noconfirm "${pkg_arr[@]}" 2>/dev/null \
        || warn "Some packages could not be removed"
      ;;
    aur)
      ensure_yay
      local pkg_arr=()
      read -ra pkg_arr <<< "$pkg"
      sudo -u "$REAL_USER" yay -Rns --noconfirm "${pkg_arr[@]}" 2>/dev/null \
        || warn "Some AUR packages could not be removed"
      ;;
    docker)
      local cname="${chosen_key//_/-}"
      docker stop "$cname" 2>/dev/null || true
      docker rm   "$cname" 2>/dev/null || true
      # Special case: Immich uses compose + systemd
      if [[ "$chosen_key" == "immich" && -f /var/lib/immich/docker-compose.yml ]]; then
        local _dc
        _dc=$(_docker_compose_cmd 2>/dev/null || echo "docker-compose")
        systemctl stop    immich.service 2>/dev/null || true
        systemctl disable immich.service 2>/dev/null || true
        rm -f /etc/systemd/system/immich.service
        systemctl daemon-reload
        ( cd /var/lib/immich && $_dc down 2>/dev/null ) || true
      fi
      ;;
  esac

  _invalidate_pkg_cache
  log "Removed: $chosen_key ($display)"
  info "$display removed."
  read -rp "  Press Enter to continue..."
}

# ── Notifications log viewer ──────────────────────────────────────────────────
view_notifications() {
  clear
  echo -e "\n  ${BOLD}${CYAN}Recent Notifications${RESET}\n"
  if [[ -s "$APPY_DIR/notifications.log" ]]; then
    tail -30 "$APPY_DIR/notifications.log"
  else
    echo -e "  ${DIM}No notifications yet. The watchdog daemon sends notifications here.${RESET}"
  fi
  echo ""
  read -rp "  Press Enter to continue..."
}

# ── Auto-update scheduler ─────────────────────────────────────────────────────
setup_scheduler() {
  clear
  echo -e "\n  ${BOLD}${CYAN}Auto-Update Scheduler${RESET}"
  echo -e "  ${DIM}Automatically update system packages on a schedule.${RESET}\n"
  echo "   1) Daily at 3:00 AM"
  echo "   2) Weekly (Sunday 3:00 AM)"
  echo "   3) Disable auto-updates"
  echo "   4) Back"
  echo ""
  read -rp "  Choice: " sched_choice

  local on_calendar=""
  case "$sched_choice" in
    1) on_calendar="*-*-* 03:00:00" ;;
    2) on_calendar="Sun *-*-* 03:00:00" ;;
    3)
      systemctl stop    appy-update.timer 2>/dev/null || true
      systemctl disable appy-update.timer 2>/dev/null || true
      rm -f /etc/systemd/system/appy-update.{service,timer}
      systemctl daemon-reload
      info "Auto-update scheduler disabled."
      read -rp "  Press Enter..."; return
      ;;
    *) return ;;
  esac

  local script_dest="/usr/local/bin/appy-daemon"
  if [[ ! -f "$script_dest" ]]; then
    local script_src
    script_src=$(realpath "$0" 2>/dev/null || echo "")
    if [[ -n "$script_src" && -f "$script_src" ]]; then
      cp "$script_src" "$script_dest"
      chmod 750 "$script_dest"
      chown root:root "$script_dest"
    else
      warn "Cannot find source script — install daemon first (M → 7)"
      read -rp "  Press Enter..."; return
    fi
  fi

  cat > /etc/systemd/system/appy-update.service <<EOF
[Unit]
Description=appy Automatic System Update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${script_dest} --update
StandardOutput=append:${APPY_LOG}
StandardError=append:${APPY_LOG}
EOF

  cat > /etc/systemd/system/appy-update.timer <<EOF
[Unit]
Description=appy Auto-Update Timer

[Timer]
OnCalendar=${on_calendar}
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now appy-update.timer
  info "Auto-update scheduled: $on_calendar"
  info "Check: systemctl list-timers appy-update.timer"
  read -rp "  Press Enter to continue..."
}

# ── Autostart manager ─────────────────────────────────────────────────────────
# Lets the user choose which installed services start automatically on reboot.
manage_autostart() {
  while true; do
    clear
    echo -e "\n  ${BOLD}${CYAN}🔁  Manage Service Autostart on Reboot${RESET}"
    echo -e "  ${DIM}Enable = starts automatically every time the server boots.${RESET}"
    echo -e "  ${DIM}Disable = service must be started manually after a reboot.${RESET}\n"

    local i=1
    declare -A _as_idx_key=()
    declare -A _as_idx_svc=()
    declare -A _as_idx_type=()
    declare -A _as_idx_enabled=()

    local key spec display type pkg svc_name

    for key in "${KEYS[@]}"; do
      spec="${S[$key]:-}"; [[ -z "$spec" ]] && continue
      IFS='|' read -r display _ type pkg svc_name _ _ <<< "$spec"

      # ── systemd-managed services ──────────────────────────────────────────
      if [[ "$svc_name" != "-" && "$type" =~ ^(pac|aur|curl)$ ]]; then
        # Only show if installed
        local fp
        fp=$(awk '{print $1}' <<< "$pkg")
        local is_inst=false
        _is_pkg_installed "$fp" && is_inst=true
        [[ "$key" == "ollama" ]] && command -v ollama &>/dev/null && is_inst=true
        $is_inst || continue

        local enabled_str="${RED}disabled${RESET}"
        systemctl is-enabled --quiet "$svc_name" 2>/dev/null \
          && enabled_str="${GREEN}enabled ${RESET}" \
          && _as_idx_enabled[$i]="yes" \
          || _as_idx_enabled[$i]="no"

        printf "  ${CYAN}%2d)${RESET} %-28s ${DIM}systemd:${RESET} %-14s %b\n" \
          "$i" "$display" "$svc_name" "$enabled_str"
        _as_idx_key[$i]="$key"
        _as_idx_svc[$i]="$svc_name"
        _as_idx_type[$i]="systemd"
        (( i++ )) || true

      # ── Immich (compose via systemd unit) ─────────────────────────────────
      elif [[ "$key" == "immich" ]]; then
        [[ -f /var/lib/immich/docker-compose.yml ]] || continue
        local enabled_str="${RED}disabled${RESET}"
        systemctl is-enabled --quiet immich.service 2>/dev/null \
          && enabled_str="${GREEN}enabled ${RESET}" \
          && _as_idx_enabled[$i]="yes" \
          || _as_idx_enabled[$i]="no"
        printf "  ${CYAN}%2d)${RESET} %-28s ${DIM}systemd:${RESET} %-14s %b\n" \
          "$i" "Immich" "immich.service" "$enabled_str"
        _as_idx_key[$i]="immich"
        _as_idx_svc[$i]="immich"
        _as_idx_type[$i]="systemd"
        (( i++ )) || true

      # ── Docker containers (restart policy) ────────────────────────────────
      elif [[ "$type" == "docker" && "$key" != "immich" ]]; then
        local cname="${key//_/-}"
        docker inspect "$cname" &>/dev/null 2>&1 || continue
        local policy
        policy=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$cname" 2>/dev/null || echo "no")
        local enabled_str
        [[ "$policy" == "always" || "$policy" == "unless-stopped" ]] \
          && enabled_str="${GREEN}always  ${RESET}" \
          && _as_idx_enabled[$i]="yes" \
          || enabled_str="${RED}no      ${RESET}" \
          && _as_idx_enabled[$i]="no"
        printf "  ${CYAN}%2d)${RESET} %-28s ${DIM}container:${RESET} %-12s %b\n" \
          "$i" "$display" "$cname" "$enabled_str"
        _as_idx_key[$i]="$key"
        _as_idx_svc[$i]="$cname"
        _as_idx_type[$i]="docker"
        (( i++ )) || true
      fi
    done

    if [[ $i -eq 1 ]]; then
      echo -e "  ${DIM}No installed services detected. Install some first.${RESET}"
      echo ""
      read -rp "  Press Enter to go back..."
      return
    fi

    echo ""
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${RESET}"
    echo -e "  Enter a number to toggle autostart, or ${YELLOW}B${RESET} to go back."
    echo ""
    read -rp "  → " _as_choice

    [[ "${_as_choice,,}" == "b" ]] && return

    if [[ "$_as_choice" =~ ^[0-9]+$ && -n "${_as_idx_key[$_as_choice]+_}" ]]; then
      local chosen_key="${_as_idx_key[$_as_choice]}"
      local chosen_svc="${_as_idx_svc[$_as_choice]}"
      local chosen_type="${_as_idx_type[$_as_choice]}"
      local currently="${_as_idx_enabled[$_as_choice]}"

      if [[ "$chosen_type" == "systemd" ]]; then
        if [[ "$currently" == "yes" ]]; then
          systemctl disable "$chosen_svc" 2>/dev/null \
            && info "Autostart DISABLED for $chosen_svc" \
            || warn "Could not disable $chosen_svc"
        else
          systemctl enable "$chosen_svc" 2>/dev/null \
            && info "Autostart ENABLED for $chosen_svc (will start on next reboot)" \
            || warn "Could not enable $chosen_svc"
        fi
      elif [[ "$chosen_type" == "docker" ]]; then
        if [[ "$currently" == "yes" ]]; then
          docker update --restart=no "$chosen_svc" 2>/dev/null \
            && info "Autostart DISABLED for Docker container: $chosen_svc" \
            || warn "Could not update restart policy"
        else
          docker update --restart=always "$chosen_svc" 2>/dev/null \
            && info "Autostart ENABLED for Docker container: $chosen_svc (restart=always)" \
            || warn "Could not update restart policy"
        fi
      fi
    else
      warn "Invalid choice: $_as_choice"
    fi

    unset _as_idx_key _as_idx_svc _as_idx_type _as_idx_enabled
    sleep 1
  done
}

# ── Maintenance menu ──────────────────────────────────────────────────────────
maintenance_menu() {
  while true; do
    clear
    echo -e "\n  ${BOLD}${CYAN}⚙  Maintenance & Management${RESET}\n"

    if systemctl is-active --quiet appy-daemon 2>/dev/null; then
      echo -e "  ${GREEN}${DOT_FULL}${RESET} appy-daemon  ${GREEN}running${RESET}  ${DIM}(watchdog active)${RESET}"
    else
      echo -e "  ${RED}${DOT_EMPTY}${RESET} appy-daemon  ${RED}not running${RESET}  ${DIM}(tip: install via option 7)${RESET}"
    fi

    if [[ -f "$APPY_DIR/pending_updates" ]]; then
      local upd
      upd=$(cat "$APPY_DIR/pending_updates")
      echo -e "  ${YELLOW}[!] $upd package update(s) pending${RESET}"
    fi
    echo ""

    echo -e "  ${DIM}── System ──────────────────────────────────────────────${RESET}"
    echo "   1)  Full system health check"
    echo "   2)  Update all packages  (pacman + AUR + Docker)"
    echo "   3)  Clean package & Docker cache"
    echo "   4)  Show failed services"
    echo "   5)  Disk usage breakdown"
    echo "   6)  Running services list"
    echo ""
    echo -e "  ${DIM}── appy Daemon ─────────────────────────────────────────${RESET}"
    echo "   7)  Install / restart appy watchdog daemon"
    echo "   8)  Remove appy watchdog daemon"
    echo "   9)  View daemon logs  (last 50 lines)"
    echo "  10)  View notifications"
    echo "  11)  Setup auto-update schedule"
    echo ""
    echo -e "  ${DIM}── Backup & Recovery ───────────────────────────────────${RESET}"
    echo "  12)  Back up all service configs"
    echo "  13)  Remove / rollback a service"
    echo ""
    echo -e "  ${DIM}── Autostart ────────────────────────────────────────────${RESET}"
    echo "  14)  Manage which services start on reboot"
    echo ""
    echo -e "  ${YELLOW}B)${RESET} Back to main menu"
    echo ""
    read -rp "  Choice: " m

    case "$m" in
      1)  run_health_check ;;
      2)  run_auto_update ;;
      3)
          echo ""
          pacman -Sc --noconfirm 2>&1 | tail -5 || true
          if command -v docker &>/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
            docker system prune -f 2>/dev/null || true
            info "Docker cache pruned"
          fi
          info "Cache cleaned"
          read -rp "  Press Enter..."
          ;;
      4)
          echo ""
          systemctl --failed 2>/dev/null || true
          read -rp "  Press Enter..."
          ;;
      5)
          echo ""
          df -h; echo ""
          du -sh /var/cache/pacman/pkg 2>/dev/null || true
          if command -v docker &>/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
            docker system df 2>/dev/null || true
          fi
          read -rp "  Press Enter..."
          ;;
      6)
          echo ""
          systemctl list-units --type=service --state=running 2>/dev/null || true
          read -rp "  Press Enter..."
          ;;
      7)  install_daemon;   read -rp "  Press Enter..." ;;
      8)  remove_daemon;    read -rp "  Press Enter..." ;;
      9)
          echo ""
          tail -50 "$APPY_DAEMON_LOG" 2>/dev/null || echo "  No daemon log found."
          read -rp "  Press Enter..."
          ;;
      10) view_notifications ;;
      11) setup_scheduler ;;
      12) run_config_backup ;;
      13) run_rollback_menu ;;
      14) manage_autostart ;;
      b|B) return ;;
      *) warn "Invalid choice: $m" ;;
    esac
  done
}

# ══════════════════════════════════════════════════════════════════════════════
# ── MAIN INTERACTIVE MENU ─────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════

# Pre-build install status in parallel for speed
declare -A _INSTALL_STATUS=()
_prefetch_install_status() {
  # Run all pacman -Qi checks in a subshell batch for speed
  local key spec type pkg
  for key in "${KEYS[@]}"; do
    spec="${S[$key]:-}"; [[ -z "$spec" ]] && continue
    IFS='|' read -r _ _ type pkg _ _ _ <<< "$spec"
    if [[ "$type" =~ ^(pac|aur)$ && "$pkg" != "-" ]]; then
      local fp
      fp=$(awk '{print $1}' <<< "$pkg")
      if _is_pkg_installed "$fp"; then
        _INSTALL_STATUS[$key]="installed"
      else
        _INSTALL_STATUS[$key]="not_installed"
      fi
    elif [[ "$type" == "docker" ]]; then
      # Special case: Immich uses compose, not a single named container
      if [[ "$key" == "immich" ]]; then
        if [[ -f /var/lib/immich/docker-compose.yml ]]; then
          _INSTALL_STATUS[$key]="installed"
        else
          _INSTALL_STATUS[$key]="not_installed"
        fi
      elif docker inspect "${key//_/-}" &>/dev/null 2>&1; then
        _INSTALL_STATUS[$key]="installed"
      else
        _INSTALL_STATUS[$key]="not_installed"
      fi
    elif [[ "$type" == "curl" ]]; then
      # Detect curl-installed services by their binary or marker file
      case "$key" in
        ollama)
          command -v ollama &>/dev/null \
            && _INSTALL_STATUS[$key]="installed" \
            || _INSTALL_STATUS[$key]="not_installed"
          ;;
        pihole)
          [[ -f /usr/local/bin/pihole ]] \
            && _INSTALL_STATUS[$key]="installed" \
            || _INSTALL_STATUS[$key]="not_installed"
          ;;
        *)
          _INSTALL_STATUS[$key]="other"
          ;;
      esac
    else
      _INSTALL_STATUS[$key]="other"
    fi
  done
}

main_menu() {
  while true; do
    clear

    # ── ASCII header ──────────────────────────────────────────────────────────
    echo -e "${BOLD}${GREEN}"
    echo "  ╔═══════════════════════════════════════════╗"
    echo "  ║   ▄▄▄    ██████  ██████  ██╗   ██╗       ║"
    echo "  ║  ██╔╝   ██╔══██╗ ██╔══██╗╚██╗ ██╔╝       ║"
    echo "  ║  ██║    ██████╔╝ ██████╔╝ ╚████╔╝        ║"
    echo "  ║  ██╗    ██╔═══╝  ██╔═══╝   ╚██╔╝         ║"
    echo "  ║  ╚██╗   ██║      ██║        ██║           ║"
    echo "  ║   ╚═╝   ╚═╝      ╚═╝        ╚═╝  v${APPY_VERSION}   ║"
    echo "  ╚═══════════════════════════════════════════╝"
    echo -e "${RESET}"

    # ── Status bar ────────────────────────────────────────────────────────────
    local snap cpu_s mem_s disk_s
    snap=$(health_snapshot 2>/dev/null || echo "cpu=?% mem=?% disk=?% load=?")
    cpu_s=$(echo "$snap"  | grep -oP 'cpu=\K[^%]+')
    mem_s=$(echo "$snap"  | grep -oP 'mem=\K[^%]+')
    disk_s=$(echo "$snap" | grep -oP 'disk=\K[^%]+')

    local daemon_dot="${RED}${DOT_EMPTY}${RESET}"
    systemctl is-active --quiet appy-daemon 2>/dev/null && daemon_dot="${GREEN}${DOT_FULL}${RESET}"

    printf "  ${DIM}watchdog:${RESET} %b  ${DIM}│  cpu:${RESET} ${YELLOW}%s%%${RESET}  ${DIM}mem:${RESET} ${YELLOW}%s%%${RESET}  ${DIM}disk:${RESET} ${YELLOW}%s%%${RESET}  ${DIM}│  log: %s${RESET}\n" \
      "$daemon_dot" "${cpu_s:-?}" "${mem_s:-?}" "${disk_s:-?}" "$APPY_LOG"

    if [[ -f "$APPY_DIR/pending_updates" ]]; then
      local upd
      upd=$(cat "$APPY_DIR/pending_updates" 2>/dev/null || echo "?")
      echo -e "  ${YELLOW}[!] ${upd} update(s) pending — press U to update${RESET}"
    fi
    echo ""

    # ── Service menu (3 columns) ──────────────────────────────────────────────
    declare -A idx_to_key=()
    local i=1

    local -a groups=(
      "🐳 Containers & Web|docker compose nginx caddy portainer"
      "🗄️  Databases|mariadb postgres redis sqlite mongodb"
      "🔒 Security & Net|fail2ban ufw wireguard tailscale vaultwarden crowdsec"
      "📷 Media & Files|jellyfin immich samba syncthing"
      "📊 Monitoring|btop htop netdata prometheus grafana uptime_kuma cockpit loki"
      "💻 Development|git neovim zsh node python golang rust docker_buildx"
      "🤖 AI & Other|ollama pihole timeshift restic"
    )

    local group_entry group_name group_keys key spec display type port desc col_count mark

    for group_entry in "${groups[@]}"; do
      group_name="${group_entry%%|*}"
      group_keys="${group_entry#*|}"

      echo -e "  ${BOLD}${BLUE}${group_name}${RESET}"
      echo -e "  ${DIM}$(printf '%0.s─' $(seq 1 60))${RESET}"

      col_count=0
      for key in $group_keys; do
        spec="${S[$key]:-}"; [[ -z "$spec" ]] && continue
        IFS='|' read -r display _ type _ _ port desc <<< "$spec"

        # Install status mark
        mark="${DIM}·${RESET}"
        if [[ "${_INSTALL_STATUS[$key]:-}" == "installed" ]]; then
          mark="${GREEN}${CHECK}${RESET}"
        fi

        printf "  ${CYAN}%2d)${RESET} [%b] %-22s ${DIM}%s${RESET}\n" \
          "$i" "$mark" "$display" "${port:--}"
        idx_to_key[$i]="$key"
        (( i++ )) || true
        (( col_count++ )) || true
      done
      echo ""
    done

    # ── Actions ───────────────────────────────────────────────────────────────
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${RESET}"
    echo -e "  ${YELLOW}A)${RESET} Install ALL services   ${YELLOW}U)${RESET} Update system   ${YELLOW}H)${RESET} Health check"
    echo -e "  ${YELLOW}M)${RESET} Maintenance menu       ${YELLOW}Q)${RESET} Quit"
    echo ""
    echo -e "  ${BOLD}Enter number(s) to install  (e.g. ${CYAN}1${RESET}${BOLD} or ${CYAN}1 3 7${RESET}${BOLD}), or a letter:${RESET}"
    echo -e "  ${DIM}${CHECK} = already installed  · = not installed${RESET}"
    echo ""
    read -rp "  → " input
    echo ""

    local input_lower="${input,,}"

    case "$input_lower" in
      q) echo -e "  ${GREEN}Goodbye!${RESET}"; exit 0 ;;
      m) maintenance_menu; _prefetch_install_status; continue ;;
      h) run_health_check; continue ;;
      u) run_auto_update; _prefetch_install_status; continue ;;
      a)
        local k
        for k in "${KEYS[@]}"; do
          do_install "$k" || true
        done
        _prefetch_install_status
        echo -e "\n  ${GREEN}${BOLD}All services installation complete!${RESET}"
        read -rp "  Press Enter to continue..."
        continue
        ;;
    esac

    # Numeric selections
    local installed_count=0 token
    for token in $input; do
      if [[ "$token" =~ ^[0-9]+$ ]]; then
        if [[ -n "${idx_to_key[$token]+_}" ]]; then
          do_install "${idx_to_key[$token]}" && (( installed_count++ )) || true
        else
          warn "No service mapped to number: $token"
        fi
      else
        warn "Invalid input: '$token' — enter a number or letter"
      fi
    done

    if [[ "$installed_count" -gt 0 ]]; then
      _prefetch_install_status
      echo -e "\n  ${GREEN}${BOLD}Done! $installed_count service(s) processed.${RESET}"
    fi
    read -rp "  Press Enter to continue..."
  done
}

# ══════════════════════════════════════════════════════════════════════════════
# ── CLI ENTRY POINT ───────────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════
case "${1:-}" in
  --daemon)
    log "Starting in daemon mode"
    run_daemon
    ;;

  --health)
    run_health_check
    ;;

  --update)
    run_auto_update
    ;;

  --status)
    health_snapshot
    ;;

  --install)
    shift
    if [[ $# -eq 0 ]]; then
      err "--install requires at least one service key"
      echo -e "  ${DIM}Available keys: ${KEYS[*]}${RESET}"
      exit 1
    fi
    for svc_key in "$@"; do
      do_install "$svc_key" || true
    done
    ;;

  --remove)
    shift
    if [[ $# -eq 0 ]]; then
      err "--remove requires at least one service key"
      exit 1
    fi
    for svc_key in "$@"; do
      spec="${S[$svc_key]:-}"
      if [[ -z "$spec" ]]; then
        err "Unknown service key: '$svc_key'"
        continue
      fi
      IFS='|' read -r _rm_display _ _rm_type _rm_pkg _rm_svc _ _ <<< "$spec"
      step "Removing $_rm_display"
      echo ""
      echo -e "  ${RED}About to remove: ${BOLD}${_rm_display}${RESET}"
      read -rp "  Type 'yes' to confirm: " _confirm
      [[ "$_confirm" != "yes" ]] && { info "Cancelled."; continue; }
      [[ "$_rm_svc" != "-" ]] && systemctl stop    "$_rm_svc" 2>/dev/null || true
      [[ "$_rm_svc" != "-" ]] && systemctl disable "$_rm_svc" 2>/dev/null || true
      _rm_pkg_arr=()
      case "$_rm_type" in
        pac)
          read -ra _rm_pkg_arr <<< "$_rm_pkg"
          pacman -Rns --noconfirm "${_rm_pkg_arr[@]}" 2>/dev/null || warn "Some packages could not be removed"
          ;;
        aur)
          ensure_yay
          read -ra _rm_pkg_arr <<< "$_rm_pkg"
          sudo -u "$REAL_USER" yay -Rns --noconfirm "${_rm_pkg_arr[@]}" 2>/dev/null || true
          ;;
        docker)
          _rm_cname="${svc_key//_/-}"
          docker stop "$_rm_cname" 2>/dev/null || true
          docker rm   "$_rm_cname" 2>/dev/null || true
          if [[ "$svc_key" == "immich" && -f /var/lib/immich/docker-compose.yml ]]; then
            local _dc2
            _dc2=$(_docker_compose_cmd 2>/dev/null || echo "docker-compose")
            systemctl stop    immich.service 2>/dev/null || true
            systemctl disable immich.service 2>/dev/null || true
            rm -f /etc/systemd/system/immich.service
            systemctl daemon-reload
            ( cd /var/lib/immich && $_dc2 down 2>/dev/null ) || true
          fi
          ;;
      esac
      info "Removed: $_rm_display"
    done
    ;;

  --backup)
    run_config_backup
    ;;

  --logs)
    tail -100 "$APPY_LOG" 2>/dev/null || echo "No logs found at $APPY_LOG"
    ;;

  --version)
    echo "appy v$APPY_VERSION"
    ;;

  --help|-h)
    echo ""
    echo -e "${BOLD}appy v${APPY_VERSION}${RESET} — Service Installer & System Manager  (CachyOS / Arch Linux)"
    echo ""
    echo -e "  ${BOLD}Interactive TUI:${RESET}"
    echo "    sudo bash appy.sh                  Launch full menu"
    echo ""
    echo -e "  ${BOLD}Non-interactive flags:${RESET}"
    echo "    --daemon                           Run watchdog daemon (used by systemd)"
    echo "    --health                           Full color-coded system health report"
    echo "    --update                           Full system update (pacman + AUR + Docker)"
    echo "    --status                           One-line health snapshot (cpu/mem/disk/load)"
    echo "    --install <key> [key...]           Install service(s) by key"
    echo "    --remove  <key> [key...]           Remove/uninstall service(s) by key"
    echo "    --backup                           Archive all service configs"
    echo "    --logs                             Show last 100 lines of appy.log"
    echo "    --version                          Print version"
    echo ""
    echo -e "  ${BOLD}Available service keys:${RESET}"
    echo "    ${KEYS[*]}" | fold -s -w 70 | sed 's/^/    /'
    echo ""
    echo -e "  ${BOLD}Environment variables:${RESET}"
    echo "    APPY_DAEMON_INTERVAL=<secs>        Watchdog check interval (default: 300)"
    echo "    APPY_NOTIFY_EMAIL=<email>          Email alerts (requires 'mail' command)"
    echo "    NO_COLOR=1                         Disable color output"
    echo ""
    echo -e "  ${BOLD}Examples:${RESET}"
    echo "    sudo bash appy.sh --install docker nginx postgres immich"
    echo "    sudo bash appy.sh --remove  nginx"
    echo "    sudo bash appy.sh --health"
    echo "    APPY_DAEMON_INTERVAL=120 sudo bash appy.sh --daemon"
    echo ""
    echo -e "  ${BOLD}Credentials:${RESET}"
    echo "    Generated passwords/tokens are saved to:  ~/appy-credentials.txt"
    echo "    (chmod 600 — readable only by you)"
    echo ""
    ;;

  *)
    # No argument or unrecognised → build install cache then launch interactive menu
    _prefetch_install_status
    main_menu
    ;;
esac
