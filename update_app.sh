#!/bin/bash
# Simple update script for raspberry-pi-manager
# Place this file at the repository root and (optionally) copy to /usr/local/bin/update_app.sh
# Usage: /bin/bash update_app.sh

set -euo pipefail

# Defaults
SERVICE_NAME=${SERVICE_NAME:-raspberry-pi-manager}
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGFILE="${REPO_DIR}/update_app.log"

echo "["$(date -Iseconds)"] Starting update" >> "$LOGFILE"
cd "$REPO_DIR"

# Fetch latest
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git fetch --all --prune
    git reset --hard origin/$(git rev-parse --abbrev-ref HEAD)
    echo "["$(date -Iseconds)"] Git updated" >> "$LOGFILE"
else
    echo "Not a git repo, skipping git pull" >> "$LOGFILE"
fi

# Install requirements if present
if [ -f requirements.txt ]; then
    if command -v pip >/dev/null 2>&1; then
        pip install -r requirements.txt >> "$LOGFILE" 2>&1 || true
        echo "["$(date -Iseconds)"] Pip install done" >> "$LOGFILE"
    fi
fi

# Restart service if exists
if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-units --full -all | grep -q "${SERVICE_NAME}"; then
        sudo systemctl restart "${SERVICE_NAME}" >> "$LOGFILE" 2>&1 || true
        echo "["$(date -Iseconds)"] Restarted service ${SERVICE_NAME}" >> "$LOGFILE"
    else
        echo "Service ${SERVICE_NAME} not found; skipping restart" >> "$LOGFILE"
    fi
fi

echo "["$(date -Iseconds)"] Update finished" >> "$LOGFILE"
