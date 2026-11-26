# Win2Go USB Creator for Linux

An interactive Bash script that applies a Windows image to a USB disk and creates UEFI boot files with BCD-SYS. Windows boot on physical hardware is pending validation.

## Requirements

Use Linux with sudo access, a local x86-64 Windows ISO containing `sources/install.wim` or `sources/install.esd`, and a writable whole USB disk with no mounted filesystems, swap, or active volumes. Win2Go must be able to trace the ISO and host boot files to their physical storage. Filesystems such as Btrfs and overlayfs, network mounts, and loop devices with unreadable backing information are rejected.

On Ubuntu or Linux Mint, check the required commands with:

```bash
bash scripts/deps-ubuntu.sh --check
```

The dependency installer can install the APT packages. See [FIXES.md](FIXES.md) for the BCD-SYS setup and the read-only USB diagnostic.

## Usage

Run `./win2go.sh` to select an ISO and USB disk interactively. The ISO menu scans the current directory, `~/Downloads`, and `~/Descargas`. To preview the operations, set `target` to the whole USB disk path you identified and run:

```bash
./win2go.sh --dry-run --iso /path/to/windows.iso --drive "$target"
```

The preview checks the ISO's location and target identity, then prints the planned operations. It runs without sudo or mounts. The installer checks the ISO contents and Windows edition during the normal run.

Run the same command without `--dry-run` to install. Review the displayed model, serial, size and device path before confirming. After you type `yes`, Win2Go erases the selected disk and creates a GPT partition table with a 512 MiB FAT32 EFI partition and an NTFS Windows partition. Disks larger than 64 GiB require an additional confirmation. Keep the target connected and avoid running concurrent disk tools or another BCD-SYS process during installation.

Use `-v` to trace commands for troubleshooting. ISO downloads, driver injection, automatic user setup, OOBE bypass, and Legacy BIOS boot are outside the current implementation.

## Tests

```bash
bash tests/smoke.sh
bash tests/dependencies.sh
bash tests/integration.sh
bash tests/images.sh
```

The first three suites cover input validation, dependency statuses, and the full command flow with mocked devices and mounts. The image suite uses `parted`, `sfdisk`, `mkfs.vfat`, `mkfs.ntfs`, `blkid`, `wimlib-imagex`, and `ntfscat` on sparse files to verify GPT, FAT32, NTFS and direct WIM/ESD application. All suites run without sudo, loop devices, or physical disks.

The integration suite simulates BCD-SYS and checks its arguments and output validation. Running BCD-SYS against a real Windows image and booting it under UEFI remain pending.

## Contributors

Original script created and maintained by **Jace**.

## License

MIT License
