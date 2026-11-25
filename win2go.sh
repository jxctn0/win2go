#!/bin/bash
set -eo pipefail
shopt -s nullglob
export LC_ALL=C
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/windows-media.sh"

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
MOUNT_ATTEMPTS=()
DRY_RUN=0
ESP_GUID=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
DATA_GUID=ebd0a0a2-b9e5-4433-87c0-68b6b72699c7

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

clear_step() {
    printf '%b=== %s ===%b\n' "$CYAN" "$1" "$RESET"
}

cleanup() {
    local status=$1 i mount_status failed=0
    for ((i = ${#MOUNT_ATTEMPTS[@]} - 1; i >= 0; i--)); do
        local path=${MOUNT_ATTEMPTS[i]}
        mount_status=0
        mountpoint -q -- "$path" || mount_status=$?
        if ((mount_status == 32)); then
            continue
        fi
        if ((mount_status != 0)) || ! sudo umount -- "$path"; then
            echo "ERROR: Could not verify or unmount $path" >&2
            failed=1
        fi
    done
    if [[ -n "$MOUNT_ROOT" ]] && ((failed == 0)); then
        rmdir -- "$MOUNT_ROOT/iso" "$MOUNT_ROOT/win" "$MOUNT_ROOT/boot" 2>/dev/null || true
        if ! rmdir -- "$MOUNT_ROOT"; then failed=1; fi
    fi
    if ((failed)); then
        echo "ERROR: Cleanup incomplete. Inspect $MOUNT_ROOT before retrying." >&2
        ((status != 0)) || status=1
    fi
    return "$status"
}

mount_volume() {
    # Record the attempt before mount, including partial success or a signal.
    MOUNT_ATTEMPTS+=("${!#}")
    sudo mount "$@"
}

valid_selection() {
    local selection=$1 maximum=$2
    [[ "$selection" =~ ^[1-9][0-9]*$ ]] &&
        (( ${#selection} <= ${#maximum} && selection <= maximum ))
}

# Follow filesystem devices through partition parents, stacked devices and loops.
# Filesystems that can span devices without exposing every member here are rejected.
path_disks() {
    local path=$1 depth=$2 expected_id=${3:-} mount_data filesystem id
    ((depth < 32)) || return 1
    mount_data=$(findmnt -nro FSTYPE,MAJ:MIN --target "$path") || return 1
    [[ "$mount_data" != *$'\n'* ]] || return 1
    read -r filesystem id <<< "$mount_data"
    [[ "$(stat -Lc '%Hd:%Ld' -- "$path")" == "$id" &&
       ( -z "$expected_id" || "$id" == "$expected_id" ) ]] || return 1
    case "$filesystem" in
        ext2|ext3|ext4|vfat|exfat|ntfs|ntfs3|iso9660|udf) ;;
        *) return 1 ;;
    esac
    block_disks "$id" "$((depth + 1))"
}

block_disks() {
    local id=$1 depth=$2 node backing backing_id slave parent
    local -a slaves
    [[ "$id" =~ ^[0-9]+:[0-9]+$ ]] && ((depth < 32)) || return 1
    node=$(readlink -e -- "/sys/dev/block/$id") || return 1
    if [[ -f "$node/partition" ]]; then
        parent=$(cat -- "${node%/*}/dev") || return 1
        block_disks "$parent" "$((depth + 1))"
    elif [[ -f "$node/loop/backing_file" ]]; then
        backing=$(cat -- "$node/loop/backing_file") || return 1
        [[ "$backing" == /* && -f "$backing" ]] || return 1
        # Reject an overmounted path or other pathname substitution.
        backing_id=$(losetup --list --noheadings --raw -O BACK-MAJ:MIN -- "/dev/${node##*/}") || return 1
        [[ "$backing_id" =~ ^[0-9]+:[0-9]+$ ]] || return 1
        path_disks "$backing" "$((depth + 1))" "$backing_id"
    elif [[ -d "$node/slaves" ]]; then
        slaves=("$node"/slaves/*)
        if ((${#slaves[@]})); then
            for slave in "${slaves[@]}"; do
                parent=$(cat -- "$slave/dev") || return 1
                block_disks "$parent" "$((depth + 1))" || return 1
            done
        elif [[ -e "$node/device" ]]; then
            printf '%s\n' "$id"
        else
            return 1
        fi
    else
        return 1
    fi
}

protect_path() {
    local path=$1 description=$2 disks
    disks=$(path_disks "$path" 0 "${3:-}") && [[ -n "$disks" ]] ||
        fail "Cannot identify physical backing for $description: $path"
    if [[ $'\n'"$disks"$'\n' == *$'\n'"$DRIVE_ID"$'\n'* ]]; then
        fail "Target USB contains $description: $path"
    fi
}

disk_identity() {
    local node sequence=""
    test -b "$DRIVE" && [[ "$(readlink -e -- "$DRIVE")" == "$DRIVE" &&
                           "$(stat -Lc '%Hr:%Lr' -- "$DRIVE")" == "$DRIVE_ID" ]] || return 1
    node=$(readlink -e -- "/sys/dev/block/$DRIVE_ID") || return 1
    if [[ -e "$node/diskseq" ]]; then
        sequence=$(cat -- "$node/diskseq") || return 1
        [[ "$sequence" =~ ^[0-9]+$ ]] || return 1
    fi
    printf '%s\n' "$node" "$sequence"
    lsblk -dnbro TYPE,TRAN,MAJ:MIN,SIZE,RO,MODEL,SERIAL -- "$DRIVE"
}

check_target() {
    local properties types mountpoints path
    properties=$(disk_identity) && [[ "$properties" == "$DRIVE_IDENTITY" ]] ||
        fail "Target USB disk changed or is unavailable: $DRIVE"
    types=$(lsblk -nro TYPE -- "$DRIVE") || fail "Cannot inspect target volumes"
    mountpoints=$(lsblk -nro MOUNTPOINTS -- "$DRIVE") || fail "Cannot inspect target mounts"
    if [[ -z "$types" ]] || grep -qvxE 'disk|part' <<< "$types"; then
        fail "Target USB has active volumes"
    fi
    while IFS= read -r path; do
        [[ -z "$path" || "$path" == "${1:-}" || "$path" == "${2:-}" ]] ||
            fail "Target USB has mounted filesystems or active swap: $path"
    done <<< "$mountpoints"
    [[ "$(stat -Lc '%d:%i:%s:%y:%z' -- "$ISO_FILE")" == "$ISO_IDENTITY" ]] ||
        fail "Source ISO changed or is unavailable: $ISO_FILE"
    protect_path "$ISO_FILE" "the source ISO" "$ISO_DEVICE"
    protect_path / "the host root filesystem"
    for path in /boot /boot/efi; do
        [[ ! -d "$path" ]] || protect_path "$path" "host boot files"
    done
}

partition_identity() {
    local path=$1 number=$2 guid=$3 properties type id actual_guid uuid node
    test -b "$path" && [[ "$(readlink -e -- "$path")" == "$path" ]] || return 1
    properties=$(lsblk -dnro TYPE,MAJ:MIN,PARTTYPE,PARTUUID -- "$path") || return 1
    read -r type id actual_guid uuid <<< "$properties"
    [[ "$type" == part && "$id" =~ ^[0-9]+:[0-9]+$ &&
       "${actual_guid,,}" == "$guid" && "$uuid" =~ ^[[:xdigit:]-]{36}$ &&
       "$(stat -Lc '%Hr:%Lr' -- "$path")" == "$id" ]] || return 1
    node=$(readlink -e -- "/sys/dev/block/$id") || return 1
    [[ "${node%/*}" == "${DRIVE_IDENTITY%%$'\n'*}" &&
       "$(cat -- "$node/partition")" == "$number" ]] || return 1
    printf '%s\n' "$properties"
    cat -- "$node/start" "$node/size"
}

check_partitions() {
    local esp windows
    esp=$(partition_identity "$PART1" 1 "$ESP_GUID") &&
        windows=$(partition_identity "$PART2" 2 "$DATA_GUID") &&
        [[ "$esp" == "$ESP_IDENTITY" && "$windows" == "$WINDOWS_IDENTITY" ]] ||
        fail "Target partitions changed or are unavailable"
}

check_mount() {
    local path=$1 partition=$2 source
    source=$(findmnt -nro SOURCE --mountpoint "$path") &&
        [[ "$(readlink -e -- "$source")" == "$partition" ]] ||
        fail "Unexpected filesystem mounted at $path"
}

usage() {
    echo "Usage: ./win2go.sh [--iso PATH] [--drive DEVICE] [--dry-run] [-v]"
}

trap 'cleanup "$?" || exit "$?"' EXIT
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
        --dry-run) DRY_RUN=1; shift ;;
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
ISO_FILE=$(readlink -e -- "$ISO_FILE")
# Keep the inspected inode open so mount cannot follow a substituted pathname.
exec {ISO_FD}<"$ISO_FILE"
ISO_HANDLE="/proc/$$/fd/$ISO_FD"
ISO_DEVICE=$(stat -Lc '%Hd:%Ld' -- "$ISO_HANDLE")
ISO_IDENTITY=$(stat -Lc '%d:%i:%s:%y:%z' -- "$ISO_HANDLE")
printf '%bSelected ISO: %s%b\n' "$GREEN" "$ISO_FILE" "$RESET"

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
DRIVE=$(readlink -e -- "$DRIVE") || fail "Target must be a whole USB disk"
test -b "$DRIVE" || fail "Target must be a whole USB disk"
properties=$(lsblk -dnbro TYPE,TRAN,MAJ:MIN,SIZE,RO -- "$DRIVE")
read -r type transport DRIVE_ID SIZE_BYTES readonly_flag <<< "$properties"
[[ "$type" == disk && "$transport" == usb && "$DRIVE_ID" =~ ^[0-9]+:[0-9]+$ &&
   "$SIZE_BYTES" =~ ^[0-9]{1,18}$ && "$readonly_flag" == 0 ]] ||
    fail "Target must be a writable whole USB disk"
DRIVE_IDENTITY=$(disk_identity) || fail "Cannot identify target USB disk"
read -r current_type current_transport current_id current_size current_ro _ <<< "${DRIVE_IDENTITY##*$'\n'}"
[[ "$current_type $current_transport $current_id $current_size $current_ro" == "$properties" ]] ||
    fail "Target USB disk changed during selection"

partition_prefix=$DRIVE
[[ "$DRIVE" != *[0-9] ]] || partition_prefix+=p
PART1="${partition_prefix}1"
PART2="${partition_prefix}2"
windows_gpt_args "$DRIVE"

check_target
printf 'Selected USB disk: %s (%s bytes, %s)\n' "$DRIVE" "$SIZE_BYTES" "$DRIVE_ID"
lsblk -dn -o MODEL,SERIAL -- "$DRIVE"

if ((DRY_RUN)); then
    echo "Dry run. Planned operations after validation and confirmation:"
    printf '  Mount ISO read-only and select an edition from install.wim or install.esd: %q\n' "$ISO_FILE"
    printf '  parted'; printf ' %q' "${PARTED_ARGS[@]}"; printf '\n'
    printf '  partprobe %q; udevadm settle\n' "$DRIVE"
    printf '  mkfs.vfat -F32 %q; mkfs.ntfs -f %q\n' "$PART1" "$PART2"
    printf '  wimlib-imagex apply <image> <index> %q\n' "$PART2"
    printf '  Mount %q and %q; run bcd-sys <Windows mount> -s <EFI mount> -f uefi\n' "$PART2" "$PART1"
    echo "  Verify the BCD and UEFI fallback loader, sync, and unmount."
    exit 0
fi

if ((SIZE_BYTES > 64 * 1024 * 1024 * 1024)); then
    read -r -p "⚠️ WARNING: $DRIVE is larger than 64 GiB. Type YES to continue: " yn
    if [[ "$yn" != "YES" ]]; then echo "Canceled."; exit 1; fi
fi

for cmd in sudo findmnt losetup stat parted partprobe sfdisk hexdump udevadm mkfs.vfat mkfs.ntfs ntfs-3g wimlib-imagex bcd-sys mount umount mountpoint hivexsh hivexregedit readpe peres setfattr fatattr; do
    command -v "$cmd" >/dev/null || { echo "ERROR: Missing dependency: $cmd. Run: bash scripts/deps-ubuntu.sh --install" >&2; exit 1; }
done

sudo -v || fail "Cannot obtain mount and disk permissions"
check_target
MOUNT_ROOT=$(mktemp -d /tmp/win2go.XXXXXXXXXX)
ISO_MOUNT="$MOUNT_ROOT/iso"
WIN_MOUNT="$MOUNT_ROOT/win"
BOOT_MOUNT="$MOUNT_ROOT/boot"
mkdir -- "$ISO_MOUNT" "$WIN_MOUNT" "$BOOT_MOUNT"
mount_volume -c -o loop,ro,nosuid,nodev,noexec -- "$ISO_HANDLE" "$ISO_MOUNT"
WIM=""
for name in install.wim install.esd; do
    if [[ -f "$ISO_MOUNT/sources/$name" ]]; then WIM="$ISO_MOUNT/sources/$name"; break; fi
done
[[ -n "$WIM" ]] || { echo "ERROR: ISO does not contain install.wim/install.esd" >&2; exit 1; }
image_info=$(wimlib-imagex info "$WIM")
grep -E '^(Index|Name):' <<< "$image_info"
read -r -p "Choose Windows edition index: " IMAGE_INDEX || fail "No Windows image index supplied"
[[ "$IMAGE_INDEX" =~ ^[1-9][0-9]*$ ]] &&
    edition_info=$(wimlib-imagex info "$WIM" "$IMAGE_INDEX") ||
    fail "Invalid Windows image index"
windows_image_is_x64 "$edition_info" ||
    fail "The selected edition must be a Windows x86_64 image for UEFI boot"
read -r -p "⚠️ This will ERASE all data on $DRIVE. Continue? (yes/no): " yn
if [[ "$yn" != "yes" ]]; then echo "Canceled."; exit 1; fi

# =======================
# Step 3: Partitioning & Formatting
# =======================
clear_step "Step 3: Partitioning $DRIVE"
check_target
sudo parted "${PARTED_ARGS[@]}"
check_target
sudo partprobe "$DRIVE"
sudo udevadm settle
[[ "$(lsblk -dnro PTTYPE -- "$DRIVE")" == gpt &&
   "$(lsblk -nro TYPE -- "$DRIVE")" == $'disk\npart\npart' ]] ||
    fail "Expected GPT with two partitions on $DRIVE"
ESP_IDENTITY=$(partition_identity "$PART1" 1 "$ESP_GUID") ||
    fail "Expected EFI system partition on $DRIVE"
WINDOWS_IDENTITY=$(partition_identity "$PART2" 2 "$DATA_GUID") ||
    fail "Expected Windows data partition on $DRIVE"
check_target
check_partitions
sudo mkfs.vfat -F32 "$PART1"
check_target
check_partitions
sudo mkfs.ntfs -f "$PART2"
sudo udevadm settle

clear_step "Step 4: Applying Windows image to NTFS"
# Direct NTFS application preserves NTFS metadata better than extracting to ext4.
check_target
check_partitions
apply_windows_image "$WIM" "$IMAGE_INDEX" "$PART2" sudo

clear_step "Step 5: Creating UEFI boot files and BCD"
check_target
check_partitions
mount_volume -t ntfs-3g -o nosuid,nodev,noexec -- "$PART2" "$WIN_MOUNT"
check_target "$WIN_MOUNT"
check_partitions
check_mount "$WIN_MOUNT" "$PART2"
mount_volume -t vfat -o nosuid,nodev,noexec -- "$PART1" "$BOOT_MOUNT"
check_target "$WIN_MOUNT" "$BOOT_MOUNT"
check_partitions
check_mount "$WIN_MOUNT" "$PART2"
check_mount "$BOOT_MOUNT" "$PART1"
sudo test -f "$WIN_MOUNT/Windows/System32/winload.efi" || { echo "Windows loader missing" >&2; exit 1; }
# Explicit -s keeps the boot store on the removable drive; no host NVRAM update.
sudo bcd-sys "$WIN_MOUNT" -s "$BOOT_MOUNT" -f uefi
validate_windows_boot "$BOOT_MOUNT" sudo

clear_step "Step 6: Finishing"
sudo sync -f -- "$WIN_MOUNT" "$BOOT_MOUNT"
cleanup_status=0
cleanup 0 || cleanup_status=$?
trap - EXIT
((cleanup_status == 0)) || exit "$cleanup_status"
echo -e "${GREEN}Windows files and UEFI BCD written. Physical boot has NOT yet been tested.${RESET}"
