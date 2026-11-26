# Shared installation operations. Callers validate their target before writing.
windows_gpt_args() {
    PARTED_ARGS=(--script "$1" mklabel gpt mkpart ESP fat32 1MiB 513MiB set 1 esp on
                 mkpart Windows ntfs 513MiB 100%)
}

apply_windows_image() {
    local image=$1 index=$2 volume=$3
    shift 3
    "$@" wimlib-imagex apply "$image" "$index" "$volume"
}

validate_windows_boot() {
    local esp=$1 bcd="$1/EFI/Microsoft/Boot/BCD"
    shift
    "$@" test -s "$bcd" || { echo "ERROR: BCD was not created" >&2; return 1; }
    "$@" hivexsh "$bcd" <<<'cd Objects\{9dea862c-5cdd-4e70-acc1-f32b344d4795}\Elements\24000001' ||
        { echo "ERROR: BCD is unreadable or has no Windows Boot Manager display order" >&2; return 1; }
    "$@" test -s "$esp/EFI/BOOT/BOOTX64.efi" ||
        { echo "ERROR: UEFI fallback bootloader missing" >&2; return 1; }
}

windows_image_is_x64() {
    grep -Eq '^Architecture:[[:space:]]+x86_64$' <<< "$1"
}
