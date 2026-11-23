# Runs as root on the private deploy host through Azure managed Run Command. invoke-private-deploy.ps1 prepends the
# assignments this script reads: environment, subscription, repository, revision, request_id, settings_b64, deploy_mode, log.
# Run Command provides no HOME, which makes azd, docker and git fail (azd panics), so the script supplies one.
set -eu
umask 077
state_dir="${CLOUDLENS_STATE_DIR:-/var/lib/cloudlens}"
work="$state_dir/deployments/$environment"
mkdir -p "$work/home"
export HOME="$work/home"
export AZURE_CONFIG_DIR="$work/azure-cli"
export DOCKER_CONFIG="$HOME/.docker"
export AZURE_DEV_COLLECT_TELEMETRY=no
export AZURE_EXTENSION_USE_DYNAMIC_INSTALL=yes_without_prompt
export CLOUDLENS_DEPLOY_REQUEST_ID="$request_id"
export CLOUDLENS_SOURCE_REVISION="$revision"
set +e
# A subshell keeps its redirection to the log, so the failure tail below reaches the Run Command output.
(
  set -e
  rm -f "$work/result.json"
  deadline=$(($(date +%s) + 1800))
  while [ ! -f "$state_dir/tools-ready" ]; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      tail -n 40 /var/log/cloudlens-tools.log
      echo "Deploy host tools did not become ready in 30 minutes." >&2
      exit 1
    fi
    sleep 15
  done
  printf '%s' "$settings_b64" | base64 -d > "$work/settings.env"
  az login --identity --output none --only-show-errors
  az account set --subscription "$subscription"
  azd auth login --managed-identity --no-prompt
  if [ ! -d "$work/CloudLens/.git" ]; then
    git clone --quiet --no-checkout "$repository" "$work/CloudLens"
  fi
  git -C "$work/CloudLens" fetch --quiet origin "$revision"
  git -C "$work/CloudLens" checkout --quiet --detach "$revision"
  cd "$work/CloudLens"
  if [ "$deploy_mode" = verify ]; then
    pwsh -NoLogo -NoProfile -File ./scripts/verify-private-deployment.ps1 -EnvironmentName "$environment" -ResultFile "$work/result.json"
  else
    pwsh -NoLogo -NoProfile -File ./scripts/deploy-on-host.ps1 -EnvironmentName "$environment" -EnvFile "$work/settings.env" -SkipLogin -Verify -ResultFile "$work/result.json"
  fi
) >> "$log" 2>&1
status=$?
if [ "$status" -ne 0 ]; then
  tail -n 40 "$log"
  exit "$status"
fi
printf 'CLOUDLENS_RESULT:'
cat "$work/result.json" || exit 1
printf '\n'
