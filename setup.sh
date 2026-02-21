#!/usr/bin/env bash
#
# cgit setup — Cloudflare Tunnel -> Anubis -> lighttpd -> cgit
# Zero public ports — all traffic via outbound-only tunnel
# Designed for VPS as small as 256 MB RAM / 1 vCPU
# Tested on: Debian 12 / Ubuntu 22.04+
#
# Usage:
#   Interactive:    sudo ./setup.sh
#   Non-interactive: sudo CGIT_DOMAIN=git.example.com ./setup.sh --yes
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==========================================================================
# TUI library — pure bash, zero deps beyond tput (ncurses-base)
# ==========================================================================

# Detect terminal capabilities
if [[ -t 0 || -e /dev/tty ]] && command -v tput &>/dev/null; then
    TERM_COLS="$(tput cols 2>/dev/null || echo 80)"
    TERM_BOLD="$(tput bold 2>/dev/null || true)"
    TERM_DIM="$(tput dim 2>/dev/null || true)"
    TERM_RESET="$(tput sgr0 2>/dev/null || true)"
    TERM_CLEAR_LINE="\033[2K\r"
    HAS_TTY=1
else
    TERM_COLS=80
    TERM_BOLD=""
    TERM_DIM=""
    TERM_RESET=""
    TERM_CLEAR_LINE=""
    HAS_TTY=0
fi

# Colors (ANSI)
C_BLUE="\033[38;5;75m"
C_GREEN="\033[38;5;114m"
C_YELLOW="\033[38;5;221m"
C_RED="\033[38;5;203m"
C_CYAN="\033[38;5;117m"
C_GRAY="\033[38;5;242m"
C_WHITE="\033[38;5;255m"
C_RESET="\033[0m"

# Box-drawing characters — pure ASCII for maximum terminal compatibility
BOX_TL="+" BOX_TR="+" BOX_BL="+" BOX_BR="+"
BOX_H="-" BOX_V="|"
BOX_BULLET=">"  BOX_CHECK="*"  BOX_CROSS="x"
BOX_DOT="."     BOX_ARROW="->" BOX_BLOCK_FULL="#"  BOX_BLOCK_LIGHT="-"

# --- Drawing primitives ---

# Print a horizontal line: hline [width] [char]
tui_hline() {
    local w="${1:-$TERM_COLS}" ch="${2:-$BOX_H}"
    printf '%*s' "$w" '' | tr ' ' "$ch"
}

