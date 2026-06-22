#!/bin/bash

# Pull latest changes, rebuild, and relaunch the app.
#
# This is invoked (detached, in a new Terminal window) by the running app's
# "Update App" button. A running process can't replace its own binary, so this
# script first waits for the current instance to quit, then pulls + rebuilds.
#
# Usage: ./update.sh [repo-dir]

REPO_DIR="${1:-$(cd "$(dirname "$0")" && pwd)}"
cd "$REPO_DIR" || { echo "Could not cd to $REPO_DIR"; exit 1; }

echo "=== Updating repo_manager ==="
echo "Repo: $REPO_DIR"

# Wait for the running app to quit so we can safely replace its binary.
echo "Waiting for the running app to quit..."
for _ in $(seq 1 100); do
    pgrep -x repo_manager >/dev/null 2>&1 || break
    sleep 0.3
done

echo "Pulling latest changes..."
git pull --ff-only || { echo "git pull failed"; exit 1; }

echo "Building and relaunching..."
exec bash ./run.sh
