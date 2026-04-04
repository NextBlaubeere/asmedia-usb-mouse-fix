# ASMedia ASM1042A USB Mouse Fix for Linux

Fixes USB mice that do not respond when connected through an LG UltraWide monitor via **Thunderbolt 2**, where the monitor's internal USB hub is hosted by an **ASMedia ASM1042A** xHCI controller. The fix consists of a udev rule and a small boot service, requires no reboot on most systems, and works generically for any USB mouse without needing to know the mouse's vendor or product ID.

This issue has been observed on a **MacBook Pro 13" Early 2015 (MacBookPro12,1)** with an LG UltraWide monitor connected via Thunderbolt 2. When the same monitor is connected via its USB port instead, the hub is hosted by the Intel xHCI controller and the mouse works fine. The ASMedia ASM1042A acts as the xHCI host controller when connected via Thunderbolt 2, and it does not recover from TT stalls on the interrupt endpoint the way the Intel controller does.

What makes this even stranger is that plugging in an unrelated Logitech wireless receiver into the monitor suddenly makes any wired mouse work. The receiver has no connection to the wired mouse whatsoever. It prevents the problem, though why exactly is unclear. The additional USB traffic it puts on the controller might be the reason, but I am not sure.

---

## Symptoms

- The mouse cursor does not move and no input is registered after boot.
- The mouse is fully enumerated and appears in `lsusb` with no errors.
- `dmesg` shows no USB errors or warnings.
- The device is listed in `xinput list` or `libinput list-devices`.
- In some cases, plugging in a specific second USB device alongside the mouse makes it work. This does not work with every device and is not a reliable workaround.
- The problem is present on every boot. It is not caused by a loose connection or a hardware defect.
- The problem does not occur on macOS or Windows. It is Linux-specific.

---

## Affected Hardware (Confirmed Setup)

| Component            | Details                                                                                                                                                                                             |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| xHCI host controller | ASMedia ASM1042A, `1b21:1142`. This is the host controller exposed by the monitor via Thunderbolt 2.                                                                                                |
| Monitor hub          | LG Electronics, `043e:9a10`. This is the actual hub the mouse connects through. The same hub hosted by an Intel xHCI (via USB connection) works fine.                                               |
| Affected devices     | Any standard USB HID mouse (virtually all USB mice operate at Full-Speed, 12 Mbit/s, regardless of generation)                                                                                      |
| Affected OS          | Confirmed on Fedora, CachyOS, Ubuntu and Pop!_OS (as of April 2026). Since it reproduces across distributions, the issue is likely in the Linux kernel itself rather than anything distro-specific. |

To check if your system has this controller:

```bash
lspci | grep -i asmedia
```

You should see something like:

```
0a:00.0 USB controller: ASMedia Technology Inc. ASM1042A USB 3.0 Host Controller
```

---

## Root Cause

> **Note:** The following is partly theory and partly based on observed log data. Not everything is fully confirmed.

USB mice operate at Full-Speed (12 Mbit/s). This is part of the USB 2.0 specification and is the standard speed for input devices. It applies to modern mice just as much as older ones.

When a Full-Speed device is connected to a faster hub, the hub uses a component called a **Transaction Translator (TT)** to bridge the speed difference. All mouse input passes through the TT on its way to the host.

The monitor contains an internal USB hub (`043e:9a10`). When connected via Thunderbolt 2, this hub is hosted by the **ASMedia ASM1042A** xHCI controller. When connected via USB, the same hub is hosted by the **Intel xHCI** controller built into the MacBook. The mouse works fine on Intel but not on ASMedia.

Dynamic debug logs from the xhci_hcd driver show that in the broken state, the ASMedia controller reports repeated `Stalled endpoint` and `Hard-reset ep` messages on ep 0 (the control endpoint) while the mouse is being configured. Shortly after, the log shows this on ep 2 (the interrupt IN endpoint):

```
xhci_hcd 0000:0a:00.0: Split transaction error for slot 3 ep 2
xhci_hcd 0000:0a:00.0: Hard-reset ep 2, slot 3
```

A split transaction error refers to a failure in the split transaction protocol, which is the mechanism by which the hub's Transaction Translator bridges full-speed traffic to the high-speed controller. Whether this means the TT itself is failing or whether the ASMedia controller is mishandling the response is not clear to me. The USB log captured when the monitor is connected via USB (Intel xHCI) shows no such error for the mouse.

