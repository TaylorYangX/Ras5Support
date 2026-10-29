# Ubuntu 20.04 on a Raspberry Pi 5

The Pi 5 can't boot the stock Ubuntu 20.04 image. Its firmware and 5.4 kernel predate the board, which is why the boot log says `bcm2712-rpi-5-b.dtb not found`. `build-pi5-focal.sh` builds a hybrid image from two Ubuntu images:

- **From 24.04.5:** the boot partition, the kernel (`6.8.0-*-raspi`), its modules and firmware.
- **From 20.04.5:** everything else in the root filesystem.

The result is a 20.04 userland running on the 24.04 kernel. Canonical doesn't support this combination, so keep the 24.04 image as your fallback.

## Build (WSL2)

```bash
cd ~/Desktop/Projects/Ras5Support
./build-pi5-focal.sh --download-only   # fetch both images, verify SHA256 (no root needed)
sudo ./build-pi5-focal.sh              # build; about 12 GB free space needed
```

The script exits on the first failed check and always unmounts and detaches what it attached. The finished image, `ubuntu-20.04-pi5-hybrid.img`, ends up in `work/`. It's also copied to your Windows Desktop when exactly one user Desktop exists under `/mnt/c/Users`; use `--out DIR` to choose another folder, or `--out ""` to skip the copy.

The script goes beyond the plain copy steps in four places, each needed for a 20.04 root on the 24.04 kernel:

| Problem | What the script does |
|---|---|
| 24.04's kernel modules are `.ko.zst`, and 20.04's kmod 27 can't load zstd modules | Decompresses them and reruns `depmod` |
| A newer 24.04 image could use ext4 features 20.04's e2fsprogs 1.45 rejects, which would break first-boot `resize2fs` (24.04.5 doesn't) | Checks for `orphan_file`, `fast_commit` and `stable_inodes` and removes them if present |
| 20.04's root plus the decompressed modules (~430 MB) and firmware (~670 MB) don't fit in 24.04's root partition | Enlarges the image (about +465 MB with 24.04.5) before copying |
| 24.04's cloud-init `user-data` may use syntax 20.04's cloud-init 22.2 ignores | Puts 20.04's own `user-data`/`network-config` in the boot partition (24.04's are kept as `*.noble`) |
| 20.04's `flash-kernel` would copy its 5.4 kernel over `/boot/firmware` on any kernel or initramfs update | Diverts it to a no-op stub (original kept as `/usr/sbin/flash-kernel.focal`). A boot-time service, `pi5-hold-kernel.service`, also runs `apt-mark hold` on the kernel packages |

## Flash and first boot

1. In Raspberry Pi Imager: **Choose OS → Use custom →** `ubuntu-20.04-pi5-hybrid.img`, then pick the SD card or USB drive. Answer **No** to OS customisation.
2. Boot the Pi 5 and log in as `ubuntu` / `ubuntu`. You'll be asked to set a new password. The root partition grows to fill the card on first boot.
3. Check:
   ```bash
   uname -r                        # 6.8.0-...-raspi
   grep VERSION= /etc/os-release   # 20.04
   apt-mark showhold               # linux-*raspi*, flash-kernel, ...
   ```

If it doesn't boot, a USB-UART probe on the 3-pin debug header between the micro-HDMI ports shows kernel messages that HDMI won't. To get back, reflash `work/ubuntu-24.04.5-preinstalled-server-arm64+raspi.img.xz`.

## Limits

- Headless server use is the realistic target. 20.04's Mesa and libcamera don't support the Pi 5, so there's no GPU acceleration, desktop or camera.
- GPIO is on the RP1 chip. RPi.GPIO and wiringPi don't work; use libgpiod or lgpio.
- Kernel updates are manual. To move to a newer 24.04 kernel, rebuild with a newer 24.04 image.
- Don't run `do-release-upgrade` when the login banner offers 22.04. Turn the offer off with `sudo sed -i 's/^Prompt=.*/Prompt=never/' /etc/update-manager/release-upgrades`.
- 20.04 is past standard support. Security updates need Ubuntu Pro (ESM).
