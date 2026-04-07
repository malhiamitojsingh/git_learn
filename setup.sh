#!/usr/bin/env bash
# =============================================================================
# Simple Service Installer for CachyOS/Arch Linux
# Usage: sudo ./setup.sh [service1 service2 ...]
#        sudo ./setup.sh --list
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RESET='\033[0m'

log_info()  { echo -e "${GREEN}[✓]${RESET} $*"; }
log_warn()  { echo -e "${YELLOW}[⚠]${RESET} $*"; }
log_error() { echo -e "${RED}[✗]${RESET} $*" >&2; }
log_step()  { echo -e "\n${BLUE}▶${RESET} $*"; }

# Check root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Check Arch-based system
check_system() {
    if ! command -v pacman &>/dev/null; then
        log_error "pacman not found - not an Arch-based system"
        exit 1
    fi
}

# Install AUR helper if needed
ensure_aur_helper() {
    if command -v yay &>/dev/null; then
        return 0
    fi
    
    log_step "Installing yay (AUR helper)"
    local user="${SUDO_USER:-$USER}"
    
    pacman -S --noconfirm --needed git base-devel
    sudo -u "$user" git clone https://aur.archlinux.org/yay-bin.git /tmp/yay-build
    pushd /tmp/yay-build > /dev/null
    sudo -u "$user" makepkg -si --noconfirm
    popd > /dev/null
    rm -rf /tmp/yay-build
    
    log_info "yay installed"
}

# Package installers
install_pacman() { pacman -S --noconfirm --needed "$@"; }
install_aur()    { sudo -u "${SUDO_USER:-$USER}" yay -S --noconfirm --needed "$@"; }

# Service definitions
declare -A SERVICES=(
    # Format: [name]="type:package:service_name:display"
    [docker]="pacman:docker:docker:Docker container runtime"
    [nginx]="pacman:nginx:nginx:Nginx web server"
    [caddy]="pacman:caddy:caddy:Caddy web server"
    [mysql]="pacman:mariadb:mariadb:MySQL/MariaDB database"
    [postgres]="pacman:postgresql:postgresql:PostgreSQL database"
    [redis]="pacman:redis:redis:Redis cache server"
    [fail2ban]="pacman:fail2ban:fail2ban:Brute force protection"
    [ufw]="pacman:ufw:ufw:Uncomplicated Firewall"
    [jellyfin]="aur:jellyfin:jellyfin:Jellyfin media server"
    [tailscale]="pacman:tailscale:tailscaled:Tailscale VPN"
    [wireguard]="pacman:wireguard-tools:wg-quick@:WireGuard VPN"
    [btop]="pacman:btop:none:System monitor (btop)"
    [htop]="pacman:htop:none:Process viewer (htop)"
    [neovim]="pacman:neovim:none:Neovim editor"
    [zsh]="pacman:zsh:none:Zsh shell + Oh-My-Zsh"
    [ollama]="curl:ollama:ollama:Ollama LLM runtime"
)

# Install function
install_service() {
    local name="$1"
    local spec="${SERVICES[$name]:-}"
    
    if [[ -z "$spec" ]]; then
        log_error "Unknown service: $name"
        return 1
    fi
    
    IFS=':' read -r type pkg service display <<< "$spec"
    log_step "Installing: $display"
    
    # Check if already installed
    if [[ "$type" != "curl" ]] && pacman -Qi "$pkg" &>/dev/null 2>&1; then
        log_info "Already installed: $pkg"
        return 0
    fi
    
    # Install based on type
    case "$type" in
        pacman) install_pacman "$pkg" ;;
        aur)    ensure_aur_helper; install_aur "$pkg" ;;
        curl)   curl -fsSL https://ollama.ai/install.sh | sh ;;
        *)      log_error "Unknown type: $type"; return 1 ;;
    esac
    
    # Enable service if specified
    if [[ "$service" != "none" ]] && [[ -n "$service" ]]; then
        if systemctl enable --now "$service" 2>/dev/null; then
            log_info "Service enabled: $service"
        else
            log_warn "Could not enable service: $service"
        fi
    fi
    
    log_info "Installed: $display"
}

# Interactive menu
interactive_menu() {
    echo -e "\n${BLUE}Available Services:${RESET}\n"
    
    local services_list=()
    local i=1
    for name in "${!SERVICES[@]}"; do
        IFS=':' read -r _ _ _ display <<< "${SERVICES[$name]}"
        printf "  %2d) %-15s - %s\n" "$i" "$name" "$display"
        services_list+=("$name")
        ((i++))
    done
    
    echo -e "\n${YELLOW}Enter numbers to install (space-separated, or 'all'):${RESET} "
    read -r selection
    
    if [[ "$selection" == "all" ]]; then
        for name in "${services_list[@]}"; do
            install_service "$name"
        done
    else
        for num in $selection; do
            if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#services_list[@]} )); then
                install_service "${services_list[$((num-1))]}"
            else
                log_warn "Invalid selection: $num"
            fi
        done
    fi
}

# List services
list_services() {
    echo -e "\n${BLUE}Available Services:${RESET}\n"
    printf "  %-15s %s\n" "NAME" "DESCRIPTION"
    printf "  %-15s %s\n" "----" "-----------"
    for name in $(echo "${!SERVICES[@]}" | tr ' ' '\n' | sort); do
        IFS=':' read -r _ _ _ display <<< "${SERVICES[$name]}"
        printf "  %-15s %s\n" "$name" "$display"
    done
    echo ""
}

# Main
main() {
    check_root
    check_system
    
    if [[ $# -eq 0 ]] || [[ "$1" == "--interactive" ]]; then
        interactive_menu
    elif [[ "$1" == "--list" ]]; then
        list_services
    elif [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
        echo "Usage: sudo $0 [--interactive|--list|service1 service2 ...]"
        echo ""
        echo "  --interactive  - Interactive menu selection"
        echo "  --list         - List all available services"
        echo "  --help         - Show this help"
        echo ""
        echo "Examples:"
        echo "  sudo $0 --interactive"
        echo "  sudo $0 docker nginx postgres"
        echo "  sudo $0 jellyfin tailscale"
        exit 0
    else
        # Install specified services
        for service in "$@"; do
            install_service "$service"
        done
    fi
    
    echo -e "\n${GREEN}✓ Setup complete!${RESET}"
}

main "$@"
