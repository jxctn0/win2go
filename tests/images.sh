#!/usr/bin/env bash
# Exercise the real partitioning, filesystem and WIM tools on regular files.
set -euo pipefail
export LC_ALL=C
for cmd in parted sfdisk mkfs.vfat mkfs.ntfs blkid wimlib-imagex ntfscat; do
    command -v "$cmd" >/dev/null || { echo "Missing image test dependency: $cmd" >&2; exit 1; }
done

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
disk="$work/disk.img"
fat="$work/esp.img"
ntfs="$work/windows.img"

truncate -s 768M "$disk"
parted --script "$disk" mklabel gpt mkpart ESP fat32 1MiB 513MiB set 1 esp on \
    mkpart Windows ntfs 513MiB 100%
sfdisk --verify "$disk"
table=$(sfdisk --dump "$disk")
grep -qx 'label: gpt' <<< "$table"
grep -qE 'start= *2048, size= *1048576, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B,.*name="ESP"$' <<< "$table"
grep -qE 'start= *1050624, size= *[0-9]+, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7,.*name="Windows"$' <<< "$table"
[[ "$(awk '/ : start=/{n++} END{print n}' <<< "$table")" == 2 ]]
echo 'PASS: GPT and both partition types, offsets and ESP size'

truncate -s 512M "$fat"
mkfs.vfat -F32 "$fat"
[[ "$(blkid -p -s TYPE -o value "$fat")" == vfat ]]
[[ "$(blkid -p -s VERSION -o value "$fat")" == FAT32 ]]
echo 'PASS: FAT32 filesystem'

mkdir -p "$work/input/Windows/System32"
printf '%s\n' 'Synthetic Windows file' > "$work/input/Windows/System32/winload.efi"
wimlib-imagex capture "$work/input" "$work/install.wim" Fixture
wimlib-imagex export "$work/install.wim" 1 "$work/install.esd" --solid
for image in install.wim install.esd; do
    # The extra force flag permits a regular file. No block device is opened.
    truncate -s 0 "$ntfs"
    truncate -s 96M "$ntfs"
    mkfs.ntfs -F -f -s 512 -p 1050624 -H 255 -S 63 "$ntfs"
    [[ "$(blkid -p -s TYPE -o value "$ntfs")" == ntfs ]]
    wimlib-imagex apply "$work/$image" 1 "$ntfs"
    ntfscat "$ntfs" /Windows/System32/winload.efi | cmp - "$work/input/Windows/System32/winload.efi"
    echo "PASS: $image applied directly to an NTFS image"
done
