#!/usr/bin/env bash
# =============================================================================
#  bashonacci.sh — CachyOS Edition
#  Intelligent post-install setup script for CachyOS / Arch Linux
#  Version: 1.0.0
#
#  Usage:
#    sudo bash setup-cachyos.sh --auto
#    sudo bash setup-cachyos.sh --interactive
#    sudo bash setup-cachyos.sh --config myserver.yml
#    sudo bash setup-cachyos.sh --rollback docker
#    sudo bash setup-cachyos.sh --list
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ─── Constants ────────────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="bashonacci-cachyos"
readonly LOG_FILE="/var/log/bashonacci-cachyos.log"
readonly LOG_HOME="${HOME}/bashonacci-cachyos-$(date +%Y%m%d-%H%M%S).log"
readonly STATE_DIR="/var/lib/bashonacci-cachyos"
readonly LOCK_FILE="/tmp/bashonacci-cachyos.lock"
readonly CONFIG_BACKUP_DIR="/etc/bashonacci/backups"

# ─── Colors ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m';   GREEN='\033[0;32m';  YELLOW='\033[1;33m'
  BLUE='\033[0;34m';  CYAN='\033[0;36m';   BOLD='\033[1m'
  DIM='\033[2m';      RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; DIM=''; RESET=''
fi

# ─── Global State ─────────────────────────────────────────────────────────────
MODE=""
CONFIG_FILE=""
ROLLBACK_TARGET=""
FORCE=false

HW_CPU_CORES=0
HW_CPU_THREADS=0
HW_CPU_MODEL=""
HW_CPU_ARCH=""
HW_RAM_TOTAL_GB=0
HW_RAM_AVAIL_GB=0
HW_SWAP_GB=0
HW_DISK_TYPE=""
HW_DISK_FREE_GB=0
HW_GPU_MODEL=""
HW_HAS_BATTERY=false
HW_PROFILE=""

declare -A SELECTED=()
declare -A INSTALLED=()

# ─── Logging ──────────────────────────────────────────────────────────────────
_log() {
  local level="$1"; shift
  local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
  local msg="[${ts}] [${level}] $*"
  echo "${msg}" >> "${LOG_FILE}"  2>/dev/null || true
  echo "${msg}" >> "${LOG_HOME}"  2>/dev/null || true
}

log_info()  { _log INFO  "$@"; echo -e "${GREEN}[✓]${RESET} $*"; }
log_warn()  { _log WARN  "$@"; echo -e "${YELLOW}[⚠]${RESET} $*"; }
log_error() { _log ERROR "$@"; echo -e "${RED}[✗]${RESET} $*" >&2; }
log_step()  { _log STEP  "$@"; echo -e "\n${BOLD}${BLUE}──── $* ────${RESET}"; }
log_debug() { _log DEBUG "$@"; }
log_cmd()   { _log CMD   "+ $*"; }

# ─── Utility ──────────────────────────────────────────────────────────────────
die() {
  echo -e "${RED}[✗]${RESET} $*" >&2
  _log ERROR "$@" 2>/dev/null || true
  exit 1
}

confirm() {
  local msg="$1"
  local answer
  echo -e "${YELLOW}[?]${RESET} ${msg} [y/N] " >&2
  read -r -t 30 answer || answer="n"
  [[ "${answer,,}" == "y" ]]
}

run_cmd() {
  log_cmd "$@"
  "$@" >> "${LOG_HOME}" 2>&1
}

# Check if a package is installed via pacman
is_installed() {
  pacman -Qi "$1" &>/dev/null
}

service_active() {
  systemctl is-active --quiet "$1" 2>/dev/null
}

port_in_use() {
  ss -tlnp 2>/dev/null | grep -q ":$1 "
}

mark_done() {
  mkdir -p "${STATE_DIR}"
  touch "${STATE_DIR}/$1.done"
}

is_done() {
  [[ -f "${STATE_DIR}/$1.done" ]]
}

remove_done() {
  rm -f "${STATE_DIR}/$1.done"
}

# Install via pacman (official repos)
pacin() {
  run_cmd pacman -S --noconfirm --needed "$@"
}

# Install via yay (AUR) — falls back to paru if yay not found
aurin() {
  if command -v yay &>/dev/null; then
    # yay must NOT run as root — run as the invoking user
    local real_user="${SUDO_USER:-${USER}}"
    run_cmd sudo -u "${real_user}" yay -S --noconfirm --needed "$@"
  elif command -v paru &>/dev/null; then
    local real_user="${SUDO_USER:-${USER}}"
    run_cmd sudo -u "${real_user}" paru -S --noconfirm --needed "$@"
  else
    log_warn "No AUR helper found (yay/paru). Installing yay first..."
    install_yay
    local real_user="${SUDO_USER:-${USER}}"
    run_cmd sudo -u "${real_user}" yay -S --noconfirm --needed "$@"
  fi
}

# ─── Lock ─────────────────────────────────────────────────────────────────────
acquire_lock() {
  if [[ -f "${LOCK_FILE}" ]]; then
    local pid; pid=$(cat "${LOCK_FILE}")
    if kill -0 "${pid}" 2>/dev/null; then
      die "Another instance is running (PID ${pid}). Abort."
    fi
    rm -f "${LOCK_FILE}"
  fi
  echo $$ > "${LOCK_FILE}"
  trap 'rm -f "${LOCK_FILE}"' EXIT
}

