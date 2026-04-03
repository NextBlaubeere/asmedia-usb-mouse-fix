# ASMedia ASM1042A USB Mouse Fix for Linux

Fixes USB mice that do not respond when connected through a monitor containing an **ASMedia ASM1042A** USB 3.0 host controller via **Thunderbolt 2**. The fix is a single udev rule, requires no reboot on most systems, and works generically for any USB mouse without needing to know the mouse's vendor or product ID.

This issue has been observed on a **MacBook Pro 13" Early 2015 (MacBookPro12,1)** with an LG UltraWide monitor connected via Thunderbolt 2. Interestingly, connecting the same monitor to a desktop PC via its USB port works fine. The problem only appears when the monitor is connected via Thunderbolt 2, which points to the Thunderbolt bridge itself as a contributing factor rather than the ASMedia chip alone.

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

| Component           | Details                                                                                                                                                                                             |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| USB host controller | ASMedia ASM1042A, PCI ID `1b21:1142`, located inside an LG UltraWide monitor connected via Thunderbolt 2. The problem has not been reproduced with the same chip connected via USB on a desktop PC. |
| Affected devices    | Any standard USB HID mouse (virtually all USB mice operate at Full-Speed, 12 Mbit/s, regardless of generation)                                                                                      |
| Affected OS         | Confirmed on Fedora, CachyOS, Ubuntu and Pop!_OS (as of April 2026). Since it reproduces across distributions, the issue is likely in the Linux kernel itself rather than anything distro-specific. |

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

> **Note:** The following is a theory based on observed behavior, not a confirmed explanation.

USB mice operate at Full-Speed (12 Mbit/s). This is part of the USB 2.0 specification and is the standard speed for input devices. It applies to modern mice just as much as older ones.

When a Full-Speed device is connected to a faster hub, the hub uses a component called a **Transaction Translator (TT)** to bridge the speed difference. All mouse input passes through the TT on its way to the host.

The problem appears to be caused by a combination of two factors, neither of which alone seems to be enough to trigger it.

The first factor is Linux's driver behavior. After a USB device finishes enumerating, the kernel's usbhid driver goes quiet if nothing in userspace has opened the device yet. There is a brief window before the desktop environment or input system opens `/dev/hidrawX`, during which no interrupt URBs are being submitted and the mouse's interrupt pipe is idle. On macOS and Windows, the driver might keep the interrupt pipe active from the moment the device enumerates, which would explain why the problem does not occur on those systems. But this alone cannot be the full explanation, because the same Linux idle window exists when the monitor's hub is connected via USB, and there the mouse works fine.

The second factor is the Thunderbolt 2 bridge. When the monitor is connected via Thunderbolt 2, USB traffic is encapsulated in the Thunderbolt protocol, tunneled through the Thunderbolt controller, and handed off to the ASMedia chip on the other side. This tunneling may introduce additional latency or change the timing of how transactions reach the TT. The idle window that Linux creates might be longer or timed differently when going through the Thunderbolt bridge.

The theory is that only when both factors are present, the Linux idle window combined with the Thunderbolt 2 timing, does the ASMedia TT lock up. Once the interrupt pipe goes quiet under these conditions, the TT appears to stop delivering input for that endpoint silently. The controller still reports the endpoint as active, the kernel driver still submits URBs, everything looks normal, but no input ever arrives. The TT does not recover on its own, even after userspace opens the device.

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

### Option 2: Udev Rule (generic)

This repository implements the same fix generically, without touching the kernel command line and without knowing the mouse's vendor or product ID in advance.

When a mouse connects and its `/dev/hidrawX` node appears, a udev rule fires and immediately starts a `cat /dev/hidrawX` process in the background. Holding a file descriptor open on the hidraw device causes the usbhid driver to keep the interrupt pipe continuously active, exactly as `HID_QUIRK_ALWAYS_POLL` does. The TT never sees an idle pipe. When the mouse is disconnected, `cat` receives EOF and exits automatically.

The process is managed by systemd as a transient unit (`--collect` ensures it is cleaned up automatically on exit). No permanent service is installed.

---

## The Rule

One file is installed: `/etc/udev/rules.d/99-hid-mouse-always-poll.rules`

```
ACTION=="add", SUBSYSTEM=="hidraw", ATTRS{bInterfaceProtocol}=="02", \
    RUN+="/bin/systemd-run --no-block --unit=hid-poll-%k --collect /bin/cat /dev/%k"
```

`bInterfaceProtocol == 0x02` is the standard USB HID descriptor value for a boot-class mouse (defined in the USB HID specification, section 4.1). This matches any USB mouse regardless of brand or model.

The rule intentionally applies to all boot-class mice on the system, not only mice behind the ASMedia controller. Scoping it to the ASMedia controller is not straightforward: udev's `ATTRS` parent walk does not reliably cross from the hidraw/HID subsystem up to the PCI controller. In practice the overhead is negligible: one lightweight `cat` process per connected mouse.

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
3. Power-cycles all currently connected USB mice so the fix takes effect immediately without a physical replug

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
