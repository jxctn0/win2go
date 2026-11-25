#!/usr/bin/env bash
# End-to-end lab stages. The regular-file stages never open block devices.
set -euo pipefail
export LC_ALL=C
umask 077
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/windows-media.sh"

die() { echo "ERROR: $*" >&2; exit 1; }

require() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null || die "Missing tool: $cmd"
    done
}

free_bytes() {
    df -B1 --output=avail -- "$1" | awk 'NR == 2 {print $1}'
}

regular() { [[ -f "$1" && ! -L "$1" ]]; }

inspect_iso() {
    require 7z wimlib-imagex sha256sum readpe
    local iso=$1 work=$2 listing member index
    regular "$iso" || die "Use the path of a regular ISO file"
    mkdir -- "$work"
    exec > >(tee "$work/inspect.log") 2>&1
    (( $(free_bytes "$work") > $(stat -c %s "$iso") + 1073741824 )) ||
        die "Insufficient space to extract the Windows archive"
    sha256sum -- "$iso" > "$work/iso.sha256"
    7z t "$iso" > "$work/iso-structure.log"
    listing=$(7z l -ba "$iso")
    for member in install.wim install.esd; do
        if grep -qiE "[[:space:]]sources/${member//./[.]}$" <<< "$listing"; then
            7z x -so "$iso" "sources/$member" > "$work/$member"
            break
        fi
    done
    regular "$work/$member" && [[ -s "$work/$member" ]] ||
        die "No install.wim or install.esd"
    7z x -so "$iso" efi/boot/bootx64.efi > "$work/iso-bootx64.efi"
    efi_application "$work/iso-bootx64.efi" || die "ISO fallback is not an x86-64 EFI application"
    readpe -h coff -h optional "$work/iso-bootx64.efi" > "$work/iso-bootx64.txt"
    wimlib-imagex info "$work/$member" | tee "$work/editions.log"
    while IFS= read -r index; do
        printf 'Index %s (x86-64)\n' "$index"
        wimlib-imagex dir "$work/$member" "$index" --path=/Windows/Boot/EFI/bootmgfw.efi
        wimlib-imagex dir "$work/$member" "$index" --path=/Windows/System32/winload.efi
    done < <(awk '/^Index:/ {index_number=$2} /^Architecture:[[:space:]]+x86_64$/ {print index_number}' "$work/editions.log") |
        tee "$work/edition-efi-paths.log"
    wimlib-imagex verify "$work/$member" > "$work/wim-verify.log" 2>&1
    touch -- "$work/inspect.ok"
    echo "PASS: ISO structure and Windows archive integrity"
}

pe_x64() {
    readpe -h coff "$1" | awk '/Machine:/ && /0x8664|AMD64/ {found=1} END {exit !found}'
}

efi_application() {
    pe_x64 "$1" && readpe -h optional "$1" |
        awk '/Subsystem required:/ && /IMAGE_SUBSYSTEM_EFI_APPLICATION/ {found=1} END {exit !found}'
}

# Derive offsets from the verified GPT, never from a caller-supplied filename.
read_layout() {
    local layout=$1 start sectors esp_start esp_sectors
    grep -qx 'label: gpt' <<< "$layout" && grep -qx 'sector-size: 512' <<< "$layout" ||
        die "Expected 512-byte GPT sectors"
    read -r esp_start esp_sectors < <(
        awk -F '[=,]' 'toupper($0) ~ /C12A7328-F81F-11D2-BA4B-00A0C93EC93B/ {print $2+0, $4+0}' <<< "$layout")
    read -r start sectors < <(
        awk -F '[=,]' 'toupper($0) ~ /EBD0A0A2-B9E5-4433-87C0-68B6B72699C7/ {print $2+0, $4+0}' <<< "$layout")
    [[ "$esp_start $esp_sectors $start" == '2048 1048576 1050624' && "$sectors" =~ ^[0-9]+$ ]] ||
        die "Unexpected GPT geometry"
    [[ "$(awk '/ : start=/{n++} END{print n}' <<< "$layout")" == 2 ]] || die "Unexpected GPT entries"
    printf '%s %s %s %s\n' "$esp_start" "$esp_sectors" "$start" "$sectors"
}

