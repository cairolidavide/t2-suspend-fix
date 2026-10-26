# t2-suspend-fix

**Reliable suspend and fast resume for Apple T2 Macs running Linux.**

[Italiano](README.it.md)

On T2 Macs (2018–2020) suspend often breaks the machine: after waking up the
keyboard, trackpad, Touch Bar, Wi-Fi or Bluetooth stop working, the system
can freeze, and many people end up disabling suspend altogether.
`t2-suspend-fix` is a small `systemd-sleep` hook that addresses the actual
causes, plus a diagnostic tool to see what happens on your machine.

## Symptoms it fixes

- Keyboard, trackpad, Touch Bar and audio dead after waking up, or the
  system freezing after a few suspend attempts
- Wi-Fi and Bluetooth not working after resume
- Resume taking 10+ seconds
- Touch Bar blank after resume, or flashing the default layout before
  `tiny-dfr` starts
- Screen staying black when the lid is opened until a key is pressed (GNOME)
- Keyboard backlight off and [wluma](https://github.com/max-baz/wluma)
  stopped working after resume

## Why it happens

These are the causes found by analysing the kernel logs of a MacBookPro15,4.
The T2 chip turned out *not* to be the culprit: the T2 driver suspends and
resumes it correctly.

| Problem | Cause |
|---|---|
| T2 devices dead, system freezes | The Broadcom Wi-Fi driver (`brcmfmac`) fails to suspend (`pci_pm_suspend returns -5`), so the suspend is aborted and retried every few seconds. After a few dozen aborted attempts the T2 stops answering (`t2bce_dma: command queue timeout`). |
| Wi-Fi / Bluetooth gone | Wi-Fi and Bluetooth are two functions of the same Broadcom chip: handling only one of them leaves the other in a broken state. |
| Resume takes ~12 s | The Intel Thunderbolt 3 bridge and controller take ~10.5 s to resume, even with nothing plugged in. |
| Touch Bar blank or flashing | The T2 re-enumerates the Touch Bar on resume: `tiny-dfr` is stopped by systemd (`BindsTo=`) and is not restarted, while the backlight driver turns the bar on at full brightness with the default layout. |
| Black screen on lid open | Since systemd 256 user sessions are frozen during suspend, and GNOME misses the lid-open event. |

## What it does

Before suspending (`pre`):

1. Unloads the Broadcom Bluetooth and Wi-Fi drivers (auto-detected).
2. If nothing is plugged into the USB-C ports, removes the Thunderbolt PCI
   branch from the bus (auto-detected, multiple controllers supported).
3. Unloads the Touch Bar backlight driver (only if `tiny-dfr` is running).

After waking up (`post`, kept as short as possible):

1. Rescans the Thunderbolt branch (~50 ms).
2. Reloads the Touch Bar backlight driver with `brightness=0` and restarts
   `tiny-dfr` as soon as its devices are ready.

Then, in the background:

1. Reloads Wi-Fi and Bluetooth.
2. Restores the keyboard backlight and restarts user services such as
   `wluma`.

It also installs two systemd drop-ins: S3 (`deep`) sleep only, and user
sessions not frozen during suspend.

The T2 driver (`apple-bce` / `t2bce`) is **not** unloaded: recent versions
save and restore the T2 state natively, and unloading it is what used to
break things.

Measured on a MacBookPro15,4:

| | Before | After |
|---|---|---|
| Device resume in the kernel | ~11 s | ~1 s |
| Lid open → screen on | ~12 s | ~2–3 s |
| Working after resume | inconsistent | keyboard, trackpad, Touch Bar, audio, camera, Wi-Fi, Bluetooth, USB-C |

## Compatibility

**Tested on:** MacBookPro15,4 (13" 2019, two Thunderbolt ports), Ubuntu
26.04, kernel 7.2 (t2linux, `t2bce` driver), systemd 259, GNOME.

**Should work on** every T2 Mac, because everything is auto-detected instead
of hard-coded: MacBookPro15,x and 16,x, MacBookAir8,x and 9,1, Macmini8,1,
iMac20,x, iMacPro1,1, MacPro7,1. These have not been tested yet: please
[report](#reporting-problems) how it works on yours.

Run `sudo t2-suspend-diag` after installing to see what is detected on your
Mac. Steps that do not apply (no Touch Bar, no Thunderbolt bridge,
CPU-integrated Thunderbolt, Bluetooth over UART, ...) are skipped.

**Requirements**

- A Linux kernel with T2 support, see [t2linux](https://wiki.t2linux.org)
- systemd (256 or newer recommended)
- Optional: [tiny-dfr](https://github.com/AsahiLinux/tiny-dfr) for the Touch
  Bar

## Installation

```bash
git clone https://github.com/cairolidavide/t2-suspend-fix.git
cd t2-suspend-fix
sudo ./install.sh
```

Options:

| Option | Effect |
|---|---|
| `--lid` | Suspend when the lid is closed (adds a `logind.conf.d` drop-in; with an external display connected the lid is ignored) |
| `--bluetooth-autoenable` | Power on Bluetooth at boot (`AutoEnable=true` in `/etc/bluetooth/main.conf`) |
| `--force` | Install even if no T2 chip is detected |

The installer backs up every file it replaces in `/var/lib/t2-suspend-fix/`,
unmasks `sleep.target` and `suspend.target` if you had masked them, and warns
about other sleep hooks that touch the same drivers. If you followed older
guides that unload `apple-bce` or `brcmfmac` before suspending, remove those
hooks: they conflict with this one.

Then test it:

```bash
systemctl suspend          # wake it up with a key, or open the lid
sudo t2-suspend-diag       # check what happened
```

### Installed files

| File | Purpose |
|---|---|
| `/usr/lib/systemd/system-sleep/t2-suspend-fix` | The sleep hook |
| `/etc/t2-suspend-fix.conf` | Settings |
| `/usr/local/bin/t2-suspend-diag` | Diagnostic tool |
| `/etc/systemd/sleep.conf.d/t2-suspend-fix.conf` | `MemorySleepMode=deep` |
| `/etc/systemd/system/systemd-suspend.service.d/t2-suspend-fix.conf` | Do not freeze user sessions |
| `/etc/systemd/logind.conf.d/t2-suspend-fix-lid.conf` | Lid → suspend (only with `--lid`) |

Nothing has to be enabled: `systemd-sleep` runs the hook at every suspend,
and everything survives reboots and updates.

## Configuration

Edit `/etc/t2-suspend-fix.conf`; changes apply from the next suspend.

| Setting | Default | Meaning |
|---|---|---|
| `RELOAD_WIFI_BT` | `yes` | Unload/reload the Broadcom Wi-Fi and Bluetooth drivers |
| `FAST_THUNDERBOLT_RESUME` | `auto` | Remove/rescan the Thunderbolt branch when USB-C is unused (`no` to disable) |
| `TOUCHBAR_FIX` | `auto` | Keep the Touch Bar dark until `tiny-dfr` is ready (`no` to disable) |
| `RESTORE_KBD_BACKLIGHT` | `yes` | Restore the keyboard backlight level |
| `RESTART_USER_SERVICES` | `wluma.service` | User services to restart after resume, if running |

## Diagnostics

```bash
sudo t2-suspend-diag              # system report and last suspend cycle
sudo t2-suspend-diag --trace      # time every device during the next cycle
sudo t2-suspend-diag --slowest    # after suspending: the slowest devices
journalctl -b -t t2-suspend-fix   # the hook's log
```

`--trace` enables the kernel's `pm_print_times` until the next reboot. It is
how the Thunderbolt delay was found:

```
pcieport 0000:03:00.0: PM: pci_pm_resume_noirq returned 0 after 7214919 usecs
thunderbolt 0000:05:00.0: PM: pci_pm_resume_noirq returned 0 after 3369536 usecs
```

## Troubleshooting

**Resume is still slow (~12 s).** Something was plugged into a USB-C port
(drive, hub, dongle, external display), so the Thunderbolt branch was kept to
avoid disconnecting it. The log says
`USB-C in use ..., keeping Thunderbolt (slow resume)`.

**Wi-Fi or Bluetooth missing after resume.** Check
`journalctl -b -t t2-suspend-fix` for errors. To bring them back without
rebooting: `sudo modprobe brcmfmac; sudo modprobe hci_bcm4377`.

**USB-C ports not working after resume.** Rescan the PCI bus:
`echo 1 | sudo tee /sys/bus/pci/rescan`, and please open an issue with the
output of `sudo t2-suspend-diag`.

**Screen stays black when opening the lid.** Check that
`/etc/systemd/system/systemd-suspend.service.d/t2-suspend-fix.conf` exists and
run `sudo systemctl daemon-reload`.

**Bluetooth is off after every boot.** Install with `--bluetooth-autoenable`.
If it is still off, systemd-rfkill may have saved it as blocked: run
`rfkill unblock bluetooth` once.

**Suspend does not happen at all.** Check that `sleep.target` and
`suspend.target` are not masked: `systemctl is-enabled suspend.target`.

## Known limitations

- On resume the Touch Bar lights up about half a second after the screen:
  `tiny-dfr` must start from scratch because the T2 re-creates the device,
  and it needs ~0.4–0.6 s to load fonts and icons.
- About 1 s of the remaining resume time is spent by the kernel
  re-synchronising EFI variables (`efivarfs: resyncing variable state`),
  which is slow on T2 firmware. It cannot be avoided by unmounting efivarfs,
  because snap sandboxes keep their own mounts.
- With a USB-C device connected, resume stays slow (see above).
- Hibernation has not been tested.

## Uninstall

```bash
sudo ./uninstall.sh
```

This removes every installed file and restores the Bluetooth `AutoEnable`
setting. Your `/etc/t2-suspend-fix.conf` and the backups in
`/var/lib/t2-suspend-fix/` are kept; the script tells you how to delete them.

## Reporting problems

Open an issue and include:

- the output of `sudo t2-suspend-diag`
- what does not work after resume
- if resume is slow: the output of `sudo t2-suspend-diag --slowest` after a
  traced cycle

Reports of it working on Mac models other than MacBookPro15,4 are welcome too.

## Credits

- The [t2linux](https://t2linux.org) community for the kernel drivers that
  make Linux run on T2 Macs
- [tiny-dfr](https://github.com/AsahiLinux/tiny-dfr) for the Touch Bar daemon

## License

[MIT](LICENSE)
