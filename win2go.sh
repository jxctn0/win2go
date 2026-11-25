#!/bin/bash
set -e

# =======================
# Win2Go USB Creator
# =======================

# Colors
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
CYAN="\033[1;36m"
RESET="\033[0m"

# Globals
ISO_FILE=""
DRIVE=""
DRIVERS=""
USERNAME="$USER"
AUTO_YES=false
VERBOSE=false

# =======================
# Helper functions
# =======================

clear_step() {
    clear
    echo -e "${CYAN}=== $1 ===${RESET}"
}

run_with_spinner() {
    local cmd="$*"
    local spin=('◐' '◓' '◑' '◒')
    local i=0
    local start_time=$(date +%s)

    bash -c "$cmd" &
    local pid=$!

    while kill -0 $pid 2>/dev/null; do
        local now=$(date +%s)
        local elapsed=$((now - start_time))
        local h=$((elapsed/3600))
        local m=$(((elapsed%3600)/60))
        local s=$((elapsed%60))
        printf "\r${CYAN}%s... %s [Elapsed: %02d:%02d:%02d]${RESET}" "$cmd" "${spin[$i]}" "$h" "$m" "$s" >&2
        i=$(( (i+1) %4 ))
        sleep 0.2
    done

    wait $pid
    local total=$(( $(date +%s) - start_time ))
    local h=$((total/3600))
    local m=$(((total%3600)/60))
    local s=$((total%60))
    printf "\r${GREEN}%s completed ✅ [Total: %02d:%02d:%02d]${RESET}\n" "$cmd" "$h" "$m" "$s" >&2
}

# Ctrl+C and error/exit handler
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${RESET}"
    sudo umount /mnt/win 2>/dev/null || true
    sudo umount /mnt/boot 2>/dev/null || true
    sudo umount /mnt/iso 2>/dev/null || true
    [[ -z "${TEMP_WIN:-}" ]] || rm -rf -- "$TEMP_WIN"
    [[ -z "${TEMP_BOOT:-}" ]] || rm -rf -- "$TEMP_BOOT"
    if [[ -n "${DOWNLOADED_ISO:-}" ]]; then
        read -p "Delete downloaded ISO? (y/N): " deliso
        if [[ "$deliso" =~ ^[Yy]$ ]]; then rm -f -- "$DOWNLOADED_ISO"; fi
    fi
}
trap cleanup EXIT
trap 'exit 130' INT

# ...existing code...

# =======================
# Parse CLI arguments
# =======================
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --iso|-i) ISO_FILE="$2"; shift ;;
        --drive|-d) DRIVE="$2"; shift ;;
        --drivers|-r) DRIVERS="$2"; shift ;;
        --user|-u) USERNAME="$2"; shift ;;
        -y) AUTO_YES=true ;;
        -v) VERBOSE=true ;;
        *) echo -e "${YELLOW}Unknown parameter passed: $1${RESET}" ;;
    esac
    shift
done

