#!/bin/bash
# install.sh for the ASMedia ASM1042A USB mouse fix

set -e

RULES_DIR="$(dirname "$(realpath "$0")")/rules"
UDEV_DIR="/etc/udev/rules.d"

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo ./install.sh" >&2
    exit 1
fi

echo "=== Installing ASMedia USB mouse fix ==="
echo ""

# ── 1. Copy udev rules ────────────────────────────────────────────────────────

echo "Installing udev rules..."

for rule in "$RULES_DIR"/*.rules; do
    dest="$UDEV_DIR/$(basename "$rule")"
    cp "$rule" "$dest"
    echo "  Copied: $(basename "$rule")"
done

echo ""

# ── 2. Reload udev ────────────────────────────────────────────────────────────

echo "Reloading udev rules..."
udevadm control --reload-rules
echo ""

# ── 3. Power-cycle all connected USB mice ─────────────────────────────────────
#
# The fix prevents the TT stall on fresh enumeration but cannot recover a mouse
# that is already stuck. Deauthorizing and re-authorizing each mouse forces a
# clean re-enumeration, during which udev immediately opens the hidraw fd.

echo "Power-cycling connected USB mice..."

MICE=()
for iface in /sys/bus/usb/devices/*/; do
    class=$(cat "${iface}bInterfaceClass" 2>/dev/null) || continue
    protocol=$(cat "${iface}bInterfaceProtocol" 2>/dev/null) || continue
    if [[ "$class" == "03" && "$protocol" == "02" ]]; then
        devpath="${iface%%:*}"
        devpath="${devpath%/}"
        if [[ -f "$devpath/authorized" ]] && [[ ! " ${MICE[*]} " == *" $devpath "* ]]; then
            MICE+=("$devpath")
        fi
    fi
done

if [[ ${#MICE[@]} -eq 0 ]]; then
    echo "  No USB mice found. Plug in your mouse and it will work automatically."
else
    for dev in "${MICE[@]}"; do
        echo "  Cycling: $dev"
        echo 0 > "$dev/authorized"
    done
    sleep 1
    for dev in "${MICE[@]}"; do
        echo 1 > "$dev/authorized"
    done
    sleep 2
fi

echo ""

# ── 4. Verify ─────────────────────────────────────────────────────────────────

echo "=== Verification ==="
echo ""

systemctl list-units "hid-poll-*" --no-pager 2>/dev/null

echo ""
echo "=== Done ==="
echo "No reboot required on most systems. Wiggle any connected mouse to confirm it responds."
