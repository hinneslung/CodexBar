#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <x86_64|aarch64> <output> [musl-sysroot]" >&2
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage
  exit 64
fi

architecture="$1"
output="$2"
sysroot="${3:-}"
case "$architecture" in
  x86_64) triple="x86_64-swift-linux-musl"; expected_machine="Advanced Micro Devices X86-64" ;;
  aarch64) triple="aarch64-swift-linux-musl"; expected_machine="AArch64" ;;
  *) usage; exit 64 ;;
esac

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_file="$source_root/Sources/CodexBarLinuxStagingLauncher/main.c"
mkdir -p "$(dirname "$output")"

if [[ -n "$sysroot" ]]; then
  compiler="${CC:-clang}"
  "$compiler" -target "$triple" --sysroot="$sysroot" -std=c11 -O2 -Wall -Wextra -Werror \
    -static -fPIE -pie "$source_file" -o "$output"
else
  native="$(uname -m)"
  if [[ "$native" != "$architecture" && ! ( "$native" == "arm64" && "$architecture" == "aarch64" ) ]]; then
    echo "a musl sysroot is required to cross-compile $architecture on $native" >&2
    exit 64
  fi
  compiler="${CC:-musl-gcc}"
  if [[ "$(basename "$compiler")" != *musl* ]]; then
    echo "release builds without a sysroot require an explicitly named musl compiler" >&2
    exit 64
  fi
  if ! command -v "$compiler" >/dev/null 2>&1; then
    echo "musl compiler not found: $compiler" >&2
    exit 69
  fi
  "$compiler" -std=c11 -O2 -Wall -Wextra -Werror -static -fPIE -pie "$source_file" -o "$output"
fi

chmod 0755 "$output"
header="$(LC_ALL=C readelf -h "$output")"
grep -F "Machine:" <<<"$header" | grep -Fq "$expected_machine"
if LC_ALL=C readelf -l "$output" | grep -q 'Requesting program interpreter'; then
  echo "launcher is dynamically linked: $output" >&2
  exit 1
fi
hash="$(sha256sum "$output" | awk '{print $1}')"
printf '%s  %s\n' "$hash" "$(basename "$output")" >"$output.sha256"
