#!/usr/bin/env bash
# =============================================================================
#  UbuntuAutoSetup — Intelligent Post-Install Server Configuration Script
#  Version: 1.0.0
#  Author:  ShellCraft Team
#  License: MIT
#
#  Usage:
#    ./setup.sh --auto
#    ./setup.sh --interactive
#    ./setup.sh --config myserver.yml
#    ./setup.sh --rollback docker
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ─── Constants ────────────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="UbuntuAutoSetup"
readonly LOG_FILE="/var/log/ubuntu-auto-setup.log"
readonly LOG_HOME="${HOME}/ubuntu-auto-setup-$(date +%Y%m%d-%H%M%S).log"
readonly STATE_DIR="/var/lib/ubuntu-auto-setup"
readonly LOCK_FILE="/tmp/ubuntu-auto-setup.lock"
readonly CONFIG_BACKUP_DIR="/etc/ubuntu-auto-setup/backups"

# ─── Colors ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m';   GREEN='\033[0;32m';  YELLOW='\033[1;33m'
  BLUE='\033[0;34m';  CYAN='\033[0;36m';   BOLD='\033[1m'
  DIM='\033[2m';      RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; DIM=''; RESET=''
fi

# ─── Global State ─────────────────────────────────────────────────────────────
MODE=""           # auto | interactive | config
CONFIG_FILE=""
ROLLBACK_TARGET=""
FORCE=false

# Hardware profile
HW_CPU_CORES=0
HW_CPU_THREADS=0
HW_CPU_MODEL=""
HW_CPU_ARCH=""
HW_RAM_TOTAL_GB=0
HW_RAM_AVAIL_GB=0
HW_SWAP_GB=0
HW_DISK_TYPE=""       # HDD | SSD | NVMe | Unknown
HW_DISK_FREE_GB=0
HW_GPU_MODEL=""
HW_HAS_BATTERY=false
HW_PROFILE=""         # low | medium | high

# Selected components (populated by rule engine or user)
declare -A SELECTED=()

# Installed tracker (for idempotency)
declare -A INSTALLED=()

# ─── Logging ──────────────────────────────────────────────────────────────────
_log() {
  local level="$1"; shift
  local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
  local msg="[${ts}] [${level}] $*"
  echo "${msg}" >> "${LOG_FILE}" 2>/dev/null || true
  echo "${msg}" >> "${LOG_HOME}"  2>/dev/null || true
}

log_info()  { _log INFO  "$@"; echo -e "${GREEN}[✓]${RESET} $*"; }
log_warn()  { _log WARN  "$@"; echo -e "${YELLOW}[⚠]${RESET} $*"; }
log_error() { _log ERROR "$@"; echo -e "${RED}[✗]${RESET} $*" >&2; }
log_step()  { _log STEP  "$@"; echo -e "\n${BOLD}${BLUE}──── $* ────${RESET}"; }
log_debug() { _log DEBUG "$@"; }
log_cmd()   { _log CMD   "+ $*"; }

# ─── Utility ──────────────────────────────────────────────────────────────────
die() { log_error "$@"; exit 1; }

