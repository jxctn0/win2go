#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

for script in win2go.sh scripts/*.sh tests/*.sh; do
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

echo "NOTE: Physical Windows boot remains unverified."