prepare_raw() {
    require parted sfdisk mkfs.vfat mkfs.ntfs blkid wimlib-imagex ntfscat readpe hivexsh dd
    local work=$1 index=$2 archive="$1/install.wim" build disk esp ntfs info bytes needed
    local layout geometry start sectors esp_start esp_sectors
    [[ -f "$work/inspect.ok" ]] || die "Complete inspect first"
    [[ "$index" =~ ^[1-9][0-9]{0,8}$ ]] || die "Invalid image index"
    regular "$archive" || archive="$work/install.esd"
    regular "$archive" || die "Missing Windows archive"
    mkdir -- "$work/raw-build"
    build="$work/raw-build"
    exec > >(tee "$build/build.log") 2>&1
    info=$(wimlib-imagex info "$archive" "$index")
    printf '%s\n' "$info"
    windows_image_is_x64 "$info" || die "Selected image is not x86_64"
    bytes=$(awk '/^Total Bytes:/ {print $3}' <<< "$info")
    [[ "$bytes" =~ ^[0-9]{1,11}$ ]] || die "Cannot estimate selected image size"
    # Allow for the source partition file and its copy, metadata and free space.
    needed=$((bytes * 2 + 4 * 1024**3))
    printf 'Host available bytes: %s; estimated peak additional bytes: %s\n' "$(free_bytes "$work")" "$needed"
    (( $(free_bytes "$work") >= needed && bytes + 2 * 1024**3 < 31 * 1024**3 )) ||
        die "Insufficient host free space or image exceeds the 32 GiB lab profile"

    disk="$build/windows-togo.raw"
    esp="$build/esp.fat"
    ntfs="$build/windows.ntfs"
    truncate -s 32G "$disk"
    windows_gpt_args "$disk"
    parted "${PARTED_ARGS[@]}"
    sfdisk --verify "$disk"
    layout=$(sfdisk --dump "$disk")
    printf '%s\n' "$layout" | tee "$build/gpt.txt"
    geometry=$(read_layout "$layout")
    read -r esp_start esp_sectors start sectors <<< "$geometry"

    truncate -s "$((esp_sectors * 512))" "$esp"
    truncate -s "$((sectors * 512))" "$ntfs"
    mkfs.vfat -F32 -h "$esp_start" "$esp"
    mkfs.ntfs -F -f -s 512 -p "$start" -H 255 -S 63 "$ntfs"
    apply_windows_image "$archive" "$index" "$ntfs"
    touch -- "$build/applied.ok"
    assemble_raw "$build"
}