# ─── Pre-flight ───────────────────────────────────────────────────────────────
check_cachyos() {
  if [[ ! -f /etc/os-release ]]; then
    die "/etc/os-release not found. Cannot detect OS."
  fi
  # shellcheck source=/dev/null
  source /etc/os-release

  # Accept CachyOS, Arch, and any Arch-based distro
  local is_arch=false
  [[ "${ID:-}"      == "cachyos"  ]] && is_arch=true
  [[ "${ID:-}"      == "arch"     ]] && is_arch=true
  [[ "${ID_LIKE:-}" == *arch*     ]] && is_arch=true
  [[ "${ID_LIKE:-}" == *cachyos*  ]] && is_arch=true

  if ! ${is_arch}; then
    echo ""
    echo -e "${RED}[✗]${RESET} Detected: ${ID:-unknown}"
    echo "    This script is for CachyOS / Arch Linux."
    echo "    For Ubuntu/Debian use: sudo bash setup.sh --auto"
    echo ""
    die "Wrong OS for this script."
  fi

  # Confirm pacman is available
  if ! command -v pacman &>/dev/null; then
    die "pacman not found. This script requires an Arch-based system."
  fi

  log_info "OS: ${PRETTY_NAME:-CachyOS} — OK."
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo ""
    echo -e "${RED}[✗]${RESET} This script must run as root."
    echo ""
    echo "    Run with:"
    echo "      sudo bash $0 ${MODE:---auto}"
    echo ""
    exit 1
  fi
}

setup_logging() {
  mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
  touch "${LOG_FILE}" "${LOG_HOME}" 2>/dev/null || true
  _log INFO "=== ${SCRIPT_NAME} v${SCRIPT_VERSION} started ==="
  _log INFO "Mode: ${MODE}"
}

update_packages() {
  log_step "Updating package database"
  if is_done "pkg_update"; then
    log_info "Package database already updated this run — skipping."
    return
  fi
  run_cmd pacman -Sy
  mark_done "pkg_update"
}

backup_configs() {
  log_step "Backing up existing configs"
  mkdir -p "${CONFIG_BACKUP_DIR}"
  local files=(/etc/ssh/sshd_config /etc/ufw /etc/fail2ban /etc/crontab)
  for f in "${files[@]}"; do
    if [[ -e "$f" ]]; then
      local dest="${CONFIG_BACKUP_DIR}/$(basename "$f").bak.$(date +%s)"
      cp -a "$f" "$dest" 2>/dev/null && log_info "Backed up: $f" || true
    fi
  done
  # etckeeper snapshot if available
  if command -v etckeeper &>/dev/null; then
    etckeeper commit "bashonacci pre-run snapshot" 2>/dev/null || true
  fi
}

# ─── Hardware Detection ───────────────────────────────────────────────────────
detect_hardware() {
  log_step "Detecting hardware"

  HW_CPU_CORES=$(nproc --all 2>/dev/null || echo 1)
  HW_CPU_THREADS=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
  HW_CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "Unknown")
  HW_CPU_ARCH=$(uname -m)

  HW_RAM_TOTAL_GB=$(awk '/MemTotal/{printf "%.1f", $2/1024/1024}' /proc/meminfo)
  HW_RAM_AVAIL_GB=$(awk '/MemAvailable/{printf "%.1f", $2/1024/1024}' /proc/meminfo)
  HW_SWAP_GB=$(awk '/SwapTotal/{printf "%.1f", $2/1024/1024}' /proc/meminfo)

  local root_dev; root_dev=$(df / 2>/dev/null | tail -1 | awk '{print $1}' | sed 's|/dev/||;s|[0-9]*$||')
  if [[ -f "/sys/block/${root_dev}/queue/rotational" ]]; then
    local rot; rot=$(cat "/sys/block/${root_dev}/queue/rotational")
    if [[ "${rot}" == "0" ]]; then
      grep -qi "nvme" <<< "${root_dev}" 2>/dev/null && HW_DISK_TYPE="NVMe" || HW_DISK_TYPE="SSD"
    else
      HW_DISK_TYPE="HDD"
    fi
  else
    HW_DISK_TYPE="Unknown"
  fi
  HW_DISK_FREE_GB=$(df -BG / 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')

  if command -v lspci &>/dev/null; then
    HW_GPU_MODEL=$(lspci 2>/dev/null | grep -iE '(vga|3d|display)' | head -1 | sed 's/.*: //' || echo "None")
  else
    HW_GPU_MODEL="Unknown"
  fi

  ls /sys/class/power_supply/BAT* &>/dev/null 2>&1 && HW_HAS_BATTERY=true

  local ram_int; ram_int=$(echo "${HW_RAM_TOTAL_GB}" | cut -d. -f1)
  if (( ram_int < 1 )) || (( HW_CPU_CORES < 1 )) || (( HW_DISK_FREE_GB < 20 )); then
    HW_PROFILE="low"
  elif (( ram_int <= 4 )) && (( HW_CPU_CORES >= 2 )) && (( HW_DISK_FREE_GB >= 40 )); then
    HW_PROFILE="medium"
  else
    HW_PROFILE="high"
  fi

  echo -e "\n${BOLD}${CYAN}┌─────────────────────────────────────────┐${RESET}"
  echo -e "${BOLD}${CYAN}│         HARDWARE SUMMARY                │${RESET}"
  echo -e "${BOLD}${CYAN}├─────────────────────────────────────────┤${RESET}"
  printf "${CYAN}│${RESET}  %-12s %-27s ${CYAN}│${RESET}\n" "CPU:"    "${HW_CPU_MODEL:0:27}"
  printf "${CYAN}│${RESET}  %-12s %-27s ${CYAN}│${RESET}\n" "Cores:"  "${HW_CPU_CORES} cores / ${HW_CPU_THREADS} threads (${HW_CPU_ARCH})"
  printf "${CYAN}│${RESET}  %-12s %-27s ${CYAN}│${RESET}\n" "RAM:"    "${HW_RAM_TOTAL_GB} GB total, ${HW_RAM_AVAIL_GB} GB avail"
  printf "${CYAN}│${RESET}  %-12s %-27s ${CYAN}│${RESET}\n" "Disk:"   "${HW_DISK_TYPE}, ${HW_DISK_FREE_GB} GB free"
  printf "${CYAN}│${RESET}  %-12s %-27s ${CYAN}│${RESET}\n" "GPU:"    "${HW_GPU_MODEL:0:27}"
  printf "${CYAN}│${RESET}  %-12s ${BOLD}%-27s${RESET} ${CYAN}│${RESET}\n" "Profile:" "${HW_PROFILE^^}"
  echo -e "${BOLD}${CYAN}└─────────────────────────────────────────┘${RESET}\n"
}