confirm() {
  # confirm "message" → returns 0 (yes) or 1 (no)
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

is_installed() {
  dpkg -l "$1" 2>/dev/null | grep -q "^ii"
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

# ─── Lock ────────────────────────────────────────────────────────────────────
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
check_ubuntu() {
  if [[ ! -f /etc/os-release ]]; then
    die "Cannot detect OS. /etc/os-release not found. This script targets Ubuntu (bare-metal or VM)."
  fi
  # shellcheck source=/dev/null
  source /etc/os-release

  # Support Ubuntu directly, or Ubuntu running inside a VM on any host (CachyOS Boxes,
  # virt-manager, VirtualBox, etc.). ID_LIKE catches Ubuntu-derived distros like Mint.
  local is_ubuntu=false
  [[ "${ID:-}"       == "ubuntu" ]] && is_ubuntu=true
  [[ "${ID_LIKE:-}"  == *ubuntu* ]] && is_ubuntu=true

  if ! ${is_ubuntu}; then
    echo ""
    echo -e "${RED}[✗]${RESET} Detected OS: ${ID:-unknown}"
    echo ""
    echo "    This script is designed for Ubuntu Server (20.04, 22.04, 24.04)."
    echo "    It appears you may be running it on your HOST machine (${ID:-unknown})"
    echo "    instead of inside the Ubuntu VM."
    echo ""
    echo "    If you are using GNOME Boxes or virt-manager on CachyOS / Arch:"
    echo "      1. Open your Ubuntu Server VM"
    echo "      2. Copy setup.sh into the VM (or re-run the curl command inside it)"
    echo "      3. Run: sudo bash setup.sh --auto"
    echo ""
    die "Wrong OS. Run this script inside the Ubuntu VM, not on the host."
  fi

  local ver_major; ver_major=$(echo "${VERSION_ID:-0}" | cut -d. -f1)
  if (( ver_major < 20 )); then
    die "Ubuntu ${VERSION_ID} is too old. Minimum supported: 20.04."
  fi
  log_info "OS: Ubuntu ${VERSION_ID} (${UBUNTU_CODENAME:-unknown}) — OK."
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo ""
    echo -e "${RED}[✗]${RESET} This script must run as root."
    echo ""
    echo "    Re-run with sudo:"
    echo "      sudo bash $0 ${MODE:---auto}"
    echo ""
    echo "    If sudo is not yet configured on this fresh Ubuntu install:"
    echo "      su -                        # switch to root"
    echo "      bash $0 ${MODE:---auto}     # run directly as root"
    echo ""
    exit 1
  fi
}

setup_logging() {
  mkdir -p "$(dirname "${LOG_FILE}")" "${HOME}" 2>/dev/null || true
  touch "${LOG_FILE}" "${LOG_HOME}" 2>/dev/null || true
  _log INFO "=== ${SCRIPT_NAME} v${SCRIPT_VERSION} started ==="
  _log INFO "Mode: ${MODE}"
}

update_packages() {
  log_step "Updating package lists"
  if is_done "pkg_update"; then
    log_info "Package lists already updated this run — skipping."
    return
  fi
  run_cmd apt-get update -qq
  mark_done "pkg_update"
}

backup_configs() {
  log_step "Backing up existing configs"
  mkdir -p "${CONFIG_BACKUP_DIR}"
  local files=(/etc/ssh/sshd_config /etc/ufw /etc/fail2ban /etc/crontab)
  for f in "${files[@]}"; do
    if [[ -e "$f" ]]; then
      local dest="${CONFIG_BACKUP_DIR}/$(basename "$f").bak.$(date +%s)"
      cp -a "$f" "$dest" 2>/dev/null && log_info "Backed up: $f → $dest" || true
    fi
  done

  # etckeeper snapshot if available
  if command -v etckeeper &>/dev/null; then
    etckeeper commit "UbuntuAutoSetup pre-run snapshot" 2>/dev/null || true
  fi
}

# ─── Hardware Detection ───────────────────────────────────────────────────────
detect_hardware() {
  log_step "Detecting system hardware"

  # CPU
  HW_CPU_CORES=$(nproc --all 2>/dev/null || echo 1)
  HW_CPU_THREADS=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
  HW_CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "Unknown")
  HW_CPU_ARCH=$(uname -m)

  # RAM
  HW_RAM_TOTAL_GB=$(awk '/MemTotal/{printf "%.1f", $2/1024/1024}' /proc/meminfo)
  HW_RAM_AVAIL_GB=$(awk '/MemAvailable/{printf "%.1f", $2/1024/1024}' /proc/meminfo)
  HW_SWAP_GB=$(awk '/SwapTotal/{printf "%.1f", $2/1024/1024}' /proc/meminfo)

  # Disk type
  local root_dev; root_dev=$(df / 2>/dev/null | tail -1 | awk '{print $1}' | sed 's|/dev/||;s|[0-9]*$||')
  if [[ -f "/sys/block/${root_dev}/queue/rotational" ]]; then
    local rot; rot=$(cat "/sys/block/${root_dev}/queue/rotational")
    if [[ "${rot}" == "0" ]]; then
      if [[ -d "/sys/block/${root_dev}/device" ]] && grep -qi "nvme" <<< "${root_dev}" 2>/dev/null; then
        HW_DISK_TYPE="NVMe"
      else
        HW_DISK_TYPE="SSD"
      fi
    else
      HW_DISK_TYPE="HDD"
    fi
  else
    HW_DISK_TYPE="Unknown"
  fi
  HW_DISK_FREE_GB=$(df -BG / 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')

  # GPU
  if command -v lspci &>/dev/null; then
    HW_GPU_MODEL=$(lspci 2>/dev/null | grep -iE '(vga|3d|display)' | head -1 | sed 's/.*: //' || echo "None")
  else
    HW_GPU_MODEL="Unknown (lspci not available)"
  fi

  # Battery
  if ls /sys/class/power_supply/BAT* &>/dev/null 2>&1; then
    HW_HAS_BATTERY=true
  fi

  # Classify
  local ram_int; ram_int=$(echo "${HW_RAM_TOTAL_GB}" | cut -d. -f1)
  if (( ram_int < 1 )) || (( HW_CPU_CORES < 1 )) || (( HW_DISK_FREE_GB < 20 )); then
    HW_PROFILE="low"
  elif (( ram_int <= 4 )) && (( HW_CPU_CORES >= 2 )) && (( HW_DISK_FREE_GB >= 40 )); then
    HW_PROFILE="medium"
  else
    HW_PROFILE="high"
  fi

  _print_hw_summary
}

_print_hw_summary() {
  echo -e "\n${BOLD}${CYAN}┌─────────────────────────────────────────┐${RESET}"
  echo -e "${BOLD}${CYAN}│         HARDWARE SUMMARY                │${RESET}"
  echo -e "${BOLD}${CYAN}├─────────────────────────────────────────┤${RESET}"
  printf "${CYAN}│${RESET}  %-12s %-27s ${CYAN}│${RESET}\n" "CPU:"    "${HW_CPU_MODEL:0:27}"
  printf "${CYAN}│${RESET}  %-12s %-27s ${CYAN}│${RESET}\n" "Cores:"  "${HW_CPU_CORES} cores / ${HW_CPU_THREADS} threads  (${HW_CPU_ARCH})"
  printf "${CYAN}│${RESET}  %-12s %-27s ${CYAN}│${RESET}\n" "RAM:"    "${HW_RAM_TOTAL_GB} GB total, ${HW_RAM_AVAIL_GB} GB available"
  printf "${CYAN}│${RESET}  %-12s %-27s ${CYAN}│${RESET}\n" "Swap:"   "${HW_SWAP_GB} GB"
  printf "${CYAN}│${RESET}  %-12s %-27s ${CYAN}│${RESET}\n" "Disk:"   "${HW_DISK_TYPE}, ${HW_DISK_FREE_GB} GB free"
  printf "${CYAN}│${RESET}  %-12s %-27s ${CYAN}│${RESET}\n" "GPU:"    "${HW_GPU_MODEL:0:27}"
  printf "${CYAN}│${RESET}  %-12s %-27s ${CYAN}│${RESET}\n" "Battery:" "${HW_HAS_BATTERY}"
  printf "${CYAN}│${RESET}  %-12s ${BOLD}%-27s${RESET} ${CYAN}│${RESET}\n" "Profile:" "${HW_PROFILE^^}"
  echo -e "${BOLD}${CYAN}└─────────────────────────────────────────┘${RESET}\n"
}

# ─── Component Registry ───────────────────────────────────────────────────────
# Format: COMPONENTS[key]="Category|Display Name|Min RAM(GB)|Min Cores|Min Disk(GB)|HDD OK"
declare -A COMPONENTS=(
  # Base System
  [ufw]="Base|UFW Firewall|0|1|1|yes"
  [ssh]="Base|SSH Hardening|0|1|1|yes"
  [unattended_upgrades]="Base|Unattended Upgrades|0|1|1|yes"
  [timezone]="Base|Timezone Setup|0|1|1|yes"
  [fail2ban]="Base|Fail2ban|0|1|1|yes"
  [certbot]="Base|Certbot (Let's Encrypt)|0|1|2|yes"
  [etckeeper]="Base|etckeeper|0|1|1|yes"

  # Web Servers
  [nginx]="Web|Nginx|1|1|5|yes"
  [caddy]="Web|Caddy|1|1|5|yes"
  [apache]="Web|Apache2|1|1|5|yes"

  # Databases
  [mysql]="Database|MySQL|2|2|10|no"
  [postgresql]="Database|PostgreSQL|2|2|10|no"
  [sqlite]="Database|SQLite|0|1|1|yes"
  [redis]="Database|Redis|1|1|2|yes"

  # Containers
  [docker]="Container|Docker|2|2|10|yes"
  [podman]="Container|Podman|1|1|5|yes"

  # Orchestration
  [docker_compose]="Orchestration|Docker Compose|2|2|5|yes"
  [k3s]="Orchestration|k3s (Kubernetes)|4|4|20|no"

  # Monitoring
  [htop]="Monitoring|htop|0|1|1|yes"
  [glances]="Monitoring|Glances|0|1|1|yes"
  [net_tools]="Monitoring|net-tools|0|1|1|yes"
  [uptime_kuma]="Monitoring|Uptime Kuma|1|1|5|yes"
  [grafana_prometheus]="Monitoring|Grafana + Prometheus|4|2|10|yes"

  # Media
  [jellyfin]="Media|Jellyfin|4|4|20|no"
  [plex]="Media|Plex Media Server|4|4|20|no"
  [immich]="Media|Immich (Photos)|4|4|20|yes"

  # Backup
  [duplicati]="Backup|Duplicati|2|2|5|yes"
  [borg]="Backup|BorgBackup|1|1|2|yes"

  # Security/VPN
  [wireguard]="Security|WireGuard VPN|1|1|2|yes"
  [tailscale]="Security|Tailscale|1|1|2|yes"
  [vaultwarden]="Security|Vaultwarden|2|2|5|yes"
  [authelia]="Security|Authelia|2|2|5|yes"

  # Cloud/Productivity
  [nextcloud]="Cloud|Nextcloud|4|2|20|yes"
  [paperless]="Cloud|Paperless-ngx|4|2|20|yes"

  # Communication
  [matrix]="Communication|Matrix (Synapse)|4|2|20|yes"
  [mumble]="Communication|Mumble Server|1|1|2|yes"

  # Home Automation
  [homeassistant]="HomeAuto|Home Assistant|2|2|10|yes"

  # Networking
  [pihole]="Networking|Pi-hole|1|1|5|yes"
  [samba]="Networking|Samba|1|1|5|yes"
  [static_ip]="Networking|Static IP Config|0|1|1|yes"

  # Dev Tools
  [ollama]="DevTools|Ollama (LLM runtime)|8|4|20|yes"
  [gitea]="DevTools|Gitea|2|2|10|yes"

  # Power (laptop)
  [tlp]="Power|TLP (Laptop Power)|0|1|1|yes"
)

# ─── Rule Engine ──────────────────────────────────────────────────────────────
evaluate_component() {
  local key="$1"
  local spec="${COMPONENTS[$key]:-}"
  [[ -z "${spec}" ]] && return 1

  IFS='|' read -r _ _ min_ram min_cores min_disk hdd_ok <<< "${spec}"

  local ram_int; ram_int=$(echo "${HW_RAM_TOTAL_GB}" | cut -d. -f1)

  (( ram_int  >= min_ram  )) || return 1
  (( HW_CPU_CORES >= min_cores )) || return 1
  (( HW_DISK_FREE_GB >= min_disk )) || return 1

  if [[ "${hdd_ok}" == "no" && "${HW_DISK_TYPE}" == "HDD" ]]; then
    return 1
  fi

  return 0
}

apply_rule_engine() {
  log_step "Applying rule engine based on ${HW_PROFILE^^} profile"

  # Base hardening always selected
  for key in ufw ssh unattended_upgrades timezone fail2ban etckeeper; do
    SELECTED[$key]=1
  done

  # Battery → TLP
  if ${HW_HAS_BATTERY}; then
    SELECTED[tlp]=1
    log_info "Battery detected → TLP selected."
  fi

  # Profile-based selections
  case "${HW_PROFILE}" in
    low)
      for key in htop glances net_tools sqlite; do
        evaluate_component "${key}" && SELECTED[$key]=1
      done
      log_warn "LOW profile: Docker, databases, and media servers are blocked."
      ;;
    medium)
      for key in docker docker_compose nginx sqlite redis htop glances net_tools certbot uptime_kuma borg; do
        evaluate_component "${key}" && SELECTED[$key]=1
      done
      log_warn "MEDIUM profile: MySQL/PostgreSQL and Jellyfin transcoding require confirmation."
      ;;
    high)
      for key in docker docker_compose nginx redis mysql postgresql htop glances net_tools \
                 certbot uptime_kuma borg wireguard tailscale gitea ollama; do
        evaluate_component "${key}" && SELECTED[$key]=1
      done
      log_info "HIGH profile: Full stack available."
      ;;
  esac
}

