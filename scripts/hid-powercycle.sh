#!/bin/bash
# Power-cycles all connected USB mice so udev re-enumerates them cleanly.
# Run once on boot after udev has settled, to ensure the hid-poll fix
# takes effect even if the device re-enumerated during early boot.

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
    exit 0
fi

for dev in "${MICE[@]}"; do
    echo 0 > "$dev/authorized"
done
sleep 1
for dev in "${MICE[@]}"; do
    echo 1 > "$dev/authorized"
done
