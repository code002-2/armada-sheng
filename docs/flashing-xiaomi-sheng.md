# Flashing Armada to the Xiaomi Pad 6S Pro (sheng) — internal storage

This is the **new internal-storage build path** of Armada: instead of the
SD-card image (ROCKNIX ABL + `/KERNEL`), the sheng variant boots from the
**Android partitions** through the **original Xiaomi ABL**, exactly like
[debian-sheng](https://github.com/ianchb/debian-sheng) but with Armada's
bootc/ostree rootfs, Steam/FEX/Proton stack and OTA updates.

Because sheng carries a different kernel (see below), the images come from a
dedicated pipeline:

```
just build-sheng-flashable <kernel-image-ref>     # locally
.github/workflows/build-sheng-disk.yml            # on GitHub Actions
```

## What differs from the standard Armada build

| | SD-card devices | sheng (this path) |
|---|---|---|
| Kernel | armada-packages (kernel.org 7.2 + patches) | **ianchb/sm8550-mainline @ `sheng-7.2.2`** (own DTS/touchscreen/board quirks) |
| Bootloader | ROCKNIX ABL reads ESP `/KERNEL` | original Xiaomi ABL reads `boot_b` |
| Output | `armada-<version>.img.gz` (whole SD disk, MBR) | `boot_b.img` + `linux_boot.img` + `linux.img` (fastboot, GPT partitions) |
| Rootfs layout | same BIB layout (ESP + /boot + btrfs /) | same; ESP unused, fstab rebaked, `x-systemd.growfs` |
| Update after OTA | `armada-bootimg-sync` rewrites `/KERNEL` | `armada-bootimg-sync` rewrites the `boot_b` **partition** (device profile) |

Everything else — Steam bootstrap, FEX + Arch rootfs, Proton, Decky plugins,
Armada Control, KDE Plasma, Waydroid — is the same Armada rootfs.

## Prerequisites

- Xiaomi Pad 6S Pro with an **unlocked bootloader** (the vendor ABL must be
  kept — do NOT flash a different ABL with this pipeline)
- **TWRP** installed (used once, for partition setup)
- `fastboot` on your computer
- USB cable. **Back up your data first — this erases the target partitions.**

## 1. Create the partitions (TWRP, one time)

Inside TWRP, open a terminal (or use the File Manager) and shrink/part the
disk. The tablet's internal storage is a GPT disk; create **two** partitions
at the end of the disk (names are load-bearing — the fstab uses them):

```
parted /dev/block/sda
(parted) print                       # see the existing layout
(parted) unit s
(parted) mkpart linux_boot ext4 <start> <end>    # >= 1 GiB
(parted) name 1 linux_boot                       # adjust the index!
(parted) mkpart linux ext4 <end> <end-of-disk>
(parted) name 2 linux
(parted) quit
```

> Hint: the names are looked up as `PARTLABEL=linux_boot` / `PARTLABEL=linux`
> by the rootfs fstab, and by `fastboot flash linux_boot` / `fastboot flash
> linux` by GPT label. If you already ran debian-sheng's single-partition
> layout (`linux` only), add the `linux_boot` partition (~2 GiB is plenty) and
> keep or recreate `linux`.

Reboot into fastboot (`adb reboot bootloader` or hold POWER+VOL-).

## 2. Flash

Download the `armada-sheng-flashable` artifact (or build locally:
`just build-sheng-flashable localhost/armada-sheng-kernel:7.2.2`), unpack,
then run the included script:

```
cd armada-sheng-flashable/
./flash.sh
```

which does:

```
fastboot erase dtbo_b
fastboot flash boot_b     boot_b.img
fastboot flash linux_boot linux_boot.img
fastboot flash linux      linux.img
fastboot reboot
```

Verify the images first (`sha256sum -c SHA256SUMS`; flash.sh does it).

## 3. First boot

- First boot takes a few minutes (btrfs + ostree deployment init, Steam
  bootstrap is pre-baked already).
- Login: user `armada` / `armada` (change it: `passwd armada`).
- Steam big picture (gamemode) or KDE Plasma desktop: pick in the session
  switcher (menu bar icon or `armada-session-select`).
- Suspend: `mem` is configured in the sheng device profile.
- OTA: `steamos-update` / Steam settings (update channel `testing` by
  default; the pipeline pushes the container to
  `ghcr.io/<owner>/armada:sheng-<date>-<sha>`).

## What is NOT yet ported from debian-sheng

| Feature | Status |
|---|---|
| Sensors (rotation/light, libssc + iio-sensor-proxy) | not in the Armada image (kernel QRTR/fastrpc is enabled; userspace needs packaging) |
| Xiaomi keyboard authentication (devauth) | kernel driver only exists in the ianchb tree; no userspace service yet |
| Fingerprint (TEE) | not supported (proprietary TEE stack) |
| Stylus (THP) / pen status | not ported |
| 120W MIPPS charging | not ported (regulator works, charging speed is stock) |

These are additive — the tablet already boots and runs without them.

## Troubleshooting

- **Boot loop / no boot**: re-flash `boot_b.img` alone
  (`fastboot flash boot_b boot_b.img`). If that fails, re-flash all three and
  check the partition names (`fastboot getvar current-slot`, `fastboot
  devices`).
- **Sits at ABL menu**: `boot_b` erased (`fastboot erase boot_b` was run) or
  `dtbo_b` mangled — re-flash `boot_b.img`.
- **OTA does not change the booted kernel** (only after an update): the
  `armada-bootimg-sync` regen writes `boot_b` on shutdown; if it never ran,
  run `sudo systemctl restart armada-bootimg-sync.service` then reboot.
- **Black screen on first boot**: the baked `initramfs` may predate the rootfs
  content; re-export the images after a clean rebuild.