# ─── Interactive Mode ─────────────────────────────────────────────────────────
interactive_select() {
  log_step "Interactive Component Selection"
  echo -e "${DIM}Navigate with arrow keys, toggle with SPACE, confirm with ENTER.${RESET}"
  echo -e "${DIM}(Showing rule-engine recommendations — you may override.)${RESET}\n"

  # Group by category
  declare -A categories=()
  for key in "${!COMPONENTS[@]}"; do
    IFS='|' read -r cat display _ <<< "${COMPONENTS[$key]}"
    categories[$cat]+=" ${key}"
  done

  for cat in Base Web Database Container Orchestration Monitoring Media Backup Security Cloud Communication HomeAuto Networking DevTools Power; do
    [[ -z "${categories[$cat]+_}" ]] && continue
    echo -e "\n${BOLD}${CYAN}── ${cat} ──${RESET}"
    for key in ${categories[$cat]}; do
      [[ -z "${COMPONENTS[$key]+_}" ]] && continue
      IFS='|' read -r _ display min_ram min_cores min_disk hdd_ok <<< "${COMPONENTS[$key]}"
      local status="${DIM}[skip]${RESET}"
      local marker=" "
      if [[ -n "${SELECTED[$key]+_}" ]]; then
        status="${GREEN}[selected]${RESET}"
        marker="*"
      fi
      if ! evaluate_component "${key}"; then
        status="${RED}[blocked: hw too low]${RESET}"
      fi
      printf "  ${marker} %-28s %b\n" "${display}" "${status}"
    done
    echo -en "\n  Toggle (enter key names separated by space, blank to skip): "
    read -r toggles
    for t in ${toggles}; do
      t=$(echo "${t}" | tr '[:upper:]' '[:lower:]')
      if [[ -n "${COMPONENTS[$t]+_}" ]]; then
        if ! evaluate_component "${t}" && ! ${FORCE}; then
          log_warn "Cannot enable '${t}': hardware requirements not met. Use --force to override."
          continue
        fi
        if [[ -n "${SELECTED[$t]+_}" ]]; then
          unset "SELECTED[$t]"
          log_info "Deselected: ${t}"
        else
          SELECTED[$t]=1
          log_info "Selected: ${t}"
        fi
      else
        log_warn "Unknown component: ${t}"
      fi
    done
  done

  echo ""
  log_info "Selected components: ${!SELECTED[*]}"
  confirm "Proceed with installation?" || die "Aborted by user."
}

