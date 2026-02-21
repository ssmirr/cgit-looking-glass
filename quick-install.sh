#!/usr/bin/env bash
# cgit-looking-glass quick installer
# Clones the repo and runs the setup wizard
set -euo pipefail

INSTALL_DIR="/opt/cgit-setup"
REPO="https://github.com/ssmirr/cgit-looking-glass.git"

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (or with sudo)."
    exit 1
fi

# Install git if missing
if ! command -v git &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq git
fi

if [[ -d "$INSTALL_DIR/.git" ]]; then
    git config --global --add safe.directory "$INSTALL_DIR" 2>/dev/null || true
    # If update fails (e.g. force-pushed history), nuke and re-clone
    if ! git -C "$INSTALL_DIR" fetch origin 2>/dev/null || \
       ! git -C "$INSTALL_DIR" reset --hard origin/master 2>/dev/null; then
        rm -rf "$INSTALL_DIR"
        git clone "$REPO" "$INSTALL_DIR"
    fi
else
    rm -rf "$INSTALL_DIR"
    git clone "$REPO" "$INSTALL_DIR"
fi

exec "$INSTALL_DIR/setup.sh" "$@" </dev/tty
