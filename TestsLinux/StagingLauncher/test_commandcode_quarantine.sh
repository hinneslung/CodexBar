#!/usr/bin/env bash
set -euo pipefail

# Exercise the real gate functions with synthetic process results only.
root="$(cd "$(dirname "$0")/../.." && pwd)"
gate="$root/TestsLinux/StagingLauncher/test_unchanged_cli_routes.sh"
source <(sed -n '/^run_invocation() {/,/^manual_api_providers=(/p' "$gate" | sed '$d')
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT
canary=quarantine-test-secret
launcher="$fixture_root/launcher"
cli="$fixture_root/CodexBarCLI"
work="$fixture_root/work"
mkdir -p "$work" "$work/home" "$work/config" "$work/data" "$work/cache" "$work/tmp"
env_path="$(command -v env)"
strace_path=unused
timeout_path="$fixture_root/fixture"
unshare_path="$fixture_root/namespace"
namespace_mode=user

cat > "$unshare_path" <<'SH'
#!/usr/bin/env bash
while [[ "$1" != -- ]]; do shift; done
shift
exec "$@"
SH
cat > "$timeout_path" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
root="$(dirname "$0")"
config="$(cat)"
while [[ "$1" != -o ]]; do shift; done
shift
cp "$root/trace" "$1"
role=present
[[ "$config" != missing ]] || role=missing
cat "$root/$role.stdout"
exit "$(cat "$root/$role.status")"
SH
chmod +x "$timeout_path" "$unshare_path"

config_for() { if [[ "$3" == true ]]; then echo present; else echo missing; fi; }

reset_fixture() {
  printf 'execve("%s", ["launcher"], []) = 0\nexecve("%s", ["CLI", "usage", "--provider", "commandcode"], []) = 0\n' \
    "$launcher" "$cli" > "$fixture_root/trace"
  printf '%s' '[{"provider":"commandcode","source":"web","error":{"kind":"provider","message":"Network unavailable"}}]' > "$fixture_root/present.stdout"
  printf '%s' '[{"provider":"commandcode","source":"web","error":{"kind":"provider","message":"Missing cookie"}}]' > "$fixture_root/missing.stdout"
  echo 124 > "$fixture_root/present.status"
  echo 1 > "$fixture_root/missing.status"
  commandcode_policy=isolated
  GITHUB_STEP_SUMMARY="$fixture_root/summary"
  : > "$GITHUB_STEP_SUMMARY"
}

expect_failure() {
  local result=0
  # Invoke in a fresh shell so errexit is not disabled by a conditional caller.
  bash -euo pipefail -c "$1" > "$fixture_root/check.log" 2>&1 || result=$?
  if [[ $result -eq 0 ]]; then
    echo "expected blocking failure: $2" >&2
    exit 1
  fi
}
export -f run_invocation run_web_route assert_exec_evidence assert_structured_credential_evidence config_for
export fixture_root work canary launcher cli env_path strace_path timeout_path unshare_path namespace_mode
export commandcode_policy GITHUB_STEP_SUMMARY

reset_fixture
bash -euo pipefail -c 'run_web_route commandcode commandcode web' > "$fixture_root/check.log"
grep -Fq 'UNVERIFIED, not passed' "$fixture_root/check.log"
grep -Fq 'known timeout (not a passed route)' "$GITHUB_STEP_SUMMARY"

commandcode_policy=strict
expect_failure 'run_web_route commandcode commandcode web' 'strict timeout'
reset_fixture
expect_failure 'run_web_route amp amp web' 'other provider timeout'
for status in 125 126 127 137 139; do
  reset_fixture
  echo "$status" > "$fixture_root/present.status"
  expect_failure 'run_web_route commandcode commandcode web' "status $status"
done
reset_fixture
echo 124 > "$fixture_root/missing.status"
expect_failure 'run_web_route commandcode commandcode web' 'missing-control timeout'
reset_fixture
echo malformed > "$fixture_root/missing.stdout"
expect_failure 'run_web_route commandcode commandcode web' 'malformed missing control'
reset_fixture
echo "$canary" > "$fixture_root/present.stdout"
expect_failure 'run_web_route commandcode commandcode web' 'credential leak on timeout'
reset_fixture
echo 'execve("/unrelated", [], []) = 0' >> "$fixture_root/trace"
expect_failure 'run_web_route commandcode commandcode web' 'unrelated child on timeout'
reset_fixture
: > "$fixture_root/trace"
expect_failure 'run_web_route commandcode commandcode web' 'empty trace on timeout'
reset_fixture
echo malformed > "$fixture_root/present.stdout"
echo 1 > "$fixture_root/present.status"
expect_failure 'run_web_route commandcode commandcode web' 'non-timeout malformed output'
reset_fixture
echo 1 > "$fixture_root/present.status"
bash -euo pipefail -c 'run_web_route commandcode commandcode web' > "$fixture_root/check.log"
[[ ! -s "$GITHUB_STEP_SUMMARY" ]]
echo 'CommandCode quarantine regression tests passed'
