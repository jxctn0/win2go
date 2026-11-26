#!/usr/bin/env bash
# Install and verify Win2Go dependencies on Ubuntu/Linux Mint.
set -euo pipefail

usage() {
  printf 'Usage: bash scripts/deps-ubuntu.sh [--check|--install]\n'
  exit 2
}

mode="${1:---check}"
[[ $# -le 1 && ( "$mode" == "--check" || "$mode" == "--install" ) ]] || usage
[[ -r /etc/os-release ]] || { echo "Unsupported system: missing /etc/os-release" >&2; exit 1; }
. /etc/os-release
# Bash conditionals avoid invalid unquoted spaces in case patterns.
if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "linuxmint" &&
      " ${ID_LIKE:-} " != *" ubuntu "* ]]; then
  echo "This installer supports Ubuntu and Linux Mint only." >&2
  exit 1
fi

# These packages provide hivexsh (libhivex-bin), hivexregedit (libwin-hivex-perl), readpe/peres, and the
# FAT32/NTFS utilities used by BCD-SYS and Win2Go.
packages=(sudo udev git ca-certificates util-linux fdisk bsdextrautils parted dosfstools ntfs-3g wimtools
          libhivex-bin libwin-hivex-perl pev attr fatattr)

required_commands=(sudo git lsblk findmnt losetup readlink stat sfdisk hexdump parted partprobe udevadm
                   mkfs.vfat mkfs.ntfs ntfs-3g mount umount mountpoint wimlib-imagex
                   hivexsh hivexregedit readpe peres setfattr fatattr bcd-sys)
missing=()
check_commands() {
  missing=()
  local cmd
  for cmd in "${required_commands[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if (("${#missing[@]}" == 0)); then
    echo "All Win2Go/BCD-SYS dependencies are installed."
    return 0
  fi
  printf 'Missing commands: %s\n' "${missing[*]}"
  return 1
}

if [[ "$mode" == "--check" ]]; then
  check_commands || exit $?
  exit 0
fi

echo "Will install APT packages: ${packages[*]}"
echo "BCD-SYS is a separate third-party project: https://github.com/jpz4085/BCD-SYS"
echo "Review its setup.sh before trusting it. The installer will not run it without confirmation."
read -r -p "Install APT packages? Type YES: " answer
[[ "$answer" == YES ]] || { echo "Cancelled."; exit 1; }
sudo apt-get update
sudo apt-get install --no-install-recommends "${packages[@]}"

if ! command -v bcd-sys >/dev/null 2>&1; then
  read -r -p "Download BCD-SYS source for review? Type YES: " answer
  if [[ "$answer" == YES ]]; then
    target="${HOME}/BCD-SYS"
    if [[ ! -e "$target" ]]; then
      git clone https://github.com/jpz4085/BCD-SYS.git "$target"
    fi
    echo "BCD-SYS source: $target"
    echo "Inspect: less \"$target/setup.sh\""
    echo "Then install manually: cd \"$target\" && sudo ./setup.sh install"
  fi
fi
echo
if ! check_commands; then
  echo "Installation incomplete. Finish BCD-SYS installation and rerun --check."
  exit 1
fi