# =======================
# Step 1: ISO Selection
# =======================
clear_step "Step 1: Select Windows ISO"
if [[ -z "$ISO_FILE" ]]; then
    ISOS=()
    SEARCH_HOME="${SUDO_USER:+$(getent passwd "$SUDO_USER" | cut -d: -f6)}"
    for dir in "$PWD" "${SEARCH_HOME:-$HOME}/Downloads" "${SEARCH_HOME:-$HOME}/Descargas"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' iso; do ISOS+=("$iso"); done < <(
            find "$dir" -maxdepth 1 -type f -iname '*.iso' -print0 2>/dev/null || true
        )
    done
    (("${#ISOS[@]}" > 0)) || { echo "No ISOs found. Use --iso /path/to/windows.iso" >&2; exit 1; }
    for i in "${!ISOS[@]}"; do printf '%d) %s\n' "$((i+1))" "${ISOS[$i]}"; done
    read -r -p "Choose ISO number: " iso_choice
    [[ "$iso_choice" =~ ^[1-9][0-9]*$ ]] &&
        (( iso_choice <= ${#ISOS[@]} )) || { echo "Invalid ISO selection" >&2; exit 1; }
    ISO_FILE="${ISOS[$((iso_choice-1))]}"
fi
[[ -f "$ISO_FILE" && -r "$ISO_FILE" ]] || { echo "ISO not found: $ISO_FILE" >&2; exit 1; }
ISO_FILE=$(readlink -f -- "$ISO_FILE")
echo -e "${GREEN}Selected ISO: $ISO_FILE${RESET}"

# =======================
# Step 2: USB Drive Selection
# =======================
clear_step "Step 2: Select USB drive"
mapfile -t DRIVES < <(lsblk -dnpo NAME,TYPE,TRAN | awk '$2=="disk" && $3=="usb" {print $1}')
(("${#DRIVES[@]}" > 0)) || { echo "No USB disks found" >&2; exit 1; }
if [[ -z "$DRIVE" ]]; then
    for i in "${!DRIVES[@]}"; do
        printf '%d) %s - %s\n' "$((i+1))" "${DRIVES[$i]}" "$(lsblk -dn -o SIZE,MODEL "${DRIVES[$i]}")"
    done
    read -r -p "Select USB disk number: " choice
    [[ "$choice" =~ ^[1-9][0-9]*$ ]] && (( choice <= ${#DRIVES[@]} )) ||
        { echo "Invalid USB selection" >&2; exit 1; }
    DRIVE="${DRIVES[$((choice-1))]}"
fi
DRIVE=$(readlink -f -- "$DRIVE")
[[ -b "$DRIVE" && "$(lsblk -dn -o TYPE "$DRIVE")" == disk && "$(lsblk -dn -o TRAN "$DRIVE")" == usb ]] ||
    { echo "ERROR: Target must be a whole USB disk" >&2; exit 1; }
echo "Selected USB disk: $DRIVE"

# Warn large drives
SIZE_GB=$(lsblk -dn -b -o SIZE "$DRIVE")
SIZE_GB=$((SIZE_GB / 1024 / 1024 / 1024))
if [[ $SIZE_GB -gt 64 ]]; then
    read -p "⚠️ WARNING: $DRIVE is larger than 64GB. Type YES to continue: " yn
    if [[ "$yn" != "YES" ]]; then echo "Canceled."; exit 1; fi
fi

# Unmount partitions
MOUNTED=$(lsblk -ln -o MOUNTPOINT "$DRIVE" | grep -v "^$" || true)
if [[ -n "$MOUNTED" ]]; then
    echo "⚠️ $DRIVE has mounted partitions."
    echo "ERROR: Unmount all partitions before continuing; refusing to force unmount." >&2
    exit 1
fi

# Essential preflight: do not erase a device if Windows boot configuration cannot be built.
for cmd in parted partprobe udevadm mkfs.vfat mkfs.ntfs wimlib-imagex bcd-sys mount hivexsh hivexregedit readpe peres setfattr fatattr; do
    command -v "$cmd" >/dev/null || { echo "ERROR: Missing dependency: $cmd. Run: bash scripts/deps-ubuntu.sh --install" >&2; exit 1; }
done
[[ "$(lsblk -dn -o TYPE "$DRIVE")" == "disk" && "$(lsblk -dn -o TRAN "$DRIVE")" == "usb" ]] || {
    echo "ERROR: Target is not a whole USB disk." >&2; exit 1;
}
# Read and validate Windows image BEFORE erasing anything.
sudo mkdir -p /mnt/iso
sudo mount -o loop,ro "$ISO_FILE" /mnt/iso
WIM=""
for name in install.wim install.esd; do
    if [[ -f "/mnt/iso/sources/$name" ]]; then WIM="/mnt/iso/sources/$name"; break; fi
done
[[ -n "$WIM" ]] || { echo "ERROR: ISO does not contain install.wim/install.esd" >&2; exit 1; }
wimlib-imagex info "$WIM" | grep -E '^(Index|Name):' || true
read -r -p "Choose Windows edition index: " IMAGE_INDEX
[[ "$IMAGE_INDEX" =~ ^[1-9][0-9]*$ ]] &&
    wimlib-imagex info "$WIM" "$IMAGE_INDEX" >/dev/null ||
    { echo "ERROR: Invalid Windows image index" >&2; exit 1; }
# Do not permit the ISO to be stored on the disk that will be erased.
ISO_SOURCE=$(findmnt -n -o SOURCE --target "$ISO_FILE" || true)
[[ "$ISO_SOURCE" != "$DRIVE"* ]] ||
    { echo "ERROR: ISO is stored on target USB" >&2; exit 1; }
read -p "⚠️ This will ERASE all data on $DRIVE. Continue? (yes/no): " yn
if [[ "$yn" != "yes" ]]; then echo "Canceled."; exit 1; fi

# =======================
# Step 3: Partitioning & Formatting
# =======================
clear_step "Step 3: Partitioning $DRIVE"
# UEFI only; a working Windows installation also requires a valid BCD store.
run_with_spinner "sudo parted \"$DRIVE\" --script mklabel gpt"
run_with_spinner "sudo parted \"$DRIVE\" --script mkpart ESP fat32 1MiB 513MiB"
run_with_spinner "sudo parted \"$DRIVE\" --script set 1 esp on"
run_with_spinner "sudo parted \"$DRIVE\" --script mkpart Windows ntfs 513MiB 100%"
sudo partprobe "$DRIVE"
sudo udevadm settle
if [[ "$DRIVE" =~ [0-9]$ ]]; then
    PART1="${DRIVE}p1"
    PART2="${DRIVE}p2"
else
    PART1="${DRIVE}1"
    PART2="${DRIVE}2"
fi
sudo mkfs.vfat -F32 "$PART1"
sudo mkfs.ntfs -f "$PART2"

sudo mkdir -p /mnt/win /mnt/boot /mnt/iso
clear_step "Step 4: Applying Windows image to NTFS"
# Direct NTFS application preserves NTFS metadata better than extracting to ext4.
sudo wimlib-imagex apply "$WIM" "$IMAGE_INDEX" "$PART2"

clear_step "Step 5: Creating UEFI boot files and BCD"
sudo mount -t ntfs-3g "$PART2" /mnt/win
sudo mount "$PART1" /mnt/boot
[[ -f /mnt/win/Windows/System32/winload.efi ]] || { echo "Windows loader missing" >&2; exit 1; }
# Explicit -s keeps the boot store on the removable drive; no host NVRAM update.
sudo bcd-sys /mnt/win -s /mnt/boot -f uefi
[[ -s /mnt/boot/EFI/Microsoft/Boot/BCD ]] || { echo "ERROR: BCD was not created" >&2; exit 1; }
[[ -f /mnt/boot/EFI/Boot/bootx64.efi ]] || { echo "ERROR: UEFI fallback bootloader missing" >&2; exit 1; }

clear_step "Step 6: Finishing"
sync
sudo umount /mnt/win
sudo umount /mnt/boot
sudo umount /mnt/iso
echo -e "${GREEN}Windows files and UEFI BCD written. Physical boot has NOT yet been tested.${RESET}"
