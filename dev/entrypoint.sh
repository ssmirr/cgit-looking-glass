#!/bin/sh
set -e

REPOS_DIR="/srv/git"

# -----------------------------------------------------------------------
# Seed a sample repo if /srv/git is empty
# -----------------------------------------------------------------------
if [ -z "$(ls -A "$REPOS_DIR" 2>/dev/null)" ]; then
    echo "==> Seeding sample repos..."

    # Sample repo 1: a small real project
    git clone --mirror https://github.com/ssmirr/cgit-looking-glass.git "$REPOS_DIR/cgit-looking-glass.git" 2>&1 || {
        # Fallback: create a synthetic repo with varied content
        echo "==> Mirror clone failed, creating synthetic repo..."
        git init --bare "$REPOS_DIR/sample-project.git"
        WORK=$(mktemp -d)
        git clone "$REPOS_DIR/sample-project.git" "$WORK/repo"
        cd "$WORK/repo"
        git config user.email "dev@localhost"
        git config user.name "Developer"

        # Commit 1: README + Python
        cat > README.md << 'INNER'
# Sample Project

A demo repository for cgit theme development.

## Features
- Multiple file types for syntax highlighting
- Several commits for log/diff views
- Branches and tags for refs view
INNER
        cat > main.py << 'INNER'
#!/usr/bin/env python3
"""Sample Python module for syntax highlighting testing."""

import os
import sys
from typing import Optional

class Config:
    """Application configuration."""

    def __init__(self, name: str, debug: bool = False):
        self.name = name
        self.debug = debug
        self._cache: dict[str, str] = {}

    def get(self, key: str, default: Optional[str] = None) -> Optional[str]:
        """Retrieve a config value."""
        if key in self._cache:
            return self._cache[key]
        value = os.environ.get(f"APP_{key.upper()}", default)
        if value is not None:
            self._cache[key] = value
        return value

def main():
    config = Config("sample", debug="--debug" in sys.argv)
    print(f"Running {config.name} (debug={config.debug})")
    port = config.get("port", "8080")
    print(f"Listening on :{port}")

if __name__ == "__main__":
    main()
INNER
        git add -A && git commit -m "feat: initial project structure with config module"

        # Commit 2: Go file
        cat > server.go << 'INNER'
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
)

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"status":"ok","version":"%s"}`, version)
}

var version = "0.1.0"

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	http.HandleFunc("/health", healthHandler)
	log.Printf("Listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}
INNER
        git add -A && git commit -m "feat: add HTTP server with health endpoint"

        # Commit 3: Makefile + shell script
        cat > Makefile << 'INNER'
.PHONY: build run test clean

VERSION := $(shell git describe --tags --always --dirty)
LDFLAGS := -ldflags "-X main.version=$(VERSION)"

build:
	go build $(LDFLAGS) -o bin/server .

run: build
	./bin/server

test:
	go test -v -race ./...

clean:
	rm -rf bin/
INNER
        cat > deploy.sh << 'INNER'
#!/bin/bash
set -euo pipefail

REMOTE="deploy@example.com"
BINARY="bin/server"

echo "Building..."
make build

echo "Deploying to ${REMOTE}..."
scp "$BINARY" "${REMOTE}:/opt/app/server.new"
ssh "$REMOTE" 'mv /opt/app/server.new /opt/app/server && systemctl restart app'

echo "Done."
INNER
        chmod +x deploy.sh
        git add -A && git commit -m "build: add Makefile and deploy script"

        # Commit 4: Create a branch
        git checkout -b feat/logging
        cat > logger.go << 'INNER'
package main

import (
	"log/slog"
	"os"
)

func setupLogger(level string) *slog.Logger {
	var lvl slog.Level
	switch level {
	case "debug":
		lvl = slog.LevelDebug
	case "warn":
		lvl = slog.LevelWarn
	case "error":
		lvl = slog.LevelError
	default:
		lvl = slog.LevelInfo
	}

	return slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: lvl,
	}))
}
INNER
        git add -A && git commit -m "feat: add structured JSON logging"
        git checkout master

        # Push everything
        git push origin --all
        cd /
        rm -rf "$WORK"
    }

    # Fix ownership and permissions
    chown -R lighttpd:lighttpd "$REPOS_DIR"
    chmod -R a+rX "$REPOS_DIR"

    # Update server info for all repos
    for repo in "$REPOS_DIR"/*.git; do
        [ -d "$repo" ] || continue
        git -C "$repo" update-server-info 2>/dev/null || true
        touch "$repo/git-daemon-export-ok"
    done
fi

# -----------------------------------------------------------------------
# Generate cgitrc from template
# -----------------------------------------------------------------------
echo "==> Generating /etc/cgitrc..."
sed \
    -e "s|{{REPOS_DIR}}|${REPOS_DIR}|g" \
    -e "s|{{CACHE_DIR}}|/var/cache/cgit|g" \
    -e "s|{{CACHE_SIZE}}|64|g" \
    -e "s|{{CLONE_PREFIX}}|http://localhost:8080|g" \
    -e "s|{{OWNER_NAME}}|Dev|g" \
    -e "s|{{SITE_TITLE}}|cgit dev|g" \
    /etc/cgit/cgitrc.template > /etc/cgitrc

# -----------------------------------------------------------------------
# Generate lighttpd config
# -----------------------------------------------------------------------
echo "==> Configuring lighttpd..."
cat > /etc/lighttpd/lighttpd.conf << 'LCONF'
server.document-root = "/usr/share/cgit"
server.bind          = "0.0.0.0"
server.port          = 8080
server.modules       = (
    "mod_rewrite",
    "mod_cgi",
    "mod_setenv",
    "mod_expire",
    "mod_accesslog"
)
server.errorlog      = "/dev/stderr"
accesslog.filename   = "/dev/stderr"
mimetype.assign      = (
    ".html" => "text/html",
    ".css"  => "text/css",
    ".js"   => "application/javascript",
    ".svg"  => "image/svg+xml",
    ".png"  => "image/png",
    ".ico"  => "image/x-icon",
    ".txt"  => "text/plain"
)
include "/etc/lighttpd/cgit.conf"
LCONF

# Apply REPOS_DIR to lighttpd cgit.conf
sed "s|{{REPOS_DIR}}|${REPOS_DIR}|g" /etc/cgit/cgit.conf > /etc/lighttpd/cgit.conf

# Install syntax-highlight filter.
# The volume mount is :ro so we can't chmod it in place — copy to a writable
# location and patch cgitrc to point there.
cp /etc/cgit/syntax-highlight.py /usr/local/bin/cgit-syntax-highlight
chmod +x /usr/local/bin/cgit-syntax-highlight
sed -i 's|source-filter=.*|source-filter=/usr/local/bin/cgit-syntax-highlight|' /etc/cgitrc

echo "==> Starting lighttpd on :8080..."
echo "    Open http://localhost:8080"
echo ""
exec lighttpd -D -f /etc/lighttpd/lighttpd.conf