# ─── yay installer (needed for AUR packages) ──────────────────────────────────
install_yay() {
  is_done "yay" && { log_info "yay already installed — skipping."; return; }
  log_step "Installing yay (AUR helper)"
  local real_user="${SUDO_USER:-${USER}}"
  local build_dir="/tmp/yay-build"

  pacin git base-devel

  rm -rf "${build_dir}"
  run_cmd sudo -u "${real_user}" git clone https://aur.archlinux.org/yay-bin.git "${build_dir}"
  cd "${build_dir}"
  run_cmd sudo -u "${real_user}" makepkg -si --noconfirm
  cd /
  rm -rf "${build_dir}"

  mark_done "yay"
  log_info "yay installed."
}

# ─── Component Registry ───────────────────────────────────────────────────────
# Format: COMPONENTS[key]="Category|Display Name|Min RAM GB|Min Cores|Min Disk GB|HDD OK"
declare -A COMPONENTS=(
  # Base
  [ufw]="Base|UFW Firewall|0|1|1|yes"
  [ssh]="Base|SSH Hardening|0|1|1|yes"
  [fail2ban]="Base|Fail2ban|0|1|1|yes"
  [etckeeper]="Base|etckeeper|0|1|1|yes"
  [timezone]="Base|Timezone Setup|0|1|1|yes"
  [reflector]="Base|Reflector (mirror ranking)|0|1|1|yes"
  [yay]="Base|yay (AUR helper)|0|1|1|yes"

  # Web
  [nginx]="Web|Nginx|1|1|5|yes"
  [caddy]="Web|Caddy|1|1|5|yes"
  [apache]="Web|Apache (httpd)|1|1|5|yes"

  # Database
  [mysql]="Database|MariaDB (MySQL-compat)|2|2|10|no"
  [postgresql]="Database|PostgreSQL|2|2|10|no"
  [sqlite]="Database|SQLite|0|1|1|yes"
  [redis]="Database|Redis|1|1|2|yes"

  # Containers
  [docker]="Container|Docker|2|2|10|yes"
  [podman]="Container|Podman|1|1|5|yes"
  [docker_compose]="Container|Docker Compose|2|2|5|yes"
  [k3s]="Orchestration|k3s (Kubernetes)|4|4|20|no"

  # Monitoring
  [htop]="Monitoring|htop|0|1|1|yes"
  [btop]="Monitoring|btop|0|1|1|yes"
  [glances]="Monitoring|Glances|0|1|1|yes"
  [net_tools]="Monitoring|net-tools|0|1|1|yes"
  [uptime_kuma]="Monitoring|Uptime Kuma|1|1|5|yes"
  [grafana_prometheus]="Monitoring|Grafana + Prometheus|4|2|10|yes"

  # Media
  [jellyfin]="Media|Jellyfin|4|4|20|no"
  [immich]="Media|Immich|4|4|20|yes"

  # Backup
  [borg]="Backup|BorgBackup|1|1|2|yes"
  [timeshift]="Backup|Timeshift|1|1|10|yes"

  # Security / VPN
  [wireguard]="Security|WireGuard|1|1|2|yes"
  [tailscale]="Security|Tailscale|1|1|2|yes"
  [vaultwarden]="Security|Vaultwarden|2|2|5|yes"

  # Networking
  [pihole]="Networking|Pi-hole|1|1|5|yes"
  [samba]="Networking|Samba|1|1|5|yes"
  [static_ip]="Networking|Static IP (NetworkManager)|0|1|1|yes"

  # Dev Tools
  [ollama]="DevTools|Ollama (LLM runtime)|8|4|20|yes"
  [gitea]="DevTools|Gitea|2|2|10|yes"
  [git]="DevTools|git|0|1|1|yes"
  [neovim]="DevTools|Neovim|0|1|1|yes"
  [zsh]="DevTools|Zsh + Oh-My-Zsh|0|1|1|yes"

  # Power
  [tlp]="Power|TLP (laptop power)|0|1|1|yes"
  [auto_cpufreq]="Power|auto-cpufreq|0|1|1|yes"

  # Communication
  [mumble]="Communication|Mumble Server|1|1|2|yes"

  # Home Automation
  [homeassistant]="HomeAuto|Home Assistant|2|2|10|yes"
)

