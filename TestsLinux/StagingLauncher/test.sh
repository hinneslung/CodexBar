#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cc -std=c11 -O2 -Wall -Wextra -Werror -static \
  "$repo_root/Sources/CodexBarLinuxStagingLauncher/main.c" -o "$work/CodexBarStagingLauncher"
cc -std=c11 -O2 -Wall -Wextra -Werror -static -DCODEXBAR_TEST_DISABLE_MEMFD \
  "$repo_root/Sources/CodexBarLinuxStagingLauncher/main.c" -o "$work/CodexBarStagingLauncherFallback"
cc -std=c11 -O2 -Wall -Wextra -Werror -static \
  "$repo_root/TestsLinux/StagingLauncher/fixture_cli.c" -o "$work/CodexBarCLI"

output="$(printf '%s' '{"canary":"stdin-only"}' | "$work/CodexBarStagingLauncher" \
  --timeout-seconds 5 --provider fixture --source web --mode usage)"
[[ "$output" == "fixture-ok" ]]
fallback_output="$(printf '%s' '{"canary":"stdin-only"}' | "$work/CodexBarStagingLauncherFallback" \
  --timeout-seconds 5 --provider fixture --source web --mode usage)"
[[ "$fallback_output" == "fixture-ok" ]]
diagnose_output="$(printf '%s' '{"canary":"stdin-only"}' | "$work/CodexBarStagingLauncher" \
  --timeout-seconds 5 --provider fixture --source web --mode diagnose)"
[[ "$diagnose_output" == "fixture-diagnose-ok" ]]
! find /tmp -maxdepth 1 -name '.codexbar-config-*' -print -quit | grep -q .

if printf '{}' | "$work/CodexBarStagingLauncher" \
  --timeout-seconds 5 --provider fixture --source auto --mode usage 2>/dev/null; then
  echo "launcher accepted disallowed source auto" >&2
  exit 1
fi
if printf '{}' | "$work/CodexBarStagingLauncher" \
  --timeout-seconds 5 --provider '../fixture' --source web --mode usage 2>/dev/null; then
  echo "launcher accepted malformed provider" >&2
  exit 1
fi
if printf '{}' | "$work/CodexBarStagingLauncher" \
  --timeout-seconds 5 --provider fixture --source web --mode arbitrary 2>/dev/null; then
  echo "launcher accepted arbitrary command mode" >&2
  exit 1
fi
if printf '{}' | "$work/CodexBarStagingLauncher" \
  --timeout-seconds 5 --provider fixture --source web 2>/dev/null; then
  echo "launcher accepted missing command mode" >&2
  exit 1
fi

python3 -c 'import sys; sys.stdout.write("x" * (1024 * 1024 + 1))' >"$work/oversize"
set +e
"$work/CodexBarStagingLauncher" --timeout-seconds 5 --provider fixture --source web \
  --mode usage <"$work/oversize" >"$work/oversize.out" 2>"$work/oversize.err"
oversize_status=$?
set -e
[[ "$oversize_status" == 65 ]]
! grep -q 'xxxxx' "$work/oversize.err"

mv "$work/CodexBarCLI" "$work/CodexBarCLI.missing"
set +e
printf '{}' | "$work/CodexBarStagingLauncher" --timeout-seconds 5 --provider fixture --source web \
  --mode usage >"$work/missing.out" 2>"$work/missing.err"
missing_status=$?
set -e
[[ "$missing_status" == 126 ]]

mv "$work/CodexBarCLI.missing" "$work/CodexBarCLI"
started="$(date +%s)"
set +e
printf '%s' '{"canary":"stdin-only"}' | "$work/CodexBarStagingLauncher" \
  --timeout-seconds 1 --provider slow --source web --mode usage \
  >"$work/timeout.out" 2>"$work/timeout.err"
timeout_status=$?
set -e
elapsed="$(( $(date +%s) - started ))"
[[ "$timeout_status" == 124 ]]
[[ "$elapsed" -le 7 ]]
! pgrep -f "$work/CodexBarCLI" >/dev/null

set +e
printf '%s' '{"canary":"stdin-only"}' | "$work/CodexBarStagingLauncher" \
  --timeout-seconds 5 --provider crash --source web --mode usage >/dev/null
crash_status=$?
set -e
[[ "$crash_status" == 42 ]]

printf '%s' '{"canary":"stdin-only"}' >"$work/config"
"$work/CodexBarStagingLauncher" --timeout-seconds 20 --provider slow --source web \
  --mode usage <"$work/config" >"$work/cancel.out" 2>"$work/cancel.err" &
launcher_pid=$!
for _ in $(seq 1 50); do
  [[ -d "/proc/$launcher_pid/fd" ]] && break
  sleep 0.01
done
config_fd="$(find "/proc/$launcher_pid/fd" -maxdepth 1 -type l -lname '*codexbar-config*' -print -quit)"
[[ -n "$config_fd" ]]
[[ "$(stat -Lc '%a' "$config_fd")" == 600 ]]
! tr '\0' '\n' <"/proc/$launcher_pid/environ" | grep -Fq 'stdin-only'
! tr '\0' '\n' <"/proc/$launcher_pid/cmdline" | grep -Fq 'stdin-only'
child_pid="$(pgrep -P "$launcher_pid" -f "$work/CodexBarCLI" | head -n 1)"
[[ -n "$child_pid" ]]
! tr '\0' '\n' <"/proc/$child_pid/environ" | grep -Fq 'stdin-only'
! tr '\0' '\n' <"/proc/$child_pid/cmdline" | grep -Fq 'stdin-only'
kill -TERM "$launcher_pid"
set +e
wait "$launcher_pid"
cancel_status=$?
set -e
[[ "$cancel_status" == 143 ]]
[[ ! -e "/proc/$launcher_pid" ]]
! pgrep -f "$work/CodexBarCLI" >/dev/null
! find /tmp -maxdepth 1 -name '.codexbar-config-*' -print -quit | grep -q .

mkfifo "$work/stalled-stdin"
bash -c 'exec 9>"$1"; sleep 30' _ "$work/stalled-stdin" &
writer_pid=$!
"$work/CodexBarStagingLauncher" --timeout-seconds 20 --provider fixture --source web \
  --mode usage <"$work/stalled-stdin" >"$work/stalled.out" 2>"$work/stalled.err" &
stalled_pid=$!
for _ in $(seq 1 50); do
  [[ -d "/proc/$stalled_pid" ]] && break
  sleep 0.01
done
kill -TERM "$stalled_pid"
set +e
wait "$stalled_pid"
stalled_status=$?
set -e
[[ "$stalled_status" == 143 ]]
kill "$writer_pid" 2>/dev/null || true
wait "$writer_pid" 2>/dev/null || true

echo "staging launcher tests passed"
