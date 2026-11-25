#!/bin/bash
set -e

# =======================
# Win2Go USB Creator
# =======================

# Colors
GREEN="\033[1;32m"
CYAN="\033[1;36m"
RESET="\033[0m"

ISO_FILE=""
DRIVE=""
MOUNT_ROOT=""
MOUNTED_PATHS=()

clear_step() {
    printf '%b=== %s ===%b\n' "$CYAN" "$1" "$RESET"
}

cleanup() {
    local status=$? i
    for ((i = ${#MOUNTED_PATHS[@]} - 1; i >= 0; i--)); do
        if ! sudo umount -- "${MOUNTED_PATHS[i]}"; then
            echo "ERROR: Could not unmount ${MOUNTED_PATHS[i]}" >&2
            ((status != 0)) || status=1
        fi
    done
    if [[ -n "$MOUNT_ROOT" ]]; then
        rmdir -- "$MOUNT_ROOT/iso" "$MOUNT_ROOT/win" "$MOUNT_ROOT/boot" "$MOUNT_ROOT" 2>/dev/null || true
    fi
    return "$status"
}

mount_volume() {
    local target=${!#}
    sudo mount "$@" || return
    MOUNTED_PATHS+=("$target")
}

valid_selection() {
    local selection=$1 maximum=$2
    [[ "$selection" =~ ^[1-9][0-9]*$ ]] &&
        (( ${#selection} <= ${#maximum} && selection <= maximum ))
}

check_target() {
    local properties types mountpoints
    properties=$(lsblk -dnro TYPE,TRAN,MAJ:MIN -- "$DRIVE") || return 1
    [[ "$properties" == "disk usb $DRIVE_ID" ]] || {
        echo "ERROR: Target USB disk changed or is unavailable" >&2
        return 1
    }
    types=$(lsblk -nro TYPE -- "$DRIVE") || return 1
    mountpoints=$(lsblk -nro MOUNTPOINTS -- "$DRIVE") || return 1
    if [[ -n "${mountpoints//$'\n'/}" ]] || grep -qvxE 'disk|part' <<< "$types"; then
        echo "ERROR: Target USB disk has mounted filesystems or active volumes" >&2
        return 1
    fi
}

usage() {
    echo "Usage: ./win2go.sh [--iso PATH] [--drive DEVICE] [-v]"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while (($#)); do
    case "$1" in
        --iso|-i|--drive|-d)
            if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
                echo "ERROR: $1 requires a value" >&2
                exit 2
            fi
            case "$1" in
                --iso|-i) ISO_FILE=$2 ;;
                --drive|-d) DRIVE=$2 ;;
            esac
            shift 2
            ;;
        -v) set -x; shift ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "ERROR: Unsupported option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
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
    valid_selection "$iso_choice" "${#ISOS[@]}" || { echo "Invalid ISO selection" >&2; exit 1; }
    ISO_FILE="${ISOS[$((iso_choice-1))]}"
fi
[[ -f "$ISO_FILE" && -r "$ISO_FILE" ]] || { echo "ISO not found: $ISO_FILE" >&2; exit 1; }
ISO_FILE=$(readlink -f -- "$ISO_FILE")
echo -e "${GREEN}Selected ISO: $ISO_FILE${RESET}"

# =======================
# Step 2: USB Drive Selection
# =======================
clear_step "Step 2: Select USB drive"
if [[ -z "$DRIVE" ]]; then
    disks=$(lsblk -dnrpo NAME,TYPE,TRAN)
    mapfile -t DRIVES < <(awk '$2=="disk" && $3=="usb" {print $1}' <<< "$disks")
    [[ -n "${DRIVES[0]:-}" ]] || { echo "No USB disks found" >&2; exit 1; }
    for i in "${!DRIVES[@]}"; do
        printf '%d) %s - %s\n' "$((i+1))" "${DRIVES[$i]}" "$(lsblk -dn -o SIZE,MODEL "${DRIVES[$i]}")"
    done
    read -r -p "Select USB disk number: " choice
    valid_selection "$choice" "${#DRIVES[@]}" ||
        { echo "Invalid USB selection" >&2; exit 1; }
    DRIVE="${DRIVES[$((choice-1))]}"
fi
DRIVE=$(readlink -f -- "$DRIVE")
[[ -b "$DRIVE" ]] || { echo "ERROR: Target must be a whole USB disk" >&2; exit 1; }
DRIVE_ID=$(lsblk -dnro MAJ:MIN -- "$DRIVE")
[[ "$DRIVE_ID" =~ ^[0-9]+:[0-9]+$ ]] || exit 1
check_target
echo "Selected USB disk: $DRIVE"

SIZE_BYTES=$(lsblk -dnbo SIZE -- "$DRIVE")
if ((SIZE_BYTES > 64 * 1024 * 1024 * 1024)); then
    read -r -p "⚠️ WARNING: $DRIVE is larger than 64 GiB. Type YES to continue: " yn
    if [[ "$yn" != "YES" ]]; then echo "Canceled."; exit 1; fi
fi

for cmd in sudo parted partprobe sfdisk hexdump udevadm mkfs.vfat mkfs.ntfs ntfs-3g wimlib-imagex bcd-sys mount umount hivexsh hivexregedit readpe peres setfattr fatattr; do
    command -v "$cmd" >/dev/null || { echo "ERROR: Missing dependency: $cmd. Run: bash scripts/deps-ubuntu.sh --install" >&2; exit 1; }
done

MOUNT_ROOT=$(mktemp -d /tmp/win2go.XXXXXXXXXX)
ISO_MOUNT="$MOUNT_ROOT/iso"
WIN_MOUNT="$MOUNT_ROOT/win"
BOOT_MOUNT="$MOUNT_ROOT/boot"
mkdir -- "$ISO_MOUNT" "$WIN_MOUNT" "$BOOT_MOUNT"
mount_volume -o loop,ro -- "$ISO_FILE" "$ISO_MOUNT"
WIM=""
for name in install.wim install.esd; do
    if [[ -f "$ISO_MOUNT/sources/$name" ]]; then WIM="$ISO_MOUNT/sources/$name"; break; fi
done
[[ -n "$WIM" ]] || { echo "ERROR: ISO does not contain install.wim/install.esd" >&2; exit 1; }
image_info=$(wimlib-imagex info "$WIM")
grep -E '^(Index|Name):' <<< "$image_info"
read -r -p "Choose Windows edition index: " IMAGE_INDEX
[[ "$IMAGE_INDEX" =~ ^[1-9][0-9]*$ ]] &&
    wimlib-imagex info "$WIM" "$IMAGE_INDEX" >/dev/null ||
    { echo "ERROR: Invalid Windows image index" >&2; exit 1; }
read -r -p "⚠️ This will ERASE all data on $DRIVE. Continue? (yes/no): " yn
if [[ "$yn" != "yes" ]]; then echo "Canceled."; exit 1; fi

# =======================
# Step 3: Partitioning & Formatting
# =======================
clear_step "Step 3: Partitioning $DRIVE"
# UEFI only; a working Windows installation also requires a valid BCD store.
check_target
sudo parted "$DRIVE" --script mklabel gpt
sudo parted "$DRIVE" --script mkpart ESP fat32 1MiB 513MiB
sudo parted "$DRIVE" --script set 1 esp on
sudo parted "$DRIVE" --script mkpart Windows ntfs 513MiB 100%
sudo partprobe "$DRIVE"
sudo udevadm settle
if [[ "$DRIVE" =~ [0-9]$ ]]; then
    PART1="${DRIVE}p1"
    PART2="${DRIVE}p2"
else
    PART1="${DRIVE}1"
    PART2="${DRIVE}2"
fi
for partition in "$PART1" "$PART2"; do
    [[ -b "$partition" &&
        "$(lsblk -dnro TYPE,PKNAME -- "$partition")" == "part ${DRIVE##*/}" ]] ||
        { echo "ERROR: Expected partition missing on $DRIVE: $partition" >&2; exit 1; }
done
check_target
sudo mkfs.vfat -F32 "$PART1"
sudo mkfs.ntfs -f "$PART2"

clear_step "Step 4: Applying Windows image to NTFS"
# Direct NTFS application preserves NTFS metadata better than extracting to ext4.
sudo wimlib-imagex apply "$WIM" "$IMAGE_INDEX" "$PART2"

clear_step "Step 5: Creating UEFI boot files and BCD"
mount_volume -t ntfs-3g -- "$PART2" "$WIN_MOUNT"
mount_volume -- "$PART1" "$BOOT_MOUNT"
sudo test -f "$WIN_MOUNT/Windows/System32/winload.efi" || { echo "Windows loader missing" >&2; exit 1; }
# Explicit -s keeps the boot store on the removable drive; no host NVRAM update.
sudo bcd-sys "$WIN_MOUNT" -s "$BOOT_MOUNT" -f uefi
sudo test -s "$BOOT_MOUNT/EFI/Microsoft/Boot/BCD" || { echo "ERROR: BCD was not created" >&2; exit 1; }
sudo test -s "$BOOT_MOUNT/EFI/BOOT/BOOTX64.efi" || { echo "ERROR: UEFI fallback bootloader missing" >&2; exit 1; }

clear_step "Step 6: Finishing"
sync
trap - EXIT
cleanup
echo -e "${GREEN}Windows files and UEFI BCD written. Physical boot has NOT yet been tested.${RESET}"
