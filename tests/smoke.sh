#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

for script in win2go.sh lib/*.sh scripts/*.sh tests/*.sh; do
  bash -n "$script"
done
echo "PASS: Bash syntax"

# Detect any attempt to run privileged commands during input validation.
sudo() {
  echo "UNEXPECTED_PRIVILEGED_COMMAND" >&2
  return 99
}
export -f sudo

expect_failure() {
  local description=$1 expected_status=$2 expected_message=$3
  shift 3
  local status=0 output
  output=$("$@" 2>&1) || status=$?
  if [[ "$status" != "$expected_status" || "$output" != *"$expected_message"* ||
        "$output" == *UNEXPECTED_PRIVILEGED_COMMAND* ]]; then
    printf 'FAIL: %s (status %s)\n%s\n' "$description" "$status" "$output" >&2
    exit 1
  fi
  echo "PASS: $description"
}

expect_failure "missing ISO rejected" 1 "ISO not found:" \
  bash ./win2go.sh --iso /definitely-not-a-real-windows-image.iso
expect_failure "missing ISO rejected when a target is specified" 1 "ISO not found:" \
  bash ./win2go.sh --iso /definitely-not-a-real-windows-image.iso --drive /dev/win2go-unused
expect_failure "non-block target rejected" 1 "Target must be a whole USB disk" \
  bash ./win2go.sh --iso ./win2go.sh --drive /dev/null
expect_failure "missing argument rejected" 2 "--iso requires a value" \
  bash ./win2go.sh --iso
expect_failure "unsupported option rejected" 2 "Unsupported option: -y" \
  bash ./win2go.sh -y
expect_failure "out-of-range USB read size rejected before device access" 2 "Maximum:" \
  bash scripts/usb-health.sh --device /dev/win2go-unused --mib 18446744073709551617

expect_failure "virtual BCD refuses loop writes without explicit opt-in" 1 "requires explicit loop-write approval" \
  bash tests/windows-image.sh bcd /tmp/win2go-test-no-image --no-loop-writes

echo "NOTE: Physical Windows boot remains unverified."

(
  source tests/windows-image.sh
  work=$(mktemp -d)
  trap 'rm -rf -- "$work"' EXIT
  mkdir "$work/raw-build"
  touch "$work/raw-build/windows-togo.raw" "$work/code.fd" "$work/vars.fd"
  echo 'PASS: BCD-SYS created a readable BCD and x64 boot files' > "$work/bcd.log"
  free_bytes() { echo 4294967296; }
  qemu-system-x86_64() { printf '%s\n' "$@"; }
  output=$(boot_raw "$work" "$work/code.fd" "$work/vars.fd" gtk)
  [[ "$output" == *$'-display\ngtk\n'* &&
     "$output" == *$'-smp\n2\n-m\n2048\n-nic\nnone\n'* &&
     "$output" == *'snapshot=on,file='* &&
     "$output" == *'usb-storage,bus=usb.0,drive=wintogo,bootindex=1'* ]]
  grep -Fqx 'Display: gtk' "$work"/qemu.*/qemu.log
  echo 'PASS: graphical QEMU arguments and logging (mocked)'
)
