#!/usr/bin/env bash
set -euo pipefail
subject="$(cd "$(dirname "$0")/.." && pwd)/deploy-cloudshell.sh"
temp="$(mktemp -d)"
trap 'rm -rf -- "$temp"' EXIT
export HOME="$temp/home"
export ACC_CLOUD=AzureCloud
export TEST_LOG="$temp/commands.log"
export TEST_REAL_MKTEMP="$(command -v mktemp)"
unset AZD_SUBSCRIPTIONS_FETCH_MAX_CONCURRENCY
mkdir -p "$HOME" "$temp/bin"
source_url="file://$subject"
if command -v cygpath >/dev/null; then source_url="file:///$(cygpath -m "$subject")"; fi
if curl -fsSL "$source_url" -o "$HOME/clouddrive/deploy-cloudlens.sh" 2>"$temp/curl-error"; then
  echo 'The old bootstrap must fail when clouddrive is missing.' >&2
  exit 1
else
  curl_status=$?
fi
[[ "$curl_status" == 23 ]] || { echo "Expected curl write error 23, got $curl_status." >&2; exit 1; }
curl -fsSL "$source_url" -o "$HOME/deploy-cloudlens.sh"
cmp "$subject" "$HOME/deploy-cloudlens.sh"
echo 'PASS: downloading the bootstrap to HOME avoids curl write error 23 when clouddrive is missing'
export PATH="$temp/bin:$PATH"

cat > "$temp/bin/mountpoint" <<'STUB'
#!/usr/bin/env bash
[[ "${TEST_PERSISTENT:-true}" == true ]]
STUB
cat > "$temp/bin/mktemp" <<'STUB'
#!/usr/bin/env bash
if [[ "${TEST_UNWRITABLE:-false}" == true && "$*" == *'/clouddrive/'* ]]; then
  echo 'Synthetic mounted share write failure.' >&2
  exit 1
fi
exec "$TEST_REAL_MKTEMP" "$@"
STUB
cat > "$temp/bin/az" <<'STUB'
#!/usr/bin/env bash
printf 'az %s\n' "$*" >> "$TEST_LOG"
STUB
cat > "$temp/bin/azd" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == version ]]; then echo 'azd version 1.37.3'; else printf 'azd %s\n' "$*" >> "$TEST_LOG"; fi
printf 'azd subscription-concurrency=%s\n' "${AZD_SUBSCRIPTIONS_FETCH_MAX_CONCURRENCY:-unset}" >> "$TEST_LOG"
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
  'status --porcelain')
    case "${TEST_DIRTY:-false}" in
      false) ;;
      lock) echo ' M infra/.terraform.lock.hcl' ;;
      mixed) printf ' M infra/.terraform.lock.hcl\n M README.md\n' ;;
      staged-lock) echo 'M  infra/.terraform.lock.hcl' ;;
      deleted-lock) echo ' D infra/.terraform.lock.hcl' ;;
      *) echo ' M README.md' ;;
    esac ;;
esac
exit 0
STUB
cat > "$temp/bin/pwsh" <<'STUB'
#!/usr/bin/env bash
printf 'pwsh %s\n' "$*" >> "$TEST_LOG"
printf 'pwsh subscription-concurrency=%s\n' "${AZD_SUBSCRIPTIONS_FETCH_MAX_CONCURRENCY:-unset}" >> "$TEST_LOG"
STUB
chmod +x "$temp/bin/"*

if TEST_PERSISTENT=false bash "$HOME/deploy-cloudlens.sh" >"$temp/missing-drive-error" 2>&1; then
  echo 'A missing drive must fail before provisioning.' >&2
  exit 1
fi
grep -q 'Reset User Settings' "$temp/missing-drive-error"
[[ ! -f "$TEST_LOG" ]] || { echo 'A missing drive must not reach Azure commands.' >&2; exit 1; }
echo 'PASS: the downloaded launcher explains how to mount missing Cloud Shell storage before provisioning'

mkdir -p "$HOME/clouddrive"
bash "$subject"
grep -q 'git clone --single-branch --branch cloudlensdev' "$TEST_LOG"
grep -q 'azd config set auth.useAzCliAuth true' "$TEST_LOG"
grep -q -- '-IngressVisibility private -ControlPlane private -SkipLogin -InstallKubernetesTools -EnvironmentName cloudlens -Profile data' "$TEST_LOG"
grep -q 'azd subscription-concurrency=1' "$TEST_LOG"
grep -q 'pwsh subscription-concurrency=1' "$TEST_LOG"
echo 'PASS: fresh Cloud Shell uses persistent storage, the existing login, private deployment and data profile'

bash "$subject" -EnvironmentName customer -Profile ai -Location eastus2 -TargetSubscriptionId aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
grep -q 'merge --ff-only origin/cloudlensdev' "$TEST_LOG"
grep -q -- '-EnvironmentName customer -Profile ai -Location eastus2' "$TEST_LOG"
echo 'PASS: reruns update fast-forward only and preserve supplied deployment arguments'

if TEST_PERSISTENT=false bash "$subject" >/dev/null 2>&1; then echo 'Ephemeral Cloud Shell must be refused' >&2; exit 1; fi
echo 'PASS: ephemeral Cloud Shell is rejected before provisioning'
if TEST_DIRTY=true bash "$subject" >/dev/null 2>&1; then echo 'Local changes must not be overwritten' >&2; exit 1; fi
echo 'PASS: existing local changes are preserved'

mkdir -p "$HOME/clouddrive/CloudLens/infra"
printf 'synthetic updated provider selections\n' > "$HOME/clouddrive/CloudLens/infra/.terraform.lock.hcl"
TEST_DIRTY=lock bash "$subject"
grep -q 'synthetic updated provider selections' "$HOME/clouddrive/CloudLens/infra/.terraform.lock.hcl"
for dirty in mixed staged-lock deleted-lock; do
  if TEST_DIRTY="$dirty" bash "$subject" >/dev/null 2>&1; then
    echo "Changes other than an unstaged provider-lock update must be refused: $dirty" >&2
    exit 1
  fi
done
echo 'PASS: generated provider-lock updates survive reruns without allowing source edits or deliberate lock changes'

AZD_SUBSCRIPTIONS_FETCH_MAX_CONCURRENCY=2 bash "$subject"
grep -q 'azd subscription-concurrency=2' "$TEST_LOG"
grep -q 'pwsh subscription-concurrency=2' "$TEST_LOG"
echo 'PASS: a caller-supplied subscription concurrency limit is preserved'

calls_before="$(wc -l < "$TEST_LOG")"
if TEST_UNWRITABLE=true bash "$subject" >"$temp/unwritable-drive-error" 2>&1; then
  echo 'A mounted but unwritable share must fail before provisioning.' >&2
  exit 1
fi
grep -q 'mounted but cannot be written' "$temp/unwritable-drive-error"
[[ "$(wc -l < "$TEST_LOG")" == "$calls_before" ]] || { echo 'Unwritable storage must not reach Azure commands.' >&2; exit 1; }
[[ -z "$(find "$HOME/clouddrive" -maxdepth 1 -name '.cloudlens-write-*' -print)" ]] || { echo 'Storage probes must be cleaned up.' >&2; exit 1; }
echo 'PASS: unwritable mounted storage is reported before provisioning and successful probes are cleaned up'