# ─── Rule Engine ──────────────────────────────────────────────────────────────
evaluate_component() {
  local key="$1"
  local spec="${COMPONENTS[$key]:-}"
  [[ -z "${spec}" ]] && return 1

  IFS='|' read -r _ _ min_ram min_cores min_disk hdd_ok <<< "${spec}"

  local ram_int; ram_int=$(echo "${HW_RAM_TOTAL_GB}" | cut -d. -f1)
  (( ram_int      >= min_ram   )) || return 1
  (( HW_CPU_CORES >= min_cores )) || return 1
  (( HW_DISK_FREE_GB >= min_disk )) || return 1
  [[ "${hdd_ok}" == "no" && "${HW_DISK_TYPE}" == "HDD" ]] && return 1
  return 0
}

apply_rule_engine() {
  log_step "Applying rule engine — profile: ${HW_PROFILE^^}"

  # Always selected
  for key in yay reflector etckeeper timezone; do
    SELECTED[$key]=1
  done

  # Battery → power tools
  if ${HW_HAS_BATTERY}; then
    SELECTED[tlp]=1
    SELECTED[auto_cpufreq]=1
    log_info "Battery detected → TLP + auto-cpufreq selected."
  fi

  case "${HW_PROFILE}" in
    low)
      for key in htop btop net_tools sqlite git; do
        evaluate_component "${key}" && SELECTED[$key]=1
      done
      log_warn "LOW profile: Docker, databases and media servers blocked."
      ;;
    medium)
      for key in docker docker_compose nginx sqlite redis htop btop glances \
                 net_tools borg wireguard git neovim; do
        evaluate_component "${key}" && SELECTED[$key]=1
      done
      ;;
    high)
      for key in docker docker_compose nginx redis mysql postgresql htop btop \
                 glances net_tools borg wireguard tailscale gitea ollama git \
                 neovim zsh; do
        evaluate_component "${key}" && SELECTED[$key]=1
      done
      ;;
  esac
}

# ─── Interactive Mode ─────────────────────────────────────────────────────────
interactive_select() {
  log_step "Interactive Component Selection"
  echo -e "${DIM}Enter key names to toggle (space separated), blank to keep current.${RESET}\n"

  declare -A categories=()
  for key in "${!COMPONENTS[@]}"; do
    IFS='|' read -r cat _ <<< "${COMPONENTS[$key]}"
    categories[$cat]+=" ${key}"
  done

  for cat in Base Web Database Container Orchestration Monitoring Media Backup Security Networking DevTools Power Communication HomeAuto; do
    [[ -z "${categories[$cat]+_}" ]] && continue
    echo -e "\n${BOLD}${CYAN}── ${cat} ──${RESET}"
    for key in ${categories[$cat]}; do
      [[ -z "${COMPONENTS[$key]+_}" ]] && continue
      IFS='|' read -r _ display _ <<< "${COMPONENTS[$key]}"
      local marker=" "; local status="${DIM}[skip]${RESET}"
      [[ -n "${SELECTED[$key]+_}" ]] && marker="*" && status="${GREEN}[selected]${RESET}"
      ! evaluate_component "${key}" && status="${RED}[hw too low]${RESET}"
      printf "  %s %-28s %b\n" "${marker}" "${display}" "${status}"
    done
    echo -en "\n  Toggle keys (blank to skip): "
    read -r toggles
    for t in ${toggles}; do
      t="${t,,}"
      if [[ -n "${COMPONENTS[$t]+_}" ]]; then
        if [[ -n "${SELECTED[$t]+_}" ]]; then
          unset "SELECTED[$t]"; log_info "Deselected: ${t}"
        else
          SELECTED[$t]=1; log_info "Selected: ${t}"
        fi
      else
        log_warn "Unknown component: ${t}"
      fi
    done
  done

  confirm "Proceed with installation?" || die "Aborted."
}

# ─── Config File Mode ─────────────────────────────────────────────────────────
load_config() {
  local cfg="$1"
  [[ ! -f "${cfg}" ]] && die "Config file not found: ${cfg}"
  log_step "Loading config: ${cfg}"

  local in_components=false
  while IFS= read -r line; do
    line="${line%%#*}"
    [[ -z "${line// }" ]] && continue
    if echo "${line}" | grep -q "^components:"; then
      in_components=true
      local inline; inline=$(echo "${line}" | sed 's/components://;s/\[//g;s/\]//g;s/,/ /g')
      for key in ${inline}; do
        key=$(echo "${key}" | tr -d ' "'"'" | tr '[:upper:]' '[:lower:]')
        [[ -n "${COMPONENTS[$key]+_}" ]] && SELECTED[$key]=1
      done
    elif ${in_components}; then
      if echo "${line}" | grep -q "^  - \|^- "; then
        local key; key=$(echo "${line}" | sed 's/.*- //;s/"//g;s/ //g' | tr '[:upper:]' '[:lower:]')
        [[ -n "${COMPONENTS[$key]+_}" ]] && SELECTED[$key]=1 || log_warn "Unknown component: ${key}"
      else
        in_components=false
      fi
    fi
    if echo "${line}" | grep -q "^force:"; then
      local val; val=$(echo "${line}" | awk '{print $2}')
      [[ "${val,,}" == "true" ]] && FORCE=true
    fi
  done < "${cfg}"

  log_info "Loaded: ${!SELECTED[*]}"
}

# ─── Installers ───────────────────────────────────────────────────────────────

### Base ###

