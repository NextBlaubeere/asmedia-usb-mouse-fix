#!/bin/bash
# uninstall.sh for the ASMedia ASM1042A USB mouse fix

set -e

UDEV_DIR="/etc/udev/rules.d"

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo ./uninstall.sh" >&2
    exit 1
fi

echo "=== Uninstalling ASMedia USB mouse fix ==="
echo ""

# Stop all running hid-poll units
UNITS=$(systemctl list-units "hid-poll-*" --no-pager --no-legend 2>/dev/null | awk '{print $1}')
if [[ -n "$UNITS" ]]; then
    echo "Stopping hid-poll units..."
    systemctl stop "$UNITS" 2>/dev/null || true
fi

# Remove udev rules
RULES=(
    "$UDEV_DIR/99-hid-mouse-always-poll.rules"
)

for f in "${RULES[@]}"; do
    if [[ -e "$f" ]]; then
        rm -f "$f"
        echo "Removed: $f"
    fi
done

udevadm control --reload-rules

# Power-cycle connected USB mice so they re-enumerate without the fix active
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
    echo "  No USB mice found."
else
    for dev in "${MICE[@]}"; do
        echo "  Cycling: $dev"
        echo 0 > "$dev/authorized"
    done
    sleep 1
    for dev in "${MICE[@]}"; do
        echo 1 > "$dev/authorized"
    done
fi

echo ""
echo "=== Done ==="
echo "Note: without the fix active, the ASMedia TT will stall again on the next boot."