assemble_raw() {
    require sfdisk blkid fsck.fat ntfsinfo ntfscat readpe hivexsh dd
    local build=$1 disk="$1/windows-togo.raw" esp="$1/esp.fat" ntfs="$1/windows.ntfs"
    local layout geometry start sectors esp_start esp_sectors payload
    regular "$build/applied.ok" && [[ ! -e "$build/raw.ok" ]] ||
        die "Missing applied NTFS volume or RAW assembly already complete"
    regular "$disk" && regular "$esp" && regular "$ntfs" ||
        die "Missing regular GPT or partition images"
    sfdisk --verify "$disk"
    layout=$(sfdisk --dump "$disk")
    geometry=$(read_layout "$layout")
    read -r esp_start esp_sectors start sectors <<< "$geometry"
    [[ "$(stat -c %s "$esp")" == "$((esp_sectors * 512))" &&
       "$(stat -c %s "$ntfs")" == "$((sectors * 512))" ]] ||
        die "Partition file length differs from GPT"
    fsck.fat -n "$esp" | tee "$build/fat-check.log"
    ntfsinfo -m "$ntfs" > "$build/ntfs-info.log"
    for payload in Windows/System32/winload.efi Windows/Boot/EFI/bootmgfw.efi Windows/System32/ntoskrnl.exe; do
        ntfscat "$ntfs" "/$payload" > "$build/${payload##*/}"
        pe_x64 "$build/${payload##*/}" || die "Invalid x64 PE file: $payload"
        readpe -h coff -h optional "$build/${payload##*/}" > "$build/${payload##*/}.txt"
        sha256sum -- "$build/${payload##*/}"
    done
    grep -q IMAGE_SUBSYSTEM_WINDOWS_BOOT_APPLICATION "$build/winload.efi.txt" ||
        die "Unexpected subsystem in winload.efi"
    efi_application "$build/bootmgfw.efi" || die "Windows Boot Manager is not an x86-64 EFI application"
    ntfscat "$ntfs" /Windows/System32/config/SYSTEM > "$build/SYSTEM"
    printf '%s\n' 'cd Select' 'lsval' | HOME="$build" hivexsh "$build/SYSTEM" > "$build/system-hive.txt"
    [[ -s "$build/system-hive.txt" ]] || die "Cannot read the Windows SYSTEM hive"

    dd if="$esp" of="$disk" bs=1M seek="$((esp_start / 2048))" conv=sparse,notrunc status=none
    dd if="$ntfs" of="$disk" bs=1M seek="$((start / 2048))" conv=sparse,notrunc status=progress
    sfdisk --verify "$disk"
    [[ "$(blkid -p -O "$((esp_start * 512))" -S "$((esp_sectors * 512))" -s VERSION -o value "$disk")" == FAT32 ]]
    [[ "$(blkid -p -O "$((start * 512))" -S "$((sectors * 512))" -s TYPE -o value "$disk")" == ntfs ]]
    # Compare the inserted volumes byte-for-byte with the checked ones.
    cmp -n "$((esp_sectors * 512))" -i "0:$((esp_start * 512))" -- "$esp" "$disk"
    cmp -n "$((sectors * 512))" -i "0:$((start * 512))" -- "$ntfs" "$disk"
    rm -- "$esp" "$ntfs"
    du -h -- "$disk"
    touch -- "$build/raw.ok"
    echo "PASS: GPT, FAT32, and applied Windows x86-64 in $disk"
    echo "PENDING: BCD-SYS and UEFI boot"
}

same_loop() {
    [[ "$loop" =~ ^/dev/loop[0-9]+$ && -b "$loop" &&
       "$(losetup -lnr -O BACK-MAJ:MIN,BACK-INO -- "$loop")" == "$backing" ]]
}

cleanup_loop() {
    local path failed=0 status
    for path in "$mounts/esp" "$mounts/windows"; do
        status=0
        mountpoint -q -- "$path" || status=$?
        case "$status" in
            0) umount -- "$path" || failed=1 ;;
            32) ;;
            *) failed=1 ;;
        esac
    done
    if [[ -n "$loop" ]]; then
        if ((failed)) || ! same_loop || ! losetup --detach "$loop"; then
            echo "ERROR: Check remaining loop or mounts at $loop and $mounts" >&2
            return 1
        fi
    fi
    rmdir -- "$mounts/esp" "$mounts/windows" "$mounts"
}

bcd_value() {
    printf 'cd %s\nlsval%s\n' "$2" "${3:+ Element}" | hivexsh "$1"
}

verify_bcd_entry() {
    local bcd=$1 manager='Objects\{9dea862c-5cdd-4e70-acc1-f32b344d4795}\Elements'
    local default_id order loader_root loader device
    default_id=$(bcd_value "$bcd" "$manager\23000003" element)
    [[ "$default_id" =~ ^\{[[:xdigit:]-]{36}\}$ ]] || die "BCD has no default Windows loader"
    order=$(bcd_value "$bcd" "$manager\24000001" element)
    grep -Fixq -- "$default_id" <<< "$order" || die "BCD boot order omits the default Windows loader"
    loader_root="Objects\\$default_id\\Elements"
    loader=$(bcd_value "$bcd" "$loader_root\12000002" element)
    [[ "${loader,,}" == '\windows\system32\winload.efi' ]] || die "BCD default loader path is invalid"
    device=$(bcd_value "$bcd" "$loader_root\11000001")
    [[ "$device" == '"Element"=hex(3):'?* ]] || die "BCD default loader has no device descriptor"
    printf 'BCD default loader %s: %s\nBoot order: %s\nLoader device: %s\n' \
        "$default_id" "$loader" "$order" "$device"
}