install_yay() {
  is_done "yay" && { log_info "yay already installed."; return; }
  if command -v yay &>/dev/null; then
    log_info "yay already present."
    mark_done "yay"; return
  fi
  log_step "Installing yay (AUR helper)"
  local real_user="${SUDO_USER:-${USER}}"
  local build_dir="/tmp/yay-build-$$"
  pacin git base-devel
  rm -rf "${build_dir}"
  sudo -u "${real_user}" git clone https://aur.archlinux.org/yay-bin.git "${build_dir}" >> "${LOG_HOME}" 2>&1
  cd "${build_dir}"
  sudo -u "${real_user}" makepkg -si --noconfirm >> "${LOG_HOME}" 2>&1
  cd /; rm -rf "${build_dir}"
  mark_done "yay"
  log_info "yay installed."
}

install_reflector() {
  is_done "reflector" && { log_info "Reflector already configured."; return; }
  log_step "Configuring Reflector (fastest mirrors)"
  pacin reflector
  reflector --country "${REFLECTOR_COUNTRY:-US,DE,GB}" \
            --latest 10 --sort rate \
            --save /etc/pacman.d/mirrorlist >> "${LOG_HOME}" 2>&1 || true
  mark_done "reflector"
  log_info "Mirrors ranked and saved."
}

install_etckeeper() {
  is_done "etckeeper" && { log_info "etckeeper already installed."; return; }
  log_step "Installing etckeeper"
  pacin etckeeper git
  if [[ ! -d /etc/.git ]]; then
    cd /etc && etckeeper init && etckeeper commit "Initial commit by ${SCRIPT_NAME}" 2>/dev/null || true
  fi
  mark_done "etckeeper"
  log_info "etckeeper initialized."
}

install_timezone() {
  is_done "timezone" && { log_info "Timezone already set."; return; }
  log_step "Configuring Timezone"
  local tz="UTC"
  if [[ "${MODE}" == "interactive" ]]; then
    echo -en "${YELLOW}[?]${RESET} Enter timezone (default UTC, e.g. America/New_York): "
    read -r tz_in; [[ -n "${tz_in}" ]] && tz="${tz_in}"
  fi
  run_cmd timedatectl set-timezone "${tz}"
  run_cmd timedatectl set-ntp true
  mark_done "timezone"
  log_info "Timezone: ${tz}, NTP enabled."
}

install_ufw() {
  is_done "ufw" && { log_info "UFW already configured."; return; }
  log_step "Configuring UFW"
  pacin ufw
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow OpenSSH
  run_cmd systemctl enable --now ufw
  confirm "Enable UFW firewall now?" && ufw --force enable
  mark_done "ufw"
  log_info "UFW configured."
}

install_ssh() {
  is_done "ssh" && { log_info "SSH already hardened."; return; }
  log_step "Hardening SSH"
  pacin openssh
  local cfg="/etc/ssh/sshd_config"
  _sshd_set() {
    local key="$1" val="$2"
    if grep -q "^${key}" "${cfg}"; then
      ${FORCE} && sed -i "s/^${key}.*/${key} ${val}/" "${cfg}"
    else
      echo "${key} ${val}" >> "${cfg}"
    fi
  }
  _sshd_set "PermitRootLogin"        "no"
  _sshd_set "PasswordAuthentication" "no"
  _sshd_set "X11Forwarding"          "no"
  _sshd_set "MaxAuthTries"           "3"
  run_cmd systemctl enable --now sshd
  mark_done "ssh"
  log_info "SSH hardened and enabled."
}

install_fail2ban() {
  is_done "fail2ban" && { log_info "Fail2ban already installed."; return; }
  log_step "Installing Fail2ban"
  pacin fail2ban
  if [[ ! -f /etc/fail2ban/jail.local ]] || ${FORCE}; then
    cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
backend = systemd
EOF
  fi
  run_cmd systemctl enable --now fail2ban
  mark_done "fail2ban"
  log_info "Fail2ban running."
}

### Web ###

install_nginx() {
  is_done "nginx" && { log_info "Nginx already installed."; return; }
  log_step "Installing Nginx"
  port_in_use 80 && ! ${FORCE} && { log_warn "Port 80 in use — skipping."; return; }
  pacin nginx
  run_cmd systemctl enable --now nginx
  command -v ufw &>/dev/null && ufw allow 'Nginx Full' 2>/dev/null || true
  mark_done "nginx"
  log_info "Nginx running."
}

install_caddy() {
  is_done "caddy" && { log_info "Caddy already installed."; return; }
  log_step "Installing Caddy"
  port_in_use 80 && ! ${FORCE} && { log_warn "Port 80 in use — skipping."; return; }
  pacin caddy
  run_cmd systemctl enable --now caddy
  mark_done "caddy"
  log_info "Caddy running."
}

install_apache() {
  is_done "apache" && { log_info "Apache already installed."; return; }
  log_step "Installing Apache"
  port_in_use 80 && ! ${FORCE} && { log_warn "Port 80 in use — skipping."; return; }
  pacin apache
  run_cmd systemctl enable --now httpd
  mark_done "apache"
  log_info "Apache running."
}

### Databases ###

