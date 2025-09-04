# Win2Go USB Creator for Linux

A fully-featured, interactive script to create **Windows To Go** USB drives from Linux. Supports Windows 10, Windows 11, and Tiny10 ISOs with first-boot driver installation, OOBE skip, and Windows 11 bypass for unsupported hardware.

---

## Features

* **ANSI-colored, interactive UI** with clear step titles
* **Automatic ISO detection** in current directory and `~/Downloads`
* **ISO download menu**:

  * Official Windows ISO (direct URL)
  * Tiny10 ISO (x64 23H2, archive.org)
* **CLI options**:

  * `--iso/-i` : Specify ISO path or URL
  * `--drive/-d` : Specify USB device
  * `--drivers/-r` : Specify a folder containing drivers
  * `--user/-u` : Username for the installed Windows
  * `-y` : Auto-run without prompts
  * `-v` : Verbose output (ISO/device info)
* **Safe USB selection**:

  * Lists block devices with size and model
  * Warns if drive is larger than 64GB
  * Automatically unmounts any mounted partitions
* **Partitioning & formatting**:

  * GPT label
  * EFI partition (FAT32, 512MB)
  * Windows partition (NTFS, remainder of disk)
* **WIM/ESD support**:

  * Detects `install.wim` or `install.esd`
  * Multi-index selection
  * Automatic Windows 11 detection
* **Applying Windows image**:

  * Uses `wimlib-imagex apply`
  * Spinner + real-time timer for long operations
  * Preserves all necessary files despite Linux attribute differences
* **Copying EFI & boot files** for UEFI boot
* **Driver installation**:

  * Drivers copied to the USB
  * Installed automatically on first boot via `SetupComplete.cmd`
* **Autounattend.xml**:

  * Skips OOBE screens
  * Creates administrator account automatically
  * Optionally uses `$USER` or custom username
* **Windows 11 bypass**:

  * Skips TPM, Secure Boot, RAM, CPU checks
  * Added automatically if a Windows 11 ISO is detected
* **Safe cleanup**:

  * Unmounts all partitions
  * Attempts to power-off or eject the USB
  * Asks whether to delete downloaded ISO
* **Ctrl+C handling**:

  * Safely stops script, unmounts USB, and optionally deletes downloaded ISO
* **Continuous spinner and timer** on all long-running steps

---

## Requirements

* Linux or macOS system with root/sudo privileges
* Dependencies:

### Debian/Ubuntu

```bash
sudo apt update
sudo apt install wimtools parted dosfstools ntfs-3g util-linux wget
```

### Fedora

```bash
sudo dnf install wimlib-partimage parted dosfstools ntfs-3g util-linux wget
```

### Arch Linux / Manjaro

```bash
sudo pacman -S wimlib-partimage parted dosfstools ntfs-3g util-linux wget
```

### macOS (using Homebrew / Atomic)

```bash
brew install wimlib parted dosfstools ntfs-3g wget
# For Atomic systems (Linux containerized), ensure /dev access is allowed for USB
```

* Script requires **sudo/root** access for partitioning, formatting, and writing Windows images.
* Tested on Linux (Debian/Ubuntu/Fedora/Arch) and macOS (Intel/Apple Silicon with Rosetta for some dependencies).

---

## Usage

### Interactive Mode

```bash
sudo ./win2go.sh
```

* Follow the interactive menus to select ISO, USB device, drivers, and username.
* The script will display colored steps, live spinner, and timer for long tasks.

### CLI Mode

```bash
sudo ./win2go.sh --iso /path/to/Win10.iso --drive /dev/sdb --drivers ./drivers --user MyUser -y -v
```

* `--iso/-i`: Path to ISO or direct download URL
* `--drive/-d`: Target USB device (e.g., `/dev/sdb`)
* `--drivers/-r`: Path to a folder containing drivers
* `--user/-u`: Username for Windows installation
* `-y`: Auto-run all steps without prompts
* `-v`: Verbose output (device and ISO info)

---

## Notes

* **All data on the selected USB drive will be erased.**
* ISO can be downloaded automatically if not present locally.
* Drivers will be installed automatically during first boot.
* Windows 11 bypass options are added automatically if a Windows 11 ISO is detected.
* Script can handle multi-index WIM/ESD images.

---

## Example

```bash
sudo ./win2go.sh --iso https://archive.org/download/tiny-10-23-h2/tiny10%20x64%2023h2.iso --drive /dev/sdb --drivers ./drivers --user MyUser -y -v
```

* Automatically downloads Tiny10 ISO
* Prepares USB `/dev/sdb`
* Copies drivers from `./drivers`
* Creates user `MyUser`
* Skips all prompts
* Shows verbose output

---

## Screenshots / Workflow

```
=== Step 1: Select USB Drive ===
1) /dev/sdb - 32G - Flash Disk
2) /dev/sdc - 64G - SanDisk
Select drive number: 1

=== Step 5: Applying Windows image (this may take a while) ===
Applying image... ◐ [Elapsed: 00:12:34]
...
Done applying image ✅ [Total: 00:12:34]
```

---

## Contributors

* Original script created and maintained by **Jace**

---

## License

MIT License — free to use, modify, and redistribute.
