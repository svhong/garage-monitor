#!/usr/bin/env bash
# Install or update the Garage Monitor desktop widget for KDE Plasma 6.
#
#   ./plasmoid/install.sh             install, or update if already installed
#   ./plasmoid/install.sh --remove    uninstall
#
# Run as your normal user (not sudo): the widget installs into
# ~/.local/share/plasma/plasmoids/.
set -euo pipefail

ID=com.svhong.garagemonitor
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -eq 0 ]]; then
    echo "Run this as your normal user, not with sudo." >&2
    exit 1
fi
if ! command -v kpackagetool6 >/dev/null; then
    echo "kpackagetool6 not found. This widget needs KDE Plasma 6." >&2
    exit 1
fi

if [[ "${1:-}" == "--remove" ]]; then
    kpackagetool6 -t Plasma/Applet -r "$ID"
    echo "Removed. Restart Plasma to clear it from memory: systemctl --user restart plasma-plasmashell"
    exit 0
fi

if [[ -d "${XDG_DATA_HOME:-$HOME/.local/share}/plasma/plasmoids/$ID" ]]; then
    kpackagetool6 -t Plasma/Applet -u "$DIR"
    echo
    echo "Updated. Plasma keeps the old version loaded until it restarts:"
    echo "  systemctl --user restart plasma-plasmashell"
else
    kpackagetool6 -t Plasma/Applet -i "$DIR"
    echo
    echo "Installed. To add it:"
    echo "  1. Right-click the desktop → Enter Edit Mode → Add Widgets…"
    echo "  2. Search for \"Garage Monitor\" and drag it onto the desktop."
    echo "  3. Right-click the widget → Configure… and set your hub address"
    echo "     (e.g. http://hermes-box:8787) and the viewer password."
fi
