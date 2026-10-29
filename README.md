# XR1710G: bootloader replacement from the running system

**English** | [Русский](README.ru.md)

Flashes a new bootloader into the `chainloader` slot of the XR1710G
(Airoha AN7581, a.k.a. Gemtek/Brightspeed/econet `xr1710g-ubi`) **with one
command from the running system** — no UART, TFTP or buttons. Two bootloaders
are available:

| | **http** — http-uboot | **openwrt** — OpenWrt chainloader |
| --- | --- | --- |
| Source | [YYH2913/http-uboot](https://github.com/YYH2913/http-uboot), release `xr1710g_260805` | [akorshun/openwrt](https://github.com/akorshun/openwrt), release [`xr1710g-r7`](https://github.com/akorshun/openwrt/releases/tag/xr1710g-r7) |
| File | `xr1710g-chainloader-slot.bin` (uImage shim + FIT) | `openwrt-airoha-an7581-gemtek_xr1710g-ubi-chainload-uboot.itb` (FIT) |
| Recovery | web recovery at `http://192.168.255.1` with its own DHCP, 10GbE port | reset at power-on → recovery image via TFTP from `192.168.1.10`; `recovery` UBI volume as fallback |
| Boot failure | enters web recovery by itself (`run boot_ubi \|\| http_recovery`) | boots the `recovery` volume, if there is one |
| UBI layouts | 2.0 / 1.5 / 1.0 | 2.0 only |
| Console | — | boot menu on UART (TFTP, recovery, installer) |

Pick **http** if you want a browser-based recovery and flexible layouts; pick
**openwrt** if you run OpenWrt and want the same bootloader the official
image ships for this board.

Tested on hardware: an XR1710G with iStoreOS `v1.4.0 r0+1-99598e539d` (kernel 6.18.41),
which came with a third-party `U-Boot 2026.07-xr1710g-wiro-recovery`, and with
the OpenWrt `xr1710g-r*` builds (kernel 6.18.55).

## How it works

The `chainloader` slot (1 MiB at `0x600000`) is read-only in the system:
`/sys/class/mtd/mtd1/flags` lacks the `MTD_WRITEABLE` bit, and `dd` says
`Permission denied`. There is usually no `kmod-mtd-rw` for such builds in the
feeds — kernel modules are published under the kernel config hash
(e.g. `6.18.41~df820d96…`), and nobody builds that.

The way out is that the `vermagic` of these kernels has no config hash:

```
vermagic=6.18.41 SMP mod_unload aarch64
```

So `mtd-rw` from **any** upstream build of the same kernel version loads
normally. Structure layout is not a concern either: `mtd-rw` touches
`struct mtd_info` at exactly one offset (`flags`, the second field, offset 4),
and no config-dependent field precedes it. This is checked automatically:
`tests/check_module.py` disassembles the module and fails if it touches
anything else. The repository carries modules for kernels **6.18.41** and
**6.18.55**; the script picks the one that matches the running kernel.

The rest is straightforward: the script lifts the protection, writes the slot
with `mtd write`, verifies the write by reading it back (sha256), **restores
the backup by itself** on a mismatch, brings the saved U-Boot environment in
line with the new bootloader, unloads the module and reboots.

## Flashing

```bash
wget -O /tmp/flash.sh https://raw.githubusercontent.com/akorshun/xr1710g-uboot-recovery/main/flash.sh && sh /tmp/flash.sh
```

The script first asks for the language (English / Русский) and then which
bootloader to flash. Without questions:

```bash
sh /tmp/flash.sh -l en -u openwrt -y
```

Download and run in two steps and without `-q`: a router on the bench often
has no WAN, and then `wget -qO- … | sh` silently does nothing — DNS does not
answer, 0 bytes arrive, `sh` reads empty input and exits with 0. Here the error
is visible.

The script needs internet only to download the image and, if needed, the
module. Offline, copy the files next to it and run it locally — from a PC
(Git Bash, Linux, macOS):

```bash
for f in flash.sh firmware/xr1710g-chainloader-slot.bin firmware/openwrt-airoha-an7581-gemtek_xr1710g-ubi-chainload-uboot.itb firmware/mtd-rw-6.18.41.ko firmware/mtd-rw-6.18.55.ko; do ssh root@192.168.1.1 "cat > /tmp/$(basename "$f")" < "$f"; done
```

then on the router `sh /tmp/flash.sh` (it picks the files up from `/tmp`).

What `flash.sh` does:

| Step | Details |
| --- | --- |
| language | `-l en\|ru`, `$XR1710G_LANG`, or a question; with `-y` taken from `$LANG` (default English) |
| bootloader | `-u http\|openwrt` or a question; with `-y` and no `-u` — `http`; with `-i` — from the image header |
| board | `econet,xr1710g-ubi` from `/tmp/sysinfo/board_name` or the DT |
| slot | partition `chainloader`, exactly 1 MiB |
| current bootloader | U-Boot version (or "OpenWrt U-Boot (FIT)") from the slot dump |
| UBI layout | from the end address of `ubi`: 2.0 / 1.5 / 1.0 |
| image | size ≤ 1 MiB; uImage header for http, FIT with the OpenWrt U-Boot for openwrt; sha256 against the release; HTTP recovery present |
| openwrt only | layout must be 2.0; the `fit` volume must hold a FIT with `config-1` (what the OpenWrt bootloader boots), otherwise a warning |
| backup | `/root/xr1710g-chainloader-<date>.bin` + sha256 |
| unlocking | the system `kmod-mtd-rw`, otherwise the module for this kernel from the repository, vermagic checked |
| writing | `mtd write` + sha256 read-back; automatic rollback on mismatch |
| environment | see below |
| finish | `rmmod`, reboot after confirmation |

Options: `-u http|openwrt` bootloader, `-l en|ru` language, `-i <file>` your
own image, `-m <file>` your own `mtd-rw.ko`, `-r <file>` roll back to a
backup, `-b` write nothing (checks, backup and hints only), `-n` no reboot,
`-y` no questions, `-h` help.

Copy the backup to your PC:

```bash
scp root@192.168.1.1:/root/xr1710g-chainloader-*.bin .
```

### U-Boot environment

Both bootloaders keep their environment in the UBI volumes `ubootenv` /
`ubootenv2`, and a saved environment **replaces the built-in one completely**.
So `flash.sh`:

* leaves an empty environment (`fw_printenv` says `Bad CRC`) alone — the new
  bootloader uses its defaults;
* **wipes** both volumes (`ubiupdatevol -t`) when the saved environment belongs
  to the other bootloader (`check_buttons` → OpenWrt, `http_recovery` →
  http-uboot), so the new one starts from its own defaults; without that the
  OpenWrt bootloader would lose the reset button handling, and http-uboot its
  `|| http_recovery` fallback;
* for http-uboot over any other environment only sets `bootcmd` to the value
  from the new image.

## Rollback

```bash
sh /tmp/flash.sh -r /root/xr1710g-chainloader-<date>.bin
```

The same works for a backup from the PC — copy it back to `/tmp`. The
bootloader kind is taken from the backup itself, so a backup of either one can
be restored. If the system no longer boots, use the recovery of the bootloader
in the slot (below).

## Recovery with http-uboot

The address is always `http://192.168.255.1`, DHCP gives the PC
`192.168.255.2`, cable into the 10GbE port.

* **By itself**: `bootcmd=run boot_ubi || http_recovery`, so recovery comes up
  without anyone when boot fails.
* **With the button**: power the router off, power it on and, when the 10GbE
  port LED blinks, press and hold `reset`; release it when the status LED
  changes from steady red to the "running" recovery pattern. There is plenty of
  time.

The repository scripts upload images into it from a PC — they find or
download the image, check sha256 and the header, wait for recovery and show
progress. Like `flash.sh`, they speak English or Russian (`upload.sh -L en|ru`,
`upload.ps1 -Lang en|ru`, `$XR1710G_LANG`, or a question at start-up):

```bash
sh upload.sh                     # the http-uboot bootloader, target uboot
```

```powershell
.\upload.ps1 -Target firmware -Layout 2.0 -File .\openwrt-...-sysupgrade.itb
```

The manual equivalent:

```bash
curl -X POST --data-binary @xr1710g-chainloader-slot.bin -H 'Content-Type: application/octet-stream' http://192.168.255.1/upload/uboot
```

The recovery checks the uImage magic and CRC of the `uboot` target, so only
`xr1710g-chainloader-slot.bin` goes there — not `u-boot.bin`, not `*.itb`
(including the OpenWrt chainloader). To switch to the OpenWrt bootloader, boot
the system and use `flash.sh -u openwrt`.

The firmware layout is chosen **from the DTS of the image being uploaded**,
not from the current one:

| Choice | Partition | Size | End |
| --- | --- | --- | --- |
| UBI 2.0 | `ubi` | 439 MiB | `0x1be00000` |
| UBI 1.5 | `ubi1.5` | 473.75 MiB | `0x1e0c0000` |
| UBI 1.0 | `ubi1.0` | 503 MiB | `0x1fe00000` |

A wrong choice does not break the bootloader, but Linux may wait for
`/dev/fit0` forever. A firmware upload wipes the system, overlay, packages and
the saved U-Boot environment; factory MACs and EEPROM are restored from the
vendor DSD region.

## Recovery with the OpenWrt bootloader

1. Give the PC the address `192.168.1.10/24`, connect it to a LAN port and
   serve `openwrt-airoha-an7581-gemtek_xr1710g-ubi-initramfs-recovery.itb`
   (from the [`xr1710g-r7`](https://github.com/akorshun/openwrt/releases/tag/xr1710g-r7)
   release) from a TFTP server.
2. Power the router on, press reset **1-2 s later** (held at power-on the SoC
   waits for a UART download instead) and keep it pressed until the blue LED
   lights up, about 15-20 s.
3. The recovery system comes up at `192.168.1.1`; sysupgrade from there.

If the `fit` volume fails to boot, the bootloader boots the `recovery` UBI
volume by itself, if there is one. On the UART console (115200 8N1) there is a boot menu: TFTP
boot, recovery from flash, installer via TFTP.

## Repository contents

| File | Purpose |
| --- | --- |
| `flash.sh` | on the router: checks, backup, unlocking, slot write, environment |
| `upload.sh` | on a PC (Linux/macOS/Git Bash): upload into the http-uboot web recovery |
| `upload.ps1` | the same for Windows PowerShell 5.1+ |
| `firmware/xr1710g-chainloader-slot.bin` | http-uboot from release `xr1710g_260805` |
| `firmware/openwrt-airoha-an7581-gemtek_xr1710g-ubi-chainload-uboot.itb` | OpenWrt chainloader from release `xr1710g-r7` |
| `firmware/mtd-rw-6.18.41.ko` | MTD unlock module for 6.18.41 kernels |
| `firmware/mtd-rw-6.18.55.ko` | MTD unlock module for 6.18.55 kernels |
| `tests/run.sh` | 138 checks on a fake router and a mock recovery |
| `tests/check_slot.py` | http-uboot slot image: magic, CRC, FIT, recovery present |
| `tests/check_module.py` | module: ELF, vermagic, symbols, structure accesses |

```
deaefed37c13f25eb551d60951cec7077adfd01c6964174d0aa938288d27be30  xr1710g-chainloader-slot.bin
0876dbc4c16bbc6d451c2c4bcc156c745dce20547406c807c22855cf39dd98fb  openwrt-airoha-an7581-gemtek_xr1710g-ubi-chainload-uboot.itb
afbe8712be475cdbf75375ab1d1b28264e9b0578f1a840b0267d52a3c5783a62  mtd-rw-6.18.41.ko
c4a456d7440ad89d52e27bd16bebd352e569fea6b68cb200589c82fe1218669b  mtd-rw-6.18.55.ko
```

The modules come from the official snapshot packages
`kmod-mtd-rw-6.18.41.2021.02.28~e8776739-r1.apk`
(`downloads.openwrt.org/snapshots/targets/airoha/an7581/kmods/6.18.41-1-1f70d6d135d30ef513a7f9bf11f7c3ec/`)
and `kmod-mtd-rw-6.18.55.2021.02.28~e8776739-r1.apk`
(`…/kmods/6.18.55-1-17f48094cd3bb72b75ee0a8e3d9703b8/`); sources are
[openwrt/packages, `kernel/mtd-rw`](https://github.com/openwrt/packages/tree/master/kernel/mtd-rw)
and [jclehner/mtd-rw](https://github.com/jclehner/mtd-rw), license GPL-2.0.
The script still compares the module `vermagic` with the kernel and refuses to
load it on a mismatch.

## Device details

* Partitions: `vendor` 6 MiB, `chainloader` 1 MiB (`0x600000`), `ubi`
  `0x1b700000`, `reserved_bmt` 66 MiB. There is no active remapping layer
  (NMBM/BMT) — `reserved_bmt` is just a reserved area, so `mtd` writes go
  straight to flash.
* UBI volumes: `fit`, `ubootenv`, `ubootenv2`, `factory`, `rootfs_data`
  (an OpenWrt installation may also have `recovery`).
* The http-uboot slot is a legacy uImage shim with valid CRCs, with a FIT
  holding the second-stage U-Boot at `0x2100`. The OpenWrt chainloader is a
  plain FIT that the vendor bootloader loads directly.
* `mtd write` erases only the blocks under the data, so the last block of the
  slot keeps the tail of the previous bootloader. That does not matter for a
  FIT — its size is in the header — and the script compares exactly as many
  bytes as the image has.
* The third-party `xr1710g-wiro-recovery` bootloader ignores an environment
  written from Linux: the saved env is correct by the U-Boot formula (CRC over
  `data` with `ENV_SIZE=0x4000`, redundant copy), but that build does not take
  it — probably a different `CONFIG_ENV_SIZE` or a non-redundant environment.
  So "reboot into recovery via `bootcmd`" does not work with it; http-uboot has
  `|| http_recovery` for that.

## Tested

* **On hardware**: `flash.sh` with http-uboot ran end to end on a live XR1710G
  — unlocking via the module (`mtd-rw: mtd0/mtd1/mtd3: setting writeable flag`,
  `mtd2` skipped as already writable), slot write, matching read-back sum,
  `bootcmd` fix, reboot. The system came up by itself with
  `U-Boot 2026.07-00766-g53b73174c0fc` in the slot, MACs and data intact,
  partition protection back (`mtd1=0x0`).
* **Both directions with flash.sh 3.0** (2026-10-29, XR1710G on OpenWrt
  `xr1710g-r7`, kernel 6.18.55, the bundled `mtd-rw-6.18.55.ko`, empty saved
  environment):
  * `-u http` over the OpenWrt bootloader: slot written and verified, reboot,
    the vendor AXON bootloader starts the uImage shim, http-uboot boots
    OpenWrt from the `fit` volume (`config-1`). Reset at power-on brings up the
    web recovery: `Recovery button detected`, the PC gets `192.168.255.2` over
    DHCP, `/about` reports layout 2.0, `/status` and the web page answer.
    Without the button it boots OpenWrt again.
  * `-u openwrt` back over http-uboot: slot written and verified, reboot,
    AXON loads the FIT directly, `U-Boot 2026.07-OpenWrt-r0-e80747b` takes its
    default environment (`bad CRC`), the reset check in `preboot` reads `off`,
    the boot menu runs `boot_ubi` and OpenWrt comes up.

  In both cases the slot matched the release sha256 after the reboot, the
  protection was back (`mtd1=0x0`), the module unloaded, and WAN, LAN and
  Wi-Fi came up with the factory MACs. Wiping an environment left by the other
  bootloader has so far been tested in CI only: on this unit the saved
  environment was empty each time.
* **In CI**: 138 checks on a fake router (faked `/proc/mtd`,
  `/sys/class/mtd`, `/sys/class/ubi`, slot dump, `mtd`, `insmod`,
  `fw_printenv`/`fw_setenv`, `ubiupdatevol`, `reboot`) and on a mock recovery,
  under `dash`, `busybox sh` and `bash`, in both languages; plus shellcheck,
  parsing `upload.ps1` with the PowerShell parser, checks of the slot image and
  both modules, and comparing both bootloaders with their release assets.

## Credits

* [YYH2913/http-uboot](https://github.com/YYH2913/http-uboot) — the U-Boot
  build with HTTP recovery for the XR1710G.
* [jclehner/mtd-rw](https://github.com/jclehner/mtd-rw) — the module that makes
  writing the slot possible.
* The OpenWrt chainloader is based on the XR1710G chainloader by Kenneth
  Kasilag and the Gemtek W1700K support in OpenWrt.