# ─── Config File Mode ─────────────────────────────────────────────────────────
load_config() {
  local cfg="$1"
  [[ ! -f "${cfg}" ]] && die "Config file not found: ${cfg}"
  log_step "Loading config: ${cfg}"

  # Parse YAML-like: components: [docker, nginx, mysql]
  local in_components=false
  while IFS= read -r line; do
    # Strip comments
    line="${line%%#*}"
    [[ -z "${line// }" ]] && continue

    if echo "${line}" | grep -q "^components:"; then
      in_components=true
      # Inline list: components: [docker, nginx]
      local inline; inline=$(echo "${line}" | sed 's/components://;s/\[//g;s/\]//g;s/,/ /g')
      for key in ${inline}; do
        key=$(echo "${key}" | tr -d ' "'"'" | tr '[:upper:]' '[:lower:]')
        [[ -n "${COMPONENTS[$key]+_}" ]] && SELECTED[$key]=1
      done
    elif ${in_components}; then
      if echo "${line}" | grep -q "^  - \|^- "; then
        local key; key=$(echo "${line}" | sed 's/.*- //;s/"//g;s/ //g' | tr '[:upper:]' '[:lower:]')
        [[ -n "${COMPONENTS[$key]+_}" ]] && SELECTED[$key]=1 || log_warn "Unknown component in config: ${key}"
      else
        in_components=false
      fi
    fi

    # Other top-level keys
    if echo "${line}" | grep -q "^force:"; then
      local val; val=$(echo "${line}" | awk '{print $2}')
      [[ "${val,,}" == "true" ]] && FORCE=true
    fi
  done < "${cfg}"

  log_info "Loaded from config: ${!SELECTED[*]}"
}

# ─── Installers ───────────────────────────────────────────────────────────────

### Base ###

install_ufw() {
  is_done "ufw" && { log_info "UFW already configured — skipping."; return; }
  log_step "Configuring UFW Firewall"
  run_cmd apt-get install -y -qq ufw
  # Don't overwrite existing rules unless --force
  if ufw status | grep -q "Status: active" && ! ${FORCE}; then
    log_info "UFW already active — preserving rules."
  else
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow OpenSSH
    confirm "Enable UFW? (will activate firewall rules)" && ufw --force enable
  fi
  mark_done "ufw"
  log_info "UFW configured."
}

install_ssh() {
  is_done "ssh" && { log_info "SSH hardening already done — skipping."; return; }
  log_step "Hardening SSH"
  local cfg="/etc/ssh/sshd_config"
  # Idempotent: only set if not already configured
  _sshd_set() {
    local key="$1" val="$2"
    if grep -q "^${key}" "${cfg}"; then
      ${FORCE} && sed -i "s/^${key}.*/${key} ${val}/" "${cfg}"
    else
      echo "${key} ${val}" >> "${cfg}"
    fi
  }
  _sshd_set "PermitRootLogin"    "no"
  _sshd_set "PasswordAuthentication" "no"
  _sshd_set "X11Forwarding"     "no"
  _sshd_set "MaxAuthTries"      "3"
  _sshd_set "LoginGraceTime"    "20"
  run_cmd systemctl reload ssh || run_cmd systemctl reload sshd
  mark_done "ssh"
  log_info "SSH hardened."
}

