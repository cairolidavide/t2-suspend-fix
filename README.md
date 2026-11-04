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
- Keyboard backlight off after resume
- The Mac never wakes up from suspend after a system update, with
  `Failed to start Load Kernel Modules` at boot
- The Mac found awake and hot in the morning after closing the lid: a failed
  suspend retried in a loop all night

## Why it happens

These are the causes found by analysing the kernel logs of a MacBookPro15,4.
Most of them are *not* in the T2 chip: the T2 driver suspends and resumes it
correctly almost every time. When it does not, the driver cannot recover
("Awake and hot" below), so the hook limits the damage.

| Problem | Cause |
|---|---|
| T2 devices dead, system freezes | The Broadcom Wi-Fi driver (`brcmfmac`) fails to suspend (`pci_pm_suspend returns -5`), so the suspend is aborted and retried every few seconds. After a few dozen aborted attempts the T2 stops answering (`t2bce_dma: command queue timeout`). |
| Wi-Fi / Bluetooth gone | Wi-Fi and Bluetooth are two functions of the same Broadcom chip: handling only one of them leaves the other in a broken state. |
| Resume takes ~12 s | The Intel Thunderbolt 3 bridge and controller take ~10.5 s to resume, even with nothing plugged in. |
| Touch Bar blank or flashing | The T2 re-enumerates the Touch Bar on resume: `tiny-dfr` is stopped by systemd (`BindsTo=`) and is not restarted, while the backlight driver turns the bar on at full brightness with the default layout. |
| Black screen on lid open | Since systemd 256 user sessions are frozen during suspend, and GNOME misses the lid-open event. |
| Awake and hot after a night with the lid closed | Rarely the T2 still stops answering during a suspend (`t2bce_dma: command queue timeout`, then `t2bce_vhci: HC died`). The suspend fails, and since the lid is still closed logind retries it immediately, forever: over 2000 failed attempts in one night were observed. systemd also falls back to s2idle after every failed S3 attempt, doubling them. |
| Never wakes up after an update | With dracut, any update that regenerates the initramfs (kernel, systemd, ...) copies `/etc/modules-load.d/` into it. If a file there lists the `t2bce` drivers, they load before the root filesystem, `t2bce_audio` fails, and from then on the Mac does not wake up from suspend. |

## What it does

Before suspending (`pre`):

1. Unloads the Broadcom Bluetooth and Wi-Fi drivers (auto-detected).
2. If nothing is plugged into the USB-C ports, removes the Thunderbolt PCI
   branch from the bus (auto-detected, multiple controllers supported).
3. Unloads the Touch Bar backlight driver (only if `tiny-dfr` is running).

After waking up (`post`, kept as short as possible):

1. Rescans the Thunderbolt branch (~50 ms).
2. Checks that the T2 is answering (its virtual USB bus still has the
   keyboard, trackpad, Touch Bar, ...).
3. Failsafe: if the lid is closed and the T2 is not answering, or 3
   suspends in a row have failed, powers the Mac off instead of letting
   logind retry the suspend in a loop.
4. Reloads the Touch Bar backlight driver with `brightness=0` and restarts
   `tiny-dfr` as soon as its devices are ready.

Then, in the background:

1. Reloads Wi-Fi and Bluetooth.
2. Restores the keyboard backlight level and, if configured, restarts user
   services.

