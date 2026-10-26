#!/bin/bash
# uninstall.sh - remove t2-suspend-fix
# https://github.com/cairolidavide/t2-suspend-fix
set -euo pipefail

STATE_DIR=/var/lib/t2-suspend-fix

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root: sudo $0" >&2; exit 1; }

echo "Removing t2-suspend-fix"
for f in \
  /usr/lib/systemd/system-sleep/t2-suspend-fix \
  /usr/local/bin/t2-suspend-diag \
  /etc/systemd/sleep.conf.d/t2-suspend-fix.conf \
  /etc/systemd/system/systemd-suspend.service.d/t2-suspend-fix.conf \
  /etc/systemd/logind.conf.d/t2-suspend-fix-lid.conf \
  /etc/t2-suspend-fix.conf.new; do
  [ -e "$f" ] && rm -f "$f" && echo "  removed $f"
done
rmdir --ignore-fail-on-non-empty /etc/systemd/sleep.conf.d \
  /etc/systemd/system/systemd-suspend.service.d /etc/systemd/logind.conf.d 2>/dev/null || true

# Restore the original Bluetooth AutoEnable line saved by install.sh
if [ -e "$STATE_DIR/bluetooth-autoenable" ] && [ -e /etc/bluetooth/main.conf ]; then
  orig=$(cat "$STATE_DIR/bluetooth-autoenable")
  if [ -n "$orig" ]; then
    sed -i -E "s/^AutoEnable=.*/$orig/" /etc/bluetooth/main.conf
  else
    sed -i -E '/^AutoEnable=true$/d' /etc/bluetooth/main.conf
  fi
  rm -f "$STATE_DIR/bluetooth-autoenable"
  echo "  restored Bluetooth AutoEnable in /etc/bluetooth/main.conf"
fi

systemctl daemon-reload
systemctl kill -s HUP systemd-logind 2>/dev/null || true

echo
echo "Kept: /etc/t2-suspend-fix.conf (your settings) and backups in $STATE_DIR"
echo "Delete them with: sudo rm -rf /etc/t2-suspend-fix.conf $STATE_DIR"