install_unattended_upgrades() {
  is_done "unattended_upgrades" && { log_info "Unattended upgrades already configured — skipping."; return; }
  log_step "Enabling Unattended Security Upgrades"
  run_cmd apt-get install -y -qq unattended-upgrades
  echo 'Unattended-Upgrade::Automatic-Reboot "false";' > /etc/apt/apt.conf.d/99uas-no-reboot 2>/dev/null || true
  run_cmd dpkg-reconfigure -plow unattended-upgrades || true
  mark_done "unattended_upgrades"
  log_info "Unattended upgrades enabled."
}

install_timezone() {
  is_done "timezone" && { log_info "Timezone already set — skipping."; return; }
  log_step "Configuring Timezone"
  local tz="UTC"
  if [[ "${MODE}" == "interactive" ]]; then
    echo -en "${YELLOW}[?]${RESET} Enter timezone (default UTC, e.g. America/New_York): "
    read -r tz_in
    [[ -n "${tz_in}" ]] && tz="${tz_in}"
  fi
  run_cmd timedatectl set-timezone "${tz}"
  mark_done "timezone"
  log_info "Timezone set to ${tz}."
}

install_fail2ban() {
  is_done "fail2ban" && { log_info "Fail2ban already configured — skipping."; return; }
  log_step "Installing Fail2ban"
  run_cmd apt-get install -y -qq fail2ban
  if [[ ! -f /etc/fail2ban/jail.local ]] || ${FORCE}; then
    cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
EOF
  fi
  run_cmd systemctl enable --now fail2ban
  mark_done "fail2ban"
  log_info "Fail2ban installed and running."
}

install_certbot() {
  is_done "certbot" && { log_info "Certbot already installed — skipping."; return; }
  log_step "Installing Certbot"
  run_cmd apt-get install -y -qq certbot python3-certbot-nginx
  mark_done "certbot"
  log_info "Certbot installed. Run: certbot --nginx -d yourdomain.com"
}

install_etckeeper() {
  is_done "etckeeper" && { log_info "etckeeper already installed — skipping."; return; }
  log_step "Installing etckeeper (/etc version control)"
  run_cmd apt-get install -y -qq etckeeper git
  if [[ ! -d /etc/.git ]] || ${FORCE}; then
    cd /etc && etckeeper init && etckeeper commit "Initial commit by ${SCRIPT_NAME}" 2>/dev/null || true
  fi
  mark_done "etckeeper"
  log_info "etckeeper initialized."
}

### Web Servers ###

install_nginx() {
  is_done "nginx" && { log_info "Nginx already installed — skipping."; return; }
  log_step "Installing Nginx"
  port_in_use 80  && ! ${FORCE} && { log_warn "Port 80 in use — skipping Nginx."; return; }
  port_in_use 443 && ! ${FORCE} && { log_warn "Port 443 in use — skipping Nginx."; return; }
  run_cmd apt-get install -y -qq nginx
  run_cmd systemctl enable --now nginx
  command -v ufw &>/dev/null && ufw allow 'Nginx Full' 2>/dev/null || true
  mark_done "nginx"
  log_info "Nginx installed and running."
}

install_caddy() {
  is_done "caddy" && { log_info "Caddy already installed — skipping."; return; }
  log_step "Installing Caddy"
  port_in_use 80  && ! ${FORCE} && { log_warn "Port 80 in use — skipping Caddy."; return; }
  run_cmd apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | tee /etc/apt/sources.list.d/caddy-stable.list
  run_cmd apt-get update -qq
  run_cmd apt-get install -y -qq caddy
  run_cmd systemctl enable --now caddy
  mark_done "caddy"
  log_info "Caddy installed."
}

install_apache() {
  is_done "apache" && { log_info "Apache already installed — skipping."; return; }
  log_step "Installing Apache2"
  port_in_use 80 && ! ${FORCE} && { log_warn "Port 80 in use — skipping Apache."; return; }
  run_cmd apt-get install -y -qq apache2
  run_cmd systemctl enable --now apache2
  mark_done "apache"
  log_info "Apache2 installed."
}

### Databases ###

install_mysql() {
  is_done "mysql" && { log_info "MySQL already installed — skipping."; return; }
  log_step "Installing MySQL"
  port_in_use 3306 && ! ${FORCE} && { log_warn "Port 3306 in use — skipping MySQL."; return; }
  if ! confirm "MySQL requires ≥2 GB RAM and SSD storage. Proceed?"; then return; fi
  run_cmd apt-get install -y -qq mysql-server
  run_cmd systemctl enable --now mysql
  local root_pass; root_pass=$(openssl rand -base64 16)
  mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${root_pass}';" 2>/dev/null || true
  echo "MySQL root password: ${root_pass}" >> "${LOG_HOME}"
  log_info "MySQL installed. Root password saved to log."
  mark_done "mysql"
}

install_postgresql() {
  is_done "postgresql" && { log_info "PostgreSQL already installed — skipping."; return; }
  log_step "Installing PostgreSQL"
  port_in_use 5432 && ! ${FORCE} && { log_warn "Port 5432 in use — skipping PostgreSQL."; return; }
  run_cmd apt-get install -y -qq postgresql postgresql-contrib
  run_cmd systemctl enable --now postgresql
  mark_done "postgresql"
  log_info "PostgreSQL installed."
}