install_mysql() {
  is_done "mysql" && { log_info "MariaDB already installed."; return; }
  log_step "Installing MariaDB (MySQL-compatible)"
  port_in_use 3306 && ! ${FORCE} && { log_warn "Port 3306 in use — skipping."; return; }
  confirm "MariaDB requires ≥2 GB RAM and SSD. Proceed?" || return
  pacin mariadb
  run_cmd mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql
  run_cmd systemctl enable --now mariadb
  local root_pass; root_pass=$(openssl rand -base64 16)
  mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${root_pass}';" 2>/dev/null || true
  echo "MariaDB root password: ${root_pass}" >> "${LOG_HOME}"
  mark_done "mysql"
  log_info "MariaDB installed. Root password saved to log."
}

install_postgresql() {
  is_done "postgresql" && { log_info "PostgreSQL already installed."; return; }
  log_step "Installing PostgreSQL"
  port_in_use 5432 && ! ${FORCE} && { log_warn "Port 5432 in use — skipping."; return; }
  pacin postgresql
  sudo -u postgres initdb -D /var/lib/postgres/data >> "${LOG_HOME}" 2>&1
  run_cmd systemctl enable --now postgresql
  mark_done "postgresql"
  log_info "PostgreSQL running."
}

install_sqlite() {
  is_done "sqlite" && { log_info "SQLite already installed."; return; }
  pacin sqlite
  mark_done "sqlite"; log_info "SQLite installed."
}

install_redis() {
  is_done "redis" && { log_info "Redis already installed."; return; }
  log_step "Installing Redis"
  pacin redis
  sed -i 's/^bind .*/bind 127.0.0.1 -::1/' /etc/redis/redis.conf 2>/dev/null || true
  run_cmd systemctl enable --now redis
  mark_done "redis"; log_info "Redis running (localhost only)."
}

### Containers ###

install_docker() {
  is_done "docker" && { log_info "Docker already installed."; return; }
  log_step "Installing Docker"
  if command -v docker &>/dev/null; then
    log_info "Docker already present."; mark_done "docker"; return
  fi
  pacin docker docker-buildx docker-compose
  run_cmd systemctl enable --now docker
  # Add invoking user to docker group
  local real_user="${SUDO_USER:-}"
  [[ -n "${real_user}" ]] && usermod -aG docker "${real_user}" && \
    log_info "Added ${real_user} to docker group. Re-login to apply."
  mark_done "docker"; log_info "Docker installed."
}

install_podman() {
  is_done "podman" && { log_info "Podman already installed."; return; }
  pacin podman
  mark_done "podman"; log_info "Podman installed."
}

install_docker_compose() {
  is_done "docker_compose" && { log_info "Docker Compose already installed."; return; }
  pacin docker-compose
  mark_done "docker_compose"; log_info "Docker Compose installed."
}

install_k3s() {
  is_done "k3s" && { log_info "k3s already installed."; return; }
  log_step "Installing k3s"
  local ram_int; ram_int=$(echo "${HW_RAM_TOTAL_GB}" | cut -d. -f1)
  (( ram_int < 4 )) && ! ${FORCE} && { log_warn "k3s needs ≥4 GB RAM. Use --force to override."; return; }
  confirm "Install k3s Kubernetes cluster?" || return
  curl -sfL https://get.k3s.io | sh -
  mark_done "k3s"; log_info "k3s installed."
}

### Monitoring ###

install_htop() {
  is_done "htop" && return
  pacin htop; mark_done "htop"; log_info "htop installed."
}

install_btop() {
  is_done "btop" && return
  pacin btop; mark_done "btop"; log_info "btop installed."
}

install_glances() {
  is_done "glances" && return
  pacin glances; mark_done "glances"; log_info "Glances installed."
}

install_net_tools() {
  is_done "net_tools" && return
  pacin net-tools curl wget; mark_done "net_tools"; log_info "net-tools installed."
}

install_uptime_kuma() {
  is_done "uptime_kuma" && { log_info "Uptime Kuma already running."; return; }
  log_step "Installing Uptime Kuma (Docker)"
  command -v docker &>/dev/null || { log_warn "Docker required — install Docker first."; return; }
  docker run -d --restart=always -p 3001:3001 \
    -v uptime-kuma:/app/data --name uptime-kuma louislam/uptime-kuma:1 2>/dev/null || true
  mark_done "uptime_kuma"; log_info "Uptime Kuma → http://localhost:3001"
}

install_grafana_prometheus() {
  is_done "grafana_prometheus" && { log_info "Grafana+Prometheus already installed."; return; }
  log_step "Installing Grafana + Prometheus"
  pacin prometheus grafana
  run_cmd systemctl enable --now prometheus grafana
  mark_done "grafana_prometheus"
  log_info "Grafana → http://localhost:3000 (admin/admin — change it)"
}

### Media ###

install_jellyfin() {
  is_done "jellyfin" && { log_info "Jellyfin already installed."; return; }
  log_step "Installing Jellyfin (AUR)"
  [[ "${HW_DISK_TYPE}" == "HDD" ]] && log_warn "HDD detected: transcoding will be slow."
  aurin jellyfin
  run_cmd systemctl enable --now jellyfin
  mark_done "jellyfin"; log_info "Jellyfin → http://localhost:8096"
}

install_immich() {
  is_done "immich" && { log_info "Immich already installed."; return; }
  log_step "Installing Immich (Docker Compose)"
  command -v docker &>/dev/null || { log_warn "Docker required."; return; }
  mkdir -p /opt/immich && cd /opt/immich
  curl -fsSL https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml -o docker-compose.yml
  curl -fsSL https://github.com/immich-app/immich/releases/latest/download/.env.example -o .env
  docker compose up -d
  mark_done "immich"; log_info "Immich → http://localhost:2283"
}

### Backup ###