It also installs two systemd drop-ins: S3 (`deep`) sleep only, with no
fallback to s2idle, and user
sessions not frozen during suspend. On systems that use dracut it adds a
dracut drop-in that keeps the `t2bce` drivers out of the initramfs, so they
always load after boot, and regenerates the initramfs of the running kernel.
This step is skipped on encrypted disks (see
[Troubleshooting](#troubleshooting)).

The T2 driver (`apple-bce` / `t2bce`) is **not** unloaded before sleeping:
recent versions save and restore the T2 state natively, and unloading it is
what used to break things. A dead T2 is not revived by default: re-binding
the `t2bce` driver crashes the kernel (see `T2_RECOVERY`), and there is no
PCI reset (the T2 functions have no reset method, and a bus reset would also
hit the internal SSD on the same slot).

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
| `--keep-initramfs` | Do not add the dracut drop-in (the initramfs is left as it is) |
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
| `/etc/systemd/sleep.conf.d/t2-suspend-fix.conf` | `SuspendState=mem`, `MemorySleepMode=deep` |
| `/etc/systemd/system/systemd-suspend.service.d/t2-suspend-fix.conf` | Do not freeze user sessions |
| `/etc/systemd/logind.conf.d/t2-suspend-fix-lid.conf` | Lid → suspend (only with `--lid`) |
| `/etc/dracut.conf.d/90-t2-suspend-fix.conf` | T2 drivers out of the initramfs (dracut only, not on encrypted disks) |

Nothing has to be enabled: `systemd-sleep` runs the hook at every suspend,
and everything survives reboots and updates. No package owns these files,
so updates never overwrite or remove them.

## Configuration

Edit `/etc/t2-suspend-fix.conf`; changes apply from the next suspend.

| Setting | Default | Meaning |
|---|---|---|
| `RELOAD_WIFI_BT` | `yes` | Unload/reload the Broadcom Wi-Fi and Bluetooth drivers |
| `FAST_THUNDERBOLT_RESUME` | `auto` | Remove/rescan the Thunderbolt branch when USB-C is unused (`no` to disable) |
| `TOUCHBAR_FIX` | `auto` | Keep the Touch Bar dark until `tiny-dfr` is ready (`no` to disable) |
| `RESTORE_KBD_BACKLIGHT` | `yes` | Restore the keyboard backlight level |
| `RESTART_USER_SERVICES` | empty | User services to restart after resume, if running (space separated) |
| `T2_RECOVERY` | `no` | **Experimental.** Re-bind the T2 driver if the T2 stopped answering during a suspend. With `t2bce` 0.07 it oopses the kernel: unbinding `t2bce_core` leaves `t2bce_vhci` running on unmapped registers |
| `T2_RECOVERY_ATTEMPTS` | `2` | Recovery attempts after each suspend |
| `FAILSAFE_POWEROFF` | `yes` | With the lid closed, power off if the T2 is not answering or suspend keeps failing |
| `FAILSAFE_MAX_FAILURES` | `3` | Failed suspends in a row before powering off |

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

**Keyboard and trackpad dead after resume.** The T2 stopped answering: only
a reboot brings it back. `sudo t2-suspend-diag` shows how many devices the
T2 USB bus has (0 = T2 not answering). The hook has an experimental
`recover` command that re-binds the T2 driver, but with `t2bce` it crashes
the kernel: do not use it.

**The Mac powered off by itself with the lid closed.** That is the failsafe:
the suspend failed and the lid was closed. See why with
`journalctl -b -1 -t t2-suspend-fix` and
`journalctl -b -1 -k | grep -E 't2bce|PM:'`.

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

**The Mac does not wake up at all, since an update.** Run
`sudo t2-suspend-diag` and look at the *Initramfs* section. If it lists T2
drivers in the initramfs, or `Load Kernel Modules` failed at boot, the
initramfs was regenerated with the T2 drivers inside. Re-run
`sudo ./install.sh` and reboot. On an encrypted disk the installer skips
this step on purpose: the internal keyboard is needed in the initramfs to
type the passphrase. This case is not handled yet; please open an issue with
the output of `sudo t2-suspend-diag`.

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
- The failsafe only limits the damage when the T2 stops answering during a
  suspend; the cause is in the T2 driver, and so is the missing recovery.
- The dracut drop-in also stops dracut from copying `/etc/modules-load.d/`
  into the initramfs. Those modules are still loaded right after boot, as
  usual; only modules needed *before* the root filesystem is mounted would
  have to be added to the initramfs another way.
- Systems using `initramfs-tools` instead of dracut are not changed: the
  installer only warns if `/etc/initramfs-tools/modules` loads the T2
  driver.
- [wluma](https://github.com/max-baz/wluma) 5 needs no help: it picks up the
  re-created backlight devices by itself within ~2 s. Do not add it to
  `RESTART_USER_SERVICES`: right after resume the ambient light sensor may
  not answer yet, and a freshly started wluma then crashes and retries for
  ~30 s.

## Uninstall

```bash
sudo ./uninstall.sh
```

This removes every installed file, regenerates the initramfs of the running
kernel if the dracut drop-in was installed, and restores the Bluetooth
`AutoEnable` setting. Your `/etc/t2-suspend-fix.conf` and the backups in
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
