#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash -n win2go.sh
echo "PASS: Bash syntax"
# All tests below exit before reaching the USB-erasure step.
if bash ./win2go.sh --iso /definitely-not-a-real-windows-image.iso >/dev/null 2>&1; then
  echo "FAIL: accepted missing ISO" >&2
  exit 1
fi
echo "PASS: missing ISO rejected"
if bash ./win2go.sh --iso /definitely-not-a-real-windows-image.iso --drive /dev/sda >/dev/null 2>&1; then
  echo "FAIL: accepted nonexistent ISO" >&2
  exit 1
fi
echo "PASS: rejects invalid input without formatting"
echo "NOTE: USB partitioning and Windows boot require separate real-device tests."