install_borg() {
  is_done "borg" && return
  pacin borg; mark_done "borg"; log_info "BorgBackup installed."
}

install_timeshift() {
  is_done "timeshift" && return
  log_step "Installing Timeshift (AUR)"
  aurin timeshift
  mark_done "timeshift"; log_info "Timeshift installed."
}

### Security / VPN ###

install_wireguard() {
  is_done "wireguard" && return
  log_step "Installing WireGuard"
  pacin wireguard-tools
  mark_done "wireguard"; log_info "WireGuard installed. Config: /etc/wireguard/"
}

install_tailscale() {
  is_done "tailscale" && return
  log_step "Installing Tailscale"
  pacin tailscale
  run_cmd systemctl enable --now tailscaled
  mark_done "tailscale"; log_info "Tailscale installed. Run: tailscale up"
}

install_vaultwarden() {
  is_done "vaultwarden" && return
  log_step "Installing Vaultwarden (Docker)"
  command -v docker &>/dev/null || { log_warn "Docker required."; return; }
  docker run -d --name vaultwarden \
    -v /opt/vaultwarden:/data \
    -p 8080:80 --restart unless-stopped \
    vaultwarden/server:latest 2>/dev/null || true
  mark_done "vaultwarden"; log_info "Vaultwarden → http://localhost:8080"
}

### Networking ###

install_pihole() {
  is_done "pihole" && return
  log_step "Installing Pi-hole"
  port_in_use 53 && log_warn "Port 53 in use — Pi-hole may conflict."
  curl -sSL https://install.pi-hole.net | bash /dev/stdin --unattended
  mark_done "pihole"; log_info "Pi-hole installed."
}

install_samba() {
  is_done "samba" && return
  log_step "Installing Samba"
  pacin samba
  run_cmd systemctl enable --now smb nmb
  mark_done "samba"; log_info "Samba running."
}

install_static_ip() {
  is_done "static_ip" && return
  log_step "Static IP Configuration (NetworkManager)"
  local iface; iface=$(ip route | grep default | awk '{print $5}' | head -1)
  local curr_ip; curr_ip=$(ip -4 addr show "${iface}" 2>/dev/null | grep -oP '(?<=inet )\S+' || echo "unknown")
  log_info "Interface: ${iface}, current IP: ${curr_ip}"
  log_warn "Use 'nmtui' or 'nmcli' to set a static IP on CachyOS."
  mark_done "static_ip"
}

### Dev Tools ###

install_git() {
  is_done "git" && return
  pacin git; mark_done "git"; log_info "git installed."
}

install_neovim() {
  is_done "neovim" && return
  pacin neovim; mark_done "neovim"; log_info "Neovim installed."
}

install_zsh() {
  is_done "zsh" && return
  log_step "Installing Zsh + Oh-My-Zsh"
  pacin zsh
  local real_user="${SUDO_USER:-${USER}}"
  sudo -u "${real_user}" sh -c \
    'RUNZSH=no CHSH=no curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh | bash' \
    >> "${LOG_HOME}" 2>&1 || true
  chsh -s /bin/zsh "${real_user}" 2>/dev/null || true
  mark_done "zsh"; log_info "Zsh + Oh-My-Zsh installed."
}

install_ollama() {
  is_done "ollama" && return
  log_step "Installing Ollama"
  curl -fsSL https://ollama.ai/install.sh | sh
  run_cmd systemctl enable --now ollama
  mark_done "ollama"; log_info "Ollama installed. Run: ollama run llama3"
}

install_gitea() {
  is_done "gitea" && return
  log_step "Installing Gitea (Docker)"
  command -v docker &>/dev/null || { log_warn "Docker required."; return; }
  docker run -d --name=gitea \
    -p 3000:3000 -p 222:22 \
    -v /opt/gitea:/data \
    --restart unless-stopped \
    gitea/gitea:latest 2>/dev/null || true
  mark_done "gitea"; log_info "Gitea → http://localhost:3000"
}

### Power ###

install_tlp() {
  is_done "tlp" && return
  log_step "Installing TLP"
  pacin tlp tlp-rdw
  run_cmd systemctl enable --now tlp
  mark_done "tlp"; log_info "TLP running."
}

install_auto_cpufreq() {
  is_done "auto_cpufreq" && return
  log_step "Installing auto-cpufreq (AUR)"
  aurin auto-cpufreq
  run_cmd systemctl enable --now auto-cpufreq
  mark_done "auto_cpufreq"; log_info "auto-cpufreq running."
}

### Communication ###

install_mumble() {
  is_done "mumble" && return
  pacin murmur
  run_cmd systemctl enable --now murmur
  mark_done "mumble"; log_info "Mumble server running."
}

### Home Automation ###

install_homeassistant() {
  is_done "homeassistant" && return
  log_step "Installing Home Assistant (Docker)"
  command -v docker &>/dev/null || { log_warn "Docker required."; return; }
  docker run -d --name homeassistant \
    --restart=unless-stopped \
    -v /opt/homeassistant:/config \
    --network=host \
    ghcr.io/home-assistant/home-assistant:stable 2>/dev/null || true
  mark_done "homeassistant"; log_info "Home Assistant → http://localhost:8123"
}

# ─── Execution Engine ─────────────────────────────────────────────────────────
INSTALL_ORDER=(
  yay reflector etckeeper timezone ufw ssh fail2ban tlp auto_cpufreq
  docker podman
  sqlite redis mysql postgresql
  nginx caddy apache
  docker_compose k3s
  uptime_kuma grafana_prometheus jellyfin immich
  borg timeshift wireguard tailscale vaultwarden
  pihole samba static_ip
  htop btop glances net_tools
  ollama gitea git neovim zsh
  mumble homeassistant
)

