#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir "$fixture/bin"
# Use a private PATH with no host fallback. The sudo stub accepts package
# operations as no-ops and does not invoke any command.
for cmd in git lsblk findmnt losetup readlink stat sfdisk hexdump parted partprobe udevadm \
    mkfs.vfat mkfs.ntfs ntfs-3g mount umount mountpoint wimlib-imagex \
    hivexsh hivexregedit readpe peres setfattr fatattr; do
    ln -s /bin/false "$fixture/bin/$cmd"
done
cat > "$fixture/bin/sudo" <<'SUDO'
#!/bin/bash
[[ "$1" == apt-get && ( "$2" == update || "$2" == install ) ]]
SUDO
chmod +x "$fixture/bin/sudo"
status=0
output=$(PATH="$fixture/bin" "$BASH" scripts/deps-ubuntu.sh --check) || status=$?
[[ "$status" == 1 && "$output" == 'Missing commands: bcd-sys' ]]
echo 'PASS: --check fails when a dependency is missing'
ln -s /bin/false "$fixture/bin/bcd-sys"
for args in '' --check --install; do
    # Empty args tests the default mode.
    output=$(PATH="$fixture/bin" "$BASH" scripts/deps-ubuntu.sh ${args:+"$args"} <<< YES)
    [[ "$output" == *'All Win2Go/BCD-SYS dependencies are installed.'* ]]
    printf 'PASS: dependency verifier succeeds in %s mode\n' "${args:-default}"
done