install_bcd() {
    local build="$1/raw-build" disk owner path source mounted attempt cleanup_status=0
    local loop="" mounts="" backing=""
    [[ "${2:-}" == --allow-loop-writes && $EUID == 0 && "${SUDO_UID:-}" =~ ^[0-9]+$ ]] ||
        die "BCD requires explicit loop-write approval and a private sudo mount namespace"
    require losetup lsblk findmnt bcd-sys mount umount mountpoint readpe hivexsh blkid ntfs-3g flock
    [[ "$(readlink /proc/self/ns/mnt)" != "$(readlink /proc/1/ns/mnt)" &&
       "$(findmnt -nro PROPAGATION --mountpoint /)" == private ]] ||
        die "Run this stage using unshare --mount --propagation private"
    disk="$build/windows-togo.raw"
    regular "$disk" && regular "$build/raw.ok" || die "Prepare the RAW image first"
    local image_fd
    exec {image_fd}<>"$disk"
    flock -n "$image_fd" || die "Image is already in use"
    path="/proc/$$/fd/$image_fd"
    owner=$(stat -Lc '%u:%h:%a:%F' -- "$path")
    [[ "$owner" == "$SUDO_UID:1:600:regular file" ]] || die "Unexpected image owner, mode or type"
    backing=$(stat -Lc '%Hd:%Ld %i' -- "$path")
    [[ -c /dev/loop-control ]] || die "No loop control device in this environment"
    [[ -z "$(losetup -j "$path")" ]] || die "Image already has a loop mapping"
    mounts=$(mktemp -d /run/win2go-lab.XXXXXXXX)
    mkdir -- "$mounts/windows" "$mounts/esp"
    trap 'cleanup_loop || exit 1' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    loop=$(losetup --find --show --partscan -- "$path")
    same_loop || die "Loop backing identity changed"
    printf 'Loop %s is backed by %s (device and inode %s)\n' "$loop" "$disk" "$backing"
    for attempt in {1..20}; do
        [[ -b "${loop}p1" && -b "${loop}p2" ]] && break
        sleep 0.25
    done
    [[ "$(lsblk -nro TYPE -- "$loop")" == $'loop\npart\npart' &&
       "$(lsblk -dnro PKNAME -- "${loop}p1")" == "${loop##*/}" &&
       "$(lsblk -dnro PKNAME -- "${loop}p2")" == "${loop##*/}" ]] ||
        die "Unexpected loop partition nodes"
    [[ -z "$(lsblk -nro MOUNTPOINTS -- "$loop" | tr -d '\n')" ]] ||
        die "Unexpected existing mounts on loop"
    [[ "$(blkid -p -s VERSION -o value "${loop}p1")" == FAT32 &&
       "$(blkid -p -s TYPE -o value "${loop}p2")" == ntfs ]] ||
        die "Unexpected loop filesystems"
    # The installed BCD-SYS uses fixed names under /tmp.
    mount -t tmpfs -o size=64m,mode=1777,nodev,nosuid,noexec tmpfs /tmp
    export HOME=/tmp
    mount -t ntfs-3g -o ro,nosuid,nodev,noexec -- "${loop}p2" "$mounts/windows"
    same_loop || die "Loop backing identity changed before mounting EFI"
    mount -t vfat -o nosuid,nodev,noexec -- "${loop}p1" "$mounts/esp"
    for mounted in esp windows; do
        source=$(findmnt -nro SOURCE --mountpoint "$mounts/$mounted")
        if [[ "$mounted" == esp ]]; then
            [[ "$source" == "${loop}p1" ]] || die "Unexpected EFI mount"
        else
            [[ "$source" == "${loop}p2" ]] || die "Unexpected Windows mount"
        fi
    done
    same_loop || die "Loop backing identity changed before BCD-SYS"
    bcd-sys "$mounts/windows" -s "$mounts/esp" -f uefi
    validate_windows_boot "$mounts/esp"
    verify_bcd_entry "$mounts/esp/EFI/Microsoft/Boot/BCD"
    for path in "Microsoft/Boot/bootmgfw.efi" BOOT/BOOTX64.efi; do
        efi_application "$mounts/esp/EFI/$path" || die "Invalid x64 EFI application: $path"
        sha256sum -- "$mounts/esp/EFI/$path"
    done
    cmp -- "$mounts/esp/EFI/Microsoft/Boot/bootmgfw.efi" "$mounts/esp/EFI/BOOT/BOOTX64.efi"
    sha256sum -- "$mounts/esp/EFI/Microsoft/Boot/BCD"
    sync -f -- "$mounts/esp"
    cleanup_loop || cleanup_status=$?
    trap - EXIT
    ((cleanup_status == 0)) || return "$cleanup_status"
    echo 'PASS: BCD-SYS created a readable BCD and x64 boot files'
}