run_installations() {
  log_step "Installing ${#SELECTED[@]} selected components"
  for key in "${INSTALL_ORDER[@]}"; do
    [[ -z "${SELECTED[$key]+_}" ]] && continue
    local fn="install_${key}"
    if declare -f "${fn}" &>/dev/null; then
      "${fn}" || log_warn "${fn} exited with error — continuing."
    else
      log_warn "No installer for: ${key}"
    fi
  done
}

# ─── Rollback ─────────────────────────────────────────────────────────────────
rollback_component() {
  local target="$1"
  log_step "Rolling back: ${target}"
  case "${target}" in
    docker)      run_cmd pacman -Rns --noconfirm docker docker-buildx docker-compose || true ;;
    nginx)       run_cmd pacman -Rns --noconfirm nginx    || true ;;
    mysql)       run_cmd pacman -Rns --noconfirm mariadb  || true ;;
    postgresql)  run_cmd pacman -Rns --noconfirm postgresql || true ;;
    redis)       run_cmd pacman -Rns --noconfirm redis    || true ;;
    tailscale)   run_cmd pacman -Rns --noconfirm tailscale || true ;;
    wireguard)   run_cmd pacman -Rns --noconfirm wireguard-tools || true ;;
    fail2ban)    systemctl stop fail2ban; run_cmd pacman -Rns --noconfirm fail2ban || true ;;
    tlp)         systemctl stop tlp; run_cmd pacman -Rns --noconfirm tlp tlp-rdw || true ;;
    *)           run_cmd pacman -Rns --noconfirm "${target}" || true ;;
  esac
  remove_done "${target}"
  command -v etckeeper &>/dev/null && etckeeper commit "Rollback: ${target}" 2>/dev/null || true
  log_info "Rollback of ${target} complete."
}

# ─── Post-Install ─────────────────────────────────────────────────────────────
post_install() {
  log_step "Installation Complete"
  echo -e "\n${BOLD}${GREEN}╔══════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${GREEN}║        BASHONACCI — DONE                 ║${RESET}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════╝${RESET}\n"
  echo -e "  ${BOLD}Log:${RESET}   ${LOG_HOME}"
  echo -e "  ${BOLD}State:${RESET} ${STATE_DIR}\n"
  echo -e "  ${BOLD}Installed:${RESET}"
  for key in "${!SELECTED[@]}"; do echo -e "    ${GREEN}✓${RESET} ${key}"; done
  echo ""
  [[ -n "${SELECTED[mysql]+_}" ]]              && log_warn "MariaDB root password → ${LOG_HOME}"
  [[ -n "${SELECTED[grafana_prometheus]+_}" ]] && log_warn "Grafana: admin/admin → change at http://localhost:3000"
  [[ -f /var/run/reboot-required ]] && confirm "Reboot now?" && reboot
}

# ─── Help & List ──────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
${BOLD}${SCRIPT_NAME} v${SCRIPT_VERSION}${RESET}

Usage:
  sudo bash $0 --auto
  sudo bash $0 --interactive
  sudo bash $0 --config FILE.yml
  sudo bash $0 --rollback COMPONENT
  sudo bash $0 --list

Flags:
  --force   Override hardware gates
  --help    Show this help
EOF
}

list_components() {
  echo -e "\n${BOLD}Available Components:${RESET}"
  for key in $(echo "${!COMPONENTS[@]}" | tr ' ' '\n' | sort); do
    IFS='|' read -r cat display _ <<< "${COMPONENTS[$key]}"
    printf "  %-24s %-16s %s\n" "${key}" "[${cat}]" "${display}"
  done
  echo ""
}

# ─── Argument Parsing ─────────────────────────────────────────────────────────
parse_args() {
  [[ $# -eq 0 ]] && { usage; exit 0; }
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auto)        MODE="auto"                              ;;
      --interactive) MODE="interactive"                       ;;
      --config)      MODE="config"; CONFIG_FILE="${2:-}"; shift ;;
      --rollback)    ROLLBACK_TARGET="${2:-}"; shift          ;;
      --force)       FORCE=true                               ;;
      --list)        list_components; exit 0                  ;;
      --help|-h)     usage; exit 0                            ;;
      *) echo -e "${RED}[✗]${RESET} Unknown argument: $1"; usage; exit 1 ;;
    esac
    shift
  done

  if [[ -n "${ROLLBACK_TARGET}" ]]; then
    check_root
    check_cachyos
    setup_logging
    rollback_component "${ROLLBACK_TARGET}"
    exit 0
  fi

  [[ -z "${MODE}" ]] && { echo -e "${RED}[✗]${RESET} Specify a mode: --auto, --interactive, or --config FILE"; exit 1; }
  [[ "${MODE}" == "config" && -z "${CONFIG_FILE}" ]] && { echo -e "${RED}[✗]${RESET} --config requires a file path"; exit 1; }
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  check_root
  check_cachyos
  setup_logging
  acquire_lock
  detect_hardware

  case "${MODE}" in
    auto)        apply_rule_engine ;;
    interactive) apply_rule_engine; interactive_select ;;
    config)      load_config "${CONFIG_FILE}" ;;
  esac

  update_packages
  backup_configs
  run_installations
  post_install
}

main "$@"
