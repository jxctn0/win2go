# Win2Go USB Creator for Linux

An interactive Bash script that applies a Windows image to a USB disk and creates UEFI boot files with BCD-SYS. Windows boot on physical hardware is pending validation.

## Requirements

Use Linux with sudo access, a local ISO containing `sources/install.wim` or `sources/install.esd`, and a whole USB disk with no mounted filesystems or active volumes.

On Ubuntu or Linux Mint, check the required commands with:

```bash
bash scripts/deps-ubuntu.sh --check
```

The dependency installer can install the APT packages. See [FIXES.md](FIXES.md) for the BCD-SYS setup and the read-only USB diagnostic.

## Usage

Run `./win2go.sh` to select an ISO and USB disk interactively. The ISO menu scans the current directory, `~/Downloads`, and `~/Descargas`. To specify both paths directly:

```bash
./win2go.sh --iso /path/to/windows.iso --drive /dev/sdb
```

Select the Windows edition and review the target disk before confirming. After you type `yes`, Win2Go erases the selected disk and creates a GPT partition table with a 512 MiB FAT32 EFI partition and an NTFS Windows partition. Disks larger than 64 GiB require an additional confirmation.

Use `-v` to trace commands for troubleshooting. ISO downloads, driver injection, automatic user setup, OOBE bypass, and Legacy BIOS boot are outside the current implementation.

## Tests

```bash
bash tests/smoke.sh
```

The smoke tests check syntax and rejection of invalid inputs. Physical Windows boot remains unverified.

## Contributors

Original script created and maintained by **Jace**.

## License

MIT License
