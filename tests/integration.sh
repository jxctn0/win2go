#!/usr/bin/env bash
# Run the production CLI with synthetic sysfs and fail-closed command mocks.
set -euo pipefail
cd "$(dirname "$0")/.."

fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
export fixture
export target=/dev/win2go-test9
export iso="$fixture/Windows test.iso"
export backing="$fixture/backing image"
export nodes="$fixture/sys"
export mount_root="$fixture/mounts"
export calls="$fixture/calls"
export esp_guid=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
export data_guid=ebd0a0a2-b9e5-4433-87c0-68b6b72699c7
export esp_uuid=11111111-1111-1111-1111-111111111111
export data_uuid=22222222-2222-2222-2222-222222222222

mkdir -p "$nodes"/{target/part1,target/part2,target/slaves,target/device,source/part1,source/slaves,source/device,loop0/loop,mapped/slaves}
ln -s "$nodes/source/part1" "$nodes/mapped/slaves/sourcepart"
printf '%s\n' 240:0 > "$nodes/target/dev"
printf '%s\n' 241:0 > "$nodes/source/dev"
printf '%s\n' 241:1 > "$nodes/source/part1/dev"
printf '%s\n' 240:1 > "$nodes/target/part1/dev"
printf '%s\n' 1 > "$nodes/source/part1/partition"
printf '%s\n' 1 > "$nodes/target/part1/partition"
printf '%s\n' 2 > "$nodes/target/part2/partition"
printf '%s\n' 2048 > "$nodes/target/part1/start"
printf '%s\n' 1050624 > "$nodes/target/part2/start"
printf '%s\n' 1048576 > "$nodes/target/part1/size"
printf '%s\n' 100000000 > "$nodes/target/part2/size"
printf '%s\n' "$backing" > "$nodes/loop0/loop/backing_file"
touch -- "$iso" "$backing"

# Commands that are only checked for availability. Privileged execution is
# handled by the sudo mock below and can never reach real programs.
mkdir "$fixture/bin"
for cmd in parted partprobe sfdisk hexdump udevadm mkfs.vfat mkfs.ntfs ntfs-3g \
    bcd-sys mount umount hivexsh hivexregedit readpe peres setfattr fatattr; do
    ln -s /bin/false "$fixture/bin/$cmd"
done
export PATH="$fixture/bin:$PATH"

unexpected() {
    printf 'UNEXPECTED_COMMAND: %s\n' "$*" >&2
    return 97
}

test() {
    if [[ "$1" == -b ]]; then
        [[ "$2" == "$target" || "$2" == "${target}p1" || "$2" == "${target}p2" ]]
    else
        builtin test "$@"
    fi
}

readlink() {
    case "${!#}" in
        "$target"|"${target}p1"|"${target}p2") printf '%s\n' "${!#}" ;;
        /sys/dev/block/240:0) printf '%s\n' "$nodes/target" ;;
        /sys/dev/block/240:1) printf '%s\n' "$nodes/target/part1" ;;
        /sys/dev/block/240:2) printf '%s\n' "$nodes/target/part2" ;;
        /sys/dev/block/241:0) printf '%s\n' "$nodes/source" ;;
        /sys/dev/block/241:1) printf '%s\n' "$nodes/source/part1" ;;
        /sys/dev/block/7:0) printf '%s\n' "$nodes/loop0" ;;
        /sys/dev/block/254:0) printf '%s\n' "$nodes/mapped" ;;
        *) command readlink "$@" ;;
    esac
}

iso_device() {
    case "$scenario" in
        same-disk) echo 240:1 ;;
        iso-root-device) echo 240:0 ;;
        loop-same|loop-other|loop-overmounted) echo 7:0 ;;
        mapped-other|mapped-same) echo 254:0 ;;
        *) echo 241:1 ;;
    esac
}