install_sqlite() {
  is_done "sqlite" && { log_info "SQLite already installed — skipping."; return; }
  log_step "Installing SQLite"
  run_cmd apt-get install -y -qq sqlite3
  mark_done "sqlite"
  log_info "SQLite installed."
}

install_redis() {
  is_done "redis" && { log_info "Redis already installed — skipping."; return; }
  log_step "Installing Redis"
  run_cmd apt-get install -y -qq redis-server
  # Bind to localhost only
  sed -i 's/^bind .*/bind 127.0.0.1 -::1/' /etc/redis/redis.conf 2>/dev/null || true
  run_cmd systemctl enable --now redis-server
  mark_done "redis"
  log_info "Redis installed (localhost-only)."
}

### Containers ###

install_docker() {
  is_done "docker" && { log_info "Docker already installed — skipping."; return; }
  log_step "Installing Docker"
  if command -v docker &>/dev/null; then
    log_info "Docker binary already present — skipping install."
    mark_done "docker"; return
  fi
  run_cmd apt-get install -y -qq ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME}") stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null
  run_cmd apt-get update -qq
  run_cmd apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  run_cmd systemctl enable --now docker
  mark_done "docker"
  log_info "Docker installed."
}

install_podman() {
  is_done "podman" && { log_info "Podman already installed — skipping."; return; }
  log_step "Installing Podman"
  run_cmd apt-get install -y -qq podman
  mark_done "podman"
  log_info "Podman installed."
}

### Orchestration ###

install_docker_compose() {
  is_done "docker_compose" && { log_info "Docker Compose already installed — skipping."; return; }
  log_step "Installing Docker Compose (standalone)"
  if command -v docker-compose &>/dev/null; then
    log_info "docker-compose already present."; mark_done "docker_compose"; return
  fi
  local ver; ver=$(curl -fsSL https://api.github.com/repos/docker/compose/releases/latest \
    | grep '"tag_name"' | cut -d'"' -f4)
  curl -fsSL "https://github.com/docker/compose/releases/download/${ver}/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
  mark_done "docker_compose"
  log_info "Docker Compose ${ver} installed."
}

install_k3s() {
  is_done "k3s" && { log_info "k3s already installed — skipping."; return; }
  log_step "Installing k3s (lightweight Kubernetes)"
  local ram_int; ram_int=$(echo "${HW_RAM_TOTAL_GB}" | cut -d. -f1)
  if (( ram_int < 4 )) && ! ${FORCE}; then
    log_warn "k3s requires ≥4 GB RAM. Current: ${HW_RAM_TOTAL_GB} GB. Use --force to override."
    return
  fi
  confirm "k3s will install a full Kubernetes cluster. Continue?" || return
  curl -sfL https://get.k3s.io | sh -
  mark_done "k3s"
  log_info "k3s installed. Config: /etc/rancher/k3s/k3s.yaml"
}

### Monitoring ###

install_htop() {
  is_done "htop" && { log_info "htop already installed — skipping."; return; }
  run_cmd apt-get install -y -qq htop
  mark_done "htop"; log_info "htop installed."
}

install_glances() {
  is_done "glances" && { log_info "Glances already installed — skipping."; return; }
  log_step "Installing Glances"
  run_cmd apt-get install -y -qq glances
  mark_done "glances"; log_info "Glances installed."
}

install_net_tools() {
  is_done "net_tools" && { log_info "net-tools already installed — skipping."; return; }
  run_cmd apt-get install -y -qq net-tools curl wget
  mark_done "net_tools"; log_info "net-tools installed."
}

install_uptime_kuma() {
  is_done "uptime_kuma" && { log_info "Uptime Kuma already installed — skipping."; return; }
  log_step "Installing Uptime Kuma (via Docker)"
  if ! command -v docker &>/dev/null; then
    log_warn "Docker required for Uptime Kuma. Install Docker first."; return
  fi
  docker run -d --restart=always -p 3001:3001 \
    -v uptime-kuma:/app/data --name uptime-kuma louislam/uptime-kuma:1 2>/dev/null || true
  mark_done "uptime_kuma"
  log_info "Uptime Kuma running at http://localhost:3001"
}

install_grafana_prometheus() {
  is_done "grafana_prometheus" && { log_info "Grafana+Prometheus already installed — skipping."; return; }
  log_step "Installing Grafana + Prometheus"
  # Prometheus
  run_cmd apt-get install -y -qq prometheus prometheus-node-exporter
  run_cmd systemctl enable --now prometheus prometheus-node-exporter
  # Grafana
  apt-get install -y -qq software-properties-common
  wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor \
    > /usr/share/keyrings/grafana.gpg
  echo "deb [signed-by=/usr/share/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    > /etc/apt/sources.list.d/grafana.list
  run_cmd apt-get update -qq
  run_cmd apt-get install -y -qq grafana
  run_cmd systemctl enable --now grafana-server
  mark_done "grafana_prometheus"
  log_info "Grafana running at http://localhost:3000 (admin/admin)"
}

### Media ###

install_jellyfin() {
  is_done "jellyfin" && { log_info "Jellyfin already installed — skipping."; return; }
  log_step "Installing Jellyfin"
  if [[ "${HW_DISK_TYPE}" == "HDD" ]]; then
    log_warn "HDD detected: Jellyfin transcoding will be slow."
    confirm "Continue anyway?" || return
  fi
  curl -fsSL https://repo.jellyfin.org/install-debuntu.sh | bash
  run_cmd systemctl enable --now jellyfin
  mark_done "jellyfin"
  log_info "Jellyfin installed at http://localhost:8096"
}