# Print a box with title and body lines
# Usage: tui_box "title" "line1" "line2" ...
tui_box() {
    local title="$1"; shift
    local inner_w=50
    # Find max line width
    for line in "$title" "$@"; do
        local stripped
        stripped="$(echo -e "$line" | sed 's/\x1b\[[0-9;]*m//g')"
        (( ${#stripped} + 2 > inner_w )) && inner_w=$(( ${#stripped} + 2 ))
    done

    printf "  ${C_GRAY}%s%s%s${C_RESET}\n" "$BOX_TL" "$(tui_hline "$inner_w" "$BOX_H")" "$BOX_TR"
    if [[ -n "$title" ]]; then
        printf "  ${C_GRAY}%s${C_RESET} ${TERM_BOLD}${C_WHITE}%-*s${C_RESET} ${C_GRAY}%s${C_RESET}\n" \
            "$BOX_V" "$(( inner_w - 2 ))" "$title" "$BOX_V"
    fi
    for line in "$@"; do
        local stripped
        stripped="$(echo -e "$line" | sed 's/\x1b\[[0-9;]*m//g')"
        local pad=$(( inner_w - ${#stripped} - 2 ))
        (( pad < 0 )) && pad=0
        printf "  ${C_GRAY}%s${C_RESET} %b%*s ${C_GRAY}%s${C_RESET}\n" \
            "$BOX_V" "$line" "$pad" "" "$BOX_V"
    done
    printf "  ${C_GRAY}%s%s%s${C_RESET}\n" "$BOX_BL" "$(tui_hline "$inner_w" "$BOX_H")" "$BOX_BR"
}

# --- Messaging ---

tui_info()  { printf "  ${C_BLUE}${BOX_BULLET}${C_RESET} %b\n" "$*"; }
tui_ok()    { printf "  ${C_GREEN}${BOX_CHECK}${C_RESET} %b\n" "$*"; }
tui_warn()  { printf "  ${C_YELLOW}!${C_RESET} %b\n" "$*"; }
tui_err()   { printf "  ${C_RED}${BOX_CROSS}${C_RESET} %b\n" "$*" >&2; }
tui_dim()   { printf "  ${C_GRAY}%b${C_RESET}\n" "$*"; }

# Fatal error
die() { tui_err "$*"; exit 1; }

# --- Input ---

# Prompt for input with a default value
# Usage: result=$(tui_input "Label" "default_value")
tui_input() {
    local label="$1" default="${2:-}" value
    if [[ -n "$default" ]]; then
        printf "  ${C_CYAN}${BOX_BULLET}${C_RESET} ${TERM_BOLD}%s${C_RESET} ${C_GRAY}[%s]${C_RESET}: " "$label" "$default" >&2
    else
        printf "  ${C_CYAN}${BOX_BULLET}${C_RESET} ${TERM_BOLD}%s${C_RESET}: " "$label" >&2
    fi
    read -r value </dev/tty
    echo "${value:-$default}"
}

# Prompt for secret input (no echo)
# Usage: result=$(tui_secret "Label")
tui_secret() {
    local label="$1" value
    printf "  ${C_CYAN}${BOX_BULLET}${C_RESET} ${TERM_BOLD}%s${C_RESET}: " "$label" >&2
    read -rs value </dev/tty
    echo >&2  # newline after hidden input
    echo "$value"
}

# Yes/no confirm: returns 0 for yes, 1 for no
# Usage: tui_confirm "Do the thing?" && do_it
tui_confirm() {
    local label="$1" default="${2:-y}"
    local hint="Y/n"
    [[ "$default" == "n" ]] && hint="y/N"
    printf "\n  ${C_CYAN}?${C_RESET} ${TERM_BOLD}%s${C_RESET} ${C_GRAY}[%s]${C_RESET} " "$label" "$hint" >&2
    local answer
    read -r answer </dev/tty
    answer="${answer:-$default}"
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

# --- Progress ---

# Global progress state
_PROGRESS_TOTAL=0
_PROGRESS_CURRENT=0
_PROGRESS_STEPS=()
_PROGRESS_LABEL=""

# Initialize progress: progress_init "step1" "step2" ...
progress_init() {
    _PROGRESS_STEPS=("$@")
    _PROGRESS_TOTAL=${#_PROGRESS_STEPS[@]}
    _PROGRESS_CURRENT=0
}

# Start next step: progress_step
progress_step() {
    (( ++_PROGRESS_CURRENT ))
    _PROGRESS_LABEL="${_PROGRESS_STEPS[$(( _PROGRESS_CURRENT - 1 ))]}"
    _progress_draw
}

# Draw the progress bar
_progress_draw() {
    local pct=$(( _PROGRESS_CURRENT * 100 / _PROGRESS_TOTAL ))
    local bar_w=30
    local filled=$(( pct * bar_w / 100 ))
    local empty=$(( bar_w - filled ))

    local bar=""
    for (( i=0; i<filled; i++ )); do bar+="$BOX_BLOCK_FULL"; done
    for (( i=0; i<empty; i++ )); do  bar+="$BOX_BLOCK_LIGHT"; done

    if [[ "$HAS_TTY" -eq 1 ]]; then
        printf "${TERM_CLEAR_LINE}" >&2
    fi
    printf "  ${C_GRAY}[%2d/%2d]${C_RESET} ${C_BLUE}%s${C_RESET} ${C_GRAY}%3d%%${C_RESET}  %s" \
        "$_PROGRESS_CURRENT" "$_PROGRESS_TOTAL" "$bar" "$pct" "$_PROGRESS_LABEL" >&2
    if [[ "$HAS_TTY" -eq 1 ]]; then
        printf "\r" >&2
    else
        echo >&2
    fi
}

# Mark current step complete (prints on new line, clears progress)
progress_done() {
    if [[ "$HAS_TTY" -eq 1 ]]; then
        printf "${TERM_CLEAR_LINE}" >&2
    fi
    tui_ok "${_PROGRESS_LABEL}"
}

# --- Summary table ---

# Print a key-value pair with dots
# Usage: tui_kv "Domain" "git.example.com"
tui_kv() {
    local key="$1" val="$2"
    local dots_w=$(( 28 - ${#key} ))
    (( dots_w < 2 )) && dots_w=2
    local dots
    dots="$(printf '%*s' "$dots_w" '' | tr ' ' "$BOX_DOT")"
    printf "  ${C_WHITE}%s${C_RESET} ${C_GRAY}%s${C_RESET} ${C_CYAN}%s${C_RESET}\n" "$key" "$dots" "$val"
}

# --- Separator ---
tui_sep() {
    printf "  ${C_GRAY}%s${C_RESET}\n" "$(tui_hline 56 "$BOX_H")"
}

# --- Blank line ---
tui_blank() { echo; }


# ==========================================================================
# Configuration defaults — can be overridden by env vars
# ==========================================================================
DOMAIN="${CGIT_DOMAIN:-git.example.com}"
REPOS_DIR="${CGIT_REPOS_DIR:-/srv/git}"
CGIT_CACHE_DIR="/var/cache/cgit"
CGIT_CACHE_SIZE="${CGIT_CACHE_SIZE:-2000}"
OWNER_NAME="${CGIT_OWNER:-admin}"
CLONE_PREFIX="${CGIT_CLONE_PREFIX:-}"   # derived from DOMAIN if empty
SITE_TITLE="${CGIT_SITE_TITLE:-git}"
ANUBIS_DIFFICULTY="${CGIT_ANUBIS_DIFFICULTY:-4}"
TUNNEL_TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-}"
AUTO_YES=0

# Parse CLI flags
for arg in "$@"; do
    case "$arg" in
        --yes|-y) AUTO_YES=1 ;;
        --help|-h)
            echo "Usage: sudo ./setup.sh [--yes]"
            echo ""
            echo "  Interactive TUI wizard for cgit deployment."
            echo "  Use --yes to skip confirmations (reads config from env vars)."
            echo ""
            echo "Environment variables:"
            echo "  CGIT_DOMAIN             Domain name (default: git.example.com)"
            echo "  CGIT_REPOS_DIR          Repos directory (default: /srv/git)"
            echo "  CGIT_OWNER              Displayed owner name (default: admin)"
            echo "  CGIT_SITE_TITLE         Site title (default: git)"
            echo "  CGIT_CLONE_PREFIX       Clone URL prefix (default: https://DOMAIN)"
            echo "  CGIT_ANUBIS_DIFFICULTY  PoW difficulty 1-8 (default: 4)"
            echo "  CGIT_CACHE_SIZE         cgit cache entries (default: 2000, auto-tuned)"
            echo "  CLOUDFLARE_TUNNEL_TOKEN Tunnel token for automated setup"
            exit 0
            ;;
    esac
done


# ==========================================================================
# System helpers
# ==========================================================================
detect_arch() {
    local arch
    arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    case "$arch" in
        amd64|x86_64) echo "amd64" ;;
        arm64|aarch64) echo "arm64" ;;
        *) die "Unsupported architecture: $arch" ;;
    esac
}

get_total_ram_mb() {
    awk '/MemTotal/ { printf "%d", $2 / 1024 }' /proc/meminfo
}


# ==========================================================================
# Wizard screens
# ==========================================================================

# --- Screen 1: Welcome ---
wizard_welcome() {
    clear 2>/dev/null || true
    tui_blank
    tui_box "cgit setup" \
        "" \
        "${C_CYAN}Cloudflare Tunnel ${C_GRAY}${BOX_ARROW}${C_CYAN} Anubis ${C_GRAY}${BOX_ARROW}${C_CYAN} lighttpd ${C_GRAY}${BOX_ARROW}${C_CYAN} cgit${C_RESET}" \
        "" \
        "A fast, secure, self-hosted git mirror." \
        "Zero public ports. Proof-of-work bot protection." \
        "" \
        "${C_GRAY}Runs on boxes as small as 256 MB RAM / 1 vCPU.${C_RESET}"
    tui_blank

    local ram_mb
    ram_mb="$(get_total_ram_mb)"
    local arch
    arch="$(detect_arch)"

    tui_dim "System"
    tui_kv "OS" "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -s)"
    tui_kv "Architecture" "$arch"
    tui_kv "RAM" "${ram_mb} MB"
    if [[ -f /swapfile ]]; then
        tui_kv "Swap" "$(swapon --show=SIZE --noheadings 2>/dev/null || echo 'active')"
    else
        tui_kv "Swap" "none (will be created if RAM < 512 MB)"
    fi
    tui_blank
}

# --- Screen 2: Configuration ---
wizard_config() {
    tui_sep
    tui_dim "Configuration"
    tui_dim "Press Enter to accept defaults, or type a new value."
    tui_blank

    DOMAIN="$(tui_input "Domain" "$DOMAIN")"
    OWNER_NAME="$(tui_input "Owner name" "$OWNER_NAME")"
    SITE_TITLE="$(tui_input "Site title" "$SITE_TITLE")"
    REPOS_DIR="$(tui_input "Repos directory" "$REPOS_DIR")"
    ANUBIS_DIFFICULTY="$(tui_input "Anubis PoW difficulty (1-8)" "$ANUBIS_DIFFICULTY")"

    # Derive clone prefix from domain if not set
    [[ -z "$CLONE_PREFIX" ]] && CLONE_PREFIX="https://${DOMAIN}"
    CLONE_PREFIX="$(tui_input "Clone URL prefix" "$CLONE_PREFIX")"

    tui_blank
    tui_sep
    tui_dim "Cloudflare Tunnel"
    tui_blank

    if [[ -f /etc/cloudflared/config.yml ]]; then
        tui_ok "Tunnel already configured at /etc/cloudflared/config.yml"
    elif [[ -n "$TUNNEL_TOKEN" ]]; then
        tui_ok "Tunnel token provided via environment"
    else
        tui_dim "You'll need a Cloudflare Tunnel token to connect your VPS."
        tui_dim "Get one from: ${C_CYAN}Cloudflare Dashboard ${BOX_ARROW} Zero Trust ${BOX_ARROW} Tunnels${C_RESET}"
        tui_dim "Create a tunnel, add hostname ${C_WHITE}${DOMAIN}${C_RESET} ${BOX_ARROW} ${C_WHITE}http://127.0.0.1:8923${C_RESET}"
        tui_dim "Then copy the token."
        tui_blank
        TUNNEL_TOKEN="$(tui_secret "Tunnel token (paste, or Enter to skip)")"
        if [[ -z "$TUNNEL_TOKEN" ]]; then
            tui_warn "No token — tunnel will need manual setup after install."
        else
            tui_ok "Token received."
        fi
    fi
    tui_blank
}

# --- Screen 3: Confirm ---
wizard_confirm() {
    tui_sep
    tui_dim "Review"
    tui_blank

    tui_kv "Domain" "$DOMAIN"
    tui_kv "Owner" "$OWNER_NAME"
    tui_kv "Title" "$SITE_TITLE"
    tui_kv "Repos" "$REPOS_DIR"
    tui_kv "Clone prefix" "$CLONE_PREFIX"
    tui_kv "PoW difficulty" "$ANUBIS_DIFFICULTY"
    if [[ -n "$TUNNEL_TOKEN" ]]; then
        tui_kv "Tunnel" "token provided"
    elif [[ -f /etc/cloudflared/config.yml ]]; then
        tui_kv "Tunnel" "already configured"
    else
        tui_kv "Tunnel" "${C_YELLOW}manual setup needed${C_RESET}"
    fi

    local ram_mb
    ram_mb="$(get_total_ram_mb)"
    local cache_size="$CGIT_CACHE_SIZE"
    if [[ "$ram_mb" -lt 384 ]]; then
        cache_size=500
    elif [[ "$ram_mb" -lt 512 ]]; then
        cache_size=1000
    fi
    tui_kv "Cache entries" "$cache_size (auto-tuned for ${ram_mb}MB RAM)"

    tui_blank
    tui_dim "Stack (all loopback — zero public ports):"
    tui_dim "  Internet ${BOX_ARROW} Cloudflare ${BOX_ARROW} cloudflared ${BOX_ARROW} Anubis :8923 ${BOX_ARROW} lighttpd :8080 ${BOX_ARROW} cgit"
    tui_blank

    if [[ "$AUTO_YES" -eq 1 ]]; then
        return 0
    fi

    tui_confirm "Proceed with installation?" || { tui_warn "Aborted."; exit 0; }
}


# ==========================================================================
# Install functions — the actual work (preserved from original)
# ==========================================================================

install_packages() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq \
        cgit \
        git \
        lighttpd \
        python3-pygments \
        python3-markdown \
        fail2ban \
        ufw \
        unattended-upgrades \
        curl \
        jq \
        >/dev/null 2>&1
}

install_anubis() {
    local arch
    arch="$(detect_arch)"

    local version
    version="$(curl -fsSL https://api.github.com/repos/TecharoHQ/anubis/releases/latest | jq -r '.tag_name' | sed 's/^v//')"
    if [[ -z "$version" || "$version" == "null" ]]; then
        die "Failed to fetch Anubis latest version. Check network connectivity."
    fi

    local deb_url="https://github.com/TecharoHQ/anubis/releases/download/v${version}/anubis_${version}_${arch}.deb"
    local tmp_deb="/tmp/anubis_${version}.deb"

    curl -fsSL -o "$tmp_deb" "$deb_url" || { echo "Failed to download Anubis .deb from ${deb_url}" >&2; return 1; }
    dpkg -i "$tmp_deb" || apt-get install -f -y -qq
    rm -f "$tmp_deb"
}

setup_git_user() {
    if ! id -u git &>/dev/null; then
        useradd -r -m -d /home/git -s /usr/bin/git-shell git
    fi
    mkdir -p "$REPOS_DIR"
    chown git:git "$REPOS_DIR"
    chmod 755 "$REPOS_DIR"
}

install_cgit_config() {
    local cgit_static="/usr/share/cgit"
    cp "${SCRIPT_DIR}/theme/cgit.css"    "${cgit_static}/cgit.css"
    cp "${SCRIPT_DIR}/theme/cgit.js"     "${cgit_static}/cgit.js"
    cp "${SCRIPT_DIR}/theme/favicon.svg" "${cgit_static}/favicon.svg" 2>/dev/null || true

    # cgit.cgi lives in /usr/lib/cgit/ but document-root is /usr/share/cgit/
    # lighttpd needs to find the CGI binary inside the document-root
    ln -sf /usr/lib/cgit/cgit.cgi "${cgit_static}/cgit.cgi"

    mkdir -p /etc/cgit
    cp "${SCRIPT_DIR}/theme/header.html" /etc/cgit/header.html
    cp "${SCRIPT_DIR}/theme/footer.html" /etc/cgit/footer.html
    cp "${SCRIPT_DIR}/theme/syntax-highlight.py" /etc/cgit/syntax-highlight.py
    chmod +x /etc/cgit/syntax-highlight.py

    local ram_mb
    ram_mb="$(get_total_ram_mb)"
    local cache_size="$CGIT_CACHE_SIZE"
    if [[ "$ram_mb" -lt 384 ]]; then
        cache_size=500
    elif [[ "$ram_mb" -lt 512 ]]; then
        cache_size=1000
    fi

    sed \
        -e "s|{{REPOS_DIR}}|${REPOS_DIR}|g" \
        -e "s|{{CACHE_DIR}}|${CGIT_CACHE_DIR}|g" \
        -e "s|{{CACHE_SIZE}}|${cache_size}|g" \
        -e "s|{{CLONE_PREFIX}}|${CLONE_PREFIX}|g" \
        -e "s|{{OWNER_NAME}}|${OWNER_NAME}|g" \
        -e "s|{{SITE_TITLE}}|${SITE_TITLE}|g" \
        "${SCRIPT_DIR}/cgitrc.template" > /etc/cgitrc

    mkdir -p "$CGIT_CACHE_DIR"
    chown www-data:www-data "$CGIT_CACHE_DIR"
    chmod 700 "$CGIT_CACHE_DIR"
}

install_lighttpd() {
    cp "${SCRIPT_DIR}/lighttpd/cgit.conf" /etc/lighttpd/conf-available/20-cgit.conf

    lighttpd-enable-mod cgi       2>/dev/null || true
    lighttpd-enable-mod rewrite   2>/dev/null || true
    lighttpd-enable-mod setenv    2>/dev/null || true
    lighttpd-enable-mod expire    2>/dev/null || true
    lighttpd-enable-mod accesslog 2>/dev/null || true

    ln -sf /etc/lighttpd/conf-available/20-cgit.conf /etc/lighttpd/conf-enabled/20-cgit.conf

    # Patch main lighttpd.conf — lighttpd does not allow reassignment of
    # server.port, server.bind, or server.document-root in included files
    local main_conf="/etc/lighttpd/lighttpd.conf"
    if [[ -f "$main_conf" ]]; then
        # Bind to loopback only on port 8080
        sed -i 's/^\s*server\.port\s*=.*/server.port = 8080/' "$main_conf"
        if grep -q '^\s*server\.bind' "$main_conf"; then
            sed -i 's/^\s*server\.bind\s*=.*/server.bind = "127.0.0.1"/' "$main_conf"
        else
            sed -i '/^\s*server\.port/a server.bind = "127.0.0.1"' "$main_conf"
        fi
        # Document root = cgit static assets
        sed -i 's|^\s*server\.document-root\s*=.*|server.document-root = "/usr/share/cgit"|' "$main_conf"
        # Remove index-file.names from main config (we don't need it, and it
        # can't be reassigned in included files either)
        sed -i '/^\s*index-file\.names/d' "$main_conf"
        # Disable the unconfigured splash page if present
        rm -f /etc/lighttpd/conf-enabled/99-unconfigured.conf
    else
        die "Main lighttpd config not found at ${main_conf}"
    fi

    lighttpd -t -f /etc/lighttpd/lighttpd.conf 2>&1 || { echo "lighttpd config test failed"; return 1; }
    systemctl enable --now lighttpd >/dev/null 2>&1
    systemctl reload lighttpd >/dev/null 2>&1
}

configure_anubis() {
    mkdir -p /etc/anubis

    local key_file="/etc/anubis/cgit.key"
    if [[ ! -f "$key_file" ]]; then
        openssl rand -hex 32 > "$key_file"
        chmod 600 "$key_file"
    fi

    local key_hex
    key_hex="$(cat "$key_file")"

    sed \
        -e "s|{{DIFFICULTY}}|${ANUBIS_DIFFICULTY}|g" \
        -e "s|{{DOMAIN}}|${DOMAIN}|g" \
        -e "s|{{ED25519_KEY}}|${key_hex}|g" \
        "${SCRIPT_DIR}/anubis/cgit.env" > /etc/anubis/cgit.env
    chmod 640 /etc/anubis/cgit.env

    # Compute tiered difficulties from base ANUBIS_DIFFICULTY
    # MED = base + 2 (capped at 8), HIGH = base + 4 (capped at 8)
    local diff_med=$(( ANUBIS_DIFFICULTY + 2 ))
    local diff_high=$(( ANUBIS_DIFFICULTY + 4 ))
    (( diff_med > 8 )) && diff_med=8
    (( diff_high > 8 )) && diff_high=8

    sed \
        -e "s|{{DIFFICULTY_HIGH}}|${diff_high}|g" \
        -e "s|{{DIFFICULTY_MED}}|${diff_med}|g" \
        -e "s|{{DIFFICULTY}}|${ANUBIS_DIFFICULTY}|g" \
        "${SCRIPT_DIR}/anubis/botPolicies.yaml" > /etc/anubis/cgit.botPolicies.yaml

    if [[ ! -f /etc/systemd/system/anubis@.service && ! -f /lib/systemd/system/anubis@.service ]]; then
        cp "${SCRIPT_DIR}/anubis/anubis@.service" /etc/systemd/system/anubis@.service
    fi

    systemctl daemon-reload
    systemctl enable --now anubis@cgit.service >/dev/null 2>&1
}

install_cloudflared() {
    if command -v cloudflared &>/dev/null; then
        cloudflared update 2>/dev/null || true
    else
        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
            | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
        local codename
        codename="$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}" || true)"
        if [[ -z "$codename" ]]; then
            codename="$(lsb_release -cs 2>/dev/null || echo bookworm)"
        fi
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared ${codename} main" \
            | tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq cloudflared >/dev/null 2>&1
    fi

    if [[ -f /etc/cloudflared/config.yml ]]; then
        systemctl enable --now cloudflared 2>/dev/null || true
        return
    fi

    if [[ -n "${TUNNEL_TOKEN}" ]]; then
        cloudflared service install "$TUNNEL_TOKEN" 2>/dev/null
        systemctl enable --now cloudflared >/dev/null 2>&1
    fi
}

setup_firewall() {
    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    ufw allow ssh >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
}

setup_fail2ban() {
    cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
EOF
    systemctl restart fail2ban >/dev/null 2>&1
}

harden_sysctl() {
    cat > /etc/sysctl.d/99-cgit-hardening.conf <<'EOF'
# Network hardening
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_max_syn_backlog = 2048

# Memory-constrained tuning
net.core.somaxconn = 512
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
vm.swappiness = 10
vm.vfs_cache_pressure = 75
EOF
    sysctl --system >/dev/null 2>&1
}

install_cron() {
    cat > /etc/cron.d/cgit-maintenance <<EOF
# Evict cgit disk cache entries older than 2h
0 */2 * * * www-data find ${CGIT_CACHE_DIR} -type f -mmin +120 -delete 2>/dev/null
EOF
}

install_mirror_script() {
    cat > /usr/local/bin/cgit-mirror <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
# Usage: cgit-mirror <git-url> [description]
#
# Requires root (or sudo) for initial clone (chown to git user).
# Subsequent fetches can run as the git user directly.

REPOS_DIR="${CGIT_REPOS_DIR:-/srv/git}"
URL="$1"
DESC="${2:-}"
REPO_NAME="$(basename "$URL" .git).git"
DEST="${REPOS_DIR}/${REPO_NAME}"

if [[ -d "$DEST" ]]; then
    echo "Updating ${REPO_NAME}..."
    git -C "$DEST" fetch --all --prune
else
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Initial clone requires root (need to chown to git user)." >&2
        echo "  Run: sudo cgit-mirror $*" >&2
        exit 1
    fi
    echo "Cloning ${REPO_NAME}..."
    git clone --mirror "$URL" "$DEST"
    chown -R git:git "$DEST"
fi

# Mark repo as exportable (cgit scan-path requires this unless enable-git-config=1)
touch "${DEST}/git-daemon-export-ok"
chown git:git "${DEST}/git-daemon-export-ok"

if [[ -n "$DESC" ]]; then
    echo "$DESC" > "${DEST}/description"
    chown git:git "${DEST}/description"
fi

echo "Done: ${DEST}"
SCRIPT
    chmod +x /usr/local/bin/cgit-mirror
}

install_sync_cron() {
    cat > /usr/local/bin/cgit-sync-all <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
REPOS_DIR="${CGIT_REPOS_DIR:-/srv/git}"
for repo in "${REPOS_DIR}"/*.git; do
    [[ -d "$repo" ]] || continue
    echo "[$(date -Is)] Syncing $(basename "$repo")..."
    git -C "$repo" fetch --all --prune 2>&1 || echo "  WARN: fetch failed for $(basename "$repo")"
done
SCRIPT
    chmod +x /usr/local/bin/cgit-sync-all

    cat > /etc/cron.d/cgit-sync <<EOF
# Sync all mirrors every 30 minutes
*/30 * * * * git /usr/local/bin/cgit-sync-all >> /var/log/cgit-sync.log 2>&1
EOF
}

install_logrotate() {
    cat > /etc/logrotate.d/cgit-sync <<'EOF'
/var/log/cgit-sync.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 0644 git git
}
EOF
}

setup_swap() {
    local ram_mb
    ram_mb="$(get_total_ram_mb)"

    if [[ "$ram_mb" -lt 512 ]]; then
        if [[ -f /swapfile ]]; then
            return
        fi
        local swap_size="512M"
        fallocate -l "$swap_size" /swapfile
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null
        swapon /swapfile
        if ! grep -q '/swapfile' /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
    fi
}


# ==========================================================================
# Main — orchestrate wizard + installation
# ==========================================================================
main() {
    [[ $EUID -eq 0 ]] || die "Run as root: sudo ./setup.sh"

    # --- Wizard ---
    if [[ "$AUTO_YES" -eq 0 && "$HAS_TTY" -eq 1 ]]; then
        wizard_welcome
        wizard_config
        wizard_confirm
    else
        # Non-interactive: derive clone prefix
        [[ -z "$CLONE_PREFIX" ]] && CLONE_PREFIX="https://${DOMAIN}"
    fi

    tui_blank
    tui_sep
    tui_dim "Installing"
    tui_blank

    # --- Run install steps with progress ---
    progress_init \
        "Configuring swap (if needed)" \
        "Installing system packages" \
        "Setting up git user" \
        "Installing Anubis" \
        "Configuring cgit" \
        "Configuring lighttpd" \
        "Configuring Anubis" \
        "Installing cloudflared" \
        "Configuring firewall" \
        "Configuring fail2ban" \
        "Hardening sysctl" \
        "Installing cron jobs" \
        "Installing mirror script" \
        "Installing sync cron" \
        "Installing logrotate"

    local logfile="/var/log/cgit-setup.log"
    : > "$logfile"

    _run_step() {
        local label="$1"; shift
        progress_step
        local rc=0
        "$@" >>"$logfile" 2>&1 </dev/null || rc=$?
        if [[ $rc -eq 0 ]]; then
            progress_done
        else
            progress_done
            tui_err "Failed: ${label} (exit code ${rc})"
            tui_err "See log: ${logfile}"
            die "Installation aborted. Fix the error above and re-run."
        fi
    }

    _run_step "Configuring swap"          setup_swap
    _run_step "Installing system packages" install_packages
    _run_step "Setting up git user"       setup_git_user
    _run_step "Installing Anubis"         install_anubis
    _run_step "Configuring cgit"          install_cgit_config
    _run_step "Configuring lighttpd"      install_lighttpd
    _run_step "Configuring Anubis"        configure_anubis
    _run_step "Installing cloudflared"    install_cloudflared
    _run_step "Configuring firewall"      setup_firewall
    _run_step "Configuring fail2ban"      setup_fail2ban
    _run_step "Hardening sysctl"          harden_sysctl
    _run_step "Installing cron jobs"      install_cron
    _run_step "Installing mirror script"  install_mirror_script
    _run_step "Installing sync cron"      install_sync_cron
    _run_step "Installing logrotate"      install_logrotate

    # --- Completion screen ---
    tui_blank
    tui_sep
    tui_blank

    local tunnel_status="${C_YELLOW}manual setup needed${C_RESET}"
    if [[ -n "$TUNNEL_TOKEN" ]]; then
        tunnel_status="${C_GREEN}active${C_RESET}"
    elif [[ -f /etc/cloudflared/config.yml ]]; then
        tunnel_status="${C_GREEN}configured${C_RESET}"
    fi

    tui_box "Setup complete" \
        "" \
        "All loopback ${BOX_ARROW} zero public ports" \
        "" \
        "${C_GRAY}Internet   ${BOX_ARROW} ${C_WHITE}Cloudflare Edge${C_RESET}" \
        "${C_GRAY}Cloudflare ${BOX_ARROW} ${C_WHITE}cloudflared  ${C_GRAY}(outbound tunnel)${C_RESET}" \
        "${C_GRAY}cloudflared${BOX_ARROW} ${C_CYAN}Anubis       ${C_GRAY}127.0.0.1:8923${C_RESET}" \
        "${C_GRAY}Anubis     ${BOX_ARROW} ${C_CYAN}lighttpd     ${C_GRAY}127.0.0.1:8080${C_RESET}" \
        "${C_GRAY}lighttpd   ${BOX_ARROW} ${C_CYAN}cgit         ${C_GRAY}${REPOS_DIR}${C_RESET}"

    tui_blank
    tui_kv "Site" "https://${DOMAIN}"
    tui_kv "Tunnel" "$tunnel_status"
    tui_kv "Theme toggle" "press 't' or click button"
    tui_blank
    tui_dim "Commands:"
    tui_dim "  ${C_WHITE}sudo cgit-mirror${C_RESET} <url> [desc]  Mirror a repo"
    tui_dim "  ${C_WHITE}cgit-sync-all${C_RESET}                  Force sync all repos"
    tui_blank

    if [[ -z "$TUNNEL_TOKEN" ]] && [[ ! -f /etc/cloudflared/config.yml ]]; then
        tui_sep
        tui_blank
        tui_warn "Cloudflare Tunnel not configured yet."
        tui_blank
        tui_dim "  1. Go to ${C_CYAN}Cloudflare Dashboard ${BOX_ARROW} Zero Trust ${BOX_ARROW} Tunnels${C_RESET}"
        tui_dim "  2. Create tunnel, add hostname: ${C_WHITE}${DOMAIN}${C_RESET} ${BOX_ARROW} ${C_WHITE}http://127.0.0.1:8923${C_RESET}"
        tui_dim "  3. Copy token, then run:"
        tui_blank
        tui_dim "     ${C_WHITE}cloudflared service install ${C_CYAN}<TOKEN>${C_RESET}"
        tui_dim "     ${C_WHITE}systemctl enable --now cloudflared${C_RESET}"
        tui_blank
    fi
}

main "$@"