After enumeration, the usbhid driver stops submitting interrupt URBs if nothing in userspace has opened the device yet. There is a brief idle window before the desktop environment opens `/dev/hidrawX`. This idle condition may be what triggers the initial stall. On macOS and Windows, the driver might keep the interrupt pipe active from the moment of enumeration, which would explain why those systems are not affected. But this is not confirmed.

---

## Solutions

### Option 1: Kernel Boot Parameter (per mouse model)

The Linux kernel has a per-device quirk called `HID_QUIRK_ALWAYS_POLL` (value `0x400`) that forces the usbhid driver to keep the interrupt endpoint permanently active, preventing the idle window entirely.

It can be applied via the kernel command line using the format `VendorID:ProductID:QuirkFlags`, for example:

```
usbhid.quirks=0x046d:0xc049:0x00000400
```

How to add a kernel parameter depends on your bootloader and distribution.

**Limitation:** This requires the exact vendor and product ID of every mouse you want to fix. There is no wildcard support in the kernel for this parameter. If you use multiple mice or switch mice, you need a separate entry for each one.

### Option 2: Udev Rule and Boot Service (generic)

This repository implements the same fix generically, without touching the kernel command line and without knowing the mouse's vendor or product ID in advance.

When a mouse connects and its `/dev/hidrawX` node appears, a udev rule fires and immediately starts a `cat /dev/hidrawX` process in the background. Holding a file descriptor open on the hidraw device causes the usbhid driver to keep the interrupt pipe continuously active, exactly as `HID_QUIRK_ALWAYS_POLL` does. The TT never sees an idle pipe. When the mouse is disconnected, `cat` receives EOF and exits automatically.

The process is managed by systemd as a transient unit (`--collect` ensures it is cleaned up automatically on exit).

However, on reboot the udev rule alone is not enough. The mouse stops working until it is replugged or power-cycled manually. I am not sure why exactly, but the most likely explanation is that during early boot the USB device re-enumerates, which briefly kills the first `cat` process. There may be a gap of a few seconds before the device comes back and the rule fires again, and if the TT stalls during that gap the second `cat` process starts too late.

To handle this, a small oneshot systemd service runs after udev has settled on every boot. It power-cycles all connected USB mice, forcing a clean re-enumeration at a point where udev is fully ready. This reliably fixes the cold boot issue.

---

## What Gets Installed

**`/etc/udev/rules.d/99-hid-mouse-always-poll.rules`**

```
ACTION=="add", SUBSYSTEM=="hidraw", ATTRS{bInterfaceProtocol}=="02", \
    RUN+="/bin/systemd-run --no-block --unit=hid-poll-%k --collect /bin/cat /dev/%k"
```

`bInterfaceProtocol == 0x02` is the standard USB HID descriptor value for a boot-class mouse (defined in the USB HID specification, section 4.1). This matches any USB mouse regardless of brand or model.

The rule intentionally applies to all boot-class mice on the system, not only mice behind the ASMedia controller. Scoping it to the ASMedia controller is not straightforward: udev's `ATTRS` parent walk does not reliably cross from the hidraw/HID subsystem up to the PCI controller. In practice the overhead is negligible: one lightweight `cat` process per connected mouse.

**`/etc/systemd/system/asmedia-usb-mouse-fix.service`**

A oneshot systemd service that runs after udev has settled on every boot. It power-cycles all connected USB mice to ensure the udev rule fires at a point where the system is fully ready, working around the re-enumeration gap described above.

**`/usr/local/lib/asmedia-usb-mouse-fix/hid-powercycle.sh`**

The script called by the boot service to perform the power-cycle.

---

## Installation

```bash
git clone https://github.com/NextBlaubeere/asmedia-usb-mouse-fix.git
cd asmedia-usb-mouse-fix
sudo ./install.sh
```

The installer:

1. Copies the udev rule to `/etc/udev/rules.d/`
2. Reloads udev rules
3. Installs and enables the boot service
4. Power-cycles all currently connected USB mice so the fix takes effect immediately without a physical replug

No reboot required on most systems.

To uninstall:

```bash
sudo ./uninstall.sh
```

---

## Verification

After installing, check that a `hid-poll` unit is running for your mouse:

```bash
systemctl list-units "hid-poll-*"
```

You should see one active unit per connected mouse hidraw node, for example:

```
hid-poll-hidraw5.service   loaded active running [systemd-run] /bin/cat /dev/hidraw5
```

Wiggle the mouse to confirm it responds. If you see no units, replug the mouse.

---

## License

MIT. See [LICENSE](LICENSE).