install_immich() {
  is_done "immich" && { log_info "Immich already installed — skipping."; return; }
  log_step "Installing Immich (via Docker Compose)"
  if ! command -v docker &>/dev/null; then
    log_warn "Docker required for Immich."; return
  fi
  mkdir -p /opt/immich && cd /opt/immich
  curl -fsSL https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml -o docker-compose.yml
  curl -fsSL https://github.com/immich-app/immich/releases/latest/download/.env.example -o .env
  docker compose up -d
  mark_done "immich"
  log_info "Immich running at http://localhost:2283"
}

### Backup ###

install_borg() {
  is_done "borg" && { log_info "BorgBackup already installed — skipping."; return; }
  log_step "Installing BorgBackup"
  run_cmd apt-get install -y -qq borgbackup
  mark_done "borg"; log_info "BorgBackup installed."
}

### Security/VPN ###

install_wireguard() {
  is_done "wireguard" && { log_info "WireGuard already installed — skipping."; return; }
  log_step "Installing WireGuard"
  run_cmd apt-get install -y -qq wireguard
  mark_done "wireguard"; log_info "WireGuard installed. Configure: /etc/wireguard/wg0.conf"
}

install_tailscale() {
  is_done "tailscale" && { log_info "Tailscale already installed — skipping."; return; }
  log_step "Installing Tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh
  mark_done "tailscale"; log_info "Tailscale installed. Run: tailscale up"
}

install_vaultwarden() {
  is_done "vaultwarden" && { log_info "Vaultwarden already installed — skipping."; return; }
  log_step "Installing Vaultwarden (via Docker)"
  if ! command -v docker &>/dev/null; then
    log_warn "Docker required for Vaultwarden."; return
  fi
  docker run -d --name vaultwarden \
    -v /opt/vaultwarden/:/data/ \
    -p 8080:80 \
    --restart unless-stopped \
    vaultwarden/server:latest 2>/dev/null || true
  mark_done "vaultwarden"
  log_info "Vaultwarden running at http://localhost:8080"
}

### Networking ###

install_pihole() {
  is_done "pihole" && { log_info "Pi-hole already installed — skipping."; return; }
  log_step "Installing Pi-hole"
  port_in_use 53 && { log_warn "Port 53 in use — Pi-hole may conflict."; }
  curl -sSL https://install.pi-hole.net | bash /dev/stdin --unattended
  mark_done "pihole"; log_info "Pi-hole installed."
}

install_samba() {
  is_done "samba" && { log_info "Samba already installed — skipping."; return; }
  log_step "Installing Samba"
  run_cmd apt-get install -y -qq samba
  run_cmd systemctl enable --now smbd
  mark_done "samba"; log_info "Samba installed."
}

install_static_ip() {
  is_done "static_ip" && { log_info "Static IP already configured — skipping."; return; }
  log_step "Configuring Static IP"
  local iface; iface=$(ip route | grep default | awk '{print $5}' | head -1)
  local curr_ip; curr_ip=$(ip -4 addr show "${iface}" | grep -oP '(?<=inet )\S+')
  log_info "Current interface: ${iface}, IP: ${curr_ip}"
  log_warn "Netplan config: edit /etc/netplan/01-static.yaml manually for your setup."
  mark_done "static_ip"
}

### Dev Tools ###

install_ollama() {
  is_done "ollama" && { log_info "Ollama already installed — skipping."; return; }
  log_step "Installing Ollama (LLM runtime)"
  curl -fsSL https://ollama.ai/install.sh | sh
  run_cmd systemctl enable --now ollama
  mark_done "ollama"; log_info "Ollama installed. Run: ollama run llama3"
}

install_gitea() {
  is_done "gitea" && { log_info "Gitea already installed — skipping."; return; }
  log_step "Installing Gitea (via Docker)"
  if ! command -v docker &>/dev/null; then
    log_warn "Docker required for Gitea."; return
  fi
  docker run -d --name=gitea \
    -p 3000:3000 -p 222:22 \
    -v /opt/gitea:/data \
    --restart unless-stopped \
    gitea/gitea:latest 2>/dev/null || true
  mark_done "gitea"
  log_info "Gitea running at http://localhost:3000"
}

### Power ###

install_tlp() {
  is_done "tlp" && { log_info "TLP already installed — skipping."; return; }
  log_step "Installing TLP (laptop power management)"
  run_cmd apt-get install -y -qq tlp tlp-rdw
  run_cmd systemctl enable --now tlp
  mark_done "tlp"; log_info "TLP installed."
}

# ─── Execution Engine ─────────────────────────────────────────────────────────
# Ordered execution as per state machine
INSTALL_ORDER=(
  # Phase 1: Base Hardening
  etckeeper timezone ssh ufw unattended_upgrades fail2ban certbot tlp
  # Phase 2: Containers/Runtimes
  docker podman
  # Phase 3: Databases
  sqlite redis mysql postgresql
  # Phase 4: Web Servers
  nginx caddy apache
  # Phase 5: Orchestration
  docker_compose k3s
  # Phase 6: Application Services
  uptime_kuma grafana_prometheus jellyfin immich
  borg wireguard tailscale vaultwarden authelia
  nextcloud paperless matrix mumble homeassistant
  pihole samba static_ip
  htop glances net_tools
  ollama gitea
)

run_installations() {
  log_step "Beginning Installation (${#SELECTED[@]} components selected)"

  for key in "${INSTALL_ORDER[@]}"; do
    [[ -z "${SELECTED[$key]+_}" ]] && continue
    local fn="install_${key}"
    if declare -f "${fn}" &>/dev/null; then
      # Re-detect hardware before heavy components
      case "${key}" in
        k3s|mysql|postgresql|jellyfin|grafana_prometheus|ollama|nextcloud)
          detect_hardware &>/dev/null || true
          ;;
      esac
      "${fn}" || log_warn "Installer '${fn}' exited with error — continuing."
    else
      log_warn "No installer function for: ${key}"
    fi
  done
}

