#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${ACC_CLOUD:-}" && "${AZUREPS_HOST_ENVIRONMENT:-}" != cloud-shell* ]]; then
  echo "Run this launcher in Azure portal Cloud Shell (Bash), with persistent storage attached." >&2
  exit 1
fi
if ! mountpoint -q "$HOME/clouddrive"; then
  echo "Persistent Cloud Shell storage is required. Attach a file share (clouddrive), then rerun; Terraform state must survive a disconnected session." >&2
  exit 1
fi
for tool in az git curl jq unzip sha256sum pwsh; do
  command -v "$tool" >/dev/null || { echo "Missing Cloud Shell prerequisite: $tool" >&2; exit 1; }
done
az account show --output none --only-show-errors

tools="$HOME/.local/bin"
mkdir -p "$tools"
export PATH="$tools:$PATH"
temp="$(mktemp -d)"
trap 'rm -rf -- "$temp"' EXIT

version_at_least() {
  [[ "$(printf '%s\n' "$2" "$1" | sort -V | head -n 1)" == "$2" ]]
}

if ! command -v azd >/dev/null || ! version_at_least "$(azd version | sed -nE 's/^azd version ([0-9.]+).*/\1/p')" 1.32.0; then
  curl --fail --silent --show-error --location https://aka.ms/install-azd.sh -o "$temp/install-azd.sh"
  bash "$temp/install-azd.sh" --install-folder "$tools"
fi
terraform_version="$(terraform version -json 2>/dev/null | jq -r .terraform_version || true)"
if [[ "$terraform_version" != 1.* ]] || ! version_at_least "$terraform_version" 1.11.0; then
  version=1.17.2
  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "Unsupported Cloud Shell architecture." >&2; exit 1 ;;
  esac
  archive="terraform_${version}_linux_${arch}.zip"
  base="https://releases.hashicorp.com/terraform/$version"
  curl --fail --silent --show-error --location "$base/$archive" -o "$temp/$archive"
  curl --fail --silent --show-error --location "$base/terraform_${version}_SHA256SUMS" -o "$temp/SHA256SUMS"
  (cd "$temp"; grep " $archive\$" SHA256SUMS | sha256sum --check --status)
  unzip -o -q "$temp/$archive" terraform -d "$tools"
fi

repo="$HOME/clouddrive/CloudLens"
url=https://github.com/Saby007/CloudLens.git
branch=cloudlensdev
if [[ -d "$repo/.git" ]]; then
  [[ "$(git -C "$repo" remote get-url origin)" == "$url" ]] || { echo "$repo has an unexpected origin." >&2; exit 1; }
  [[ "$(git -C "$repo" branch --show-current)" == "$branch" ]] || { echo "$repo must be on $branch." >&2; exit 1; }
  [[ -z "$(git -C "$repo" status --porcelain)" ]] || { echo "$repo has local changes. Preserve them before updating; the launcher will not discard them." >&2; exit 1; }
  git -C "$repo" fetch origin "$branch"
  git -C "$repo" merge --ff-only "origin/$branch"
else
  git clone --single-branch --branch "$branch" "$url" "$repo"
fi

# Use Cloud Shell's own Azure CLI login, not a second device-code login or copied credentials.
azd config set auth.useAzCliAuth true
azd auth login --check-status --no-prompt
has_environment=false
has_profile=false
for argument in "$@"; do
  case "${argument,,}" in
    -environmentname) has_environment=true ;;
    -profile) has_profile=true ;;
  esac
done
defaults=()
$has_environment || defaults+=(-EnvironmentName cloudlens)
$has_profile || defaults+=(-Profile data)
cd "$repo"
echo "Terraform state and environment settings are persisted in $repo/.azure."
echo "Keep Cloud Shell active during provisioning. If disconnected, rerun the same command to resume."
pwsh -NoLogo -NoProfile -File ./scripts/deploy-end-to-end.ps1 \
  -IngressVisibility private -ControlPlane private -SkipLogin -InstallKubernetesTools "${defaults[@]}" "$@"
