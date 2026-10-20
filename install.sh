#!/usr/bin/env bash
# Eris Box installer
#   bash <(curl -fsSL https://raw.githubusercontent.com/eris4444/eris-box/main/install.sh)
# Extra arguments are passed to "erisbox install" (for example: --swap 2G, --no-swap, -y).
set -euo pipefail

RAW="https://raw.githubusercontent.com/eris4444/eris-box/main"
BIN=/usr/local/bin/erisbox

if [ "$(id -u)" != 0 ]; then
  echo "Please run as root:  sudo -i   and then run the install command again." >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq curl ca-certificates
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
if [ -n "${ERISBOX_SRC:-}" ]; then
  cp "$ERISBOX_SRC" "$tmp"                       # local copy (used by the tests)
else
  curl -fsSL "$RAW/erisbox.sh" -o "$tmp"
fi
grep -q '^# ERIS-BOX-SCRIPT' "$tmp" || { echo "Download failed: that is not the Eris Box script." >&2; exit 1; }
bash -n "$tmp"
install -m 755 "$tmp" "$BIN"
echo "Installed the erisbox command: $BIN"

if [ -t 0 ] || ( : </dev/tty ) 2>/dev/null; then
  "$BIN" install "$@" </dev/tty
  echo
  echo "Opening the menu (later just type: erisbox)"
  sleep 2
  exec "$BIN" menu </dev/tty
else
  "$BIN" install -y "$@"
fi
