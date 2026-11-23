#!/usr/bin/env bash
# Runs scripts/private-host-run.sh the way Azure managed Run Command does (root, no HOME) with stub tools.
set -eu
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
subject="$here/../private-host-run.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state"
: > "$tmp/state/tools-ready"

stub() { printf '%s\n' "#!/usr/bin/env bash" "$2" > "$tmp/bin/$1"; chmod +x "$tmp/bin/$1"; }
stub az 'echo "az $*" >> "$STUB_CALLS"'
stub azd 'if [ -z "${HOME:-}" ]; then echo "panic: could not determine current home directory: \$HOME is not defined" >&2; exit 2; fi; echo "azd $* home=$HOME" >> "$STUB_CALLS"'
stub git 'case "$1" in clone) for last; do :; done; mkdir -p "$last/.git";; esac; echo "git $*" >> "$STUB_CALLS"'
stub pwsh '[ -n "${HOME:-}" ] || exit 2
echo "pwsh $* docker=${DOCKER_CONFIG:-} telemetry=${AZURE_DEV_COLLECT_TELEMETRY:-}" >> "$STUB_CALLS"
[ "${STUB_PWSH_FAIL:-}" = 1 ] && { echo "synthetic build failure"; exit 1; }
while [ $# -gt 0 ]; do if [ "$1" = -ResultFile ]; then printf "{\"healthy\":true,\"requestId\":\"%s\"}" "$CLOUDLENS_DEPLOY_REQUEST_ID" > "$2"; fi; shift; done'

revision="$(printf 'a%.0s' $(seq 1 40))"
request="$(printf 'b%.0s' $(seq 1 32))"
run_host() {
  {
    printf "%s\n" "environment='test'" "subscription='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'" "repository='https://example.test/CloudLens.git'" \
      "revision='$revision'" "request_id='$request'" "settings_b64='$(printf 'APP_PROFILE="data"\n' | base64 -w0)'" "deploy_mode='$1'" "log='$tmp/host.log'"
    cat "$subject"
  } > "$tmp/remote.sh"
  : > "$tmp/calls"
  PATH="$tmp/bin:$PATH" STUB_CALLS="$tmp/calls" CLOUDLENS_STATE_DIR="$tmp/state" env -u HOME bash "$tmp/remote.sh"
}

out="$(run_host deploy)"
grep -q "^CLOUDLENS_RESULT:{\"healthy\":true,\"requestId\":\"$request\"}$" <<<"$out" || { echo "FAIL: no verified result: $out"; exit 1; }
grep -q 'azd auth login --managed-identity' "$tmp/calls" || { echo 'FAIL: the host must sign in with its identity'; exit 1; }
grep -q "checkout --quiet --detach $revision$" "$tmp/calls" || { echo 'FAIL: exact revision not checked out'; exit 1; }
grep -q 'deploy-on-host.ps1' "$tmp/calls" || { echo 'FAIL: deploy mode must build'; exit 1; }
grep -q "docker=$tmp/state/deployments/test/home/.docker telemetry=no" "$tmp/calls" || { echo 'FAIL: HOME, docker and telemetry settings missing'; exit 1; }
echo 'PASS: the host script supplies HOME and deploys at the exact revision'

run_host verify >/dev/null
grep -q 'verify-private-deployment.ps1' "$tmp/calls" && ! grep -q 'deploy-on-host.ps1' "$tmp/calls" || { echo 'FAIL: verify mode must not rebuild'; exit 1; }
echo 'PASS: verify mode does not rebuild'

rm -f "$tmp/state/deployments/test/result.json"
status=0
out="$(STUB_PWSH_FAIL=1 run_host deploy 2>&1)" || status=$?
[ "$status" -ne 0 ] && grep -q 'synthetic build failure' <<<"$out" && ! grep -q '^CLOUDLENS_RESULT:' <<<"$out" || { echo "FAIL: a failed build must exit non-zero with the log tail: $out"; exit 1; }
echo 'PASS: a failed build exits non-zero and prints the log tail'