# ─── Rollback ─────────────────────────────────────────────────────────────────
rollback_component() {
  local target="$1"
  log_step "Rolling back: ${target}"
  case "${target}" in
    docker)
      run_cmd apt-get purge -y docker-ce docker-ce-cli containerd.io || true
      remove_done "docker"
      ;;
    nginx)
      run_cmd apt-get purge -y nginx || true
      remove_done "nginx"
      ;;
    mysql)
      run_cmd apt-get purge -y mysql-server || true
      remove_done "mysql"
      ;;
    postgresql)
      run_cmd apt-get purge -y postgresql || true
      remove_done "postgresql"
      ;;
    ufw)
      run_cmd ufw --force reset || true
      run_cmd apt-get purge -y ufw || true
      remove_done "ufw"
      ;;
    fail2ban)
      run_cmd systemctl stop fail2ban || true
      run_cmd apt-get purge -y fail2ban || true
      remove_done "fail2ban"
      ;;
    k3s)
      /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true
      remove_done "k3s"
      ;;
    tailscale)
      run_cmd apt-get purge -y tailscale || true
      remove_done "tailscale"
      ;;
    *)
      # Generic: purge by package name
      run_cmd apt-get purge -y "${target}" || true
      remove_done "${target}"
      ;;
  esac
  log_info "Rollback of ${target} complete."
  # etckeeper snapshot after rollback
  command -v etckeeper &>/dev/null && etckeeper commit "Rollback: ${target}" 2>/dev/null || true
}

# ─── Post-Install ─────────────────────────────────────────────────────────────
post_install() {
  log_step "Post-Install Summary"
  echo -e "\n${BOLD}${GREEN}╔═══════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${GREEN}║       INSTALLATION COMPLETE               ║${RESET}"
  echo -e "${BOLD}${GREEN}╚═══════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "  ${BOLD}Log file:${RESET}  ${LOG_HOME}"
  echo -e "  ${BOLD}State dir:${RESET} ${STATE_DIR}"
  echo ""
  echo -e "  ${BOLD}Installed components:${RESET}"
  for key in "${!SELECTED[@]}"; do
    echo -e "    ${GREEN}✓${RESET} ${key}"
  done
  echo ""

  # Credentials reminder
  if [[ -n "${SELECTED[mysql]+_}" ]]; then
    log_warn "MySQL root password is in: ${LOG_HOME}"
  fi
  if [[ -n "${SELECTED[grafana_prometheus]+_}" ]]; then
    log_info "Grafana default: admin/admin → change immediately at http://localhost:3000"
  fi

  # Reboot prompt
  if [[ -f /var/run/reboot-required ]]; then
    log_warn "A reboot is required to complete some installations."
    confirm "Reboot now?" && reboot
  fi
}

# ─── Argument Parsing ─────────────────────────────────────────────────────────
usage() {
  cat <<EOF
${BOLD}${SCRIPT_NAME} v${SCRIPT_VERSION}${RESET}

Usage:
  sudo ./setup.sh --auto                  Fully automatic mode
  sudo ./setup.sh --interactive           Interactive selection
  sudo ./setup.sh --config FILE.yml       Config file mode
  sudo ./setup.sh --rollback COMPONENT    Rollback a component
  sudo ./setup.sh --list                  List all available components

Flags:
  --force     Override hardware warnings and existing-config protection
  --help      Show this help

Examples:
  sudo ./setup.sh --auto
  sudo ./setup.sh --config myserver.yml
  sudo ./setup.sh --rollback docker
EOF
}

list_components() {
  echo -e "\n${BOLD}Available Components:${RESET}"
  for key in $(echo "${!COMPONENTS[@]}" | tr ' ' '\n' | sort); do
    IFS='|' read -r cat display _ <<< "${COMPONENTS[$key]}"
    printf "  %-22s %-15s %s\n" "${key}" "[${cat}]" "${display}"
  done
  echo ""
}

parse_args() {
  [[ $# -eq 0 ]] && { usage; exit 0; }
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auto)        MODE="auto"                       ;;
      --interactive) MODE="interactive"                ;;
      --config)      MODE="config"; CONFIG_FILE="${2:-}"; shift ;;
      --rollback)    ROLLBACK_TARGET="${2:-}"; shift   ;;
      --force)       FORCE=true                        ;;
      --list)        list_components; exit 0           ;;
      --help|-h)     usage; exit 0                     ;;
      *) die "Unknown argument: $1. Run with --help."  ;;
    esac
    shift
  done

  # Rollback is standalone
  if [[ -n "${ROLLBACK_TARGET}" ]]; then
    check_root
    check_ubuntu
    setup_logging
    rollback_component "${ROLLBACK_TARGET}"
    exit 0
  fi

  [[ -z "${MODE}" ]] && die "Specify a mode: --auto, --interactive, or --config FILE"
  [[ "${MODE}" == "config" && -z "${CONFIG_FILE}" ]] && die "--config requires a file path"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  check_root           # must be first — no point locking if we can't run
  check_ubuntu         # before logging so errors print clearly to terminal
  setup_logging        # safe now: root confirmed, Ubuntu confirmed, /var/log writable
  acquire_lock         # after logging so lock errors are captured
  detect_hardware

  case "${MODE}" in
    auto)
      apply_rule_engine
      ;;
    interactive)
      apply_rule_engine
      interactive_select
      ;;
    config)
      load_config "${CONFIG_FILE}"
      ;;
  esac

  update_packages
  backup_configs
  run_installations
  post_install
}

main "$@"
