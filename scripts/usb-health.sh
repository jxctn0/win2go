#!/usr/bin/env bash
# Non-destructive USB read benchmark and kernel-error check.
set -euo pipefail

usage() {
  echo "Usage: sudo bash scripts/usb-health.sh --device /dev/sdX [--mib 1024] [--timeout 180]"
  exit 2
}

device=""
mib=1024
seconds=180
while (($#)); do
  case "$1" in
    --device) (($# >= 2)) || usage; device="$2"; shift 2 ;;
    --mib) (($# >= 2)) || usage; mib="$2"; shift 2 ;;
    --timeout) (($# >= 2)) || usage; seconds="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$device" && "$mib" =~ ^[1-9][0-9]*$ && "$seconds" =~ ^[1-9][0-9]*$ ]] || usage
((${#mib} <= 4 && ${#seconds} <= 4 && mib <= 4096 && seconds <= 1800)) || { echo "Maximum: 4096 MiB, 1800 seconds" >&2; exit 2; }
((EUID == 0)) || { echo "Run with sudo to access disk and kernel logs" >&2; exit 2; }
for cmd in lsblk readlink dd timeout dmesg grep mktemp cmp head; do
  command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 2; }
done

device=$(readlink -f -- "$device")
[[ -b "$device" ]] || { echo "Not a block device: $device" >&2; exit 2; }
[[ "$(lsblk -dn -o TYPE "$device")" == disk && "$(lsblk -dn -o TRAN "$device")" == usb ]] ||
  { echo "Refusing: only whole USB disks are accepted" >&2; exit 2; }

size=$(lsblk -dn -b -o SIZE "$device")
((size >= mib * 1048576)) || { echo "USB smaller than requested read range" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# dmesg stores may not be accessible on all systems; keep the read test usable.
kernel_ok=1
if dmesg --raw > "$tmp/before" 2>"$tmp/dmesg-error"; then
  before_lines=$(wc -l < "$tmp/before")
else
  kernel_ok=0
fi

echo "USB device: $device"
lsblk -dn -o NAME,SIZE,MODEL,TRAN,SERIAL "$device"
echo "READ-ONLY test: $mib MiB, maximum $seconds seconds"
echo "No writes or formatting will be performed."
# A single read shares one timeout across the entire requested range.
read_rc=0
LC_ALL=C timeout --signal=TERM --kill-after=5s "${seconds}s" \
  dd if="$device" of=/dev/null bs=1M count="$mib" iflag=direct,fullblock status=progress \
  2>"$tmp/dd-log" || read_rc=$?
cat "$tmp/dd-log"

new_errors=0
if ((kernel_ok)) && dmesg --raw > "$tmp/after" 2>/dev/null; then
  # Kernel ring buffer may rotate; if so, report that comparison is uncertain.
  if cmp -s "$tmp/before" <(head -n "$before_lines" "$tmp/after"); then
    tail -n "+$((before_lines + 1))" "$tmp/after" > "$tmp/new"
    if grep -Ei 'I/O error|error -110|error -62|reset .*usb|device descriptor read|Buffer I/O error|blk_update_request|critical medium error' "$tmp/new" > "$tmp/errors"; then
      new_errors=1
      echo "NEW kernel warnings:"
      cat "$tmp/errors"
    fi
  else
    echo "NOTE: kernel log rotated; new-error check is inconclusive"
    kernel_ok=0
  fi
else
  echo "NOTE: kernel log could not be inspected"
  kernel_ok=0
fi

if ((read_rc != 0)); then
  echo "FAIL: read exited with status $read_rc"
  exit 1
elif ! grep -qFx "$mib+0 records in" "$tmp/dd-log"; then
  echo "FAIL: read ended before completing $mib MiB"
  exit 1
elif ((new_errors)); then
  echo "WARNING: read completed but new kernel errors appeared"
  exit 1
fi

echo "PASS: read completed without dd errors."
if ((kernel_ok)); then
  echo "PASS: no matching NEW kernel errors observed."
else
  echo "Kernel errors not fully checked."
fi
echo "NOTE: A passing read test does NOT verify write reliability, real capacity, or Windows boot."