stat() {
    if [[ "$2" == '%Hr:%Lr' ]]; then
        case "${!#}" in
            "$target") echo 240:0 ;;
            "${target}p1") echo 240:1 ;;
            "${target}p2") echo 240:2 ;;
            *) unexpected stat "$@" ;;
        esac
    elif [[ "$2" == '%Hd:%Ld' ]]; then
        case "${!#}" in
            "$iso"|/proc/*/fd/*) iso_device ;;
            "$backing") [[ "$scenario" == loop-same ]] && echo 240:1 || echo 241:1 ;;
            /|/boot|/boot/efi) [[ "$scenario" == host-disk ]] && echo 240:1 || echo 241:1 ;;
            *) unexpected stat "$@" ;;
        esac
    else
        command stat "$@"
    fi
}

findmnt() {
    case "$*" in
        "-nro FSTYPE,MAJ:MIN --target "*)
            case "${!#}" in
                "$iso")
                    case "$scenario" in
                        ambiguous) echo 'btrfs 241:1' ;;
                        lookup-failure) echo 'ext4 241:1'; return 1 ;;
                        loop-*) printf 'iso9660 %s\n' "$(iso_device)" ;;
                        *) printf 'ext4 %s\n' "$(iso_device)" ;;
                    esac ;;
                *) printf 'ext4 %s\n' "$(stat -Lc '%Hd:%Ld' -- "${!#}")" ;;
            esac ;;
        "-nro SOURCE --mountpoint $mount_root/win") echo "${target}p2" ;;
        "-nro SOURCE --mountpoint $mount_root/boot")
            [[ "$scenario" == wrong-mount ]] && echo "${target}p2" || echo "${target}p1" ;;
        *) unexpected findmnt "$@" ;;
    esac
}

losetup() {
    [[ "$*" == '-lnr -O BACK-MAJ:MIN -- /dev/loop0' ]] || unexpected losetup "$@"
    case "$scenario" in
        loop-same|loop-overmounted) echo 240:1 ;;
        *) echo 241:1 ;;
    esac
}

lsblk() {
    case "$*" in
        '-dnrpo NAME,TYPE,TRAN') printf '/dev/win2go-host disk sata\n%s disk usb\n' "$target" ;;
        "-dn -o SIZE,MODEL $target") echo '60G Test USB' ;;
        "-dnbro TYPE,TRAN,MAJ:MIN,SIZE,RO -- $target")
            if [[ "$scenario" == large ]]; then
                echo 'disk usb 240:0 128000000000 0'
            else
                echo 'disk usb 240:0 64000000000 0'
            fi ;;
        "-dnbro TYPE,TRAN,MAJ:MIN,SIZE,RO,MODEL,SERIAL -- $target")
            printf '%s Test_USB STABLE\n' "$(lsblk -dnbro TYPE,TRAN,MAJ:MIN,SIZE,RO -- "$target")" ;;
        "-nro TYPE -- $target")
            if [[ "$scenario" == active-volume ]]; then
                printf 'disk\npart\ncrypt\n'
            elif [[ -f "$fixture/partitioned" ]]; then
                printf 'disk\npart\npart\n'
            else
                echo disk
            fi ;;
        "-nro MOUNTPOINTS -- $target")
            if [[ "$scenario" == mounted ]]; then echo /media/automounted; fi
            if [[ "$scenario" == auto-mount && -f "$fixture/formatted-esp" ]]; then echo /media/automounted; fi
            if [[ -f "$mount_root/win/mounted" ]]; then echo "$mount_root/win"; fi
            if [[ -f "$mount_root/boot/mounted" ]]; then echo "$mount_root/boot"; fi ;;
        "-dn -o MODEL,SERIAL -- $target") echo 'Test USB STABLE' ;;
        "-dnro PTTYPE -- $target") [[ "$scenario" == wrong-table ]] && echo dos || echo gpt ;;
        "-dnro TYPE,MAJ:MIN,PARTTYPE,PARTUUID -- ${target}p1")
            echo "part 240:1 $esp_guid $esp_uuid" ;;
        "-dnro TYPE,MAJ:MIN,PARTTYPE,PARTUUID -- ${target}p2")
            case "$scenario" in
                wrong-partition) echo "part 240:2 $esp_guid $data_uuid" ;;
                partition-changed)
                    if [[ -f "$fixture/formatted-esp" ]]; then
                        echo "part 240:2 $data_guid $esp_uuid"
                    else
                        echo "part 240:2 $data_guid $data_uuid"
                    fi ;;
                *) echo "part 240:2 $data_guid $data_uuid" ;;
            esac ;;
        *) unexpected lsblk "$@" ;;
    esac
}

mktemp() {
    [[ "$*" == '-d /tmp/win2go.XXXXXXXXXX' ]] || unexpected mktemp "$@"
    mkdir -- "$mount_root"
    printf '%s\n' "$mount_root"
}

mountpoint() {
    [[ "$*" == "-q -- $mount_root/"* ]] || unexpected mountpoint "$@"
    [[ -f "${!#}/mounted" ]] || return 32
}

wimlib-imagex() {
    [[ "$1" == info && "$2" == "$mount_root/iso/sources/install."* && -f "$2" ]] ||
        { unexpected wimlib-imagex "$@"; return; }
    if [[ $# == 2 ]]; then
        printf 'Index: 1\nName: Test Windows\nIndex: 2\nName: Test Windows Pro\n'
        case "$scenario" in
            changed-disk) echo 2 > "$nodes/target/diskseq" ;;
            changed-iso) printf 'replacement bytes' >> "$iso" ;;
        esac
    else
        [[ "$3" == 1 || "$3" == 2 ]] || return 1
        if [[ "$scenario" == unsupported-edition ]]; then
            echo 'Architecture:           ARM64'
        else
            echo 'Architecture:           x86_64'
        fi
    fi
}

sudo() {
    local cmd=$1 path=${!#} image line
    printf '%s\n' "$*" >> "$calls"
    shift
    case "$cmd" in
        -v) [[ "$scenario" != denied ]] ;;
        mount)
            case "$path" in
                "$mount_root/iso")
                    [[ "$1 $2 $3 $4" == '-c -o loop,ro,nosuid,nodev,noexec --' &&
                       "$(command readlink -e -- "$5")" == "$iso" ]] || return 97
                    touch "$path/mounted"
                    [[ "$scenario" != mount-partial ]] || return 23
                    if [[ "$scenario" == signal ]]; then
                        kill -TERM "$$"
                        return 0
                    fi
                    mkdir "$path/sources"
                    case "$scenario" in
                        esd) touch "$path/sources/install.esd" ;;
                        no-image) ;;
                        *) touch "$path/sources/install.wim" ;;
                    esac ;;
                "$mount_root/win")
                    [[ "$*" == "-t ntfs-3g -o nosuid,nodev,noexec -- ${target}p2 $path" ]] || return 97
                    touch "$path/mounted"
                    if [[ "$scenario" != missing-loader ]]; then
                        mkdir -p "$path/Windows/System32"
                        touch "$path/Windows/System32/winload.efi"
                    fi ;;
                "$mount_root/boot")
                    [[ "$*" == "-t vfat -o nosuid,nodev,noexec -- ${target}p1 $path" ]] || return 97
                    touch "$path/mounted" ;;
                *) unexpected sudo mount "$@" ;;
            esac ;;
        parted)
            [[ "$*" == "--script $target mklabel gpt mkpart ESP fat32 1MiB 513MiB set 1 esp on mkpart Windows ntfs 513MiB 100%" ]] || return 97
            [[ "$scenario" != parted-failure ]] || return 24
            touch "$fixture/partitioned" ;;
        partprobe) [[ "$*" == "$target" ]] ;;
        udevadm) [[ "$*" == settle ]] ;;
        mkfs.vfat)
            [[ "$*" == "-F32 ${target}p1" ]] || return 97
            touch "$fixture/formatted-esp" ;;
        mkfs.ntfs)
            [[ "$*" == "-f ${target}p2" && -f "$fixture/formatted-esp" ]] || return 97
            touch "$fixture/formatted-win" ;;
        wimlib-imagex)
            image=install.wim
            [[ "$scenario" != esd ]] || image=install.esd
            [[ "$*" == "apply $mount_root/iso/sources/$image 2 ${target}p2" &&
               -f "$fixture/formatted-win" ]] || return 97
            [[ "$scenario" != apply-failure ]] || return 25 ;;
        bcd-sys)
            [[ "$*" == "$mount_root/win -s $mount_root/boot -f uefi" ]] || return 97
            [[ "$scenario" != bcd-failure ]] || return 26
            mkdir -p "$mount_root/boot/EFI/"{Microsoft/Boot,BOOT}
            [[ "$scenario" == missing-bcd ]] ||
                echo bcd > "$mount_root/boot/EFI/Microsoft/Boot/BCD"
            [[ "$scenario" == missing-fallback ]] ||
                echo loader > "$mount_root/boot/EFI/BOOT/BOOTX64.efi" ;;
        hivexsh)
            [[ "$*" == "$mount_root/boot/EFI/Microsoft/Boot/BCD" ]] || return 97
            IFS= read -r line
            [[ "$line" == 'cd Objects\{9dea862c-5cdd-4e70-acc1-f32b344d4795}\Elements\24000001' &&
               "$scenario" != corrupt-bcd ]] ;;
        test) builtin test "$@" ;;
        sync) [[ "$*" == "-f -- $mount_root/win $mount_root/boot" && "$scenario" != sync-failure ]] ;;
        umount)
            [[ "$*" == "-- $mount_root/"* && -f "$path/mounted" ]] || return 97
            if [[ "$scenario" == busy && "$path" == "$mount_root/boot" ]]; then return 29; fi
            find "$path" -mindepth 1 -delete ;;
        *) unexpected sudo "$cmd" "$@" ;;
    esac
}

export -f unexpected test readlink iso_device stat findmnt losetup lsblk mktemp mountpoint wimlib-imagex sudo

run_case() {
    export scenario=$1
    local expected_status=$2 expected_message=$3 input=$4 status=0 output
    shift 4
    command rm -rf -- "$mount_root"
    command rm -f -- "$fixture"/{partitioned,formatted-esp,formatted-win}
    printf 1 > "$nodes/target/diskseq"
    : > "$iso"
    : > "$calls"
    output=$("$BASH" ./win2go.sh --iso "$iso" "$@" <<< "$input" 2>&1) || status=$?
    if [[ "$status" != "$expected_status" || "$output" != *"$expected_message"* ||
          "$output" == *UNEXPECTED_COMMAND* ]]; then
        printf 'FAIL: %s (status %s)\n%s\n' "$scenario" "$status" "$output" >&2
        cat "$calls" >&2
        exit 1
    fi
    if [[ "$scenario" != busy ]]; then
        [[ ! -e "$mount_root" ]] || { echo "Leaked mounts: $scenario" >&2; exit 1; }
    fi
    printf 'PASS: %s\n' "$scenario"
}

no_writes() {
    if grep -Eq '^(parted|mkfs\.|wimlib-imagex apply|bcd-sys)' "$calls"; then
        echo "Unexpected disk writes in $scenario" >&2
        exit 1
    fi
}

for scenario in same-disk iso-root-device loop-same; do
    run_case "$scenario" 1 'Target USB contains the source ISO' '' --drive "$target"
    [[ ! -s "$calls" ]]
done
run_case host-disk 1 'Target USB contains the host root' '' --drive "$target"
[[ ! -s "$calls" ]]
for scenario in ambiguous lookup-failure loop-overmounted; do
    run_case "$scenario" 1 'Cannot identify physical backing for the source ISO' '' --drive "$target"
    [[ ! -s "$calls" ]]
done
for scenario in dry-run loop-other mapped-other large; do
    run_case "$scenario" 0 'mkfs.vfat -F32 /dev/win2go-test9p1' '' --dry-run --drive "$target"
    [[ ! -s "$calls" ]]
done
ln -s "$nodes/target/part1" "$nodes/mapped/slaves/targetpart"
run_case mapped-same 1 'Target USB contains the source ISO' '' --drive "$target"
[[ ! -s "$calls" ]]
rm -- "$nodes/mapped/slaves/targetpart"
run_case mounted 1 'mounted filesystems' '' --drive "$target"
run_case active-volume 1 'active volumes' '' --drive "$target"
run_case invalid-selection 1 'Invalid USB selection' 99
run_case large 1 'Canceled' no --drive "$target"
[[ ! -s "$calls" ]]
run_case denied 1 'Cannot obtain mount and disk permissions' '' --drive "$target"
[[ "$(cat "$calls")" == -v ]]
run_case no-image 1 'does not contain install.wim/install.esd' '' --drive "$target"
no_writes
run_case invalid-index 1 'Invalid Windows image index' 3 --drive "$target"
no_writes
run_case unsupported-edition 1 'must be a Windows x86_64 image' 2 --drive "$target"
no_writes
run_case cancelled 1 'Canceled' $'2\nno' --drive "$target"
no_writes
run_case changed-disk 1 'Target USB disk changed' $'2\nyes' --drive "$target"
no_writes
run_case changed-iso 1 'Source ISO changed' $'2\nyes' --drive "$target"
no_writes
run_case mount-partial 23 '' '' --drive "$target"
no_writes
run_case signal 143 '' '' --drive "$target"
no_writes
run_case wim 0 'Windows files and UEFI BCD written' $'1\n2\nyes'
[[ "$(tail -n 3 "$calls")" == "umount -- $mount_root/boot"$'\n'"umount -- $mount_root/win"$'\n'"umount -- $mount_root/iso" ]]
run_case esd 0 'Windows files and UEFI BCD written' $'2\nyes' --drive "$target"
run_case parted-failure 24 '' $'2\nyes' --drive "$target"
run_case wrong-table 1 'Expected GPT' $'2\nyes' --drive "$target"
run_case wrong-partition 1 'Expected Windows data partition' $'2\nyes' --drive "$target"
run_case partition-changed 1 'Target partitions changed' $'2\nyes' --drive "$target"
run_case auto-mount 1 'mounted filesystems' $'2\nyes' --drive "$target"
if grep -q '^mkfs.ntfs' "$calls"; then exit 1; fi
run_case apply-failure 25 '' $'2\nyes' --drive "$target"
run_case wrong-mount 1 'Unexpected filesystem' $'2\nyes' --drive "$target"
run_case missing-loader 1 'Windows loader missing' $'2\nyes' --drive "$target"
if grep -q '^bcd-sys' "$calls"; then exit 1; fi
run_case bcd-failure 26 '' $'2\nyes' --drive "$target"
run_case missing-bcd 1 'BCD was not created' $'2\nyes' --drive "$target"
run_case corrupt-bcd 1 'BCD is unreadable' $'2\nyes' --drive "$target"
run_case missing-fallback 1 'fallback bootloader missing' $'2\nyes' --drive "$target"
run_case sync-failure 1 '' $'2\nyes' --drive "$target"
run_case busy 1 'Cleanup incomplete' $'2\nyes' --drive "$target"
[[ -f "$mount_root/boot/mounted" && ! -f "$mount_root/win/mounted" && ! -f "$mount_root/iso/mounted" ]]
