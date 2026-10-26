#!/bin/bash
# install.sh - install t2-suspend-fix
# https://github.com/cairolidavide/t2-suspend-fix
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sudo ./install.sh [options]

  --lid                    suspend when the lid is closed (logind drop-in)
  --bluetooth-autoenable   power on Bluetooth at boot (AutoEnable=true in
                           /etc/bluetooth/main.conf)
  --force                  install even if no Apple T2 chip is detected
  -h, --help               show this help
EOF
}

LID=no BT_AUTOENABLE=no FORCE=no
for arg in "$@"; do
  case "$arg" in
    --lid) LID=yes ;;
    --bluetooth-autoenable) BT_AUTOENABLE=yes ;;
    --force) FORCE=yes ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
  esac
done

SRC=$(dirname "$(readlink -f "$0")")
HOOK=/usr/lib/systemd/system-sleep/t2-suspend-fix
STATE_DIR=/var/lib/t2-suspend-fix
BACKUP="$STATE_DIR/backup-$(date +%Y%m%d-%H%M%S)"

info() { printf '  %s\n' "$*"; }
warn() { printf '  WARNING: %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
# backup FILE [NEW]: copy FILE to $BACKUP, unless it is identical to NEW
backup() {
  [ -e "$1" ] || return 0
  [ -n "${2:-}" ] && cmp -s "$1" "$2" && return 0
  mkdir -p "$BACKUP"
  cp -a "$1" "$BACKUP/"
  info "backup of $1 in $BACKUP"
}

[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 $*"

echo "Checking the system"
has_t2() {
  local d
  for d in /sys/bus/pci/devices/*; do
    [ "$(cat "$d/vendor")" = 0x106b ] && [ "$(cat "$d/device")" = 0x1801 ] && return 0
  done
  return 1
}

if has_t2; then
  info "Apple T2 found: $(cat /sys/class/dmi/id/product_name 2>/dev/null)"
elif [ "$FORCE" = yes ]; then
  warn "no Apple T2 detected, installing anyway (--force)"
else
  die "no Apple T2 chip (PCI 106b:1801) found. This is only for T2 Macs (use --force to override)."
fi

if [ -e /sys/module/t2bce_core ]; then
  info "T2 driver: t2bce"
elif [ -e /sys/module/apple_bce ]; then
  info "T2 driver: apple-bce"
else
  warn "T2 driver (apple-bce / t2bce) not loaded: keyboard, trackpad and Touch Bar need a T2 Linux kernel, see https://wiki.t2linux.org"
fi

SYSTEMD_VER=$(systemctl --version | awk 'NR==1{print $2}' | tr -cd '0-9')
if [ "${SYSTEMD_VER:-0}" -lt 256 ]; then
  warn "systemd $SYSTEMD_VER < 256: MemorySleepMode is not supported. If /sys/power/mem_sleep does not default to [deep], add the kernel parameter mem_sleep_default=deep"
fi

echo "Installing"
backup "$HOOK" "$SRC/src/t2-suspend-fix"
install -Dm755 "$SRC/src/t2-suspend-fix" "$HOOK"
info "$HOOK"

install -Dm755 "$SRC/tools/t2-suspend-diag" /usr/local/bin/t2-suspend-diag
info "/usr/local/bin/t2-suspend-diag"

if [ -e /etc/t2-suspend-fix.conf ]; then
  install -Dm644 "$SRC/conf/t2-suspend-fix.conf" /etc/t2-suspend-fix.conf.new
  info "/etc/t2-suspend-fix.conf kept, new defaults in /etc/t2-suspend-fix.conf.new"
else
  install -Dm644 "$SRC/conf/t2-suspend-fix.conf" /etc/t2-suspend-fix.conf
  info "/etc/t2-suspend-fix.conf"
fi

install -Dm644 "$SRC/conf/sleep.conf.d/t2-suspend-fix.conf" /etc/systemd/sleep.conf.d/t2-suspend-fix.conf
info "/etc/systemd/sleep.conf.d/t2-suspend-fix.conf"
install -Dm644 "$SRC/conf/systemd-suspend.service.d/t2-suspend-fix.conf" \
  /etc/systemd/system/systemd-suspend.service.d/t2-suspend-fix.conf
info "/etc/systemd/system/systemd-suspend.service.d/t2-suspend-fix.conf"

if [ "$LID" = yes ]; then
  install -Dm644 "$SRC/conf/logind.conf.d/t2-suspend-fix-lid.conf" \
    /etc/systemd/logind.conf.d/t2-suspend-fix-lid.conf
  systemctl kill -s HUP systemd-logind
  info "/etc/systemd/logind.conf.d/t2-suspend-fix-lid.conf (lid closed -> suspend)"
fi

if [ "$BT_AUTOENABLE" = yes ]; then
  if [ -e /etc/bluetooth/main.conf ]; then
    mkdir -p "$STATE_DIR"
    grep -E '^AutoEnable=' /etc/bluetooth/main.conf > "$STATE_DIR/bluetooth-autoenable" || true
    backup /etc/bluetooth/main.conf
    if grep -qE '^AutoEnable=' /etc/bluetooth/main.conf; then
      sed -i -E 's/^AutoEnable=.*/AutoEnable=true/' /etc/bluetooth/main.conf
    elif grep -qE '^\[Policy\]' /etc/bluetooth/main.conf; then
      sed -i -E 's/^\[Policy\]/[Policy]\nAutoEnable=true/' /etc/bluetooth/main.conf
    else
      printf '\n[Policy]\nAutoEnable=true\n' >> /etc/bluetooth/main.conf
    fi
    info "/etc/bluetooth/main.conf: AutoEnable=true"
  else
    warn "/etc/bluetooth/main.conf not found, Bluetooth option skipped"
  fi
fi

for t in sleep.target suspend.target; do
  if [ "$(systemctl is-enabled "$t" 2>/dev/null)" = masked ]; then
    systemctl unmask "$t" >/dev/null
    info "$t was masked: unmasked"
  fi
done

systemctl daemon-reload

echo "Checking for conflicts"
others=$(grep -lE 'apple.bce|t2bce|brcmfmac|hci_bcm|thunderbolt|tiny-dfr' \
  /usr/lib/systemd/system-sleep/* 2>/dev/null | grep -v "/t2-suspend-fix$" || true)
if [ -n "$others" ]; then
  warn "other sleep hooks touch the same drivers and may conflict; consider removing them:"
  printf '    %s\n' $others
else
  info "none"
fi
lid=$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
  org.freedesktop.login1.Manager HandleLidSwitch 2>/dev/null | awk '{print $2}' | tr -d '"')
[ -n "$lid" ] && [ "$lid" != suspend ] && info "closing the lid currently does: $lid (use --lid to suspend)"

cat <<'EOF'

Done. Test it with:   systemctl suspend
Then check with:      sudo t2-suspend-diag
Settings:             /etc/t2-suspend-fix.conf
EOF
