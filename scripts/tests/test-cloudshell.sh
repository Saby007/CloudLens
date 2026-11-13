#!/usr/bin/env bash
set -euo pipefail
subject="$(cd "$(dirname "$0")/.." && pwd)/deploy-cloudshell.sh"
temp="$(mktemp -d)"
trap 'rm -rf -- "$temp"' EXIT
export HOME="$temp/home"
export ACC_CLOUD=AzureCloud
export TEST_LOG="$temp/commands.log"
mkdir -p "$HOME/clouddrive" "$temp/bin"
export PATH="$temp/bin:$PATH"

cat > "$temp/bin/mountpoint" <<'STUB'
#!/usr/bin/env bash
[[ "${TEST_PERSISTENT:-true}" == true ]]
STUB
cat > "$temp/bin/az" <<'STUB'
#!/usr/bin/env bash
printf 'az %s\n' "$*" >> "$TEST_LOG"
STUB
cat > "$temp/bin/azd" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == version ]]; then echo 'azd version 1.37.3'; else printf 'azd %s\n' "$*" >> "$TEST_LOG"; fi
STUB
cat > "$temp/bin/terraform" <<'STUB'
#!/usr/bin/env bash
echo '{"terraform_version":"1.17.2"}'
STUB
cat > "$temp/bin/git" <<'STUB'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$TEST_LOG"
if [[ "$1" == clone ]]; then mkdir -p "${@: -1}/.git"; exit; fi
case "$3 $4" in
  'remote get-url') echo 'https://github.com/Saby007/CloudLens.git' ;;
  'branch --show-current') echo cloudlensdev ;;
  'status --porcelain') [[ "${TEST_DIRTY:-false}" == false ]] || echo ' M README.md' ;;
esac
exit 0
STUB
cat > "$temp/bin/pwsh" <<'STUB'
#!/usr/bin/env bash
printf 'pwsh %s\n' "$*" >> "$TEST_LOG"
STUB
chmod +x "$temp/bin/"*

bash "$subject"
grep -q 'git clone --single-branch --branch cloudlensdev' "$TEST_LOG"
grep -q 'azd config set auth.useAzCliAuth true' "$TEST_LOG"
grep -q -- '-IngressVisibility private -ControlPlane private -SkipLogin -InstallKubernetesTools -EnvironmentName cloudlens -Profile data' "$TEST_LOG"
echo 'PASS: fresh Cloud Shell uses persistent storage, the existing login, private deployment and data profile'

bash "$subject" -EnvironmentName customer -Profile ai -Location eastus2 -TargetSubscriptionId aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
grep -q 'merge --ff-only origin/cloudlensdev' "$TEST_LOG"
grep -q -- '-EnvironmentName customer -Profile ai -Location eastus2' "$TEST_LOG"
echo 'PASS: reruns update fast-forward only and preserve supplied deployment arguments'

if TEST_PERSISTENT=false bash "$subject" >/dev/null 2>&1; then echo 'Ephemeral Cloud Shell must be refused' >&2; exit 1; fi
echo 'PASS: ephemeral Cloud Shell is rejected before provisioning'
if TEST_DIRTY=true bash "$subject" >/dev/null 2>&1; then echo 'Local changes must not be overwritten' >&2; exit 1; fi
echo 'PASS: existing local changes are preserved'
