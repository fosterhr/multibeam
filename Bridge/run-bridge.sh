#!/usr/bin/env bash
# MultiBeam bridge for Linux. Needs Python 3 (already installed on most distros).
# Run:  bash run-bridge.sh    (or: chmod +x run-bridge.sh && ./run-bridge.sh)
cd "$(dirname "$0")" || exit 1

if command -v python3 >/dev/null 2>&1; then
  exec python3 bridge.py
fi

echo "Python 3 was not found. Install it, then run this script again:"
echo "  Debian/Ubuntu:  sudo apt install python3"
echo "  Fedora:         sudo dnf install python3"
echo "  Arch:           sudo pacman -S python"
exit 1