boot_raw() {
    require qemu-system-x86_64
    local work=$1 code=$2 vars=$3 disk="$1/raw-build/windows-togo.raw" evidence
    regular "$code" && regular "$vars" && regular "$disk" || die "Supply regular RAW and matching OVMF files"
    [[ -f "$work/bcd.log" ]] &&
        grep -Fxq 'PASS: BCD-SYS created a readable BCD and x64 boot files' "$work/bcd.log" ||
        die "A successful BCD stage is required (save stdout to bcd.log)"
    [[ "$code$disk" != *,* ]] || die "QEMU paths cannot contain commas"
    (( $(free_bytes "$work") >= 4 * 1024**3 )) || die "Insufficient space for guest snapshot"
    evidence=$(mktemp -d -- "$work/qemu.XXXXXXXX")
    cp -- "$vars" "$evidence/OVMF_VARS.fd"
    code=$(realpath -- "$code")
    disk=$(realpath -- "$disk")
    echo "Evidence directory: $evidence"
    cd -- "$evidence"
    TMPDIR="$PWD" qemu-system-x86_64 -machine q35,accel=tcg -cpu max -smp 2 -m 2048 \
        -nic none -display none -monitor stdio -vga std -serial file:serial.log \
        -drive "if=pflash,format=raw,readonly=on,file=$code" \
        -drive if=pflash,format=raw,file=OVMF_VARS.fd \
        -device qemu-xhci,id=usb \
        -drive "if=none,id=wintogo,format=raw,snapshot=on,file=$disk" \
        -device usb-storage,bus=usb.0,drive=wintogo,bootindex=1 2>&1 | tee qemu.log
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        inspect) [[ $# == 3 ]] || die "Usage: $0 inspect ISO NEW_WORK_DIR"; inspect_iso "$2" "$3" ;;
        prepare) [[ $# == 3 ]] || die "Usage: $0 prepare WORK_DIR INDEX"; prepare_raw "$2" "$3" ;;
        assemble) [[ $# == 2 ]] || die "Usage: $0 assemble WORK_DIR"
            assemble_raw "$2/raw-build" 2>&1 | tee "$2/raw-build/assemble.log" ;;
        bcd) [[ $# == 3 ]] || die "Usage: $0 bcd WORK_DIR --allow-loop-writes"; install_bcd "$2" "$3" ;;
        boot) [[ $# == 4 ]] || die "Usage: $0 boot WORK_DIR OVMF_CODE OVMF_VARS"; boot_raw "$2" "$3" "$4" ;;
        *) die "Usage: $0 {inspect|prepare|assemble|bcd|boot} ..." ;;
    esac
fi
