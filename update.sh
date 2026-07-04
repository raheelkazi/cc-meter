#!/usr/bin/env bash
# Update the installed cc-meter menu bar app:
# pull latest, rebuild release, reinstall the binary, and restart the LaunchAgent.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_PATH="$HOME/.local/bin/cc-meter"
LABEL="com.raheelkazi.cc-meter"

cd "$REPO_DIR"

echo "==> Pulling latest changes"
git pull --ff-only

echo "==> Building release binary"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/cc-meter"
echo "==> Installing to $INSTALL_PATH"
mkdir -p "$(dirname "$INSTALL_PATH")"
cp "$BIN" "$INSTALL_PATH"

echo "==> Restarting LaunchAgent ($LABEL)"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

echo "==> Done. cc-meter updated and restarted."
